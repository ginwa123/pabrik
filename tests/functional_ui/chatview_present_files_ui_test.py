"""DB-seeded Playwright test for the ``present_files`` HTML inline preview.

Regression test for: the present_files HTML card renders BLANK in the
chatview while "Open in new tab" works perfectly.

Root cause: every ``/api`` response carries the server's default
framing headers (``X-Frame-Options: DENY`` + ``CSP frame-ancestors
'none'``), so a direct ``<iframe src=/api/files/download...>``
navigation is refused inline — while top-level "Open in new tab"
ignores framing headers and works. The fix fetches the bytes over
same-origin ``fetch`` and renders them into a sandboxed ``srcdoc``
iframe instead (same contract as PreviewContentRenderer's html
branch: ``sandbox="allow-scripts"``, no ``allow-same-origin``).

Each test:

1. Boots a fresh pabrik + Vite via the ``ui_harness`` fixture.
2. Writes a REAL html file into the harness's isolated tmpdir and
   seeds ``sessions`` + ``llm_history`` rows (assistant tool-call +
   present_files tool result) pointing at it — the exact wire shape
   production stores.
3. Drives headless Chromium at
   ``<vite_url>/app/<workspace_id>/chat/<id>``, expands the card, and
   asserts the framed document actually RENDERS (the thing jsdom can
   never prove: real Chromium executes srcdoc + runs sandboxed
   scripts).
"""

from __future__ import annotations

import json
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


MARKER = "WIREFRAME_INLINE_OK_7f3a"
CLICKED = "WIRED_CLICK_OK"

HTML_DOC = f"""<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>wireframe</title></head>
<body>
<h1 id="wire-marker">{MARKER}</h1>
<button id="wire-btn" onclick="document.getElementById('wire-result').textContent='{CLICKED}'">tap me</button>
<p id="wire-result">not-clicked</p>
</body>
</html>
"""


# ─── Test: html preview renders inline via srcdoc ───────────────────────────


