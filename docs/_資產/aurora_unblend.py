# 極光層只留「光」：把夾帶的天空扣掉（color to alpha，背景＝那一列的天空色）
# 用法：python -I aur_unblend.py <原圖.png> <現在的 aur.webp> <輸出.webp>
import sys
from PIL import Image

orig = Image.open(sys.argv[1]).convert('RGB'); px = orig.load(); W, H = orig.size
aur = Image.open(sys.argv[2]).convert('RGBA'); ap = aur.load(); AW, AH = aur.size
OX, OY = 60, 40   # 極光層在原圖的位置（AURORA.aur）

def med(v):
    v = sorted(v); return v[len(v) // 2]
BG = []
for y in range(H):
    cs = [px[x, y] for x in list(range(0, 80)) + list(range(W - 75, W))]
    BG.append(tuple(med([c[k] for c in cs]) for k in range(3)))

def smooth(e0, e1, v):
    t = max(0.0, min(1.0, (v - e0) / (e1 - e0))); return t * t * (3 - 2 * t)

out = Image.new('RGBA', (AW, AH), (0, 0, 0, 0)); op = out.load()
for y in range(AH):
    b = BG[y + OY]
    for x in range(AW):
        r, g, bl, m = ap[x, y]
        if m == 0: continue
        o = (r, g, bl)
        d = [o[k] - b[k] for k in range(3)]
        a = 0.0
        for k in range(3):
            if d[k] > 0: a = max(a, d[k] / max(1, 255 - b[k]))
            elif d[k] < 0: a = max(a, -d[k] / max(1, b[k]))
        if a <= 0: continue
        c = tuple(max(0, min(255, round(b[k] + d[k] / a))) for k in range(3))
        w = smooth(4, 14, max(abs(v) for v in d))        # 跟天空差不到 4 的點整個拿掉，14 以上不動
        fa = a * w * (m / 255)
        if fa * 255 < 1: continue
        op[x, y] = c + (round(fa * 255),)
out.save(sys.argv[3], quality=92)

# 驗算：疊回那一列的天空色，跟原本那一層疊上去的差多少（極光中心應該幾乎 0）
mx = 0; tot = 0; n = 0
for y in range(0, AH, 3):
    b = BG[y + OY]
    for x in range(0, AW, 3):
        r, g, bl, m = ap[x, y]
        if m < 250: continue
        c = op[x, y]; fa = c[3] / 255
        for k in range(3):
            e = abs(round(b[k] * (1 - fa) + c[k] * fa) - (r, g, bl)[k]); mx = max(mx, e); tot += e; n += 1
print('size', AW, AH, 'max err', mx, 'mean err', round(tot / max(1, n), 2))
