# -*- coding: utf-8 -*-
"""
成就徽章「發布過的檔名不可以換內容」—— precheck 第 ⑧ 項的後半（閘門）

🔴 為什麼存在（2026-09-25）
  徽章在 Storage 的公開網址會被 CDN 與瀏覽器快取。**同一個路徑換了內容**，
  有人看到新圖、有人看到舊圖（最久約一小時），而且不會有任何錯誤。
  規則是：**改圖一律換新檔名**（ach_x.webp → ach_x.v2.webp），
  再把 achievements.badge_path 改成新檔名。
  那條規則原本只寫在註解裡 —— 而「要人記得」的規則遲早等於不存在（硬規則 11.1）。

做法
  旁邊一份「已發布清單」`成就徽章_已發布.json`：檔名 → 內容的 sha256。
  · 清單裡已經有的檔名、內容卻變了 ⇒ **擋下**，並印出該用的新檔名
  · 新的檔名 ⇒ 自動記進清單（不需要有人記得去登記）
  · 清單裡有、資料夾裡沒有 ⇒ 只提醒不擋（那個名字仍然保留，不可以之後拿來放別的圖）
  ⚠ 清單放在資料夾**外面**：放裡面的話，把整個資料夾拖進 Storage 時會一起被傳上去。

⚠ 這一支擋不到「直接在 Supabase 後台覆蓋同名檔」那一條路 ——
  那一條由錯誤儀表第 ⑮ 格看 Storage 的 updated_at 抓。

用法：python badgeimmutable.py <徽章資料夾>
離開碼：0 通過　1 擋下
"""
import glob
import hashlib
import json
import os
import re
import sys

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()


def next_name(name, taken):
    """ach_x.webp → ach_x.v2.webp；ach_x.v2.webp → ach_x.v3.webp（跳過已經用過的）"""
    base, ext = os.path.splitext(name)
    m = re.match(r'^(.*)\.v(\d+)$', base)
    stem, n = (m.group(1), int(m.group(2)) + 1) if m else (base, 2)
    while True:
        cand = '%s.v%d%s' % (stem, n, ext)
        if cand not in taken:
            return cand
        n += 1


def main():
    if len(sys.argv) < 2:
        print('用法：python badgeimmutable.py <徽章資料夾>')
        return 1
    d = os.path.abspath(sys.argv[1])
    manifest = os.path.join(os.path.dirname(d), os.path.basename(d) + '_已發布.json')
    try:
        with open(manifest, 'r', encoding='utf-8') as f:
            known = json.load(f)
    except FileNotFoundError:
        known = {}

    files = sorted(glob.glob(os.path.join(d, '*.webp')) + glob.glob(os.path.join(d, '*.png')))
    now = {os.path.basename(p): sha(p) for p in files}

    changed = [n for n, h in now.items() if n in known and known[n] != h]
    added = [n for n in now if n not in known]
    missing = [n for n in known if n not in now]

    if changed:
        taken = set(known) | set(now)
        print('   🔴 %d 張已發布的徽章被換了內容（同一個檔名）：' % len(changed))
        for n in changed:
            print('      %s  →  請改存成 %s，再把 achievements.badge_path 指過去' % (n, next_name(n, taken)))
        print('      理由：同一個網址換內容，CDN 與瀏覽器會繼續給舊圖（約一小時），而且不報錯。')
        print('      舊檔請還原（git checkout -- <檔名>），不要刪 —— 線上的成就可能還指著它。')
        return 1

    if added:
        known.update({n: now[n] for n in added})
        with open(manifest, 'w', encoding='utf-8', newline='\n') as f:
            json.dump(dict(sorted(known.items())), f, ensure_ascii=False, indent=1)
            f.write('\n')
        print('   ✅ 新發布 %d 張，已記進 %s' % (len(added), os.path.basename(manifest)))
    if missing:
        print('   ⚪ 清單裡有、資料夾裡沒有 %d 張（名字仍保留，不要拿來放別的圖）：%s'
              % (len(missing), '、'.join(missing[:5]) + ('…' if len(missing) > 5 else '')))
    print('   ✅ %d 張已發布的徽章，內容都沒有被換過' % (len(now) - len(added)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
