"""Functional test harness for pabrik.

Boots a real `pabrik` binary against an isolated tmpdir HOME and provides
a typed HTTP client for the API. Every byte of state (DB, config, design
files, attachments) lives under the tempdir allocated at boot; teardown
rmtree's that tempdir, never anything else.

⛔  SAFETY INVARIANTS — DO NOT WEAKEN WITHOUT REVIEW  ⛔

1. ``is_safe_tmp(path, orig_home)`` is the SINGLE source of truth for
   "may this path be deleted by the harness". Any ``shutil.rmtree`` call
   MUST be gated by it. There is no second code path.

2. The harness NEVER calls ``os.environ["HOME"]`` inside teardown. It
   uses the captured ``self.temp_dir`` attribute, which is set once at
   boot and not subject to mid-test env mutation.

3. The harness NEVER uses ``~``, ``os.path.expanduser``, or relative
   paths. All paths are absolute and captured.

4. If ``is_safe_tmp()`` returns False, teardown RAISES instead of
   deleting. The tempdir is leaked; the developer's home is never
   touched. This is the correct trade-off.

5. ``ORIG_HOME`` is captured BEFORE ``os.environ["HOME"]`` is shadowed
   and restored as the first step of teardown. A stray ``~`` in any
   downstream code expands to the tempdir, not the real home.

6. (Windows-only) ``XDG_CONFIG_HOME`` / ``XDG_STATE_HOME`` /
   ``XDG_DATA_HOME`` / ``XDG_CACHE_HOME`` plus ``USERPROFILE`` /
   ``APPDATA`` / ``LOCALAPPDATA`` are captured BEFORE shadowing and
   restored on teardown. The Windows child's env points inside
   ``temp_dir`` (``<temp_dir>/.config``, ``<temp_dir>/AppData/...``)
   so pabrik's XDG/APPDATA-aware code lands inside the tempdir even
   when the parent shell has those vars set to the real home. Linux/mac
   keep the original parent env per project request ("dont touch linux
   and mac") — child ``HOME`` is still isolated there via the existing
   ``env["HOME"]`` path.

The five negative tests in ``tests/functional/harness_safety_test.py``
guard these invariants against regression.
"""

from __future__ import annotations

import contextlib
import dataclasses
import json
import os
import random
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from functools import lru_cache
from pathlib import Path
from typing import Any, Iterator, Sequence

# ============================================================================
# Safety constants
# ============================================================================

#: Tuple of absolute path prefixes that the harness recognises as "tmpdir".
#: ``tempfile.mkdtemp`` on Linux returns ``/tmp/...``; on macOS it returns
#: ``/var/folders/.../T/...`` (or ``/private/var/folders/.../T/...`` after
#: ``realpath``); on Windows it returns ``C:\Users\<u>\AppData\Local\Temp\...``
#: (or a custom ``%TEMP%`` location). The POSIX prefix list is unused on
#: Windows and the Windows prefix uses native backslashes so ``startswith``
#: matches ``realpath``'s output on that OS.
ALLOWED_TMP_PREFIXES: tuple[str, ...] = (
    "/tmp/",
    "/private/tmp/",
    "/private/var/folders/",
    "/var/folders/",
    tempfile.gettempdir() + "/",
) if os.name != "nt" else (
    # Windows: only ``tempfile.gettempdir()`` (e.g. ``C:\Users\u\AppData\Local\Temp``)
    # is a valid tmpdir — the POSIX prefixes above don't exist. Use native
    # backslashes so the prefix matches ``os.path.realpath``'s output.
    tempfile.gettempdir().rstrip("\\") + "\\",
)

#: Substring that every harness-allocated tmpdir must contain. Acts as
#: a "namespace" so a buggy caller that points ``mkdtemp`` output at a
#: non-tmpdir path is rejected.
REQUIRED_TMP_SUBSTR = "pabrik-func-"

#: Last-resort kill signal. Windows has no ``signal.SIGKILL`` (the
#: attribute simply doesn't exist — accessing it raises AttributeError,
#: which the OSError-only handlers below would NOT swallow).
#: ``SIGTERM`` already maps to TerminateProcess on Windows, so it is
#: the correct fallback there.
_SIGKILL: int = getattr(signal, "SIGKILL", signal.SIGTERM)

#: Port range the harness will scan for a free port. Skip 8081 (the
#: always-running dev port per project memory). Used by the legacy
#: sequential picker (``_find_free_port_sequential``); the modern
#: ``_find_free_port`` defaults to random selection in the much larger
#: range below.
DEFAULT_PORT = 8080
PORT_SCAN_END = 8199

#: Random-port range used by ``_find_free_port`` (no args) and
#: ``find_free_port_random``. Deliberately BELOW the kernel's ephemeral
#: range rather than inside it.
#:
#: The previous range was 40000-60000, chosen for 20,000 ports of
#: headroom against TIME_WAIT. But Linux's default
#: ``net.ipv4.ip_local_port_range`` is 32768-60999, so 40000-60000 sits
#: ENTIRELY INSIDE the pool the kernel hands out as *source* ports for
#: outgoing connections. Every ``bind()`` probe the harness does, plus
#: every pnpm / vite / zig / git / curl on the box, draws from that same
#: pool. The picker closes its probe socket and returns the number; the
#: pabrik child binds the real listener tens of ms later, and in between
#: the port can be taken. The collision surfaces as
#: ``error: BindFailed`` at boot and — before the matching main.zig fix —
#: an rc=-11 "crash" that fails an unrelated test. Observed in
#: llm_stream_get_test::test_stream_route_does_not_shadow_sibling_routes
#: on a loaded self-hosted runner.
#:
#: 20000-32000 gives 12,000 ports that no ephemeral allocation can reach
#: under a default ``ip_local_port_range`` and stays clear of the
#: documented dev ports (8080/8081) and the sequential 8080-8199 window.
RANDOM_PORT_START = 20000
RANDOM_PORT_END = 32000

#: Number of random attempts before giving up. With 12,000 ports and
#: a busy CI runner holding a few hundred listeners, the chance of 50
#: consecutive collisions is vanishingly small — safely "never
#: happens". If a host is so loaded that this raises, the harness
#: surfaces the failure with the actionable hint to widen the range.
RANDOM_PORT_ATTEMPTS = 50

#: Ports that the random picker MUST skip regardless of bind() success.
#: 8081 is the always-running dev backend per project memory. The
#: ``UIHarness`` adds 5173 (Vite's default) when calling
#: ``find_free_port_random(reserved=...)``.
RESERVED_PORTS: tuple[int, ...] = (8081,)


# ============================================================================
# Errors
# ============================================================================


class FunctionalHarnessError(RuntimeError):
    """Raised when the harness cannot safely proceed.

    Distinct from ``AssertionError`` (which is what API-level asserts
    raise) so test fixtures can catch this and treat it as a setup
    failure rather than a test failure.
    """


# ============================================================================
# Safety validator
# ============================================================================


