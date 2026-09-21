# 以「擬合出來的圓」重切徽章，讓圓剛好內切 256x256
#
# 🔴 先前用 bbox（有墨的範圍）切正方形 —— 而帽子、彩帶、陰影、鄰居間隙
#    都會把 bbox 撐歪 ⇒ 方框沒對準圓心 ⇒ App 裁成圓時下方露出白色月牙。
# ✅ 這支改成：沿 180 條射線**從外往內**找第一個非白點（圓內的白熊不會干擾），
#    最小平方擬合圓（Kasa），剔除離群（凸出物），再用擬合的圓心與半徑切。
#
# ⚠ 原圖本身是橢圓時（2026-09-21 第三列扁了 3%）用**短邊半徑**切 ——
#   長軸兩端各裁掉幾 px，但**不拉伸**（拉伸會讓熊變胖）。
# ⚠ 先輸出到暫存資料夾、跑過 badgecheck.py 再覆蓋 src/assets。
#   寫檔用 os.replace 原子替換：寫到一半失敗不會留下半張圖。
#
# 用法：
#   python badge_recut.py sheet <合成圖> <輸出資料夾> "13,20;24,22"
#       最後一個參數是排法：列用 ; 分、顆用 , 分，填成就編號（省略＝第一張 6/6/7 那張）
#       偵測到的列數／顆數對不上會直接停，不會把圖切給錯的成就。
#   python badge_recut.py single <圖> <code> <輸出資料夾>
#       單張，例：single 桌面\新圖.png onboarding_14 out\
import math
import os
import sys
from PIL import Image

MARGIN = 1.5   # 半徑再內縮 1.5px（原圖尺度），確保內切圓全落在粉色裡


def white(c):
    return c[0] > 244 and c[1] > 244 and c[2] > 244


def kasa(P):
    # 解 x²+y² + D x + E y + F = 0 的最小平方
    n = len(P)
    sx = sum(x for x, _ in P); sy = sum(y for _, y in P)
    sxx = sum(x * x for x, _ in P); syy = sum(y * y for _, y in P); sxy = sum(x * y for x, y in P)
    sz = sum(x * x + y * y for x, y in P)
    sxz = sum(x * (x * x + y * y) for x, y in P); syz = sum(y * (x * x + y * y) for x, y in P)
    A = [[sxx, sxy, sx], [sxy, syy, sy], [sx, sy, n]]
    b = [-sxz, -syz, -sz]
    # 高斯消去
    M = [A[i] + [b[i]] for i in range(3)]
    for i in range(3):
        p = max(range(i, 3), key=lambda r: abs(M[r][i])); M[i], M[p] = M[p], M[i]
        for r in range(3):
            if r != i:
                f = M[r][i] / M[i][i]
                M[r] = [M[r][k] - f * M[i][k] for k in range(4)]
    D, E, F = (M[i][3] / M[i][i] for i in range(3))
    cx, cy = -D / 2, -E / 2
    return cx, cy, math.sqrt(max(cx * cx + cy * cy - F, 0))