def test_present_files_html_renders_inline_in_chatview(
    ui_harness: UIHarness, page,
) -> None:
    """The present_files HTML card renders the file inline in chatview.

    Seeds a REAL html file on disk (inside the session cwd so the
    download endpoint's sandbox allows it) plus the assistant
    tool-call + tool-result rows production stores. Then:
      1. locks the root cause: the download response carries
         ``X-Frame-Options: DENY`` + ``frame-ancestors 'none'`` (a
         direct iframe-src navigation can never render inline);
      2. expands the card and asserts the iframe uses ``srcdoc``
         (no ``src`` navigation at all);
      3. asserts the framed document RENDERS (marker text visible
         inside the frame) and its sandboxed script EXECUTES
         (button click updates text) — real-Chromium proof jsdom
         cannot give.
    """
    h = ui_harness
    session_id = "sess_present_files_html_001"

    # 1. Real file on disk inside the isolated tmpdir (the session cwd).
    #
    # BYTES, not `write_text`: text mode translates "\n" to "\r\n" on
    # Windows, so the file on disk was CRLF while the assertion below
    # compares against the LF literal — the test failed on Windows for a
    # reason that had nothing to do with the download endpoint. Writing
    # bytes makes the fixture byte-exact on every platform, which is what
    # "the endpoint must serve the exact file bytes" needs in order to
    # mean anything.
    html_path = h.temp_dir / "wireframe.html"
    html_path.write_bytes(HTML_DOC.encode("utf-8"))
    html_bytes = html_path.stat().st_size

    # 2. Lock the root cause on the wire: framing headers present, body
    #    byte-identical. (Session row must exist first — the endpoint
    #    resolves the sandbox root from it.)
    workspace_id = create_workspace(h)
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Present Files", cwd=str(h.temp_dir))
        bind_session_workspace(conn, workspace_id, session_id)

    dl = h.http(
        "GET",
        "/api/files/download",
        params={
            "session_id": session_id,
            "path": str(html_path),
            "disposition": "inline",
        },
        expect=200,
    )
    assert dl.body == HTML_DOC.encode("utf-8"), (
        "download endpoint must serve the exact file bytes"
    )
    lowered = {k.lower(): v for k, v in dl.headers.items()}
    assert lowered.get("x-frame-options") == "DENY", (
        f"expected framing headers on the download response, got {dl.headers!r}"
    )
    assert "frame-ancestors 'none'" in lowered.get("content-security-policy", ""), (
        f"expected frame-ancestors 'none' in CSP, got {dl.headers!r}"
    )

    # 3. Seed the conversation: user + assistant tool-call + tool result.
    envelope = json.dumps(
        {
            "tool": "present_files",
            "parameters": {"files": [{"path": str(html_path)}]},
            "success": True,
            "data": {
                "status": "presented",
                "count": 1,
                "files": [
                    {
                        "path": str(html_path),
                        "bytes": html_bytes,
                        "mime": "text/html; charset=utf-8",
                        "label": "wireframe",
                    }
                ],
                "error": None,
            },
            "error": None,
            "v": 1,
        }
    )
    with seed.connect() as conn:
        ts = DbSeed.baseline_timestamps(count=3, interval_seconds=30)
        seed.seed_user_message(conn, session_id, "show me the wireframe", created_at=ts[0])
        seed.seed_assistant_message(
            conn,
            session_id,
            text="",
            finish_reason="tool_calls",
            tool_calls=[{
                "id": "call_present_001",
                "type": "function",
                "function": {
                    "name": "present_files",
                    "arguments": {"files": [{"path": str(html_path)}]},
                },
            }],
            created_at=ts[1],
        )
        seed.seed_tool_result(
            conn, session_id, "call_present_001", "present_files", envelope,
            created_at=ts[2],
        )

    # 4. Open chatview and make sure the card is expanded.
    #
    # The card is EXPANDED BY DEFAULT — "presented files are the payload,
    # not metadata" (PresentFiles.vue, since #834). Clicking the header
    # therefore COLLAPSES it, which is what this test used to do while it
    # still assumed a collapsed default: the iframe it then waited for had
    # been in the DOM before the click and was gone after it. Read
    # `aria-expanded` and only click when it is actually closed, so the
    # test survives either default.
    open_chatview(page, h, workspace_id, session_id)
    page.wait_for_selector('[data-testid="present-files-card"]', timeout=15000)
    card = page.locator('[data-testid="present-files-card"]').first
    card.scroll_into_view_if_needed()
    header = card.locator('[role="button"]').first
    if header.get_attribute("aria-expanded") == "false":
        header.click()
    # The expanded body carries the file rows.
    page.wait_for_selector('[data-testid="present-files-row-0"]', timeout=15000)

    # 5. The inline iframe appears — via srcdoc, never src navigation.
    frame_el = page.locator('[data-testid="present-files-inline-html-0"] iframe')
    frame_el.wait_for(timeout=15000)
    assert (frame_el.get_attribute("src") or "") == "", (
        "html preview must not navigate the iframe to the download URL "
        "(framing headers refuse it) — it must render via srcdoc"
    )
    srcdoc = frame_el.get_attribute("srcdoc") or ""
    assert MARKER in srcdoc, "iframe srcdoc must carry the fetched file bytes"
    sandbox = frame_el.get_attribute("sandbox") or ""
    assert "allow-scripts" in sandbox, f"expected sandbox allow-scripts, got {sandbox!r}"
    assert "allow-same-origin" not in sandbox, (
        f"allow-same-origin would break the null-origin boundary, got {sandbox!r}"
    )

    # 6. Real-Chromium proof: the framed document RENDERS and its
    #    sandboxed script EXECUTES (jsdom can never show this).
    frame = page.frame_locator('[data-testid="present-files-inline-html-0"] iframe')
    marker = frame.locator("#wire-marker")
    marker.wait_for(timeout=10000)
    assert marker.inner_text() == MARKER
    frame.locator("#wire-btn").click()
    result = frame.locator("#wire-result")
    for _ in range(20):  # up to ~2s for the sandboxed onclick to run
        if result.inner_text() == CLICKED:
            break
        page.wait_for_timeout(100)
    assert result.inner_text() == CLICKED, (
        "sandboxed script did not execute inside the srcdoc iframe"
    )

    # 7. The proven fallback stays: Open-in-new-tab action is present.
    assert page.locator('[data-testid="present-files-open-tab-0"]').count() > 0, (
        "Open in new tab fallback must stay available"
    )
