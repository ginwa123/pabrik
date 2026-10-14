"""The Documents section must sit DIRECTLY under Projects — measured in pixels.

The report was "why is the document menu at the bottom, and so far away".
The cause was `flex-1` on the wrapper around `<ProjectsList>` inside the
sidebar `<nav>`: the Projects section absorbed every pixel the other two
sections did not need, so `<DocumentsList>` — the last child, `shrink-0`
— was pushed to the very bottom of the sidebar, with a screen-tall empty
box in between.

This is the measuring half of the regression. The cheap half is
``src/apps/desktop/src/__tests__/Sidebar.documentsSectionPlacement.spec.ts``,
which pins the structural contract; jsdom has no layout engine, so only a
real browser can prove the gap actually closed.

Run:
    PABRIK_BIN=<worktree>/zig-out/bin/pabrikcore-linux-x86_64 \\
        /tmp/pabrik-ui-venv/bin/python -m pytest -s \\
        tests/functional_ui/sidebar_documents_placement_test.py -v
"""

from __future__ import annotations

# The Projects section header sits in this `[data-workspace-menu]` wrapper,
# so its parent element IS the ProjectsList root — the box that used to be
# `flex-1` and eat the sidebar.
_PROJECTS_SECTION_JS = """
() => {
  const header = document.querySelector('[data-workspace-menu]');
  if (!header) return { error: 'no [data-workspace-menu] — Projects section did not render' };
  const projects = header.parentElement;
  const documents = document.querySelector('[data-testid="documents-section"]');
  const nav = document.querySelector('aside nav') || document.querySelector('nav');
  if (!documents) return { error: 'no documents section' };
  if (!nav) return { error: 'no nav' };

  const box = (el) => {
    const r = el.getBoundingClientRect();
    return { top: r.top, bottom: r.bottom, height: r.height };
  };

  // The bottom of the last PROJECT ROW — not of the Projects box.
  //
  // This distinction is the whole bug. `flex-1` made the Projects BOX as
  // tall as the sidebar, but the box's own bottom still touched the
  // Documents header, so "gap between the two boxes" measured 0 on the
  // broken layout. The empty space lives INSIDE the Projects box, between
  // the header and where the rows actually end — which is exactly the
  // dead space the report is pointing at.
  const rows = [...projects.querySelectorAll('li')];
  const rowsBottom = rows.length
    ? Math.max(...rows.map((el) => el.getBoundingClientRect().bottom))
    : null;

  // Slack inside the Projects box: how much taller it is than its rows.
  const slack = rowsBottom === null ? null : projects.getBoundingClientRect().bottom - rowsBottom;

  // Every element inside the nav that is a scroll container of its own,
  // split by which section owns it. The Recent section legitimately has
  // one — it is the user-drag-resizable panel — so it is reported
  // separately instead of being swept into the Projects/Documents count.
  const nestedScrollers = (root) =>
    [...root.querySelectorAll('*')]
      .filter((el) => {
        const oy = getComputedStyle(el).overflowY;
        return oy === 'auto' || oy === 'scroll';
      })
      .map((el) => el.getAttribute('data-testid') || el.className.split(' ').slice(0, 3).join('.'));

  return {
    nav: box(nav),
    projects: box(projects),
    rowsBottom,
    slack,
    documents: box(documents),
    projectsOverflow: {
      scrollHeight: projects.scrollHeight,
      clientHeight: projects.clientHeight,
      overflowY: getComputedStyle(projects).overflowY,
    },
    documentsOverflow: {
      scrollHeight: documents.scrollHeight,
      clientHeight: documents.clientHeight,
      overflowY: getComputedStyle(documents).overflowY,
    },
    navOverflowY: getComputedStyle(nav).overflowY,
    projectsScrollers: nestedScrollers(projects),
    documentsScrollers: nestedScrollers(documents),
    recentScrollers: [...nav.querySelectorAll('*')]
      .filter((el) => {
        const oy = getComputedStyle(el).overflowY;
        return (oy === 'auto' || oy === 'scroll')
          && !projects.contains(el) && !documents.contains(el);
      })
      .map((el) => el.getAttribute('data-testid') || el.className.split(' ').slice(0, 3).join('.')),
    projectRows: projects.querySelectorAll('[data-testid="item-task-count"], li').length,
  };
}
"""


def _seed_documents(h, workspace_id: str, count: int = 3) -> None:
    for i in range(count):
        h.http(
            "POST",
            f"/api/workspaces/{workspace_id}/documents",
            json_body={"title": f"Doc {i + 1}", "content": f"Body {i + 1}.\n"},
            expect=201,
        )


def _expand_documents(page) -> None:
    """The section is collapsed more often than not; a blind click would COLLAPSE it."""
    if page.locator('[data-testid="documents-section-body"]').count() == 0:
        page.locator('[data-testid="documents-section-header"]').first.click()
    page.wait_for_selector('[data-testid="documents-section-body"]', timeout=20000)


def _collapse_recent(page) -> None:
    """Collapse the Recent section — this is the state in the bug report.

    Reproducing the screenshot matters. With Recent expanded at its
    default ~40% the leftover for Projects is small enough that even the
    BUGGY `flex-1` wrapper happens to produce a zero gap, and a test that
    passes on the broken layout is worse than no test. In the report
    Recent is collapsed (`▶ RECENT`), Documents is expanded (`▼`), and
    that is the combination that let Projects eat the whole sidebar.
    """
    title = page.locator('[data-testid="recent-section-title"]')
    if title.count() == 0:
        return
    # The chevron points right when collapsed, down when expanded.
    expanded = page.evaluate(
        "() => { const c = document.querySelector('[data-testid=\"recent-section-title\"]')"
        "  ?.closest('button')?.querySelector('span');"
        "  return c ? getComputedStyle(c).transform !== 'none' : false }"
    )
    if expanded:
        title.locator("xpath=ancestor::button[1]").click()
        page.wait_for_timeout(300)


