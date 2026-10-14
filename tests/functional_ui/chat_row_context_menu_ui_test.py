"""Chat-row right-click context menu — real browser, real backend.

Covers the three actions added to the sidebar RECENT chat-row menu
(task_1790946799743_0):

1. **Rename chat** — asserts the name lands in BOTH tables.
   ``workspace_item_tasks.name`` AND ``sessions.name``. A sidebar row is
   rendered from the session list while the kanban board is rendered from
   the task list, so a rename that only reaches one of them renames the
   chat in half the app. ``task.id == session_id`` (Migration 052) and
   ``llm_history.updateTaskName`` cascades, which is why the UI calls
   ``api.updateTaskSimple`` rather than ``api.updateSession``.
2. **Stop agent** — row is hidden on an idle chat, appears once a worker
   exists, and picking it flips the worker's ``cancelled`` flag.
3. **Unattended mode** — persists ``is_auto_retry_until_stop`` WITHOUT
   clearing ``selected_profile_model``. The second half is the point: the
   PUT body always carries ``selected_profile_model``, the server reads
   ``''`` as CLEAR, so an implementation that passes only the flag resets
   the chat's model profile on every toggle.

Run:
    PABRIK_BIN=/home/ginwa/ginwaaitoolbox/zig-out/bin/pabrik \\
      /home/ginwa/ginwaaitoolbox/.venv-func/bin/python -m pytest \\
      tests/functional_ui/chat_row_context_menu_ui_test.py -v -s

Note on flakiness: the rename/unattended assertions wait on the sidebar
repainting through the SSE `session_updated` broadcast, so they are
inherently a round-trip. If one fails right after you have edited
``ChatsList.vue``, re-run before believing it — Vite's on-disk transform
cache is being rewritten underneath the dev server at that moment, which
was the cause of the only failure observed while building this file
(three consecutive clean 6/6 runs since, and a deliberate mutation test
confirms the assertions fail for the right reason rather than silently).
"""

from __future__ import annotations

import contextlib
import sqlite3
import time
from typing import Iterator

from harness import harness_path
from ui_harness import UIHarness

from db_seed import DbSeed


# ─── Fixtures via the HTTP API (faster and more honest than driving UI) ────


def _create_workspace(h: UIHarness, name: str) -> str:
    return h.http("POST", "/api/workspaces", json_body={"name": name}, expect=201).json()["id"]


def _create_agent(h: UIHarness, workspace_id: str, name: str) -> str:
    return h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/agent",
        json_body={"name": name, "path": harness_path(h, "ui-chat-menu-agent")},
        expect=201,
    ).json()["item"]["id"]


def _create_task(h: UIHarness, workspace_id: str, agent_id: str, name: str) -> str:
    """Create an agent task. ``task.id`` IS the session id (Migration 052)."""
    body = h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/{agent_id}/tasks",
        json_body={"name": name},
        expect=201,
    ).json()
    return body.get("id", body.get("task", {}).get("id", ""))


def _seed_matching_session(h: UIHarness, session_id: str, name: str) -> None:
    """Give the task a matching ``sessions`` row.

    ``POST .../tasks`` writes ``workspace_item_tasks`` only — the session
    row is created lazily on the first message. In production the two carry
    the same name by the time a chat shows up in RECENT, and the whole point
    of the rename test is that they stay in step. Seed the session here so
    both rows exist before the rename, exactly as they would in a real chat.

    Uses the suite's own ``DbSeed`` helper, which validates the DB path with
    ``is_safe_tmp`` before touching it.
    """
    seed = DbSeed(h.temp_dir / ".config" / "pabrik" / "agent.db")
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, name)


def _create_chat(h: UIHarness, ws_name: str, agent_name: str, chat_name: str) -> str:
    """One chat visible in the sidebar RECENT list: workspace + agent + task
    + the matching ``sessions`` row. Returns the session id (= task id)."""
    ws_id = _create_workspace(h, ws_name)
    agent_id = _create_agent(h, ws_id, agent_name)
    task_id = _create_task(h, ws_id, agent_id, chat_name)
    _seed_matching_session(h, task_id, chat_name)
    return task_id


# ─── Direct DB reads — the assertions that matter are about the two tables ──


