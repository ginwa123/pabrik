/** Zero-dependency code highlighter for read-only diff output. `detectLanguage` is the repo's
 * single extension→language table (moved verbatim from `CodeEditor.vue` so the diff card and the
 * full editor agree on language). */
export type TokenType = 'keyword' | 'string' | 'comment' | 'number' | 'function' | 'type' | 'plain'

export interface Token {
  text: string
  type: TokenType
}

/** Extension → monaco language id. Moved verbatim from CodeEditor.vue. */
export const detectLanguage = (fileName: string): string => {
  const ext = fileName.split('.').pop()?.toLowerCase() || ''
  const languageMap: Record<string, string> = {
    js: 'javascript',
    jsx: 'javascript',
    ts: 'typescript',
    tsx: 'typescript',
    vue: 'html',
    html: 'html',
    htm: 'html',
    css: 'css',
    scss: 'scss',
    less: 'less',
    json: 'json',
    jsonc: 'json',
    md: 'markdown',
    markdown: 'markdown',
    xml: 'xml',
    yaml: 'yaml',
    yml: 'yaml',
    py: 'python',
    python: 'python',
    sh: 'shell',
    bash: 'shell',
    zsh: 'shell',
    ps1: 'powershell',
    psm1: 'powershell',
    psd1: 'powershell',
    powershell: 'powershell',
    zig: 'zig',
    rs: 'rust',
    toml: 'ini',
    ini: 'ini',
    txt: 'plaintext',
    log: 'plaintext',
    gitignore: 'plaintext',
    env: 'plaintext',
    sql: 'sql',
    graphql: 'graphql',
    go: 'go',
    java: 'java',
    c: 'c',
    cpp: 'cpp',
    h: 'c',
    hpp: 'cpp',
  }
  return languageMap[ext] || 'plaintext'
}

/** Languages whose highlighter is a no-op (rendered as plain text). */
const PASSTHROUGH = new Set(['plaintext', 'markdown'])

/** Line-comment markers per language family. */
const LINE_COMMENT: Record<string, string[]> = {
  javascript: ['//'],
  typescript: ['//'],
  html: ['<!--'],
  xml: ['<!--'],
  css: ['/*'],
  scss: ['/*'],
  less: ['/*'],
  json: [],
  python: ['#'],
  shell: ['#'],
  powershell: ['#'],
  yaml: ['#'],
  ini: ['#', ';'],
  zig: ['//'],
  rust: ['//'],
  go: ['//'],
  java: ['//'],
  c: ['//'],
  cpp: ['//'],
  sql: ['--'],
  graphql: ['#'],
}

const KEYWORDS: Record<string, Set<string>> = {
  javascript: new Set(
    'const let var function return if else for while class extends import export from new typeof instanceof switch case default break continue try catch finally throw async await yield delete void in of do this super'.split(
      ' ',
    ),
  ),
  typescript: new Set(
    'const let var function return if else for while class extends implements interface type enum namespace import export from new typeof instanceof switch case default break continue try catch finally throw async await yield delete void in of do this super public private protected readonly static abstract as satisfies'.split(
      ' ',
    ),
  ),
  html: new Set(['template', 'script', 'style']),
  python: new Set(
    'def return if elif else for while import from as class pass raise try except finally with lambda None True False and or not in is global nonlocal assert del yield async await'.split(
      ' ',
    ),
  ),
  shell: new Set(
    'if then else elif fi for while do done case esac function return exit echo export local readonly declare unset shift trap source in'.split(
      ' ',
    ),
  ),
  powershell: new Set(
    'function return if else elseif for foreach while do switch param begin process end try catch finally throw in'.split(
      ' ',
    ),
  ),
  zig: new Set(
    'const var fn pub comptime if else for while switch return break continue defer errdefer try catch orelse unreachable and or test struct enum union packed extern align threadlocal asm volatile nosuspend await suspend resume inline noinline usingnamespace'.split(
      ' ',
    ),
  ),
  rust: new Set(
    'fn let mut const static struct enum impl trait pub use mod crate return if else match for while loop break continue in ref move where async await dyn unsafe extern as true false self Self super type'.split(
      ' ',
    ),
  ),
  go: new Set(
    'func var const type struct interface map chan return if else for range switch case default break continue defer go select package import true false nil'.split(
      ' ',
    ),
  ),
  java: new Set(
    'class interface enum extends implements package import public private protected static final void int long double float boolean char byte short return if else for while switch case default break continue new this super try catch finally throw true false null'.split(
      ' ',
    ),
  ),
  c: new Set(
    'int long short char float double void struct union enum typedef static const extern return if else for while switch case default break continue sizeof true false NULL'.split(
      ' ',
    ),
  ),
  cpp: new Set(
    'int long short char float double void bool struct union enum class template typename typedef static const constexpr extern return if else for while switch case default break continue new delete this using namespace public private protected virtual override true false nullptr'.split(
      ' ',
    ),
  ),
  sql: new Set(
    'select from where join left right inner outer on group by order having limit offset insert into values update set delete create table index view alter drop primary key foreign references not null unique default and or as distinct'.split(
      ' ',
    ),
  ),
  json: new Set(['true', 'false', 'null']),
  yaml: new Set(['true', 'false', 'null']),
  ini: new Set(['true', 'false']),
  css: new Set(['media', 'import', 'keyframes', 'important']),
  scss: new Set([
    'media',
    'import',
    'mixin',
    'include',
    'extend',
    'function',
    'return',
    'if',
    'else',
    'for',
    'each',
    'while',
    'important',
  ]),
  less: new Set(['media', 'import', 'mixin', 'when', 'important']),
  xml: new Set([]),
  graphql: new Set(
    'query mutation subscription type interface union enum input scalar fragment on'.split(' '),
  ),
}

