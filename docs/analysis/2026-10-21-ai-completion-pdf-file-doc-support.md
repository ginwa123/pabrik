# Can the Pabrik chat attach a PDF / file / document to the model?

**Card:** `task_1792523186979_4` — "Is AI Completion open ai support pdf or file or docs ?"
**Date:** 2026-10-21 · **Audited rev:** `969952c5d` (main)
**Scope:** the *AI Completion* chat path of a Pabrik desktop session — i.e. a user
message with attachments sent to an OpenAI-style profile (`url_style = openai` or
`openai-response`).

---

## TL;DR

**OpenAI supports it. Pabrik does not — not at all, and not for any file type.**

| | OpenAI API can take | Pabrik can send today |
|---|---|---|
| **Images** (`image_url` / `input_image`) | ✅ | ✅ image + video, via `image_urls` / `video_urls` |
| **PDF** (`file` / `input_file`) | ✅ | ❌ no path exists |
| **Docs** (`.docx`, `.xlsx`, `.pptx`, `.txt`, `.md`, code) | ✅ *Responses API only* | ❌ no path exists |
| **Audio** (`input_audio`) | ✅ | ❌ no path exists |

The whole attachment contract in Pabrik is **two columns and three content-part
types**: images and video. There is no `file` / `input_file` / `document` content
part, no `file_urls` column, no upload endpoint, and no frontend affordance for
anything that is not an image or a video. Attaching a PDF to a Pabrik chat is
impossible today — the picker refuses it, and the wire has nowhere to put it.

Two *workarounds* exist today, and neither is "attach a PDF to the prompt":
the agent can be asked to *read* a PDF already in the workspace (via the `pdf`
skill / `pdftotext`), and the `present_files` tool can *show* a PDF inline in
the chat — but that is a preview for the human, not input for the model.

---

## 1. The frontend refuses the file before anything else happens

`src/apps/desktop/src/components/file/FileInput.vue`

| Line | What it says |
|---|---|
| 1039 | `<input type="file" accept="image/*,video/*">` — the paperclip picker offers **only** images and video |
| 149–153 | `isImageFile` = `file.type.startsWith('image/')`; `isVideoFile` = `startsWith('video/')`; `isMediaFile` = the OR of both |
| 266 | paste filter: `if (!item.type.startsWith('image/') && !item.type.startsWith('video/')) continue` |
| 291 | the `navigator.clipboard.read()` fallback repeats the same filter |

This is *asserted*, not incidental — `src/apps/desktop/src/__tests__/FileInput.spec.ts:274-289`:

> `it('does NOT attach any image for non-image items (e.g. application/pdf)')`
> … "FileInput is image-only (the paperclip flow), so PDFs are ignored."

The same image/video-only rule governs the kanban task editor
(`src/apps/desktop/src/components/kanban/KanbanDescriptionEditor.vue:355-356`,
`:428`, `:446`).

## 2. The wire has exactly two media channels

| Layer | Where | Shape |
|---|---|---|
| frontend → API | `src/apps/desktop/src/api/index.ts:729-734`, `:832-833`, `:916-922` | `body.image_urls` / `body.video_urls`, `\|\|`-joined |
| helper | `src/apps/desktop/src/helpers/mediaUrls.ts` | `joinMediaUrlsWire` / `splitMediaUrlsWire` / `renderableMediaUrls` |
| DB | `llm_history.image_url` (migration 36), `.video_url` (90); `session_queue_messages.image_url` (37), `.video_url` (90); `workspace_item_tasks.image_urls` (69), `.video_urls` (90) | one TEXT column each |
| queue | `src/agentic_loop/insert_queue_message.zig:16-45` | inserts `image_url`, `video_url` — nothing else |
| worker | `src/agentic_loop/workflow.zig:841-912` | `extractBase64ImageUrls` / `extractBase64VideoUrls` scrape `data:image/…` / `data:video/…` out of the queued message |
| history → model | `src/agentic_loop/parsing.zig:94-146` | builds `content_parts` from `image_urls` + `video_urls` only |