@contextlib.contextmanager
def _db(h: UIHarness) -> Iterator[sqlite3.Connection]:
    """A connection to the harness's agent.db that is CLOSED on exit.

    `with sqlite3.connect(...) as conn` is NOT a closing block — sqlite3's
    context manager only commits or rolls back the transaction — so every
    read in this module used to leave the file handle open. Linux and
    macOS unlink an open file happily and never noticed; on Windows the
    harness's teardown rmtree then dies with

        PermissionError: [WinError 32] The process cannot access the file
        because it is being used by another process: ...\\agent.db

    which pytest reports as the test PASSING and then ERRORING. That is
    what this module did for all eight of its tests. Closing the handle is
    the teardown's precondition; the commit-on-exit behaviour is kept
    explicitly so nothing else about the helper changes.
    """
    conn = sqlite3.connect(str(h.temp_dir / ".config" / "pabrik" / "agent.db"))
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def _task_name(h: UIHarness, task_id: str) -> str:
    with _db(h) as conn:
        row = conn.execute(
            "SELECT name FROM workspace_item_tasks WHERE id = ?", (task_id,)
        ).fetchone()
    assert row is not None, f"task {task_id} not found in workspace_item_tasks"
    return row[0]


def _session_row(h: UIHarness, session_id: str) -> sqlite3.Row:
    with _db(h) as conn:
        conn.row_factory = sqlite3.Row
        row = conn.execute("SELECT * FROM sessions WHERE id = ?", (session_id,)).fetchone()
    assert row is not None, f"session {session_id} not found"
    return row


def _wait_for_row_names(
    h: UIHarness, task_id: str, expected: str, timeout_s: float = 10.0
) -> tuple[str, str]:
    """Poll BOTH rename targets until they read ``expected``.

    The rename is one UI action but two writes — ``sessions.name`` and the
    ``workspace_item_tasks.name`` half of the cascade — and the sidebar
    repaint that the test waits on is driven by the SSE broadcast that summarises
    them. Reading the tables the instant the sidebar shows the new text can
    therefore land between the two statements and report a half-applied
    rename; CI run 38436976454, shard 1/3 hit exactly that
    (``assert 'UI_MENU_ORIGINAL' == 'UI_MENU_RENAMED'``, with the sidebar
    already repainted).

    Returns ``(task_name, session_name)`` as last observed, so the caller
    keeps its own assertions and error messages: a rename that never lands
    still fails, just after this budget rather than instantly.
    """
    deadline = time.monotonic() + timeout_s
    task_name = _task_name(h, task_id)
    session_name = _session_row(h, task_id)["name"]
    while time.monotonic() < deadline and (
        task_name != expected or session_name != expected
    ):
        time.sleep(0.2)
        task_name = _task_name(h, task_id)
        session_name = _session_row(h, task_id)["name"]
    return task_name, session_name


def _seed_running_worker(h: UIHarness, session_id: str) -> None:
    """Make the chat look like it has a live agent run.

    ``workflow.zig`` calls ``updateWorker`` with ``worker_id = session_id``,
    so production rows carry the session id in BOTH ``id`` and
    ``session_id``. That matters: ``llm_history.cancelSession`` runs
    ``UPDATE worker SET cancelled = 1 WHERE id = ?``, so a row with a
    distinct id would make "Stop agent" silently match nothing.

    ``App.vue`` re-syncs ``processingState`` from ``GET /api/workers`` on
    every SSE connect, which filters on ``cancelled = 0`` — so this row is
    what puts the sidebar row into its "processing" state on page load.
    """
    with _db(h) as conn:
        cols = {r[1] for r in conn.execute("PRAGMA table_info(worker)").fetchall()}
        # `last_activity` was renamed to `last_activity_nano` by a later
        # migration; only write the columns this schema actually has.
        activity_col = "last_activity_nano" if "last_activity_nano" in cols else "last_activity"
        conn.execute(
            f"INSERT INTO worker (id, session_id, working_directory, {activity_col}, "
            "last_activity_description, cancelled) "
            "VALUES (?, ?, ?, strftime('%s','now'), 'seeded for test', 0) "
            "ON CONFLICT(id) DO UPDATE SET cancelled = 0",
            (session_id, session_id, str(h.temp_dir)),
        )
        conn.commit()


def _worker_cancelled(h: UIHarness, session_id: str) -> int:
    with _db(h) as conn:
        row = conn.execute(
            "SELECT cancelled FROM worker WHERE id = ?", (session_id,)
        ).fetchone()
    assert row is not None, f"no worker row for session {session_id}"
    return int(row[0] or 0)


