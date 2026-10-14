"""The document viewer COVERS the chat it was opened from.

Repro: click a session in the RECENT list, then click a document. The URL
becomes `/app/<ws>/chat/<session>?doc=<id>`, which mounts the ChatView AND
the DocumentsView overlay at the same time. The document is meant to cover
the chat (it is an `absolute inset-0` overlay inside the same `<main>`), but
the chat's floating chrome painted ON TOP of it: the composer dock, the
scroll-to-bottom arrow and the scroll slider were all visible over the
document body, which made the viewer look broken.

The cause was a missing stacking context, and the whole reason this is a
browser test: `main` and `.chat-column` are both `position: relative` with
`z-index: auto`, which does NOT open a stacking context. So the chat's
z-ladder (scroll slider / pill rail 20, composer dock 30, scroll-to-bottom
31) and the document overlay's `z-index: 10` were all compared in the ROOT
stacking context, where every chat tier outranks 10 and wins. jsdom has no
layout engine and does not apply SFC `<style>` blocks, so it can see
neither the computed `isolation` nor the resulting paint order — both halves
of this contract are invisible to the unit suite.

What is asserted here, by `elementFromPoint` (hit-testing walks the same
stacking order that painting does, so the returned element is the one the
user actually sees):

  1. `elementFromPoint` at the centre of the composer card, the
     scroll-to-bottom arrow and the scroll slider all land INSIDE the
     document overlay — i.e. the document, not the chat, is on top;
  2. `.chat-column` actually computes `isolation: isolate`, so the
     containment is real rather than an accidental z-index coincidence;
  3. the chat is still MOUNTED underneath, because the overlay is
     deliberately an overlay — that is what keeps a Back/Forward or a
     document switch instant. If the chat were simply unmounted, the paint
     order would look right while the behaviour regressed.

The unit half of the contract lives in
`src/apps/desktop/src/__tests__/ChatView.stackingContainment.spec.ts`.

Run (frontend served from THIS worktree; the backend binary may come from
anywhere since only frontend code is under test):
    PABRIK_BIN=/home/ginwa/ginwaaitoolbox/zig-out/bin/pabrikcore-linux-x86_64 \\
        /tmp/pabrik-ui-venv/bin/python -m pytest -s \\
        tests/functional_ui/document_page_replaces_chat_test.py -v
"""

from __future__ import annotations

from db_seed import DbSeed

BODY = (
    "Message {i} paragraph one.\\n\\n"
    "Message {i} paragraph two with longer text so the bubble has real "
    "height in the virtual scroller. Lorem ipsum dolor sit amet, "
    "consectetur adipiscing elit, sed do eiusmod tempor incididunt ut "
    "labore et dolore magna aliqua.\\n\\n"
    "Message {i} paragraph three with even more filler so each bubble "
    "measures a few hundred pixels tall in real layout."
)


def _seed_db_path(h) -> "object":
    return h.temp_dir / ".config" / "pabrik" / "agent.db"


def _seed_session(h, session_id: str, workspace_id: str, count: int = 40) -> None:
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Doc covers chat")
        conn.execute(
            "UPDATE sessions SET workspace_id = ? WHERE id = ?",
            (workspace_id, session_id),
        )
        stamps = DbSeed.baseline_timestamps(count=count, interval_seconds=30)
        for i in range(count):
            body = BODY.format(i=i)
            if i % 2 == 0:
                seed.seed_user_message(conn, session_id, body, created_at=stamps[i])
            else:
                seed.seed_assistant_message(conn, session_id, body, created_at=stamps[i])


def _open_chat_then_document(ui_harness, page, session_id: str) -> tuple[str, str]:
    """The exact repro: chat session first, then the document over it."""
    h = ui_harness
    ws = h.http("POST", "/api/workspaces", json_body={"name": "doc-over-chat-ws"}, expect=201)
    workspace_id = ws.json()["id"]
    _seed_session(h, session_id, workspace_id)

    # A real document, created over the API so the viewer has a body.
    doc = h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/documents",
        json_body={
            "title": "Release plan",
            "content": "# Release plan\\n\\nShip the viewer fix.\\n",
        },
        expect=201,
    )
    document_id = doc.json()["document"]["id"]

    # Step 1 — the session is open. A ChatView is now mounted.
    page.goto(
        h.web_url(f"/app/{workspace_id}/chat/{session_id}"),
        wait_until="load",
        timeout=60000,
    )
    page.wait_for_function(
        "() => { const w = document.querySelector('.messages-scroll-hide-native');"
        " return !!(w && w.querySelector('.virtual-scroller')); }",
        timeout=20000,
    )
    page.wait_for_function(
        "() => { const d = document.querySelector('.composer-dock');"
        " return !!d && d.offsetHeight > 0; }",
        timeout=20000,
    )
    page.wait_for_timeout(2500)

    # Step 2 — click a document. It is its own PAGE now
    # (`/app/{ws}/doc/{id}`), so this REPLACES the chat rather than
    # layering over it — which is what removes the reported bug.
    page.goto(
        h.web_url(f"/app/{workspace_id}/doc/{document_id}"),
        wait_until="load",
        timeout=60000,
    )
    page.wait_for_selector('[data-testid="documents-view"]', timeout=20000)
    page.wait_for_selector('[data-testid="documents-rendered"]', timeout=20000)
    page.wait_for_timeout(1500)
    return workspace_id, document_id


