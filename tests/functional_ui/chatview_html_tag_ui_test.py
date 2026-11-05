"""DB-seeded Playwright tests for the chatview's ``<html>`` wrapper tag.

Feature (2026-08-23 html-tag-support): the LLM can wrap raw HTML in
``<html>...</html>``; the chatview renders each block as a live
sandboxed iframe (``sandbox="allow-scripts allow-forms"``, null origin)
instead of markdown. ``allow-forms`` is what lets an interactive block submit a
form; ``allow-same-origin`` must never be added. Any text outside the tags still renders as markdown.

Each test:

1. Boots a fresh pabrik + Vite via the ``ui_harness`` fixture.
2. Seeds ``sessions`` + ``llm_history`` rows whose ``response_content``
   carries the raw tagged string — the exact wire shape production
   stores (tags included).
3. Drives headless Chromium at
   ``<vite_url>/app/<workspace_id>/chat/<id>`` and asserts the rendered
   DOM.

Real Chromium (unlike jsdom vitest) EXECUTES iframe srcdoc content —
that's the point of tests 2 and 3: we prove scripts run inside the
sandbox and clicks land, not just that an iframe tag exists.

Plan: docs/superpowers/plans/2026-08-23-html-tag-support.md (Task 4)
"""

from __future__ import annotations

from pathlib import Path

from chatview_boot import (
    bind_session_workspace,
    create_workspace,
    open_chatview,
)
from db_seed import DbSeed
from ui_harness import UIHarness


# ─── Helpers ────────────────────────────────────────────────────────────────


def _seed_db_path(h: UIHarness) -> Path:
    """Path to the harness's isolated agent.db (DbSeed re-validates)."""
    return h.temp_dir / ".config" / "pabrik" / "agent.db"


def _wait_for_text(page, text: str, timeout_ms: int = 10000) -> None:
    """Wait for ``text`` anywhere in the DOM (attached — VirtualScroller
    may keep off-viewport messages out of the visible window)."""
    page.locator(f"text={text}").first.wait_for(timeout=timeout_ms, state="attached")


# ─── Test 1: html-only assistant message renders a sandboxed iframe ────────


def test_html_only_message_renders_sandboxed_iframe(
    ui_harness: UIHarness, page,
) -> None:
    """An assistant row of just ``<html>...</html>`` renders one iframe
    with sandbox="allow-scripts" and NO markdown wrapper around it."""
    h = ui_harness
    session_id = "sess_html_tag_iframe_001"
    workspace_id = create_workspace(h)
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "HTML tag")
        bind_session_workspace(conn, workspace_id, session_id)
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(
            conn, session_id, "show me a button", created_at=ts[0],
        )
        seed.seed_assistant_message(
            conn, session_id,
            "<html><button id=\"probe-btn\">Click me</button></html>",
            created_at=ts[1],
        )

    open_chatview(page, h, workspace_id, session_id)

    # The iframe appears with the security contract intact.
    page.wait_for_selector("iframe.chat-html-frame", timeout=15000)
    frame_el = page.locator("iframe.chat-html-frame").first
    sandbox = frame_el.get_attribute("sandbox")
    assert sandbox == "allow-scripts allow-forms", (
        f"Expected sandbox='allow-scripts allow-forms', got {sandbox!r}. "
        f"allow-forms is what lets an interactive block submit; "
        f"allow-same-origin would break the null-origin security boundary."
    )
    # The inner payload must NOT ALSO render as markdown inside the
    # assistant item. (The group container itself carries the
    # .markdown-content class by design — paragraph mode — so assert on
    # the assistant-item's inner HTML instead of the page-wide count.)
    item_html = page.locator(".assistant-item").first.inner_html()
    assert ".markdown-content" not in item_html, (
        "html-only message should render via iframe, not markdown"
    )
    assert "<button" not in item_html, (
        "raw html payload leaked into the DOM outside the iframe srcdoc"
    )


# ─── Test 2: inner HTML actually executes inside the sandbox ───────────────