def _canonical(path: str) -> str:
    """``normcase(realpath(path))`` — the one spelling every comparison here uses.

    Both halves are load-bearing, and the first one cost 548 test errors
    on the windows-2022 CI cell before it existed.

    ``realpath`` canonicalises the candidate. On Windows that includes
    expanding 8.3 SHORT names to long ones, so a path under a runner's
    ``%TEMP%`` of ``C:\\Users\\RUNNER~1\\AppData\\Local\\Temp`` comes back
    as ``C:\\Users\\runneradmin\\AppData\\Local\\Temp``. A GitHub
    ``windows-2022`` runner's ``%TEMP%`` is exactly that short form, and
    ``tempfile.gettempdir()`` — which builds ``ALLOWED_TMP_PREFIXES`` —
    returns it verbatim. Comparing the canonicalised candidate against the
    RAW allow-list therefore failed for the harness's own tempdir, on
    every test in the job, with an error message that printed both sides
    in a form that visibly matched and so read as nonsense:

        mkdtemp produced an unsafe path: C:\\Users\\RUNNER~1\\...\\pabrik-func-abc
        Expected prefix in ('C:\\\\Users\\\\RUNNER~1\\\\AppData\\\\Local\\\\Temp\\\\',)

    (neither of those is the string that was compared — ``real`` is).

    ``normcase`` supplies the other half: a Windows path comparison is
    case-insensitive, which this function has always assumed and never
    actually got. On POSIX both calls are near-identity, so nothing
    changes there.
    """
    return os.path.normcase(os.path.realpath(path))


@lru_cache(maxsize=32)
def _canonical_prefix(prefix: str) -> str:
    """``_canonical`` for an allow-list entry, memoised.

    The prefixes come from ``tempfile.gettempdir()`` and never change
    within a process, but ``realpath`` costs syscalls and this is on the
    teardown path of every test. Cached per prefix string, so a test that
    monkeypatches ``ALLOWED_TMP_PREFIXES`` with a fresh tuple still gets
    a freshly-computed value rather than a stale one.
    """
    return _canonical(prefix)


def is_safe_tmp(path: str | os.PathLike[str], orig_home: str | os.PathLike[str]) -> bool:
    """Return True iff ``path`` is a tmpdir the harness is allowed to rmtree.

    Returns False for:
      - empty strings
      - non-absolute paths
      - paths outside the allow-list of tmpdir prefixes
      - paths missing the REQUIRED_TMP_SUBSTR namespace
      - paths that resolve to the real ``$HOME`` (catches symlinks)

    Every comparison below is made in ONE canonical form, on both sides.
    The allow-list is an assertion about *which directories*; spelling
    the same directory two different ways is not a different directory,
    and treating it as one would either fail safe-but-uselessly (the
    8.3 bug above) or — if resolved the other way round — pass something
    that should not pass.

    This function is the single source of truth for "may this be deleted".
    ANY rmtree in the harness MUST be gated by it.
    """
    if not path:
        return False
    p = os.fspath(path)
    if not os.path.isabs(p):
        return False
    real = _canonical(p)
    if not any(real.startswith(_canonical_prefix(prefix)) for prefix in ALLOWED_TMP_PREFIXES):
        return False
    if REQUIRED_TMP_SUBSTR not in real:
        return False
    real_home = _canonical(os.fspath(orig_home)) if orig_home else ""
    if real_home and real == real_home:
        return False
    return True


def harness_path(harness: Any, *parts: str) -> str:
    """Return an absolute path under ``harness``'s isolated tempdir.

    Use this for any path a test PUTS INTO A JSON BODY that the server
    resolves — an agent/routine item ``path``, a knowledge
    ``file_path``, a session ``cwd``, a command ``workdir``.

    The reason is not tidiness. The server validates these with
    ``std.fs.path.isAbsolute`` and rejects a relative one with 400
    ``NotAbsolutePath``, and ``isAbsolute`` is platform-relative: on
    windows-2022 ``"/tmp/a.md"`` is NOT absolute, so a literal that is
    correct on ubuntu-24.04 fails at the HTTP door and the test reports
    a server regression that does not exist. Deriving from
    ``harness.temp_dir`` (itself a real ``mkdtemp`` output) is absolute
    on every platform and needs no ``os.path`` juggling at the call
    site.

    Accepts either a ``FunctionalHarness`` or a ``UIHarness`` — both
    expose ``temp_dir``.

        json_body={"path": harness_path(h, "my-agent")}

    Passing empty ``parts`` returns the tempdir itself.
    """
    return str(harness.temp_dir.joinpath(*parts))


# ============================================================================
# Response + Harness
# ============================================================================


@dataclasses.dataclass(frozen=True)
class Response:
    """A typed HTTP response from the pabrik API."""

    status: int
    body: bytes
    headers: dict[str, str] = dataclasses.field(default_factory=dict)

    def json(self) -> Any:
        """Parse the body as JSON. Raises on invalid JSON."""
        return json.loads(self.body)