# ─── Page helpers ──────────────────────────────────────────────────────────


def _collect_errors(page) -> list[str]:
    errors: list[str] = []
    page.on("console", lambda msg: errors.append(msg.text) if msg.type == "error" else None)
    page.on("pageerror", lambda exc: errors.append(str(exc)))
    return errors


def _print_errors(errors: list[str]) -> None:
    if errors:
        print("\n[console errors]")
        for e in errors:
            print(f"  - {e[:300]}")


def _boot_app(h: UIHarness, page, session_id: str, ws_name: str) -> None:
    """Open /app and wait for the chat row in the RECENT list."""
    page.goto(h.web_url("/app"), wait_until="domcontentloaded", timeout=60000)
    page.locator(f"text={ws_name}").first.wait_for(timeout=20000, state="visible")
    row = page.locator(f'[data-testid="chat-row-{session_id}"]')
    try:
        row.wait_for(timeout=5000, state="visible")
    except Exception:
        # The RECENT section can start collapsed.
        page.locator('[data-testid="recent-section-title"]').click()
        row.wait_for(timeout=15000, state="visible")


def _open_menu(page, session_id: str) -> None:
    page.locator(f'[data-testid="chat-row-{session_id}"]').click(button="right")
    page.locator('[data-testid="chat-context-menu"]').wait_for(timeout=10000, state="visible")


def _rename_via_menu(page, session_id: str, new_name: str) -> None:
    """Rename through the context menu and wait for the write to land.

    Clicking save returns as soon as the click is dispatched — the PUT has
    not necessarily left the browser yet. The handler then writes TWO rows
    (``workspace_item_tasks.name``, then ``sessions.name`` via the
    ``updateTaskName`` cascade) before it answers, so a caller that reads
    either table right after the click can observe half a rename. That is
    how ``test_rename_leaves_every_other_session_column_alone`` failed on
    CI: the task row already read ``UI_SCOPE_RENAMED`` while the
    ``sessions`` snapshot taken a moment earlier still read
    ``UI_SCOPE_CHAT``. Gating on the response makes "renamed" mean the
    server has finished rather than the click was dispatched.
    """
    _open_menu(page, session_id)
    page.locator('[data-testid="chat-context-menu-rename"]').click()
    page.locator('[data-testid="rename-modal-input"]').wait_for(timeout=10000, state="visible")
    page.locator('[data-testid="rename-modal-input"]').fill(new_name)
    with page.expect_response(
        lambda r: r.request.method == "PUT" and "/api/workspaces/tasks/" in r.url
    ) as renamed:
        page.locator('[data-testid="rename-modal-save"]').click()
    assert renamed.value.status == 200, (
        f"rename PUT answered {renamed.value.status} — the tables cannot have "
        "been updated, so every assertion after this point is meaningless"
    )


def _wait_for_unattended(
    h: UIHarness, page, session_id: str, expected: str, tries: int = 60
) -> None:
    """Poll the DB until ``is_auto_retry_until_stop`` reaches ``expected``.

    Reads the column as text: the value comes back as an int or a str
    depending on how the row was written, and comparing on type would make
    the assertion hostage to that. The sleep between polls is what gives the
    PUT + SSE round-trip time to land — a tight loop would exhaust ``tries``
    in microseconds and report a false failure.
    """
    last = None
    for _ in range(tries):
        last = _session_row(h, session_id)["is_auto_retry_until_stop"]
        if str(last) == expected:
            return
        page.wait_for_timeout(100)
    raise AssertionError(
        f"is_auto_retry_until_stop never reached {expected!r} (last value: {last!r})"
    )


# ─── 1. Rename ─────────────────────────────────────────────────────────────