def test_html_block_scripts_execute_inside_sandbox(
    ui_harness: UIHarness, page,
) -> None:
    """The iframe's srcdoc content is LIVE: the button renders, is
    clickable, and its onclick handler runs (sets document.title).

    This is the real-Chromium advantage — jsdom never executes srcdoc.
    """
    h = ui_harness
    session_id = "sess_html_tag_exec_001"
    workspace_id = create_workspace(h)
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "HTML exec")
        bind_session_workspace(conn, workspace_id, session_id)
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(conn, session_id, "make it interactive", created_at=ts[0])
        seed.seed_assistant_message(
            conn, session_id,
            "<html>"
            "<button id=\"probe-btn\" onclick=\"document.title='CLICKED'\">Click me</button>"
            "</html>",
            created_at=ts[1],
        )

    open_chatview(page, h, workspace_id, session_id)
    page.wait_for_selector("iframe.chat-html-frame", timeout=15000)

    # Reach INTO the frame (frame_locator works on sandboxed frames for
    # DOM queries) and click the button.
    frame = page.frame_locator("iframe.chat-html-frame")
    btn = frame.locator("#probe-btn")
    btn.wait_for(timeout=10000)
    assert btn.inner_text() == "Click me"
    btn.click()

    # The onclick handler ran → document.title changed inside the frame.
    # Playwright's Frame object can read the title same-process even for
    # null-origin frames (the sandbox restricts the PAGE's access, not
    # the automation protocol). Poll briefly — srcdoc script execution
    # is async relative to the click returning.
    child_frames = [f for f in page.frames if f != page.main_frame]
    assert child_frames, "expected at least one child frame"
    title = ""
    for _ in range(20):  # up to ~2s
        title = child_frames[0].title()
        if title == "CLICKED":
            break
        page.wait_for_timeout(100)
    assert title == "CLICKED", (
        f"Expected onclick to set frame title to 'CLICKED', got {title!r}. "
        f"Scripts did not execute inside the sandboxed iframe."
    )


# ─── Test 2b: an interactive form fires its submit event ───────────────────


def test_html_block_form_submit_fires_inside_sandbox(
    ui_harness: UIHarness, page,
) -> None:
    """Typing into the block and submitting its form runs the page's own
    ``submit`` handler with the typed value.

    ``allow-forms`` is the flag that makes this work: measured in real
    Chromium, WITHOUT it ``requestSubmit()`` does not even dispatch the
    event, so an interactive widget built around a ``<form>`` is dead in
    the transcript. The handler writes the value into the frame's title,
    which proves both halves — the keystrokes landed AND the submit
    handler ran.
    """
    h = ui_harness
    session_id = "sess_html_tag_form_001"
    workspace_id = create_workspace(h)
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "HTML form")
        bind_session_workspace(conn, workspace_id, session_id)
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(conn, session_id, "a form please", created_at=ts[0])
        seed.seed_assistant_message(
            conn, session_id,
            "<html>"
            '<form id="probe-form" onsubmit="event.preventDefault();'
            "document.title='SUBMIT:'+document.getElementById('probe-in').value"
            '">'
            '<input id="probe-in">'
            '<button id="probe-sub" type="submit">Go</button>'
            "</form>"
            "</html>",
            created_at=ts[1],
        )

    open_chatview(page, h, workspace_id, session_id)
    page.wait_for_selector("iframe.chat-html-frame", timeout=15000)

    frame = page.frame_locator("iframe.chat-html-frame")
    field = frame.locator("#probe-in")
    field.wait_for(timeout=10000)
    field.fill("prod-42")
    frame.locator("#probe-sub").click()

    child_frames = [f for f in page.frames if f != page.main_frame]
    assert child_frames, "expected at least one child frame"
    title = ""
    for _ in range(20):  # up to ~2s
        title = child_frames[0].title()
        if title.startswith("SUBMIT:"):
            break
        page.wait_for_timeout(100)
    assert title == "SUBMIT:prod-42", (
        f"Expected the form's submit handler to run with the typed value, got "
        f"{title!r}. Without `allow-forms` the submit event never fires."
    )


# ─── Test 3: mixed message — surrounding markdown + html block ─────────────


def test_mixed_markdown_and_html_block_render_together(
    ui_harness: UIHarness, page,
) -> None:
    """Text outside <html> tags renders as markdown; the block itself
    renders as an iframe whose srcdoc carries the inner HTML."""
    h = ui_harness
    session_id = "sess_html_tag_mixed_001"
    workspace_id = create_workspace(h)
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Mixed")
        bind_session_workspace(conn, workspace_id, session_id)
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(conn, session_id, "widget please", created_at=ts[0])
        seed.seed_assistant_message(
            conn, session_id,
            "Here is **your** widget:\n<html><b>live bold</b></html>\nEnjoy!",
            created_at=ts[1],
        )

    open_chatview(page, h, workspace_id, session_id)

    # Surrounding markdown still renders (bold from ** **).
    _wait_for_text(page, "Here is your widget:")
    assert page.locator(".markdown-content strong").count() > 0, (
        "markdown outside the html block should still render via marked"
    )

    # The iframe exists and its srcdoc contains the inner payload.
    page.wait_for_selector("iframe.chat-html-frame", timeout=15000)
    srcdoc = page.locator("iframe.chat-html-frame").first.get_attribute("srcdoc") or ""
    assert "live bold" in srcdoc, (
        f"srcdoc should carry the inner html payload, got: {srcdoc[:200]!r}"
    )


