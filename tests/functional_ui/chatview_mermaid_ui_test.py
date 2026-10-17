"""DB-seeded Playwright tests for the chatview's ``<mermaid>`` wrapper tag.

Feature (2026-10-17 mermaid-support): the LLM can wrap Mermaid source in
``<mermaid>...</mermaid>`` (``core.zig`` -> ``ResponseFormatting``); the
chatview renders each block as a live SVG diagram (``MermaidDiagram.vue``,
Mermaid loaded lazily) instead of markdown. A ```mermaid fence, the shape
models reach for anyway, renders the same way.

Each test seeds a real assistant row and drives headless Chromium, so the
diagram is proved in a browser that actually lays out SVG and actually
loads the Mermaid chunk — jsdom vitest can do neither.
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

MERMAID_SOURCE = "flowchart TD\n  A[Ask] --> B[Diagram]"

#: ``--semantic-card-bg`` in ``style.css`` — the surface a rich block paints.
CARD_BG = "rgb(29, 28, 25)"


def _seed_db_path(h: UIHarness) -> Path:
    return h.temp_dir / ".config" / "pabrik" / "agent.db"


def _seed_turn(h: UIHarness, session_id: str, assistant_content: str) -> str:
    workspace_id = create_workspace(h)
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Mermaid")
        bind_session_workspace(conn, workspace_id, session_id)
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(conn, session_id, "draw me the flow", created_at=ts[0])
        seed.seed_assistant_message(conn, session_id, assistant_content, created_at=ts[1])
    return workspace_id


def _diagram_metrics(page) -> dict:
    """Geometry, palette and label shape of the rendered diagram, read in the page."""
    return page.evaluate(
        """() => {
            const box = document.querySelector('[data-testid="chat-mermaid"]');
            const svg = box && box.querySelector('svg');
            if (!box || !svg) return null;
            const r = svg.getBoundingClientRect();
            const br = box.getBoundingClientRect();
            const nodes = Array.from(svg.querySelectorAll('g.node'));
            const first = nodes[0];
            const label = first && first.querySelector('text, span, p');
            const shape = first && first.querySelector('rect, polygon, circle, ellipse');
            const sheet = svg.querySelector('style');
            const css = sheet ? sheet.textContent : '';
            return {
                svgWidth: r.width,
                svgHeight: r.height,
                boxWidth: br.width,
                boxBackground: getComputedStyle(box).backgroundColor,
                nodeCount: nodes.length,
                nodeLabels: nodes.map((n) => n.textContent.trim()).join('|'),
                svgTextCount: svg.querySelectorAll('text').length,
                foreignObjectCount: svg.querySelectorAll('foreignObject').length,
                labelFill: label ? getComputedStyle(label).fill : '',
                shapeFill: shape ? getComputedStyle(shape).fill : '',
                shapeStroke: shape ? getComputedStyle(shape).stroke : '',
                css: css,
            };
        }"""
    )


# ─── Test 1: a <mermaid> block renders a real, laid-out SVG ────────────────


def test_mermaid_block_renders_a_laid_out_svg(ui_harness: UIHarness, page) -> None:
    h = ui_harness
    session_id = "sess_mermaid_svg_001"
    workspace_id = _seed_turn(
        h, session_id, f"<mermaid>{MERMAID_SOURCE}</mermaid>",
    )
    open_chatview(page, h, workspace_id, session_id)

    page.wait_for_selector('[data-testid="chat-mermaid-svg"] svg', timeout=20000)
    m = _diagram_metrics(page)
    assert m is not None, "the diagram container rendered no <svg>"
    print(
        "diagram:",
        {
            k: m[k]
            for k in (
                "svgWidth",
                "svgHeight",
                "nodeCount",
                "nodeLabels",
                "shapeFill",
                "shapeStroke",
                "labelFill",
                "svgTextCount",
                "foreignObjectCount",
            )
        },
    )

    assert m["svgWidth"] > 40 and m["svgHeight"] > 40, f"svg not laid out: {m}"
    assert m["nodeCount"] == 2, f"expected both nodes of a 2-node flow: {m}"
    assert m["nodeLabels"] == "Ask|Diagram", f"node labels missing: {m['nodeLabels']!r}"

    # The APP's palette reached the diagram, and no stock mermaid one did:
    # `#fff4dd` is theme-base's primary (the theme this config selects),
    # `#ECECFF` theme-default's — either would read as a foreign widget.
    assert m["shapeFill"] == "rgb(40, 39, 39)", f"--color-bg-p1 node fill: {m}"
    assert m["shapeStroke"] == "rgb(57, 56, 54)", f"--color-bg-p2 node stroke: {m}"
    assert m["labelFill"] == "rgb(197, 201, 197)", f"--semantic-text label ink: {m}"
    assert "#282727" in m["css"], "the app palette never reached the stylesheet"
    assert "#fff4dd" not in m["css"] and "#ECECFF" not in m["css"], (
        "a stock mermaid palette leaked into the stylesheet"
    )

    # SVG <text> labels (root-level `htmlLabels: false`), not <foreignObject>
    # HTML that inherits the app's Tailwind preflight inside the diagram.
    assert m["foreignObjectCount"] == 0, f"labels are HTML, not SVG text: {m}"
    assert m["svgTextCount"] >= 2, f"expected <text> labels: {m}"

    # The diagram is drawn on the app's card surface inside the chat column,
    # never as a white sheet (the regression class of PR #309/#968).
    assert m["boxBackground"] == CARD_BG, f"diagram canvas is {m['boxBackground']!r}"
    assert m["svgWidth"] <= m["boxWidth"] + 1, f"svg overflows its card: {m}"
    # Arrowheads share the connector tone; mermaid's stock head is near-white
    # (#e2e3e6), which reads as a bright dot on the end of a muted line.
    assert ".arrowheadPath{fill:#7a8382" in m["css"], "arrowheads should use the connector tone"

    body_text = page.locator(".assistant-item").first.inner_text()
    assert "flowchart TD" not in body_text, "raw mermaid source leaked as text"


# ─── Test 2: ```mermaid fence, the shape models reach for ──────────────────


def test_mermaid_fence_renders_a_diagram(ui_harness: UIHarness, page) -> None:
    h = ui_harness
    session_id = "sess_mermaid_fence_001"
    workspace_id = _seed_turn(
        h, session_id, f"```mermaid\n{MERMAID_SOURCE}\n```",
    )
    open_chatview(page, h, workspace_id, session_id)

    page.wait_for_selector('[data-testid="chat-mermaid-svg"] svg', timeout=20000)
    assert page.locator('[data-testid="chat-mermaid-svg"] svg').count() == 1


# ─── Test 3: prose outside the tag still renders as markdown ───────────────


def test_mixed_prose_and_mermaid_render_together(ui_harness: UIHarness, page) -> None:
    h = ui_harness
    session_id = "sess_mermaid_mixed_001"
    workspace_id = _seed_turn(
        h,
        session_id,
        f"Here is **your** flow:\n<mermaid>{MERMAID_SOURCE}</mermaid>\nDone.",
    )
    open_chatview(page, h, workspace_id, session_id)

    page.wait_for_selector('[data-testid="chat-mermaid-svg"] svg', timeout=20000)
    assert page.locator(".markdown-content strong").count() > 0, (
        "markdown outside the mermaid block should still render"
    )
    assert page.locator("text=Here is your flow:").count() > 0
    assert page.locator("iframe.chat-html-frame").count() == 0


# ─── Test 4: a diagram that does not parse shows its source, not a hole ────


def test_malformed_mermaid_falls_back_to_its_source(ui_harness: UIHarness, page) -> None:
    h = ui_harness
    session_id = "sess_mermaid_broken_001"
    workspace_id = _seed_turn(
        h, session_id, "<mermaid>flowchart TD\n  A[unclosed --> B</mermaid>",
    )

    errors: list[str] = []
    page.on("pageerror", lambda exc: errors.append(str(exc)))

    open_chatview(page, h, workspace_id, session_id)
    page.wait_for_selector('[data-testid="chat-mermaid"]', timeout=20000)

    page.wait_for_selector('[data-testid="chat-mermaid-error"]', timeout=20000)
    assert page.locator('[data-testid="chat-mermaid-svg"] svg').count() == 0
    note = page.locator('[data-testid="chat-mermaid-error"]').inner_text()
    assert note.startswith("Diagram not rendered"), note
    assert "flowchart TD" in page.locator('[data-testid="chat-mermaid"]').inner_text(), (
        "the fallback must show the source, not an empty box"
    )
    assert not errors, f"page errors while rendering a broken diagram: {errors}"


# ─── Test 5: legacy markdown is untouched ──────────────────────────────────


def test_legacy_markdown_message_has_no_diagram(ui_harness: UIHarness, page) -> None:
    h = ui_harness
    session_id = "sess_mermaid_legacy_001"
    workspace_id = _seed_turn(h, session_id, "# Heading\n\nSome **bold** text.\n")
    open_chatview(page, h, workspace_id, session_id)

    page.wait_for_selector(".markdown-content h1", timeout=20000)
    assert page.locator(".markdown-content h1").inner_text() == "Heading"
    assert page.locator('[data-testid="chat-mermaid"]').count() == 0
