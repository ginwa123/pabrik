import { marked } from 'marked'
import { isThinkingTags, getThinkingTags, stripThinkingTags } from './stripTags'
import { tryUnwrapToolOutput } from './unwrapToolOutput'

/** Render a chat message's content to HTML. */
const escapeHtml = (text: string): string => {
  const div = document.createElement('div')
  div.textContent = text
  return div.innerHTML
}

const MAX_CACHE_ENTRIES = 200

// Map is module-scoped so the cache survives across component re-renders and even across
// mount/unmount (the hot path is the long-lived chat, where the same messages re-render dozens of
// times). Tests reset via `_resetRenderResponseCache`.
const cache = new Map<string, string>()

/**  * Test-only cache reset. Not exported through the helpers barrel (helpers/index.ts) so production
 * callers can't accidentally clobber the cache. */
export const _resetRenderResponseCache = (): void => {
  cache.clear()
}

const computeKey = (content: string, role: string, toolName: string | undefined): string => {
  // Pipe delimiter is safe: none of the inputs contain `|` (markdown
  // and tool envelopes are user/LLM text, not pipes).
  return `${role}|${toolName ?? ''}|${content.trim()}`
}

/**  * The inline pill for a tool whose result carries no summary of its own: the tool name, plus
 * whether it worked. Shared by the empty-content path and the unregistered-tool fallback so the two
 * cannot drift apart. */
const toolNamePill = (toolName: string, status?: 'ok' | 'failed', detail?: string): string => {
  const name = escapeHtml(toolName)
  if (status === 'failed') {
    const message = escapeHtml((detail ?? 'unknown error').trim() || 'unknown error')
    return `<span class="tool-inline">${name} → <span class="tool-inline-error">✗</span> ${message}</span>`
  }
  if (status === 'ok') {
    return `<span class="tool-inline">${name} → <span class="tool-inline-success">✓</span></span>`
  }
  return `<span class="tool-inline">${name}</span>`
}

export const renderResponse = (
  content: string,
  role: string,
  tool_name?: string,
  // 4 trailing parameters kept for diff readability with the original Vue call sites. They are not
  // used by the function body — the return value depends only on (content, role, tool_name), which
  // is also what the cache keys on.
  _diffviewBefore?: string,
  _diffviewAfter?: string,
  _finish_reason?: string,
  _tool_calls_json?: string,
): string => {
  // Cache check BEFORE the trim() so a miss on the raw input doesn't
  // allocate a new trimmed string. The computeKey() inside is cheap
  // (one .trim() + concat).
  const key = computeKey(content, role, tool_name)
  const cached = cache.get(key)
  if (cached !== undefined) return cached

  // Bounded cache: if we exceed the limit, clear and start over.
  // Clearing is simpler than LRU and good enough — typical chats
  // have far fewer than 200 distinct content variants.
  if (cache.size >= MAX_CACHE_ENTRIES) {
    cache.clear()
  }

  const trimmed = content.trim()
  if (!trimmed) {
    // A `tool` row can legitimately be empty — 403 such rows in the live DB, mostly a result that
    // has not landed yet and a handful of tools that return nothing at all.
    const emptyTool = role === 'tool' && tool_name ? toolNamePill(tool_name) : ''
    cache.set(key, emptyTool)
    return emptyTool
  }

  let result: string
  try {
    if (role === 'assistant') {
      if (isThinkingTags(trimmed)) {
        result = getThinkingTags(trimmed)
      } else {
        const cleanContent = stripThinkingTags(trimmed)
        result = marked.parse(cleanContent, { async: false }) as string
      }
    } else if (role === 'tool') {
      result = renderTool(trimmed, tool_name)
    } else {
      result = escapeHtml(trimmed)
    }
  } catch {
    result = escapeHtml(trimmed)
  }

  cache.set(key, result)
  return result
}