# ─── Test 4: legacy messages untouched (regression guard) ──────────────────


def test_legacy_markdown_messages_render_without_iframe(
    ui_harness: UIHarness, page,
) -> None:
    """A plain markdown assistant message renders exactly as before —
    zero chat-html-frame iframes on the page."""
    h = ui_harness
    session_id = "sess_html_tag_legacy_001"
    workspace_id = create_workspace(h)
    seed = DbSeed(_seed_db_path(h))
    md_text = "# Heading\n\nSome **bold** text.\n"
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Legacy")
        bind_session_workspace(conn, workspace_id, session_id)
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(conn, session_id, "tell me things", created_at=ts[0])
        seed.seed_assistant_message(conn, session_id, md_text, created_at=ts[1])

    open_chatview(page, h, workspace_id, session_id)
    page.wait_for_selector(".markdown-content h1", timeout=15000)
    assert page.locator(".markdown-content h1").inner_text() == "Heading"
    assert page.locator("iframe.chat-html-frame").count() == 0, (
        "legacy markdown messages must NOT produce iframes"
    )


# ─── Test 5: unclosed <html> degrades safely (no crash, no iframe) ─────────


def test_unclosed_html_tag_degrades_safely(ui_harness: UIHarness, page) -> None:
    """Mid-stream the close tag hasn't arrived yet. The regex requires a
    closed pair, so the raw text falls through to the legacy path — no
    iframe, no crash, no console error blowing up the page."""
    h = ui_harness
    session_id = "sess_html_tag_unclosed_001"
    workspace_id = create_workspace(h)
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Unclosed")
        bind_session_workspace(conn, workspace_id, session_id)
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(conn, session_id, "go", created_at=ts[0])
        seed.seed_assistant_message(
            conn, session_id,
            "<html><div>never closed",
            created_at=ts[1],
        )

    errors: list[str] = []
    page.on("pageerror", lambda exc: errors.append(str(exc)))

    open_chatview(page, h, workspace_id, session_id)
    # The raw text shows through the legacy path (escaped by marked).
    _wait_for_text(page, "never closed", timeout_ms=15000)
    assert page.locator("iframe.chat-html-frame").count() == 0, (
        "unclosed <html> must not produce an iframe"
    )
    # No uncaught page errors from the render path.
    assert not errors, f"page errors during unclosed-tag render: {errors}"


# ─── Frame height: the report must describe the CONTENT, not the viewport ───
#
# 2026-11-03 (task_1793689343828): a long `<html>` report rendered as a ~150px
# slab — the transcript showed the card's heading and the first lines of its
# columns, and the rest was unreachable: the frame has no scrollbar (by design,
# #574) and no expand affordance. Two payload shapes triggered it, both because
# the frame's own viewport leaked into the height it reports about itself:
#
#   * percentage heights (`html,body{height:100%}` + a `flex:1;overflow:hidden`
#     grid) resolve AGAINST the frame, so every document metric equalled the
#     frame's current height and the report described the viewport, not the
#     content — a self-consistent 120px frame over ~600px of content.
#   * `min-height:100vh` grows with the frame, so each report raised the frame,
#     which raised the report: a ratchet that reached 16k px and was still
#     climbing when the tab closed.
#
# The fix makes the report the body's CONTENT box and pins
# `html{height:auto!important}` in the frame shell, so the frame's height can
# never be an input to its own layout.


def _report_payload(body_css: str, *, wrap: str = "", rows: int = 14) -> str:
    """A 3-column report card — the shape a real answer takes — plus the
    viewport-coupled CSS under test wrapped around it."""
    table_rows = "".join(
        f"<tr><td>invoice {1000 + i}</td><td>5,000,000</td>"
        f"<td>{i * 137:,}</td><td>line {i}</td></tr>"
        for i in range(rows)
    )
    columns = "".join(
        f'<div class="col"><div class="col-h">{title}</div>'
        f"<table><tbody>{table_rows}</tbody></table></div>"
        for title in ("AS BILLING SENDS IT TODAY", "WITH INVOICE_ID OMITTED", "AFTER SPLIT")
    )
    inner = (
        '<div class="hdr">LOCAL-ONLY PROOF · BILLING PAYLOAD → REFERENCE CONSUMER</div>'
        '<div class="hero" style="font-size:28px">Our real message, their real model</div>'
        f'<div class="cols">{columns}</div>'
    )
    body = f'<div class="{wrap}">{inner}</div>' if wrap else inner
    return (
        "<style>"
        ".cols{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}"
        ".col{padding:8px;border:1px solid #282727}"
        "table{width:100%;border-collapse:collapse;font-size:11px}"
        "td{border:1px solid #282727;padding:3px 6px}"
        ".col-h{font:11px monospace;margin-bottom:6px}"
        f"{body_css}"
        "</style>" + body
    )


