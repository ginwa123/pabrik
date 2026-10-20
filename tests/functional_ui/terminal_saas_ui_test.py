"""Functional UI test: under ``--saas`` the Terminal tab's shell runs INSIDE the
workspace's VM.

Why this test exists
--------------------
The right-sidebar terminal used to call ``forkpty`` on the HOST in every mode, so
a ``--saas`` tenant saw the server's own cwd and could read the whole host
filesystem — the exact leak the mode exists to prevent. The fix routes a
``--saas`` terminal into the workspace's VM through ``pabrik-vmd``, keyed by
``workspace_id``, with a refusal (never a host fallback) when no workspace is
named.

This test asserts the two halves that matter, end to end in a real browser:

1. ``test_saas_terminal_shell_runs_inside_the_vm`` — open the sidebar terminal,
   type a marker plus ``pwd``, and see the marker come back with ``/workspace``.
   Then prove it is not the host: ``/home`` does not exist in the guest.
2. ``test_saas_terminal_refuses_without_a_workspace`` — the create endpoint
   answers 409 instead of opening a host shell. Driven from the same logged-in
   browser session, so it is the real route with the real cookie.

The VM half needs a Linux host with ``/dev/kvm`` plus a guest kernel, a base
image and firecracker. Where any of those is missing the test SKIPS: the point
is to prove the guest path where a guest can exist, not to fail a laptop.

The boot gets its OWN manager socket and VM root. Without that the run would
ping the developer's already-running ``pabrik-vmd``, reuse its base image, and
silently test an older agent.

Run:
    PABRIK_BIN=./zig-out/bin/pabrikcore-linux-x86_64 \\
      python -m pytest tests/functional_ui/terminal_saas_ui_test.py -v -s
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterator

import pytest

from chatview_boot import bind_session_workspace
from db_seed import DbSeed
from harness import find_free_port_random
from ui_harness import UIHarness

EMAIL = "saas-terminal@example.com"
PASSWORD = "supersecret123"

#: JS predicate for ``page.wait_for_function``: true once the xterm buffer (last
#: 300 lines) contains the marker passed as arg. xterm renders to a canvas, so
#: the dev-only ``window.__pabrikTerm`` hook is the only readable surface.
BUFFER_HAS_MARKER_JS = """(marker) => {
  const t = window.__pabrikTerm;
  if (!t) return false;
  const b = t.buffer.active;
  let out = '';
  const n = b.length;
  for (let y = Math.max(0, n - 300); y < n; y++) {
    const line = b.getLine(y);
    if (line) out += line.translateToString(true) + '\\n';
  }
  return out.includes(marker);
}"""


# ============================================================================
# Host artifacts — the guest can only be tested where one can boot
# ============================================================================


def _first_existing(*candidates: Any) -> Path | None:
    for candidate in candidates:
        if not candidate:
            continue
        path = Path(candidate)
        if path.exists():
            return path
    return None


def _guest_artifacts(pabrik_bin: Path) -> dict[str, Path] | None:
    """The four things a ``--saas`` boot needs, or None when this host lacks one.

    ``pabrik-vmd`` is looked up beside the pabrik binary first: that is the copy
    built from the same tree, so the test exercises this commit's daemon and
    agent rather than whatever release happens to be installed.
    """
    if sys.platform != "linux":
        return None
    if not Path("/dev/kvm").exists():
        return None
    vmd = _first_existing(
        os.environ.get("PABRIK_VMD_BIN"),
        pabrik_bin.parent / "pabrik-vmd",
        shutil.which("pabrik-vmd"),
    )
    fc = _first_existing(
        os.environ.get("PABRIK_FC_BIN"),
        shutil.which("firecracker"),
        Path.home() / "firecracker-demo" / "firecracker",
    )
    kernel = _first_existing(
        os.environ.get("PABRIK_GUEST_KERNEL"),
        Path.home() / ".cache" / "pabrik-vm" / "vmlinux",
        Path.home() / "firecracker-demo" / "vmlinux-6.18.51",
    )
    image = _first_existing(
        os.environ.get("PABRIK_VM_BASE_IMAGE"),
        Path.home() / ".cache" / "pabrik-vm" / "images" / "base.ext4",
    )
    if vmd is None or fc is None or kernel is None or image is None:
        return None
    return {"vmd": vmd, "fc": fc, "kernel": kernel, "image": image}


#: Every env var the harness's child processes inherit from us. ``XDG_*`` inside
#: the harness points at its tempdir, so the default image paths cannot be found
#: — these overrides are what make the boot land on a real guest.
_VM_ENV_KEYS = (
    "PABRIK_VM_DIR",
    "PABRIK_VM_BASE_IMAGE",
    "PABRIK_GUEST_KERNEL",
    "PABRIK_FC_BIN",
    "PABRIK_VMD_BIN",
    "PABRIK_VMD_SOCKET",
    "PABRIK_ALLOWED_ORIGINS",
)


def _stop_workspace_vms(vmd: Path, socket: Path, vm_root: Path) -> None:
    """Stop every VM this run booted, then the manager itself.

    A VM left running keeps a firecracker process and its memory; a manager left
    running keeps both alive. The socket path is unique to this test, so matching
    on it cannot reach the developer's own manager.
    """
    workspaces = vm_root / "workspaces"
    if workspaces.is_dir():
        for workspace in workspaces.iterdir():
            subprocess.run(
                [str(vmd), "stop", "--socket", str(socket), "--workspace-id", workspace.name],
                capture_output=True,
                text=True,
                timeout=60,
            )
    subprocess.run(
        ["pkill", "-f", f"pabrik-vmd serve --socket {socket}"],
        capture_output=True,
        text=True,
        timeout=30,
    )


@pytest.fixture
def saas_ui(default_pabrik_bin: Path, tmp_path_factory: pytest.TempPathFactory) -> Iterator[UIHarness]:
    """A logged-in ``--saas`` backend + Vite, on its own manager and VM root."""
    artifacts = _guest_artifacts(default_pabrik_bin)
    if artifacts is None:
        pytest.skip(
            "no guest VM toolchain (need Linux + /dev/kvm + firecracker + kernel + base image)"
        )

    vm_root = tmp_path_factory.mktemp("saas-vm")
    socket = vm_root / "vmd.sock"
    # `--saas` turns the engine's Origin gate ON, and the UI harness serves the
    # app from Vite on its own port with the browser's Origin forwarded through
    # the proxy. Without this entry every mutation — including the terminal
    # create — is a 403. The port is picked here so the backend can be told
    # before it boots.
    vite_port = find_free_port_random(reserved=(5173, 8081))
    env = {
        "PABRIK_VM_DIR": str(vm_root),
        "PABRIK_VM_BASE_IMAGE": str(artifacts["image"]),
        "PABRIK_GUEST_KERNEL": str(artifacts["kernel"]),
        "PABRIK_FC_BIN": str(artifacts["fc"]),
        "PABRIK_VMD_BIN": str(artifacts["vmd"]),
        # A socket of our own: pinging the developer's manager would reuse ITS
        # base image and test an agent this commit never built.
        "PABRIK_VMD_SOCKET": str(socket),
        "PABRIK_ALLOWED_ORIGINS": f"127.0.0.1:{vite_port}",
    }
    saved = {key: os.environ.get(key) for key in _VM_ENV_KEYS}
    os.environ.update(env)

    h: UIHarness | None = None
    try:
        h = UIHarness.boot(
            default_pabrik_bin,
            vite_port=vite_port,
            extra_args=("--saas",),
            ready_timeout_s=90.0,
        )
        _create_admin(default_pabrik_bin, h.temp_dir)
        yield h
    finally:
        if h is not None:
            try:
                _stop_workspace_vms(artifacts["vmd"], socket, vm_root)
            finally:
                h.teardown()
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def _create_admin(bin_path: Path, home: Path) -> None:
    """Mint the admin row ``--saas`` implies auth for. Same HOME shadow as the
    server, or this writes into the developer's real profile."""
    env = dict(os.environ)
    env["HOME"] = str(home)
    env["XDG_CONFIG_HOME"] = str(home / ".config")
    env["XDG_STATE_HOME"] = str(home / ".local" / "state")
    env["XDG_DATA_HOME"] = str(home / ".local" / "share")
    env["XDG_CACHE_HOME"] = str(home / ".cache")
    r = subprocess.run(
        [str(bin_path), "create-admin", "--email", EMAIL, "--password", PASSWORD],
        capture_output=True,
        text=True,
        env=env,
        timeout=60,
    )
    assert r.returncode == 0, f"create-admin failed: {r.stderr[-2000:]}"


