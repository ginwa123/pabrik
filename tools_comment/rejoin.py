#!/usr/bin/env python3
"""Rejoin comment blocks that were split apart to dodge the 3-line ceiling.

`local/no-floating-comments` reports a comment run followed by exactly one
blank line, where the chain of blank-separated runs ends at code. The fix is
to delete the blank lines inside the chain, which turns N floating blocks
back into ONE block — and that one block is then subject to
`local/max-comment-lines` again, which is the honest outcome: the prose was
always over the ceiling, and the split only hid it.

So this tool does the rejoin and reports how many blank lines it removed. The
rejoined blocks that are STILL over the ceiling are the ones that need real
editing, and `reflow.py` handles those next.

Guards, all three run by `batch.py` after this tool:
  - the comment prose is character-identical (only blank lines are removed)
  - every non-comment line is unchanged
  - the file still parses
"""
import re
import sys

COMMENT = re.compile(r'^[ \t]*(?://|/\*|\*)')


def is_blank(line):
    return not line.strip()


def rejoin(path, apply_changes):
    """Delete the single blank lines inside each floating chain."""
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

        # Look ahead: exactly one blank, then another comment run? If so the
        # chain continues and that blank is a split, so drop it.
        while i < n and is_blank(lines[i]):
            j = i
            while j < n and is_blank(lines[j]):
                j += 1
            if (j - i) == 1 and j < n and COMMENT.match(lines[j]):
                removed += 1
                i = j
                while i < n and COMMENT.match(lines[i]):
                    run.append(lines[i])
                    i += 1
                continue
            break

        out.extend(run)
        # Whatever stopped the chain is emitted verbatim by the next iteration,
        # so a section break of two or more blanks survives untouched.
        while i < n and is_blank(lines[i]):
            out.append(lines[i])
            i += 1

    new_text = '\n'.join(out)
    if apply_changes and new_text != open(path).read():
        open(path, 'w').write(new_text)
    return removed


if __name__ == '__main__':
    target = sys.argv[1]
    apply_changes = '--apply' in sys.argv
    print(rejoin(target, apply_changes))
