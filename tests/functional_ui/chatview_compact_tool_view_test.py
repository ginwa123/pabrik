"""The compact chat view: one turn's tool calls, folded into one card.

Two bugs this guards, both seen in the real app:

1. The compact view drew EVERY call as a group card that said "1 tool calls"
   and carried neither the tool nor its argument, so it said LESS than the dev
   view.
2. Nothing ever folded: the chat groups CONSECUTIVE tool rows, and a chat that
   fires one tool per turn has a thinking turn between each call — so every
   group held one call. The fold has to follow the TURN (every call until the
   assistant stops), not the row adjacency.
3. The folded view BLINKED: a turn's groups that draw nothing (the calls the
   card already holds, and the thoughts it swallowed) drew an empty wrapper per
   group, and `VirtualScroller.measureItems` skipped every 0px row (`h > 0`), so
   each of them kept its ~67px PLACEHOLDER in the height model forever. The
   sizer overshot the real content by thousands of px, the tail cap tried to
   clamp it, the clamp moved `scrollTop`, and ChatView re-stuck on the growth —
   every frame, forever: ~13 000 DOM mutations and a `scrollTop` cycling through
   503 / 1019 / 2123 in 12 s of an IDLE transcript.

Each test:
1. Boots a fresh pabrik + Vite (the ``ui_harness`` fixture).
2. Writes a config.json — with ``chat_view: "compact"`` for the compact view,
   without it for the dev view. The backend reads config.json fresh per
   request, so a post-boot write is picked up.
3. Seeds ``sessions`` + ``llm_history`` rows: one thinking turn and one tool
   result per call, then the assistant's stop — so the tool rows are NOT
   adjacent and the thoughts separate them.
4. Drives headless Chromium at the chat deep link and asserts what the chat
   SHOWS.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from chatview_boot import (
    bind_session_workspace,
    create_workspace,
    open_chatview,
)
from db_seed import DbSeed
from ui_harness import UIHarness


def _seed_db_path(h: UIHarness) -> Path:
    return h.temp_dir / ".config" / "pabrik" / "agent.db"


def _config_dir(h: UIHarness) -> Path:
    if sys.platform == "darwin":
        return h.temp_dir / "Library" / "Application Support" / "pabrik"
    if sys.platform == "win32":
        return h.temp_dir / "AppData" / "Roaming" / "pabrik"
    return h.temp_dir / ".config" / "pabrik"


def _write_config(h: UIHarness, chat_view: str | None) -> None:
    """Write a config.json with (or without) the chat view mode."""
    config_dir = _config_dir(h)
    config_dir.mkdir(parents=True, exist_ok=True)
    body: dict[str, object] = {
        "api_key": "stub-not-real",
        "model": "stub-model",
        "base_url": "http://127.0.0.1:1",
    }
    if chat_view is not None:
        body["chat_view"] = chat_view
    (config_dir / "config.json").write_text(json.dumps(body), encoding="utf-8")


# The calls of ONE agent turn: the agent thinks, calls one tool, thinks, calls
# the next — so in the transcript the tool rows are separated by thoughts and
# never end up in one group.
CALLS = [
    ("read_file", {"path": "/tmp/alpha.ts"}),
    ("command", {"command": "ls -la"}),
    ("search", {"pattern": "needle"}),
]


def _seed_transcript(h: UIHarness, workspace_id: str, session_id: str) -> None:
    """Seed one turn: a thought and a tool result per call, then the stop."""
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Compact View", cwd=str(h.temp_dir))
        bind_session_workspace(conn, workspace_id, session_id)
        seed.seed_user_message(conn, session_id, text="read the file and tell me what it draws")
        for index, (tool, parameters) in enumerate(CALLS):
            call_id = f"tc_{tool}_{index}"
            seed.seed_assistant_message(
                conn,
                session_id,
                text="",
                finish_reason="tool_calls",
                reasoning_content=f"Thinking about step {index + 1}",
                tool_calls=[
                    {
                        "id": call_id,
                        "type": "function",
                        "function": {"name": tool, "arguments": json.dumps(parameters)},
                    }
                ],
            )
            envelope = {
                "tool": tool,
                "parameters": parameters,
                "success": True,
                "data": {},
                "error": None,
                "v": 1,
                "duration_ms": 1200 * (index + 1),
            }
            seed.seed_tool_result(
                conn,
                session_id,
                tool_call_id=call_id,
                tool_name=tool,
                content=json.dumps(envelope),
            )
        # The turn ends here: the assistant stops, so every call above is one run.
        seed.seed_assistant_message(conn, session_id, text="Done.", finish_reason="stop")


def test_one_turn_of_calls_folds_into_one_card(ui_harness: UIHarness, page) -> None:
    """The calls of a turn fold into one card, even with thoughts between them."""
    h = ui_harness
    session_id = "sess_compact_view_fold_001"
    workspace_id = create_workspace(h)
    _write_config(h, "compact")
    _seed_transcript(h, workspace_id, session_id)

    open_chatview(page, h, workspace_id, session_id)
    page.locator('[data-testid="compact-tool-group"]').first.wait_for(timeout=20000)

    cards = page.locator('[data-testid="compact-tool-group"]')
    assert cards.count() == 1, (
        f"one turn's calls must fold into ONE card, got {cards.count()} cards"
    )
    count = page.locator('[data-testid="compact-tool-group-count"]').first.inner_text()
    assert count.strip() == f"{len(CALLS)} tool calls", (
        f"the card must count the whole turn, got {count!r}"
    )
    assert page.locator('[data-testid="compact-tool-row"]').count() == 0, (
        "a folded run must not draw its rows"
    )


def test_the_thoughts_of_the_turn_are_inside_the_card(ui_harness: UIHarness, page) -> None:
    """A thought belongs to the call it led to, so it lives in the card — a
    Thought row leaking out below the card is the bug this guards."""
    h = ui_harness
    session_id = "sess_compact_view_thoughts_001"
    workspace_id = create_workspace(h)
    _write_config(h, "compact")
    _seed_transcript(h, workspace_id, session_id)

    open_chatview(page, h, workspace_id, session_id)
    page.locator('[data-testid="compact-tool-group"]').first.wait_for(timeout=20000)

    assert page.locator(".assistant-reasoning").count() == 0, (
        "a folded turn must not draw the dev view's Thought rows below the card"
    )
    body = page.locator(".tool-sequence-compact").first.inner_text()
    assert "Thinking about step 1" not in body, (
        f"a folded card must stay shut until it is opened, got {body!r}"
    )

    page.locator('[data-testid="compact-tool-group-header"]').first.click()
    page.locator('[data-testid="compact-thought-row"]').first.wait_for(timeout=10000)

    inside = page.evaluate(
        """() => document.querySelectorAll(
             '[data-testid="compact-tool-chain"] [data-testid="compact-thought-row"]').length"""
    )
    assert inside == len(CALLS), (
        f"every thought of the turn must draw INSIDE the chain, got {inside} of {len(CALLS)}"
    )
    previews = page.locator('[data-testid="compact-thought-preview"]').all_text_contents()
    assert previews == [f"Thinking about step {i + 1}" for i in range(len(CALLS))], (
        f"each thought must carry its own line, got {previews}"
    )
    whole = page.locator("body").inner_text()
    for index in range(len(CALLS)):
        text = f"Thinking about step {index + 1}"
        assert whole.count(text) == 1, f"{text!r} must be drawn once, got {whole.count(text)}"


def test_unfolding_the_card_shows_the_tool_and_its_argument(ui_harness: UIHarness, page) -> None:
    """Unfolded, each call is one line: the tool and the argument."""
    h = ui_harness
    session_id = "sess_compact_view_rows_001"
    workspace_id = create_workspace(h)
    _write_config(h, "compact")
    _seed_transcript(h, workspace_id, session_id)

    open_chatview(page, h, workspace_id, session_id)
    page.locator('[data-testid="compact-tool-group-header"]').first.click()
    page.locator('[data-testid="compact-tool-row"]').first.wait_for(timeout=10000)

    rows = page.locator('[data-testid="compact-tool-row"]')
    assert rows.count() == len(CALLS), (
        f"unfolding must draw one row per call, got {rows.count()}"
    )
    names = page.locator('[data-testid="compact-tool-row-name"]').all_text_contents()
    assert names == [tool for tool, _ in CALLS], f"each row must name its tool, got {names}"

    primaries = page.locator('[data-testid="compact-tool-row-primary"]').all_text_contents()
    assert primaries == ["/tmp/alpha.ts", "ls -la", "needle"], (
        f"each row must show the argument that identifies the call, got {primaries}"
    )
    body = page.locator(".tool-sequence").first.inner_text()
    assert "1 tool calls" not in body, f"no row may be a group of one, got {body!r}"


def test_a_row_opens_the_full_card(ui_harness: UIHarness, page) -> None:
    """The `+` on a row opens the dev card for that call."""
    h = ui_harness
    session_id = "sess_compact_view_expand_001"
    workspace_id = create_workspace(h)
    _write_config(h, "compact")
    _seed_transcript(h, workspace_id, session_id)

    open_chatview(page, h, workspace_id, session_id)
    page.locator('[data-testid="compact-tool-group-header"]').first.click()
    page.locator('[data-testid="compact-tool-row"]').first.wait_for(timeout=10000)

    # The only card on screen is the run's own group card: the rows are lines.
    assert page.locator(".chat-tool-card").count() == 1, (
        "the compact rows must not draw the dev cards"
    )
    page.locator('[data-testid="compact-tool-row-expand"]').first.click()
    page.wait_for_function(
        "() => document.querySelectorAll('.chat-tool-card').length >= 2", timeout=10000
    )
    assert page.locator(".chat-tool-card").count() == 2, (
        "the `+` on a row must open the dev card for that one call"
    )


# A transcript long enough to actually scroll: the fold leaves several empty wrappers per turn, and
# the blink only shows once enough of them have piled up a placeholder height.
TURNS = 16

# How long the transcript must stay untouched before it counts as settled, and the patience we give
# it to get there. A repainting view never reaches the quiet window.
IDLE_QUIET_MS = 700
IDLE_MAX_MS = 8000

# `maxTailGap` on the ChatView <VirtualScroller>: the sizer may reserve this much empty space below
# the real content by design. Anything beyond it is a model that does not describe the content.
TAIL_GAP_SLACK_PX = 100 + 8


def _seed_turns(h: UIHarness, workspace_id: str, session_id: str, turns: int) -> None:
    """Seed `turns` agent turns; each one thinks, calls, thinks, calls, then stops."""
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Compact View", cwd=str(h.temp_dir))
        bind_session_workspace(conn, workspace_id, session_id)
        for turn in range(turns):
            seed.seed_user_message(conn, session_id, text=f"turn {turn}: read it and tell me")
            for index, (tool, parameters) in enumerate(CALLS):
                call_id = f"tc_{turn}_{tool}_{index}"
                seed.seed_assistant_message(
                    conn,
                    session_id,
                    text="",
                    finish_reason="tool_calls",
                    reasoning_content=f"Thinking about turn {turn} step {index + 1}",
                    tool_calls=[
                        {
                            "id": call_id,
                            "type": "function",
                            "function": {"name": tool, "arguments": json.dumps(parameters)},
                        }
                    ],
                )
                envelope = {
                    "tool": tool,
                    "parameters": parameters,
                    "success": True,
                    "data": {},
                    "error": None,
                    "v": 1,
                    "duration_ms": 1200 * (index + 1),
                }
                seed.seed_tool_result(
                    conn,
                    session_id,
                    tool_call_id=call_id,
                    tool_name=tool,
                    content=json.dumps(envelope),
                )
            seed.seed_assistant_message(conn, session_id, text=f"Done {turn}.", finish_reason="stop")


# Counts what the transcript does while NOTHING happens: DOM mutations, the scroll positions the
# reader passes through, and how far the sizer's height model sits from the content it describes.
_SETTLE_PROBE = r"""
async (args) => {
  const quietMs = args.quietMs;
  const maxMs = args.maxMs;
  const scroller = document.querySelector('.messages-scroll-hide-native .virtual-scroller')
    || document.querySelector('.virtual-scroller');
  if (!scroller) return { error: 'no scroller' };
  const sizer = scroller.querySelector('.virtual-scroller-sizer');
  const content = scroller.querySelector('.virtual-scroller-content');
  const targets = {};
  let mutations = 0;
  let added = 0;
  let removed = 0;
  let lastMutationAt = performance.now();
  const mark = (name, node) => {
    const tag = node && node.nodeType === 1 ? node.tagName.toLowerCase() : 'text';
    const key = name + ':' + tag;
    targets[key] = (targets[key] || 0) + 1;
  };
  const mo = new MutationObserver((records) => {
    for (const record of records) {
      mutations += 1;
      lastMutationAt = performance.now();
      if (record.type === 'childList') {
        added += record.addedNodes.length;
        removed += record.removedNodes.length;
        for (const node of record.addedNodes) mark('insert', node);
      } else {
        mark('attribute', record.target);
      }
    }
  });
  mo.observe(scroller, { childList: true, subtree: true, attributes: true, characterData: true });
  const scrollTops = new Set([Math.round(scroller.scrollTop)]);
  const startedAt = performance.now();
  let settledAfterMs = null;
  while (performance.now() - startedAt < maxMs) {
    await new Promise((resolve) => setTimeout(resolve, 50));
    scrollTops.add(Math.round(scroller.scrollTop));
    if (performance.now() - lastMutationAt >= quietMs) {
      settledAfterMs = Math.round(performance.now() - startedAt);
      break;
    }
  }
  mo.disconnect();
  const transform = content ? content.style.transform || '' : '';
  const match = transform.match(/translate3d\(0px,\s*(-?[\d.]+)px/);
  const topSpacer = match ? Math.round(parseFloat(match[1])) : 0;
  const contentHeight = content ? Math.round(content.offsetHeight) : 0;
  const children = content ? Array.from(content.children) : [];
  return {
    settledAfterMs: settledAfterMs,
    mutations: mutations,
    added: added,
    removed: removed,
    hotspots: Object.entries(targets).sort((a, b) => b[1] - a[1]).slice(0, 4),
    scrollTops: Array.from(scrollTops).sort((a, b) => a - b),
    sizerHeight: sizer ? Math.round(parseFloat(sizer.style.height) || 0) : 0,
    realContentBottom: topSpacer + contentHeight,
    zeroHeightItems: children.filter((child) => child.getBoundingClientRect().height < 1).length,
    renderedItems: children.length,
  };
}
"""


def test_the_compact_view_settles_instead_of_repainting(ui_harness: UIHarness, page) -> None:
    """An idle compact transcript must stop repainting.

    The reported blink: the fold leaves every other group of a turn drawing an empty wrapper, and
    those 0px rows were never measured, so the height model held a placeholder for each of them. The
    sizer overshot the real content, the tail cap clamped it, the clamp moved the reader, ChatView
    re-stuck on the growth — and the VirtualScroller re-rendered its whole window every frame.
    """
    h = ui_harness
    session_id = "sess_compact_view_blink_001"
    workspace_id = create_workspace(h)
    _write_config(h, "compact")
    _seed_turns(h, workspace_id, session_id, TURNS)

    open_chatview(page, h, workspace_id, session_id)
    page.locator('[data-testid="compact-tool-group"]').first.wait_for(timeout=30000)
    # The mount's own autoscroll is legitimate churn; judge the state it lands in.
    page.wait_for_timeout(800)

    probe = page.evaluate(_SETTLE_PROBE, {"quietMs": IDLE_QUIET_MS, "maxMs": IDLE_MAX_MS})
    overshoot = probe["sizerHeight"] - probe["realContentBottom"]

    assert probe["zeroHeightItems"] > 0, (
        "the fixture must reproduce the report: the fold leaves groups that draw nothing, "
        f"got {probe['renderedItems']} rendered items with no empty one"
    )
    # Both numbers in every message: the model overshoot is what makes the view loop, and the loop
    # is what the human sees, so a red run has to report the blink it caused.
    idle_report = (
        f"repainted forever: {probe['mutations']} mutations "
        f"({probe['added']} nodes inserted, {probe['removed']} removed) in {IDLE_MAX_MS}ms, "
        f"scrollTop cycling through {probe['scrollTops']}, hotspots {probe['hotspots']}"
        if probe["settledAfterMs"] is None
        else f"settled after {probe['settledAfterMs']}ms"
    )

    assert overshoot <= TAIL_GAP_SLACK_PX, (
        "the height model must describe the content: the sizer reserves "
        f"{probe['sizerHeight']}px for content that ends at {probe['realContentBottom']}px "
        f"({overshoot}px of empty space, max {TAIL_GAP_SLACK_PX}) — the unmeasured empty groups "
        f"are holding placeholder heights; the transcript {idle_report}"
    )
    assert probe["settledAfterMs"] is not None, (
        f"an idle transcript must stop repainting, but it {idle_report}"
    )
    assert len(probe["scrollTops"]) == 1, (
        f"the reader's position must hold still while idle, got scrollTops {probe['scrollTops']}"
    )


def test_dev_view_still_draws_the_cards(ui_harness: UIHarness, page) -> None:
    """Without the setting, the chat keeps drawing the dev cards."""
    h = ui_harness
    session_id = "sess_dev_view_cards_001"
    workspace_id = create_workspace(h)
    _write_config(h, None)
    _seed_transcript(h, workspace_id, session_id)

    open_chatview(page, h, workspace_id, session_id)
    page.locator(".chat-tool-card").first.wait_for(timeout=20000)

    assert page.locator(".chat-tool-card").count() == len(CALLS), (
        "the dev view must keep one card per call"
    )
    assert page.locator('[data-testid="compact-tool-row"]').count() == 0, (
        "the dev view must not draw the compact rows"
    )


# ─── What the turn SAYS: the answer it ends with, and the narration on the way there ─────────────

# The sentence the agent writes before each call, on every tool-calling turn.
NARRATIONS = (
    "I will start by reading the alpha file.",
    "Now let me look at the directory.",
)
ANSWER = "The totals are wrong because the tax column is never filled."
QUESTION = "Which database should I read, billing or archive?"


def _envelope(
    tool: str, parameters: object, data: object, duration_ms: int | None = None
) -> str:
    body: dict[str, object] = {
        "tool": tool,
        "parameters": parameters,
        "success": True,
        "data": data,
        "error": None,
        "v": 1,
    }
    if duration_ms is not None:
        body["duration_ms"] = duration_ms
    return json.dumps(body)


def _seed_narrated_turn(h: UIHarness, workspace_id: str, session_id: str) -> None:
    """One turn that narrates before each call and answers at the end."""
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Compact View", cwd=str(h.temp_dir))
        bind_session_workspace(conn, workspace_id, session_id)
        seed.seed_user_message(conn, session_id, text="why are the bill totals wrong?")
        for index, (tool, parameters) in enumerate(CALLS):
            call_id = f"tc_narrated_{index}"
            narration = NARRATIONS[index] if index < len(NARRATIONS) else ""
            seed.seed_assistant_message(
                conn,
                session_id,
                text=narration,
                finish_reason="tool_calls",
                tool_calls=[
                    {
                        "id": call_id,
                        "type": "function",
                        "function": {"name": tool, "arguments": json.dumps(parameters)},
                    }
                ],
            )
            seed.seed_tool_result(
                conn,
                session_id,
                tool_call_id=call_id,
                tool_name=tool,
                content=_envelope(tool, parameters, {}, duration_ms=1200),
            )
        seed.seed_assistant_message(conn, session_id, text=ANSWER, finish_reason="stop")


def test_only_the_answer_the_turn_ended_with_stands_in_the_transcript(
    ui_harness: UIHarness, page
) -> None:
    """A line the agent wrote on the way to a call is not its answer."""
    h = ui_harness
    session_id = "sess_compact_view_narration_001"
    workspace_id = create_workspace(h)
    _write_config(h, "compact")
    _seed_narrated_turn(h, workspace_id, session_id)

    open_chatview(page, h, workspace_id, session_id)
    page.locator('[data-testid="compact-tool-group"]').first.wait_for(timeout=20000)

    body = page.locator("body").inner_text()
    for narration in NARRATIONS:
        assert narration not in body, (
            f"the narration on the way to a call must not stack above the card, "
            f"got {narration!r} in {body!r}"
        )
    assert ANSWER in body, (
        f"the answer the turn ended with must stay in the transcript, got {body!r}"
    )


def test_the_narration_lives_inside_the_card(ui_harness: UIHarness, page) -> None:
    """Unfolded, the narration is one line per sentence, in the order it happened."""
    h = ui_harness
    session_id = "sess_compact_view_narration_002"
    workspace_id = create_workspace(h)
    _write_config(h, "compact")
    _seed_narrated_turn(h, workspace_id, session_id)

    open_chatview(page, h, workspace_id, session_id)
    page.locator('[data-testid="compact-tool-group-header"]').first.click()
    page.locator('[data-testid="compact-narration-row"]').first.wait_for(timeout=10000)

    inside = page.evaluate(
        """() => document.querySelectorAll(
             '[data-testid="compact-tool-chain"] [data-testid="compact-narration-row"]').length"""
    )
    assert inside == len(NARRATIONS), (
        f"every line the agent wrote on the way to a call must draw INSIDE the chain, "
        f"got {inside} of {len(NARRATIONS)}"
    )
    previews = page.locator('[data-testid="compact-narration-preview"]').all_text_contents()
    assert previews == list(NARRATIONS), f"each line must carry its own text, got {previews}"
    whole = page.locator("body").inner_text()
    for narration in NARRATIONS:
        assert whole.count(narration) == 1, (
            f"{narration!r} must be drawn once, got {whole.count(narration)}"
        )


def test_a_question_for_the_human_stays_visible(ui_harness: UIHarness, page) -> None:
    """`ask_user` ends the turn by asking, so the question it wrote must stay on screen."""
    h = ui_harness
    session_id = "sess_compact_view_question_001"
    workspace_id = create_workspace(h)
    _write_config(h, "compact")

    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Compact View", cwd=str(h.temp_dir))
        bind_session_workspace(conn, workspace_id, session_id)
        seed.seed_user_message(conn, session_id, text="why are the bill totals wrong?")
        seed.seed_assistant_message(
            conn,
            session_id,
            text=QUESTION,
            finish_reason="tool_calls",
            tool_calls=[
                {
                    "id": "tc_ask",
                    "type": "function",
                    "function": {
                        "name": "ask_user",
                        "arguments": json.dumps(
                            {"question": QUESTION, "options": ["billing", "archive"]}
                        ),
                    },
                }
            ],
        )
        seed.seed_tool_result(
            conn,
            session_id,
            tool_call_id="tc_ask",
            tool_name="ask_user",
            content=_envelope(
                "ask_user",
                {"question": QUESTION},
                {
                    "status": "pending",
                    "question_id": "q_ui_compact_1",
                    "question": QUESTION,
                    "options": ["billing", "archive"],
                },
            ),
        )

    open_chatview(page, h, workspace_id, session_id)
    page.locator('[data-testid="ask-user-card"]').first.wait_for(timeout=20000)

    body = page.locator("body").inner_text()
    assert QUESTION in body, (
        f"the question the turn ended by asking must stay in the transcript, got {body!r}"
    )


def test_a_presented_file_keeps_its_own_card(ui_harness: UIHarness, page) -> None:
    """`present_files` IS what the agent is showing, so it never folds into a row."""
    h = ui_harness
    session_id = "sess_compact_view_present_001"
    workspace_id = create_workspace(h)
    _write_config(h, "compact")

    report = h.temp_dir / "report.txt"
    report.write_bytes(b"presented bytes\n")

    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Compact View", cwd=str(h.temp_dir))
        bind_session_workspace(conn, workspace_id, session_id)
        seed.seed_user_message(conn, session_id, text="read it and show me the report")
        for index, (tool, parameters) in enumerate(CALLS[:2]):
            call_id = f"tc_present_run_{index}"
            seed.seed_assistant_message(
                conn,
                session_id,
                text="",
                finish_reason="tool_calls",
                tool_calls=[
                    {
                        "id": call_id,
                        "type": "function",
                        "function": {"name": tool, "arguments": json.dumps(parameters)},
                    }
                ],
            )
            seed.seed_tool_result(
                conn,
                session_id,
                tool_call_id=call_id,
                tool_name=tool,
                content=_envelope(tool, parameters, {}, duration_ms=900),
            )
        seed.seed_assistant_message(
            conn,
            session_id,
            text="",
            finish_reason="tool_calls",
            tool_calls=[
                {
                    "id": "tc_present",
                    "type": "function",
                    "function": {
                        "name": "present_files",
                        "arguments": json.dumps({"files": [{"path": str(report)}]}),
                    },
                }
            ],
        )
        seed.seed_tool_result(
            conn,
            session_id,
            tool_call_id="tc_present",
            tool_name="present_files",
            content=_envelope(
                "present_files",
                {"files": [{"path": str(report)}]},
                {
                    "status": "presented",
                    "count": 1,
                    "files": [
                        {
                            "path": str(report),
                            "bytes": report.stat().st_size,
                            "mime": "text/plain",
                            "label": "report",
                        }
                    ],
                },
            ),
        )
        seed.seed_assistant_message(
            conn, session_id, text="Here is the report.", finish_reason="stop"
        )

    open_chatview(page, h, workspace_id, session_id)
    page.locator('[data-testid="present-files-card"]').first.wait_for(timeout=20000)

    count = page.locator('[data-testid="compact-tool-group-count"]').first.inner_text()
    assert count.strip() == "2 tool calls", (
        f"only the calls that fold belong in the count, got {count!r}"
    )
    page.locator('[data-testid="compact-tool-group-header"]').first.click()
    page.locator('[data-testid="compact-tool-row"]').first.wait_for(timeout=10000)
    names = page.locator('[data-testid="compact-tool-row-name"]').all_text_contents()
    assert "present_files" not in names, (
        f"a presented file must keep its own card, not become a chain row, got {names}"
    )
