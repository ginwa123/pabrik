#!/usr/bin/env python3
"""Fail when a Kotlin comment block spans more than two lines.

WHY THIS EXISTS
---------------
CODING_STANDARDS.md §4 caps a Zig comment block at three lines and §5 caps
the same block in Vue/TypeScript at three. The Android app had no cap at
all, so a comment there could grow into a design document sitting between
the reader and the function it describes.

The ceiling here is TWO, one line tighter than §4/§5, because that is the
number this app was asked to hold. Nothing else differs: the semantics are
`local/max-comment-lines`'s, which are `zginlint/max-comment-lines`'s, so
"a comment block is a paragraph" means the same thing in all three
languages.

THE RULE
--------
* A **comment line** carries comment content and no code byte, so a blank
  line or a line with code on it ends the block.
* A **comment block** is a run of consecutive comment lines. Two lines
  pass, three fail, and the finding is reported at the block's first line.
* A `/* ... */` comment counts by the lines it spans. In Kotlin the block
  form NESTS, so `/* a /* b */ c */` is one comment and its depth is
  tracked rather than assumed.
* `/** ... */` KDoc counts like any other comment. There is no doc-string
  exemption.
* `--max N` moves the ceiling.

WHAT IS NOT BANNED
------------------
  * Comments. The rule is about length, not existence.
  * A trailing comment after code. `val x = 1 // note` has a code byte on
    its line, so it is not a comment line and never joins a block.
  * Comment markers inside a literal. `"// not a comment"`, a raw string
    holding `/*`, and `'/'` are text. This is a lexer, not a line scan, so
    it knows the difference — and the selftest pins it.
  * Prose everywhere else. Docs, commit messages, PR bodies and YAML
    comments are not Kotlin and are not scanned.

WHICH FILES
-----------
Every `.kt` file git keeps under `src/apps/android_mobile/` — `main`,
`test` and `androidTest` alike. The file set is
`git ls-files --cached --others --exclude-standard`, so staged and
untracked-but-kept files are both checked and anything `.gitignore`
excludes (Gradle's `build/`, `.gradle/`) is not.

Enumerating that set is a step that can FAIL (no git, not a work tree, a
directory that does not exist). When it does, this script exits 2 and says
so; it never reports the tree clean, because "clean" is the one answer that
lets a violation merge.

THE BASELINE, AND HOW IT GOES AWAY
----------------------------------
The tree carries 1,806 over-long blocks in 211 files — mostly KDoc that
explains a real invariant in a paragraph, which is exactly the prose this
rule is about. Converting them is not mechanical and it is not this
change's job, so the rule ships the way §2 and §5 shipped: with a counted
ceiling in `src/apps/android_mobile/comment-lines-baseline.json`, one pin
per file.

| | |
|---|---|
| a file over its pin | **FAIL** |
| a file with findings that is not pinned | **FAIL** (a new file cannot sneak in) |
| a count below its pin | PASS, with a notice naming the value to re-pin |
| a baseline pinned at a different `--max` | **FAIL** (a looser ceiling needs a deliberate re-pin) |

The count may only fall. `--pin` rewrites the baseline and is for AFTER
fixing debt, never for silencing a new violation. `--strict` ignores the
baseline entirely and asks for zero; it is the finish line and is tested
today, so flipping the CI step to it is a one-word change.

USAGE
-----
  lint-kt-comment-lines.py             -> the gate: check against the pin
  lint-kt-comment-lines.py --strict    -> the finish line: zero findings
  lint-kt-comment-lines.py --pin       -> re-pin to today's counts
  lint-kt-comment-lines.py --selftest  -> the scanner and the verdict, on fixtures
  lint-kt-comment-lines.py --max 3     -> move the ceiling (needs a matching pin)
  lint-kt-comment-lines.py --root DIR  -> scan another tree (repeatable)

Exit codes: 0 clean, 1 findings, 2 usage error or a scan that could not
run.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DEFAULT_MAX = 2
DEFAULT_ROOT = os.path.join('src', 'apps', 'android_mobile')
BASELINE = os.path.join(REPO_ROOT, 'src', 'apps', 'android_mobile',
                        'comment-lines-baseline.json')
SUFFIX = '.kt'


class ScanError(Exception):
    """The file set could not be enumerated, so this is not a clean tree."""


class UsageError(Exception):
    """The ceiling and the baseline disagree, or the baseline is missing."""


class Span:
    """One comment's extent: 1-indexed lines, 0-indexed columns.

    `end_col` is EXCLUSIVE. A `//` comment ends at the end of its line, so
    its `end_col` is that line's length and the "anything after it" test
    that decides whether the last line carries a code byte is trivially
    satisfied.
    """

    __slots__ = ('start_line', 'start_col', 'end_line', 'end_col')

    def __init__(self, start_line, start_col, end_line, end_col):
        self.start_line = start_line
        self.start_col = start_col
        self.end_line = end_line
        self.end_col = end_col


def scan_comment_spans(text):
    """Every comment in `text`, in source order.

    One pass over the characters keeps string and comment state apart, so
    a `//` inside a string literal is text and a `"` inside a comment is
    text. Kotlin's literal shapes are all here: `"..."` with backslash
    escapes, raw `\"\"\"...\"\"\"` strings (no escapes, may span lines), `'x'`
    char literals, and `//` / nesting `/* */` comments.
    """
    spans = []
    i = 0
    n = len(text)
    line = 1
    col = 0

    def advance(to):
        nonlocal i, line, col
        to = min(to, n)
        while i < to:
            if text[i] == '\n':
                line += 1
                col = 0
            else:
                col += 1
            i += 1

    while i < n:
        ch = text[i]

        if text.startswith('//', i):
            end = text.find('\n', i)
            if end < 0:
                end = n
            spans.append(Span(line, col, line, col + (end - i)))
            advance(end)
            continue

        if text.startswith('/*', i):
            start_line, start_col = line, col
            depth = 0
            while i < n:
                if text.startswith('/*', i):
                    depth += 1
                    advance(i + 2)
                    continue
                if text.startswith('*/', i):
                    depth -= 1
                    advance(i + 2)
                    if depth == 0:
                        break
                    continue
                advance(i + 1)
            spans.append(Span(start_line, start_col, line, col))
            continue

        if text.startswith('"""', i):
            advance(i + 3)
            while i < n and not text.startswith('"""', i):
                advance(i + 1)
            advance(i + 3)
            continue

        if ch == '"' or ch == "'":
            quote = ch
            advance(i + 1)
            while i < n:
                if text[i] == '\\':
                    advance(i + 2)
                    continue
                if text[i] == quote:
                    advance(i + 1)
                    break
                advance(i + 1)
            continue

        advance(i + 1)

    return spans


