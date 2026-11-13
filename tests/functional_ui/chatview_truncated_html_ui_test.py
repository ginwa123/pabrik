"""Functional UI test: a reply cut off inside a raw-text element keeps its tail on screen.

The transcript renders an assistant turn with ``marked`` + ``v-html``. When the
model writes a raw-text element — ``<style>``, ``<script>``, ``<textarea>``,
``<title>`` — or an ``<!--`` comment, and the reply ends before its end tag, the
HTML parser reads on as text to the matching end tag. The reply visibly stops at
the opener, and there is nothing to expand because the text is still in the DOM
— as that element's own text — and paints nowhere.

The payload below is the shape that produced the report: an ``<html>`` block
whose ``<style>`` never closes, so ``hasRichBlocks`` is false (an unclosed tag
does not count) and the turn falls through to the markdown path.

Run:
    PABRIK_BIN=./zig-out/bin/pabrikcore-linux-x86_64 \\
        python3 -m pytest tests/functional_ui/chatview_truncated_html_ui_test.py -v
"""

from __future__ import annotations

import pytest

from chatview_boot import (
    bind_session_workspace,
    create_workspace,
    open_chatview,
    seed_db_path,
)
from db_seed import DbSeed
from ui_harness import UIHarness

HEADING = "Here is the audit."
TAIL = "the tail the user could not reach"

TRUNCATED_REPORT = "\n".join(
    [
        HEADING,
        "",
        "<html>",
        "<style>",
        ".card{color:#c5c9c5}",
        ".row{margin:0}",
        "",
        "Card in review. Nothing pushed; both working trees only.",
        TAIL,
    ]
)


def _seed(h: UIHarness, workspace_id: str, session_id: str, reply: str) -> None:
    seed = DbSeed(seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Truncated reply")
        bind_session_workspace(conn, workspace_id, session_id)
        seed.seed_user_message(conn, session_id, "audit the split bill flow")
        seed.seed_assistant_message(conn, session_id, reply)


@pytest.mark.parametrize(
    "reply,marker",
    [
        (TRUNCATED_REPORT, TAIL),
        ("Here is the audit.\n\n<!-- still writing\n\n" + TAIL, TAIL),
        ("Here is the audit.\n\n<textarea>" + TAIL, TAIL),
    ],
    ids=["unclosed-style-in-html-block", "unclosed-comment", "unclosed-textarea"],
)
def test_a_cut_off_reply_keeps_its_tail_readable(
    page, ui_harness: UIHarness, reply: str, marker: str
) -> None:
    """The text after an opener the model never closed is on screen, not swallowed."""
    h = ui_harness
    session_id = "sess_truncated_html"
    workspace_id = create_workspace(h)
    _seed(h, workspace_id, session_id, reply)

    page.set_viewport_size({"width": 1440, "height": 900})
    open_chatview(page, h, workspace_id, session_id)
    page.locator(f"text={HEADING}").first.wait_for(timeout=15000, state="visible")

    on_screen = page.locator(".assistant-item-body").first.inner_text()
    assert marker in on_screen, on_screen


def test_a_complete_report_still_keeps_its_look(page, ui_harness: UIHarness) -> None:
    """A closed ``<style>`` is still a style element, so a finished report is unchanged."""
    h = ui_harness
    session_id = "sess_complete_html"
    workspace_id = create_workspace(h)
    reply = "Here is the audit.\n\n<style>.card{color:red}</style>\n\nDone and closed."
    _seed(h, workspace_id, session_id, reply)

    page.set_viewport_size({"width": 1440, "height": 900})
    open_chatview(page, h, workspace_id, session_id)

    page.locator("text=Done and closed.").first.wait_for(timeout=15000, state="visible")
    assert page.locator(".assistant-item-body style").count() == 1
