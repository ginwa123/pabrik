#!/usr/bin/env python3
"""Rejoin floating comment blocks across many files, then reflow what is left.

Usage: batch_rejoin.py <top-n-from-/tmp/nf_files.txt> [--apply]

Two steps per file, in this order:

  1. REJOIN — delete the single blank lines inside each floating chain, which
     turns N split blocks back into ONE block. This is what makes the cheat
     visible again.
  2. REFLOW — the rejoined block is now over the three-line ceiling, so
     `reflow.py` runs on it and shortens it honestly.

The same three guards as `batch.py` run after both steps, and any one failing
reverts the file: the comment prose must be character-identical, every
non-comment line must be unchanged, and the file must still parse.
"""
import glob as _glob
import os
import re
import subprocess
import sys
import tempfile

WT = '/home/ginwa/.config/pabrik/.worktrees/paydown-2548-comment-lines-1792080502826/'
HERE = os.path.dirname(os.path.abspath(__file__))
DESKTOP = WT + 'src/apps/desktop'
sys.path.insert(0, HERE)

from prose import code, prose  # noqa: E402
from rejoin import rejoin  # noqa: E402

VUE_PARSER = (_glob.glob(DESKTOP + '/node_modules/.pnpm/'
                         'vue-eslint-parser@*/node_modules/vue-eslint-parser') or [''])[0]
TS_PARSER = (_glob.glob(DESKTOP + '/node_modules/.pnpm/'
                        '@typescript-eslint+parser@*/node_modules/'
                        '@typescript-eslint/parser') or [''])[0]

# `@typescript-eslint/parser` ships ESM (`dist/index.js`), `vue-eslint-parser`
# ships CJS (`dist/index.cjs`), so the loader tries both. A dynamic import of
# a .cjs URL yields `{ default: module }`.
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
    """True when the file still parses after the edit."""
    src = open(path).read()
    if path.endswith('.vue'):
        if not _node_parse(src, 'vue', VUE_PARSER):
            return False
        for m in re.finditer(r'<script[^>]*>(.*?)</script>', src, re.S):
            if not _node_parse(m.group(1), 'ts', TS_PARSER):
                return False
        return True
    return _node_parse(src, 'ts', TS_PARSER)


def main():
    n = int(sys.argv[1])
    apply_changes = '--apply' in sys.argv
    rows = [l.split('\t') for l in open('/tmp/nf_files.txt').read().splitlines() if l.strip()]
    ok = fail = 0
    for rel in [r[1].strip() for r in rows[:n]]:
        path = WT + rel
        if not os.path.exists(path):
            print(f'MISSING {rel}')
            continue
        before = prose(path)
        code_before = code(path)

        removed = rejoin(path, apply_changes)
        # Reflow whatever the rejoin exposed, using the CURRENT findings.
        r = subprocess.run([sys.executable, os.path.join(HERE, 'reflow.py'), rel]
                           + (['--apply'] if apply_changes else []),
                           capture_output=True, text=True, cwd=WT)
        line = (r.stdout.strip().splitlines() or [r.stderr.strip()[:200]])[0]

        if prose(path) != before:
            subprocess.run(['git', 'checkout', '--', rel], cwd=WT)
            print(f'REVERTED (prose changed) {rel} :: rejoined {removed} :: {line}')
            fail += 1
            continue
        if code(path) != code_before:
            subprocess.run(['git', 'checkout', '--', rel], cwd=WT)
            print(f'REVERTED (code changed) {rel} :: rejoined {removed} :: {line}')
            fail += 1
            continue
        if apply_changes and not parses(path):
            subprocess.run(['git', 'checkout', '--', rel], cwd=WT)
            print(f'REVERTED (does not parse) {rel} :: rejoined {removed} :: {line}')
            fail += 1
            continue
        print(f'OK {rel} :: rejoined {removed} :: {line}')
        ok += 1
    print(f'\n{ok} files kept, {fail} reverted')


if __name__ == '__main__':
    main()
