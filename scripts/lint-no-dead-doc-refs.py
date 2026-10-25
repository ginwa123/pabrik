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
in a directory between the file that holds the comment and that root —
the frontend's own `src/apps/desktop/docs/comment-length-policy.md` is
reachable that way, and the rule leaves it alone.

WHAT IS NOT BANNED
------------------
  * A path in a STRING LITERAL. A test fixture that mentions
    `docs/spec.md`, or a path a program writes, is data, not a pointer.
  * A path in a comment that is not a `docs/...md` path. This rule is
    about documents this repo keeps in `docs/`, not about every path in
    the tree.
  * A document that exists. Pointing at a live document is the point.

WHICH FILES
-----------
Only the files git keeps: the scan is `git ls-files --cached --others
--exclude-standard`, filtered to `.zig`, `.ts` and `.vue` under `src/`,
`tests/` and `tools/`, plus `build.zig`. Staged and untracked-but-kept
files are both in scope, so a new file is checked; anything `.gitignore`
excludes is not.

This used to be a bare `os.walk`, and `os.walk` does not read
`.gitignore`. A local `pnpm install` therefore dropped a vendored SDK into
`src/apps/mcp_hello_world/node_modules/`, whose `.d.ts` header says
`@see docs/protocol.md` — a promise made by a third party, about a
document in somebody else's tree — and the gate failed on it. The same
walk also read the generated, ignored
`src/apps/desktop_app/embedded/webapp_assets.zig`. Both are files this
repo does not own, so both are out of scope, and git — which already
knows the answer, from `.gitignore`, `.git/info/exclude` and
`core.excludesFile` — is what decides. A hardcoded `node_modules` skip
would fix today's report and miss the generated file, the next `dist/`,
and whatever the next tool writes.

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

Exit codes: 0 clean, 1 findings, 2 a usage error or a scan that could not
run. There is no third answer, and no silent pass: enumerating the file
set is a step that can fail (no git, not a work tree), and a scan that
cannot run must never report the tree clean — that is the one answer that
lets a violation merge.
"""
import os
import re
import subprocess
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
SUFFIXES = ('.zig', '.ts', '.vue')


class ScanError(Exception):
    """The file set could not be enumerated, so this is not a clean tree."""


def resolve(ref, file_dir, root=REPO_ROOT):
    """True when the referenced document exists.

    A reference resolves at the repository root, or relative to the
    directory of the file that holds it — the frontend's own
    `src/apps/desktop/docs/*.md` is reachable that way. Both checks are
    anchored at `root`, never at the process's working directory: a gate
    whose verdict depends on where it was invoked from is not a gate.
    The walk up the parents stops at `root`, because a document outside
    the repository is not a document this repository promised.
    """
    root = os.path.abspath(root)
    if os.path.exists(os.path.join(root, ref)):
        return True
    d = os.path.abspath(file_dir)
    while True:
        if os.path.exists(os.path.join(d, ref)):
            return True
        if d == root:
            return False
        parent = os.path.dirname(d)
        if parent == d:
            return False
        d = parent


def scan_text(text, path, root=REPO_ROOT):
    """The dead references in one file's text, as (line_no, ref) pairs."""
    out = []
    file_dir = os.path.dirname(os.path.abspath(path))
    for i, line in enumerate(text.split('\n'), 1):
        if not COMMENT_START.match(line):
            continue
        for m in DOC_REF.finditer(line):
            ref = m.group(0)
            if not resolve(ref, file_dir, root):
                out.append((i, ref))
    return out


def scan_file(path, root=REPO_ROOT):
    with open(path, encoding='utf-8', errors='replace') as fh:
        return scan_text(fh.read(), path, root)


