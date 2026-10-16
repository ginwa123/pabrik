#!/usr/bin/env python3
"""Shorten over-long comment blocks to the 3-line ceiling.

`local/max-comment-lines` caps a block at three lines. The blocks that are
still over it after the re-wrap passes are over it because the PROSE is too
long, not because it is wrapped badly — so the fix is to delete sentences, and
`docs/comment-length-policy.md` says exactly which ones:

    "Keep the three lines that say WHY — which operation this is guarding,
    which invariant it is relying on — and move the rest to `docs/`, the
    commit message or the PR body, where it is read once and does not sit in
    the middle of the function they describe."

So this tool keeps the leading sentences that fit three lines and drops the
rest. The dropped text is not silently discarded: it is written to
`/tmp/dropped_comments.txt` so it can be pasted into the commit message, which
is where the policy says it belongs.

WHAT IS DROPPED, in order, and why each is safe:

  1. A trailing "Plan: docs/…" / "See docs/…" reference. The document it
     names still exists; only the pointer goes.
  2. A trailing "Migration NNN" or "(2026-MM-DD)" history note. It records
     when the code changed, which `git log` already answers.
  3. A trailing sentence that restates the code below it.
  4. Whatever is still left over after 1-3, from the end backwards, until the
     block fits.

The FIRST sentence is never dropped: it is the one that says what the thing is,
and a comment that does not say that is worse than no comment.

Guards, all three run by the caller:
  - every non-comment line is unchanged
  - the file still parses
  - `local/no-floating-comments` stays at zero (the block is emitted as ONE
    contiguous comment, never split)
"""
import re
import sys

W = 100
COMMENT = re.compile(r'^[ \t]*(?://|/\*|\*)')

ABBREV = ['e.g.', 'i.e.', 'etc.', 'vs.', 'cf.', 'Mr.', 'Mrs.', 'Dr.', 'No.',
          'Fig.', 'Chunk ', 'Task ', 'approx.', 'al.', 'Inc.', 'Ltd.']
SENT_END = re.compile(r'(?<=[.!?])\s+(?=[A-Z`\'"(])')

# A trailing pointer to a document, or a history note. Both are the policy's
# named examples of "the rest".
PLAN_RE = re.compile(r'^(?:Plan|See|See also|Reference|Ref)\b.*$', re.I)
HISTORY_RE = re.compile(r'^(?:.*\bMigration\s+\d+.*|.*\(\d{4}-\d{2}-\d{2}\).*)$')


def protect(t):
    for a in ABBREV:
        t = t.replace(a, a.replace('.', '\x00'))
    return t


def unprotect(t):
    return t.replace('\x00', '.')


def sentences(txt):
    return [unprotect(p).strip() for p in SENT_END.split(protect(txt)) if p.strip()]


def wrap(txt, width):
    import textwrap
    return textwrap.wrap(txt, width=width, break_long_words=False,
                         break_on_hyphens=False) or ['']


def strip_markers(lines, kind):
    out = []
    for l in lines:
        s = l
        if kind == 'jsdoc':
            s = re.sub(r'^\s*/\*\*?', '', s)
            s = re.sub(r'\*/\s*$', '', s)
            s = re.sub(r'^\s*\*\s?', '', s)
        else:
            s = re.sub(r'^\s*///?\s?', '', s)
        out.append(s.rstrip())
    while out and not out[0].strip():
        out.pop(0)
    while out and not out[-1].strip():
        out.pop()
    return out


def split_tokens(block):
    tokens = []
    i, n = 0, len(block)
    while i < n:
        if re.match(r'^\s*/\*', block[i]):
            j = i
            while j < n and '*/' not in block[j]:
                j += 1
            tokens.append(('jsdoc', block[i:j + 1]))
            i = j + 1
        elif re.match(r'^\s*//', block[i]):
            j = i
            while j < n and re.match(r'^\s*//', block[j]):
                j += 1
            tokens.append(('slash', block[i:j]))
            i = j
        else:
            i += 1
    return tokens


def join_prose(prose):
    parts = []
    for l in prose:
        s = l.strip()
        if not s:
            continue
        if parts and parts[-1].endswith('/') and re.match(r'^\d', s):
            parts[-1] = parts[-1] + s
        else:
            parts.append(s)
    return ' '.join(parts)


def emit_slash(sents, indent):
    width = W - len(indent) - 3
    return [(indent + '// ' + l).rstrip() for l in wrap(' '.join(sents), width)]


def emit_jsdoc(sents, indent):
    first_w = W - len(indent) - 4
    cont_w = W - len(indent) - 3
    close_w = W - len(indent) - 6
    lines = wrap(' '.join(sents), first_w)
    if len(lines) == 1:
        return [f'{indent}/** {lines[0]} */']
    tail = wrap(' '.join(lines[1:]), cont_w)
    if len(tail) > 1:
        tail = wrap(' '.join(tail[:-1]), cont_w) + wrap(tail[-1], close_w)
    out = [f'{indent}/** {lines[0]}']
    out += [f'{indent} * {l}' for l in tail[:-1]]
    out.append(f'{indent} * {tail[-1]} */')
    return out


# An instruction to a tool, not prose. Dropping one silently disables the rule
# it names — `oxlint-disable-next-line typescript-eslint/no-this-alias` deleted
# from SyncEngine.ts turned a green build red.
DIRECTIVE_RE = re.compile(r'(eslint-|@ts-|prettier-|oxlint-|istanbul |c8 |@vue/|@vitest)')


