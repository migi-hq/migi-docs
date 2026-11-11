# 從教練熊原圖（方形白底、中間一個藍色圓）裁出一張「去背、圓貼滿、沒有白邊」的頭像，比照廚師熊與商人熊。
# 用法：python coach_recut.py <原圖> <輸出 webp> <預覽 png>
import sys, math
from PIL import Image, ImageDraw

src, out, prev = sys.argv[1], sys.argv[2], sys.argv[3]
im = Image.open(src).convert('RGBA'); w, h = im.size
px = im.load()

def inside(p):
    r, g, b, a = p
    return a > 40 and min(r, g, b) < 236      # 不是白底

# 沿 720 個方向由外往內找圓的邊
pts = []
for k in range(720):
    ang = k * math.pi / 360
    for d in range(360, 0, -1):
        x = w / 2 + d * math.cos(ang); y = h / 2 + d * math.sin(ang)
        if 0 <= x < w and 0 <= y < h and inside(px[int(x), int(y)]):
            pts.append((x, y)); break

# 最小平方擬合圓：x² + y² = a·x + b·y + c
n = len(pts)
sx = sum(p[0] for p in pts); sy = sum(p[1] for p in pts)
sxx = sum(p[0] ** 2 for p in pts); syy = sum(p[1] ** 2 for p in pts); sxy = sum(p[0] * p[1] for p in pts)
z = [p[0] ** 2 + p[1] ** 2 for p in pts]
sz = sum(z); sxz = sum(p[0] * zz for p, zz in zip(pts, z)); syz = sum(p[1] * zz for p, zz in zip(pts, z))

def det3(m):
    return (m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]))

A = [[sxx, sxy, sx], [sxy, syy, sy], [sx, sy, n]]; B = [sxz, syz, sz]
D = det3(A)
def col(i):
    return [[B[r] if c == i else A[r][c] for c in range(3)] for r in range(3)]
a, b, c = det3(col(0)) / D, det3(col(1)) / D, det3(col(2)) / D
cx, cy = a / 2, b / 2; r = math.sqrt(c + cx * cx + cy * cy)
dev = [math.hypot(p[0] - cx, p[1] - cy) - r for p in pts]
print('原圖 %dx%d　圓心 (%.1f, %.1f)　半徑 %.1f　邊界點離擬合圓：最小 %.1f 最大 %.1f' % (w, h, cx, cy, r, min(dev), max(dev)))

rr = r - 5                                     # 原圖的圓是手繪的，邊界離正圓最多差 4 像素；往內縮 5 才不會有哪一段留白
OUT, SS = 400, 4
crop = im.transform((OUT, OUT), Image.EXTENT, (cx - rr, cy - rr, cx + rr, cy + rr), Image.BICUBIC)
mask = Image.new('L', (OUT * SS, OUT * SS), 0)
ImageDraw.Draw(mask).ellipse((0, 0, OUT * SS - 1, OUT * SS - 1), fill=255)
crop.putalpha(mask.resize((OUT, OUT), Image.LANCZOS))
crop.save(out, 'WEBP', quality=92, method=6)
crop.resize((256, 256)).save(prev)

# 檢查：新圖四角透明、圓周往內沒有白
o = Image.open(out).convert('RGBA')
def cls(p):
    r_, g_, b_, a_ = p
    return 'T' if a_ < 40 else ('W' if min(r_, g_, b_) > 243 else 'C')
runs = []
for k in range(32):
    ang = k * math.pi / 16; n0 = 0
    for d in range(OUT // 2 - 1, 0, -1):
        if cls(o.getpixel((int(OUT / 2 + d * math.cos(ang)), int(OUT / 2 + d * math.sin(ang))))) == 'C': break
        n0 += 1
    runs.append(n0)
print('新圖', o.size, '四角', [cls(o.getpixel(xy)) for xy in [(1, 1), (OUT - 2, 1), (1, OUT - 2), (OUT - 2, OUT - 2)]], '（T＝透明）　圓周往內白或透明的寬度：最大', max(runs), '像素')
