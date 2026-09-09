# -*- coding: utf-8 -*-
"""
鍵盤到不了的可點元素 —— 數「`onClick` 掛在不能用鍵盤操作的東西上」。

🔴 為什麼這是 POS 的**速度**問題，不只是無障礙（2026-09-09）：
   CLAUDE.md 待辦 10 自己寫著「POS 主力是滑鼠鍵盤，**鍵盤操作才是
   這台機器的效率來源**」。而一個 `<div onClick>`：
     · Tab 鍵到不了
     · Enter／空白鍵按不了
     · 讀螢幕軟體讀不出它可以點
   ⇒ 店員只能用滑鼠一個一個點過去。

📌 這支**不當閘門，當棘輪**（見 `precheck.py` 第 ⑧ 項）：
   今天三個 repo 加起來兩百多處，直接擋會讓每一次 push 都失敗，
   而一個永遠紅的檢查會讓人學會忽略紅色（硬規則 3.5 那個症狀）。

────────────────────────────────────────────────────────────
判準：找到每一個 `onClick`，往回找它掛在哪一個標籤上，然後分三類

  ✅ 本來就能用鍵盤   button / a / input / select / textarea / summary
  ✅ 自己補過         同一個標籤上有 tabIndex
  🔴 到不了           其餘的小寫 HTML 標籤（div / span / li / img …）
  ⚪ 無法判斷         大寫開頭的自訂元件（要看它內部渲染成什麼）

⚠ 大寫元件**不計入棘輪的數字**，只另外印出來。
  把「不知道」算成「有問題」會讓數字失去意義 —— 改好了也不會下降，
  而一個降不下來的棘輪就是一個永遠紅的檢查。

用法：python keycheck.py <資料夾> [--list]
離開碼：一律 0（它是量測不是判決；擋不擋由 precheck 決定）
"""
import io
import os
import re
import sys

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

FOCUSABLE = {'button', 'a', 'input', 'select', 'textarea', 'summary'}
TAG_START = re.compile(r'<([A-Za-z][A-Za-z0-9._-]*)')
ONCLICK = re.compile(r'\bonClick\s*=')


def owner_tag(src, at):
    """往回找這個 onClick 掛在哪一個標籤上。

    ⚠ JSX 裡 `onClick` 一定屬於**它前面最近的那個還沒關的開始標籤** ——
      標籤若已經關掉，那個位置就是文字節點，不可能有屬性。
    """
    best = None
    for m in TAG_START.finditer(src, 0, at):
        best = m
    return best


def tag_text(src, start):
    """從 `<` 取到**這個標籤自己的** `>`。

    🔴 2026-09-09 第一版寫成「往後看 400 個字元」，結果**吃到後面別的標籤**：
      同一個檔案裡只要下面某處有一個 `tabIndex`，上面所有 `<div onClick>`
      都會被判成「補過了」⇒ 造樣本測試時**棘輪完全沒反應**。
      ⚠ 而在真的 repo 上它看起來很正常（那些檔案本來就幾乎沒有 tabIndex）
        —— 也就是這個 bug **只有靠正對照才抓得到**（硬規則 3.55）。

    ⚠ 要數大括號深度：`onClick={() => x}` 裡的 `>` 是箭頭函式的一部分，
      不是標籤結尾。只認**深度 0** 的那個 `>`。
    """
    depth = 0
    for i in range(start, len(src)):
        c = src[i]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
        elif c == '>' and depth <= 0:
            return src[start:i + 1]
    return src[start:start + 400]


def scan(path):
    try:
        src = io.open(path, encoding='utf-8').read()
    except Exception:
        return []
    out = []
    for m in ONCLICK.finditer(src):
        t = owner_tag(src, m.start())
        if not t:
            continue
        name = t.group(1)
        window = tag_text(src, t.start())
        line = src.count('\n', 0, m.start()) + 1
        if name[0].isupper():
            kind = 'component'
        elif name in FOCUSABLE:
            kind = 'ok'
        elif 'tabIndex' in window:
            kind = 'ok'
        elif 'data-nokbd' in window:
            # 刻意不進 Tab 順序，而且**必須寫理由**（例：彈窗遮罩用 Esc 關閉）。
            # 🎯 讓例外寫在程式碼裡，不要安靜地留在一個數字裡。
            kind = 'ok'
        else:
            kind = 'bad'
        out.append((kind, line, name))
    return out


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
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    show = '--list' in sys.argv
    target = args[0] if args else '.'

    bad = ok = comp = pressed = 0
    per_file = {}
    for f in walk(target):
        # 🔴 `{...pressable(fn)}` 展開之後標籤裡**沒有 `onClick=` 這幾個字**，
        #   所以那些元素**整個從掃描中消失**，不是被判成 ok。
        #   ⇒ 數字會降（棘輪要的就是這個），但「補救了幾處」看不見。
        #   ⚠ 而看不見的東西沒有人會去驗證它有沒有做對 —— 所以另外數一次印出來。
        #   📌 這也是 spread 型 helper 的代價：日後若有人寫出**只展開 onClick、
        #     不給 tabIndex** 的第二個 helper，這支檢查器看不到它。
        #     ⇒ **POS 只認可 `pressable` 這一個**，要加第二個先改這裡。
        try:
            pressed += io.open(f, encoding='utf-8').read().count('...pressable(')
        except Exception:
            pass
        for kind, line, name in scan(f):
            if kind == 'bad':
                bad += 1
                per_file.setdefault(f, []).append((line, name))
            elif kind == 'ok':
                ok += 1
            else:
                comp += 1

    if show and per_file:
        for f in sorted(per_file):
            rel = os.path.relpath(f, target)
            print('  %s' % rel)
            for line, name in per_file[f][:40]:
                print('      :%-5d <%s onClick>' % (line, name))
    elif per_file:
        print('  最多的幾支：')
        top = sorted(per_file.items(), key=lambda x: -len(x[1]))[:5]
        for f, hits in top:
            print('      %-46s %d 處' % (os.path.relpath(f, target), len(hits)))

    print('  鍵盤到不了：%d 處' % bad)
    print('  （本來就能用鍵盤 %d 處　大寫元件無法判斷 %d 處　'
          '已用 pressable 補救 %d 處）' % (ok, comp, pressed))
    return 0


if __name__ == '__main__':
    sys.exit(main())
