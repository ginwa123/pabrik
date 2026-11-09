"""Typing `/` in the composer opens the slash command menu, and it filters as you type.

Why this suite exists
---------------------
The composer already had two single-row hints — one for `/skill-`, one for `/tool-` — and
`/files-` had none at all. A bare `/` opened nothing, so the only way to discover the commands
was to guess them. The fix replaces both hints with one menu that a bare `/` opens and that
narrows as the user types.

jsdom can prove the state machine (``FileInput.slashMenu.spec.ts``) but not the painted result:
the composer sits at the BOTTOM of the window, so a menu that renders above it can run off the
top of the pane, and a menu that renders below it can run off the bottom. This suite drives the
real app (Vite + pabrik + headless Chromium) and asserts both the behaviour and the geometry.

Run (the frontend is served from THIS worktree; the backend binary may come from anywhere since
only frontend code is under test):

    PABRIK_BIN=/path/to/zig-out/bin/pabrikcore-linux-x86_64 \\
        /tmp/pabrik-ui-venv/bin/python -m pytest -s \\
        tests/functional_ui/chatview_slash_command_menu_ui_test.py -v
"""

from __future__ import annotations

from typing import Any

from chatview_boot import bind_session_workspace, create_workspace, open_chatview, seed_db_path
from db_seed import DbSeed

#: The composer's textarea, and the menu a bare `/` opens.
TEXTAREA = '[data-testid="chat-message-textarea"]'
MENU = '[data-testid="slash-command-menu"]'
SKILL_PICKER = '[data-testid="skill-picker-list"]'
SEND_BUTTON = "[data-testid='send-message-button']"

#: The three commands the menu must offer, in order.
COMMANDS = ["/skill-", "/tool-", "/files-"]

#: Sub-pixel layout: a menu flush with the pane edge is fine.
SLACK_PX = 2

#: A pane tall enough that the composer is not itself the whole window.
VIEWPORT = {"width": 1280, "height": 900}