def targets(root=REPO_ROOT):
    """Every file the rule covers: the ones git keeps, the ones it ignores not.

    Raises `ScanError` when git cannot answer — see the module docstring
    for why that is a failure and not an empty list.
    """
    cmd = ['git', '-C', root, 'ls-files', '-z', '--cached', '--others',
           '--exclude-standard', '--full-name', '--', *SCAN_ROOTS, *SCAN_FILES]
    try:
        proc = subprocess.run(cmd, capture_output=True, check=False)
    except OSError as exc:
        raise ScanError(f'could not run git: {exc}') from exc
    if proc.returncode != 0:
        err = proc.stderr.decode('utf-8', 'replace').strip()
        raise ScanError(f'git ls-files failed (exit {proc.returncode}): {err}')
    for rel in proc.stdout.decode('utf-8', 'replace').split('\0'):
        if not rel or not rel.endswith(SUFFIXES):
            continue
        path = os.path.join(root, rel)
        # A tracked file can be deleted from the working tree and not yet
        # staged; git still lists it, and there is nothing to read.
        if os.path.isfile(path):
            yield path


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

    def fixture_git(repo, *args, check=True):
        """Git in a FIXTURE repo, with the caller's GIT_* environment removed.

        A pre-commit hook runs under `git commit`, and a commit made from a
        LINKED WORKTREE exports `GIT_INDEX_FILE`. Inherited, it makes this
        `git add` write into the CALLER's index instead of the fixture's: a
        phantom `src/tracked.zig` entry then exists with no file on disk, the
        next commit records it, and CI's own scan fails on a fixture nobody
        wrote. Scrubbing the prefix is what keeps the fixture disposable.
        """
        env = {k: v for k, v in os.environ.items()
               if not k.startswith('GIT_')}
        return subprocess.run(['git', '-C', repo, *args], check=check,
                              capture_output=True, env=env)

    with tempfile.TemporaryDirectory() as tmp:
        # 1. a comment pointing at a document that does not exist
        p = os.path.join(tmp, 'a.zig')
        open(p, 'w').write('// see docs/plans/2026-08-06-x.md\n')
        check('a dead reference is found', [(1, 'docs/plans/2026-08-06-x.md')],
              scan_file(p, tmp))

        # 2. a comment pointing at a document that DOES exist. It is at the
        #    root of the fixture tree, so this also pins that a root-anchored
        #    reference resolves without asking the process's CWD.
        os.makedirs(os.path.join(tmp, 'docs', 'plans'))
        open(os.path.join(tmp, 'docs', 'plans', '2026-08-06-x.md'), 'w').write('# x\n')
        check('a live reference is not a finding', [], scan_file(p, tmp))

        # 3. a path in a string literal is DATA, not a pointer
        p2 = os.path.join(tmp, 'b.zig')
        open(p2, 'w').write(
            'const path = "docs/plans/2026-08-06-x.md";\n')
        check('a string literal is not a finding', [], scan_file(p2, tmp))

        # 4. a trailing comment after code is not a claim
        p3 = os.path.join(tmp, 'c.zig')
        open(p3, 'w').write('const x = 1; // see docs/plans/2026-08-06-x.md\n')
        check('a trailing comment is not a finding', [], scan_file(p3, tmp))

        # 5. a reference relative to the file's own directory resolves
        os.makedirs(os.path.join(tmp, 'sub', 'docs'))
        open(os.path.join(tmp, 'sub', 'docs', 'policy.md'), 'w').write('# p\n')
        p4 = os.path.join(tmp, 'sub', 'd.zig')
        open(p4, 'w').write('// see docs/policy.md\n')
        check('a dir-relative reference resolves', [], scan_file(p4, tmp))

        # 6. EVERY dead reference on a line is reported, not just the first.
        # The paths here do not exist: the fixture from case 2 created
        # `docs/plans/2026-08-06-x.md`, so this case must not reuse it.
        p5 = os.path.join(tmp, 'e.zig')
        open(p5, 'w').write('// see docs/plans/missing-one.md and docs/plans/missing-two.md\n')
        check('every dead reference on a line is reported',
              [(1, 'docs/plans/missing-one.md'), (1, 'docs/plans/missing-two.md')],
              scan_file(p5, tmp))

        # 7. a live reference and a dead one on the SAME line: only the dead
        #    one is a finding
        p6 = os.path.join(tmp, 'f.zig')
        open(p6, 'w').write('// see docs/plans/2026-08-06-x.md and docs/plans/missing.md\n')
        check('a live reference on the same line is not a finding',
              [(1, 'docs/plans/missing.md')], scan_file(p6, tmp))

    # 8. WHICH FILES: the file set is git's, so a vendored dependency and a
    #    generated artifact are out of scope while a real source file is not.
    #    The fixture is a throwaway repo with a `.gitignore`, because that is
    #    the exact mechanism the scan has to obey — not a hardcoded list of
    #    directory names.
    with tempfile.TemporaryDirectory() as repo:
        fixture_git(repo, 'init', '-q')
        open(os.path.join(repo, '.gitignore'), 'w').write(
            'node_modules/\ngen_deps.zig\n')

        def put(rel, text):
            path = os.path.join(repo, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, 'w').write(text)
            return path

        put('src/tracked.zig', '// see docs/gone-tracked.md\n')
        put('src/new.zig', '// see docs/gone-untracked.md\n')
        generated = put('src/gen_deps.zig', '// see docs/protocol.md\n')
        vendored = put(
            'src/apps/mcp_hello_world/node_modules/sdk/progressExample.d.ts',
            '/**\n * @see docs/protocol.md\n */\n')
        fixture_git(repo, 'add', 'src/tracked.zig')

        def findings(root):
            out = []
            for path in targets(root):
                for line, ref in scan_file(path, root):
                    out.append((os.path.relpath(path, root), line, ref))
            return sorted(out)

        def scanned(root):
            return sorted(os.path.relpath(p, root) for p in targets(root))

        # The fixtures must really hold dead references, or every "not
        # scanned" check below would pass for the wrong reason.
        check('the vendored fixture holds a dead reference',
              [(2, 'docs/protocol.md')], scan_file(vendored, repo))
        check('the generated fixture holds a dead reference',
              [(1, 'docs/protocol.md')], scan_file(generated, repo))

        # An ignored DIRECTORY is not descended into, and an ignored single
        # FILE is skipped. A staged file and an untracked-but-kept file are
        # both still scanned — a new file must not slip past the gate.
        check('only the files git keeps are scanned',
              ['src/new.zig', 'src/tracked.zig'], scanned(repo))
        check('a dead reference in a kept file is still a finding',
              [('src/new.zig', 1, 'docs/gone-untracked.md'),
               ('src/tracked.zig', 1, 'docs/gone-tracked.md')],
              findings(repo))
        # A fixture is only worth its name if git really ignores it: assert
        # that, so the two checks above cannot pass on a wrong .gitignore.
        ignored = [fixture_git(repo, 'check-ignore', '-q', p,
                              check=False).returncode
                   for p in (vendored, generated)]
        check('the unused fixtures are git-ignored', [0, 0], ignored)

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

    try:
        # Materialise: `targets` is a generator, and the enumeration error
        # only surfaces on the first `next` — after main has started looping.
        paths = list(targets())
    except ScanError as exc:
        print(f'x the dead-doc-ref scan could not run: {exc}', file=sys.stderr)
        print('  A scan that cannot run must never report the tree clean.',
              file=sys.stderr)
        return 2

    hits = []
    for path in paths:
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