def _sign_in(page, h: UIHarness) -> None:
    page.goto(h.web_url("/app"), wait_until="domcontentloaded", timeout=60000)
    page.wait_for_url("**/login**", timeout=20000)
    page.get_by_placeholder("you@example.com").fill(EMAIL)
    page.get_by_placeholder("••••••••").fill(PASSWORD)
    page.get_by_role("button", name="Sign in").click()
    # A URL glob is not proof: `/login?redirect=/app` matches `**/app**` too, and
    # the setup request that follows would then race the cookie and 401. Ask the
    # server instead — this is the exact postcondition the test needs.
    page.wait_for_function(
        """async () => {
          const r = await fetch('/api/auth/me');
          if (!r.ok) return false;
          const me = await r.json();
          return me.authenticated === true;
        }""",
        timeout=30000,
    )


#: Runs INSIDE the logged-in page, so the request carries the session cookie.
#: The first authenticated mutation is RETRIED rather than preceded by a sleep:
#: the cookie settles a beat after the form submit, and the retry is also the
#: honest postcondition ("this browser can mutate"). A 401 creates nothing, so
#: retrying cannot leave duplicates behind.
CREATE_CHAT_JS = """async (name) => {
  const post = async (path, body) => {
    const r = await fetch(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    return { status: r.status, body: await r.json().catch(() => ({})) };
  };
  let ws = null;
  for (let i = 0; i < 60; i++) {
    ws = await post('/api/workspaces', { name: name + '-ws' });
    if (ws.status === 201) break;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  if (!ws || ws.status !== 201) {
    throw new Error('workspace create failed: ' + JSON.stringify(ws));
  }
  const sess = await post('/api/llm/session', { name: name, cwd_session: '/workspace' });
  if (sess.status !== 201) {
    throw new Error('session create failed: ' + JSON.stringify(sess));
  }
  return { session_id: sess.body.id, workspace_id: ws.body.id };
}"""