def test_rename_chat_updates_task_and_session_names(ui_harness: UIHarness, page) -> None:
    """Rename must write BOTH workspace_item_tasks.name and sessions.name."""
    h = ui_harness
    task_id = _create_chat(h, "ui-chatmenu-rename-ws", "UI_MENU_AGENT", "UI_MENU_ORIGINAL")

    assert _task_name(h, task_id) == "UI_MENU_ORIGINAL"
    assert _session_row(h, task_id)["name"] == "UI_MENU_ORIGINAL"

    errors = _collect_errors(page)
    _boot_app(h, page, task_id, "ui-chatmenu-rename-ws")
    _open_menu(page, task_id)

    # The title bar must name the row that was right-clicked, otherwise the
    # user cannot tell which chat they are about to rename.
    assert page.locator('[data-testid="chat-context-menu-title"]').inner_text().strip() == (
        "UI_MENU_ORIGINAL"
    )

    page.locator('[data-testid="chat-context-menu-rename"]').click()
    page.locator('[data-testid="rename-modal-input"]').wait_for(timeout=10000, state="visible")
    page.locator('[data-testid="rename-modal-input"]').fill("UI_MENU_RENAMED")
    page.locator('[data-testid="rename-modal-save"]').click()

    try:
        # Sidebar repaints via the SSE `session_updated` broadcast that the
        # rename cascade ends in, so poll rather than sleep a fixed amount.
        page.locator(f'[data-testid="chat-row-{task_id}"]').get_by_text(
            "UI_MENU_RENAMED", exact=False
        ).wait_for(timeout=15000, state="visible")

        # The half that breaks silently: the task list still shows the old
        # name, so the kanban board and the sidebar disagree.
        #
        # Polled, not read once. The sidebar text above is driven by the SSE
        # broadcast; the two rows it summarises are written by separate
        # statements (`sessions` then the `workspace_item_tasks` half of the
        # rename cascade), so reading the tables the instant the sidebar
        # updates races the tail of the cascade and reports a half-applied
        # rename. That is exactly what CI run 38436976454, shard 1/3 saw:
        # `assert 'UI_MENU_ORIGINAL' == 'UI_MENU_RENAMED'` while the sidebar
        # had already repainted. The assertion is unchanged — a rename that
        # never reaches the task row still fails, after the same budget the
        # sidebar text is given.
        task_name, session_name = _wait_for_row_names(h, task_id, "UI_MENU_RENAMED")
        assert task_name == "UI_MENU_RENAMED", (
            "workspace_item_tasks.name was not updated — the kanban board would "
            "still show the old name"
        )
        assert session_name == "UI_MENU_RENAMED", (
            "sessions.name was not updated — the chat header would still show "
            "the old name"
        )
    finally:
        _print_errors(errors)


# ─── 2. Stop agent ─────────────────────────────────────────────────────────


def test_stop_agent_hidden_on_idle_chat(ui_harness: UIHarness, page) -> None:
    """An idle chat must not offer to stop anything."""
    h = ui_harness
    task_id = _create_chat(h, "ui-chatmenu-idle-ws", "UI_IDLE_AGENT", "UI_IDLE_CHAT")

    errors = _collect_errors(page)
    _boot_app(h, page, task_id, "ui-chatmenu-idle-ws")
    _open_menu(page, task_id)
    try:
        assert page.locator('[data-testid="chat-context-menu-stop"]').count() == 0, (
            "Stop agent is offered on an idle chat — picking it would POST a "
            "stop for a run that never existed"
        )
    finally:
        _print_errors(errors)


def test_stop_agent_cancels_the_running_worker(ui_harness: UIHarness, page) -> None:
    """With a live worker, Stop agent appears and cancels the run."""
    h = ui_harness
    task_id = _create_chat(h, "ui-chatmenu-stop-ws", "UI_STOP_AGENT", "UI_STOP_CHAT")
    _seed_running_worker(h, task_id)
    assert _worker_cancelled(h, task_id) == 0

    errors = _collect_errors(page)
    _boot_app(h, page, task_id, "ui-chatmenu-stop-ws")
    _open_menu(page, task_id)

    try:
        stop = page.locator('[data-testid="chat-context-menu-stop"]')
        stop.wait_for(timeout=10000, state="visible")
        assert "Stop agent" in stop.inner_text()
        stop.click()

        # The endpoint answers 200 unconditionally, so asserting the
        # response would prove nothing. Assert the flag it is supposed to
        # set: `UPDATE worker SET cancelled = 1 WHERE id = ?`.
        for _ in range(60):
            if _worker_cancelled(h, task_id) == 1:
                break
            page.wait_for_timeout(100)
        assert _worker_cancelled(h, task_id) == 1, (
            "Stop agent did not set worker.cancelled — the run would keep going"
        )
    finally:
        _print_errors(errors)


# ─── 3. Unattended mode ────────────────────────────────────────────────────