def fit(im, box):
    px = im.load(); W, H = im.size
    x0, y0, x1, y1 = box
    cx0, cy0 = (x0 + x1) / 2, (y0 + y1) / 2
    R0 = min(x1 - x0, y1 - y0) / 2          # 用短邊：凸出物只會讓長邊變長
    pts = []
    for a in range(0, 360, 2):
        c, s = math.cos(math.radians(a)), math.sin(math.radians(a))
        d = R0 + 4
        while d > R0 * 0.55:
            x, y = int(round(cx0 + d * c)), int(round(cy0 + d * s))
            if 0 <= x < W and 0 <= y < H and not white(px[x, y]):
                pts.append((cx0 + d * c, cy0 + d * s)); break
            d -= 0.5
    cx, cy, R = kasa(pts)
    for _ in range(3):                       # 剔除離群（帽子、彩帶、陰影）再擬合
        keep = [p for p in pts if abs(math.hypot(p[0] - cx, p[1] - cy) - R) < 2.5]
        if len(keep) < 40:
            break
        cx, cy, R = kasa(keep)
    keep = [p for p in pts if abs(math.hypot(p[0] - cx, p[1] - cy) - R) < 2.5]

    def axis(lo, hi):
        ds = []
        for p in keep:
            a = math.degrees(math.atan2(p[1] - cy, p[0] - cx)) % 180
            if lo <= a <= hi:
                ds.append(math.hypot(p[0] - cx, p[1] - cy))
        ds.sort()
        return ds[len(ds) // 2] if ds else R
    Rx = axis(0, 12) if axis(0, 12) else R
    Rx = min(axis(0, 12), axis(168, 180))
    Ry = axis(78, 102)
    return cx, cy, R, Rx, Ry, len(keep), len(pts)


def cut(im, circle, dst):
    cx, cy, R, Rx, Ry = circle[:5]
    r = min(R, Rx, Ry) - MARGIN
    # ⚠ 原圖的圓貼到畫布邊時（2026-09-21 的 26 號：圓心 y 617、半徑 618），
    #   框會超出畫布 ⇒ PIL 拋 box offset can't be negative。
    #   夾在畫布內就好 —— 少不到 1px，而往外補白會讓那一邊露白。
    W, H = im.size
    r = min(r, cx, cy, W - cx, H - cy)
    tmp = dst + '.tmp.webp'
    im.resize((256, 256), Image.LANCZOS, box=(cx - r, cy - r, cx + r, cy + r)).save(tmp, 'WEBP', quality=90)
    os.replace(tmp, dst)                      # 原子替換：寫失敗不會留下半張檔


def report(code, c):
    cx, cy, R, Rx, Ry, k, n = c
    ecc = abs(Rx - Ry) / R * 100
    print(f'  {code:16} 圓心 ({cx:7.1f},{cy:7.1f})  R {R:6.1f}  水平 {Rx:6.1f}  垂直 {Ry:6.1f}  '
          f'扁 {ecc:4.1f}%  採用 {k}/{n}')


def sheet_boxes(im, ROWS):
    # 同 cut.py：水平帶 -> 每列垂直切段
    px = im.load(); W, H = im.size
    ink = lambda c: not white(c)
    rows = [sum(1 for x in range(0, W, 2) if ink(px[x, y])) for y in range(H)]
    bands, on = [], False
    for y, v in enumerate(rows):
        if v > 3 and not on: on, s = True, y
        elif v <= 3 and on:
            on = False
            if y - s > 8: bands.append((s, y))
    circ = [b for b in bands if b[1] - b[0] > 150]
    # 🔴 偵測到的列數／每列顆數對不上就停 —— 不然會把圖切給錯的成就，而且不報錯
    assert len(circ) == len(ROWS), f'偵測到 {len(circ)} 列圓，而 rows 給了 {len(ROWS)} 列'
    out = []
    for ri, (by0, by1) in enumerate(circ):
        cols = [sum(1 for y in range(by0, by1, 2) if ink(px[x, y])) for x in range(W)]
        segs, on = [], False
        for x, v in enumerate(cols):
            if v > 2 and not on: on, s = True, x
            elif v <= 2 and on:
                on = False
                if x - s > 30: segs.append((s, x))
        assert len(segs) == len(ROWS[ri]), f'第 {ri+1} 列偵測到 {len(segs)} 顆，而 rows 給了 {len(ROWS[ri])} 顆'
        for si, (x0, x1) in enumerate(segs):
            out.append((ROWS[ri][si], (x0, by0, x1, by1)))
    return out


# 2026-09-21 第一張合成圖（6/6/7 那張）的排法，當預設
DEFAULT_ROWS = '09,10,13,14,15,16;17,18,19,20,21,22;23,24,25,26,27,28,29'

mode = sys.argv[1]
if mode == 'sheet':
    # 第 4 個參數：列用 ; 分、顆用 , 分，填成就編號 —— 例 "13,20;24,22"
    im = Image.open(sys.argv[2]).convert('RGB'); outd = sys.argv[3]
    spec = sys.argv[4] if len(sys.argv) > 4 else DEFAULT_ROWS
    rows = [r.split(',') for r in spec.split(';')]
    for n, box in sheet_boxes(im, rows):
        c = fit(im, box); report('onboarding_' + n, c)
        cut(im, c, os.path.join(outd, f'ach_onboarding_{n}.webp'))
elif mode == 'single':
    im = Image.open(sys.argv[2]).convert('RGB'); code = sys.argv[3]; outd = sys.argv[4]
    W, H = im.size
    c = fit(im, (0, 0, W, H)); report(code, c)
    cut(im, c, os.path.join(outd, f'ach_{code}.webp'))
