"""Comment-prose extraction, shared by the batch runner.

`comment_tokens(path)` returns every comment's prose in file order as
whitespace-separated tokens. Comment markers are stripped and string /
template literals are skipped, so a `//` inside a string is not mistaken for
a comment. `/` and `*` are dropped as standalone tokens because they are
JSDoc delimiters rather than prose.

`prose(path)` joins those tokens with no separator, which turns "is the
prose unchanged?" into a string equality test: a re-flow that adds, drops or
reorders a single word changes the result.
"""
import re

QUOTES = ('"', "'", '`')


def comment_tokens(path):
    src = open(path).read()
    chunks = []
    i, n = 0, len(src)
    while i < n:
        if src.startswith('//', i):
            j = src.find('\n', i)
            if j < 0:
                j = n
            chunks.append(src[i + 2:j])
            i = j
        elif src.startswith('/*', i):
            j = src.find('*/', i + 2)
            if j < 0:
                j = n
            else:
                j += 2
            chunks.append(src[i + 2:j])
            i = j
        elif src.startswith('<!--', i):
            # An HTML comment in a `<template>`. `local/max-comment-lines` and
            # `local/no-floating-comments` both document this surface as out of
            # scope, so it is skipped here too rather than counted as prose.
            j = src.find('-->', i + 4)
            i = n if j < 0 else j + 3
        elif src[i] in QUOTES:
            q = src[i]
            i += 1
            while i < n and src[i] != q:
                if src[i] == '\\':
                    i += 1
                i += 1
            i += 1
        else:
            i += 1
    text = '\n'.join(chunks)
    text = re.sub(r'^\s*\*\s?', '', text, flags=re.M)
    text = text.replace('*/', ' ')
    return [t for t in re.findall(r'\S+', text) if t not in ('/', '*')]


def prose(path):
    return ''.join(comment_tokens(path))


def code(path):
    """Every non-comment, non-blank line of the file, in order.

    The third guard: a comment re-flow must not change a single line of
    executable code. The prose check cannot see a deleted `const x = ref()`
    (it is not a comment) and the parse check cannot either when the file
    still parses without it — which is exactly what happened to
    DesignView.vue, where `const isPreviewMode = ref<boolean>(false)` was
    eaten and every later use of it became a type error.

    A line counts as code when it holds a byte that is not inside a comment
    and not inside a string or template literal. A line that is entirely a
    comment is dropped, so re-wrapping a comment never trips the guard.
    """
    src = open(path).read()
    out = []
    i, n = 0, len(src)
    line_start = 0
    line_has_code = False

    def close_line(end):
        nonlocal line_start, line_has_code
        if line_has_code:
            out.append(src[line_start:end])
        line_start = end + 1
        line_has_code = False

    while i < n:
        if src.startswith('//', i):
            j = src.find('\n', i)
            if j < 0:
                j = n
            i = j
        elif src.startswith('/*', i):
            j = src.find('*/', i + 2)
            if j < 0:
                j = n
            else:
                j += 2
            i = j
        elif src.startswith('<!--', i):
            # An HTML comment in a `<template>`: out of scope for both comment
            # rules, so it is neither prose nor code here.
            j = src.find('-->', i + 4)
            i = n if j < 0 else j + 3
        elif src[i] in QUOTES:
            q = src[i]
            line_has_code = True
            i += 1
            while i < n and src[i] != q:
                if src[i] == '\\':
                    i += 1
                i += 1
            i += 1
        elif src[i] == '`':
            line_has_code = True
            i += 1
            while i < n and src[i] != '`':
                if src[i] == '\\':
                    i += 1
                i += 1
            i += 1
        elif src[i] == '\n':
            close_line(i)
            i += 1
        else:
            if not src[i].isspace():
                line_has_code = True
            i += 1
    if line_start < n:
        close_line(n - 1 if src.endswith('\n') else n)
    return out
