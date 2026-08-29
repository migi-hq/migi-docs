#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tokencheck.py —— 抓「本來有 token 卻寫死」的樣式值

    python tokencheck.py                # 掃三端
    python tokencheck.py migi-pos       # 只掃一個
    python tokencheck.py --all          # 連「沒有 token 可用」的也一起列（判斷用）

── 🔴 為什麼需要它 ────────────────────────────────────
遷移那 1800 處是**固定利息**的工作：今天改一處跟三個月後改一處，成本一樣。
但「新寫的程式碼繼續寫死」是**複利** —— 每寫一行 UI 就多一個要遷移的點。

實測（2026-08-29）：
    2026-08-15 三端統一了顏色 token
    之後 web 長出字級／圓角／間距／陰影（27 個），POS 沒跟上
    今天 POS 有 304 個寫死 fontSize、117 個寫死 borderRadius，
    而它的 var(--) 只用了 17 次

→ 沒有東西擋著的話，這件事會一直發生。**這支就是那個擋著的東西。**

⚠ 它只報「值剛好等於某個 token」的那些 —— 那些是**零風險、零判斷**的取代。
  值對不上 token 的（例如 fontSize: 17）預設不報，因為那要決定
  「該升 16 還是降 19」，不是機械工作。用 --all 才會列出來。

⚠ 同 pillcheck.py / jsxcomment.py 的傳統：**逐行印出讓人判讀，不回傳是非題**
  （CLAUDE.md 硬規則 3.5）。
