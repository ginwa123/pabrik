#!/usr/bin/env python3
"""Fail when a Kotlin file carries more than 1000 lines of code.

WHY THIS EXISTS
---------------
CODING_STANDARDS.md §4 caps a Zig comment block at three lines, §5 the same
in Vue/TypeScript, and §7 the same in Kotlin at two. Those rules cap the
prose. Nothing capped the CODE, so a Kotlin file could grow until the reader
had to scroll to find the class it declares.

The desktop app has had that cap since it was written — ESLint's `max-lines`
at 600 for source, 1000 for tests, 800 for `.d.ts`. This is the Android half,
at a flat 1000.

WHAT A "CODE LINE" IS
---------------------
A line that is neither blank nor comment-only. Comments and blank lines are
free, deliberately: this repo's comments are dense and §7 already governs
their length, so a total-lines cap would make deleting an explanation the
cheapest way to satisfy the gate. The rule measures how much LOGIC sits in
one file, which is the thing that actually hurts.

  * a line with code and a trailing comment is a code line
  * a line inside a raw string literal is a code line
  * a blank line inside a raw string literal is blank (a documented gap)
  * `//`, `/* */` and `/** */` lines are not code lines

THE RULE
--------
* A file at or under 1000 code lines passes.
* A file over 1000 fails, and the finding names the count.
* `--max N` moves the ceiling.

WHICH FILES
-----------
Every `.kt` file git keeps under `src/apps/android_mobile/` — `main`, `test`
and `androidTest` alike, via `git ls-files --cached --others
--exclude-standard`, so a new file is checked before it is committed and
Gradle's `build/` is not.

Enumerating that set is a step that can FAIL (no git, not a work tree, a
directory that does not exist). When it does, this script exits 2 and says
so; it never reports the tree clean, because "clean" is the one answer that
lets a violation merge.

THE BASELINE, AND HOW IT GOES AWAY
----------------------------------
One file is over the ceiling today: `CreateTaskTest.kt` at 1057 code lines.
Splitting a 1571-line test file is a real refactor, not a mechanical one, so
the rule ships the way §2, §5 and §7 shipped: with a counted ceiling in
`src/apps/android_mobile/file-lines-baseline.json`, one pin per file.

| | |
|---|---|
| a file over its pin | **FAIL** |
| a file over the ceiling that is not pinned | **FAIL** (a new file cannot sneak in) |
| a count below its pin | PASS, with a notice naming the value to re-pin |
| a pinned file now under the ceiling | PASS, with a notice to drop the pin |
| a baseline pinned at a different `--max` | **FAIL** (a looser ceiling needs a deliberate re-pin) |
| the baseline file missing or unreadable | **FAIL** (exit 2) |

The count may only fall. `--pin` rewrites the baseline and is for AFTER
fixing debt, never for silencing a new violation. `--strict` ignores the
baseline entirely and asks for zero; it is the finish line and is tested
today, so flipping the CI step to it is a one-word change.

USAGE
-----
  lint-kt-file-lines.py             -> the gate: check against the pin
  lint-kt-file-lines.py --strict    -> the finish line: zero findings
  lint-kt-file-lines.py --pin       -> re-pin to today's counts
  lint-kt-file-lines.py --selftest  -> the counter and the verdict, on fixtures
  lint-kt-file-lines.py --max 800   -> move the ceiling (needs a matching pin)
  lint-kt-file-lines.py --root DIR  -> scan another tree (repeatable)

Exit codes: 0 clean, 1 findings, 2 usage error or a scan that could not run.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DEFAULT_MAX = 1000
DEFAULT_ROOT = os.path.join('src', 'apps', 'android_mobile')
BASELINE = os.path.join(REPO_ROOT, 'src', 'apps', 'android_mobile',
                        'file-lines-baseline.json')
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


def code_line_count(text):
    """How many lines of `text` carry code.

    A code line is neither blank nor comment-only. A line with code and a
    trailing comment is code; a line inside a raw string literal is code.
    """
    lines = text.split('\n')
    comments = set(comment_lines(scan_comment_spans(text), lines))
    return sum(1 for number, line in enumerate(lines, 1)
               if line.strip() and number not in comments)


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


def scan_tree(roots):
    """Every file's code-line count, keyed by repo-relative path."""
    per_file = {}
    for relative, absolute in kt_files(roots):
        with open(absolute, 'r', encoding='utf-8', errors='replace') as handle:
            per_file[relative] = code_line_count(handle.read())
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
    """Split a scan into (failures, notices, totals) against the pins.

    A failure is a reason to exit 1. A notice is a pin that has gone stale
    in the safe direction — the count fell — because a gate that fails on
    improvement teaches people to stop improving.
    """
    if baseline['max'] != max_lines:
        raise UsageError('baseline is pinned at --max %s but this run asks '
                         'for %s — re-pin deliberately, or drop --max'
                         % (baseline['max'], max_lines))

    pins = baseline['files']
    totals = {'pinned': 0, 'over': 0, 'unpinned': 0, 'largest': 0}
    failures = []
    notices = []

    for path in sorted(per_file):
        count = per_file[path]
        totals['largest'] = max(totals['largest'], count)
        pin = pins.get(path)
        if pin is None:
            if count > max_lines:
                totals['unpinned'] += 1
                failures.append('%s: %d code lines, over the %d ceiling, and '
                                'the file is not in the baseline'
                                % (path, count, max_lines))
            continue
        totals['pinned'] += 1
        if count > pin:
            totals['over'] += 1
            failures.append('%s: %d code lines, baseline pins %d'
                            % (path, count, pin))
        elif count < pin:
            if count > max_lines:
                notices.append('%s: %d code lines, down from %d — re-pin to %d'
                               % (path, count, pin, count))
            else:
                notices.append('%s: %d code lines, at or under the %d ceiling '
                               '— drop it from the baseline'
                               % (path, count, max_lines))

    for path in sorted(pins):
        if path not in per_file:
            notices.append('%s: pinned at %d but not scanned'
                           % (path, pins[path]))

    return failures, notices, totals


