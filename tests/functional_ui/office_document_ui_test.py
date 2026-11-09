"""The office document page, driven in a real browser.

Two bugs lived here and neither was visible to a unit test:

1. A document created as "Office document" (docx) opened a **spreadsheet**.
   `DocumentsView` mounted the editor as soon as the row existed, and the body
   it handed over was still `''` — `parseOfficeBody('')` returns the default
   kind, `sheet`.
2. Nothing typed into it survived a reload, because Save wrote that blank
   workbook under the document's real kind.

Both are timing bugs in a live SPA, so they are asserted here: create through
the sidebar menu (the path a user takes), type, Save, reload, read back.

Run:
    PABRIK_BIN=<worktree>/zig-out/bin/pabrikcore-linux-x86_64 \\
        /tmp/pabrik-ui-venv/bin/python -m pytest -s \\
        tests/functional_ui/office_document_ui_test.py -v
"""

from __future__ import annotations

import json

# The Univer ribbon is the discriminator: the sheets preset renders
# "Start | Formulas | View", the docs preset "Start | Insert | View". Both live
# inside the editor surface, so the sidebar's own text cannot confuse it.
_EDITOR_STATE = r"""
() => {
  const surface = document.querySelector('[data-testid="office-document-editor-surface"]')
  const text = surface ? surface.innerText : ''
  return {
    url: location.pathname,
    title: (document.querySelector('[data-testid="documents-title"]') || {}).textContent || null,
    hasSurface: !!surface,
    canvases: surface ? surface.querySelectorAll('canvas').length : 0,
    loading: !!document.querySelector('[data-testid="documents-office-loading"]'),
    error: (document.querySelector('[data-testid="office-document-editor-error"]') || {}).textContent || null,
    sheetsRibbon: text.includes('Formulas'),
    docsRibbon: text.includes('Insert'),
  }
}
"""


def _editor_kind(state: dict) -> str:
    if state["sheetsRibbon"] and not state["docsRibbon"]:
        return "sheet"
    if state["docsRibbon"] and not state["sheetsRibbon"]:
        return "doc"
    return "unknown"


def _wait_for_editor(page, timeout_ms: int = 60000) -> dict:
    """Wait until the editor has painted, then return its state.

    A canvas is the "Univer mounted" signal: the surface exists before the
    preset has rendered anything into it.
    """
    page.wait_for_selector('[data-testid="office-document-editor-surface"]', timeout=timeout_ms)
    page.wait_for_function(
        "() => document.querySelectorAll("
        "'[data-testid=\"office-document-editor-surface\"] canvas').length > 0",
        timeout=timeout_ms,
    )
    # The ribbon is part of the first paint, but give the preset a beat to
    # finish laying it out before reading its text.
    page.wait_for_timeout(2500)
    return page.evaluate(_EDITOR_STATE)


def _open_documents_section(page) -> None:
    """Expand the sidebar's Documents section if it is collapsed.

    The flag is persisted, so a blind click can COLLAPSE an already-open
    section — only click when the body is absent.
    """
    if page.locator('[data-testid="documents-section-body"]').count() == 0:
        page.locator('[data-testid="documents-section-header"]').first.click()
        page.wait_for_selector('[data-testid="documents-section-body"]', timeout=15000)


def _create_from_menu(page, h, workspace_id: str, choice_testid: str) -> str:
    """Create a document through the sidebar's "New Document" menu.

    Returns the new document's id, taken from the URL the app navigates to.
    """
    page.goto(h.web_url(f"/app/{workspace_id}"), wait_until="load", timeout=60000)
    page.wait_for_selector('[data-testid="documents-add-button"]', timeout=30000)
    page.wait_for_timeout(1200)
    page.click('[data-testid="documents-add-button"]')
    page.wait_for_selector('[data-testid="documents-new-menu"]', timeout=10000)
    page.click(f'[data-testid="{choice_testid}"]')
    page.wait_for_function(
        "() => location.pathname.includes('/doc/')", timeout=30000
    )
    return page.evaluate("() => location.pathname.split('/').pop()")


def _stored_body(h, workspace_id: str, document_id: str) -> tuple[dict, dict]:
    r = h.http("GET", f"/api/workspaces/{workspace_id}/documents/{document_id}", expect=200)
    doc = r.json()["document"]
    return doc, json.loads(doc["content"]) if doc["content"] else {}


