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


# ─── Test: the frame follows a document that SHRINKS — and never paints white ──

# A DARK presented document that collapses on a click, like the wireframe in the
# bug report: the toggle flips `class` and `style.display` only — attribute
# mutations, which a childList-only MutationObserver never reports.
SHRINKING_DOC = """<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><style>
  body{margin:0;background:#181616;color:#c5c9c5;font:14px/1.5 sans-serif}
  .pane{display:none}
  .pane.on{display:block}
  #paneA{height:900px}
  #paneB{height:200px}
</style></head>
<body>
<button id="switch">switch</button>
<div class="pane on" id="paneA">A</div>
<div class="pane" id="paneB">B</div>
<script>
document.getElementById('switch').addEventListener('click', function () {
  var a = document.getElementById('paneA')
  var b = document.getElementById('paneB')
  a.classList.remove('on')
  a.style.display = 'none'
  b.classList.add('on')
  b.style.display = 'block'
})
</script>
</body>
</html>
"""


def _seed_present_files_html(h: UIHarness, session_id: str, html: str) -> str:
    """Write ``html`` into the harness tmpdir and seed the present_files wire rows."""
    html_path = h.temp_dir / "shrinker.html"
    html_path.write_bytes(html.encode("utf-8"))
    html_bytes = html_path.stat().st_size

    workspace_id = create_workspace(h)
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Present Files", cwd=str(h.temp_dir))
        bind_session_workspace(conn, workspace_id, session_id)

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
                        "label": "shrinker",
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
            tool_calls=[
                {
                    "id": "call_present_shrink_001",
                    "type": "function",
                    "function": {
                        "name": "present_files",
                        "arguments": {"files": [{"path": str(html_path)}]},
                    },
                }
            ],
            created_at=ts[1],
        )
        seed.seed_tool_result(
            conn,
            session_id,
            "call_present_shrink_001",
            "present_files",
            envelope,
            created_at=ts[2],
        )
    return workspace_id


def test_present_files_frame_tracks_a_document_that_shrinks(
    ui_harness: UIHarness, page
) -> None:
    """The preview frame follows a document that collapses, and its canvas is themed.

    The bug (2026-10-16): a presented dark HTML document whose script swaps a
    pane by flipping ``class`` / ``style.display`` left the frame at its old,
    taller height, and the injected srcdoc shell kept ``background:#fff`` on
    ``html`` — so the uncovered strip painted a bright WHITE slab under the
    document, inside the dark transcript.
    """
    h = ui_harness
    session_id = "sess_present_files_shrink_001"
    workspace_id = _seed_present_files_html(h, session_id, SHRINKING_DOC)

    open_chatview(page, h, workspace_id, session_id)
    page.wait_for_selector('[data-testid="present-files-card"]', timeout=15000)
    card = page.locator('[data-testid="present-files-card"]').first
    card.scroll_into_view_if_needed()
    header = card.locator('[role="button"]').first
    if header.get_attribute("aria-expanded") == "false":
        header.click()
    page.wait_for_selector('[data-testid="present-files-row-0"]', timeout=15000)

    frame_el = page.locator('[data-testid="present-files-inline-html-0"] iframe')
    frame_el.wait_for(timeout=15000)
    frame = page.frame_locator('[data-testid="present-files-inline-html-0"] iframe')
    frame.locator("#switch").wait_for(timeout=10000)

    def frame_height() -> int:
        return int(frame_el.evaluate("el => el.clientHeight"))

    def body_height() -> float:
        return float(frame.locator("body").evaluate("el => el.getBoundingClientRect().height"))

    # 1. The reporter grows the frame to the tall pane.
    page.wait_for_timeout(800)
    tall_frame = frame_height()
    assert tall_frame > 500, f"frame should have grown to the tall pane, got {tall_frame}"

    # 2. Collapse the document (class/style mutations ONLY) and wait for the report.
    frame.locator("#switch").click()
    short_frame = tall_frame
    for _ in range(40):  # up to ~4s for the resize report to land
        page.wait_for_timeout(100)
        short_frame = frame_height()
        if short_frame < tall_frame - 100:
            break
    assert short_frame < tall_frame - 100, (
        f"frame did not follow the SHORTER document: {tall_frame}px -> {short_frame}px "
        "(a stale frame leaves a dead band under the content)"
    )

    # 3. No dead band: the frame is exactly as tall as its content.
    body = body_height()
    assert short_frame <= body + 2, (
        f"frame taller than its content: frame {short_frame}px > body {body}px"
    )

    # 4. The frame document's canvas is the app's card surface, never white.
    canvas = frame.locator("html").evaluate("el => getComputedStyle(el).backgroundColor")
    assert canvas != "rgb(255, 255, 255)", f"frame canvas is white: {canvas}"
    card_bg = page.evaluate(
        """() => {
            const probe = document.createElement('div')
            probe.style.background = 'var(--semantic-card-bg)'
            document.body.appendChild(probe)
            const c = getComputedStyle(probe).backgroundColor
            probe.remove()
            return c
        }"""
    )
    assert canvas == card_bg, f"frame canvas {canvas} is not the app card surface {card_bg}"

    # 5. Nothing bare is exposed: the bottom edge of the frame hits real content.
    bottom = frame.locator("body").evaluate(
        "() => { const el = document.elementFromPoint(4, window.innerHeight - 4); "
        "return el ? el.tagName : '' }"
    )
    assert bottom != "HTML", "the frame's bare canvas is exposed at its bottom edge"