def test_unattended_toggle_persists_without_clearing_the_profile(
    ui_harness: UIHarness, page
) -> None:
    """Toggle unattended on, and prove the model profile survives it."""
    h = ui_harness
    task_id = _create_chat(
        h, "ui-chatmenu-unattended-ws", "UI_UNATTENDED_AGENT", "UI_UNATTENDED_CHAT"
    )

    # Give the chat a model profile so the assertion below has something to
    # lose. The list response carries `selected_profile_model`, and the PUT
    # body always includes that field — empty means CLEAR server-side.
    h.http(
        "PUT",
        f"/api/llm/session/{task_id}",
        json_body={"selected_profile_model": "ui-test-profile"},
        expect=200,
    )
    assert _session_row(h, task_id)["selected_profile_model"] == "ui-test-profile"
    # The column reads back as an int or a str depending on how the row was
    # written, so compare on the text form rather than on type.
    assert str(_session_row(h, task_id)["is_auto_retry_until_stop"]) == "0"

    errors = _collect_errors(page)
    _boot_app(h, page, task_id, "ui-chatmenu-unattended-ws")
    _open_menu(page, task_id)

    try:
        toggle = page.locator('[data-testid="chat-context-menu-unattended"]')
        assert "Turn on unattended mode" in toggle.inner_text(), (
            "the label must state the ACTION — a static label leaves the user "
            "guessing whether the pick turns the flag on or off"
        )
        toggle.click()
        _wait_for_unattended(h, page, task_id, "1")

        assert str(_session_row(h, task_id)["is_auto_retry_until_stop"]) == "1", (
            "unattended mode was not persisted"
        )
        # The landmine. `api.updateSession` sends selected_profile_model on
        # every call and the server treats '' as clear, so a toggle that
        # forgets to send the current value back silently resets the chat
        # to the default model.
        assert _session_row(h, task_id)["selected_profile_model"] == "ui-test-profile", (
            "toggling unattended mode CLEARED selected_profile_model — the chat "
            "fell back to the default model"
        )
    finally:
        _print_errors(errors)


def test_unattended_label_reflects_state_after_toggle(ui_harness: UIHarness, page) -> None:
    """Reopening the menu shows the flipped label, proving state round-trips."""
    h = ui_harness
    task_id = _create_chat(h, "ui-chatmenu-unatt-label-ws", "UI_LABEL_AGENT", "UI_LABEL_CHAT")

    errors = _collect_errors(page)
    _boot_app(h, page, task_id, "ui-chatmenu-unatt-label-ws")

    try:
        _open_menu(page, task_id)
        page.locator('[data-testid="chat-context-menu-unattended"]').click()
        _wait_for_unattended(h, page, task_id, "1")

        _open_menu(page, task_id)
        toggle = page.locator('[data-testid="chat-context-menu-unattended"]')
        assert "Turn off unattended mode" in toggle.inner_text(), (
            "the menu still offers to turn unattended ON after it is on — the "
            "row is reading a stale value instead of server truth"
        )
    finally:
        _print_errors(errors)


# ─── Regression guard ──────────────────────────────────────────────────────


def test_unattended_toggle_off_returns_to_zero(ui_harness: UIHarness, page) -> None:
    """The OFF direction is a separate code path (`next = '0'`) — test it.

    The profile landmine is symmetric: turning the flag off also routes
    through ``api.updateSession``, so an implementation that only handled
    the ON direction (or that reads the profile from a stale snapshot)
    would clear ``selected_profile_model`` here while passing the ON test.
    """
    h = ui_harness
    task_id = _create_chat(
        h, "ui-chatmenu-unatt-off-ws", "UI_UNATT_OFF_AGENT", "UI_UNATT_OFF_CHAT"
    )
    h.http(
        "PUT",
        f"/api/llm/session/{task_id}",
        json_body={"selected_profile_model": "ui-test-profile"},
        expect=200,
    )

    errors = _collect_errors(page)
    _boot_app(h, page, task_id, "ui-chatmenu-unatt-off-ws")

    try:
        # ON
        _open_menu(page, task_id)
        page.locator('[data-testid="chat-context-menu-unattended"]').click()
        _wait_for_unattended(h, page, task_id, "1")

        # OFF — reopen, and the label must offer the reverse action.
        _open_menu(page, task_id)
        toggle = page.locator('[data-testid="chat-context-menu-unattended"]')
        assert "Turn off unattended mode" in toggle.inner_text()
        toggle.click()
        _wait_for_unattended(h, page, task_id, "0")

        assert str(_session_row(h, task_id)["is_auto_retry_until_stop"]) == "0", (
            "turning unattended mode OFF did not persist"
        )
        assert _session_row(h, task_id)["selected_profile_model"] == "ui-test-profile", (
            "turning unattended mode OFF CLEARED selected_profile_model"
        )
    finally:
        _print_errors(errors)