const IDENT_START = /[A-Za-z_$]/
const IDENT_CHAR = /[A-Za-z0-9_$]/
const NUMBER_RE =
  /^(?:0x[0-9a-fA-F_]+|0b[01_]+|0o[0-7_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d[\d_]*)?)/
const IDENT_RE = /^[A-Za-z_$][A-Za-z0-9_$]*/

/** Split one line into typed tokens. Pure function — no DOM, no HTML.
 * `language` is a monaco language id (see `detectLanguage`). */
export function highlightLine(line: string, language: string): Token[] {
  if (!line || PASSTHROUGH.has(language)) return [{ text: line, type: 'plain' }]

  const keywords = KEYWORDS[language] ?? KEYWORDS.javascript!
  const commentMarkers = LINE_COMMENT[language] ?? ['//']
  const tokens: Token[] = []
  let i = 0
  const n = line.length
  let plainBuf = ''

  const flushPlain = () => {
    if (plainBuf) {
      tokens.push({ text: plainBuf, type: 'plain' })
      plainBuf = ''
    }
  }

  while (i < n) {
    const rest = line.slice(i)

    // Block comment opener `/*` (css family + c-style): consume to `*/`
    // on the same line, else the rest of the line.
    if (rest.startsWith('/*')) {
      const end = line.indexOf('*/', i + 2)
      flushPlain()
      if (end === -1) {
        tokens.push({ text: line.slice(i), type: 'comment' })
        return tokens
      }
      tokens.push({ text: line.slice(i, end + 2), type: 'comment' })
      i = end + 2
      continue
    }

    // HTML/XML comment `<!-- ... -->`.
    if (rest.startsWith('<!--')) {
      const end = line.indexOf('-->', i + 4)
      flushPlain()
      if (end === -1) {
        tokens.push({ text: line.slice(i), type: 'comment' })
        return tokens
      }
      tokens.push({ text: line.slice(i, end + 3), type: 'comment' })
      i = end + 3
      continue
    }

    // Line comment: marker outside of a string starts a comment to EOL.
    // (Strings are consumed first below, so a `#`/`//` inside "..." never
    // reaches this branch.)
    let isComment = false
    for (const m of commentMarkers) {
      if (m && rest.startsWith(m)) {
        // `#` is also a CSS id selector — only treat as comment for
        // languages where `#` comments exist AND this isn't css-like.
        if (m === '#' && (language === 'css' || language === 'scss' || language === 'less')) {
          continue
        }
        isComment = true
        break
      }
    }
    if (isComment) {
      flushPlain()
      tokens.push({ text: line.slice(i), type: 'comment' })
      return tokens
    }

    const ch = line[i]!

    // Strings: "..." '...' `...` with backslash escapes.
    if (ch === '"' || ch === "'" || ch === '`') {
      flushPlain()
      let j = i + 1
      while (j < n) {
        if (line[j] === '\\') {
          j += 2
          continue
        }
        if (line[j] === ch) {
          j += 1
          break
        }
        j += 1
      }
      tokens.push({ text: line.slice(i, j), type: 'string' })
      i = j
      continue
    }

    // Numbers.
    const numMatch = NUMBER_RE.exec(rest)
    if (numMatch && (i === 0 || !IDENT_CHAR.test(line[i - 1]!))) {
      flushPlain()
      tokens.push({ text: numMatch[0], type: 'number' })
      i += numMatch[0].length
      continue
    }

    // Identifiers: keyword → function-call → Type → plain.
    if (IDENT_START.test(ch)) {
      const idMatch = IDENT_RE.exec(rest)!
      const word = idMatch[0]
      const after = line.slice(i + word.length)
      flushPlain()
      if (keywords.has(word)) {
        tokens.push({ text: word, type: 'keyword' })
      } else if (/^\s*\(/.test(after)) {
        tokens.push({ text: word, type: 'function' })
      } else if (/^[A-Z]/.test(word)) {
        tokens.push({ text: word, type: 'type' })
      } else {
        tokens.push({ text: word, type: 'plain' })
      }
      i += word.length
      continue
    }

    // Anything else (operators, whitespace, punctuation) accumulates.
    plainBuf += ch
    i += 1
  }

  flushPlain()
  return tokens.length > 0 ? tokens : [{ text: line, type: 'plain' }]
}

/** Tokenize every line against an ALREADY-RESOLVED monaco language id. For a caller that resolved
 * the language itself — an explicit override, or a `detectLanguage` result it wants to reuse. */
export function highlightLines(lines: readonly string[], language: string): Token[][] {
  return lines.map((line) => highlightLine(line, language))
}

/** Tokenize every line of one file for a render site that only knows the path — the diff reviews,
 * the git viewers. Pairing `detectLanguage` with `highlightLine` happens exactly once, here, so a
 * new code surface cannot drift from the others. */
export function highlightLinesForFile(
  lines: readonly string[],
  filePath: string | null | undefined,
): Token[][] {
  return highlightLines(lines, detectLanguage(filePath ?? ''))
}
