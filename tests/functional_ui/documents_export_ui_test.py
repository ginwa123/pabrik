"""Exporting documents from the sidebar — real browser, real backend, real download.

The feature is "export like a browser document": right-click a row in the Documents section, pick
Export, and the browser saves the file. Three things are proven here, and the third is the one that
usually rots:

1. A right-click on a document row opens the action menu, and the menu's label counts what it will
   write ("Export document" for one, "Export 2 documents" for a selection).
2. Ctrl-click builds a multi-document selection; a plain click still opens the document.
3. Picking an export row produces a REAL browser download whose bytes are the document's body (one
   file) or a zip holding every selected document (several).

Run:
    PABRIK_BIN=<worktree>/zig-out/bin/pabrik \\
      <repo>/.venv-func/bin/python -m pytest \\
      tests/functional_ui/documents_export_ui_test.py -v -s
"""

from __future__ import annotations

import zipfile
from pathlib import Path

from ui_harness import UIHarness


def _create_workspace(h: UIHarness, name: str) -> str:
    return h.http("POST", "/api/workspaces", json_body={"name": name}, expect=201).json()["id"]


def _create_document(h: UIHarness, workspace_id: str, title: str, content: str, fmt: str = "markdown") -> str:
    body = {"title": title, "content": content}
    if fmt != "markdown":
        body["format"] = fmt
    return h.http(
        "POST", f"/api/workspaces/{workspace_id}/documents", json_body=body, expect=201
    ).json()["document"]["id"]


def _boot_documents(h: UIHarness, page, workspace_id: str, first_doc_id: str) -> None:
    """Open the workspace page and wait for the Documents section to paint its rows."""
    page.goto(h.web_url(f"/app/{workspace_id}"), wait_until="domcontentloaded", timeout=60000)
    row = page.locator(f'[data-testid="document-row-{first_doc_id}"]')
    try:
        row.wait_for(timeout=15000, state="visible")
    except Exception:
        # The section can start collapsed on a returning profile.
        page.locator('[data-testid="documents-section-title"]').click()
        row.wait_for(timeout=15000, state="visible")


def _open_menu(page, doc_id: str) -> None:
    page.locator(f'[data-testid="document-row-{doc_id}"]').click(button="right")
    page.locator('[data-testid="documents-context-menu"]').wait_for(timeout=10000, state="visible")


def test_export_one_document_downloads_its_body(ui_harness: UIHarness, page, artifacts_dir: Path) -> None:
    h = ui_harness
    ws = _create_workspace(h, "ui-doc-export-one")
    doc = _create_document(h, ws, "Release plan", "# v1\n\nship it")

    _boot_documents(h, page, ws, doc)
    _open_menu(page, doc)

    label = page.locator('[data-testid="documents-context-menu-export"]').inner_text().strip()
    assert label == "Export document", f"menu row read {label!r} for a single selection"

    # The screenshot the task asks for: the menu open on a real document row.
    shot = artifacts_dir / "documents-export-menu.png"
    page.screenshot(path=str(shot))
    print(f"\n[screenshot] {shot}")

    with page.expect_download(timeout=20000) as download_info:
        page.locator('[data-testid="documents-context-menu-export"]').click()
    download = download_info.value

    assert download.suggested_filename == "Release plan.md", (
        f"downloaded as {download.suggested_filename!r} — the server's Content-Disposition "
        "filename did not reach the browser"
    )
    saved = artifacts_dir / download.suggested_filename
    download.save_as(str(saved))
    assert saved.read_text() == "# v1\n\nship it", "the downloaded bytes are not the document body"

    # The sidebar reports what it did, so the user is not left guessing whether the click worked.
    notice = page.locator('[data-testid="documents-export-notice"]')
    notice.wait_for(timeout=10000, state="visible")
    assert "Exported Release plan.md" in notice.inner_text()


def test_export_a_selection_downloads_one_zip(ui_harness: UIHarness, page, artifacts_dir: Path) -> None:
    h = ui_harness
    ws = _create_workspace(h, "ui-doc-export-many")
    first = _create_document(h, ws, "Plan", "# plan")
    second = _create_document(
        h, ws, "Budget", '{"kind":"sheet","snapshot":{"sheets":{}}}', fmt="office"
    )

    _boot_documents(h, page, ws, first)

    # Ctrl-click both rows: the selection is what the menu's count must describe.
    page.locator(f'[data-testid="document-row-{first}"]').click(modifiers=["Control"])
    page.locator(f'[data-testid="document-row-{second}"]').click(modifiers=["Control"])
    _open_menu(page, second)

    label = page.locator('[data-testid="documents-context-menu-export"]').inner_text().strip()
    assert label == "Export 2 documents", f"menu row read {label!r} for a two-document selection"

    shot = artifacts_dir / "documents-export-selection.png"
    page.screenshot(path=str(shot))
    print(f"\n[screenshot] {shot}")

    with page.expect_download(timeout=20000) as download_info:
        page.locator('[data-testid="documents-context-menu-export"]').click()
    download = download_info.value

    assert download.suggested_filename == "documents.zip", (
        f"downloaded as {download.suggested_filename!r}, not the archive"
    )
    saved = artifacts_dir / download.suggested_filename
    download.save_as(str(saved))

    with zipfile.ZipFile(saved) as archive:
        names = sorted(archive.namelist())
        assert names == ["Budget.json", "Plan.md"], f"archive holds {names}"
        assert archive.read("Plan.md") == b"# plan"
        assert b'"kind":"sheet"' in archive.read("Budget.json")


def test_export_all_writes_every_document(ui_harness: UIHarness, page, artifacts_dir: Path) -> None:
    h = ui_harness
    ws = _create_workspace(h, "ui-doc-export-all")
    first = _create_document(h, ws, "One", "one")
    _create_document(h, ws, "Two", "two")

    _boot_documents(h, page, ws, first)
    _open_menu(page, first)

    with page.expect_download(timeout=20000) as download_info:
        page.locator('[data-testid="documents-context-menu-export-all"]').click()
    download = download_info.value

    saved = artifacts_dir / download.suggested_filename
    download.save_as(str(saved))
    with zipfile.ZipFile(saved) as archive:
        assert sorted(archive.namelist()) == ["One.md", "Two.md"]