#: Runs INSIDE the page: one create with `workspace_id`, one without.
CREATE_TERMINAL_JS = """async (workspaceId) => {
  const post = async (body) => {
    const r = await fetch('/api/terminal/sessions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    return { status: r.status, body: await r.json() };
  };
  const refused = await post({ cwd: '/workspace' });
  const accepted = await post({ workspace_id: workspaceId, cwd: '/workspace' });
  return { refused, accepted };
}"""


def _create_chat(page, h: UIHarness, name: str) -> tuple[str, str]:
    """A chat that belongs to a real workspace, so the deep link resolves."""
    ids = page.evaluate(CREATE_CHAT_JS, name)
    session_id = str(ids["session_id"])
    workspace_id = str(ids["workspace_id"])
    seed = DbSeed(h.temp_dir / ".config" / "pabrik" / "agent.db")
    with seed.connect() as conn:
        bind_session_workspace(conn, workspace_id, session_id)
    return session_id, workspace_id


def _open_terminal(page, h: UIHarness, workspace_id: str, session_id: str) -> None:
    page.goto(
        h.web_url(f"/app/{workspace_id}/chat/{session_id}"),
        wait_until="load",
        timeout=60000,
    )
    page.locator("text=How can I help you?").first.wait_for(timeout=30000, state="visible")
    sidebar = page.locator('[data-testid="chat-right-sidebar"]')
    try:
        sidebar.wait_for(timeout=3000, state="visible")
    except Exception:
        page.locator('[data-testid="chat-app-bar-sidebar-toggle"]').click(timeout=5000)
        sidebar.wait_for(timeout=10000, state="visible")
    page.locator('[data-testid="chat-right-sidebar-tab-terminal"]').click()
    page.locator('[data-testid="terminal-xterm"]').wait_for(timeout=10000, state="visible")
    page.locator('[data-testid="terminal-empty-new"]').click()
    # A chip with the live dot means the session exists AND its socket attached.
    # A `+` that never lights up has two very different causes (a refused create
    # vs a socket that never attached); the panel says which, so report it
    # instead of a bare locator timeout.
    try:
        page.locator('[data-testid="terminal-session-chip"]', has_text="●").first.wait_for(
            timeout=60000, state="visible"
        )
    except Exception:
        status = page.locator('[data-testid="terminal-status"]')
        shown = status.first.text_content() if status.count() else "(no status element)"
        raise AssertionError(
            f"terminal session never came up; panel says: {shown!r}\n"
            f"--- backend log ---\n{h.tail_log(80)}"
        ) from None


