"""Functional UI test: under ``--saas`` the Explorer lists the workspace's VM.

Why this test exists
--------------------
``--saas`` lists a workspace's VM, not the host's filesystem, so a folder
request has to say WHICH workspace it means. The Explorer did not: it asked
for ``/workspace`` and the server refused with 400 "SaaS mode lists a
workspace's VM: pass workspace_id". The Explorer showed an empty tree and
every attempt raised a toast — the app could not show a tenant their own
files.

This test asserts the two halves that matter, end to end in a real browser:

1. ``test_saas_explorer_lists_the_workspace_vm`` — the Explorer's own request
   names the workspace, the server answers 200, and the tree it returns is
   the GUEST's (``/workspace``), not the host's.
2. ``test_saas_folder_route_refuses_without_a_workspace`` — the same route
   without the id is still refused. That is the negative control: it proves
   the first test is about the id and not about the route being open.

The VM half needs a Linux host with ``/dev/kvm`` plus a guest kernel, a base
image and firecracker. Where any of those is missing the test SKIPS: the point
is to prove the guest path where a guest can exist, not to fail a laptop.

The bring-up (its own manager socket, its own VM root, the allowlisted Vite
origin, the admin row) lives with the terminal test, which needs the same
machine; this module imports its fixture rather than copying it.

Run:
    PABRIK_BIN=./zig-out/bin/pabrik \\
      python -m pytest tests/functional_ui/explorer_saas_ui_test.py -v -s
"""

from __future__ import annotations

import json
import time
from typing import Any

import pytest

from terminal_saas_ui_test import (  # noqa: F401 — the fixture is the point
    EMAIL,
    PASSWORD,
    _create_chat,
    saas_ui,
)
from db_seed import DbSeed
from ui_harness import UIHarness

#: The seeded chat's message: the chat's cwd rides in with its history.
CHAT_MARKER = "hello from the explorer test"

#: How long the Explorer's listing may take. The first request boots the
#: workspace's VM, so this is a VM boot, not an API round-trip.
LISTING_TIMEOUT_S = 120.0


def _sign_in(page, h: UIHarness) -> None:
    """Sign in, and let the SERVER say the session is there.

    The login view is re-created by the router's redirect from ``/app``, so a
    fill can land on a form that is about to be replaced — the button then
    stays disabled. Fill until it is submittable, and prove the session with
    ``/api/auth/me`` rather than with the URL (``/login?redirect=/app``
    matches any "**/app**" glob).
    """
    for _ in range(3):
        page.goto(h.web_url("/app"), wait_until="domcontentloaded", timeout=60000)
        page.wait_for_url("**/login**", timeout=30000)
        email_box = page.get_by_placeholder("you@example.com")
        password_box = page.get_by_placeholder("••••••••")
        sign_in = page.get_by_role("button", name="Sign in")
        for _ in range(20):
            email_box.fill(EMAIL)
            password_box.fill(PASSWORD)
            if sign_in.is_enabled():
                sign_in.click(timeout=10000)
                break
            page.wait_for_timeout(250)
        else:
            continue
        try:
            page.wait_for_function(
                """async () => {
                  const r = await fetch('/api/auth/me');
                  if (!r.ok) return false;
                  const me = await r.json();
                  return me.authenticated === true;
                }""",
                timeout=30000,
            )
            return
        except Exception:
            continue
    raise AssertionError("could not sign in")


def _create_chat_with_a_message(page, h: UIHarness, name: str) -> tuple[str, str]:
    """A chat that has a message.

    The chat's cwd rides in with its history (the messages endpoint reads it
    from the joined session row), so a chat with no message has no cwd — and
    the Explorer, which lists the cwd, would have nothing to ask for.
    """
    session_id, workspace_id = _create_chat(page, h, name)
    seed = DbSeed(h.temp_dir / ".config" / "pabrik" / "agent.db")
    with seed.connect() as conn:
        seed.seed_user_message(conn, session_id, CHAT_MARKER)
    return session_id, workspace_id


