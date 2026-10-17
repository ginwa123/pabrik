"""Platform gates for the Python functional suites.

One table, one reason per row, applied by each suite's ``conftest.py``.
The CI matrix runs the same suites on ``ubuntu-24.04``, ``macos-15`` and
``windows-2022``; a suite that cannot run on a cell is skipped THERE
with a reason that says WHY, instead of failing with a collection error
about a missing ``termios`` module that says nothing about the product.

Two rules govern this file:

1. **A row here is a statement about the platform, not about the test.**
   "``import pty`` does not exist on Windows" and "the terminal HTTP API
   answers ``UnsupportedPlatform`` on Windows" are facts about the
   platform. "This test is flaky" is not, and belongs in an xfail on the
   test itself. If you find yourself adding a row because a test is
   annoying on macOS, the fix belongs in the test.

2. **Fix the row, don't grow it.** Most rows here were added because a
   portable fix was possible but not made in the same change. A row whose
   test has since been made portable must be deleted, not kept as a
   belt-and-braces skip — a stale skip hides the next regression.

Nothing in here is a product bug. The table used to gate the whole terminal
API on Windows (``is_pty_os = linux || macos``); the product has since grown
a Windows backend — ConPTY, with a pipe fallback for a host whose
pseudoconsole cannot start a client — so those rows were deleted, as this
file's own rule required. The one terminal row that remains is the
Playwright panel suite, which has no Windows runner for toolchain reasons
that have nothing to do with the platform gate.
"""

from __future__ import annotations

import os
import sys
from typing import Any, NamedTuple


class Gate(NamedTuple):
    """One ``(platform, module) -> reason`` row.

    ``import_time`` distinguishes the two ways a gate has to be applied,
    and it is a property of the blocker, not a preference:

      * ``True``  — the module cannot even be IMPORTED on this platform
        (``import pty`` at module scope). ``pytest.mark.skipif`` never
        runs, because collection dies first. These go into
        ``collect_ignore`` so the file is never opened.

      * ``False`` — the module imports fine and the tests are skipped, so
        ``pytest.mark.skipif`` is enough and the reason shows up on the
        test id where a reviewer can see it.
    """

    platform: str
    module: str
    reason: str
    import_time: bool = False


#: ``sys.platform``-prefix -> human label used in skip reasons.
_PLATFORM_LABELS = {
    "win32": "Windows",
    "darwin": "macOS",
    "linux": "Linux",
}

#: Every gate, as a flat table. The comment above each group is the
#: class of blocker, so a new row lands next to its siblings and the
#: "why" is visible without opening each test.
GATES: tuple[Gate, ...] = (
    # ── POSIX-only stdlib imports (`pty` / `fcntl` / `termios`) ──────────
    # These are module-level `import pty`, so on Windows they are a
    # COLLECTION ERROR that takes the whole file with them, not a test
    # failure. The TUI needs a pseudo-terminal; Windows has ConPTY,
    # which is not exposed through the `pty` module.
    Gate(
        "win32",
        "tui_turn_streaming_test.py",
        "needs a POSIX pty (import pty/fcntl/termios); Windows has ConPTY, "
        "which the stdlib pty module does not expose",
        import_time=True,
    ),
    Gate(
        "win32",
        "tui_perf_test.py",
        "imports tui_perf_probe, which does a module-level `import pty` / "
        "`fcntl` — neither exists on Windows, so collection fails before "
        "any skip marker can run",
        import_time=True,
    ),
    # ── Linux-only kernel interfaces ────────────────────────────────────
    # RSS accounting reads /proc/<pid>/status. macOS has no /proc; the
    # equivalent is `ps -o rss=` or psutil, and the TUI perf budget is
    # the only consumer.
    Gate(
        "darwin",
        "tui_perf_test.py",
        "tui_perf_probe reads /proc/<pid>/status for RSS; macOS has no /proc",
    ),

    # ── Product gate: no pty backend on Windows ──────────────────────────
    # DELETED 2026-10-17. Every row here said "no pty backend on Windows:
    # terminal_session.zig sets is_pty_os = linux || macos", and that is no
    # longer true: the terminal API ships a Windows backend (ConPTY, with a
    # pipe fallback for a host whose pseudoconsole cannot start a client),
    # and the four `terminal_*` suites run — and pass — on Windows with a
    # `cmd.exe` instead of the `/bin/sh` they used to pass. A gate whose
    # subject has been fixed is a gate that hides the next regression, so
    # the rows are gone rather than kept as belt and braces.
    Gate(
        "win32",
        "terminal_sidebar_ui_test.py",
        "a Playwright browser test of the terminal panel; the Windows CI "
        "cell runs `zig build test` and installs no browser or UI "
        "toolchain, so this suite has no Windows runner (the API it drives "
        "is covered on Windows by the terminal_* Zig suites)",
    ),

    # ── POSIX signal / waitpid semantics ────────────────────────────────
    # The test asserts a graceful-shutdown EXIT CODE of 130, which is
    # what a process group that received SIGINT reports. Windows' os.kill
    # maps to TerminateProcess: no signal semantics, no WIFEXITED, and
    # WNOHANG/WTERMSIG are Unix-only attributes that raise
    # AttributeError. A faithful Windows version needs
    # GenerateConsoleCtrlEvent against a real console, which this
    # harness does not allocate.
    Gate(
        "win32",
        "graceful_shutdown_test.py",
        "asserts SIGINT-graceful exit semantics (os.WNOHANG / "
        "os.WIFEXITED / exit code 130); Windows os.kill is TerminateProcess "
        "and those waitpid attributes do not exist",
    ),

    # ── select() over a pipe ────────────────────────────────────────────
    # CPython's Windows select() accepts sockets only. Reading a child
    # process's stdout without deadlocking there needs a reader thread or
    # a pipe server, not a wider select.
    Gate(
        "win32",
        "mcp_stdio_hang_test.py",
        "select.select() on a subprocess pipe; Windows select() accepts "
        "sockets only",
    ),
)


