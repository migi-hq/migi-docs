#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tokenfix.py —— 把「值剛好等於某個 token」的寫死值換成 var()

    python tokenfix.py migi-web --dry     # 先看會改什麼（預設就是 dry）
    python tokenfix.py migi-web --write    # 真的寫入

── 只做零風險的那一半 ──────────────────────────────────
它**只換值完全相同的**：`fontSize: 13` → `fontSize: 'var(--xs)'`。
🎯 所以理論上**畫面不會有任何變化** —— 那正是可以放心批次做的理由。
⚠ 但仍然要跑 build ＋ 開 dev server 逐頁看（硬規則 3.85）：
  這類改動 build 不會說話，只有畫出來才會發現。

── 🔴 刻意不碰的三類 ────────────────────────────────
1. **zIndex** —— 有 `z={1300}` 這種不在刻度上的值，而層級是「這個東西該在第幾層」
   的**判斷**，不是查表。整套層級要單獨一輪人工。
2. **gap / padding** —— `--sp-*` 是 4px 格線，而最常用的 gap 是 10px（77 次）
   根本不在格線上。那是「格線該不該是 4px」的設計問題。
3. **token 的定義檔本身** —— `shared.jsx` 的 `C` 物件、`styles.css` 的 `:root`。
   🔴 把定義換成 `var()` 會變成自我參照，整個色彩系統會空掉。

── ⚠ 執行順序很重要 ────────────────────────────────
POS 與 admin 要**先接上 @migi/assets**（拿得到 `--xxs`／`--bw-*`／`--lh-*`），
再跑這支。順序反了的話 `var(--xxs)` 解析不出來，
CSS 會**直接忽略那個屬性** —— 字級會退回瀏覽器預設而不是報錯。
"""
import io, os, re, sys

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
    '#F8F7F6': '--field-bg', '#ECE7E4': '--field-bd',
    '#F6F5F4': '--page-bg', '#B23B3B': '--danger',
    # ⚠ #FFFFFF 刻意不換：它太常出現在漸層、rgba 附近與 SVG 的 fill 裡，
    #   而 SVG 屬性用 var() 在部分瀏覽器不吃。白色的收益也最低。
}
BORDER = {'0.5': '--bw-hair', '.5': '--bw-hair', '1': '--bw-base',
          '1.5': '--bw-thick', '2': '--bw-heavy'}
LINEH = {'1': '--lh-none', '1.3': '--lh-tight', '1.6': '--lh-body', '1.8': '--lh-loose'}

SKIP_DIR = {'node_modules', 'dist', 'assets', '.git', 'public'}
# 🔴 token 的定義檔：換了會變成自我參照
SKIP_FILE = {'tokens.css', 'tokens.js', 'styles.css', 'index.css', 'shared.jsx'}


def fix(text):
    n = [0]

    def num(table, quote):
        def f(m):
            tok = table.get(int(m.group(2)))
            if not tok:
                return m.group(0)
            n[0] += 1
            return "%s%svar(%s)%s" % (m.group(1), quote, tok, quote)
        return f

    # JS inline style：fontSize: 13  →  fontSize: 'var(--xs)'
    text = re.sub(r'(fontSize:\s*)(\d+)\b', num(FONT, "'"), text)
    text = re.sub(r'(borderRadius:\s*)(\d+)\b', num(RADIUS, "'"), text)
    # CSS：font-size: 13px  →  font-size: var(--xs)
    text = re.sub(r'(font-size:\s*)(\d+)px', num(FONT, ''), text)
    text = re.sub(r'(border-radius:\s*)(\d+)px', num(RADIUS, ''), text)

    def lh(m):
        tok = LINEH.get(m.group(2))
        if not tok:
            return m.group(0)
        n[0] += 1
        return "%s'var(%s)'" % (m.group(1), tok)
    text = re.sub(r'(lineHeight:\s*)([\d.]+)', lh, text)

    def bd(m):
        tok = BORDER.get(m.group(1))
        if not tok:
            return m.group(0)
        n[0] += 1
        return 'var(%s) solid' % tok
    text = re.sub(r'([\d.]+)px solid', bd, text)

    def col(m):
        tok = COLOR.get(m.group(0).upper())
        if not tok:
            return m.group(0)
        n[0] += 1
        return 'var(%s)' % tok
    text = re.sub(r'#[0-9A-Fa-f]{6}\b', col, text)

    return text, n[0]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    write = '--write' in sys.argv
    root = (args[0] if args else 'migi-web')
    if not root.endswith('src'):
        root = os.path.join(root, 'src')
    total = files_changed = 0
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if d not in SKIP_DIR]
        for f in fn:
            if not f.endswith(('.jsx', '.js', '.css')) or f in SKIP_FILE:
                continue
            p = os.path.join(dp, f)
            try:
                s = io.open(p, encoding='utf-8').read()
            except Exception:
                continue
            out, n = fix(s)
            if n:
                total += n
                files_changed += 1
                print('  %-52s %4d 處' % (p.replace('\\', '/'), n))
                if write:
                    io.open(p, 'w', encoding='utf-8', newline='\n').write(out)
    print('\n%s：%d 個檔、%d 處' % ('已寫入' if write else '預覽（沒有寫入，加 --write 才會改）',
                                   files_changed, total))
    if not write:
        print('⚠ 寫入後務必：npm run build ＋ 開 dev server 逐頁看（硬規則 3.85）')


if __name__ == '__main__':
    main()
