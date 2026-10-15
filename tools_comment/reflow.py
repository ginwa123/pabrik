#!/usr/bin/env python3
"""Word-preserving re-flow of over-long comment blocks to the 3-line ceiling.

A "block" is what `local/max-comment-lines` reports: a run of consecutive
comment LINES. One block may hold several comment TOKENS (a `/** ... */`
immediately followed by another, with no blank line between). Those token
boundaries are semantic, so the block is split into tokens first and each
token is reflowed on its own; the tokens are re-emitted separated by a blank
line, which ends a block per the rule.

Per token:
  1. Strip the markers, keep the prose lines verbatim.
  2. Join hard-wrapped lines. A line ending in `/ - _` joins the next with NO
     space, so a path broken across lines (`plans/` + `2026-08-06-x.md`) is
     reassembled instead of gaining a spurious space.
  3. Split into sentences at `. ` / `! ` / `? ` before a capital, backtick or
     quote, with abbreviations protected first.
  4. Greedily group consecutive sentences into chunks that fit three lines at
     the repo's 100-col print width (prefix included).
  5. Emit each chunk as its own comment, separated by a blank line.

No word is added, dropped or reordered. A token is SKIPPED untouched when it
holds anything a re-flow could mangle: a list marker, a column-aligned table,
a section rule, a directive, a JSDoc tag, a fence, an arrow annotation, or a
sentence that cannot fit three lines on its own.
"""
import json, re, sys, textwrap
from collections import Counter

W = 100

ABBREV = ['e.g.', 'i.e.', 'etc.', 'vs.', 'cf.', 'Mr.', 'Mrs.', 'Dr.', 'No.',
          'Fig.', 'Chunk ', 'Task ', 'approx.', 'al.', 'Inc.', 'Ltd.']
SENT_END = re.compile(r'(?<=[.!?])\s+(?=[A-Z`\'"(])')
LIST_RE = re.compile(r'^\s*(?:[-*+•]\s|\d+[.)]\s|\(?\d+\)\s)')
RULE_RE = re.compile(r'^\s*(?://\s*[-=—_*]{3,}|/\*\s*[-=—_*]{3,}|\*\s*[-=—_*]{3,})')
DIRECTIVE_RE = re.compile(r'(eslint-|@ts-|prettier-|istanbul |c8 |vime:|oxlint-|@vue/|@vitest)')
JSDOC_TAG_RE = re.compile(r'^\s*\*\s*@\w+|^\s*@\w+')
FENCE_RE = re.compile(r'^\s*(?:```|~~~)')
ALIGNED_RE = re.compile(r'\S {3,}\S')
ARROW_RE = re.compile(r'^\s*(?:→|←|↳|=>|->)')
NO_SPACE_JOIN = ('/', '-', '_')


def protect(t):
    for a in ABBREV:
        t = t.replace(a, a.replace('.', '\x00'))
    return t


def unprotect(t):
    return t.replace('\x00', '.')


def sentences(txt):
    return [unprotect(p).strip() for p in SENT_END.split(protect(txt)) if p.strip()]


def wrap(txt, width):
    return textwrap.wrap(txt, width=width, break_long_words=False,
                         break_on_hyphens=False) or ['']


def split_tokens(block):
    """Split a block's lines into (kind, lines) tokens.

    kind is 'jsdoc' for a `/** ... */` (or `/* ... */`) run and 'slash' for a
    run of `//` / `///` lines.
    """
    tokens = []
    i = 0
    n = len(block)
    while i < n:
        line = block[i]
        if re.match(r'^\s*/\*', line):
            j = i
            while j < n and '*/' not in block[j]:
                j += 1
            tokens.append(('jsdoc', block[i:j + 1]))
            i = j + 1
        elif re.match(r'^\s*//', line):
            j = i
            while j < n and re.match(r'^\s*//', block[j]):
                j += 1
            tokens.append(('slash', block[i:j]))
            i = j
        else:
            i += 1
    return tokens


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


# A continuation line that starts with one of these is the tail of a token the
# previous line broke: a date (`2026-08-06-x.md`), a version, a hex id, a
# snake_case word. Anything else after a `/` is prose (`Null on 404 /` +
# `network failure`) and must keep its space.
CONTINUATION_RE = re.compile(r'^(?:\d|[a-z][a-z0-9]*(?:_[a-z0-9]+)+|[a-z]+\.[a-z]{2,4}\b)')


def join_prose(prose):
    """Reassemble hard-wrapped lines into one string.

    A line ending in `/`, `-` or `_` joins the next with NO space only when the
    next line looks like the tail of the same token, so a path broken across
    lines (`plans/` + `2026-08-06-x.md`) is reassembled while `Null on 404 /` +
    `network failure` keeps the space the author wrote.
    """
    parts = []
    for l in prose:
        s = l.strip()
        if not s:
            continue
        if parts and parts[-1].endswith(NO_SPACE_JOIN) and CONTINUATION_RE.match(s):
            parts[-1] = parts[-1] + s
        else:
            parts.append(s)
    return ' '.join(parts)