def _seed_report_message(h: UIHarness, session_id: str, workspace_id: str, payload: str) -> None:
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Frame height")
        bind_session_workspace(conn, workspace_id, session_id)
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(conn, session_id, "show me the report", created_at=ts[0])
        seed.seed_assistant_message(
            conn, session_id, f"<html>{payload}</html>", created_at=ts[1],
        )


def _frame_height(page) -> float:
    """The rendered height of the chat's `<html>` frame, in page pixels."""
    return float(
        page.locator("iframe.chat-html-frame").first.evaluate(
            "el => el.getBoundingClientRect().height"
        )
    )


def _settled_frame_height(page, *, deadline_ms: int = 8000) -> float:
    """Poll the frame height until two reads 250 ms apart agree.

    Nothing is awaited on a fixed budget: the report arrives by postMessage and
    may be re-sent when the frame re-lays-out, so the test waits for the value
    to stop moving instead of guessing how long that takes."""
    previous = _frame_height(page)
    waited = 0
    while waited < deadline_ms:
        page.wait_for_timeout(250)
        waited += 250
        current = _frame_height(page)
        if current == previous:
            return current
        previous = current
    return previous


def test_percentage_height_payload_reports_its_content_height(
    ui_harness: UIHarness, page,
) -> None:
    """A card that sizes itself with percentage heights still lays out at its
    CONTENT height: every row of the report ends up inside the frame.

    The frame has no inner scrollbar, so a report that under-describes the
    content is unreadable rather than merely ugly — that is the bug.
    `html{height:auto!important}` in the frame shell keeps `height:100%` from
    resolving against the frame the parent is about to size."""
    h = ui_harness
    session_id = "sess_html_tag_pct_height_001"
    workspace_id = create_workspace(h)
    _seed_report_message(
        h, session_id, workspace_id,
        _report_payload(
            "html,body{height:100%;margin:0}"
            ".shell{height:100%;display:flex;flex-direction:column;box-sizing:border-box}"
            ".shell>.cols{flex:1;overflow:hidden}",
            wrap="shell",
        ),
    )

    open_chatview(page, h, workspace_id, session_id)
    page.wait_for_selector("iframe.chat-html-frame", timeout=15000)

    height = _settled_frame_height(page)
    frame = page.frame_locator("iframe.chat-html-frame")
    content_bottom = float(
        frame.locator("tbody tr").evaluate_all(
            "els => Math.max(...els.map(e => e.getBoundingClientRect().bottom))"
        )
    )
    assert content_bottom <= height + 2, (
        f"the report's last row sits at {content_bottom:.0f}px inside a "
        f"{height:.0f}px frame — the rest of the card is unreachable"
    )


def test_viewport_height_payload_settles_instead_of_ratcheting(
    ui_harness: UIHarness, page,
) -> None:
    """`min-height:100vh` content reports its own height once and stops.

    The frame's viewport is an output of the report; when the document measures
    itself against that viewport every report grows the frame that produced it,
    and a single message inflates the transcript without bound."""
    h = ui_harness
    session_id = "sess_html_tag_vh_height_001"
    workspace_id = create_workspace(h)
    _seed_report_message(
        h, session_id, workspace_id,
        _report_payload(".page{min-height:100vh;box-sizing:border-box}", wrap="page"),
    )

    open_chatview(page, h, workspace_id, session_id)
    page.wait_for_selector("iframe.chat-html-frame", timeout=15000)

    height = _settled_frame_height(page)
    content_bottom = float(
        page.frame_locator("iframe.chat-html-frame")
        .locator("tbody tr")
        .evaluate_all("els => Math.max(...els.map(e => e.getBoundingClientRect().bottom))")
    )
    assert height < 2000, (
        f"a `min-height:100vh` payload grew its frame to {height:.0f}px — the "
        f"report is chasing the viewport it just resized"
    )
    assert content_bottom <= height + 2, (
        f"content ends at {content_bottom:.0f}px inside a {height:.0f}px frame"
    )