def _watch_folder_requests(page) -> list[dict[str, Any]]:
    """Record every ``/api/system/folder`` answer the page gets.

    The request is the behaviour under test: whether the client named the
    workspace, and what the server answered with.
    """
    seen: list[dict[str, Any]] = []

    def on_response(response) -> None:
        if "/api/system/folder" not in response.url:
            return
        try:
            body = response.json()
        except Exception:
            body = None
        seen.append({"url": response.url, "status": response.status, "body": body})

    page.on("response", on_response)
    return seen


def _open_explorer(page) -> None:
    """Show the chat's right sidebar on its Explorer tab."""
    sidebar = page.locator('[data-testid="chat-right-sidebar"]')
    try:
        sidebar.wait_for(timeout=5000, state="visible")
    except Exception:
        page.locator('[data-testid="chat-app-bar-sidebar-toggle"]').click(timeout=10000)
        sidebar.wait_for(timeout=15000, state="visible")
    page.locator('[data-testid="chat-right-sidebar-tab-explorer"]').click(timeout=10000)
    page.locator('[data-testid="chat-right-sidebar-explorer"]').wait_for(timeout=10000, state="visible")


def _await_explorer_listing(seen: list[dict[str, Any]]) -> dict[str, Any]:
    """The Explorer's own listing: the folder request that names a path.

    The app asks for the system folder on the way in too (before a workspace
    is known), so the Explorer's request is the one that names the path it is
    listing. The first answer boots the VM, so this waits for it.
    """
    deadline = time.monotonic() + LISTING_TIMEOUT_S
    while time.monotonic() < deadline:
        for entry in seen:
            if "path=" in entry["url"]:
                return entry
        time.sleep(0.25)
    raise AssertionError("the Explorer never asked for a folder listing")


def test_saas_explorer_lists_the_workspace_vm(saas_ui: UIHarness, page) -> None:
    """The Explorer's request names the workspace, and the tree is the guest's."""
    h = saas_ui
    seen = _watch_folder_requests(page)

    _sign_in(page, h)
    session_id, workspace_id = _create_chat_with_a_message(page, h, "saas-explorer")
    page.goto(
        h.web_url(f"/app/{workspace_id}/chat/{session_id}"),
        wait_until="load",
        timeout=60000,
    )
    # The chat's cwd arrives with its history: the Explorer lists the cwd, so
    # it needs the chat loaded, not just rendered.
    page.get_by_text(CHAT_MARKER).first.wait_for(timeout=30000, state="visible")
    _open_explorer(page)

    listing = _await_explorer_listing(seen)
    assert listing["status"] == 200, json.dumps(listing)
    assert f"workspace_id={workspace_id}" in listing["url"], listing["url"]

    # The tree is the GUEST's: its home is the workspace root inside the VM.
    body = listing["body"]
    assert isinstance(body, dict), json.dumps(listing)
    assert body.get("home") == "/workspace", json.dumps(body)
    assert body.get("absolute") == "/workspace", json.dumps(body)

    # A refusal would have toasted; a 200 does not.
    assert page.get_by_text("pass workspace_id").count() == 0


def test_saas_folder_route_refuses_without_a_workspace(saas_ui: UIHarness, page) -> None:
    """No ``workspace_id`` is a refusal; with it the same route answers.

    Driven from the same logged-in browser session, so this is the real route
    with the real cookie — and the two calls differ in exactly one thing.
    """
    h = saas_ui
    _sign_in(page, h)
    _session_id, workspace_id = _create_chat(page, h, "saas-explorer-refusal")

    result = page.evaluate(
        """async (workspaceId) => {
          const get = async (url) => {
            const r = await fetch(url);
            return { status: r.status, body: await r.json().catch(() => ({})) };
          };
          const without = await get('/api/system/folder?path=%2Fworkspace&action=list');
          const with_ = await get(
            '/api/system/folder?path=%2Fworkspace&action=list&workspace_id=' +
              encodeURIComponent(workspaceId),
          );
          return { without, with: with_ };
        }""",
        workspace_id,
    )

    refused = result["without"]
    accepted = result["with"]
    assert refused["status"] == 400, json.dumps(refused)
    assert "workspace_id" in refused["body"]["error"], json.dumps(refused)

    assert accepted["status"] == 200, json.dumps(accepted)
    assert accepted["body"]["home"] == "/workspace", json.dumps(accepted)
