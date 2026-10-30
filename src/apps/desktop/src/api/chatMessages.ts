import { joinMediaUrlsWire } from '../helpers/mediaUrls'
import { encodeFileAttachmentsWire, type FileAttachment } from '../helpers/fileAttachments'
import { ApiError, apiFetch } from './client'
import { splitMediaUrls } from './tasks'

// Send a message to LLM Migration 063 — adds the optional `isAutoRetryUntilStop` flag. "1" opts
// into unattended mode (the workflow re-reads this column on entry and soft-bails past retry_count
// > 10). Default undefined = today's behavior.
export const DEFAULT_CHAT_TOOLS = [
  'search_tool',
  'view_tool',
  'use_tool',
  'command',
  'search',
  'load_memory',
  'save_memory',
  'search_skills',
  'use_skill',
  // Introspection: list the tools equipped for this session ("what tools do I have"). Read-only,
  // sub-agent-safe. Seeded here so plain chat, design mode, and routine sessions (which all use
  // this request body) get it; agent/kanban modes seed it via backend DEFAULT_AGENT_TOOLS.
  'used_tools',
  // Interactive: ask the human a question (ends the turn until they answer).
  // Seeded in every mode by default — without it here the tool would be
  // silently filtered out of plain chat sessions.
  'ask_user',
  // Workspace-scoped documents (Migration 095). Both resolve their own workspace server-side from
  // the calling session, so a plain chat is as safe as a project task: outside a workspace-linked
  // session they refuse rather than guessing a scope.
  'add_document',
  'edit_document',
  // Read-only counterpart: `edit_document` replaces the WHOLE body, so a
  // chat agent cannot revise a note it wrote earlier without a way to
  // find the row first.
  'search_documents',
  // `delete_document` is intentionally omitted — irreversible, and it does not belong in the set
  // every plain chat starts with. It stays one click away in Settings → Tools, and an agent can
  // also reach it through search_tool → use_tool, which bypasses the allowlist.
].join(',')

export async function sendChatMessage(
  sessionId: string,
  message: string,
  cwdSession: string,
  imageUrls?: string[],
  selectedAgent?: string,
  isAutoRetryUntilStop?: string,
  videoUrls?: string[],
  workspaceId?: string,
  fileAttachments?: FileAttachment[],
): Promise<{ status: string }> {
  // Migration 090 — split data:video/... out to video_urls so a pasted
  // clip never hits the image-only validator (400).
  const { images, videos } = splitMediaUrls(imageUrls, videoUrls)
  const imageUrlsStr = joinMediaUrlsWire(images)
  const videoUrlsStr = joinMediaUrlsWire(videos)
  // The attached documents ride in ONE field, as a JSON array string — the
  // same shape the backend's `file_attachments` column holds.
  const fileAttachmentsStr = encodeFileAttachmentsWire(fileAttachments ?? [])

  try {
    // silent: true — ChatView already surfaces these failures inline
    // (e.g. the LLM-not-configured banner) and the new global
    // notification system would duplicate the message.
    return await apiFetch<{ status: string }>('/llm/session', {
      method: 'POST',
      body: {
        session_id: sessionId,
        queue_message: message,
        allowed_tools: DEFAULT_CHAT_TOOLS,
        cwd_session: cwdSession,
        workspace_id: workspaceId ?? '',
        image_urls: imageUrlsStr,
        video_urls: videoUrlsStr,
        ...(fileAttachmentsStr && fileAttachmentsStr !== '[]'
          ? { file_attachments: fileAttachmentsStr }
          : {}),
        selected_profile_model: selectedAgent || '',
        // Migration 063 — pass through to POST /api/session. Empty
        // / undefined => the backend's default ("0" = off).
        is_auto_retry_until_stop: isAutoRetryUntilStop ?? '',
      },
      silent: true,
    })
  } catch (err) {
    // Preserve the original return-shape semantics so ChatView can branch on `status` for
    // user-facing messages: 'bad_request'         — backend 400 'unprocessable_entity'— backend 422
    // 'http_error'          — backend 4xx/5xx other than the above 'offline'.
    if (err instanceof ApiError) {
      if (err.status === 400) return { status: 'bad_request' }
      if (err.status === 422) return { status: 'unprocessable_entity' }
      return { status: 'http_error' }
    }
    return { status: 'offline' }
  }
}
