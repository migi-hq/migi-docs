# -*- coding: utf-8 -*-
"""
JSX 註解檢查器 —— 補回 CLAUDE.md 硬規則 3.6 提到、但檔案一直不存在的那一支。

📌 分工（三支不重疊，不要合併）：
    jsxcomment.py    ← 本檔。① 屬性列表位置　② 註解被自己關掉
    jsxcomment2.py   運算式位置（`? (`／`: (`／`=> (`／`return (` 之後）
    tokencheck.py    寫死值

🔴 2026-09-09 建立時查證：CLAUDE.md 硬規則 3.6 寫著
   「檢查器：jsxcomment.py（屬性列表變體）＋ jsxcomment2.py（運算式位置變體）」，
   而 `jsxcomment.py` **從來不存在**。也就是那半句話從寫下的當天就是假的，
   而**沒有任何東西會告訴你**（同踩坑第 29 條：先查再說有）。

────────────────────────────────────────────────────────────
① 屬性列表位置（硬規則 3.6，2026-08-25 掛掉一次 build）
    JSX 註解只在**子元素位置**合法。放進開始標籤的屬性之間會炸，
    而錯誤訊息會指向**下一行**，看起來像那一行的屬性有問題。

② 註解被自己關掉（硬規則 3.6b，2026-09-05 發現，而它已經上線一天）
    註解裡若出現字面的「結束符號」，parser 在**那裡**就把註解關掉，
    後面幾行全部變成**畫面上的文字**。
    🔴 而 `npm run build` 只給一個警告就通過
      （`The character "}" is not valid inside a JSX element`），
      指的還是下一行 —— 所以硬規則 11 的「推之前先 build」擋不住它。
    實際後果：那幾句話被畫在 POS 的結帳畫面上。

    判準：一個 JSX 註解區塊裡，結束符號出現**兩次以上**。
    第一次就已經把註解關掉了，所以第二次的存在本身就是證據。

用法：python jsxcomment.py <檔案或資料夾> [...]
離開碼：有命中 → 1（可以直接當 push 閘門）

────────────────────────────────────────────────────────────
🎯 自我驗證（檢查器自己壞掉也不會有症狀，所以樣本要留著）

    python jsxcomment.py docs/_資產/jsxcomment_樣本/bad_attr.jsx \
                         docs/_資產/jsxcomment_樣本/bad_selfclose.jsx
    → 期望 FOUND 2、離開碼 1          🎯 正對照：該抓的有抓到

    python jsxcomment.py docs/_資產/jsxcomment_樣本/good.jsx
    → 期望 OK、離開碼 0               ⚠ 負對照：不該抓的沒誤抓

🔴 **兩個都要跑。** 只驗「壞的會被抓」的話，一支「什麼都說有問題」
  的實作也會全綠；只驗「好的不誤報」的話，**整支拿掉**也會全綠
  （硬規則 3.55）。
────────────────────────────────────────────────────────────
"""
import io
import os
import re
import sys

# 🔴 Windows 的主控台預設是 cp950，印到 emoji 或某些中文會直接拋
#   `UnicodeEncodeError` —— 2026-09-09 第一次跑就炸在這裡。
#   ⚠ 而它炸的時機是「**找到問題、正要印出來**」的那一刻 ⇒
#     檢查器在「一切正常」時完全看不出有這個病。
#   ⚠ 離開碼那時剛好也是 1（因為是例外），所以**看起來像正常擋下** ——
#     那正是最糟的一種：對的結果配上錯的原因。
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

END = '*' + '/'                      # 註解結束符號。刻意用組的，見硬規則 3.6b
OPEN_JSX = '{' + '/*'                # JSX 註解開頭
TAG_OPEN = re.compile(r'^<[A-Za-z][A-Za-z0-9._-]*')
BLOCK_LOOKAHEAD = 40                 # 一個註解區塊最多往下看幾行


def scan_attr(lines):
    """① 屬性列表位置。

    保守判準：進到一個「開始標籤還沒關」的狀態時，才認定是屬性列表。
    ⚠ 寧可漏抓也不要誤報 —— 一個會誤報的檢查器會被學會忽略，
      那比沒有檢查更糟（同硬規則 3.5 那個「永遠紅的驗證段」）。
    """
    bad = []
    in_tag = False
    for i, raw in enumerate(lines):
        ln = raw.strip()
        if not ln:
            continue

        if in_tag:
            if ln.startswith(OPEN_JSX):
                bad.append((i + 1, raw.rstrip(), '屬性列表位置'))
            if '>' in ln:
                in_tag = False
            continue

        # 開始標籤而且這一行沒關 → 接下來是屬性列表
        if TAG_OPEN.match(ln) and '>' not in ln:
            in_tag = True
    return bad


def scan_selfclose(lines):
    """② 註解被自己關掉。

    從 `{/*` 那一行往下找「視覺上的結尾」（行尾正好是結束符號加右大括號），
    然後數這個區塊裡出現幾次結束符號。**兩次以上就是第一次已經關掉了。**
    """
    bad = []
    i = 0
    n = len(lines)
    while i < n:
        ln = lines[i].strip()
        if not ln.startswith(OPEN_JSX):
            i += 1
            continue

        # 往下找區塊的視覺結尾
        end = -1
        for j in range(i, min(i + BLOCK_LOOKAHEAD, n)):
            if lines[j].rstrip().endswith(END + '}'):
                end = j
                break
        if end < 0:
            i += 1
            continue

        body = '\n'.join(lines[i:end + 1])
        if body.count(END) >= 2:
            bad.append((i + 1, lines[i].rstrip(), '註解被自己關掉'))
        i = end + 1
    return bad


def scan(path):
    try:
        src = io.open(path, encoding='utf-8').read()
    except Exception as e:
        return [(0, 'read failed: %s' % e, '讀不到')]
    lines = src.split('\n')
    return sorted(scan_attr(lines) + scan_selfclose(lines))


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
            for lineno, text, why in scan(f):
                hits += 1
                print('%s:%d  %s' % (f, lineno, why))
                print('    %s' % text)
    if hits == 0:
        print('OK: %d files, no bad JSX comments' % total)
        return 0
    print('FOUND %d' % hits)
    return 1


if __name__ == '__main__':
    sys.exit(main())