@dataclasses.dataclass
class FunctionalHarness:
    """A booted pabrik instance bound to an isolated tmpdir.

    Lifecycle:
        h = FunctionalHarness.boot()
        try:
            r = h.http("POST", "/api/workspaces", json_body={"name": "x"})
            assert r.status == 201
        finally:
            h.teardown()

    The tempdir is validated BEFORE teardown runs. If validation fails
    (e.g., mkdtemp returned something unexpected), teardown raises
    and refuses to delete anything.
    """

    port: int
    pabrik_bin: Path
    temp_dir: Path
    orig_home: str
    log_path: Path
    pid: int | None = None
    # The Popen `boot()` spawned, kept so `_wait_dead` can poll it:
    # `Popen.poll()` is the only portable NON-BLOCKING liveness probe (see
    # `_wait_dead`). None only for a hand-constructed harness.
    proc: subprocess.Popen | None = dataclasses.field(default=None, repr=False)
    dry_run: bool = False
    _stopped: bool = dataclasses.field(default=False, repr=False)
    # Windows original env snapshot (USERPROFILE/APPDATA/LOCALAPPDATA) — empty on POSIX.
    orig_userprofile: str = ""
    orig_appdata: str = ""
    orig_localappdata: str = ""
    # XDG original env snapshots — empty if not set in parent env.
    orig_xdg_config_home: str = ""
    orig_xdg_state_home: str = ""
    orig_xdg_data_home: str = ""
    orig_xdg_cache_home: str = ""

    # ---- bootstrap --------------------------------------------------------

    @classmethod
    def boot(
        cls,
        pabrik_bin: Path | None = None,
        *,
        port: int | None = None,
        ready_timeout_s: float = 30.0,
        stub_llm_profile: bool = False,
        extra_args: Sequence[str] = (),
    ) -> "FunctionalHarness":
        """Boot a fresh pabrik binary against an isolated tmpdir HOME.

        Args:
            pabrik_bin: Path to the pabrik binary. Defaults to ``$PABRIK_BIN``
                or a known zig-out path.
            port: Backend port. ``None`` (the default) picks a **random**
                free port from the wide ``[RANDOM_PORT_START,
                RANDOM_PORT_END]`` range via ``find_free_port_random`` —
                see the Port Allocation section of
                ``tests/functional/README.md`` for why this replaced the
                previous sequential scan. Pass an explicit integer (e.g.
                ``port=8123``) to fall back to a sequential scan from
                that port for backwards compat / debugging.
            ready_timeout_s: Seconds to wait for pabrik to become ready.
            stub_llm_profile: Pre-create a stub LLM profile so the
                backend boots without a real API key.
            extra_args: Extra CLI flags appended after `--port` (e.g.
                `("--http2", "h2c")`). Defaults to none, so existing
                callers keep the exact same command line.

        Raises:
            FunctionalHarnessError: if HOME is unset, the tmpdir fails
                the safety check, the binary is missing, or the binary
                does not become ready within ``ready_timeout_s``.
        """
        # 1. Snapshot HOME BEFORE we shadow it.
        # On Windows, HOME is not set by default; USERPROFILE is.
        orig_home = os.environ.get("HOME", "") or os.environ.get("USERPROFILE", "")
        if not orig_home:
            # Fallback to expanduser for edge cases.
            try:
                orig_home = str(Path.home())
            except Exception:
                orig_home = ""
        if not orig_home:
            raise FunctionalHarnessError(
                "HOME not set; refusing to boot. "
                "Functional tests must run in a normal user shell."
            )

        # Snapshot Windows envs for isolation and restore.
        orig_userprofile = os.environ.get("USERPROFILE", "")
        orig_appdata = os.environ.get("APPDATA", "")
        orig_localappdata = os.environ.get("LOCALAPPDATA", "")

        # Snapshot XDG envs for isolation and restore. These are used by
        # pabrik on Linux for config/state/cache paths (XDG spec). If the
        # parent env has e.g. XDG_CONFIG_HOME=/home/user/.config, the child
        # must NOT inherit it — otherwise config.json lands in the real home.
        orig_xdg_config_home = os.environ.get("XDG_CONFIG_HOME", "")
        orig_xdg_state_home = os.environ.get("XDG_STATE_HOME", "")
        orig_xdg_data_home = os.environ.get("XDG_DATA_HOME", "")
        orig_xdg_cache_home = os.environ.get("XDG_CACHE_HOME", "")

        # 1.5. Reap orphan pabrik pids from prior aborted runs. This MUST
        #      run BEFORE _find_free_port() so the random pick sees a
        #      clean slate. Without this, a prior `kill -9` of the pytest
        #      worker leaves pabrik children alive in their own pgids,
        #      holding their ports — and over time those zombies consume
        #      random picks in the 20k window. Failures here are
        #      non-fatal: if reap raises, print a warning and continue
        #      (a slightly leakier state is strictly better than
        #      aborting).
        try:
            _reap_orphan_test_pids()
        except Exception as e:
            print(f"warning: orphan reap failed: {e}", file=sys.stderr)

        # 2. Pick a free port. None / no arg → random pick from the
        #    20k-port range (see RANDOM_PORT_START..END). Explicit
        #    int → sequential scan from that port for backward compat
        #    with tests that want a deterministic value.
        chosen_port = _find_free_port(port)

        # 3. mkdtemp. Atomic, fresh, mode 0700.
        temp_dir = Path(tempfile.mkdtemp(prefix=REQUIRED_TMP_SUBSTR))

        # 4. Validate BEFORE shadowing HOME. If this fails, we abort
        #    and the tempdir is leaked. Leaking a tempdir is preferable
        #    to corrupting state.
        if not is_safe_tmp(str(temp_dir), orig_home):
            raise FunctionalHarnessError(
                f"mkdtemp produced an unsafe path: {temp_dir}\n"
                f"Expected prefix in {ALLOWED_TMP_PREFIXES}\n"
                f"With substring {REQUIRED_TMP_SUBSTR!r}\n"
                f"Refusing to proceed; tempdir leaked."
            )

        # 5. Optionally pre-create a stub LLM profile so the binary
        #    can start without a real api_key. Calls to the LLM endpoint
        #    will fail at runtime (which is fine — they're not what
        #    functional tests assert on).
        if stub_llm_profile:
            _write_stub_llm_profile(temp_dir)

        # 6. Resolve the binary.
        bin_path = pabrik_bin if pabrik_bin is not None else _default_pabrik_bin()
        if not bin_path.exists():
            raise FunctionalHarnessError(f"pabrik binary not found: {bin_path}")
        if not os.access(bin_path, os.X_OK):
            raise FunctionalHarnessError(f"pabrik binary not executable: {bin_path}")

        # 7. Spawn. Cross-platform: on POSIX, start_new_session=True
        #    puts the child in its own process group (so killpg kills
        #    any subprocess the binary spawned). On Windows,
        #    start_new_session maps to CREATE_NEW_PROCESS_GROUP and
        #    killpg is unavailable — we use kill-by-pid instead.
        # Windows-only PARENT isolation: shadow HOME/USERPROFILE/APPDATA so
        # stray `~` expansions in test code hit temp_dir, not real home.
        # Linux/mac keep the original parent env per user request ("dont touch
        # linux and mac"). The CHILD env is isolated on every platform — see
        # the XDG block after this one.
        xdg_config = temp_dir / ".config"
        xdg_state = temp_dir / ".local" / "state"
        xdg_data = temp_dir / ".local" / "share"
        xdg_cache = temp_dir / ".cache"
        # Created on every platform, not just Windows: the child inherits these
        # paths from the env block below and the server expects the parent dir
        # to exist before it writes config.json / state / cache beneath it.
        xdg_config.mkdir(parents=True, exist_ok=True)
        xdg_state.mkdir(parents=True, exist_ok=True)
        xdg_data.mkdir(parents=True, exist_ok=True)
        xdg_cache.mkdir(parents=True, exist_ok=True)
        if os.name == "nt":
            os.environ["HOME"] = str(temp_dir)
            os.environ["USERPROFILE"] = str(temp_dir)
            os.environ["XDG_CONFIG_HOME"] = str(xdg_config)
            os.environ["XDG_STATE_HOME"] = str(xdg_state)
            os.environ["XDG_DATA_HOME"] = str(xdg_data)
            os.environ["XDG_CACHE_HOME"] = str(xdg_cache)
            appdata_roaming = temp_dir / "AppData" / "Roaming"
            appdata_local = temp_dir / "AppData" / "Local"
            appdata_roaming.mkdir(parents=True, exist_ok=True)
            appdata_local.mkdir(parents=True, exist_ok=True)
            os.environ["APPDATA"] = str(appdata_roaming)
            os.environ["LOCALAPPDATA"] = str(appdata_local)

        log_path = temp_dir / "pabrik.log"
        env = os.environ.copy()
        # Child env: HOME always isolated (existing Linux/mac behavior).
        env["HOME"] = str(temp_dir)
        # XDG isolation applies to the CHILD on EVERY platform, not just
        # Windows. On Linux `getDefaultConfigDir` (Config.zig) resolves
        # $XDG_CONFIG_HOME/pabrik BEFORE $HOME/.config/pabrik, and the same
        # XDG-first rule is duplicated for memories/, skills/ and hooks/.
        # A child that inherits XDG_CONFIG_HOME=/home/runner/.config (which
        # is exactly what the GitHub Actions ubuntu runner sets) writes
        # state into the runner's REAL home while every test reads
        # <temp_dir>/.config — so the assertions inspect a file the server
        # never touched, and all harness instances in the job share one
        # config.json, which makes results order-dependent.
        # Only `env` is shadowed here; os.environ is left alone on Linux/mac.
        env["XDG_CONFIG_HOME"] = str(xdg_config)
        env["XDG_STATE_HOME"] = str(xdg_state)
        env["XDG_DATA_HOME"] = str(xdg_data)
        env["XDG_CACHE_HOME"] = str(xdg_cache)
        if os.name == "nt":
            env["USERPROFILE"] = str(temp_dir)
            env["APPDATA"] = str(temp_dir / "AppData" / "Roaming")
            env["LOCALAPPDATA"] = str(temp_dir / "AppData" / "Local")
        log_file = log_path.open("wb")
        # `start_new_session=True` is a keyword arg accepted on
        # Python 3.2+ for both POSIX (setsid) and Windows
        # (CREATE_NEW_PROCESS_GROUP). Pass it unconditionally.
        proc = subprocess.Popen(
            [str(bin_path), "--port", str(chosen_port), *extra_args],
            stdout=log_file,
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,
        )
        # Parent can close its handle — child has duped it. On Windows, keeping
        # it open prevents shutil.rmtree (PermissionError: file in use).
        try:
            log_file.close()
        except Exception:
            pass

        # 7.5. Record pids so a subsequent boot can reap us if we die.
        #      The pidfile format is "<harness_pid> <pabrik_pid>\n":
        #        - harness_pid: the Python process running this code
        #          (pytest worker, or the bare pytest process without xdist).
        #          When reap sees this pid is dead, the tempdir is an orphan.
        #        - pabrik_pid: the actual pabrik binary holding the TCP port.
        #          When reap sees the harness is dead, it kills this pid.
        #      Wrapped in try/except because a write failure here must NOT
        #      prevent tests from running — the worst case is "this test
        #      won't be reaped on the next boot" which is the pre-patch
        #      behaviour anyway.
        try:
            (temp_dir / ".harness.pid").write_text(f"{os.getpid()} {proc.pid}\n")
        except OSError as e:
            print(f"warning: failed to write pidfile: {e}", file=sys.stderr)

        # 8. Wait for readiness.
        try:
            _wait_ready(chosen_port, ready_timeout_s, proc, log_path)
        except Exception:
            with contextlib.suppress(ProcessLookupError):
                proc.kill()
            with contextlib.suppress(Exception):
                log_file.close()
            raise

        return cls(
            port=chosen_port,
            pabrik_bin=bin_path,
            temp_dir=temp_dir,
            orig_home=orig_home,
            log_path=log_path,
            pid=proc.pid,
            proc=proc,
            dry_run=os.environ.get("PABRIK_FUNCTIONAL_DRY_RUN") == "1",
            orig_userprofile=orig_userprofile,
            orig_appdata=orig_appdata,
            orig_localappdata=orig_localappdata,
            orig_xdg_config_home=orig_xdg_config_home,
            orig_xdg_state_home=orig_xdg_state_home,
            orig_xdg_data_home=orig_xdg_data_home,
            orig_xdg_cache_home=orig_xdg_cache_home,
        )

    # ---- HTTP client ------------------------------------------------------

    def http(
        self,
        method: str,
        path: str,
        *,
        json_body: dict | list | None = None,
        params: dict[str, Any] | None = None,
        expect: int | tuple[int, ...] = 200,
        timeout_s: float = 5.0,
    ) -> Response:
        """Issue an HTTP request to the harness's pabrik instance.

        Args:
            method: HTTP verb (GET, POST, PUT, PATCH, DELETE).
            path: URL path beginning with ``/`` (e.g. ``/api/workspaces``).
            json_body: Optional JSON-serializable body. Sets
                ``Content-Type: application/json``.
            params: Optional URL query parameters.
            expect: Status code or tuple of acceptable codes. Default 200.
                On mismatch, raises AssertionError with the body excerpt.
            timeout_s: Per-request timeout.

        Returns:
            Response with status, body, and headers.

        Raises:
            AssertionError: if the response status is not in ``expect``.
        """
        url = f"http://127.0.0.1:{self.port}{path}"
        if params:
            url += "?" + urllib.parse.urlencode(params)
        data: bytes | None = None
        headers: dict[str, str] = {}
        if json_body is not None:
            data = json.dumps(json_body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout_s) as resp:
                status = resp.status
                body = resp.read()
                resp_headers = {k: v for k, v in resp.headers.items()}
        except urllib.error.HTTPError as e:
            status = e.code
            body = e.read()
            resp_headers = {k: v for k, v in (e.headers.items() if e.headers else [])}

        r = Response(status=status, body=body, headers=resp_headers)
        expected = (expect,) if isinstance(expect, int) else expect
        if status not in expected:
            excerpt = body[:500].decode("utf-8", errors="replace")
            raise AssertionError(
                f"{method} {path}: expected {expected}, got {status}\n"
                f"body: {excerpt}"
            )
        return r

    # ---- lifecycle helpers ------------------------------------------------

    def health(self) -> bool:
        """Return True iff /health returns 200 with status==ok."""
        try:
            r = self.http("GET", "/health", expect=200)
            return r.json().get("status") == "ok"
        except Exception:
            return False

    def tail_log(self, n: int = 50) -> str:
        """Return the last n lines of the pabrik log (useful on failure)."""
        try:
            with self.log_path.open("rb") as f:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                # Read up to ~64 KB from the end.
                f.seek(max(0, size - 65536))
                data = f.read().decode("utf-8", errors="replace")
            return "\n".join(data.splitlines()[-n:])
        except FileNotFoundError:
            return ""

    # ---- teardown ---------------------------------------------------------

    def teardown(self) -> None:
        """Stop the pabrik binary and rmtree the isolated tempdir.

        Order matters:
          1. Restore HOME (so any post-test code sees the original env).
          2. Stop the binary (SIGTERM, then SIGKILL fallback).
          3. Validate the tempdir with is_safe_tmp(); raise if it
             fails. The tempdir is leaked in that case — the correct
             trade-off vs. deleting the wrong tree.
          4. rmtree the validated tempdir (or skip if dry_run).

        Idempotent: safe to call twice.
        """
        # 1. Restore HOME first (so any post-test code sees original env).
        # HOME is restored on all platforms (Linux/mac keep parent HOME
        # isolated only via child env, but teardown still ensures original
        # is back). XDG and Windows vars are restored only on Windows per
        # user request to not touch Linux/mac.
        os.environ["HOME"] = self.orig_home
        if os.name == "nt":
            for key, orig in (
                ("XDG_CONFIG_HOME", self.orig_xdg_config_home),
                ("XDG_STATE_HOME", self.orig_xdg_state_home),
                ("XDG_DATA_HOME", self.orig_xdg_data_home),
                ("XDG_CACHE_HOME", self.orig_xdg_cache_home),
            ):
                if orig:
                    os.environ[key] = orig
                else:
                    os.environ.pop(key, None)
            if self.orig_userprofile:
                os.environ["USERPROFILE"] = self.orig_userprofile
            else:
                os.environ.pop("USERPROFILE", None)
            if self.orig_appdata:
                os.environ["APPDATA"] = self.orig_appdata
            else:
                os.environ.pop("APPDATA", None)
            if self.orig_localappdata:
                os.environ["LOCALAPPDATA"] = self.orig_localappdata
            else:
                os.environ.pop("LOCALAPPDATA", None)

        # 2. Stop the binary.
        if self.pid is not None and not self._stopped:
            self._stopped = True
            self._stop_binary()

        # 3. Validate. THIS IS THE SAFETY NET.
        if not is_safe_tmp(str(self.temp_dir), self.orig_home):
            raise FunctionalHarnessError(
                f"REFUSING to rmtree unsafe path: {self.temp_dir}\n"
                f"This is a bug in the harness; the tempdir did not\n"
                f"pass is_safe_tmp() validation. Manual cleanup required.\n"
                f"  orig_home = {self.orig_home}\n"
                f"  temp_dir  = {self.temp_dir}\n"
                f"  realpath  = {os.path.realpath(str(self.temp_dir))}"
            )

        # 3.5. Remove the pidfile BEFORE rmtree so the next boot doesn't
        #      see this entry. Idempotent under dry_run (which skips
        #      rmtree below) — without this, dry_run would leave a
        #      pidfile pointing at a now-dead harness python, causing
        #      the next boot to mistakenly treat this tempdir as an
        #      orphan and try to reap its already-dead pabrik.
        pidfile = self.temp_dir / ".harness.pid"
        try:
            pidfile.unlink()
        except FileNotFoundError:
            pass
        except OSError as e:
            print(f"warning: failed to remove pidfile: {e}", file=sys.stderr)

        # 4. rmtree the validated tempdir.
        if self.dry_run:
            print(f"[dry-run] would rmtree: {self.temp_dir}")
        else:
            # The child tree is already dead, but "dead" is not "finished
            # writing": a shell pabrik spawned (the PTY a terminal test
            # drives) can still be flushing its last writes into the temp
            # HOME, and POSIX rmtree surfaces that as ENOTEMPTY — a
            # directory that got a new entry between the scan and the
            # delete. Windows hits the same race with PermissionError.
            # Both platforms therefore retry with the same backoff; the
            # Windows-only branch used to `raise` on the first POSIX
            # failure, so the loop below was dead code off Windows and
            # the tempdir leaked into /tmp with the test reported red.
            # The final `raise last_exc` still surfaces a tree that never
            # became removable.
            last_exc = None
            retries = 10 if os.name == "nt" else 5
            for _ in range(retries):
                try:
                    shutil.rmtree(self.temp_dir)
                    last_exc = None
                    break
                except OSError as e:
                    last_exc = e
                    time.sleep(1.0)
            if last_exc is not None:
                raise last_exc

    # ---- context-manager sugar -------------------------------------------

    def __enter__(self) -> "FunctionalHarness":
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self.teardown()

    # ---- private helpers --------------------------------------------------

    def _stop_binary(self) -> None:
        """SIGTERM the process group, fall back to SIGKILL after 1s.

        All kill operations swallow OSError (covers ProcessLookupError,
        PermissionError, and ESRCH) — the process can die between any
        of these calls, and the OS may not let us signal a pgid that's
        been recycled. Either way, our job is done.

        Cross-platform notes:
          - POSIX: subprocess.Popen(..., start_new_session=True) puts
            the child in its own process group; os.killpg() signals
            the whole group (defends against children that ignore
            SIGTERM).
          - Windows: there are no process groups. start_new_session
            maps to CREATE_NEW_PROCESS_GROUP, and TerminateProcess is
            the only way to kill a child we don't own. We skip the
            pgid dance and kill by pid directly.

        Teardown budget (was 10s, now 3s) — the slim budget is
        safe because ``/test/shutdown`` exits the process within
        ~50ms in the common case. The SIGTERM/SIGKILL steps are the
        safety net for the rare case where ShutdownTheader blocks
        (e.g. a future regression that re-introduces a long-running
        blocking call in the shutdown handler).
        """
        assert self.pid is not None
        # Use /test/shutdown for graceful exit; tolerate any failure.
        try:
            with urllib.request.urlopen(
                f"http://127.0.0.1:{self.port}/test/shutdown",
                data=b"",
                timeout=2.0,
            ) as resp:
                resp.read()
        except Exception:
            pass
        if self._wait_dead(1.0, "post-shutdown"):
            return
        # Fall back to SIGTERM the whole group.
        self._signal_group(signal.SIGTERM)
        if self._wait_dead(1.0, "post-sigterm"):
            return
        # Last resort — SIGKILL (SIGTERM on Windows, which lacks SIGKILL).
        self._signal_group(_SIGKILL)
        self._wait_dead(1.0, "post-sigkill")  # best-effort final wait

    def _wait_dead(self, timeout: float, label: str = "wait") -> bool:
        """Return True iff the process exited within ``timeout`` seconds.

        Uses ``os.waitpid(pid, WNOHANG)`` to detect exit. WNOHANG is
        the correct call here — ``os.kill(pid, 0)`` returns 0 for
        zombie processes (the process is dead but the parent hasn't
        reaped it), so it would falsely report "alive" for a zombie
        and stall the harness for the full SIGTERM/SIGKILL budget.

        ``waitpid(WNOHANG)`` returns:
          - ``(0, 0)``            — process is still running, no zombie
          - ``(pid, status)``     — child has exited and we JUST reaped it
          - raises ``OSError`` (ECHILD) — child doesn't exist (no zombie either)

        ``Popen.poll()`` is preferred and is the only branch that cannot
        block: it is ``WaitForSingleObject(handle, 0)`` on Windows and
        ``waitpid(WNOHANG)`` on POSIX, and it reaps the child on both.
        Windows DOES have ``os.waitpid`` but does NOT have ``os.WNOHANG``,
        so the old ``wnohang = 0`` fallback turned this loop into a
        blocking wait — which hung the entire test process in
        ``_stop_binary``'s first ``_wait_dead`` whenever the child did not
        exit on the graceful path. The remaining branches are kept for a
        harness with no ``proc`` (``waitpid`` only where WNOHANG exists,
        otherwise a ``kill(pid, 0)`` probe).
        """
        assert self.pid is not None
        has_waitpid = hasattr(os, "waitpid")
        # `os.WNOHANG` does NOT exist on Windows, and the old fallback of
        # `wnohang = 0` ("blocking, but the loop deadline caps it") is
        # WRONG: the deadline is only checked BEFORE the call, so a
        # blocking `os.waitpid(pid, 0)` on a child that never exits hangs
        # the whole test process inside `_stop_binary`'s FIRST
        # `_wait_dead`, and the SIGTERM/SIGKILL fallbacks below it are
        # never reached. Treat "no WNOHANG" as "waitpid cannot poll here".
        has_waitpid = hasattr(os, "waitpid") and hasattr(os, "WNOHANG")
        wnohang = os.WNOHANG if has_waitpid else 0
        t0 = time.monotonic()
        deadline = time.monotonic() + timeout
        polls = 0
        while time.monotonic() < deadline:
            polls += 1
            # `Popen.poll()` FIRST — the only probe here that is
            # non-blocking on every platform (WaitForSingleObject(0) on
            # Windows, waitpid(WNOHANG) on POSIX) and the only one that
            # cannot hang the caller, because it also reaps the child.
            # `self.proc` is the Popen `boot()` spawned.
            if self.proc is not None:
                if self.proc.poll() is not None:
                    return True
            elif has_waitpid:
                try:
                    wpid, _status = os.waitpid(self.pid, wnohang)
                except ChildProcessError:
                    # ECHILD — no such process (already reaped and gone)
                    return True
                except OSError:
                    # Some other error — treat as alive and retry
                    pass
                else:
                    if wpid == self.pid:
                        # We just reaped the zombie — process is really dead
                        return True
                    # wpid == 0 means still running, no zombie yet
            else:
                # Windows / fallback: kill(pid, 0) returns 0 if alive
                # (including zombie — but Windows doesn't have those)
                try:
                    os.kill(self.pid, 0)
                except OSError:
                    return True
            time.sleep(0.05)
        return False

    def _signal_group(self, sig: int) -> None:
        """Signal the process group on POSIX, or the pid on Windows.

        OSError is swallowed throughout — the process can die between
        our queries, the OS may have recycled the pgid, or we may not
        own the pid. None of those are the harness's concerns; we
        made a best-effort attempt.
        """
        assert self.pid is not None
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
            # Windows: no killpg. Best effort — SIGTERM (which
            # Python maps to TerminateProcess for the child).
            try:
                os.kill(self.pid, sig)
            except OSError:
                pass


