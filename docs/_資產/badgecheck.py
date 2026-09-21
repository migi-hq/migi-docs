# -*- coding: utf-8 -*-
"""
成就徽章「圓不圓」檢查 —— precheck 第 ⑧ 項（閘門）

🔴 為什麼存在（2026-09-21）
  App 用 border-radius:50% + object-fit:cover 把 256×256 的徽章裁成內切圓。
  圖裡的粉色圓只要**沒對準方框中心、或比方框小、或本身是橢圓**，
  內切圓的邊緣就會露出白色背景 ⇒ 使用者看到「不是正圓」。
  那一天 29 枚裡 **17 枚**有這個問題，兩種形狀：
    · 舊 10 張   四周一圈 11px 白環（圓直徑 233，放在 256 裡）
    · 第三列 7 張 **原圖就是橢圓**（合成圖擠 7 顆時橫向壓扁 3%），
                 bbox 取了長邊 ⇒ 方框比水平直徑寬 8px ⇒ 左右斷開
  ⚠ build 不會說、檢查器不會說 —— 是使用者肉眼看出來的。
  🔴 我一度說成「22 枚、第一二列下方露月牙」—— 那是第一版判準把
    熊的白色身體當成背景（見下）。**正對照跑舊版才抓到這個誤報**。

判準
  沿內切圓（距邊 2px）取 360 點，數「中性白」的點。
  🔴 **只認中性白**（三通道 ≥ 250 且色差 ≤ 4）＝背景露出來。
    熊的身體是**暖白**（254,249,246），第一版用「三通道 > 244」
    把圓底部的熊全算成露白 ⇒ 誤報一大片（硬規則 3.5：先懷疑儀器）。
  超過 2 點就擋（1–2 點是熊身上的高光像素，不是月牙）。

例外寫在 ALLOW 裡，**而且是上限不是跳過** ——
  那枚變得更糟時照樣會擋下來。

修法（錯誤訊息會印出這一行）
  python "docs/_資產/badge_recut.py" single <原圖> <code> <輸出資料夾>
  —— 擬合真正的圓再切，不是用 bbox。

用法：python badgecheck.py <assets 資料夾>
離開碼：0 通過　1 擋下
"""
import glob
import math
import os
import sys

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

from PIL import Image

LIMIT = 2
# code -> (允許的白點上限, 為什麼)
ALLOW = {
    'onboarding_05': (24, '熊拿的三張白色麻將牌貼著圓的下緣 —— 那是圖案，不是背景露出'),
}
DIRS = ['右', '右下', '下', '左下', '左', '左上', '上', '右上']


def bg_white(c):
    return min(c) >= 250 and max(c) - min(c) <= 4


def check(path):
    im = Image.open(path).convert('RGB')
    W, H = im.size
    if (W, H) != (256, 256):
        return None, '尺寸 %dx%d（應為 256x256）' % (W, H)
    px = im.load()
    c, r = 127.5, 126
    hits = []
    for a in range(360):
        x = int(round(c + r * math.cos(math.radians(a))))
        y = int(round(c + r * math.sin(math.radians(a))))
        if bg_white(px[x, y]):
            hits.append(a)
    dirs = sorted({DIRS[int(((a + 22.5) % 360) // 45)] for a in hits})
    return len(hits), '、'.join(dirs)


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else '.'
    files = sorted(glob.glob(os.path.join(d, 'ach_*.webp')))
    if not files:
        print('   ⚪ 沒有 ach_*.webp（這個 repo 沒有成就徽章）')
        return 0
    bad = []
    for f in files:
        code = os.path.basename(f)[4:-5]
        n, info = check(f)
        if n is None:
            bad.append((code, info)); continue
        cap, why = ALLOW.get(code, (LIMIT, None))
        if n > cap:
            bad.append((code, '邊緣 %d/360 點露白（%s）%s' % (n, info, '　上限 %d：%s' % (cap, why) if why else '')))
    if bad:
        print('   🔴 %d 枚徽章在圓形容器裡會露白（使用者看到的是「不是正圓」）：' % len(bad))
        for code, msg in bad:
            print('      %-16s %s' % (code, msg))
        print('   修法：python "docs/_資產/badge_recut.py" single <原圖> <code> <輸出資料夾>')
        print('         —— 擬合真正的圓再切。不要用 bbox：帽子、陰影、鄰居間隙都會把它撐歪')
        return 1
    print('   ✅ %d 枚徽章都是正圓（邊緣沒有露白）' % len(files))
    return 0


if __name__ == '__main__':
    sys.exit(main())
