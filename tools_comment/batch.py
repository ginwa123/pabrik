#!/usr/bin/env python3
"""Apply `reflow.py` to many files, verifying prose preservation per file.

Usage: batch.py <top-n-from-/tmp/mcl_files.txt> [--apply]

For each file: snapshot the original, run the reflow, then prove the comment
prose is character-identical. A file that fails the check is REVERTED and
reported, so a bad conversion can never reach the working tree.
"""
import json, os, re, shutil, subprocess, sys, tempfile

WT = '/home/ginwa/.config/pabrik/.worktrees/paydown-2548-comment-lines-1792080502826/'
HERE = os.path.dirname(os.path.abspath(__file__))


def comment_tokens(path):
    src = open(path).read()
    chunks = []
    i, n = 0, len(src)
    while i < n:
        if src.startswith('//', i):
            j = src.find('\n', i)
            if j < 0: j = n
            chunks.append(src[i + 2:j]); i = j
        elif src.startswith('/*', i):
            j = src.find('*/', i + 2)
            if j < 0: j = n
            else: j += 2
            chunks.append(src[i + 2:j]); i = j
        elif src[i] in '"\'':
            q = src[i]; i += 1
            while i < n and src[i] != q:
                if src[i] == '\\': i += 1
                i += 1
            i += 1
        elif src[i] == '`':
            i += 1
            while i < n and src[i] != '`':
                if src[i] == '\\': i += 1
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


def main():
    n = int(sys.argv[1])
    apply_changes = '--apply' in sys.argv
    rows = [l.split('\t') for l in open('/tmp/mcl_files.txt').read().splitlines() if l.strip()]
    targets = [r[1].strip() for r in rows[:n]]
    ok = fail = 0
    for rel in targets:
        path = WT + rel
        if not os.path.exists(path):
            print(f'MISSING {rel}')
            continue
        before = prose(path)
        r = subprocess.run([sys.executable, os.path.join(HERE, 'reflow.py'), rel]
                           + (['--apply'] if apply_changes else []),
                           capture_output=True, text=True, cwd=WT)
        line = r.stdout.strip().splitlines()[0] if r.stdout.strip() else r.stderr.strip()[:200]
        after = prose(path)
        if before != after:
            # revert
            subprocess.run(['git', 'checkout', '--', rel], cwd=WT)
            print(f'REVERTED (prose changed) {rel} :: {line}')
            fail += 1
            continue
        print(f'OK {rel} :: {line}')
        ok += 1
    print(f'\n{ok} files preserved, {fail} reverted')


if __name__ == '__main__':
    main()