# ============================================================================
# Internal helpers
# ============================================================================


def _find_free_port(start: int | None = None) -> int:
    """Find a free port for the pabrik backend.

    Default behaviour (no ``start``): pick a random port from the wide
    range ``[RANDOM_PORT_START, RANDOM_PORT_END]`` (20k-32k, clear of
    the kernel's ephemeral pool). Random
    selection avoids the two pathologies the previous sequential scan
    suffered in CI:

      1. **Sequential consumption** — every test boot increments the
         port number, so a long suite fills the 8080..8199 window and
         later tests fail with "No free port found".
      2. **TIME_WAIT saturation** — even with ``SO_REUSEADDR``, a CI
         runner holding 100+ ports in TIME_WAIT could collide with the
         narrow 120-port scan window.

    Random selection from 20,000 ports with 50 attempts is collision-
    proof for any realistic host occupancy (see ``RANDOM_PORT_ATTEMPTS``
    comment).

    With an explicit ``start`` (used by the orphan-reap TIME_WAIT
    regression test): falls back to the legacy sequential scan from
    ``start`` to ``PORT_SCAN_END``. This keeps the historical test
    contract intact while production boots use the new random path.

    Args:
        start: If given, scan sequentially from this port to
            ``PORT_SCAN_END`` (legacy behaviour). If ``None``, pick
            a random port from the wide range.

    Returns:
        A free port number (never 8081).

    Raises:
        FunctionalHarnessError: If no free port can be found within
            the configured budget.
    """
    if start is not None:
        return _find_free_port_sequential(start)
    return find_free_port_random()


