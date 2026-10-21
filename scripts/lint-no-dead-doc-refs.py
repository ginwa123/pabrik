#!/usr/bin/env python3
"""Fail when a comment points at a document that does not exist.

WHY THIS EXISTS
---------------
A comment that says "see docs/plans/2026-08-06-x.md" is a promise to the
reader: follow the pointer, read the document, understand the code. When the
document is deleted, the promise is broken and the reader is left with a
dead end. The pointer is worse than no pointer, because it looks like an
answer.

This happened here. PR #815 deleted 356 plan documents in one commit and
left 218 comments pointing at them. Every one of those was a dead
promise, and nothing in the build noticed: the comment is not code, so
the compiler is silent, and no linter asked whether the file was still
there.

THE RULE
--------
A comment may not name a `docs/...md` path that does not resolve. A
reference resolves when the file exists, either at the repository root or
relative to the directory of the file that holds the comment — the
frontend's own `src/apps/desktop/docs/comment-length-policy.md` is
reachable that way, and the rule leaves it alone.

WHAT IS NOT BANNED
------------------
  * A path in a STRING LITERAL. A test fixture that mentions
    `docs/spec.md`, or a path a program writes, is data, not a pointer.
  * A path in a comment that is not a `docs/...md` path. This rule is
    about documents this repo keeps in `docs/`, not about every path in
    the tree.
  * A document that exists. Pointing at a live document is the point.

HOW IT IS SCANNED
------------------
The scan is LINE-ANCHORED: a line counts only when it BEGINS with a
comment marker, so a `docs/x.md` inside a string literal or a trailing
comment after code is not a finding. The rule is about a comment that
CLAIMS to point at a document, and a comment that starts the line is the
shape of such a claim.

That anchor is a deliberate trade. A full lexer would be exact, and this
script is not a lexer: it is a scan. The trade is that a `docs/x.md`
inside a multi-line string literal whose line happens to begin with `//`
is a false positive. There are none in this tree, and the selftest below
pins the behaviour so a change in the anchor cannot pass unnoticed.

USAGE
-----
  lint-no-dead-doc-refs.py           -> scan the tree, exit 1 on any hit
  lint-no-dead-doc-refs.py --selftest -> run against fixtures
"""
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# A `docs/...md` path, not preceded by a word character or a slash (so
# `/home/me/docs/spec.md` in a string literal is not a match).
DOC_REF = re.compile(r'(?<![\w/])docs/[A-Za-z0-9_./-]+\.md')

# A line that BEGINS a comment. The anchor is what keeps a `docs/x.md` in
# a string literal out of the findings.
COMMENT_START = re.compile(r'^\s*(?://|/\*|\*)')

# The trees the rule covers. `build.zig` is included because it is a Zig
# file the comment rules already cover.
SCAN_ROOTS = ('src', 'tests', 'tools')
SCAN_FILES = ('build.zig',)


def resolve(ref, file_dir):
    """True when the referenced document exists.

    A reference resolves at the repository root, or relative to the
    directory of the file that holds it — the frontend's own
    `src/apps/desktop/docs/*.md` is reachable that way.
    """
    if os.path.exists(ref):
        return True
    d = file_dir
    while True:
        cand = os.path.normpath(os.path.join(d, ref))
        if os.path.exists(cand):
            return True
        nd = os.path.dirname(d)
        if nd == d:
            return False
        d = nd


def scan_text(text, path):
    """The dead references in one file's text, as (line_no, ref) pairs."""
    out = []
    file_dir = os.path.dirname(os.path.abspath(path))
    for i, line in enumerate(text.split('\n'), 1):
        if not COMMENT_START.match(line):
            continue
        for m in DOC_REF.finditer(line):
            ref = m.group(0)
            if not resolve(ref, file_dir):
                out.append((i, ref))
    return out


def scan_file(path):
    with open(path, encoding='utf-8', errors='replace') as fh:
        return scan_text(fh.read(), path)


def targets():
    """Every file the rule covers."""
    for root in SCAN_ROOTS:
        base = os.path.join(REPO_ROOT, root)
        if not os.path.isdir(base):
            continue
        for dp, dn, fn in os.walk(base):
            for f in sorted(fn):
                if f.endswith(('.zig', '.ts', '.vue')):
                    yield os.path.join(dp, f)
    for f in SCAN_FILES:
        p = os.path.join(REPO_ROOT, f)
        if os.path.exists(p):
            yield p