def _open_chat(h: Any, page: Any, session_id: str) -> None:
    """Boot a workspace + a session whose entity renders the real composer."""
    workspace_id = create_workspace(h, name="slash-menu-ws")
    seed = DbSeed(seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Slash menu")
        bind_session_workspace(conn, workspace_id, session_id)
        seed.seed_user_message(conn, session_id, "hello")
    page.set_viewport_size(VIEWPORT)
    open_chatview(page, h, workspace_id, session_id, timeout_ms=60000)
    # The textarea is `:disabled` until the session resolves.
    page.wait_for_function(
        f"() => {{ const t = document.querySelector('{TEXTAREA}');"
        " return !!t && !t.disabled; }",
        timeout=30000,
    )
    page.wait_for_selector(SEND_BUTTON, timeout=30000)


def _type(page: Any, text: str) -> None:
    """Replace the composer's text. Callers wait for the menu themselves.

    The menu opens after a 100 ms debounce, so there is no "the debounce
    has elapsed" signal to wait on — a quiet-window heuristic can return
    during the quiet period, before the menu has reacted. Each caller
    therefore waits for the exact row set it expects.
    """
    page.locator(TEXTAREA).first.fill(text)


def _wait_for_rows(page: Any, expected: list[str], timeout_ms: int = 10000) -> None:
    """Wait until the menu lists exactly ``expected``, in order."""
    page.wait_for_function(
        "(exp) => {"
        f"  const m = document.querySelector('{MENU}');"
        "  const rows = m ? [...m.querySelectorAll('button')].map((b) => b.textContent.trim()) : [];"
        "  return rows.length === exp.length && exp.every((e, i) => rows[i].includes(e));"
        "}",
        arg=expected,
        timeout=timeout_ms,
    )


def _wait_for_menu_closed(page: Any, timeout_ms: int = 10000) -> None:
    page.wait_for_function(
        f"() => !document.querySelector('{MENU}')", timeout=timeout_ms
    )


def _wait_for_textarea(page: Any, value: str, timeout_ms: int = 10000) -> None:
    page.wait_for_function(
        "(v) => {"
        f"  const t = document.querySelector('{TEXTAREA}');"
        "  return !!t && t.value === v;"
        "}",
        arg=value,
        timeout=timeout_ms,
    )


def _menu_rows(page: Any) -> list[str]:
    return page.eval_on_selector_all(
        f"{MENU} button", "els => els.map(e => e.textContent.trim())"
    )


def _menu_geometry(page: Any) -> dict:
    g = page.evaluate(
        r"""
() => {
  const menu = document.querySelector('[data-testid="slash-command-menu"]');
  if (!menu) return null;
  const r = menu.getBoundingClientRect();
  return {
    top: r.top, bottom: r.bottom, left: r.left, right: r.right,
    width: r.width, height: r.height,
    viewportWidth: window.innerWidth,
    viewportHeight: window.innerHeight,
    rows: menu.querySelectorAll('button').length,
  };
}
"""
    )
    assert g is not None, "the slash command menu is not in the DOM"
    return g


def test_a_bare_slash_opens_the_menu_with_all_three_commands(ui_harness, page) -> None:
    _open_chat(ui_harness, page, "sess-slash-open")
    _type(page, "/")
    _wait_for_rows(page, COMMANDS)

    rows = _menu_rows(page)
    print(f"\n[slash-menu] rows: {rows}")
    assert len(rows) == 3, f"a bare `/` must list all three commands, got {rows}"
    for command in COMMANDS:
        assert any(command in row for row in rows), f"{command} is missing from {rows}"


def test_the_menu_stays_inside_the_window(ui_harness, page) -> None:
    """The composer is at the bottom of the pane, so the menu must not run off an edge."""
    _open_chat(ui_harness, page, "sess-slash-geometry")
    _type(page, "/")
    _wait_for_rows(page, COMMANDS)
    g = _menu_geometry(page)
    print(f"\n[slash-menu] geometry: {g}")

    assert g["rows"] == 3, f"the geometry sample needs the full menu: {g}"
    assert g["width"] > 0 and g["height"] > 0, f"the menu has no painted box: {g}"
    assert g["top"] >= -SLACK_PX, f"the menu runs off the top of the window: {g}"
    assert g["bottom"] <= g["viewportHeight"] + SLACK_PX, (
        f"the menu runs off the bottom of the window: {g}"
    )
    assert g["left"] >= -SLACK_PX, f"the menu runs off the left of the window: {g}"
    assert g["right"] <= g["viewportWidth"] + SLACK_PX, (
        f"the menu runs off the right of the window: {g}"
    )


def test_typing_letters_narrows_the_menu(ui_harness, page) -> None:
    _open_chat(ui_harness, page, "sess-slash-filter")
    _type(page, "/")
    _wait_for_rows(page, COMMANDS)

    _type(page, "/sk")
    _wait_for_rows(page, ["/skill-"])
    rows = _menu_rows(page)
    assert len(rows) == 1 and "/skill-" in rows[0], f"`/sk` must narrow to /skill-: {rows}"

    _type(page, "/f")
    _wait_for_rows(page, ["/files-"])
    rows = _menu_rows(page)
    assert len(rows) == 1 and "/files-" in rows[0], f"`/f` must narrow to /files-: {rows}"

    _type(page, "/t")
    _wait_for_rows(page, ["/tool-"])
    rows = _menu_rows(page)
    assert len(rows) == 1 and "/tool-" in rows[0], f"`/t` must narrow to /tool-: {rows}"


def test_a_prefix_that_matches_nothing_closes_the_menu(ui_harness, page) -> None:
    _open_chat(ui_harness, page, "sess-slash-nomatch")
    _type(page, "/")
    _wait_for_rows(page, COMMANDS)

    _type(page, "/z")
    _wait_for_menu_closed(page)
    assert page.locator(MENU).count() == 0, "`/z` matches no command, so the menu must close"


def test_escape_dismisses_the_menu_and_keeps_the_text(ui_harness, page) -> None:
    _open_chat(ui_harness, page, "sess-slash-escape")
    _type(page, "/")
    _wait_for_rows(page, COMMANDS)

    page.keyboard.press("Escape")
    _wait_for_menu_closed(page)

    assert page.locator(MENU).count() == 0, "Escape must dismiss the menu"
    assert page.locator(TEXTAREA).first.input_value() == "/", "Escape must not edit the text"


def test_enter_completes_the_highlighted_command_and_opens_its_picker(ui_harness, page) -> None:
    _open_chat(ui_harness, page, "sess-slash-enter")
    _type(page, "/")
    _wait_for_rows(page, COMMANDS)

    page.keyboard.press("Enter")
    _wait_for_textarea(page, "/skill-")
    _wait_for_menu_closed(page)

    assert page.locator(TEXTAREA).first.input_value() == "/skill-", (
        "Enter on the first row must complete the token to /skill-"
    )
    assert page.locator(MENU).count() == 0, "the menu must close once a command is accepted"
    page.wait_for_selector(SKILL_PICKER, timeout=10000)


def test_arrow_down_then_enter_completes_the_second_command(ui_harness, page) -> None:
    _open_chat(ui_harness, page, "sess-slash-arrow")
    _type(page, "/")
    _wait_for_rows(page, COMMANDS)

    page.keyboard.press("ArrowDown")
    page.keyboard.press("Enter")
    _wait_for_textarea(page, "/tool-")

    assert page.locator(TEXTAREA).first.input_value() == "/tool-", (
        "ArrowDown then Enter must complete the second row, /tool-"
    )


def test_enter_on_the_menu_never_sends_the_message(ui_harness, page) -> None:
    _open_chat(ui_harness, page, "sess-slash-nosend")
    _type(page, "/")
    _wait_for_rows(page, COMMANDS)

    page.keyboard.press("Enter")
    _wait_for_textarea(page, "/skill-")

    assert page.locator(TEXTAREA).first.input_value() == "/skill-", (
        "Enter must complete the command, not send the message"
    )