def _find_free_port_sequential(start: int) -> int:
    """Sequential port scan from ``start`` to ``PORT_SCAN_END``. Legacy.

    Kept as the explicit-call path used by
    ``harness_orphan_reap_test.py::test_find_free_port_picks_time_wait_port``
    which depends on the deterministic "first free port = target_port"
    behaviour. Production boot uses ``_find_free_port()`` with no args
    which delegates to ``find_free_port_random()``.

    Uses ``SO_REUSEADDR`` so the scan can pick ports in TIME_WAIT state.
    After the harness closes its probe socket, pabrik (which also sets
    ``SO_REUSEADDR`` on its listener — see
    ``kabelweb repo src/server/http_server.zig:201 setReuseAddr``)
    can bind the same port despite lingering server-side TIME_WAITs from
    previous test runs. Without ``SO_REUSEADDR``, rapid test runs would
    saturate the 120-port scan window with TIME_WAIT entries and every
    subsequent test would error with ``No free port found in
    8080..8199 (excluding 8081)`` until the TIME_WAITs expire (~60s).
    """
    if start == 8081:
        start = 8082
    for port in range(start, PORT_SCAN_END + 1):
        if port == 8081:
            continue
        if port_is_free_with_reuse(port):
            return port
    raise FunctionalHarnessError(
        f"No free port found in {start}..{PORT_SCAN_END} (excluding 8081)"
    )


