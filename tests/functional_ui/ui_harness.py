"""UI test harness — boots a pabrik backend + Vite dev server for Playwright.

Extends the existing ``FunctionalHarness`` boot story by ALSO spawning a
Vite dev server that:

  - Serves the Vue app from ``src/apps/desktop/``.
  - Proxies ``/api/*`` to the harness's chosen backend port (via the
    ``VITE_API_PROXY_TARGET`` env var, which ``src/apps/desktop/vite.config.ts``
    reads). This is what makes the test isolated: the running web app
    talks to the fixture's backend, not to the developer's always-on :8081.
  - Runs on its own free port — picked RANDOMLY from the wide shared
    range ``[20000, 32000]`` (see ``RANDOM_PORT_START`/`_END` and the
    ephemeral-range note in ``find_free_port_random`` in
    ``harness.py``). Skips Vite's default ``5173`` and the dev
    backend ``8081`` via the reserved-port list. Random selection
    avoids the CI pathology where the previous narrow sequential
    scan (5180..5299) was consumed across rapid test runs.

⛔  SAFETY INVARIANTS — INHERITED + EXTENDED  ⛔

The UI harness inherits ALL safety invariants from ``FunctionalHarness``:
``is_safe_tmp``, captured ``temp_dir``, ``ORIG_HOME`` snapshot, etc. The
new dimension is the **Vite process**.

1. ``UIHarness.teardown()`` stops Vite FIRST, then the backend, then
   rmtree's the tempdir. The order matters: if we killed the backend
   first, Vite's HTTP requests would 502 mid-shutdown and could leak
   dangling connections.

2. Vite is spawned with ``start_new_session=True`` so a single
   ``killpg(SIGTERM)`` kills the whole group (vite + esbuild + rollup
   children). Same pattern as the backend.

3. Vite logs go to ``temp_dir/vite.log`` (the same tempdir the backend's
   logs land in). Teardown rmtree's both via the existing
   ``FunctionalHarness.teardown()`` path.

4. Vite's own HOME / data dir is NOT shadowed — vite doesn't write to
   ``~/.cache`` or anything user-specific. We only shadow HOME for the
   backend; the frontend is stateless from a data perspective.

5. **Cross-platform isolation** (macOS, Linux, Windows):
   - **pnpm resolution** (2026-08-28 — pnpm migration): ``shutil.which('pnpm')``
     falls back to ``shutil.which('pnpm.cmd')`` for Windows, where
     ``pnpm`` is a batch script and ``subprocess.Popen(['pnpm', ...])``
     would otherwise fail with ``FileNotFoundError``. Previously this
     resolved ``npm``; npm was replaced by pnpm as the project's
     package manager (see the workspace ``.npmrc``).
   - **Vite signal handling**: POSIX uses ``os.killpg(SIGTERM)`` to
     signal the whole process group; Windows falls back to ``os.kill``
     (which calls ``TerminateProcess``).
   - **Source path resolution**: ``Path`` objects work cross-platform;
     the ``cwd=`` argument to ``subprocess.Popen`` accepts both
     ``/`` and ``\\`` separators.
   - **Tempdir safety**: inherited from ``FunctionalHarness.teardown``
     which now handles Windows paths via ``tempfile.gettempdir()``
     (the parent fix in 2026-08-21 makes ``is_safe_tmp`` cross-platform
     by using native backslashes on Windows).

6. **The UI harness NEVER calls ``shutil.rmtree`` itself.** All rmtree
   goes through ``FunctionalHarness.teardown`` which is gated by
   ``is_safe_tmp``. This is the single source of truth for "may this
   path be deleted" — same as the parent harness.

Run quick:
    from harness import UIHarness
    with UIHarness.boot() as h:
        print(h.web_url())  # http://127.0.0.1:<vite-port>/
"""

from __future__ import annotations

import contextlib
import dataclasses
import os
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Iterator, Sequence

# Reuse the existing harness — battle-tested for boot + teardown.
from harness import (
    DEFAULT_PORT,
    RANDOM_PORT_END,
    RANDOM_PORT_START,
    FunctionalHarness,
    FunctionalHarnessError,
    REQUIRED_TMP_SUBSTR,
    Response,
    find_free_port_random,
    is_safe_tmp,
    port_is_free_with_reuse,
)


# ============================================================================
# Vite-specific constants
# ============================================================================