def test_rename_leaves_every_other_session_column_alone(ui_harness: UIHarness, page) -> None:
    """Rename must touch ``sessions.name`` and nothing else.

    ``api.updateSession`` would satisfy a name-only assertion while also
    clearing the model profile and re-stamping ``updated_at`` — so this
    compares the whole row before and after, not just the name.
    """
    h = ui_harness
    task_id = _create_chat(h, "ui-chatmenu-rename-scope-ws", "UI_SCOPE_AGENT", "UI_SCOPE_CHAT")
    h.http(
        "PUT",
        f"/api/llm/session/{task_id}",
        json_body={"selected_profile_model": "ui-test-profile"},
        expect=200,
    )
    with _db(h) as conn:
        conn.execute(
            "UPDATE sessions SET is_auto_retry_until_stop = '1', "
            "updated_at = '2001-02-03 04:05:06' WHERE id = ?",
            (task_id,),
        )
        conn.commit()

    before = dict(_session_row(h, task_id))

    errors = _collect_errors(page)
    _boot_app(h, page, task_id, "ui-chatmenu-rename-scope-ws")
    _rename_via_menu(page, task_id, "UI_SCOPE_RENAMED")

    try:
        after = dict(_session_row(h, task_id))
        # The task row is the other half of the rename contract.
        assert _task_name(h, task_id) == "UI_SCOPE_RENAMED"

        drift = {
            col: (before[col], after[col])
            for col in before
            if col != "name" and before[col] != after[col]
        }
        assert not drift, (
            "rename changed session columns it should not have touched: "
            + ", ".join(f"{c}: {old!r} -> {new!r}" for c, (old, new) in drift.items())
        )
        assert after["name"] == "UI_SCOPE_RENAMED"
    finally:
        _print_errors(errors)


def test_rename_does_not_move_the_row_to_the_top(ui_harness: UIHarness, page) -> None:
    """Rename must not bump sessions.updated_at.

    The sidebar sorts RECENT by ``updated_at``. The naive rename path
    (``api.updateSession``) writes ``selected_profile_model`` on every call,
    and that write carries ``updated_at = CURRENT_TIMESTAMP`` — so renaming
    one chat would jump it to the top of the list.
    """
    h = ui_harness
    ws_id = _create_workspace(h, "ui-chatmenu-order-ws")
    agent_id = _create_agent(h, ws_id, "UI_ORDER_AGENT")
    older = _create_task(h, ws_id, agent_id, "UI_ORDER_OLDER")
    newer = _create_task(h, ws_id, agent_id, "UI_ORDER_NEWER")
    # Both need a `sessions` row or neither is listed in RECENT at all.
    _seed_matching_session(h, older, "UI_ORDER_OLDER")
    _seed_matching_session(h, newer, "UI_ORDER_NEWER")

    # Make `newer` unambiguously the most recent.
    with _db(h) as conn:
        conn.execute(
            "UPDATE sessions SET updated_at = '2999-01-01 00:00:00' WHERE id = ?", (newer,)
        )
        conn.execute(
            "UPDATE sessions SET updated_at = '2000-01-01 00:00:00' WHERE id = ?", (older,)
        )
        conn.commit()

    errors = _collect_errors(page)
    _boot_app(h, page, newer, "ui-chatmenu-order-ws")

    try:
        _rename_via_menu(page, older, "UI_ORDER_RENAMED")

        page.locator(f'[data-testid="chat-row-{older}"]').get_by_text(
            "UI_ORDER_RENAMED", exact=False
        ).wait_for(timeout=15000, state="visible")

        assert _session_row(h, older)["updated_at"].startswith("2000-01-01"), (
            "rename bumped sessions.updated_at, so the renamed chat jumps to the "
            "top of a list sorted by it"
        )
    finally:
        _print_errors(errors)