def port_is_free_with_reuse(port: int) -> bool:
    """Return True iff ``port`` can be bound on 127.0.0.1 with SO_REUSEADDR.

    Used as the atomic-free primitive by both the random picker and
    the sequential scan. SO_REUSEADDR lets the probe bind TIME_WAIT
    ports; the subsequent pabrik/vite listener sets the same flag so
    it can also bind the port despite lingering server-side TIME_WAITs.

    Public so the ``UIHarness`` can share it without duplicating the
    SO_REUSEADDR + bind() dance.
    """
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False


def find_free_port_random(
    *,
    reserved: tuple[int, ...] = RESERVED_PORTS,
    attempts: int = RANDOM_PORT_ATTEMPTS,
    range_start: int = RANDOM_PORT_START,
    range_end: int = RANDOM_PORT_END,
) -> int:
    """Pick a random free port from a wide range, avoiding reserved ports.

    Used by both ``FunctionalHarness.boot()`` (no args — default
    reserved = (8081,)) and ``UIHarness`` (passes
    ``reserved=(5173, 8081)`` to also skip Vite's default port and
    the dev backend port).

    Strategy: ``attempts`` independent random picks within
    ``[range_start, range_end]``; the first one that binds without
    error and isn't in ``reserved`` wins. Raises
    ``FunctionalHarnessError`` if all attempts fail.

    Args:
        reserved: Ports the picker MUST skip even if bind() succeeds.
            Default: ``(8081,)`` — the always-running dev backend.
        attempts: Number of random picks before giving up. Default 50.
        range_start: Inclusive low end of the random range. Default 40000.
        range_end: Inclusive high end of the random range. Default 60000.

    Returns:
        A free port in ``[range_start, range_end]`` not in ``reserved``.

    Raises:
        FunctionalHarnessError: If no free port is found within
            ``attempts`` picks. Practically unreachable on any sane host
            (see ``RANDOM_PORT_ATTEMPTS`` docstring).
    """
    if range_end < range_start:
        raise ValueError(
            f"range_end ({range_end}) must be >= range_start ({range_start})"
        )
    if attempts <= 0:
        raise ValueError(f"attempts must be > 0, got {attempts}")
    range_size = range_end - range_start + 1
    for _ in range(attempts):
        port = range_start + random.randint(0, range_size - 1)
        if port in reserved:
            continue
        if port_is_free_with_reuse(port):
            return port
    raise FunctionalHarnessError(
        f"No free port found after {attempts} random picks in "
        f"[{range_start}, {range_end}] (excluding reserved={reserved}). "
        f"This host's port occupancy is pathological; widen the random "
        f"range via find_free_port_random(range_start=, range_end=) "
        f"or check `ss -tlnp | wc -l` for runaway listeners."
    )