#: Vite-specific reserved ports — Vite's default 5173 (which a developer's
#: running ``pnpm dev`` session might bind) and the dev backend port 8081
#: (always-running per project memory). Passed to
#: ``find_free_port_random(reserved=...)`` so the picker skips them
#: regardless of bind() success.
VITE_RESERVED_PORTS: tuple[int, ...] = (5173, 8081)

#: The range ``_find_free_vite_port`` actually draws from. It re-exports
#: the shared harness range instead of carrying its own numbers, because
#: commit f131e6c4 moved that range out of the kernel's ephemeral pool
#: (40000-60000 -> 20000-32000) and the copy left here went stale —
#: ``harness_safety_test`` then asserted a range the picker never used.
#: Re-exporting keeps one source of truth: change the range in
#: ``harness.py`` and every contract test follows.
VITE_PORT_START = RANDOM_PORT_START
VITE_PORT_END = RANDOM_PORT_END

#: Vite ready timeout. Vite's first compile + module-graph build takes
#: ~5-15s on a warm cache, more on cold. We poll vite's HTTP root for
#: a 200 response — by the time Vite is serving, the bundle is ready.
VITE_READY_TIMEOUT_S = 60.0

#: Polling interval for vite readiness. 200ms is fine — vite's compile
#: is the slow part, not the wait.
VITE_POLL_INTERVAL_S = 0.2


# ============================================================================
# UIHarness
# ============================================================================