`rg "file_urls|document_urls"` over `src/` → **0 hits**.
`rg "file_url|file_data|input_file|\"file\":"` over `src/` → **0 hits**.

So there is no column, no field, and no code path that could carry a file.

## 3. The model-facing content part has three types — no fourth

`src/modules/agent/Agent.zig:46-52`

```zig
/// Content part types for multimodal messages (text, image_url, or video_url)
pub const ContentPart = struct {
    part_type: []const u8,
    text: ?[]const u8 = null,
    image_url: ?ImageUrl = null,
    video_url: ?VideoUrl = null,
    ...
};
```

The three request builders all consume **this same** struct:

| Builder | Line | Maps a part to | OpenAI's real name for that part |
|---|---|---|---|
| `buildJsonOpenAIRequest` (chat completions) | 1528 | `content` array, `content_parts` serialized **verbatim** (`Agent.zig:199-207`) | `text` · `image_url` · **`video_url` is not an OpenAI type** |
| `buildJsonResponsesRequest` | 1655 | `input_text` · `input_image` · `input_video` (`:1697-1716`) | `input_text` · `input_image` · **`input_video` is not an OpenAI type** |
| `buildJsonAnthropicRequest` | 1294 | `text` · `image` · `video` blocks (`:1395-1421`) | `text` · `image` · **`video` is not an Anthropic block type** |

Two things follow:

1. **No `file` / `input_file` / `document` branch exists in any of the three.**
   Even if the picker accepted a PDF, the request builder would have nothing to
   emit and the shape would be wrong per provider.
2. **Caveat worth flagging to the humans:** the `video_url` / `input_video` /
   `video` spellings are *not* content types in the OpenAI or Anthropic APIs.
   They are a convention that some OpenAI-compatible relays (Qwen-style, Gemini
   bridges) accept. On `api.openai.com` a video part would be rejected as an
   invalid content part. That is a separate question from this card, but it
   means "the video path works" is provider-dependent, not universal.

## 4. What OpenAI itself supports (docs, verified 2026-10-21)

**Chat Completions — PDF only.** Content part type `file`:

```json
{ "type": "file",
  "file": { "filename": "draconomicon.pdf",
            "file_data": "data:application/pdf;base64,<bytes>" } }
```

`file_id` (an uploaded file id) works instead of `file_data`. **`file_url` is NOT
supported on Chat Completions.** No `detail` parameter on chat file inputs.

**Responses API — many types.** Content part type `input_file`:

```json
{ "type": "input_file",
  "filename": "doc.pdf",
  "file_data": "data:application/pdf;base64,…",   // or file_id, or file_url
  "detail": "auto" }                               // auto | low | high
```

Accepted families: PDF; text & code (`.txt .md .json .html .xml`, code files);
rich documents (`.doc .docx .rtf .odt`); presentations (`.ppt .pptx`);
spreadsheets (`.csv .xls .xlsx`). `file_url` (an external URL) is supported
**here only**.

