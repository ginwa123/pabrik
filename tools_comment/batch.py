#!/usr/bin/env python3
"""Apply `reflow.py` to many files, verifying prose preservation per file.

Usage: batch.py <top-n-from-/tmp/mcl_files.txt> [--apply]

For each file: snapshot the original, run the reflow, then prove the comment
prose is character-identical. A file that fails the check is REVERTED and
reported, so a bad conversion can never reach the working tree.
"""
import json, os, re, shutil, subprocess, sys, tempfile

WT = '/home/ginwa/.config/pabrik/.worktrees/paydown-2548-comment-lines-1792080502826/'
HERE = os.path.dirname(os.path.abspath(__file__))
DESKTOP = WT + 'src/apps/desktop'

# The Vue SFC parser and the TS parser, resolved through .pnpm because
# `vue-eslint-parser` is not hoisted to node_modules root. Both are found by
# glob so a version bump does not silently disable the guard.
import glob as _glob

VUE_PARSER = (_glob.glob(DESKTOP + '/node_modules/.pnpm/'
                         'vue-eslint-parser@*/node_modules/vue-eslint-parser') or [''])[0]
TS_PARSER = (_glob.glob(DESKTOP + '/node_modules/.pnpm/'
                        '@typescript-eslint+parser@*/node_modules/'
                        '@typescript-eslint/parser') or [''])[0]

# Node, not Python: both parsers are ESM and resolve their own deps only when
# loaded by Node from a real file URL. `require()` on the package root fails
# with ERR_REQUIRE_ESM, and `importlib` on a directory returns a None spec.
# `@typescript-eslint/parser` ships ESM (`dist/index.js`), `vue-eslint-parser`
# ships CJS (`dist/index.cjs`), so the loader tries both and takes whichever
# resolves. A dynamic import of a .cjs URL yields `{ default: module }`.
#
# The SFC parser needs the TS parser as a MODULE OBJECT in `options.parser` —
# the string `'ts'` makes it `require('ts')`, which does not exist.
PARSE_SNIPPET = """
import fs from 'fs'
const file = process.argv[2]
const kind = process.argv[3]
const url = 'file://' + process.argv[4]
const tsUrl = process.argv[5]
let mod
try {
  mod = await import(url)
} catch (err) {
  process.stdout.write('LOAD_FAIL ' + err.code)
  process.exit(3)
}
const parser = mod.parse ? mod : mod.default
const src = fs.readFileSync(file, 'utf8')
if (kind === 'vue') {
  let tsMod
  try {
    tsMod = await import('file://' + tsUrl)
  } catch (err) {
    process.stdout.write('TS_LOAD_FAIL ' + err.code)
    process.exit(4)
  }
  const ts = tsMod.parseForESLint ? tsMod : tsMod.default
  parser.parse(src, { sourceType: 'module', parser: ts })
} else {
  parser.parseForESLint(src, { filePath: file })
}
process.stdout.write('PARSE_OK')
"""


def _entry(parser_dir):
    if not parser_dir:
        return None
    return (_glob.glob(parser_dir + '/dist/index.js')
            or _glob.glob(parser_dir + '/dist/index.cjs') or [None])[0]


def _node_parse(src, kind, parser_dir):
    """Parse `src` with a Node-loaded parser. Returns True on success.

    The source goes through a TEMP FILE, never argv: a 7k-line source exceeds
    the OS argument limit, the subprocess dies E2BIG, and a bare `except`
    would swallow that as "parses fine".
    """
    entry = _entry(parser_dir)
    if not entry:
        return False
    with tempfile.NamedTemporaryFile('w', suffix='.mjs', delete=False) as fh:
        fh.write(PARSE_SNIPPET)
        script = fh.name
    with tempfile.NamedTemporaryFile('w', suffix='.ts', delete=False) as fh:
        fh.write(src)
        target = fh.name
    try:
        r = subprocess.run(['node', script, target, kind, entry,
                            _entry(TS_PARSER) or ''],
                           capture_output=True, text=True, timeout=180)
        return r.returncode == 0 and 'PARSE_OK' in r.stdout
    except Exception:
        return False
    finally:
        os.unlink(script)
        os.unlink(target)


def parses(path):
    """True when the file still parses after the edit.

    A `.vue` file needs BOTH the SFC parser (template) and the TS parser on
    each `<script>` block. Brace-counting is not a parse check, and a comment
    edit that eats a `*/` shows up here and nowhere else.
    """
    src = open(path).read()
    if path.endswith('.vue'):
        if not _node_parse(src, 'vue', VUE_PARSER):
            return False
        for m in re.finditer(r'<script[^>]*>(.*?)</script>', src, re.S):
            if not _node_parse(m.group(1), 'ts', TS_PARSER):
                return False
        return True
    return _node_parse(src, 'ts', TS_PARSER)


def prose(path):
    return ''.join(comment_tokens(path))


def main():
    n = int(sys.argv[1])
    apply_changes = '--apply' in sys.argv
    rows = [l.split('\t') for l in open('/tmp/mcl_files.txt').read().splitlines() if l.strip()]
    targets = [r[1].strip() for r in rows[:n]]
    ok = fail = 0
    for rel in targets:
        path = WT + rel
        if not os.path.exists(path):
            print(f'MISSING {rel}')
            continue
        before = prose(path)
        r = subprocess.run([sys.executable, os.path.join(HERE, 'reflow.py'), rel]
                           + (['--apply'] if apply_changes else []),
                           capture_output=True, text=True, cwd=WT)
        line = r.stdout.strip().splitlines()[0] if r.stdout.strip() else r.stderr.strip()[:200]
        after = prose(path)
        if before != after:
            subprocess.run(['git', 'checkout', '--', rel], cwd=WT)
            print(f'REVERTED (prose changed) {rel} :: {line}')
            fail += 1
            continue
        if apply_changes and not parses(path):
            subprocess.run(['git', 'checkout', '--', rel], cwd=WT)
            print(f'REVERTED (does not parse) {rel} :: {line}')
            fail += 1
            continue
        print(f'OK {rel} :: {line}')
        ok += 1
    print(f'\n{ok} files preserved, {fail} reverted')


if __name__ == '__main__':
    main()