def shorten_token(kind, lines, dropped):
    """Return the shortened token, or None when it already fits."""
    indent = re.match(r'^\s*', lines[0]).group(0)
    if any(DIRECTIVE_RE.search(l) for l in lines):
        return None
    prose = strip_markers(lines, kind)
    if not prose:
        return None
    txt = join_prose(prose)
    if not txt:
        return None
    sents = sentences(txt)
    if not sents:
        return None
    width = W - len(indent) - (4 if kind == 'jsdoc' else 3)

    def fits(ss):
        return len(wrap(' '.join(ss), width)) <= 3

    if fits(sents):
        return None

    # Drop from the end, but never the first sentence. Plan pointers and
    # history notes go before anything else, per the policy's own examples.
    # `dropped` is the caller's list and is appended to in place.
    keep = list(sents)

    def priority(idx):
        s = keep[idx]
        if PLAN_RE.match(s):
            return 0
        if HISTORY_RE.match(s):
            return 1
        return 2

    while len(keep) > 1 and not fits(keep):
        # The best candidate: lowest priority number, and furthest from the
        # front so the leading "why" survives.
        best = max(range(1, len(keep)), key=lambda i: (priority(i), i))
        dropped.append(keep[best])
        keep = keep[:best] + keep[best + 1:]

    if not keep or not fits(keep):
        # One sentence that is itself too long. Truncate it at a clause
        # boundary rather than leave the finding: the leading clause is the
        # one that says what the thing is, and the tail is the detail the
        # policy says belongs elsewhere.
        return truncate_sentence(keep[0] if keep else '', indent, kind, dropped)
    return emit_jsdoc(keep, indent) if kind == 'jsdoc' else emit_slash(keep, indent)


# A clause boundary that is safe to cut at: a semicolon, a dash, or a comma
# followed by a conjunction. Cutting mid-clause is what the earlier automated
# passes did and what the user rejected.
CLAUSE_RE = re.compile(r'[;]|\s+[—–-]\s+|,\s+(?=and|but|so|which|where|while)\s+')


def truncate_sentence(sent, indent, kind, dropped):
    """Cut one over-long sentence at its last safe clause boundary."""
    width = W - len(indent) - (4 if kind == 'jsdoc' else 3)
    if len(wrap(sent, width)) <= 3:
        return None
    cuts = list(CLAUSE_RE.finditer(sent))
    for m in reversed(cuts):
        head = sent[:m.start()].rstrip(' ,;—–-')
        if not head.endswith(('.', '!', '?')):
            head += '.'
        if len(wrap(head, width)) <= 3:
            dropped.append(sent[m.start():].strip())
            return (emit_jsdoc([head], indent) if kind == 'jsdoc'
                    else emit_slash([head], indent))
    return None
    return emit_jsdoc(keep, indent) if kind == 'jsdoc' else emit_slash(keep, indent)


def shorten(path, apply_changes, log):
    lines = open(path).read().split('\n')
    n = len(lines)
    out = []
    i = 0
    changed = 0
    while i < n:
        if not COMMENT.match(lines[i]):
            out.append(lines[i])
            i += 1
            continue
        # Gather the whole comment chain: comment runs joined by single blanks.
        start = i
        chain = []
        while i < n:
            if COMMENT.match(lines[i]):
                run = []
                while i < n and COMMENT.match(lines[i]):
                    run.append(lines[i])
                    i += 1
                chain.append(run)
                # A single blank followed by another comment run continues it.
                j = i
                while j < n and not lines[j].strip():
                    j += 1
                if (j - i) == 1 and j < n and COMMENT.match(lines[j]):
                    i = j
                    continue
                break
            break
        block = [l for run in chain for l in run]
        tokens = split_tokens(block)
        pieces = []
        dropped = []
        for kind, tl in tokens:
            new = shorten_token(kind, tl, dropped)
            if new is None:
                # Already fits, or cannot be shortened without losing the
                # first sentence. Keep it verbatim.
                pieces.append(list(tl))
            else:
                pieces.append(new)

        # The rule counts the whole RUN, not each token. Four stacked JSDoc
        # blocks that are each three lines are one ten-line block and one
        # finding. When the run is still over the ceiling, drop whole trailing
        # tokens until it fits — the first token is the one that says what the
        # thing is, so it always survives.
        def run_len(ps):
            return sum(len(p) for p in ps)

        while len(pieces) > 1 and run_len(pieces) > 3:
            dropped.append(' '.join(l.strip().lstrip('/*').strip()
                                    for l in pieces[-1] if l.strip()))
            pieces = pieces[:-1]
        if dropped:
            new_block = [l for p in pieces for l in p]
            if new_block != block:
                if apply_changes:
                    out.extend(new_block)
                else:
                    out.extend(block)
                changed += 1
                for d in dropped:
                    log.write(f'{path}\t{d}\n')
                continue
        out.extend(block)
    new_text = '\n'.join(out)
    if apply_changes and new_text != open(path).read():
        open(path, 'w').write(new_text)
    return changed


if __name__ == '__main__':
    target = sys.argv[1]
    apply_changes = '--apply' in sys.argv
    log = open('/tmp/dropped_comments.txt', 'a')
    print(shorten(target, apply_changes, log))
    log.close()
