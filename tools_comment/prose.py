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