def test_an_office_document_opens_the_docs_editor_not_a_spreadsheet(ui_harness, page) -> None:
    h = ui_harness
    ws = h.http("POST", "/api/workspaces", json_body={"name": "office-docx"}, expect=201)
    workspace_id = ws.json()["id"]

    document_id = _create_from_menu(page, h, workspace_id, "documents-new-doc")
    state = _wait_for_editor(page)
    print(f"\n[docx] {state}")

    assert state["error"] is None, f"the editor reported a failure: {state['error']}"
    assert not state["loading"], "the page is still on 'Loading document…'"
    assert _editor_kind(state) == "doc", (
        f"an office DOCUMENT opened the {_editor_kind(state)} editor: {state}"
    )

    # And the body it was created with is a document envelope, not a workbook.
    doc, body = _stored_body(h, workspace_id, document_id)
    assert doc["format"] == "office", doc
    assert body["kind"] == "doc", body
    assert "sheetOrder" not in body["snapshot"], (
        f"a docx was created with a workbook snapshot: {sorted(body['snapshot'])[:8]}"
    )


def test_typing_survives_save_and_a_reload(ui_harness, page) -> None:
    h = ui_harness
    ws = h.http("POST", "/api/workspaces", json_body={"name": "office-save"}, expect=201)
    workspace_id = ws.json()["id"]

    document_id = _create_from_menu(page, h, workspace_id, "documents-new-doc")
    _wait_for_editor(page)

    typed = "Quarterly numbers for the board."
    page.click('[data-testid="office-document-editor-surface"]')
    page.wait_for_timeout(1000)
    page.keyboard.type(typed)
    page.wait_for_timeout(2000)

    page.click('[data-testid="documents-save"]')
    page.wait_for_timeout(3000)

    doc, body = _stored_body(h, workspace_id, document_id)
    print(f"\n[save] kind={body['kind']} bytes={doc['content_bytes']}")
    assert body["kind"] == "doc", body
    assert "body" in body["snapshot"], (
        f"the saved snapshot is not a document: {sorted(body['snapshot'])[:8]}"
    )
    assert typed in json.dumps(body["snapshot"]), "the typed text is not in the stored body"

    # The reload is the half the user reported: the page must come back as the
    # same document, with the same text.
    page.reload(wait_until="load")
    state = _wait_for_editor(page)
    print(f"[reload] {state}")

    assert state["error"] is None, f"the editor reported a failure after reload: {state['error']}"
    assert _editor_kind(state) == "doc", (
        f"after a reload the document opened the {_editor_kind(state)} editor: {state}"
    )

    _, after = _stored_body(h, workspace_id, document_id)
    assert typed in json.dumps(after["snapshot"]), "the text was lost across the reload"


def test_a_spreadsheet_opens_the_sheets_editor_and_keeps_its_cells(ui_harness, page) -> None:
    h = ui_harness
    ws = h.http("POST", "/api/workspaces", json_body={"name": "office-xlsx"}, expect=201)
    workspace_id = ws.json()["id"]

    document_id = _create_from_menu(page, h, workspace_id, "documents-new-sheet")
    state = _wait_for_editor(page)
    print(f"\n[xlsx] {state}")

    assert state["error"] is None, f"the editor reported a failure: {state['error']}"
    assert _editor_kind(state) == "sheet", (
        f"an office SPREADSHEET opened the {_editor_kind(state)} editor: {state}"
    )

    page.click('[data-testid="office-document-editor-surface"]')
    page.wait_for_timeout(800)
    page.keyboard.type("1200")
    page.keyboard.press("Enter")
    page.wait_for_timeout(2000)

    page.click('[data-testid="documents-save"]')
    page.wait_for_timeout(3000)

    doc, body = _stored_body(h, workspace_id, document_id)
    print(f"[save] kind={body['kind']} bytes={doc['content_bytes']}")
    assert body["kind"] == "sheet", body
    assert "sheetOrder" in body["snapshot"], (
        f"the saved snapshot is not a workbook: {sorted(body['snapshot'])[:8]}"
    )
    assert "1200" in json.dumps(body["snapshot"]), "the typed value is not in the stored body"

    page.reload(wait_until="load")
    state = _wait_for_editor(page)
    assert _editor_kind(state) == "sheet", (
        f"after a reload the spreadsheet opened the {_editor_kind(state)} editor: {state}"
    )
