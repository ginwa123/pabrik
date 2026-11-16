import { joinMediaUrlsWire } from '../helpers/mediaUrls'
import { encodeFileAttachmentsWire, type FileAttachment } from '../helpers/fileAttachments'
import { ApiError, apiFetch } from './client'
import { splitMediaUrls } from './tasks'

// Send a message to LLM Migration 063 — adds the optional `isAutoRetryUntilStop` flag.
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
  // Introspection: list the tools equipped for this session ("what tools do I have").
  'used_tools',
  // Workspace-scoped documents (Migration 095): `document` reads and searches, `document_markdown` writes.
  'document',
  'document_markdown',
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
  // Migration 090 — split data:video/... out to video_urls so a pasted clip never hits the image-only validator (400).
  const { images, videos } = splitMediaUrls(imageUrls, videoUrls)
  const imageUrlsStr = joinMediaUrlsWire(images)
  const videoUrlsStr = joinMediaUrlsWire(videos)
  // The attached documents ride in ONE field, as a JSON array string — the same shape the backend's `file_attachments` column holds.
  const fileAttachmentsStr = encodeFileAttachmentsWire(fileAttachments ?? [])

  try {
    // silent: true — ChatView already surfaces these failures inline (e.g. the LLM-not-configured banner) and the new global notification system would duplicate the …
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
        // Migration 063 — pass through to POST /api/session.
        is_auto_retry_until_stop: isAutoRetryUntilStop ?? '',
      },
      silent: true,
    })
  } catch (err) {
    // Preserve the original return-shape semantics so ChatView can branch on `status` for user-facing messages: 'bad_request' — backend 400 'unprocessable_entity'— …
    if (err instanceof ApiError) {
      if (err.status === 400) return { status: 'bad_request' }
      if (err.status === 422) return { status: 'unprocessable_entity' }
      return { status: 'http_error' }
    }
    return { status: 'offline' }
  }
}

/** One `llm_history` row with every column as text — the shape the delete returns and the restore takes back. */
export interface MessageRow {
  id: string
  session_id: string
  model: string
  response_content: string
  tool_calls_json: string
  finish_reason: string
  usage_json: string
  created_at_nano: string
  role: string
  reasoning_content: string
  is_feed_to_llm: string
  agent: string
  loop_index: string
  temperature: string
  is_thinking: string
  parent_session_id: string
  parent_id: string
  prompt_tokens: string
  completion_tokens: string
  total_tokens: string
  is_input: string
  is_output: string
  tool_name: string
  diffview_before: string
  diffview_after: string
  image_url: string
  tool_call_id: string
  created_iso: string
  is_loading: string
  cache_creation_input_tokens: string
  cache_read_input_tokens: string
  reasoning_id: string
  reasoning_encrypted_content: string
  video_url: string
  file_attachments: string
  file_attachments_meta: string
}

/** Delete ONE `llm_history` row. The response carries the whole row so the caller can undo. */
export async function deleteMessage(
  messageId: string,
): Promise<{ deleted: { row: MessageRow } }> {
  return await apiFetch<{ deleted: { row: MessageRow } }>(
    `/llm/message/${encodeURIComponent(messageId)}`,
    { method: 'DELETE', silent: true },
  )
}

/** Put a deleted row back, with the same id. */
export async function restoreMessage(row: MessageRow): Promise<{ restored: { id: string } }> {
  return await apiFetch<{ restored: { id: string } }>('/llm/message/restore', {
    method: 'POST',
    body: { row },
    silent: true,
  })
}

/** Drop one row from the model's context, or put it back. The row itself survives. */
export async function setMessageFeed(
  messageId: string,
  isFeedToLlm: boolean,
): Promise<{ id: string; is_feed_to_llm: boolean }> {
  return await apiFetch<{ id: string; is_feed_to_llm: boolean }>(
    `/llm/message/${encodeURIComponent(messageId)}`,
    { method: 'PATCH', body: { is_feed_to_llm: isFeedToLlm ? 1 : 0 }, silent: true },
  )
}
