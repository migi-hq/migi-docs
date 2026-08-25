# -*- coding: utf-8 -*-
"""
找出「{/* */} 出現在運算式位置」的 JSX 註解。

背景（2026-08-25 掛掉一次 build）：
    {/* ... */} **只在 JSX 子元素位置合法**。
    放在三元運算子的括號內（運算式位置）時，parser 會把 { 當成物件實字，
    錯誤訊息長這樣：

        Expected ")" but found "style"
        175|  <div style={{ maxWidth: 780 }}>

    —— 指的是**下一行**，看起來像 style 有問題，實際原因在前面。

判準（保守，只抓最明確的形狀）：
    某一行是 `{/*` 開頭，而它前面最近的非空白、非註解行**結尾是 `(`**
    → 那就是運算式位置（`? (`、`: (`、`=> (`、`return (`、`&& (`）。

    ⚠ 例外：`(` 之後接的若本來就是 JSX 元素（`(<div>`），那一行不會只有 `(`。
      所以只看「行尾正好是 (」已經足夠精準。

用法：python jsxcomment2.py <檔案或資料夾> [...]
"""
import io
import os
import re
import sys

OPEN_EXPR = re.compile(r'\($')


def scan(path):
    try:
        src = io.open(path, encoding='utf-8').read()
    except Exception as e:
        return [(0, 'read failed: %s' % e)]
    lines = src.split('\n')
    bad = []
    prev = None          # 前一個非空白、非純註解行
    in_block = False
    for i, raw in enumerate(lines):
        ln = raw.strip()

        # 追蹤裸的 /* */ 區塊，避免把註解內容當程式碼
        if in_block:
            if '*/' in ln:
                in_block = False
            continue

        if not ln:
            continue

        if ln.startswith('{/*'):
            if prev is not None and OPEN_EXPR.search(prev):
                bad.append((i + 1, raw.rstrip()))
            # 這一行本身是註解，不更新 prev
            if '*/' not in ln:
                in_block = True
            continue

        if ln.startswith('/*'):
            if '*/' not in ln:
                in_block = True
            continue

        if ln.startswith('//'):
            continue

        prev = ln
    return bad


def walk(target):
    if os.path.isfile(target):
        yield target
        return
    for root, dirs, files in os.walk(target):
        dirs[:] = [d for d in dirs if d not in ('node_modules', '.git', 'dist')]
        for f in files:
            if f.endswith(('.jsx', '.tsx')):
                yield os.path.join(root, f)


def main():
    targets = sys.argv[1:] or ['.']
    total = 0
    hits = 0
    for t in targets:
        for f in walk(t):
            total += 1
            for lineno, text in scan(f):
                hits += 1
                print('%s:%d  {/* *\\/} 在運算式位置 -> 改成裸的 /* *\\/' % (f, lineno))
                print('    %s' % text)
    if hits == 0:
        print('OK: %d files, no comment-in-expression-position' % total)
    else:
        print('FOUND %d' % hits)
        sys.exit(1)


main()