def cmd_pin(roots, max_lines):
    per_file = scan_tree(roots)
    pins = {path: count for path, count in per_file.items()
            if count > max_lines}
    payload = {
        'max': max_lines,
        'root': roots[0] if len(roots) == 1 else roots,
        'files': pins,
        'total': sum(pins.values()),
    }
    with open(BASELINE, 'w', encoding='utf-8') as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write('\n')
    print('pinned %d file(s) over %d code lines -> %s'
          % (len(pins), max_lines, os.path.relpath(BASELINE, REPO_ROOT)))
    for path in sorted(pins):
        print('  %s: %d' % (path, pins[path]))
    return 0


def cmd_check(roots, max_lines, strict):
    per_file = scan_tree(roots)
    scanned = len(per_file)

    if strict:
        failures = ['%s: %d code lines, over the %d ceiling'
                    % (path, count, max_lines)
                    for path, count in sorted(per_file.items())
                    if count > max_lines]
        if failures:
            print('\n'.join(failures))
            print()
            print('x --strict asks for zero: %d file(s) carry more than %d '
                  'code lines' % (len(failures), max_lines))
            return 1
        print('ok --strict: %d Kotlin file(s), none over %d code lines'
              % (scanned, max_lines))
        return 0

    failures, notices, totals = verdict(per_file, load_baseline(), max_lines)

    if failures:
        print('\n'.join(failures))
        print()
        print('x %d file(s) over their baseline pin (%d pinned, %d unpinned)'
              % (totals['over'] + totals['unpinned'], totals['pinned'],
                 totals['unpinned']))
        print('  A file is a unit of reading. Split it — a ViewModel into its')
        print('  state and its effects, a screen into its sections, a test')
        print('  into one file per behaviour — rather than raising the')
        print('  ceiling. (CODING_STANDARDS.md §8.)')
        return 1

    if notices:
        print('\n'.join('note %s' % notice for notice in notices))
        print()
    print('ok %d Kotlin file(s): none over %d code lines beyond the baseline '
          '(%d pinned, largest %d)'
          % (scanned, max_lines, totals['pinned'], totals['largest']))
    return 0