**Summary table (OpenAI's own docs):**

| Input method | Responses API | Chat Completions |
|---|---|---|
| `file_data` (base64) | PDF, txt/md/json/html/xml, code, doc/docx/rtf/odt, ppt/pptx, csv/xls/xlsx | **PDF only** |
| `file_id` (uploaded) | same list | **PDF only** |
| `file_url` (external URL) | same list | **not supported** |

Anthropic's Messages API has a native `document` content block for PDFs —
also not implemented in Pabrik.

## 5. What *does* work with PDFs in Pabrik today (both are workarounds)

**(a) The agent can read a PDF that is already in the workspace.**
The `pdf` skill is installed (`~/.config/pabrik/skills/pdf`, scripts under
`scripts/`: `convert_pdf_to_images.py`, `extract_form_field_info.py`, …) and the
host has poppler's `pdftotext` at `/usr/sbin/pdftotext`. Caveat: `pypdf` is
**not** importable on this box (`python3` is 3.14 with no `pip` module), so the
skill's pypdf snippets need `pdftotext` or a venv. Also note the skill body
points at `~/.config/nalar/skills/pdf/scripts/…`, a path that does not exist
here — the live copy is `~/.config/pabrik/skills/pdf/scripts/…`.

**(b) `present_files` renders a PDF inline in the chat.**
`src/modules/agent/tools/present_files.zig:146` maps `.pdf → application/pdf`;
`src/apps/desktop/src/components/tool_outputs/PresentFiles.vue:139-140, 313-329`
fetches it as a Blob and embeds it (budget `MAX_INLINE_PDF_BYTES = 20 MiB`).
This is a **human-facing preview**. The bytes never enter the prompt.

**(c) `read_file` on a PDF is useless.** `src/modules/agent/tools/read_file.zig`
has no binary guard (`shapeContent` just splits raw bytes into "lines"), so
reading a PDF returns mojibake to the model.

## 6. If we want to build it — the touch points

A minimal, provider-correct implementation is **not** one change; it is seven,
and they must land together or the request goes out malformed.

| # | Change | Where |
|---|---|---|
| 1 | A `file` content-part variant: `filename`, `mime`, `bytes` (base64) | `src/modules/agent/Agent.zig:46-52` (`ContentPart`) + its `jsonStringify` (`:52-72`) + `deinit` (`:903-916`) |
| 2 | A `file_urls` / `file_data` column on the history + queue tables | new migration (next free number after `migration_90.zig`); mirror `image_url` (migration 36/37) and `video_url` (90) |
| 3 | Persist + queue it | `src/agentic_loop/insert_queue_message.zig:16-45`, `src/agentic_loop/workflow.zig:841-912`, `src/agentic_loop/llm_history.zig:1589-1624` |
| 4 | Turn the column into content parts | `src/agentic_loop/parsing.zig:94-146` (the `has_images or has_videos` branch) |
| 5 | Emit the provider-correct shape per wire style | chat: `{"type":"file","file":{filename,file_data}}` (PDF only, no `file_url`); responses: `{"type":"input_file",filename,file_data,detail}`; anthropic: `{"type":"document","source":{…}}` — `buildJsonOpenAIRequest` (1528), `buildJsonResponsesRequest` (1655), `buildJsonAnthropicRequest` (1294) |
| 6 | Frontend: accept the types, stage them, send them | `src/apps/desktop/src/components/file/FileInput.vue` (`:149-153`, `:266`, `:291`, `:1039`), `src/apps/desktop/src/api/index.ts` (`:729-734` etc.), `src/apps/desktop/src/helpers/mediaUrls.ts` (new sibling for file urls) |
| 7 | Caps + validation, mirroring the image path | `src/http_handlers/image_urls_validation.zig` (10 MB cap) and `video_urls_validation.zig` (25 MB cap) — PDFs are large; base64 inflates by 4/3 |

Decisions a human has to make before step 1:

* **Chat-Completions profiles can only take PDF.** A profile on
  `url_style = openai` cannot receive a `.docx` at all — the provider will
  reject it. Either restrict the picker by the session's wire style, or route
  everything to `openai-response`.
* **Base64 in a TEXT column is a scale problem.** A 20 MB PDF becomes ~27 MB of
  base64 in `llm_history`, on every turn it survives in. The image path already
  lives with this (images are downscaled to < 4 MB client-side, `FileInput.vue`
  comment); a PDF has no such downscale. A file-id + content-addressed blob
  store would be the honest design; that is a much bigger change than step 1.
* **`file_url` vs `file_data`:** `file_url` works only on the Responses API and
  avoids the base64 blow-up entirely — if the file already lives at an
  http(s) URL.

---

## Verification notes

* All file:line references are against `969952c5d` (main) in this worktree.
* The OpenAI capability table is from the official OpenAI API docs
  (`developers.openai.com/api/docs/guides/file-inputs` and `/guides/pdf-files`),
  read 2026-10-21.
* No code was changed for this card; this document is the deliverable.