#: Whether the chat is still mounted inside the MAIN VIEW AREA.
#:
#: Scoped to <main> on purpose: a bare `document.querySelector` also finds
#: the sidebar's and right sidebar's own virtual scrollers, which are
#: always present and say nothing about the main view.
#:
#: The document is a PAGE, so the strongest statement is not "the overlay
#: covers the chat" but "the chat is GONE". Asserting only the former
#: would pass against the old overlay design too — that is exactly the
#: shape that shipped the bug.
_PROBE_SCRIPT = r"""
() => {
  const main = document.querySelector('main');
  const overlay = document.querySelector('[data-testid="documents-view"]');
  if (!overlay || !main) return { missing: true };

  const describe = (el) => {
    if (!el) return 'null';
    const tid = el.getAttribute('data-testid');
    return el.tagName + (tid ? '#' + tid : '');
  };
  const mid = (el) => {
    const r = el.getBoundingClientRect();
    return [r.left + r.width / 2, r.top + r.height / 2];
  };
  const targets = {
    composerCard: main.querySelector('.composer-card'),
    scrollToBottom: main.querySelector('.chat-scroll-to-bottom'),
    scrollSlider: main.querySelector('.chat-scroll-slider'),
  };
  const points = {};
  for (const [name, el] of Object.entries(targets)) {
    if (!el) { points[name] = { absent: true }; continue; }
    const [x, y] = mid(el);
    const hit = document.elementFromPoint(x, y);
    points[name] = {
      point: [Math.round(x), Math.round(y)],
      hit: describe(hit),
      insideDocOverlay: !!(hit && overlay.contains(hit)),
    };
  }

  const column = main.querySelector('.chat-column');
  return {
    missing: false,
    points,
    // A document is its own page: nothing of the chat is left mounted.
    chatColumnPresent: !!column,
    composerPresent: !!main.querySelector('.composer-dock'),
    scrollerPresent: !!main.querySelector('.virtual-scroller'),
    kanbanPresent: !!main.querySelector('[data-kanban-view="stub"], .kanban-view'),
    isolation: column ? getComputedStyle(column).isolation : null,
    docTitle: (document.querySelector('[data-testid="documents-title"]') || {}).textContent || '',
  };
}
"""


def test_document_page_replaces_the_chat(ui_harness, page) -> None:
    session_id = "sess-doc-covers-chat"
    workspace_id, document_id = _open_chat_then_document(ui_harness, page, session_id)

    p = page.evaluate(_PROBE_SCRIPT)
    print(f"\n[doc-page] probe: {p}")
    assert not p.get("missing"), "document page not found"

    assert p["docTitle"].strip() == "Release plan", (
        f"document title is {p['docTitle']!r}, expected 'Release plan' — "
        "the page may not have loaded at all"
    )

    # The document owns the main view. The chat it was opened from is
    # unmounted, so there is nothing left to paint over the document.
    assert not p["chatColumnPresent"], (
        "the chat column is still mounted behind the document; a document is "
        "a PAGE now, so it must replace the view rather than overlay it"
    )
    assert not p["composerPresent"], (
        "the composer dock survived the document page — this is the "
        "reported bug (chat chrome painted over the document)"
    )
    assert not p["scrollerPresent"], "the chat transcript survived the document page"


def test_document_page_carries_no_chat_z_index_leak(ui_harness, page) -> None:
    """Whatever is painted at the chrome's old position must be the doc.

    With the chat unmounted there is nothing at those coordinates but the
    document, so this is a belt-and-braces check that the page really is
    the only surface there — it would fail if a future refactor put a
    floating overlay back without the chat's stacking containment.
    """
    session_id = "sess-doc-isolation"
    _open_chat_then_document(ui_harness, page, session_id)

    p = page.evaluate(_PROBE_SCRIPT)
    print(f"\n[doc-page] paint: {p}")
    assert not p.get("missing"), "document page not found"

    # Every probe target is gone with the chat; assert that explicitly
    # rather than skipping, so a regression that resurrects the chrome
    # cannot make this test vacuously true.
    for name, pt in p["points"].items():
        assert pt.get("absent"), (
            f"{name} is still in the DOM on a document page ({pt}) — the "
            "chat surface should be unmounted, not just covered"
        )