def guard_hit(prose):
    for l in prose:
        if LIST_RE.match(l):
            return 'list'
        if RULE_RE.match(l):
            return 'rule'
        if DIRECTIVE_RE.search(l):
            return 'directive'
        if JSDOC_TAG_RE.match(l):
            return 'jsdoc-tag'
        if FENCE_RE.match(l):
            return 'fence'
        if ALIGNED_RE.search(l):
            return 'aligned'
        if ARROW_RE.match(l):
            return 'arrow'
    return None


def group_sentences(sents, width):
    groups, cur = [], []
    for s in sents:
        trial = cur + [s]
        if len(wrap(' '.join(trial), width)) <= 3 or not cur:
            cur = trial
        else:
            groups.append(cur)
            cur = [s]
    if cur:
        groups.append(cur)
    return groups


def emit_slash(groups, indent):
    width = W - len(indent) - 3
    out = []
    for gi, g in enumerate(groups):
        if gi:
            out.append('')
        for l in wrap(' '.join(g), width):
            out.append((indent + '// ' + l).rstrip())
    return out


def emit_jsdoc(groups, indent):
    # `/** ` is 4 cols, ` * ` is 3, and the closing line also carries ` */`.
    first_w = W - len(indent) - 4
    cont_w = W - len(indent) - 3
    close_w = W - len(indent) - 6
    out = []
    for gi, g in enumerate(groups):
        if gi:
            out.append('')
        lines = wrap(' '.join(g), first_w)
        if len(lines) == 1:
            out.append(f'{indent}/** {lines[0]} */')
            continue
        # Re-wrap the tail at the continuation width, then pull the final
        # line back to the closing width so ` */` cannot push past 100 cols.
        tail = wrap(' '.join(lines[1:]), cont_w)
        if len(tail) > 1:
            head = wrap(' '.join(tail[:-1]), cont_w)
            last = wrap(tail[-1], close_w)
            tail = head + last
        out.append(f'{indent}/** {lines[0]}')
        for l in tail[:-1]:
            out.append(f'{indent} * {l}')
        out.append(f'{indent} * {tail[-1]} */')
    return out


def reflow_token(kind, lines):
    indent = re.match(r'^\s*', lines[0]).group(0)
    prose = strip_markers(lines, kind)
    if not prose:
        return None, 'empty'
    g = guard_hit(prose)
    if g:
        return None, g
    txt = join_prose(prose)
    if not txt:
        return None, 'empty'
    sents = sentences(txt)
    if not sents:
        return None, 'no-sentences'
    width = W - len(indent) - (4 if kind == 'jsdoc' else 3)
    if any(len(wrap(s, width)) > 3 for s in sents):
        return None, 'sentence-too-long'
    groups = group_sentences(sents, width)
    if any(len(wrap(' '.join(gg), width)) > 3 for gg in groups):
        return None, 'group-overflow'
    new = emit_jsdoc(groups, indent) if kind == 'jsdoc' else emit_slash(groups, indent)
    if new == lines:
        return None, 'no-change'
    return new, None


def process(path, ranges, apply_changes):
    lines = open(path).read().split('\n')
    edits, skipped = [], []
    for (start, end) in ranges:
        block = lines[start - 1:end]
        tokens = split_tokens(block)
        if not tokens:
            skipped.append((start, 'no-tokens'))
            continue
        pieces, bad = [], None
        for kind, tlines in tokens:
            new, why = reflow_token(kind, tlines)
            if new is None:
                bad = why
                break
            pieces.append(new)
        if bad:
            skipped.append((start, bad))
            continue
        new_block = []
        for pi, p in enumerate(pieces):
            if pi:
                new_block.append('')
            new_block.extend(p)
        if new_block == block:
            skipped.append((start, 'no-change'))
            continue
        edits.append((start, end, new_block))
    if apply_changes and edits:
        for start, end, new in sorted(edits, key=lambda e: -e[0]):
            lines[start - 1:end] = new
        open(path, 'w').write('\n'.join(lines))
    return edits, skipped


def main():
    base = json.load(open('/tmp/eslint_base.json'))
    target = sys.argv[1]
    do_apply = len(sys.argv) > 2 and sys.argv[2] == '--apply'
    for f in base:
        if not f['filePath'].endswith(target):
            continue
        msgs = [m for m in f['messages'] if m.get('ruleId') == 'local/max-comment-lines']
        ranges = sorted(
            (m['line'], m['line'] - 1 + int(m['message'].split('spans ')[1].split(' ')[0]))
            for m in msgs)
        edits, skipped = process(f['filePath'], ranges, do_apply)
        print(f'{target}: {len(ranges)} blocks -> {len(edits)} converted, {len(skipped)} skipped')
        for k, v in Counter(s[1] for s in skipped).most_common():
            print(f'   skip {k}: {v}')


if __name__ == '__main__':
    main()
