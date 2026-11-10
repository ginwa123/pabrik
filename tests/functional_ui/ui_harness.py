"""UI test harness — a shared Vite dev server plus a per-test pabrik backend.

The suite used to boot a fresh Vite dev server for every test. Vite
compiles its module graph lazily, so the first ``page.goto`` against a
new server paid the whole compile: measured at 4.16 s cold against
0.91 s warm on the same server. With 161 tests that was ~9 of the
suite's ~12 minutes spent recompiling the same Vue app.

The split here is what removes that cost:

* ``ViteServer`` — one per pytest worker, booted once, torn down once.
  It is stateless with respect to the backend; the only thing it needs
  is a proxy target, which is why the backend port is pinned per worker
  (``FunctionalHarness.boot(port=..., pin_port=True)``) instead of being
  redrawn per test.
* ``UIHarness`` — one per test. Boots a fresh pabrik against an isolated
  tmpdir HOME on that pinned port, and tears it down. It does NOT own
  the Vite server unless it booted one itself (``run_quick`` and other
  standalone callers), which is what ``owns_vite`` records.

⛔  SAFETY INVARIANTS — INHERITED + EXTENDED  ⛔

The UI harness inherits ALL safety invariants from ``FunctionalHarness``:
``is_safe_tmp``, captured ``temp_dir``, ``ORIG_HOME`` snapshot, etc. The
new dimension is the **Vite process**.

1. ``UIHarness.teardown()`` stops Vite FIRST when it owns it, then the
   backend, then rmtree's the tempdir. If we killed the backend first,
   Vite's HTTP requests would 502 mid-shutdown and could leak dangling
   connections.

2. Vite is spawned with ``start_new_session=True`` so a single
   ``killpg(SIGTERM)`` kills the whole group (vite + esbuild + rollup
   children). Same pattern as the backend.

3. Vite logs go to a file under the system tempdir, NOT the harness
   tempdir: on Windows the child can still hold the handle when
   ``rmtree`` runs, which fails with ``PermissionError``.

4. Vite's own HOME / data dir is NOT shadowed — vite doesn't write to
   ``~/.cache`` or anything user-specific. We only shadow HOME for the
   backend; the frontend is stateless from a data perspective.

5. **Cross-platform isolation** (macOS, Linux, Windows):
   - **pnpm resolution**: ``shutil.which('pnpm')`` falls back to
     ``shutil.which('pnpm.cmd')`` for Windows, where ``pnpm`` is a batch
     script and ``subprocess.Popen(['pnpm', ...])`` would otherwise fail
     with ``FileNotFoundError``.
   - **Vite signal handling**: POSIX uses ``os.killpg(SIGTERM)`` to
     signal the whole process group; Windows falls back to ``os.kill``
     (which calls ``TerminateProcess``).
   - **Tempdir safety**: inherited from ``FunctionalHarness.teardown``
     which handles Windows paths via ``tempfile.gettempdir()``.

6. **The UI harness NEVER calls ``shutil.rmtree`` itself.** All rmtree
   goes through ``FunctionalHarness.teardown`` which is gated by
   ``is_safe_tmp``. This is the single source of truth for "may this
   path be deleted" — same as the parent harness.

Run quick:
    from ui_harness import UIHarness
    with UIHarness.boot() as h:
        print(h.web_url())  # http://127.0.0.1:<vite-port>/
"""

from __future__ import annotations

import contextlib
import dataclasses
import os
import shutil
import signal
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Iterator, Sequence

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
# ViteServer
# ============================================================================