def selftest():
    """Drive the counter and the verdict with fixtures whose answer is known.

    A counter that has quietly stopped counting is a silent outage, and the
    only way to notice is to run it against known input on every
    invocation. The same holds for the verdict: a ratchet that no longer
    fails on growth is worse than no linter.
    """
    failures = []

    def check(name, source, expected, max_lines=DEFAULT_MAX):
        actual = code_line_count(source)
        if actual == expected:
            print('  ok %s' % name)
            return
        failures.append(name)
        print('  FAIL %s: expected %d, got %d' % (name, expected, actual))

    def body(count):
        return '\n'.join(['val x = 1'] * count) + '\n'

    check('a file of exactly the ceiling counts to it', body(DEFAULT_MAX),
          DEFAULT_MAX)
    check('one line over the ceiling counts to it', body(DEFAULT_MAX + 1),
          DEFAULT_MAX + 1)
    check('an empty file has no code lines', '', 0)
    check('a blank file has no code lines', '\n\n\n', 0)
    check('whitespace-only lines are not code', '   \n\t\n', 0)
    check('a comment-only line is not code', '// one\nval x = 1\n', 1)
    check('a KDoc block is not code', '/** one\n * two\n */\nval x = 1\n', 1)
    check('a nested block comment is not code',
          '/* one /* inner */\n   two */\nval x = 1\n', 1)
    check('a trailing comment after code is code', 'val x = 1 // note\n', 1)
    check('a marker inside a string literal is code',
          'val s = "// one"\n', 1)
    check('a raw string literal is code',
          'val s = """\nline one\nline two\n"""\n', 4)
    check('a char literal is code', "val c = '/'\n", 1)
    check('a block comment opened after code counts that line as code',
          'val x = 1 /* one\n   two */\n', 1)
    check('a block comment closed before code counts that line as code',
          '/* one\n   two */ val x = 1\n', 1)
    check('an unterminated raw string does not crash the counter',
          'val s = """\nval x = 1\n', 2)
    check('an unterminated block comment swallows the rest, without crashing',
          '/* one\nval x = 1\n', 0)

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
        if (len(got_failures) == expected_failures
                and len(got_notices) == expected_notices):
            print('  ok %s' % name)
            return
        failures.append(name)
        print('  FAIL %s: %d failure(s)/%d notice(s), expected %d/%d'
              % (name, len(got_failures), len(got_notices),
                 expected_failures, expected_notices))

    pinned = {'max': DEFAULT_MAX, 'files': {'a.kt': 1057}}
    check_verdict('a file at its pin passes', {'a.kt': 1057}, pinned, 0)
    check_verdict('a file over its pin fails', {'a.kt': 1058}, pinned, 1)
    check_verdict('a file under its pin drops a notice to re-pin',
                  {'a.kt': 1040}, pinned, 0, expected_notices=1)
    check_verdict('a pinned file now under the ceiling asks to be dropped',
                  {'a.kt': 900}, pinned, 0, expected_notices=1)
    check_verdict('a new file over the ceiling fails',
                  {'a.kt': 1057, 'b.kt': 1001}, pinned, 1)
    check_verdict('a new file at the ceiling is fine',
                  {'a.kt': 1057, 'b.kt': 1000}, pinned, 0)
    check_verdict('a pinned file that vanished drops a notice',
                  {}, pinned, 0, expected_notices=1)

    try:
        verdict({}, {'max': 1200, 'files': {}}, DEFAULT_MAX)
    except UsageError:
        print('  ok a looser baseline than --max fails instead of passing')
    else:
        failures.append('ceiling mismatch')
        print('  FAIL a baseline pinned at 1200 passed a --max 1000 run')

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
        description='Fail when a Kotlin file exceeds the code-line ceiling.')
    parser.add_argument('--selftest', action='store_true',
                        help='run the counter and verdict against fixtures')
    parser.add_argument('--pin', action='store_true',
                        help="re-pin the baseline to today's counts")
    parser.add_argument('--strict', action='store_true',
                        help='ignore the baseline and require zero findings')
    parser.add_argument('--max', type=int, default=DEFAULT_MAX, metavar='N',
                        help='code lines allowed per file (default %d)'
                             % DEFAULT_MAX)
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
