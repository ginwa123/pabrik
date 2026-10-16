#!/usr/bin/env python3
"""Attach floating comment blocks to the code they explain.

`local/no-floating-comments` reports a comment run followed by exactly one
blank line, where the chain of blank-separated runs ends at code. The fix is
to delete that blank line, which joins the comment to the code.

This is the mirror image of `rejoin.py`: that tool undoes a comment that was
SPLIT into pieces, this one attaches a comment that was always separate. Both
delete the same blank line, and both are safe for the same reason — a blank
line inside a comment chain carries no information.

Unlike `rejoin.py`, this tool does NOT run the reflow afterwards. A comment
that is now attached and still over the three-line ceiling is left visible as
an honest over-long block; shortening it is a separate, prose-level decision.

Guards, all three run by the caller:
  - the comment prose is character-identical
  - every non-comment line is unchanged
  - the file still parses
"""
import re
import sys

COMMENT = re.compile(r'^[ \t]*(?://|/\*|\*)')
# A line that starts a statement, a member, or a template/expression. This is
# the thing a comment attaches to.
CODE = re.compile(r'^[ \t]*(?:[A-Za-z_$@})\]]|[`\'"])')


def is_blank(line):
    return not line.strip()


def attach(path, apply_changes):
    """Delete the single blank line between a floating comment and its code."""
    lines = open(path).read().split('\n')
    n = len(lines)
    out = []
    i = 0
    removed = 0
    while i < n:
        if not COMMENT.match(lines[i]):
            out.append(lines[i])
            i += 1
            continue

        # Gather this comment run.
        run = []
        while i < n and COMMENT.match(lines[i]):
            run.append(lines[i])
            i += 1

        # Exactly one blank line, then code? That blank is the float, so drop
        # it and let the comment touch the code.
        if i < n and is_blank(lines[i]):
            j = i + 1
            if j < n and not is_blank(lines[j]) and CODE.match(lines[j]):
                removed += 1
                i = j  # skip the blank; the code line is emitted next iteration
            else:
                out.append(lines[i])
                i += 1

        out.extend(run)

    new_text = '\n'.join(out)
    if apply_changes and new_text != open(path).read():
        open(path, 'w').write(new_text)
    return removed


if __name__ == '__main__':
    target = sys.argv[1]
    apply_changes = '--apply' in sys.argv
    print(attach(target, apply_changes))