def _wait_pid_dead(pid: int, timeout: float) -> bool:
    """Return True iff ``pid`` exited within ``timeout`` seconds.

    Uses ``os.kill(pid, 0)`` as a liveness probe. Cross-platform:
    POSIX and Windows both support the probe. ESRCH ⇒ dead; EPERM ⇒
    alive-but-not-ours (treated as "dead for our purposes" because we
    can't signal it anyway).

    Windows note: ``os.kill(dead_pid, 0)`` raises plain ``OSError``
    (``[WinError 87] The parameter is incorrect``), NOT
    ``ProcessLookupError`` — so the except clause must be broad
    ``OSError`` (narrow ``(ProcessLookupError, PermissionError)``
    lets 87 escape, aborting the orphan-reap loop mid-scan and
    leaking every tempdir after the first dead pid).

    For subprocess children specifically, prefer ``os.waitpid(WNOHANG)``
    which also reaps zombies — see ``_stop_binary`` for the richer case.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except OSError:
            # ProcessLookupError / PermissionError on POSIX;
            # [WinError 87] on Windows for a dead pid. Either way
            # the pid is gone (or not ours) — dead for our purposes.
            return True
        time.sleep(0.05)
    return False


def _reap_orphan_test_pids() -> int:
    """Kill orphaned pabrik children from prior aborted runs. Idempotent.

    On every harness boot, scan ``<tempfile.gettempdir()>/pabrik-func-*/
    .harness.pid``. Each pidfile contains ``"<harness_worker_pid>
    <pabrik_child_pid>\n"`` — written by ``boot()``. If the harness python
    parent died (``kill -0`` returns ``ProcessLookupError``), the tempdir
    is an orphan: the pabrik child survived in its own pgid
    (``subprocess.Popen(start_new_session=True)``) and is still holding
    its TCP port. Kill the pabrik child, then ``rmtree`` the tempdir via
    the existing ``is_safe_tmp()`` validator.

    Returns the number of orphans reaped. Failures are logged to stderr
    but never raised — a reap failure must NOT prevent the test from
    booting (the alternative — aborting because we couldn't clean up —
    is strictly worse than booting with a slightly-leakier state).

    Cross-platform: ``tempfile.gettempdir()`` (NOT hardcoded ``/tmp/``),
    ``os.kill`` for liveness + signals, ``signal.SIGTERM``/``SIGKILL``
    which both work on POSIX and Windows.
    """
    reaped = 0
    base = Path(tempfile.gettempdir())
    if not base.is_dir():
        return 0
    try:
        candidates = list(base.iterdir())
    except OSError as e:
        print(f"warning: orphan reap scan failed: {e}", file=sys.stderr)
        return 0
    for entry in candidates:
        if not entry.is_dir() or not entry.name.startswith("pabrik-func-"):
            continue
        pidfile = entry / ".harness.pid"
        if not pidfile.is_file():
            continue
        # Parse "<harness_pid> <pabrik_pid>". Anything else → skip silently.
        try:
            tokens = pidfile.read_text().split()
            if len(tokens) != 2:
                continue
            harness_pid = int(tokens[0])
            pabrik_pid = int(tokens[1])
        except (OSError, ValueError):
            continue
        # If the harness python is alive, this test is still in progress —
        # another worker scanning concurrently must NOT kill it.
        # NOTE: broad OSError (not just ProcessLookupError): on
        # Windows a dead pid raises [WinError 87], which must count
        # as "harness dead" or the whole reap loop aborts on the
        # first orphan (leaking every tempdir after it). The outer
        # `except Exception` is the backstop for non-OSError probe
        # failures (e.g. CPython's SystemError when a recycled pid
        # lands on a protected system process): one bad entry must
        # never abort the scan — skip it and reap the rest.
        try:
            try:
                os.kill(harness_pid, 0)
            except OSError:
                pass  # harness is dead — this dir is an orphan
            else:
                continue
            # Harness is dead. Kill the pabrik child if alive.
            if pabrik_pid and pabrik_pid != os.getpid():
                try:
                    os.kill(pabrik_pid, signal.SIGTERM)
                except OSError:
                    pass
                # Wait up to 1s for graceful exit; SIGKILL fallback
                # (SIGTERM on Windows, which lacks SIGKILL).
                if not _wait_pid_dead(pabrik_pid, 1.0):
                    try:
                        os.kill(pabrik_pid, _SIGKILL)
                    except OSError:
                        pass
        except Exception as e:
            print(
                f"warning: orphan reap skipped {entry.name}: {e}",
                file=sys.stderr,
            )
            continue
        # rmtree via the safety validator (same gate as teardown).
        # is_safe_tmp checks (1) prefix allow-list, (2) REQUIRED_TMP_SUBSTR
        # substring, (3) not the real HOME. For an orphan we don't know
        # the original HOME, so pass an empty string — that disables the
        # "matches HOME" check but still validates prefix + substring.
        if is_safe_tmp(str(entry), ""):
            try:
                shutil.rmtree(entry)
                reaped += 1
            except OSError:
                # Race with another worker reaping the same dir, or
                # permission error — either way, our job is done.
                pass
    return reaped


def _default_pabrik_bin() -> Path:
    """Resolve the pabrik binary. Checks env var, then known zig-out paths."""
    candidates: list[Path] = []
    env_bin = os.environ.get("PABRIK_BIN")
    if env_bin:
        candidates.append(Path(env_bin))
    candidates.extend([
        Path("./zig-out/bin/pabrik"),
        Path("./zig-out/bin/pabrik.exe"),
        Path("./zig-out/bin/pabrikcore-linux-x86_64"),
        Path("./zig-out/bin/pabrikcore-macos-aarch64"),
        Path("./zig-out/bin/pabrikcore-macos-x86_64"),
        Path("./zig-out/bin/pabrikcore-windows-x86_64"),
        Path("./zig-out/bin/pabrikcore-windows-x86_64.exe"),
    ])
    for c in candidates:
        if c.exists():
            return c.resolve()
    raise FunctionalHarnessError(
        "No pabrik binary found. Set PABRIK_BIN or run "
        "`zig build install:linux:system` first."
    )


def mcp_hello_world_bin() -> Path:
    """Resolve the mcp-hello-world test MCP server binary.

    Built by `zig build mcp-hello-world`. Same sibling-binary
    resolution as the pabrik binary: the wrapper lives at
    zig-out/bin/mcp-hello-world next to pabrikcore-*.

    Resolution order:
      1. ``$MCP_HELLO_WORLD_BIN`` env var
      2. ``./zig-out/bin/mcp-hello-world`` (sibling of pabrik binary)
      3. ``./zig-out/bin/mcp-hello-world-linux-x86_64`` (cross-target)

    Raises FunctionalHarnessError if no binary is found.
    """
    candidates: list[Path] = []
    env_bin = os.environ.get("MCP_HELLO_WORLD_BIN")
    if env_bin:
        candidates.append(Path(env_bin))
    candidates.extend([
        Path("./zig-out/bin/mcp-hello-world"),
        Path("./zig-out/bin/mcp-hello-world-linux-x86_64"),
    ])
    for c in candidates:
        if c.exists() and os.access(c, os.X_OK):
            return c.resolve()
    raise FunctionalHarnessError(
        "mcp-hello-world binary not found; set MCP_HELLO_WORLD_BIN or run "
        "`zig build mcp-hello-world` first."
    )


def mcp_http_hello_world_bin() -> Path:
    """Resolve the mcp-http-hello-world test MCP server binary.

    Sibling of mcp_hello_world_bin() (the stdio binary). Built by
    `zig build mcp-http-hello-world`. Same sibling-binary resolution
    pattern — the wrapper lives at zig-out/bin/mcp-http-hello-world
    next to mcp-hello-world-* and pabrikcore-*.

    Per the project convention "one binary per transport" (the HTTP
    transport is NOT a `--http` flag on the stdio binary; it's a
    separate sibling), this is a distinct binary with its own
    install step.

    Resolution order:
      1. ``$MCP_HTTP_HELLO_WORLD_BIN`` env var
      2. ``./zig-out/bin/mcp-http-hello-world`` (sibling of pabrik binary)
      3. ``./zig-out/bin/mcp-http-hello-world-linux-x86_64`` (cross-target)

    Raises FunctionalHarnessError if no binary is found.
    """
    candidates: list[Path] = []
    env_bin = os.environ.get("MCP_HTTP_HELLO_WORLD_BIN")
    if env_bin:
        candidates.append(Path(env_bin))
    candidates.extend([
        Path("./zig-out/bin/mcp-http-hello-world"),
        Path("./zig-out/bin/mcp-http-hello-world-linux-x86_64"),
    ])
    for c in candidates:
        if c.exists() and os.access(c, os.X_OK):
            return c.resolve()
    raise FunctionalHarnessError(
        "mcp-http-hello-world binary not found; set MCP_HTTP_HELLO_WORLD_BIN "
        "or run `zig build mcp-http-hello-world` first."
    )


def _wait_ready(
    port: int, timeout_s: float, proc: subprocess.Popen[bytes], log_path: Path
) -> None:
    """Poll /health every 100ms until 'ok' or timeout.

    Raises FunctionalHarnessError with the log tail on failure.
    """
    deadline = time.monotonic() + timeout_s
    url = f"http://127.0.0.1:{port}/health"
    last_err: str = ""
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            log = log_path.read_text(errors="replace") if log_path.exists() else ""
            raise FunctionalHarnessError(
                f"pabrik exited rc={proc.returncode} during boot\n"
                f"--- last 30 lines of log ---\n"
                + "\n".join(log.splitlines()[-30:])
            )
        try:
            with urllib.request.urlopen(url, timeout=1.0) as resp:
                body = json.loads(resp.read())
                if body.get("status") == "ok":
                    return
        except Exception as e:
            # Catch-all during readiness polling (not just URLError /
            # ConnectionError / OSError). A half-open listener can reply
            # with a malformed status line (http.client.BadStatusLine,
            # an HTTPException, not a URLError) when a prior test's pabrik
            # is still shutting down on a recycled port, or when the
            # server is mid-boot. Any such transient must be retried,
            # not propagated as a fixture ERROR (observed on CI Linux as
            # `ERROR design_lifecycle_test.py::test_element_html_file_written_to_disk
            # - http.client.BadStatusLine: GET /health HTTP/1.1`).
            last_err = f"{type(e).__name__}: {e}"
        time.sleep(0.1)
    log = log_path.read_text(errors="replace") if log_path.exists() else ""
    raise FunctionalHarnessError(
        f"pabrik did not become ready in {timeout_s}s (last_err={last_err})\n"
        f"--- last 30 lines of log ---\n"
        + "\n".join(log.splitlines()[-30:])
    )


def _write_stub_llm_profile(temp_dir: Path) -> None:
    """Pre-create a stub LLM profile at the platform-correct path.

    Linux:   $HOME/.config/pabrik/config.json (or $XDG_CONFIG_HOME)
    macOS:   $HOME/Library/Application Support/pabrik/config.json
    Windows: %APPDATA%/pabrik/config.json ($HOME/.config is also written
             as a fallback so the same helper works cross-platform).

    The base_url points to a port that never responds, so session-create
    will fail at runtime when it tries to call the LLM — which is fine,
    since the functional tests assert on the wire, not on LLM responses.

    Writes to all three locations so the harness works regardless of
    which platform's `getDefaultConfigDir` the pabrik binary uses.
    """
    profile = {
        "profiles_models": {
            "stub": {
                "model": "stub-model",
                "base_url": "http://127.0.0.1:1",
                "api_key": "stub-key-not-real",
            }
        },
        "selected_profile_model": "stub",
    }
    payload = json.dumps(profile, indent=2)
    for config_dir in (
        temp_dir / ".config" / "pabrik",
        temp_dir / "AppData" / "Roaming" / "pabrik",
        temp_dir / "Library" / "Application Support" / "pabrik",
    ):
        config_dir.mkdir(parents=True, exist_ok=True)
        (config_dir / "config.json").write_text(payload)


# ============================================================================
# Convenience for scripts that don't want pytest fixtures
# ============================================================================


def run_quick(
    pabrik_bin: Path | None = None,
    *,
    port: int = DEFAULT_PORT,
    stub_llm_profile: bool = False,
) -> Iterator[FunctionalHarness]:
    """Context manager for use outside pytest.

    Example:
        with run_quick() as h:
            r = h.http("GET", "/health")
            print(r.json())
    """
    h = FunctionalHarness.boot(
        pabrik_bin, port=port, stub_llm_profile=stub_llm_profile
    )
    try:
        yield h
    finally:
        h.teardown()


__all__ = [
    "ALLOWED_TMP_PREFIXES",
    "DEFAULT_PORT",
    "FunctionalHarness",
    "FunctionalHarnessError",
    "PORT_SCAN_END",
    "RANDOM_PORT_ATTEMPTS",
    "RANDOM_PORT_END",
    "RANDOM_PORT_START",
    "REQUIRED_TMP_SUBSTR",
    "RESERVED_PORTS",
    "Response",
    "find_free_port_random",
    "is_safe_tmp",
    "port_is_free_with_reuse",
    "run_quick",
]