@dataclasses.dataclass
class UIHarness:
    """A booted pabrik backend + Vite dev server, both bound to the same
    isolated tmpdir as the backend's HOME.

    The frontend (Vite) is spawned AFTER the backend is ready, with
    ``VITE_API_PROXY_TARGET`` pointing at the backend's chosen port.
    This makes the running web app's ``/api/*`` calls land on the
    fixture's backend, not on the developer's always-running :8081.

    Lifecycle:
        h = UIHarness.boot()
        try:
            page = browser.new_page()
            page.goto(h.web_url())
            ... drive the UI ...
        finally:
            h.teardown()

    The teardown order is:
      1. SIGTERM the Vite process group (5s budget).
      2. SIGTERM the backend process group (handled by
         ``FunctionalHarness.teardown``).
      3. Restore HOME (handled by ``FunctionalHarness.teardown``).
      4. ``is_safe_tmp`` validate the tempdir (handled by
         ``FunctionalHarness.teardown``).
      5. ``shutil.rmtree`` the tempdir (handled by
         ``FunctionalHarness.teardown``).
    """

    backend: FunctionalHarness
    vite_port: int
    vite_pid: int | None
    vite_log_path: Path
    vite_proc: subprocess.Popen[bytes] | None
    project_root: Path
    vite_killed: bool = False

    # ---- bootstrap --------------------------------------------------------

    @classmethod
    def boot(
        cls,
        pabrik_bin: Path | None = None,
        *,
        port: int | None = None,
        vite_port: int | None = None,
        ready_timeout_s: float = 30.0,
        vite_ready_timeout_s: float = VITE_READY_TIMEOUT_S,
        stub_llm_profile: bool = False,
        project_root: Path | None = None,
        extra_args: Sequence[str] = (),
    ) -> "UIHarness":
        """Boot backend + vite against an isolated tmpdir HOME.

        Args:
            pabrik_bin: Path to the pabrik binary (default: $PABRIK_BIN or
                zig-out/bin/pabrik).
            port: Backend port. ``None`` (the default) picks a **random**
                free port from the wide shared ``[RANDOM_PORT_START,
                RANDOM_PORT_END]`` range. Pass an explicit integer to
                fall back to a sequential scan starting from that port
                (legacy behaviour, mainly for debugging).
            vite_port: Vite port. ``None`` (the default) picks a random
                free port from the same wide range, with reserved ports
                = ``(5173, 8081)``. Pass a value to skip the random pick.
            ready_timeout_s: Seconds to wait for pabrik to become ready.
            vite_ready_timeout_s: Seconds to wait for vite to serve a 200
                on its root URL.
            stub_llm_profile: If True, pre-create a stub LLM profile so
                the backend boots without a real API key. Same as the
                functional/ harness.
            project_root: Path to the frontend source tree (default:
                walk up from cwd until we find package.json + vite.config.ts).
                The harness will cwd to this directory when spawning vite.
            extra_args: Extra backend CLI flags appended after `--port`
                (e.g. ``("--auth",)``). Defaults to none.

        Raises:
            FunctionalHarnessError: If the backend OR vite fails to boot,
                the tempdir fails the safety check, or the project root
                is missing.
        """
        # 1. Boot the backend (inherited harness). If this fails, the
        #    tempdir is cleaned up by FunctionalHarness.boot internally.
        backend = FunctionalHarness.boot(
            pabrik_bin,
            port=port,
            ready_timeout_s=ready_timeout_s,
            stub_llm_profile=stub_llm_profile,
            extra_args=extra_args,
        )

        # 2. Resolve the frontend project root.
        if project_root is None:
            project_root = cls._find_project_root()
        if not (project_root / "package.json").exists():
            backend.teardown()
            raise FunctionalHarnessError(
                f"project_root {project_root} does not contain package.json"
            )
        if not (project_root / "vite.config.ts").exists():
            backend.teardown()
            raise FunctionalHarnessError(
                f"project_root {project_root} does not contain vite.config.ts"
            )

        # 3. Pick a free vite port.
        chosen_vite_port = _find_free_vite_port(vite_port)

        # 4. Resolve the pnpm binary. On Windows, ``pnpm`` is a batch
        #    script (``pnpm.cmd``) and ``subprocess.Popen(["pnpm", ...])``
        #    fails with FileNotFoundError because Windows won't
        #    auto-execute .cmd files from a list-form argv. shutil.which
        #    resolves to the correct executable for the platform.
        #    (pnpm replaced npm as the project's package manager on
        #    2026-08-28 — see the workspace .npmrc.)
        pnpm_bin = shutil.which("pnpm") or shutil.which("pnpm.cmd")
        if pnpm_bin is None:
            backend.teardown()
            raise FunctionalHarnessError(
                "pnpm not found in PATH. Install Node.js (https://nodejs.org/) "
                "and pnpm (https://pnpm.io/installation) or activate via "
                "corepack (`corepack enable && corepack prepare pnpm@latest --activate`)."
            )

        # 5. Spawn vite. We use pnpm + --port + --strictPort so vite
        #    fails fast if it can't bind (instead of silently picking
        #    the next port and breaking our env wiring).
        #
        #    ⚠️  NO ``--`` SEPARATOR before the vite flags. The previous
        #    version used ``pnpm run dev -- --port 5190 --strictPort``
        #    and observed in the CI log that vite actually received
        #    ``vite -- --port 5190 --strictPort --host 127.0.0.1`` — the
        #    ``--`` was forwarded literally, and vite 8's CLI parser
        #    treats ``--`` as "end of named options", silently dropping
        #    ``--port`` / ``--strictPort`` and falling back to its
        #    default 5173. We saw 13 test errors with vite ending up on
        #    5189 (sequential scan) instead of the harness's chosen
        #    5190, and the harness's ``_wait_vite_ready`` then timed
        #    out waiting for 5190 to respond. Dropping the ``--`` lets
        #    pnpm forward the flags as proper options.
        env = os.environ.copy()
        env["VITE_API_PROXY_TARGET"] = f"http://127.0.0.1:{backend.port}"
        # Vite reads .env files; we set BROWSER=none so vite doesn't try
        # to open a browser tab on the developer's display.
        env["BROWSER"] = "none"
        # Vite log outside temp_dir so backend's rmtree doesn't fail on
        # Windows when vite child still holds the file (PermissionError).
        # Use a separate temp file that we clean up explicitly.
        vite_log_path = Path(tempfile.gettempdir()) / f"pabrik-vite-{backend.temp_dir.name}.log"
        vite_log_file = vite_log_path.open("wb")
        vite_proc = subprocess.Popen(
            [
                pnpm_bin,
                "run",
                "dev",
                "--port",
                str(chosen_vite_port),
                "--strictPort",
                "--host",
                "127.0.0.1",
            ],
            cwd=str(project_root),
            stdout=vite_log_file,
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,
        )
        # Parent can close its handle — child has duped it. On Windows, keeping
        # it open prevents shutil.rmtree (PermissionError: file in use) on teardown.
        try:
            vite_log_file.close()
        except Exception:
            pass

        instance = cls(
            backend=backend,
            vite_port=chosen_vite_port,
            vite_pid=vite_proc.pid,
            vite_log_path=vite_log_path,
            vite_proc=vite_proc,
            project_root=project_root,
        )

        # 5. Wait for vite to be ready. If this fails, tear down everything.
        try:
            instance._wait_vite_ready(vite_ready_timeout_s)
        except Exception:
            with contextlib.suppress(ProcessLookupError):
                vite_proc.kill()
            backend.teardown()
            raise

        return instance

    # ---- re-exported accessors --------------------------------------------

    @property
    def port(self) -> int:
        """The backend's port (= the proxy target)."""
        return self.backend.port

    @property
    def temp_dir(self) -> Path:
        """The isolated tmpdir; the frontend and backend both log here."""
        return self.backend.temp_dir

    @property
    def orig_home(self) -> str:
        """The real $HOME that was snapshotted at boot."""
        return self.backend.orig_home

    @property
    def pid(self) -> int | None:
        """The backend's PID. Use ``backend_pid`` for explicit access."""
        return self.backend.pid

    @property
    def backend_pid(self) -> int | None:
        return self.backend.pid

    @property
    def log_path(self) -> Path:
        """The backend's log path. Use ``backend_log_path`` for explicit access."""
        return self.backend.log_path

    @property
    def backend_log_path(self) -> Path:
        return self.backend.log_path

    def http(self, *args: Any, **kwargs: Any) -> Response:
        """Delegate to the backend's HTTP client. See FunctionalHarness.http."""
        return self.backend.http(*args, **kwargs)

    def health(self) -> bool:
        return self.backend.health()

    def tail_log(self, n: int = 50) -> str:
        return self.backend.tail_log(n)

    def tail_vite_log(self, n: int = 50) -> str:
        """Tail the vite dev server log. Useful for debugging browser-test failures."""
        try:
            with self.vite_log_path.open("rb") as f:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                f.seek(max(0, size - 65536))
                data = f.read().decode("utf-8", errors="replace")
            return "\n".join(data.splitlines()[-n:])
        except FileNotFoundError:
            return ""

    def web_url(self, path: str = "/") -> str:
        """The URL a browser should load to see the running web app.

        Example::

            page.goto(h.web_url("/"))

        Path is joined with a leading slash if missing.
        """
        if not path.startswith("/"):
            path = "/" + path
        return f"http://127.0.0.1:{self.vite_port}{path}"

    # ---- teardown --------------------------------------------------------

    def teardown(self) -> None:
        """Stop vite, then teardown the backend (which cleans the tempdir).

        Order matters:
          1. Stop vite — so the frontend stops proxying requests to a
             backend that may be about to die.
          2. Backend teardown — SIGTERM, restore HOME, validate tmpdir,
             rmtree.
        """
        # 1. Stop vite. Idempotent.
        self._stop_vite()

        # 2. Backend teardown. This handles HOME restore, SIGTERM/SIGKILL
        #    the binary, is_safe_tmp validation, and rmtree.
        self.backend.teardown()
        # Vite log is now outside temp_dir (to avoid Windows PermissionError
        # on rmtree when child still holds the file). Clean it separately
        # with retries.
        if os.name == "nt":
            for _ in range(5):
                try:
                    if self.vite_log_path.exists():
                        self.vite_log_path.unlink()
                    break
                except OSError:
                    time.sleep(0.5)
        else:
            try:
                if self.vite_log_path.exists():
                    self.vite_log_path.unlink()
            except OSError:
                pass

    def __enter__(self) -> "UIHarness":
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self.teardown()

    # ---- private helpers -------------------------------------------------

    def _stop_vite(self) -> None:
        """SIGTERM the vite process group, fall back to SIGKILL after 5s.

        Mirrors the backend's teardown pattern but uses shorter timeouts
        (vite doesn't have a graceful shutdown endpoint — it's fine to
        be aggressive here).

        ``_reap_port_listener`` runs unconditionally at the end, on every
        platform's teardown path. Waiting for ``vite_proc`` to exit is a
        necessary but NOT sufficient condition: the pid Popen returned is
        a launcher, and a launcher that exits while the dev server it
        started keeps running is exactly the leak that made this suite
        unbootable on Windows (see ``_reap_port_listener``). The port
        being free is the postcondition callers actually depend on, so it
        is asserted rather than inferred.
        """
        if self.vite_proc is None or self.vite_killed:
            return
        self.vite_killed = True
        # Send SIGTERM to the whole process group.
        try:
            self._signal_vite_group(signal.SIGTERM)
        except Exception:
            pass
        if not self._wait_vite_dead(5.0):
            # Last resort — SIGKILL.
            try:
                self._signal_vite_group(signal.SIGKILL)
            except Exception:
                pass
            self._wait_vite_dead(1.0)  # best-effort final wait
        self._reap_port_listener(self.vite_port)

    def _reap_port_listener(self, port: int) -> None:
        """Kill whatever is still LISTENING on ``port`` (Windows only).

        Why this exists, concretely. ``_signal_vite_group`` signals the
        pid ``subprocess.Popen`` returned for ``pnpm run dev``, which on
        Windows is the ``pnpm.cmd`` / ``cmd.exe`` launcher — not the
        ``node`` process that actually binds the vite port. When the
        launcher has already handed off, or ``taskkill /T`` cannot walk
        from it to the live child, the signal kills nothing that matters
        and the dev server survives teardown. Measured on this repo: a
        4-test run left 4-5 ``node.exe`` processes (≈500 MB each) still
        listening on the harness's 20000-31999 range although every
        harness tmpdir had been rmtree'd, and the accumulated leak
        exhausted a 6 GB host — the suite wedged on the fifth test with
        pytest alive, vite alive and the backend dead. Resolving the pid
        from the listening socket is the one handle that cannot be stale,
        and it is also the invariant the caller wants: nothing left bound
        to our port.

        POSIX is untouched — ``_signal_vite_group`` there signals the real
        process group with ``killpg`` and does reap the tree.
        """
        if os.name != "nt":
            return
        try:
            listing = subprocess.run(
                ["netstat", "-ano", "-p", "TCP"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=10,
            ).stdout
        except Exception:
            return
        for line in listing.splitlines():
            parts = line.split()
            # `  TCP    127.0.0.1:22470    0.0.0.0:0    LISTENING    2272`
            if len(parts) < 5 or parts[0] != "TCP" or parts[3] != "LISTENING":
                continue
            if not parts[1].endswith(f":{port}"):
                continue
            with contextlib.suppress(Exception):
                subprocess.run(
                    ["taskkill", "/PID", parts[4], "/T", "/F"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=10,
                )

    def _wait_vite_dead(self, timeout: float) -> bool:
        """Return True iff the vite process exited within ``timeout`` seconds."""
        if self.vite_proc is None:
            return True
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.vite_proc.poll() is not None:
                return True
            time.sleep(0.05)
        return False

    def _signal_vite_group(self, sig: int) -> None:
        """Signal the vite process group on POSIX, or the pid on Windows."""
        if self.vite_pid is None:
            return
        if hasattr(os, "killpg"):
            try:
                pgid = os.getpgid(self.vite_pid)
            except OSError:
                pgid = self.vite_pid
            try:
                os.killpg(pgid, sig)
            except OSError:
                pass
        else:
            # Windows: TerminateProcess only kills the parent; vite spawns
            # node/esbuild children that may hold vite.log. Use taskkill /T
            # to kill the whole tree when available, fall back to os.kill.
            if sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    subprocess.run(
                        ["taskkill", "/PID", str(self.vite_pid), "/T", "/F"],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=5,
                    )
                    return
                except Exception:
                    pass
            try:
                os.kill(self.vite_pid, sig)
            except OSError:
                pass

    def _wait_vite_ready(self, timeout_s: float) -> None:
        """Poll vite's HTTP root until it returns 200 or timeout.

        Raising 200 means vite has compiled the bundle and is serving.
        Until then, requests may hang or 404 on module imports.
        """
        assert self.vite_proc is not None
        deadline = time.monotonic() + timeout_s
        url = f"http://127.0.0.1:{self.vite_port}/"
        last_err: str = ""
        while time.monotonic() < deadline:
            if self.vite_proc.poll() is not None:
                log = (
                    self.vite_log_path.read_text(errors="replace")
                    if self.vite_log_path.exists()
                    else ""
                )
                raise FunctionalHarnessError(
                    f"vite exited rc={self.vite_proc.returncode} during boot\n"
                    f"--- last 30 lines of vite.log ---\n"
                    + "\n".join(log.splitlines()[-30:])
                )
            try:
                with urllib.request.urlopen(url, timeout=1.0) as resp:
                    if resp.status == 200:
                        return
            except (urllib.error.URLError, ConnectionError, OSError) as e:
                last_err = str(e)
            time.sleep(VITE_POLL_INTERVAL_S)
        log = (
            self.vite_log_path.read_text(errors="replace")
            if self.vite_log_path.exists()
            else ""
        )
        raise FunctionalHarnessError(
            f"vite did not become ready in {timeout_s}s (last_err={last_err})\n"
            f"--- last 30 lines of vite.log ---\n"
            + "\n".join(log.splitlines()[-30:])
        )

    @staticmethod
    def _find_project_root() -> Path:
        """Walk up from cwd looking for a directory with package.json + vite.config.ts.

        Also checks the standard ``src/apps/desktop/`` subdirectory at
        each level (the project's expected layout: package.json +
        vite.config.ts live inside src/apps/desktop/, NOT at the repo
        root). Falls back to the relative path ``src/apps/desktop`` from
        the cwd. If the harness is invoked from elsewhere, override via
        ``project_root=``.
        """
        cwd = Path.cwd().resolve()
        for candidate in (cwd, *cwd.parents):
            # 1. Both files in the SAME directory (monorepo-style).
            if (candidate / "package.json").exists() and (
                candidate / "vite.config.ts"
            ).exists():
                return candidate
            # 2. Standard project layout: vite lives in src/apps/desktop/.
            standard = candidate / "src" / "apps" / "desktop"
            if (standard / "package.json").exists() and (
                standard / "vite.config.ts"
            ).exists():
                return standard
        raise FunctionalHarnessError(
            f"Could not find a project_root with package.json + vite.config.ts "
            f"starting from {cwd}. Pass project_root= explicitly."
        )


# ============================================================================
# Helpers
# ============================================================================


def _find_free_vite_port(suggested: int | None) -> int:
    """Find a free port for vite.

    Strategy: random selection from the shared ``harness.RANDOM_PORT_*``
    range (re-exported as ``VITE_PORT_START`` / ``VITE_PORT_END``).
    Avoids the two CI pathologies the previous sequential scan suffered
    from:

      1. **Sequential consumption** — every UI test boot incremented
         the port, so a long suite filled the legacy 5180..5299 window
         (Vite scans the legacy range sequentially too — see the CI
         log from the bug: vite tried 5173..5188 then landed on 5189
         because the prior 5173-5188 ports were held by something).
      2. **Vite ignores --port** — vite 8 silently drops ``--port`` /
         ``--strictPort`` if pnpm forwards the argv with a literal
         ``--`` separator (see the spawn site above for the fix).
         Combined with the narrow sequential scan, this caused
         repeated test failures on shared CI runners.

    Random pick from 12k ports with 50 attempts is collision-proof
    for any realistic host occupancy. Vite-specific reserved ports
    (``5173, 8081``) are excluded via ``reserved=`` so the picker
    never lands on Vite's default or the dev backend.

    If ``suggested`` is provided (e.g. for deterministic debugging),
    use it iff it's free.
    """
    if suggested is not None:
        if not port_is_free_with_reuse(suggested):
            raise FunctionalHarnessError(
                f"Suggested vite port {suggested} is already in use"
            )
        return suggested
    return find_free_port_random(reserved=VITE_RESERVED_PORTS)


# Back-compat alias — older internal callers used the local helper.
# The shared ``port_is_free_with_reuse`` (with SO_REUSEADDR, identical
# semantics) supersedes it but the name is kept so any future diffs
# that touch the local helper don't break.
_port_is_free = port_is_free_with_reuse


# ============================================================================
# Convenience for scripts that don't want pytest fixtures
# ============================================================================


def run_quick(
    pabrik_bin: Path | None = None,
    *,
    port: int | None = None,
    stub_llm_profile: bool = False,
) -> Iterator[UIHarness]:
    """Context manager for use outside pytest.

    Example::

        with run_quick() as h:
            print(h.web_url())  # http://127.0.0.1:<vite-port>/
    """
    h = UIHarness.boot(
        pabrik_bin, port=port, stub_llm_profile=stub_llm_profile
    )
    try:
        yield h
    finally:
        h.teardown()


__all__ = [
    "UIHarness",
    "VITE_PORT_END",
    "VITE_PORT_START",
    "VITE_READY_TIMEOUT_S",
    "VITE_RESERVED_PORTS",
    "run_quick",
]
