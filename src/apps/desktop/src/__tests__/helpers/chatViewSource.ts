/** The chat view as ONE haystack: the SFC plus every file it was split into, so a guard written
 * against `ChatView.vue` keeps holding after a slice moves out to its own file. */
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const VIEWS = resolve(HERE, '..', '..', 'components', 'views')
const CHAT_VIEW_DIR = join(VIEWS, 'chat_view')

function collect(dir: string, out: string[]): string[] {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    if (statSync(p).isDirectory()) collect(p, out)
    else if (/\.(vue|ts|css)$/.test(name)) out.push(p)
  }
  return out
}

export function readChatViewSource(): string {
  const parts = [readFileSync(join(VIEWS, 'ChatView.vue'), 'utf8')]
  const dirs = [CHAT_VIEW_DIR, join(VIEWS, 'chat_right_sidebar')]
  for (const dir of dirs) parts.push(...collect(dir, []).map((p) => readFileSync(p, 'utf8')))
  return parts.join('\n\n/* ---- next file ---- */\n\n')
}

export function readChatViewBundle(): { files: string[]; text: string } {
  const parts = [`ChatView.vue\n${readFileSync(join(VIEWS, 'ChatView.vue'), 'utf8')}`]
  const dirs = [CHAT_VIEW_DIR, join(VIEWS, 'chat_right_sidebar')]
  for (const dir of dirs) {
    for (const p of collect(dir, [])) parts.push(`${p}\n${readFileSync(p, 'utf8')}`)
  }
  return { files: dirs, text: parts.join('\n\n') }
}