// Tool branch — extracted from renderResponse so the assistant cache
// path stays short and the file is easier to scan.
const renderTool = (content: string, tool_name: string | undefined): string => {
  if (tool_name === 'read_file') {
    const mathPath = content.match(/<path>(.*?)<\/path>/)
    const path = mathPath ? mathPath[1] : null
    const errorArr = content.match(/<error>(.*?)<\/error>/)
    if (errorArr) {
      const errorQuery = errorArr[0]
      return `<span class="tool-inline">${tool_name} → ${path} ${errorQuery}</span>`
    }
    return `<span class="tool-inline">${tool_name} → ${path}</span>`
  }

  if (tool_name === 'search') {
    const fileMatch = content.match(/<file path="([^"]+)" total="(\d+)" count="(\d+)">/)
    if (fileMatch) {
      const matchCount = fileMatch[3]
      return `<span class="tool-inline">search → ${matchCount} matches</span>`
    }
    const warningMatch = content.match(/<warning>(.*?)<\/warning>/)
    if (warningMatch) {
      return `<span class="tool-inline">search → ${warningMatch[1]}</span>`
    }
    const errorMatch = content.match(/<error>(.*?)<\/error>/)
    return `<span class="tool-inline">search → ${errorMatch?.[1] || 'unknown'}</span>`
  }

  if (tool_name === 'glob') {
    const patternMatch = content.match(/pattern="([^"]+)"/)
    const totalMatch = content.match(/total="(\d+)"/)
    const returnedMatch = content.match(/returned="(\d+)"/)
    const warningMatch = content.match(/<warning>(.*?)<\/warning>/)
    if (warningMatch) {
      return `<span class="tool-inline">glob → ${warningMatch[1]}</span>`
    }
    const pattern = patternMatch ? patternMatch[1] : 'unknown'
    const total = totalMatch ? totalMatch[1] : '0'
    const returned = returnedMatch ? returnedMatch[1] : total
    const resultsText = total !== '0' ? ` (${returned} files)` : ''
    return `<span class="tool-inline">glob → "${pattern}"${resultsText}</span>`
  }

  // Collapsed-bubble summary for the inline tool pill in ChatView. Mirrors the structured
  // ListDirectory.vue card so users see the same info (path + entry count) whether they look at the
  // collapsed bubble or the expanded body.
  if (tool_name === 'list_directory') {
    const errorMatch = content.match(/<error>([\s\S]*?)<\/error>/)
    if (errorMatch) {
      return `<span class="tool-inline">${tool_name} → ${escapeHtml(errorMatch[1]?.trim() || 'error')}</span>`
    }
    const pathMatch = content.match(/<directory_listing\s[^>]*\bpath="([^"]+)"/)
    const countMatch = content.match(/<directory_listing\s[^>]*\bcount="(\d+)"/)
    const dirPath = pathMatch?.[1] ?? 'unknown'
    const dirCount = countMatch?.[1] ?? '0'
    const plural = dirCount === '1' ? 'entry' : 'entries'
    return `<span class="tool-inline">${tool_name} → ${escapeHtml(dirPath)} (${dirCount} ${plural})</span>`
  }

  if (tool_name === 'mcp_context7_query-docs' || tool_name === 'context7') {
    const mathQuery = content.match(/<query>(.*?)<\/query>/)
    const query = mathQuery ? mathQuery[1] : null
    return `<span class="tool-inline">${tool_name} → "${query || 'unknown'}"</span>`
  }

  // Universal MCP summary: ANY `mcp_<server>_<tool>` (graphify, db, future servers). The backend
  // stores MCP success as RAW server text (no `<tool>` envelope), so unwrap may fail — fall back to
  // the raw content. Truncate to one line / 80 chars so the collapsed pill stays one line.
  if (tool_name?.startsWith('mcp_')) {
    const unwrappedMcp = tryUnwrapToolOutput(content)
    const dataRaw =
      unwrappedMcp === null ? content : (unwrappedMcp.data ?? unwrappedMcp.error ?? '')
    const raw = typeof dataRaw === 'string' ? dataRaw : JSON.stringify(dataRaw)
    if (unwrappedMcp !== null && !unwrappedMcp.success) {
      return `<span class="tool-inline">${tool_name} → ${escapeHtml((unwrappedMcp.error ?? 'error').trim() || 'error')}</span>`
    }
    const oneLine = raw.replace(/\s+/g, ' ').trim()
    const preview = oneLine.slice(0, 80)
    const suffix = oneLine.length > 80 ? '…' : ''
    return `<span class="tool-inline">${tool_name} → ${escapeHtml(preview || 'ok')}${suffix}</span>`
  }

  // Bare name: the card is the answer, and a one-line chip cannot hold it.
  if (
    tool_name === 'search_skills' ||
    tool_name === 'use_skill' ||
    tool_name === 'add_skill' ||
    tool_name === 'edit_skill' ||
    tool_name === 'web_search' ||
    tool_name === 'list_web_search_providers'
  ) {
    return `<span class="tool-inline">${tool_name}</span>`
  }

  if (tool_name === 'set_git_worktree') {
    // JSON envelope first (canonical): {"tool":...,"success":bool,"data":{path,branch,cleared,created},"error":...}
    // Falls back to legacy <worktree> XML for old chat history.
    try {
      const parsed: unknown = JSON.parse(content)
      const record =
        typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)
          ? (parsed as Record<string, unknown>)
          : null
      const envelope =
        record !== null && (typeof record.tool === 'string' || typeof record.success === 'boolean')
          ? record
          : null
      const dataRaw = envelope !== null ? envelope.data : parsed
      const data =
        typeof dataRaw === 'object' && dataRaw !== null && !Array.isArray(dataRaw)
          ? (dataRaw as Record<string, unknown>)
          : null
      if (envelope !== null && envelope.success === false) {
        const msg =
          typeof envelope.error === 'string' && envelope.error.trim().length > 0
            ? envelope.error.trim()
            : 'error'
        return `<span class="tool-inline">${tool_name} → ${escapeHtml(msg)}</span>`
      }
      if (data !== null) {
        if (typeof data.path === 'string' && data.path.trim().length > 0) {
          return `<span class="tool-inline">${tool_name} → ${escapeHtml(data.path.trim())}</span>`
        }
        if (data.cleared === true || data.cleared === 'true' || data.cleared === 1) {
          return `<span class="tool-inline">${tool_name} → cleared</span>`
        }
        if (typeof data.error === 'string' && data.error.trim().length > 0) {
          return `<span class="tool-inline">${tool_name} → ${escapeHtml(data.error.trim())}</span>`
        }
      }
      // Bare JSON object without envelope (inner data passed directly).
      if (envelope === null && data !== null) {
        return `<span class="tool-inline">${tool_name} → ${escapeHtml('error')}</span>`
      }
    } catch {
      // Not JSON — fall through to legacy XML below.
    }
    // Legacy XML fallback: SET success <path>, CLEAR <cleared>, else <error>.
    const pathMatch = content.match(/<path>([\s\S]*?)<\/path>/)
    if (pathMatch) {
      return `<span class="tool-inline">${tool_name} → ${escapeHtml(pathMatch[1]?.trim() || '')}</span>`
    }
    if (/<cleared>\s*true\s*<\/cleared>/.test(content)) {
      return `<span class="tool-inline">${tool_name} → cleared</span>`
    }
    const errMatch = content.match(/<error>([\s\S]*?)<\/error>/)
    return `<span class="tool-inline">${tool_name} → ${escapeHtml(errMatch?.[1]?.trim() || 'error')}</span>`
  }

  if (tool_name === 'read_compacted_messages') {
    // Collapsed-bubble summary for the inline tool pill in ChatView. Mirrors the structured
    // ReadCompactedMessages.vue card so users see the same info (mode + count + session) whether
    // they look at the collapsed bubble or the expanded body.
    const errorMatch = content.match(/<error>([\s\S]*?)<\/error>/)
    if (errorMatch) {
      return `<span class="tool-inline">${tool_name} → ${escapeHtml(errorMatch[1]?.trim() || 'error')}</span>`
    }
    const modeMatch = content.match(/<read_compacted_messages\s+mode="([^"]+)"/)
    const countMatch = content.match(/<count>(\d+)<\/count>/)
    const sessionMatch = content.match(/<session_id>([\s\S]*?)<\/session_id>/)
    const mode = modeMatch?.[1] ?? 'index'
    const count = countMatch?.[1] ?? '?'
    const session = sessionMatch?.[1]?.trim() ?? ''
    return `<span class="tool-inline">${tool_name} → ${escapeHtml(mode)} mode · ${count} ${count === '1' ? 'message' : 'messages'}${session ? ' · ' + escapeHtml(session) : ''}</span>`
  }

  if (tool_name === 'update_plan') {
    // Collapsed-bubble summary for the inline tool pill in ChatView. Mirrors the structured
    // UpdatePlan.vue card so users see "wrote N bytes" whether they look at the collapsed bubble or
    // expand the structured card.
    const updateError = content.match(/<error>([\s\S]*?)<\/error>/)
    if (updateError && updateError[1]) {
      return `<span class="tool-inline">${tool_name} → ${escapeHtml(updateError[1].trim()) || 'error'}</span>`
    }
    // Estimate byte count from the inner envelope length as a rough "how big was this plan write"
    // signal. We pull the inner envelope (stripping both <tool> and <update_plan> wrappers) so the
    // number reflects the actual content, not the XML envelope chrome.
    const innerPlanMatch = content.match(/<update_plan>([\s\S]*?)<\/update_plan>/)
    const innerBytes = innerPlanMatch?.[1]?.length ?? 0
    return `<span class="tool-inline">${tool_name} → wrote ${innerBytes}b of plan</span>`
  }

  if (tool_name === 'update_plan_text_replace') {
    // Collapsed-bubble summary for the inline tool pill in ChatView. JSON envelope:
    // {"tool":…,"success":bool,"data":{session_id,updated_at,plan,replacements},"error":…}
    try {
      const parsed: unknown = JSON.parse(content)
      const record =
        typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)
          ? (parsed as Record<string, unknown>)
          : null
      const envelope =
        record !== null && (typeof record.tool === 'string' || typeof record.success === 'boolean')
          ? record
          : null
      if (envelope !== null && envelope.success === false) {
        const msg =
          typeof envelope.error === 'string' && envelope.error.trim().length > 0
            ? envelope.error.trim()
            : 'error'
        return `<span class="tool-inline">${tool_name} → ${escapeHtml(msg)}</span>`
      }
      const dataRaw = envelope !== null ? envelope.data : parsed
      const data =
        typeof dataRaw === 'object' && dataRaw !== null && !Array.isArray(dataRaw)
          ? (dataRaw as Record<string, unknown>)
          : null
      if (data !== null) {
        const count = typeof data.replacements === 'number' ? data.replacements : null
        const suffix = count === null ? '' : ` · ${count} replacement${count === 1 ? '' : 's'}`
        return `<span class="tool-inline">${tool_name} → edited plan${suffix}</span>`
      }
    } catch {
      // Not JSON — fall through to the generic renderer.
    }
  }

  if (tool_name === 'get_plan') {
    // Collapsed-bubble summary for the inline tool pill in ChatView. Mirrors the structured
    // GetPlan.vue card so users see "fetched current plan · N items" whether they look at the
    // collapsed bubble or expand the structured card.
    const getError = content.match(/<error>([\s\S]*?)<\/error>/)
    if (getError && getError[1]) {
      return `<span class="tool-inline">${tool_name} → ${escapeHtml(getError[1].trim()) || 'error'}</span>`
    }
    // No-plan sentinel: <get_plan><empty/></get_plan>
    if (/<empty\s*\/?>/.test(content)) {
      return `<span class="tool-inline">${tool_name} → no plan set</span>`
    }
    // Count `- [ ]` / `- [x]` items in the CDATA-wrapped body for the "N items" hint. We strip the
    // CDATA wrappers first so we only match checklist markers, not any literal `[ ]` text inside
    // non-checklist prose.
    const cdataMatch = content.match(/<!\[CDATA\[([\s\S]*?)\]\]>/)
    const cdata = cdataMatch?.[1] ?? ''
    const itemMatches = cdata.match(/^- \[(x| )\]\s+/gim)
    const itemCount = itemMatches?.length ?? 0
    const itemLabel = itemCount === 1 ? 'item' : 'items'
    return `<span class="tool-inline">${tool_name} → fetched current plan${itemCount > 0 ? ` · ${itemCount} ${itemLabel}` : ''}</span>`
  }

  if (tool_name === 'spawn_sub_agent') {
    const agentMatches = content.match(/<agent name="([^"]*)" success="([^"]*)">/g)
    const agentCount = agentMatches ? agentMatches.length : 0
    const summaryMatch = content.match(/<summary succeeded="(\d+)" failed="(\d+)" \/>/)
    const succeeded = summaryMatch ? summaryMatch[1] : '0'
    const failed = summaryMatch ? summaryMatch[2] : '0'
    return `<span class="tool-inline">${tool_name} → ${agentCount} agents (${succeeded} succeeded, ${failed} failed)</span>`
  }

  // Unregistered tool — no card claimed this name, so this pill is all the transcript shows until
  // the reader expands the row (ChatView prints the payload there via `toolPayloadPreview`).
  const unwrapped = tryUnwrapToolOutput(content)
  if (unwrapped === null) {
    return toolNamePill(tool_name || 'tool')
  }
  return unwrapped.success
    ? toolNamePill(tool_name || unwrapped.name, 'ok')
    : toolNamePill(tool_name || unwrapped.name, 'failed', unwrapped.error ?? undefined)
}