def is_blank(text):
    return text.strip() == ''


def comment_lines(spans, lines):
    """The line numbers that carry comment content and no code byte.

    A `//` comment counts only when nothing but whitespace precedes it. A
    block comment counts its first line only when nothing precedes it, its
    last line only when nothing follows it, and every line between
    unconditionally — the same test `maxCommentLines.ts` applies.
    """
    out = []
    for span in spans:
        first, last = span.start_line, span.end_line
        before = is_blank(lines[first - 1][:span.start_col])
        after = is_blank(lines[last - 1][span.end_col:])
        if first == last:
            if before and after:
                out.append(first)
            continue
        if before:
            out.append(first)
        out.extend(range(first + 1, last))
        if after:
            out.append(last)
    return sorted(set(out))


def blocks_from_lines(line_numbers):
    """Group ascending comment-line numbers into blocks.

    A line continues the previous block when it is the very next line, and
    otherwise opens a new one — exactly what the Zig and ESLint halves do.
    """
    blocks = []
    for line in line_numbers:
        if blocks and blocks[-1][0] + blocks[-1][1] == line:
            blocks[-1][1] += 1
        else:
            blocks.append([line, 1])
    return [tuple(block) for block in blocks]


def scan_text(text, max_lines):
    """The over-long blocks in one file: (first_line, line_count) pairs."""
    lines = text.split('\n')
    found = blocks_from_lines(comment_lines(scan_comment_spans(text), lines))
    return [block for block in found if block[1] > max_lines]


def scan_file(path, max_lines):
    with open(path, 'r', encoding='utf-8', errors='replace') as handle:
        return scan_text(handle.read(), max_lines)