@dataclasses.dataclass
class ViteServer:
    """A running Vite dev server whose ``/api`` proxy targets ``backend_port``.

    Booted once per pytest worker and shared by every test in it. The
    proxy target is fixed at process start (``vite.config.ts`` reads
    ``VITE_API_PROXY_TARGET`` at config load), which is why the backend
    port is pinned per worker rather than redrawn per test.
    """

    port: int
    backend_port: int
    pid: int | None
    log_path: Path
    proc: subprocess.Popen[bytes] | None
    project_root: Path
    killed: bool = False

    @classmethod
    def boot(
        cls,
        backend_port: int,
        *,
        vite_port: int | None = None,
        project_root: Path | None = None,
        ready_timeout_s: float = VITE_READY_TIMEOUT_S,
    ) -> "ViteServer":
        """Spawn Vite against ``backend_port`` and wait until it serves.

        Args:
            backend_port: The port Vite's ``/api`` proxy forwards to.
            vite_port: Vite's own port. ``None`` picks a random free port
                from the shared range, skipping ``VITE_RESERVED_PORTS``.
            project_root: The frontend source tree. Defaults to walking
                up from cwd for ``package.json`` + ``vite.config.ts``.
            ready_timeout_s: Seconds to wait for a 200 on Vite's root.

        Raises:
            FunctionalHarnessError: if the project root is missing, pnpm
                is not on PATH, or Vite does not become ready in time.
        """
        if project_root is None:
            project_root = cls._find_project_root()
        if not (project_root / "package.json").exists():
            raise FunctionalHarnessError(
                f"project_root {project_root} does not contain package.json"
            )
        if not (project_root / "vite.config.ts").exists():
            raise FunctionalHarnessError(
                f"project_root {project_root} does not contain vite.config.ts"
            )

        chosen_port = _find_free_vite_port(vite_port)

        pnpm_bin = shutil.which("pnpm") or shutil.which("pnpm.cmd")
        if pnpm_bin is None:
            raise FunctionalHarnessError(
                "pnpm not found in PATH. Install Node.js (https://nodejs.org/) "
                "and pnpm (https://pnpm.io/installation) or activate via "
                "corepack (`corepack enable && corepack prepare pnpm@latest --activate`)."
            )

        env = os.environ.copy()
        env["VITE_API_PROXY_TARGET"] = f"http://127.0.0.1:{backend_port}"
        env["BROWSER"] = "none"
        log_path = Path(tempfile.gettempdir()) / f"pabrik-vite-{os.getpid()}-{chosen_port}.log"
        log_file = log_path.open("wb")
        # ⚠️  NO ``--`` SEPARATOR before the vite flags. The previous
        # version used ``pnpm run dev -- --port 5190 --strictPort`` and
        # observed in the CI log that vite actually received
        # ``vite -- --port 5190 --strictPort --host 127.0.0.1`` — the
        # ``--`` was forwarded literally, and vite 8's CLI parser treats
        # ``--`` as "end of named options", silently dropping ``--port`` /
        # ``--strictPort`` and falling back to its default 5173.
        proc = subprocess.Popen(
            [
                pnpm_bin,
                "run",
                "dev",
                "--port",
                str(chosen_port),
                "--strictPort",
                "--host",
                "127.0.0.1",
            ],
            cwd=str(project_root),
            stdout=log_file,
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,
        )
        try:
            log_file.close()
        except Exception:
            pass

        instance = cls(
            port=chosen_port,
            backend_port=backend_port,
            pid=proc.pid,
            log_path=log_path,
            proc=proc,
            project_root=project_root,
        )
        try:
            instance._wait_ready(ready_timeout_s)
        except Exception:
            with contextlib.suppress(ProcessLookupError):
                proc.kill()
            instance._unlink_log()
            raise
        return instance

    def url(self, path: str = "/") -> str:
        """The URL a browser should load to see the running web app."""
        if not path.startswith("/"):
            path = "/" + path
        return f"http://127.0.0.1:{self.port}{path}"

    def tail_log(self, n: int = 50) -> str:
        """Tail the vite dev server log. Useful for debugging browser-test failures."""
        try:
            with self.log_path.open("rb") as f:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                f.seek(max(0, size - 65536))
                data = f.read().decode("utf-8", errors="replace")
            return "\n".join(data.splitlines()[-n:])
        except FileNotFoundError:
            return ""

    def teardown(self) -> None:
        """Stop Vite and remove its log. Idempotent."""
        self._stop()
        self._unlink_log()

    def _unlink_log(self) -> None:
        if os.name == "nt":
            for _ in range(5):
                try:
                    if self.log_path.exists():
                        self.log_path.unlink()
                    return
                except OSError:
                    time.sleep(0.5)
            return
        try:
            if self.log_path.exists():
                self.log_path.unlink()
        except OSError:
            pass

    def _stop(self) -> None:
        """SIGTERM the vite process group, fall back to SIGKILL after 5s.

        ``_reap_port_listener`` runs unconditionally at the end, on every
        platform's teardown path. Waiting for ``proc`` to exit is a
        necessary but NOT sufficient condition: the pid Popen returned is
        a launcher, and a launcher that exits while the dev server it
        started keeps running is exactly the leak that made this suite
        unbootable on Windows (see ``_reap_port_listener``). The port
        being free is the postcondition callers actually depend on, so it
        is asserted rather than inferred.
        """
        if self.proc is None or self.killed:
            return
        self.killed = True
        try:
            self._signal_group(signal.SIGTERM)
        except Exception:
            pass
        if not self._wait_dead(5.0):
            try:
                self._signal_group(signal.SIGKILL)
            except Exception:
                pass
            self._wait_dead(1.0)
        self._reap_port_listener(self.port)

    def _reap_port_listener(self, port: int) -> None:
        """Kill whatever is still LISTENING on ``port`` (Windows only).

        ``_signal_group`` signals the pid ``subprocess.Popen`` returned for
        ``pnpm run dev``, which on Windows is the ``pnpm.cmd`` / ``cmd.exe``
        launcher — not the ``node`` process that actually binds the vite
        port. When the launcher has already handed off, or ``taskkill /T``
        cannot walk from it to the live child, the signal kills nothing
        that matters and the dev server survives teardown. Measured on
        this repo: a 4-test run left 4-5 ``node.exe`` processes (≈500 MB
        each) still listening on the harness's 20000-31999 range although
        every harness tmpdir had been rmtree'd, and the accumulated leak
        exhausted a 6 GB host — the suite wedged on the fifth test with
        pytest alive, vite alive and the backend dead. Resolving the pid
        from the listening socket is the one handle that cannot be stale,
        and it is also the invariant the caller wants: nothing left bound
        to our port.

        POSIX is untouched — ``_signal_group`` there signals the real
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

    def _wait_dead(self, timeout: float) -> bool:
        """Return True iff the vite process exited within ``timeout`` seconds."""
        if self.proc is None:
            return True
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                return True
            time.sleep(0.05)
        return False

    def _signal_group(self, sig: int) -> None:
        """Signal the vite process group on POSIX, or the pid on Windows."""
        if self.pid is None:
            return
        if hasattr(os, "killpg"):
            try:
                pgid = os.getpgid(self.pid)
            except OSError:
                pgid = self.pid
            try:
                os.killpg(pgid, sig)
            except OSError:
                pass
        else:
            # Windows: TerminateProcess only kills the parent; vite spawns
            # node/esbuild children that may hold the log. Use taskkill /T
            # to kill the whole tree when available, fall back to os.kill.
            if sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    subprocess.run(
                        ["taskkill", "/PID", str(self.pid), "/T", "/F"],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=5,
                    )
                    return
                except Exception:
                    pass
            try:
                os.kill(self.pid, sig)
            except OSError:
                pass

    def _wait_ready(self, timeout_s: float) -> None:
        """Poll vite's HTTP root until it returns 200 or timeout.

        Raising 200 means vite has compiled the bundle and is serving.
        Until then, requests may hang or 404 on module imports.
        """
        assert self.proc is not None
        deadline = time.monotonic() + timeout_s
        url = f"http://127.0.0.1:{self.port}/"
        last_err: str = ""
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise FunctionalHarnessError(
                    f"vite exited rc={self.proc.returncode} during boot\n"
                    f"--- last 30 lines of vite.log ---\n"
                    + "\n".join(self.tail_log(30).splitlines()[-30:])
                )
            try:
                with urllib.request.urlopen(url, timeout=1.0) as resp:
                    if resp.status == 200:
                        return
            except (urllib.error.URLError, ConnectionError, OSError) as e:
                last_err = str(e)
            time.sleep(VITE_POLL_INTERVAL_S)
        raise FunctionalHarnessError(
            f"vite did not become ready in {timeout_s}s (last_err={last_err})\n"
            f"--- last 30 lines of vite.log ---\n"
            + "\n".join(self.tail_log(30).splitlines()[-30:])
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
            if (candidate / "package.json").exists() and (
                candidate / "vite.config.ts"
            ).exists():
                return candidate
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
# UIHarness
# ============================================================================


@dataclasses.dataclass
class UIHarness:
    """A booted pabrik backend, plus the Vite server that proxies to it.

    Lifecycle:
        h = UIHarness.boot()
        try:
            page.goto(h.web_url())
            ... drive the UI ...
        finally:
            h.teardown()

    ``owns_vite`` records whether this instance booted the Vite server
    itself. When the suite passes a shared ``vite=``, teardown stops only
    the backend and leaves Vite running for the next test.
    """

    backend: FunctionalHarness
    vite: ViteServer
    owns_vite: bool = False

    @classmethod
    def boot(
        cls,
        pabrik_bin: Path | None = None,
        *,
        port: int | None = None,
        pin_port: bool = False,
        vite: ViteServer | None = None,
        vite_port: int | None = None,
        ready_timeout_s: float = 30.0,
        vite_ready_timeout_s: float = VITE_READY_TIMEOUT_S,
        stub_llm_profile: bool = False,
        project_root: Path | None = None,
        extra_args: Sequence[str] = (),
    ) -> "UIHarness":
        """Boot a backend, and a Vite server unless one is supplied.

        Args:
            pabrik_bin: Path to the pabrik binary (default: $PABRIK_BIN or
                zig-out/bin/pabrik).
            port: Backend port. ``None`` (the default) picks a **random**
                free port from the wide shared ``[RANDOM_PORT_START,
                RANDOM_PORT_END]`` range. Ignored when ``vite`` is given —
                the backend then binds ``vite.backend_port``.
            pin_port: With ``port``, bind that exact port instead of
                scanning upward from it.
            vite: A shared, already-booted Vite server. When given, this
                instance does not own it and teardown leaves it running.
            vite_port: Vite port for the private server this call boots.
                Ignored when ``vite`` is given.
            ready_timeout_s: Seconds to wait for pabrik to become ready.
            vite_ready_timeout_s: Seconds to wait for vite to serve a 200
                on its root URL.
            stub_llm_profile: If True, pre-create a stub LLM profile so
                the backend boots without a real API key. Same as the
                functional/ harness.
            project_root: Path to the frontend source tree (default:
                walk up from cwd until we find package.json + vite.config.ts).
            extra_args: Extra backend CLI flags appended after `--port`
                (e.g. ``("--auth",)``). Defaults to none.

        Raises:
            FunctionalHarnessError: If the backend OR vite fails to boot,
                the tempdir fails the safety check, or the project root
                is missing.
        """
        if vite is not None:
            backend = FunctionalHarness.boot(
                pabrik_bin,
                port=vite.backend_port,
                pin_port=True,
                ready_timeout_s=ready_timeout_s,
                stub_llm_profile=stub_llm_profile,
                extra_args=extra_args,
            )
            backend.record_extra_pid(vite.pid or 0)
            return cls(backend=backend, vite=vite, owns_vite=False)

        backend = FunctionalHarness.boot(
            pabrik_bin,
            port=port,
            pin_port=pin_port,
            ready_timeout_s=ready_timeout_s,
            stub_llm_profile=stub_llm_profile,
            extra_args=extra_args,
        )
        try:
            private_vite = ViteServer.boot(
                backend.port,
                vite_port=vite_port,
                project_root=project_root,
                ready_timeout_s=vite_ready_timeout_s,
            )
        except Exception:
            backend.teardown()
            raise
        backend.record_extra_pid(private_vite.pid or 0)
        return cls(backend=backend, vite=private_vite, owns_vite=True)

    # ---- re-exported accessors --------------------------------------------

    @property
    def port(self) -> int:
        """The backend's port (= the proxy target)."""
        return self.backend.port

    @property
    def temp_dir(self) -> Path:
        """The isolated tmpdir; the backend logs here."""
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

    @property
    def vite_port(self) -> int:
        return self.vite.port

    @property
    def vite_pid(self) -> int | None:
        return self.vite.pid

    @property
    def vite_log_path(self) -> Path:
        return self.vite.log_path

    @property
    def vite_proc(self) -> subprocess.Popen[bytes] | None:
        return self.vite.proc

    @property
    def project_root(self) -> Path:
        return self.vite.project_root

    def http(self, *args: Any, **kwargs: Any) -> Response:
        """Delegate to the backend's HTTP client. See FunctionalHarness.http."""
        return self.backend.http(*args, **kwargs)

    def health(self) -> bool:
        return self.backend.health()

    def tail_log(self, n: int = 50) -> str:
        return self.backend.tail_log(n)

    def tail_vite_log(self, n: int = 50) -> str:
        """Tail the vite dev server log. Useful for debugging browser-test failures."""
        return self.vite.tail_log(n)

    def web_url(self, path: str = "/") -> str:
        """The URL a browser should load to see the running web app.

        Example::

            page.goto(h.web_url("/"))
        """
        return self.vite.url(path)

    # ---- teardown --------------------------------------------------------

    def teardown(self) -> None:
        """Stop the backend (and Vite, if this instance owns it).

        Order matters: Vite first, so the frontend stops proxying requests
        to a backend that is about to die.
        """
        if self.owns_vite:
            self.vite.teardown()
        self.backend.teardown()

    def __enter__(self) -> "UIHarness":
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self.teardown()


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
    "ViteServer",
    "VITE_PORT_END",
    "VITE_PORT_START",
    "VITE_READY_TIMEOUT_S",
    "VITE_RESERVED_PORTS",
    "run_quick",
]
