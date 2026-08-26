# -*- coding: utf-8 -*-
"""
統一 Pill 之後的靜態檢查（這個專案沒有本機 node，這是唯一的事前防線）

三件事：
  ① 括號平衡（字串／樣板字串／註解都跳過）
  ② 用了 <Pill 就必須 import Pill —— 漏 import 在 build 時才會爆
  ③ 殘留的舊寫法：還在寫死 borderRadius:'var(--r-pill)' 的「資訊型徽章」
     ⚠ 只印出來讓人判讀，不回傳是非題（硬規則 3.5）
"""
import io, os, re, sys

ROOT = r"C:\Users\user\Desktop\migi github\migi-web\src"

def strip_code(s):
    """把字串、樣板、註解換成空白，保留長度與換行。"""
    out = list(s); i = 0; n = len(s)
    while i < n:
        c = s[i]
        if c in "'\"`":
            q = c; j = i + 1
            while j < n:
                if s[j] == '\\': j += 2; continue
                if s[j] == q: break
                j += 1
            for k in range(i, min(j + 1, n)):
                if s[k] != '\n': out[k] = ' '
            i = j + 1; continue
        # ⚠ 正規表示式裡的 \/ 後面接 / 會長得跟行註解一模一樣
        #   （2026-08-26 誤報：rewards.jsx:897 的 /^image\//）
        if c == '/' and i > 0 and s[i-1] == '\\':
            i += 1; continue
        if c == '/' and i + 1 < n and s[i+1] == '/':
            j = s.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j): out[k] = ' '
            i = j; continue
        if c == '/' and i + 1 < n and s[i+1] == '*':
            j = s.find('*/', i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if s[k] != '\n': out[k] = ' '
            i = j; continue
        i += 1
    return ''.join(out)

PAIR = {')': '(', ']': '[', '}': '{'}

def balance(path):
    src = io.open(path, encoding='utf-8').read()
    code = strip_code(src)
    st = []
    for idx, ch in enumerate(code):
        if ch in '([{':
            st.append((ch, idx))
        elif ch in ')]}':
            if not st:
                return "第 %d 行：多出一個 %s" % (code[:idx].count('\n') + 1, ch)
            op, oi = st.pop()
            if op != PAIR[ch]:
                return "第 %d 行：%s 對到 %s（開在第 %d 行）" % (
                    code[:idx].count('\n') + 1, ch, op, code[:oi].count('\n') + 1)
    if st:
        op, oi = st[-1]
        return "檔尾仍有未閉合的 %s（開在第 %d 行）" % (op, code[:oi].count('\n') + 1)
    return None

bad = 0
files = []
for dp, _, fns in os.walk(ROOT):
    for fn in fns:
        if fn.endswith(('.jsx', '.js')):
            files.append(os.path.join(dp, fn))

print("=== \u2460 \u62ec\u865f\u5e73\u8861 ===")
for p in files:
    r = balance(p)
    if r:
        bad += 1
        print("  \U0001F534 %s\n     %s" % (os.path.relpath(p, ROOT), r))
print("  %d \u500b\u6a94\u6848\uff0c%d \u500b\u6709\u554f\u984c" % (len(files), bad))

print("\n=== \u2461 \u7528\u4e86 <Pill \u4f46\u6c92 import ===")
miss = 0
for p in files:
    src = io.open(p, encoding='utf-8').read()
    uses = re.search(r'<Pill[\s/>]', src)
    if not uses:
        continue
    if os.path.basename(p) == 'ui.jsx':
        continue
    imported = re.search(r'import\s*\{[^}]*\bPill\b[^}]*\}\s*from', src)
    tag = "\u2705" if imported else "\U0001F534 \u6c92 import"
    if not imported: miss += 1
    print("  %s %s  (%d \u8655)" % (tag, os.path.relpath(p, ROOT),
                                    len(re.findall(r'<Pill[\s/>]', src))))
print("  \u6f0f import\uff1a%d" % miss)

print("\n=== \u2462 tone=\"plain\" \u662f\u4e0d\u662f\u7ad9\u5728\u7070\u5e95\u4e0a\uff08\u6703\u5b8c\u5168\u6d88\u5931\uff09===")
# plain \u5c31\u662f --field-bg\u3002\u653e\u9032\u4e00\u500b --field-bg \u7684\u5217 \u2192 \u770b\u4e0d\u898b\u4e14\u4e0d\u5831\u932f\u3002
# \u2b06 \u5f80\u4e0a\u627e\u6700\u8fd1\u7684\u5bb9\u5668\u80cc\u666f\uff0c\u5217\u51fa\u4f86\u8b93\u4eba\u5224\u8b80\uff08\u786c\u898f\u5247 3.5\uff1a\u4e0d\u56de\u50b3\u662f\u975e\u984c\uff09\u3002
LOOKBACK = 40
for p in files:
    lines = io.open(p, encoding='utf-8').read().split('\n')
    for i, line in enumerate(lines):
        if 'tone="plain"' not in line:
            continue
        bg = None
        for j in range(i, max(-1, i - LOOKBACK), -1):
            m = re.search(r"background:\s*'(var\(--[\w-]+\)|#[0-9A-Fa-f]{3,8})'", lines[j])
            if m and '<div' in lines[j]:
                bg = (m.group(1), j + 1); break
        rel = os.path.relpath(p, ROOT)
        if bg is None:
            print("  \u2753 %s:%d  \u5f80\u4e0a %d \u884c\u627e\u4e0d\u5230\u5bb9\u5668\u80cc\u666f\uff0c\u8981\u81ea\u5df1\u770b" % (rel, i + 1, LOOKBACK))
        elif bg[0] == 'var(--field-bg)':
            print("  \U0001F534 %s:%d  \u5bb9\u5668\u5728\u7b2c %d \u884c\u662f %s \u2014\u2014 \u8ddf plain \u540c\u8272\uff0c\u81a0\u56ca\u6703\u6d88\u5931" % (rel, i + 1, bg[1], bg[0]))
        else:
            print("  \u2705 %s:%d  \u5bb9\u5668 %s\uff08\u7b2c %d \u884c\uff09" % (rel, i + 1, bg[0], bg[1]))

print("\n=== \u2463 \u6b98\u7559\u7684\u5f92\u624b\u5fbd\u7ae0\uff08\u9010\u884c\u5217\u51fa\u4f9b\u5224\u8b80\uff09===")
BADGE = re.compile(r"borderRadius:\s*'var\(--r-pill\)'")
for p in files:
    for i, line in enumerate(io.open(p, encoding='utf-8'), 1):
        if not BADGE.search(line):
            continue
        # 只挑「像徽章」的：有 background 又有 fontSize，且不是按鈕/進度條
        if 'fontSize' not in line or 'background' not in line:
            continue
        if 'onClick' in line or 'cursor' in line or '<button' in line:
            continue
        txt = line.strip()
        print("  %s:%d  %s" % (os.path.relpath(p, ROOT), i,
                               txt[:150] + ('\u2026' if len(txt) > 150 else '')))
