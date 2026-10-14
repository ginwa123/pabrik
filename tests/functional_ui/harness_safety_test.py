"""Safety tests for the UIHarness.

These tests run WITHOUT a pabrik binary or a Vite dev server. They
assert the safety invariants in ``ui_harness.py`` — the guards that
prevent the harness from ever deleting the developer's real $HOME,
on macOS, Linux, AND Windows.

If any of these tests fail, the harness has a P0 bug. Do not merge
until they pass.

The tests are deliberately cross-platform: they use ``os.path.normpath``
to construct the expected paths, so the same test passes on every OS.
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

import pytest

from harness import (
    ALLOWED_TMP_PREFIXES,
    REQUIRED_TMP_SUBSTR,
    is_safe_tmp,
)


# ─── Cross-platform is_safe_tmp coverage ─────────────────────────────────────


def test_is_safe_tmp_accepts_fresh_mkdtemp_on_this_os() -> None:
    """A fresh mkdtemp on the current OS is always safe.

    This is the regression test for the Windows bug: before the
    2026-08-21 fix, ``ALLOWED_TMP_PREFIXES`` was hardcoded to POSIX
    paths plus ``tempfile.gettempdir() + "/"`` — which on Windows
    produced a mixed-separator prefix (e.g. ``C:\\Users\\u\\AppData\\Local\\Temp/``)
    that never matched ``realpath``'s backslash output. The fix is
    OS-aware: on Windows the prefix is normalised to native backslashes.
    """
    with tempfile.TemporaryDirectory(prefix=REQUIRED_TMP_SUBSTR) as td:
        # The harness's own validation must accept the OS's native
        # tempdir location. ``orig_home`` is a non-existent path that
        # won't accidentally match ``realpath``.
        assert is_safe_tmp(td, "/this/home/does/not/exist") is True, (
            f"is_safe_tmp rejected a freshly-created tempdir on {sys.platform}. "
            f"This is a Windows path-separator regression — see harness.py "
            f"ALLOWED_TMP_PREFIXES for the OS-aware fix."
        )


def test_is_safe_tmp_accepts_pathlib_path_on_this_os() -> None:
    """PathLike inputs work on the current OS (regression for Windows)."""
    with tempfile.TemporaryDirectory(prefix=REQUIRED_TMP_SUBSTR) as td:
        p = Path(td)
        assert is_safe_tmp(p, "/home/nonexistent") is True


def test_is_safe_tmp_rejects_paths_outside_tempdir() -> None:
    """Paths outside any allowed tmpdir prefix are always rejected."""
    # Use a path that exists but is NOT under any tempdir.
    # /etc/passwd is a standard POSIX path that exists on Linux/macOS.
    # On Windows, fall back to a path that definitely doesn't qualify.
    if sys.platform == "win32":
        bogus = "C:\\Windows\\System32\\drivers\\etc\\hosts"
    else:
        bogus = "/etc/passwd"
    if os.path.exists(bogus):
        assert is_safe_tmp(bogus, "/home/nonexistent") is False


def test_is_safe_tmp_rejects_real_home() -> None:
    """The real $HOME is never safe, even with the required substring."""
    real_home = os.path.expanduser("~")
    assert is_safe_tmp(real_home, real_home) is False, (
        f"is_safe_tmp accepted the real $HOME ({real_home}) — this is a P0 bug"
    )


def test_is_safe_tmp_rejects_relative_path() -> None:
    """Relative paths are never safe (could resolve anywhere)."""
    assert is_safe_tmp(f"./{REQUIRED_TMP_SUBSTR}xyz", "/home/x") is False
    assert is_safe_tmp(REQUIRED_TMP_SUBSTR + "xyz", "/home/x") is False


def test_is_safe_tmp_rejects_empty_path() -> None:
    """Empty path is never safe."""
    assert is_safe_tmp("", "/home/x") is False
    assert is_safe_tmp("", "") is False


# ─── ALLOWED_TMP_PREFIXES cross-platform sanity ──────────────────────────────


def test_allowed_tmp_prefixes_match_realpath_on_this_os() -> None:
    """The allowed prefixes must cover ``realpath`` output on the current OS.

    On macOS: prefixes are like ``/tmp/`` and ``/var/folders/``.
    On Linux: prefixes are like ``/tmp/``.
    On Windows: prefixes are like ``C:\\Users\\u\\AppData\\Local\\Temp\\``.

    Both sides are compared in the harness's canonical form
    (``harness._canonical`` = ``normcase(realpath(...))``), because the RAW
    strings legitimately disagree on Windows — and a raw ``startswith`` is
    not a weaker version of this assertion, it is a different and false
    one. A ``windows-2022`` runner's ``%TEMP%`` is the 8.3 SHORT form
    (``C:\\Users\\RUNNER~1\\AppData\\Local\\Temp``), which is what
    ``tempfile.gettempdir()`` — and so ``ALLOWED_TMP_PREFIXES`` — returns
    verbatim, while ``os.path.realpath`` of a directory under it comes back
    LONG (``C:\\Users\\runneradmin\\...``). So
    ``realpath(td).startswith(prefix)`` was False on every Windows run even
    though the harness deletes the tempdir correctly: ``is_safe_tmp``
    canonicalises BOTH sides before comparing. ``_canonical``'s docstring
    records the 548 windows-2022 test errors that shape already cost.
    """
    from harness import _canonical

    with tempfile.TemporaryDirectory(prefix=REQUIRED_TMP_SUBSTR) as td:
        real = _canonical(td)
        matched = any(
            real.startswith(_canonical(prefix)) for prefix in ALLOWED_TMP_PREFIXES
        )
        assert matched, (
            f"canonical(realpath({td!r})) = {real!r} did not match any "
            f"canonicalised entry of ALLOWED_TMP_PREFIXES = "
            f"{ALLOWED_TMP_PREFIXES!r} on {sys.platform}.\n"
            f"This means the harness would leak the tempdir on "
            f"teardown instead of cleaning it up."
        )


def test_is_safe_tmp_canonicalises_the_allow_list_entry(monkeypatch) -> None:
    """An allow-list entry is compared in its canonical form, not raw.

    The ``windows-2022`` 8.3 SHORT-name case, reproduced on every host. On
    that runner ``tempfile.gettempdir()`` returns
    ``C:\\Users\\RUNNER~1\\AppData\\Local\\Temp`` — which is what the
    allow-list holds verbatim — while ``realpath`` of a directory under it
    returns ``C:\\Users\\runneradmin\\...``, so a RAW
    ``real.startswith(prefix)`` is False for the harness's OWN tempdir.

    The divergence here is a redundant ``..`` segment instead of a short
    name, because ``realpath`` collapses both and a ``..`` needs no symlink
    privilege on Windows. That matters: with a short name the property is
    only observable on the one host that spells its ``%TEMP%`` that way,
    and the sibling test above can only fail there. This one fails on
    Linux and macOS too if ``is_safe_tmp`` ever stops canonicalising the
    prefix side — which is the half that actually broke.
    """
    import harness

    sep = "\\" if os.name == "nt" else "/"
    with tempfile.TemporaryDirectory(prefix=REQUIRED_TMP_SUBSTR) as td:
        os.makedirs(os.path.join(td, "sub"))
        # The same directory as ``td``, spelled non-canonically.
        non_canonical = f"{td}{sep}sub{sep}..{sep}"
        assert not harness._canonical(td).startswith(non_canonical), (
            "the fixture did not produce a non-canonical spelling — this "
            "test would pass vacuously"
        )
        monkeypatch.setattr(harness, "ALLOWED_TMP_PREFIXES", (non_canonical,))
        assert harness.is_safe_tmp(td, "/this/home/does/not/exist") is True, (
            f"is_safe_tmp rejected {td!r} when the allow-list spells the same "
            f"directory as {non_canonical!r}. A raw prefix comparison is "
            f"False there, and on a windows-2022 runner that is every "
            f"harness tempdir — so teardown would refuse to delete it."
        )


def test_tempfile_gettempdir_is_in_allowed_prefixes() -> None:
    """``tempfile.gettempdir()`` (OS-default temp) must be an allowed prefix.

    This is the test that catches the Windows regression: the previous
    implementation had ``tempfile.gettempdir() + "/"`` which on Windows
    produced a mixed-separator prefix that never matched ``realpath``.
    """
    gettempdir = tempfile.gettempdir()
    # Build the expected prefix the same way the harness does.
    if os.name == "nt":
        expected_prefix = gettempdir.rstrip("\\") + "\\"
    else:
        expected_prefix = gettempdir + "/"
    assert any(
        prefix == expected_prefix for prefix in ALLOWED_TMP_PREFIXES
    ), (
        f"tempfile.gettempdir() = {gettempdir!r} on {sys.platform} is not "
        f"in ALLOWED_TMP_PREFIXES = {ALLOWED_TMP_PREFIXES!r}. "
        f"Expected prefix {expected_prefix!r} to be present."
    )


# ─── pnpm binary resolution (cross-platform) ────────────────────────────────


def test_pnpm_resolves_on_this_os() -> None:
    """``shutil.which('pnpm')`` (or ``pnpm.cmd`` on Windows) finds a binary.

    The UI harness uses this resolution so vite can be spawned on
    Windows where ``pnpm`` is a batch script. If pnpm is not installed
    on the test host, this test is skipped (it documents the
    expected behaviour rather than failing the suite).

    2026-08-28 — pnpm migration: this test previously asserted on
    ``npm``. The project's package manager is now pnpm; see the
    workspace ``.npmrc``.
    """
    import shutil

    pnpm_bin = shutil.which("pnpm") or shutil.which("pnpm.cmd")
    if pnpm_bin is None:
        pytest.skip("pnpm not installed on this host")
    assert os.path.exists(pnpm_bin), f"shutil.which('pnpm') returned {pnpm_bin!r} but it doesn't exist"
    # On POSIX, pnpm must be executable. On Windows, .cmd files don't
    # need the executable bit.
    if os.name != "nt":
        assert os.access(pnpm_bin, os.X_OK), f"pnpm binary {pnpm_bin!r} is not executable on POSIX"


# ─── vite port range sanity ─────────────────────────────────────────────────


def test_vite_port_range_avoids_default_5173() -> None:
    """The UI harness's vite port range excludes Vite's default 5173.

    This avoids clashing with a developer's running ``npm run dev``
    session. The convention is captured in the harness constants.
    """
    from ui_harness import VITE_PORT_START, VITE_PORT_END

    assert 5173 < VITE_PORT_START, (
        f"VITE_PORT_START ({VITE_PORT_START}) must be > 5173 to avoid "
        f"clashing with developer dev-runs"
    )
    assert VITE_PORT_END > VITE_PORT_START, "VITE_PORT_END must be > VITE_PORT_START"


def test_vite_port_range_avoids_backend_port_8081() -> None:
    """The vite port range must not include 8081 (the dev backend port)."""
    from ui_harness import VITE_PORT_START, VITE_PORT_END

    assert not (VITE_PORT_START <= 8081 <= VITE_PORT_END), (
        f"vite port range [{VITE_PORT_START}, {VITE_PORT_END}] must not include 8081"
    )


# ─── vite random-port selector ──────────────────────────────────────────────


def test_vite_reserved_ports_includes_5173_and_8081() -> None:
    """The UI harness's reserved-port list skips Vite's default + dev backend.

    The picker is asked for ports from the wide shared harness range
    (``harness.RANDOM_PORT_*``) with ``VITE_RESERVED_PORTS =
    (5173, 8081)`` so it never lands on either of these
    "always-likely-to-be-busy" ports.
    """
    from ui_harness import VITE_RESERVED_PORTS

    assert 5173 in VITE_RESERVED_PORTS, (
        f"VITE_RESERVED_PORTS must include 5173 (Vite's default — a "
        f"developer's running pnpm dev session would bind it); "
        f"got {VITE_RESERVED_PORTS!r}"
    )
    assert 8081 in VITE_RESERVED_PORTS, (
        f"VITE_RESERVED_PORTS must include 8081 (always-on dev backend "
        f"per project memory); got {VITE_RESERVED_PORTS!r}"
    )


def test_find_free_vite_port_returns_port_in_range() -> None:
    """``_find_free_vite_port(None)`` returns a port in the random range.

    With no ``suggested`` arg, the picker falls through to the shared
    random selector. The contract: the returned port is in the wide
    range, not in VITE_RESERVED_PORTS, and is bindable.
    """
    from ui_harness import VITE_PORT_END, VITE_PORT_START, _find_free_vite_port
    from ui_harness import VITE_RESERVED_PORTS
    from harness import port_is_free_with_reuse

    port = _find_free_vite_port(None)
    assert VITE_PORT_START <= port <= VITE_PORT_END, (
        f"vite port {port} fell outside the configured range "
        f"[{VITE_PORT_START}, {VITE_PORT_END}]"
    )
    assert port not in VITE_RESERVED_PORTS, (
        f"vite port {port} is in VITE_RESERVED_PORTS {VITE_RESERVED_PORTS!r}"
    )
    # And bindable (the picker just bound it, but closing+reopening is
    # the cleanest "still free" assertion).
    assert port_is_free_with_reuse(port) is True


def test_find_free_vite_port_honours_suggested_when_free() -> None:
    """``_find_free_vite_port(suggested)`` returns the suggested port if free.

    Lets a debugging caller force a deterministic port. Returns the
    value verbatim if ``port_is_free_with_reuse`` says yes.
    """
    from ui_harness import VITE_PORT_START, _find_free_vite_port
    from harness import port_is_free_with_reuse

    # Find a port in the harness's real range that nobody is listening
    # on. (Iterate a small window; if every port is busy the test is
    # moot.)
    chosen = None
    for p in range(VITE_PORT_START, VITE_PORT_START + 100):
        if port_is_free_with_reuse(p):
            chosen = p
            break
    if chosen is None:
        # Free port probe failed — uncommon, skip rather than flake.
        import pytest
        pytest.skip(
            f"no free port in [{VITE_PORT_START}, {VITE_PORT_START + 100}] "
            "to seed suggested-port test"
        )

    assert _find_free_vite_port(chosen) == chosen


def test_find_free_vite_port_raises_when_suggested_busy() -> None:
    """``_find_free_vite_port(suggested)`` raises if the suggested port is busy.

    The contract: an explicit caller-side value is honored iff the
    port is genuinely free; otherwise the harness fails fast with a
    clear message instead of silently picking a different port.
    """
    from ui_harness import _find_free_vite_port, FunctionalHarnessError

    # Bind a port so it's definitely not free, then ask the picker to
    # use it. Picker MUST raise — not silently substitute.
    import socket
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        busy_port = s.getsockname()[1]
        s.listen(1)
        try:
            import pytest
            with pytest.raises(FunctionalHarnessError) as exc:
                _find_free_vite_port(busy_port)
            assert str(busy_port) in str(exc.value)
        finally:
            s.close()


def test_find_free_vite_port_usually_varies_across_calls() -> None:
    """Back-to-back random picks usually differ (parallel to backend test).

    With a 20k-port range the collision probability is tiny — if this
    ever flakes we'd suspect random.randint() semantics drifting.
    """
    from ui_harness import _find_free_vite_port

    picks = {_find_free_vite_port(None) for _ in range(10)}
    assert len(picks) > 1, (
        f"10 random vite-port picks returned only {len(picks)} distinct "
        f"values ({picks!r}) — randomisation is broken / seed is pinned"
    )


def test_ui_harness_boot_signature_accepts_none_port() -> None:
    """``UIHarness.boot(port=None)`` is the documented default — must accept None.

    Regression guard for the bug where ``port: int = DEFAULT_PORT`` was
    the default (=8080), which then triggered the legacy sequential
    scan even when the caller didn't pass a port. The fix: ``port:
    int | None = None`` so a bare ``UIHarness.boot(...)`` call goes
    through the random path.

    We can't easily mock-boot the UI harness here (it spawns a real
    Vite), so we just inspect the function signature via ``inspect`` —
    cheaper than booting Vite just to read .port.
    """
    import inspect
    from ui_harness import UIHarness

    sig = inspect.signature(UIHarness.boot)
    port_param = sig.parameters["port"]
    assert port_param.default is None, (
        f"UIHarness.boot(port=...) default must be None (random), got "
        f"{port_param.default!r}. With a non-None default, callers using "
        f"the documented `UIHarness.boot(...)` shape would silently get "
        f"the legacy sequential scan from that port."
    )