def test_documents_sits_directly_under_projects(ui_harness, page) -> None:
    """The whole report, as one number: how far below Projects Documents starts."""
    h = ui_harness
    ws = h.http("POST", "/api/workspaces", json_body={"name": "placement-ws"}, expect=201)
    workspace_id = ws.json()["id"]
    _seed_documents(h, workspace_id)

    page.goto(h.web_url(f"/app/{workspace_id}"), wait_until="load", timeout=60000)
    # The sidebar shell is up once the New Chat action has rendered.
    page.wait_for_selector('[data-testid="sidebar-new-chat-button"]', timeout=20000)
    page.wait_for_selector('[data-workspace-menu]', timeout=20000)
    _collapse_recent(page)
    _expand_documents(page)
    page.wait_for_timeout(500)

    m = page.evaluate(_PROJECTS_SECTION_JS)
    assert "error" not in m, m["error"]
    print(f"\n[placement] {m}")

    # Precondition: Recent really is collapsed, so the sidebar has the
    # leftover height the report describes. Without this the numbers below
    # can look healthy on the buggy layout.
    assert m["projects"]["top"] - m["nav"]["top"] < 120, (
        f"Recent is still expanded (Projects starts {m['projects']['top'] - m['nav']['top']:.0f}px "
        f"below the nav top). Collapse it first — the reported layout is the collapsed one."
    )

    assert m["rowsBottom"] is not None, "the Projects section rendered no rows to measure"

    # Two views of the same dead space.
    #
    #  - `slack`   : the Projects BOX is far taller than its own rows.
    #  - `row_gap` : Documents starts that far below the last project ROW.
    #
    # Both are needed. Measuring only the gap between the two BOXES reads
    # 0 on the broken layout, because the box's bottom still touched the
    # Documents header — the empty space was inside the box. That is why
    # this test passed on the buggy code until the row was measured.
    slack = m["slack"]
    row_gap = m["documents"]["top"] - m["rowsBottom"]

    # One sidebar row is 32px. Past ~1 row of slack, a filler box has
    # crept back between the projects and the documents.
    assert slack < 32, (
        f"the Projects section is {m['projects']['height']:.0f}px tall for "
        f"{m['projectRows']} row(s) — {slack:.0f}px of it is empty filler, and "
        f"Documents starts {row_gap:.0f}px below the last project row "
        f"(nav is {m['nav']['height']:.0f}px tall). The `flex-1` filler is back; "
        f"this is the reported bug."
    )
    assert row_gap < 32, (
        f"Documents starts {row_gap:.0f}px below the last project row, with "
        f"{slack:.0f}px of the gap being empty Projects box."
    )

    # And the Projects section must be sized by its ROWS, not by the space
    # left over. If scrollHeight still exceeds clientHeight it is a
    # scroll container again, which is what the gap alone would not catch.
    assert m["projectsOverflow"]["overflowY"] not in ("auto", "scroll"), (
        f"Projects is a scroll container of its own again "
        f"(overflow-y: {m['projectsOverflow']['overflowY']})"
    )
    assert m["projectsOverflow"]["scrollHeight"] <= m["projectsOverflow"]["clientHeight"] + 1, (
        f"Projects content overflows its box "
        f"({m['projectsOverflow']['scrollHeight']} > {m['projectsOverflow']['clientHeight']})"
    )


def test_projects_and_documents_do_not_scroll_themselves(ui_harness, page) -> None:
    """The <nav> owns the scroll for the two sections this bug was about.

    Scoped on purpose. The Recent section legitimately keeps a scroll
    container of its own — it is the panel the user drag-resizes — so
    "no nested scrollers anywhere" would be asserting a design that does
    not exist. What must hold is that Projects and Documents are sized by
    their content and let the <nav> do the scrolling.
    """
    h = ui_harness
    ws = h.http("POST", "/api/workspaces", json_body={"name": "placement-scroll-ws"}, expect=201)
    workspace_id = ws.json()["id"]
    _seed_documents(h, workspace_id, count=4)

    page.goto(h.web_url(f"/app/{workspace_id}"), wait_until="load", timeout=60000)
    page.wait_for_selector('[data-workspace-menu]', timeout=20000)
    _expand_documents(page)
    page.wait_for_timeout(500)

    m = page.evaluate(_PROJECTS_SECTION_JS)
    assert "error" not in m, m["error"]
    print(
        f"\n[scroll ownership] nav={m['navOverflowY']} "
        f"projects={m['projectsScrollers']} documents={m['documentsScrollers']} "
        f"recent={m['recentScrollers']}"
    )

    assert m["navOverflowY"] in ("auto", "scroll"), (
        f"the sidebar <nav> is not the scroller (overflow-y: {m['navOverflowY']})"
    )
    assert m["projectsScrollers"] == [], (
        f"Projects grows a scroll container again: {m['projectsScrollers']}"
    )
    assert m["documentsScrollers"] == [], (
        f"Documents grows a scroll container again: {m['documentsScrollers']}"
    )