def kt_files(roots):
    """The `.kt` files git keeps under `roots`, as (repo-relative, absolute).

    `git ls-files` reads `.gitignore` for us, which a bare `os.walk` does
    not: a local Gradle build writes thousands of `.kt` files under
    `build/`, and they are not files this repo owns.
    """
    try:
        listing = subprocess.run(
            ['git', 'ls-files', '--cached', '--others', '--exclude-standard',
             '--', *roots],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as err:
        raise ScanError('git could not be run: %s' % err) from err
    if listing.returncode != 0:
        raise ScanError('git ls-files failed: %s'
                        % (listing.stderr.strip() or listing.returncode))

    files = []
    for relative in listing.stdout.splitlines():
        if not relative.endswith(SUFFIX):
            continue
        if not any(relative == root or relative.startswith(root + os.sep)
                   for root in roots):
            continue
        absolute = os.path.join(REPO_ROOT, relative)
        if not os.path.isfile(absolute):
            continue
        files.append((relative, absolute))
    if not files:
        raise ScanError('no %s files under %s — the scan would be vacuous'
                        % (SUFFIX, ', '.join(roots)))
    return sorted(files)


def scan_tree(roots, max_lines):
    """Every finding in the tree, keyed by repo-relative path."""
    per_file = {}
    files = kt_files(roots)
    for relative, absolute in files:
        per_file[relative] = scan_file(absolute, max_lines)
    return per_file


def load_baseline(path=BASELINE):
    if not os.path.isfile(path):
        raise UsageError('no baseline at %s — run --pin in the change that '
                         'adds the rule' % os.path.relpath(path, REPO_ROOT))
    try:
        with open(path, 'r', encoding='utf-8') as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as err:
        raise UsageError('baseline %s is unreadable: %s'
                         % (os.path.relpath(path, REPO_ROOT), err)) from err
    if not isinstance(data.get('files'), dict) or 'max' not in data:
        raise UsageError('baseline %s needs `max` and `files`'
                         % os.path.relpath(path, REPO_ROOT))
    return data


def verdict(per_file, baseline, max_lines):
    """Split a scan into (failures, notices) against the pins.

    A failure is a reason to exit 1. A notice is a pin that has gone stale
    in the safe direction — the count fell — because a gate that fails on
    improvement teaches people to stop improving.
    """
    if baseline['max'] != max_lines:
        raise UsageError('baseline is pinned at --max %s but this run asks '
                         'for %s — re-pin deliberately, or drop --max'
                         % (baseline['max'], max_lines))

    pins = baseline['files']
    totals = {'pinned': 0, 'found': 0, 'over': 0, 'unpinned': 0}
    failures = []
    notices = []

    for path in sorted(per_file):
        findings = per_file[path]
        found = len(findings)
        totals['found'] += found
        pin = pins.get(path)
        if pin is None:
            if found:
                totals['unpinned'] += 1
                failures.append('%s: %d comment block(s) over %d lines, and '
                                'the file is not in the baseline'
                                % (path, found, max_lines))
                for first_line, line_count in findings:
                    failures.append('  %s:%d: %d lines'
                                    % (path, first_line, line_count))
            continue
        totals['pinned'] += pin
        if found > pin:
            totals['over'] += 1
            failures.append('%s: %d comment block(s) over %d lines, baseline '
                            'pins %d' % (path, found, max_lines, pin))
            for first_line, line_count in findings:
                failures.append('  %s:%d: %d lines'
                                % (path, first_line, line_count))
        elif found < pin:
            notices.append('%s: %d baselined block(s) fixed — re-pin to %d'
                           % (path, pin, found))

    for path in sorted(pins):
        if path not in per_file:
            notices.append('%s: pinned at %d but not scanned' % (path, pins[path]))

    return failures, notices, totals


def cmd_pin(roots, max_lines):
    per_file = scan_tree(roots, max_lines)
    pins = {path: len(findings) for path, findings in per_file.items()
            if findings}
    total = sum(pins.values())
    payload = {
        'max': max_lines,
        'root': roots[0] if len(roots) == 1 else roots,
        'files': pins,
        'total': total,
    }
    with open(BASELINE, 'w', encoding='utf-8') as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write('\n')
    print('pinned %d comment block(s) over %d lines across %d of %d files -> %s'
          % (total, max_lines, len(pins), len(per_file),
             os.path.relpath(BASELINE, REPO_ROOT)))
    return 0


def cmd_check(roots, max_lines, strict):
    per_file = scan_tree(roots, max_lines)
    scanned = len(per_file)

    if strict:
        failures = []
        for path in sorted(per_file):
            findings = per_file[path]
            if not findings:
                continue
            failures.append('%s: %d comment block(s) over %d lines'
                            % (path, len(findings), max_lines))
            for first_line, line_count in findings:
                failures.append('  %s:%d: %d lines'
                                % (path, first_line, line_count))
        if failures:
            print('\n'.join(failures))
            print()
            print('x --strict asks for zero: %d file(s) carry an over-long '
                  'comment block' % sum(1 for f in per_file.values() if f))
            return 1
        print('ok --strict: %d Kotlin file(s), no comment block over %d lines'
              % (scanned, max_lines))
        return 0

    failures, notices, totals = verdict(per_file, load_baseline(), max_lines)

    if failures:
        print('\n'.join(failures))
        print()
        print('x %d file(s) over their baseline pin (%d block(s) baselined, '
              '%d found)' % (totals['over'] + totals['unpinned'],
                             totals['pinned'], totals['found']))
        print('  A comment block is a paragraph. Keep the two lines that say')
        print('  WHY — which operation this guards, which invariant it relies')
        print('  on — and move the rest to the commit message or the PR body.')
        print('  (CODING_STANDARDS.md §7.)')
        return 1

    if notices:
        print('\n'.join('note %s' % notice for notice in notices))
        print()
    print('ok %d Kotlin file(s): no comment block over %d lines beyond the '
          'baseline (%d baselined)' % (scanned, max_lines, totals['pinned']))
    return 0


def selftest():
    """Drive the scanner and the verdict with fixtures whose answer is known.

    A scanner that has quietly stopped matching is a silent outage, and the
    only way to notice is to run it against known input on every
    invocation. The same holds for the verdict: a ratchet that no longer
    fails on growth is worse than no linter.
    """
    failures = []

    def check(name, source, expected, max_lines=DEFAULT_MAX):
        actual = scan_text(source, max_lines)
        if actual == expected:
            print('  ok %s' % name)
            return
        failures.append(name)
        print('  FAIL %s: expected %r, got %r' % (name, expected, actual))

    check('a two-line block passes', '// one\n// two\nval x = 1\n', [])
    check('a three-line block fails at its first line',
          '// one\n// two\n// three\nval x = 1\n', [(1, 3)])
    check('a blank line splits two legal blocks',
          '// one\n// two\n\n// three\n// four\n', [])
    check('a code line splits two legal blocks',
          '// one\n// two\nval x = 1\n// three\n// four\n', [])
    check('a trailing comment after code never joins a block',
          'val x = 1 // note\n// one\n// two\n', [])
    check('a trailing comment after code does not open one',
          '// one\n// two\nval x = 1 // note\n// three\n// four\n', [])
    check('a marker inside a string literal is text',
          'val s = "// one\\n// two"\nval t = 1\n', [])
    check('an escaped quote does not end the string',
          'val s = "a \\" // b"\nval t = 1\n', [])
    check('a marker inside a raw string literal is text',
          'val s = """\n// one\n// two\n// three\n"""\nval t = 1\n', [])
    check('a marker inside a char literal is text',
          "val c = '/'\nval d = '\\n'\nval t = 1\n", [])
    check('a block comment counts the lines it spans',
          '/* one\n   two\n   three */\nval x = 1\n', [(1, 3)])
    check('a two-line block comment passes',
          '/* one\n   two */\nval x = 1\n', [])
    check('a block comment opened after code does not count its first line',
          'val x = 1 /* one\n   two\n   three */\n', [])
    check('a block comment closed before code does not count its last line',
          '/* one\n   two\n   three */ val x = 1\n', [])
    check('KDoc counts like any other comment',
          '/** one\n * two\n * three */\nval x = 1\n', [(1, 3)])
    check('a nested block comment is one comment',
          '/* one /* inner */\n   two\n   three */\nval x = 1\n', [(1, 3)])
    check('a comment line mixed with a block comment is one block',
          '// one\n/* two\n   three */\nval x = 1\n', [(1, 3)])
    check('--max 3 moves the ceiling',
          '// one\n// two\n// three\nval x = 1\n', [], max_lines=3)
    check('--max 1 tightens it',
          '// one\n// two\nval x = 1\n', [(1, 2)], max_lines=1)
    check('an unterminated raw string does not crash the lexer',
          'val s = """\n// one\n// two\n', [])
    check('an unterminated block comment does not crash the lexer',
          '/* one\n// two\n// three', [(1, 3)])

    if scan_text('', DEFAULT_MAX) == []:
        print('  ok an empty file has no blocks')
    else:
        failures.append('empty file')
        print('  FAIL empty file: non-empty result')

    with tempfile.TemporaryDirectory() as tmp:
        try:
            kt_files([os.path.join(tmp, 'nothing-here')])
        except ScanError:
            print('  ok a scan with no files fails instead of passing')
        else:
            failures.append('vacuous scan')
            print('  FAIL a scan with no files reported clean')

    def check_verdict(name, per_file, baseline, expected_failures,
                      expected_notices=0):
        try:
            got_failures, got_notices, _ = verdict(per_file, baseline,
                                                   DEFAULT_MAX)
        except UsageError as err:
            failures.append(name)
            print('  FAIL %s: unexpected usage error: %s' % (name, err))
            return
        # Detail lines are indented; only the file-level entries count here.
        got_top = [line for line in got_failures if not line.startswith('  ')]
        if (len(got_top) == expected_failures
                and len(got_notices) == expected_notices):
            print('  ok %s' % name)
            return
        failures.append(name)
        print('  FAIL %s: %d failure(s)/%d notice(s), expected %d/%d'
              % (name, len(got_top), len(got_notices),
                 expected_failures, expected_notices))

    pinned = {'max': DEFAULT_MAX, 'files': {'a.kt': 2}}
    check_verdict('a file at its pin passes',
                  {'a.kt': [(1, 3), (9, 4)]}, pinned, 0)
    check_verdict('a file over its pin fails',
                  {'a.kt': [(1, 3), (9, 4), (20, 5)]}, pinned, 1)
    check_verdict('a clean file drops a notice to re-pin',
                  {'a.kt': []}, pinned, 0, expected_notices=1)
    check_verdict('a new file with findings fails',
                  {'a.kt': [], 'b.kt': [(1, 3)]}, pinned, 1,
                  expected_notices=1)
    check_verdict('a new clean file is fine',
                  {'a.kt': [], 'b.kt': []}, pinned, 0, expected_notices=1)

    try:
        verdict({}, {'max': 3, 'files': {}}, DEFAULT_MAX)
    except UsageError:
        print('  ok a looser baseline than --max fails instead of passing')
    else:
        failures.append('ceiling mismatch')
        print('  FAIL a baseline pinned at 3 passed a --max 2 run')

    if failures:
        print()
        print('x %d selftest fixture(s) failed: %s'
              % (len(failures), ', '.join(failures)))
        return 1
    print()
    print('ok every selftest fixture behaved')
    return 0


def main(argv):
    parser = argparse.ArgumentParser(
        description='Fail when a Kotlin comment block exceeds the ceiling.')
    parser.add_argument('--selftest', action='store_true',
                        help='run the scanner and verdict against fixtures')
    parser.add_argument('--pin', action='store_true',
                        help='re-pin the baseline to today\'s counts')
    parser.add_argument('--strict', action='store_true',
                        help='ignore the baseline and require zero findings')
    parser.add_argument('--max', type=int, default=DEFAULT_MAX, metavar='N',
                        help='lines allowed per block (default %d)' % DEFAULT_MAX)
    parser.add_argument('--root', action='append', default=None, metavar='DIR',
                        help='tree to scan, repeatable (default: %s)'
                             % DEFAULT_ROOT)
    args = parser.parse_args(argv)

    if args.selftest:
        return selftest()
    if args.max < 1:
        print('x --max must be at least 1', file=sys.stderr)
        return 2

    roots = args.root or [DEFAULT_ROOT]
    try:
        if args.pin:
            return cmd_pin(roots, args.max)
        return cmd_check(roots, args.max, args.strict)
    except ScanError as err:
        print('x %s' % err, file=sys.stderr)
        return 2
    except UsageError as err:
        print('x %s' % err, file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