# ─── Test: a presented markdown / .mmd file draws its mermaid diagram ───────

PRESENTED_MD = """# Flow

Here is the pipeline:

```mermaid
flowchart TD
  A[Ask] --> B[Diagram]
```

Done.
"""

PRESENTED_MMD = "flowchart LR\n  X[Left] --> Y[Right]\n"


def test_present_files_markdown_and_mmd_render_diagrams(
    ui_harness: UIHarness, page,
) -> None:
    """A presented file containing mermaid renders a DIAGRAM, not source text.

    Two real files on disk inside the isolated session cwd (the download
    endpoint's sandbox root):

    * ``flow.md`` — prose around a ```mermaid fence (what an agent writes
      into a report);
    * ``flow.mmd`` — bare mermaid source, no fence, mime
      ``application/octet-stream`` (what a server guesses for ``.mmd``).

    Both are fetched over the same-origin inline endpoint and rendered by
    the shared ``PreviewContentRenderer``; the diagram itself must be the
    same app-themed SVG the transcript draws.
    """
    h = ui_harness
    session_id = "sess_present_files_mermaid_001"

    md_path = h.temp_dir / "flow.md"
    mmd_path = h.temp_dir / "flow.mmd"
    md_path.write_bytes(PRESENTED_MD.encode("utf-8"))
    mmd_path.write_bytes(PRESENTED_MMD.encode("utf-8"))

    workspace_id = create_workspace(h)
    seed = DbSeed(_seed_db_path(h))
    files = [
        {
            "path": str(md_path),
            "bytes": md_path.stat().st_size,
            "mime": "text/markdown; charset=utf-8",
            "label": "flow.md",
        },
        {
            "path": str(mmd_path),
            "bytes": mmd_path.stat().st_size,
            "mime": "application/octet-stream",
            "label": "flow.mmd",
        },
    ]
    envelope = json.dumps(
        {
            "tool": "present_files",
            "parameters": {"files": [{"path": f["path"]} for f in files]},
            "success": True,
            "data": {
                "status": "presented",
                "count": len(files),
                "files": files,
                "error": None,
            },
            "error": None,
            "v": 1,
        }
    )
    with seed.connect() as conn:
        seed.seed_session(
            conn, session_id, "Present Files Mermaid", cwd=str(h.temp_dir),
        )
        bind_session_workspace(conn, workspace_id, session_id)
        ts = DbSeed.baseline_timestamps(count=3, interval_seconds=30)
        seed.seed_user_message(conn, session_id, "show me the flow", created_at=ts[0])
        seed.seed_assistant_message(
            conn,
            session_id,
            text="",
            finish_reason="tool_calls",
            tool_calls=[{
                "id": "call_present_mermaid_001",
                "type": "function",
                "function": {
                    "name": "present_files",
                    "arguments": {"files": [{"path": f["path"]} for f in files]},
                },
            }],
            created_at=ts[1],
        )
        seed.seed_tool_result(
            conn, session_id, "call_present_mermaid_001", "present_files", envelope,
            created_at=ts[2],
        )

    open_chatview(page, h, workspace_id, session_id)
    page.wait_for_selector('[data-testid="present-files-card"]', timeout=15000)
    card = page.locator('[data-testid="present-files-card"]').first
    card.scroll_into_view_if_needed()
    header = card.locator('[role="button"]').first
    if header.get_attribute("aria-expanded") == "false":
        header.click()

    # 1. The `.md` preview draws its fence as a diagram, prose intact.
    md_box = page.locator('[data-testid="present-files-inline-text-0"]')
    md_box.wait_for(timeout=15000)
    md_box.locator('[data-testid="chat-mermaid-svg"] svg').wait_for(timeout=20000)
    assert md_box.locator("h1").count() > 0, "prose around the diagram must still render"
    md_text = md_box.inner_text()
    assert "```mermaid" not in md_text, f"the fence still renders as text: {md_text!r}"
    assert "Done." in md_text, "prose after the diagram must still render"

    # 2. A whole-file `.mmd` (no fence) is all diagram.
    mmd_box = page.locator('[data-testid="present-files-inline-text-1"]')
    mmd_box.wait_for(timeout=15000)
    # Scoped to the drawing's own testid: the card's copy affordance is an
    # <svg> icon too, so a bare `svg` matches two elements.
    mmd_box.locator('[data-testid="preview-mermaid"] [data-testid="chat-mermaid-svg"] svg').wait_for(
        timeout=20000
    )
    m = mmd_box.evaluate(
        """el => {
            const svg = el.querySelector('[data-testid="chat-mermaid-svg"] svg');
            const r = svg.getBoundingClientRect();
            const node = svg.querySelector('g.node rect, g.node polygon, g.node circle');
            return {
                width: r.width,
                height: r.height,
                nodeFill: node ? getComputedStyle(node).fill : '',
                labels: Array.from(svg.querySelectorAll('g.node text'))
                    .map((t) => t.textContent.trim())
                    .join('|'),
            };
        }"""
    )
    print("presented .mmd diagram:", m)

    assert m["width"] > 40 and m["height"] > 40, f"svg not laid out: {m}"
    assert m["labels"] == "Left|Right", f"labels came from flow.mmd: {m}"
    # Same app theme as the transcript's diagrams (--color-bg-p1 node fill),
    # not mermaid's stock light palette.
    assert m["nodeFill"] == "rgb(40, 39, 39)", f"node fill is not the app token: {m}"
