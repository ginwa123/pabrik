"""The CLICK path, not a hard navigation.

`page.goto` remounts the whole app, so it can never show a stale subtree
left behind by a client-side transition. The user clicks a document row in
the sidebar, which is a `router.replace` inside a live SPA — a completely
different code path. This drives the real click.

Run:
    PABRIK_BIN=<worktree>/zig-out/bin/pabrikcore-linux-x86_64 \\
        /tmp/pabrik-ui-venv/bin/python -m pytest -s \\
        tests/functional_ui/document_page_click_test.py -v
"""

from __future__ import annotations

from db_seed import DbSeed

BODY = "Message {i} with enough text to give the bubble real height in a real layout."


def _seed_db_path(h):
    return h.temp_dir / ".config" / "pabrik" / "agent.db"


def _seed_session(h, session_id: str, workspace_id: str, count: int = 12) -> None:
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Doc click")
        conn.execute("UPDATE sessions SET workspace_id = ? WHERE id = ?", (workspace_id, session_id))
        stamps = DbSeed.baseline_timestamps(count=count, interval_seconds=30)
        for i in range(count):
            if i % 2 == 0:
                seed.seed_user_message(conn, session_id, BODY.format(i=i), created_at=stamps[i])
            else:
                seed.seed_assistant_message(conn, session_id, BODY.format(i=i), created_at=stamps[i])


_STATE_SCRIPT = r"""
() => ({
  url: location.pathname + location.search,
  hasDocView: !!document.querySelector('[data-testid="documents-view"]'),
  chatColumn: document.querySelectorAll('.chat-column').length,
  composerDock: document.querySelectorAll('.composer-dock').length,
  composerCard: document.querySelectorAll('.composer-card').length,
  textarea: document.querySelectorAll('[data-testid="chat-message-textarea"]').length,
  scrollSlider: document.querySelectorAll('.chat-scroll-slider').length,
  // Which elements of the CHAT survived, and where they sit.
  chatHosts: [...document.querySelectorAll('.chat-column, .composer-dock')].map((e) => ({
    cls: e.className.split(' ').slice(0, 2).join('.'),
    inMain: !!e.closest('main'),
    inAside: !!e.closest('aside'),
    inBody: !e.closest('main') && !e.closest('aside'),
    visible: !!(e.offsetWidth || e.offsetHeight),
  })),
  // The decisive dump: what is actually mounted under <main>.
  mainKids: [...document.querySelectorAll('main > *')].map((e) => {
    const tid = e.getAttribute('data-testid');
    const cls = (e.className || '').toString().split(' ').filter(Boolean).slice(0, 3).join('.');
    const kids = [...e.children].map(
      (k) =>
        k.tagName.toLowerCase() +
        (k.getAttribute('data-testid') ? '#' + k.getAttribute('data-testid') : '') +
        (k.className ? '.' + k.className.toString().split(' ')[0] : ''),
    );
    return { tag: e.tagName.toLowerCase() + (tid ? '#' + tid : ''), cls, kids: kids.slice(0, 6) };
  }),
  docViewCls: (document.querySelector('[data-testid="documents-view"]') || {}).className || null,
})
"""


def test_clicking_a_document_row_unmounts_the_chat(ui_harness, page) -> None:
    h = ui_harness
    ws = h.http("POST", "/api/workspaces", json_body={"name": "click-ws"}, expect=201)
    workspace_id = ws.json()["id"]
    _seed_session(h, "sess-click", workspace_id)

    doc = h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/documents",
        json_body={"title": "Untitled document", "content": "# Untitled document\n\nBody.\n"},
        expect=201,
    )
    document_id = doc.json()["document"]["id"]

    # Boot straight onto the chat, exactly like the repro.
    page.goto(
        h.web_url(f"/app/{workspace_id}/chat/sess-click"), wait_until="load", timeout=60000
    )
    page.wait_for_function("() => !!document.querySelector('.composer-dock')", timeout=20000)
    page.wait_for_timeout(1500)
    print(f"\n[click] ON CHAT: {page.evaluate(_STATE_SCRIPT)}")

    # The section may already be expanded (the flag is persisted), so a
    # blind click can COLLAPSE it. Only click when the body is absent.
    if page.locator('[data-testid="documents-section-body"]').count() == 0:
        page.locator('[data-testid="documents-section-header"]').first.click()
    try:
        page.wait_for_selector(f'[data-testid="document-row-{document_id}"]', timeout=25000)
    except Exception:
        body = page.locator('[data-testid="documents-section-body"]')
        txt = body.first.inner_text() if body.count() else "(no section body — header click did not expand)"
        raise AssertionError(f"the document row never appeared. Section text: {txt!r}")
    row = page.locator(f'[data-testid="document-row-{document_id}"]')
    row.first.click()
    page.wait_for_timeout(3000)

    after = page.evaluate(_STATE_SCRIPT)
    print(f"\n[click] AFTER CLICK: {after}")

    assert after["url"].endswith(f"/doc/{document_id}"), f"URL is not the document page: {after['url']}"
    assert after["hasDocView"], "the document did not render"
    for key in ("chatColumn", "composerDock", "composerCard", "textarea", "scrollSlider"):
        assert after[key] == 0, (
            f"{key} survived the click: {after['chatHosts']} — this is the reported bug"
        )