def _type(page, command: str) -> None:
    page.locator('[data-testid="terminal-xterm"]').click()
    page.keyboard.type(command, delay=15)
    page.keyboard.press("Enter")


def test_saas_terminal_shell_runs_inside_the_vm(saas_ui: UIHarness, page) -> None:
    """The tab's shell is the guest's: it starts at ``/workspace`` and cannot
    see the host's filesystem."""
    h = saas_ui
    errors: list[str] = []
    page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
    page.on("pageerror", lambda e: errors.append(str(e)))

    _sign_in(page, h)
    session_id, workspace_id = _create_chat(page, h, "saas-terminal")
    _open_terminal(page, h, workspace_id, session_id)

    marker = "SAAS-UI-4c1e"
    try:
        _type(page, f"echo {marker}")
        page.wait_for_function(BUFFER_HAS_MARKER_JS, arg=marker, timeout=60000)

        # The cwd the card requires: the agent's own `/workspace`, not a host path.
        _type(page, "echo PWD=$(pwd)")
        page.wait_for_function(BUFFER_HAS_MARKER_JS, arg="PWD=/workspace", timeout=60000)

        # And prove it is a different filesystem: the host has `/home`, the guest
        # does not. `test -d` keeps this locale-free.
        not_host = "GUEST-ONLY-91af"
        _type(page, f"test -d /home && echo HOST-VISIBLE || echo {not_host}")
        page.wait_for_function(BUFFER_HAS_MARKER_JS, arg=not_host, timeout=60000)
    finally:
        if errors:
            print("\n[console errors]")
            for e in errors:
                print(f"  - {e[:300]}")


def test_saas_terminal_refuses_without_a_workspace(saas_ui: UIHarness, page) -> None:
    """No ``workspace_id`` is a refusal, never a shell on the host.

    Same logged-in browser session, so this is the real route with the real
    cookie; the accepted call right after it proves the refusal is about the
    missing id and not about terminals being broken.
    """
    h = saas_ui
    _sign_in(page, h)
    _session_id, workspace_id = _create_chat(page, h, "saas-terminal-refusal")

    result = page.evaluate(CREATE_TERMINAL_JS, workspace_id)
    refused = result["refused"]
    accepted = result["accepted"]

    assert refused["status"] == 409, json.dumps(refused)
    assert "workspace_id" in refused["body"]["error"], json.dumps(refused)

    assert accepted["status"] == 201, json.dumps(accepted)
    assert accepted["body"]["backend"] == "guest-pty", json.dumps(accepted)
    assert accepted["body"]["id"].startswith("gterm-"), json.dumps(accepted)

    # Leave nothing running in the VM.
    page.evaluate(
        """async (id) => {
          await fetch('/api/terminal/sessions/' + encodeURIComponent(id), { method: 'DELETE' });
        }""",
        accepted["body"]["id"],
    )