"""
import io, os, re, sys

# ── token 對照表（來源：migi-assets/tokens.json）──
# ⚠ 只列「值能唯一對應」的。--sp-* 刻意不列：它是 4px 格線，
#   而最常用的 gap 是 10px（77 次）根本不在格線上 —— 那是設計問題不是寫死問題。
FONT = {11: '--xxxs', 12: '--xxs', 13: '--xs', 14: '--s', 15: '--m',
        16: '--l', 19: '--xl', 22: '--xxl', 38: '--h'}
RADIUS = {8: '--r-sm', 12: '--r-field', 14: '--r-card', 16: '--r-lg',
          99: '--r-pill', 999: '--r-pill'}
COLOR = {
    '#FAD6DC': '--brand', '#EFE3DA': '--milktea', '#DECDBC': '--milktea-bd',
    '#FAF5EF': '--milktea-light', '#7A5C42': '--milktea-ink', '#FFF6F8': '--brand-tint',
    '#FFE7EE': '--brand-light', '#2E2B2C': '--ink', '#C2607A': '--accent',
    '#E8B89B': '--gold', '#7A7572': '--gray-1', '#9A9491': '--gray-2',
    '#B4AEA9': '--hint', '#ECEAE9': '--gray-3', '#F2F0EE': '--gray-4',
    '#FFFFFF': '--white', '#F8F7F6': '--field-bg', '#ECE7E4': '--field-bd',
    '#F6F5F4': '--page-bg', '#B23B3B': '--danger',
}
BORDER = {'0.5': '--bw-hair', '.5': '--bw-hair', '1': '--bw-base',
          '1.5': '--bw-thick', '2': '--bw-heavy'}
LINEH = {'1': '--lh-none', '1.3': '--lh-tight', '1.6': '--lh-body', '1.8': '--lh-loose'}
ZINDEX = {100: '--z-sticky', 1000: '--z-sheet', 1100: '--z-sheet2',
          1200: '--z-overlay', 2000: '--z-toast', 2100: '--z-alert'}

RULES = [
    ('fontSize',     re.compile(r'fontSize:\s*(\d+)\b'),          lambda m: FONT.get(int(m))),
    ('font-size',    re.compile(r'font-size:\s*(\d+)px'),         lambda m: FONT.get(int(m))),
    ('borderRadius', re.compile(r'borderRadius:\s*(\d+)\b'),      lambda m: RADIUS.get(int(m))),
    ('border-radius',re.compile(r'border-radius:\s*(\d+)px'),     lambda m: RADIUS.get(int(m))),
    ('色碼',          re.compile(r'(#[0-9A-Fa-f]{6})\b'),          lambda m: COLOR.get(m.upper())),
    ('邊框寬度',       re.compile(r'([\d.]+)px solid'),             lambda m: BORDER.get(m)),
    ('lineHeight',   re.compile(r'lineHeight:\s*([\d.]+)'),       lambda m: LINEH.get(m)),
    ('zIndex',       re.compile(r'zIndex:\s*(\d+)\b'),            lambda m: ZINDEX.get(int(m))),
]

# 值對不上 token 的（--all 才報）
LOOSE = [
    ('fontSize',     re.compile(r'fontSize:\s*(\d+)\b'),          FONT,   int),
    ('borderRadius', re.compile(r'borderRadius:\s*(\d+)\b'),      RADIUS, int),
    ('gap',          re.compile(r'gap:\s*(\d+)\b'),               {},     int),
    ('zIndex',       re.compile(r'zIndex:\s*(\d+)\b'),            ZINDEX, int),
]

SKIP_DIR = {'node_modules', 'dist', 'assets', '.git', 'public'}
# ⚠ tokens 的定義檔本身當然全是數字與色碼，不要掃它
SKIP_FILE = {'tokens.css', 'tokens.js'}


def files(root):
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if d not in SKIP_DIR]
        for f in fn:
            if f.endswith(('.jsx', '.js', '.css')) and f not in SKIP_FILE:
                yield os.path.join(dp, f)


def scan(root, show_all=False):
    hits, loose = [], []
    for path in files(root):
        try:
            lines = io.open(path, encoding='utf-8').read().split('\n')
        except Exception:
            continue
        for i, line in enumerate(lines, 1):
            # ⚠ 整行註解跳過：註解裡寫 #FAD6DC 是在說明，不是在寫死
            if line.lstrip().startswith(('//', '*', '/*')):
                continue
            for name, pat, look in RULES:
                for m in pat.finditer(line):
                    tok = look(m.group(1))
                    if tok:
                        hits.append((path, i, name, m.group(1), tok, line.strip()[:76]))
            if show_all:
                for name, pat, table, conv in LOOSE:
                    for m in pat.finditer(line):
                        if conv(m.group(1)) not in table:
                            loose.append((path, i, name, m.group(1), line.strip()[:76]))
    return hits, loose


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    show_all = '--all' in sys.argv
    roots = args or ['migi-web/src', 'migi-pos/src', 'migi-admin/src']
    total = 0
    for root in roots:
        if not os.path.isdir(root):
            root = os.path.join(root, 'src')
        if not os.path.isdir(root):
            print('跳過（找不到）：%s' % root); continue
        hits, loose = scan(root, show_all)
        print('\n' + '=' * 70)
        print('%s　　有 token 可用卻寫死：%d 處' % (root, len(hits)))
        print('=' * 70)
        for path, ln, kind, val, tok, src in hits[:400]:
            print('  %s:%d' % (path.replace('\\', '/'), ln))
            print('      %s %s  →  var(%s)' % (kind, val, tok))
            print('      %s' % src)
        if len(hits) > 400:
            print('  …還有 %d 處（只印前 400）' % (len(hits) - 400))
        total += len(hits)
        if show_all and loose:
            print('\n  ── 沒有 token 可用（要人判斷該 snap 到哪一階）%d 處 ──' % len(loose))
            seen = {}
            for path, ln, kind, val, src in loose:
                seen.setdefault((kind, val), 0)
                seen[(kind, val)] += 1
            for (kind, val), n in sorted(seen.items(), key=lambda x: -x[1])[:25]:
                print('      %-14s %-6s ×%d' % (kind, val, n))
    print('\n' + '=' * 70)
    if total:
        print('🔴 共 %d 處可以直接換成 token（值完全相同，零視覺變化）' % total)
    else:
        print('✅ 沒有「有 token 可用卻寫死」的地方')
    print('=' * 70)
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main())