def selftest():
    """The scan is the whole product, so it is checked against known input.

    A scanner that has quietly stopped matching is a silent outage, and
    the only way to notice is to check it against known input on every
    invocation. This is the same argument `ci-change-filter.sh` makes for
    its own --selftest.
    """
    import tempfile
    failures = 0

    def check(desc, expected, got):
        nonlocal failures
        if expected == got:
            print(f'  ok   {desc}')
        else:
            failures += 1
            print(f'  FAIL {desc}: expected {expected!r}, got {got!r}')

    with tempfile.TemporaryDirectory() as tmp:
        # 1. a comment pointing at a document that does not exist
        p = os.path.join(tmp, 'a.zig')
        open(p, 'w').write('// see docs/plans/2026-08-06-x.md\n')
        check('a dead reference is found', [(1, 'docs/plans/2026-08-06-x.md')],
              scan_file(p))

        # 2. a comment pointing at a document that DOES exist
        os.makedirs(os.path.join(tmp, 'docs', 'plans'))
        open(os.path.join(tmp, 'docs', 'plans', '2026-08-06-x.md'), 'w').write('# x\n')
        check('a live reference is not a finding', [], scan_file(p))

        # 3. a path in a string literal is DATA, not a pointer
        p2 = os.path.join(tmp, 'b.zig')
        open(p2, 'w').write(
            'const path = "docs/plans/2026-08-06-x.md";\n')
        check('a string literal is not a finding', [], scan_file(p2))

        # 4. a trailing comment after code is not a claim
        p3 = os.path.join(tmp, 'c.zig')
        open(p3, 'w').write('const x = 1; // see docs/plans/2026-08-06-x.md\n')
        check('a trailing comment is not a finding', [], scan_file(p3))

        # 5. a reference relative to the file's own directory resolves
        os.makedirs(os.path.join(tmp, 'sub', 'docs'))
        open(os.path.join(tmp, 'sub', 'docs', 'policy.md'), 'w').write('# p\n')
        p4 = os.path.join(tmp, 'sub', 'd.zig')
        open(p4, 'w').write('// see docs/policy.md\n')
        check('a dir-relative reference resolves', [], scan_file(p4))

        # 6. EVERY dead reference on a line is reported, not just the first.
        # The paths here do not exist: the fixture from case 2 created
        # `docs/plans/2026-08-06-x.md`, so this case must not reuse it.
        p5 = os.path.join(tmp, 'e.zig')
        open(p5, 'w').write('// see docs/plans/missing-one.md and docs/plans/missing-two.md\n')
        check('every dead reference on a line is reported',
              [(1, 'docs/plans/missing-one.md'), (1, 'docs/plans/missing-two.md')],
              scan_file(p5))

        # 7. a live reference and a dead one on the SAME line: only the dead
        #    one is a finding
        p6 = os.path.join(tmp, 'f.zig')
        open(p6, 'w').write('// see docs/plans/2026-08-06-x.md and docs/plans/missing.md\n')
        check('a live reference on the same line is not a finding',
              [(1, 'docs/plans/missing.md')], scan_file(p6))

    print()
    if failures:
        print(f'selftest: {failures} failure(s)')
        return 1
    print('selftest: all checks passed')
    return 0


def main():
    args = sys.argv[1:]
    if '--selftest' in args:
        sys.exit(selftest())
    if args:
        print(f'usage: {os.path.basename(sys.argv[0])} [--selftest]',
              file=sys.stderr)
        return 2

    hits = []
    for path in targets():
        for line, ref in scan_file(path):
            hits.append((path, line, ref))
    if hits:
        print('x a comment points at a document that does not exist.',
              file=sys.stderr)
        print('  A comment that names a document is a promise to the reader.',
              file=sys.stderr)
        print('  When the document is deleted, the promise is broken.', file=sys.stderr)
        print('  Either point at a document that exists, or drop the pointer.',
              file=sys.stderr)
        print('  See CODING_STANDARDS.md.', file=sys.stderr)
        print(file=sys.stderr)
        for path, line, ref in hits:
            rel = os.path.relpath(path, REPO_ROOT)
            print(f'  {rel}:{line}: {ref}', file=sys.stderr)
        return 1
    print('ok no comment points at a document that does not exist')
    return 0


if __name__ == '__main__':
    sys.exit(main())