def current_platform() -> str:
    """Return the gate platform key for the running interpreter.

    ``sys.platform`` is the value the table is keyed on. Normalising here
    (rather than at every call site) means a new row never has to know
    about Windows' 32/64 distinction or Python 2's legacy ``win32``.
    """
    if os.name == "nt":
        return "win32"
    if sys.platform == "darwin":
        return "darwin"
    return "linux"


def platform_label(platform: str | None = None) -> str:
    """Human label for a platform key, e.g. ``"Windows"``."""
    return _PLATFORM_LABELS.get(platform or current_platform(), "this platform")


def gate_platforms() -> tuple[str, ...]:
    """Every platform key the table can be asked about, in a stable order.

    Derived from ``_PLATFORM_LABELS`` rather than from ``GATES`` on
    purpose. If it walked ``GATES``, a table with zero rows would return
    an empty tuple and ``parametrize`` would silently collect ZERO tests
    — a green run that checks nothing. This list is the contract: it
    changes only when a runner is added to the CI matrix.
    """
    return tuple(_PLATFORM_LABELS)


def _gates(platform: str) -> list[Gate]:
    """All rows for one platform, de-duplicated by module (first wins)."""
    seen: dict[str, Gate] = {}
    for g in GATES:
        if g.platform == platform and g.module not in seen:
            seen[g.module] = g
    return list(seen.values())


def collect_ignore_for(platform: str | None = None) -> list[str]:
    """Return the file names a suite's ``collect_ignore`` must exclude.

    Only rows flagged ``import_time`` land here — those files raise at
    ``import``, so a skip marker never gets a chance to fire. The rest
    are handled by :func:`runtime_skip_reasons`, which produces skip
    markers the reviewer can actually see on the test id.

    Bare basenames, not joined paths, because pytest resolves
    ``collect_ignore`` entries relative to the directory of the
    ``conftest.py`` that declares the list. A suite copies the result
    straight into its own ``collect_ignore``; nothing needs the suite's
    location, so nothing takes it.
    """
    return [g.module for g in _gates(platform or current_platform()) if g.import_time]


def runtime_skip_reasons(platform: str | None = None) -> dict[str, str]:
    """Return ``{module_basename: reason}`` for the non-import-time rows."""
    return {
        g.module: g.reason
        for g in _gates(platform or current_platform())
        if not g.import_time
    }


def apply_runtime_gates(items: list[Any], platform: str | None = None) -> int:
    """Skip every collected item whose module has a runtime gate.

    Returns the number of items skipped.

    This is the hook body each suite's ``conftest.py`` delegates to, and
    it lives here rather than being copy-pasted into both conftests for
    the same reason ``scripts/ci-install-linux-deps.sh`` exists: a rule
    that has to be kept in agreement in N places is a rule that will
    drift in all N of them, and this one has a bug in it (see the
    ``pytest.mark.skip`` note below) that would then have to be fixed N
    times.

    Items are marked rather than ignored, deliberately: the skipped test
    ids stay in the report WITH their reason, so a reviewer reading the
    CI log sees that ``terminal_ws_test.py`` was skipped on Windows and
    why, instead of inferring it from a test file that vanished.
    """
    # Imported here, not at module scope: everything above this line is
    # pure and importable by a bare `python3 -c "import platform_gates"`,
    # which is how the table is easiest to poke at by hand.
    import pytest

    reasons = runtime_skip_reasons(platform)
    if not reasons:
        return 0

    skipped = 0
    for item in items:
        name = getattr(getattr(item, "path", None), "name", "")
        reason = reasons.get(name)
        if reason is None:
            continue
        # `pytest.mark.skip(reason=...)` is a FACTORY: each call returns a
        # fresh Mark already carrying that reason. There is no way to
        # rebind it afterwards — `Mark` is not callable, so the tempting
        # `template.mark(reason=...)` raises TypeError during collection
        # and takes the whole run down with an INTERNALERROR. This exact
        # bug shipped in the first draft of this file; build one mark per
        # item.
        item.add_marker(pytest.mark.skip(reason=reason))
        skipped += 1
    return skipped


__all__ = [
    "GATES",
    "Gate",
    "apply_runtime_gates",
    "collect_ignore_for",
    "current_platform",
    "gate_platforms",
    "platform_label",
    "runtime_skip_reasons",
]
