# 歐拉小鎮的星空（桌邊背景 code town）：把插畫拆成三層，給計分板做景深與小動態（2026-11-04）
#   遠景 sky.webp（天空、遠山、遠處松樹；被小鎮蓋住的地方往下抹；原圖那顆流星已抹掉，改由程式畫）
#   小鎮 land.webp（透明；旗子與三角旗挖掉，鐘的指針抹掉）
#   前景 fg.webp（左下、右下花叢，原圖像素、不透明）
#   小圖 parts.webp ＋ parts.json（旗子、6 面三角旗；位置要抄進 bg.jsx 與 tablebg.jsx 的 TOWN.parts）
# 用法：python -I town_layers.py "docs/_資產/桌邊背景_歐拉小鎮的星空.webp" <輸出資料夾>
#   輸出的四張改名成 bg-town-{sky,land,fg,parts}.webp，放進 migi-table 與 migi-web 的 src/assets（兩邊各一份）
# 座標都是寫死的原圖像素（1672×941）；換圖要重量、重調。驗證方式：沒有錯開時三層疊起來要跟原圖逐點相同
import sys, json
from collections import deque
from PIL import Image, ImageFilter

src, out = sys.argv[1], sys.argv[2]
im = Image.open(src).convert('RGB')
W, H = im.size
px = im.load()

def diff(a, b):
    return max(abs(a[0]-b[0]), abs(a[1]-b[1]), abs(a[2]-b[2]))

def grow(seeds, ok, tol, bound):
    """從 seeds 往四周長，相鄰兩點顏色差 <= tol 且 ok(x,y) 才進去"""
    seen = bytearray(W*H)
    q = deque()
    for (x, y) in seeds:
        if ok(x, y) and not seen[y*W+x]:
            seen[y*W+x] = 1; q.append((x, y))
    while q:
        x, y = q.popleft()
        c = px[x, y]
        for nx, ny in ((x+1,y),(x-1,y),(x,y+1),(x,y-1)):
            if 0 <= nx < W and 0 <= ny < H and bound(nx, ny):
                i = ny*W+nx
                if not seen[i] and ok(nx, ny) and diff(px[nx, ny], c) <= tol:
                    seen[i] = 1; q.append((nx, ny))
    return seen

def fill_holes(mask, bound):
    """mask 裡被包住的洞（不跟 bound 外緣相連的非 mask 點）補進 mask"""
    outside = bytearray(W*H)
    q = deque()
    for y in range(H):
        for x in range(W):
            if bound(x, y) and not mask[y*W+x]:
                # 外緣：bound 邊界上的點
                edge = any(not (0 <= nx < W and 0 <= ny < H) or not bound(nx, ny)
                           for nx, ny in ((x+1,y),(x-1,y),(x,y+1),(x,y-1)))
                if edge:
                    outside[y*W+x] = 1; q.append((x, y))
    while q:
        x, y = q.popleft()
        for nx, ny in ((x+1,y),(x-1,y),(x,y+1),(x,y-1)):
            if 0 <= nx < W and 0 <= ny < H and bound(nx, ny):
                i = ny*W+nx
                if not outside[i] and not mask[i]:
                    outside[i] = 1; q.append((nx, ny))
    res = bytearray(W*H)
    for y in range(H):
        for x in range(W):
            i = y*W+x
            if bound(x, y) and not outside[i]:
                res[i] = 1
    return res

ALL = lambda x, y: True

# ── 1. 天空：從最上面一列往下長，顏色漸層平順就算天空（山線、屋頂、樹梢是跳一階）
SKY_TOL = 6
sky = grow([(x, 0) for x in range(W)], lambda x, y: y < 720, SKY_TOL, lambda x, y: y < 720)
# 小鎮＝從最下面一列往上長、碰到天空就停的那一塊；星星月亮這種被天空包住的島歸天空
land = bytearray(W*H)
q = deque()
for x in range(W):
    i = (H-1)*W+x
    if not sky[i]: land[i] = 1; q.append((x, H-1))
while q:
    x, y = q.popleft()
    for nx, ny in ((x+1,y),(x-1,y),(x,y+1),(x,y-1)):
        if 0 <= nx < W and 0 <= ny < H:
            i = ny*W+nx
            if not land[i] and not sky[i]:
                land[i] = 1; q.append((nx, ny))

# ── 2. 前景花叢：左下、右下兩團，從最下面一列往上長（花叢內部顏色接近、跟後面的樹差一階）
# 第三版（2026-11-04 使用者回報前景破圖）：不再逐欄找頂端（參差不齊的欄就是左下那幾條直紋），改成：
#   · 用顏色連成一片來抓花叢；左下的切線是一條水平線 y=857（兩根樹幹最低到 855、第一朵花從 860 開始）
#     ⇒ 切線落在花叢內部同一色的地方，錯開時看不出來
#   · 右下：右邊那棵樹到 872，那幾欄（1605 以右）從 874 起
#   · 花朵整朵算進前景
bushL = lambda c: c[0] <= 73 and 72 <= c[1] <= 90 and 96 <= c[2] <= 114 and c[2] - c[0] >= 28   # 前面那團（含最下面較深的一瓣）；第二團較淺 r 76 以上
bushR = lambda c: c[0] <= 73 and 76 <= c[1] <= 90 and 98 <= c[2] <= 114 and c[2] - c[0] >= 30
LB = lambda x, y: x < 340 and y >= 857
TRUNK_R = lambda x: 1638 <= x <= 1660          # 右邊樹幹的那幾欄（花叢在 872 接上樹幹）
RB = lambda x, y: x > 1395 and y >= (874 if TRUNK_R(x) else 830)
fgL = grow([(x, H-1) for x in range(0, 330)], lambda x, y: bushL(px[x, y]), 14, LB)
fgR = grow([(x, H-1) for x in range(1420, W)], lambda x, y: bushR(px[x, y]) or (px[x, y][0] > 170 and px[x, y][0] - px[x, y][2] > 25), 12, RB)
fg = bytearray(W*H)
for i in range(W*H):
    if fgL[i]: fg[i] = 1
# 右下花叢深淺比較多，用顏色連成一片會漏掉花心與左下角 ⇒ 沿用第二版：每一欄找「連續 6 點都是花叢」的最上面那一點填到底，
# 頂端線取前後 7 欄的中位數抹平（右下花叢跟牆分得很清楚，第二版在這裡本來就沒有直紋）
rawR = bytearray(W*H)
okR = lambda c: bushR(c) or (c[0] > 170 and c[0] - c[2] > 25)
for y in range(830, H):
    for x in range(1396, W):
        if fgR[y*W+x]: rawR[y*W+x] = 1
topsR = {}
for x in range(1396, W):
    for y in range(830, H-3):
        if all(rawR[(y+k)*W+x] for k in range(min(6, H-y))): topsR[x] = y; break
for x in topsR:
    win = sorted(topsR[xx] for xx in range(x-3, x+4) if xx in topsR)
    if len(win) >= 4:
        for y in range(max(win[len(win)//2], 874 if TRUNK_R(x) else 830), H): fg[y*W+x] = 1
isflower = lambda c: c[0] > 170 and c[0] - c[2] > 20
for x in list(range(0, 340)) + list(range(1396, W)):      # 每一欄補滿最上面與最下面之間（花朵、反鋸齒的邊在花叢裡面）
    ys = [y for y in range(800, H) if fg[y*W+x]]
    if ys:
        for y in range(ys[0], ys[-1] + 1): fg[y*W+x] = 1
for y in range(800, H):                                    # 每一列：花叢中間夾的空隙補起來（6 點以內，或是花朵）
    for lo, hi in ((0, 340), (1396, W)):
        xs = [x for x in range(lo, hi) if fg[y*W+x]]
        for a, b in zip(xs, xs[1:]):
            if 1 < b - a and (b - a <= 6 or all(isflower(px[x, y]) for x in range(a+1, b))):
                for x in range(a+1, b): fg[y*W+x] = 1
for x in list(range(0, 340)) + list(range(1396, W)):      # 花頂凸出切線的那一兩點補上（最多 6 點，只補粉色）
    y = 800
    while y < H and not fg[y*W+x]: y += 1
    if y < H and isflower(px[x, y]):
        y0 = y
        while y > y0 - 6 and isflower(px[x, y-1]): y -= 1; fg[y*W+x] = 1
LEFT_END = 2000

# ── 3. 旗子：旗桿右邊、在小鎮那一塊的粉色
FLAG = (1112, 518, 1160, 560)
flag = bytearray(W*H)
for y in range(FLAG[1], FLAG[3]):
    for x in range(FLAG[0], FLAG[2]):
        if land[y*W+x]: flag[y*W+x] = 1

# ── 4. 彩旗三角形：桃色、在繩子下面
BUNT = (790, 700, 1030, 750)
tri = bytearray(W*H)
for y in range(BUNT[1], BUNT[3]):
    for x in range(BUNT[0], BUNT[2]):
        r, g, b = px[x, y]
        if r > 150 and r - b > 12 and g > 110: tri[y*W+x] = 1
# 分成一塊一塊
comps = []
seen = bytearray(W*H)
for y in range(BUNT[1], BUNT[3]):
    for x in range(BUNT[0], BUNT[2]):
        i = y*W+x
        if tri[i] and not seen[i]:
            pts = []; q = deque([(x, y)]); seen[i] = 1
            while q:
                cx, cy = q.popleft(); pts.append((cx, cy))
                for nx, ny in ((cx+1,cy),(cx-1,cy),(cx,cy+1),(cx,cy-1)):
                    j = ny*W+nx
                    if BUNT[0] <= nx < BUNT[2] and BUNT[1] <= ny < BUNT[3] and tri[j] and not seen[j]:
                        seen[j] = 1; q.append((nx, ny))
            if len(pts) > 40: comps.append(pts)
            else:
                for (cx, cy) in pts: tri[cy*W+cx] = 0

def bbox(pts, pad=2):
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    return [min(xs)-pad, min(ys)-pad, max(xs)+pad+1, max(ys)+pad+1]

# 遮罩長一圈（反鋸齒的邊也一起帶走）
def dilate(mask, n=1):
    for _ in range(n):
        m2 = bytearray(mask)
        for y in range(1, H-1):
            for x in range(1, W-1):
                if not mask[y*W+x] and (mask[y*W+x+1] or mask[y*W+x-1] or mask[(y+1)*W+x] or mask[(y-1)*W+x]):
                    m2[y*W+x] = 1
        mask = m2
    return mask

def mask_img(mask, blur=0.0):
    m = Image.frombytes('L', (W, H), bytes(255 if v else 0 for v in mask))
    return m.filter(ImageFilter.GaussianBlur(blur)) if blur else m

# ── 輸出 ──
# 天空：小鎮蓋住的地方，每一欄用上面最後一個天空色往下抹
skyimg = im.copy(); sp = skyimg.load()
landD = dilate(land, 2)    # 外擴 2 點：房子、旗子的深色描邊有一部分被算成天空，不抹掉的話錯開時會留一圈殘影
for x in range(W):
    last = px[x, 0]
    for y in range(H):
        if landD[y*W+x]: sp[x, y] = last
        else: last = px[x, y]
# 畫上去的那顆流星（四角星 ＋ 往右上的尾巴）抹掉，改由程式畫成會劃過的（2026-11-04 使用者：「把靜態流星變成動態」）
#   範圍內比天空亮的點都算流星，除了旁邊兩顆小菱形星；外擴 2 點把光暈一起帶走；每一欄用上下最近的天空色線性補
MBOX = (650, 132, 1004, 300)
KEEP = [(965, 205), (854, 282)]              # 旁邊兩顆小菱形星，不是流星
met = bytearray(W*H)
# 光暈比門檻暗、抓不到 ⇒ 不用亮度逐點判斷，改成沿路徑抹一條帶子：尾巴每一欄找最亮那一點、上下各 8 點；星星周圍抹半徑 34 的圓
HEAD = (687, 266)
for x in range(700, 1004):
    yb = max(range(135, 285), key=lambda y: sum(px[x, y]) if not any(abs(x-kx) <= 6 and abs(y-ky) <= 6 for kx, ky in KEEP) else 0)
    for y in range(yb - 8, yb + 9): met[y*W+x] = 1
for y in range(HEAD[1] - 34, HEAD[1] + 35):
    for x in range(HEAD[0] - 34, HEAD[0] + 35):
        if (x-HEAD[0])**2 + (y-HEAD[1])**2 <= 34*34: met[y*W+x] = 1
for x in range(MBOX[0], MBOX[2]):
    y = MBOX[1]
    while y < MBOX[3]:
        if met[y*W+x]:
            y0 = y
            while y < MBOX[3] and met[y*W+x]: y += 1
            a, b = sp[x, y0-1], sp[x, y]
            for yy in range(y0, y):
                k = (yy - y0 + 1) / (y - y0 + 1)
                sp[x, yy] = tuple(round(a[i] + (b[i]-a[i]) * k) for i in range(3))
        else: y += 1
ms = skyimg.filter(ImageFilter.BoxBlur(3)); msp = ms.load()   # 一欄一欄補的接縫柔化
for y in range(MBOX[1], MBOX[3]):
    for x in range(MBOX[0], MBOX[2]):
        if met[y*W+x]: sp[x, y] = msp[x, y]
skyimg.save(f'{out}/sky.webp', quality=88)

# 小鎮：去掉前景、旗子、三角形；三角形與前景的位置用上面的顏色抹（露出來的只有一點邊）
landimg = im.copy(); lp = landimg.load()
triD = dilate(tri, 1)
triHole = bytearray(W*H)   # 三角形後面是遠景 ⇒ 小鎮這一層挖空，露出遠景（遠景那裡本來就抹好了）
for x in range(BUNT[0], BUNT[2]):
    top = None
    for y in range(BUNT[1], BUNT[3]):
        if triD[y*W+x]:
            if top is None: top = y
            ay = max(0, top-4)
            if land[ay*W+x]: lp[x, y] = px[x, ay]
            else: triHole[y*W+x] = 1
        else: top = None
# 花叢外面有一圈細細的深色描邊（畫法的一部分）⇒ 外擴 3 點把描邊算進前景、跟著花叢一起動；
# 前景蓋住的範圍＝底下補色的範圍（同一份），沒有錯開時才會跟原圖逐點相同
fgD = fgCover = dilate(fg, 3)
# 花叢底下補色：每一點看「往上」與「往內側」（左下往右、右下往左）哪一邊先碰到花叢外面，用比較近那一邊的顏色
#   上緣是水平切線 ⇒ 往上碰到的是同色的花叢；側邊碰到的是牆、台階、路 ⇒ 錯開時露出來的那一條像旁邊延伸過來
for x in range(W):
    for y in range(700, H):
        if not fgD[y*W+x]: continue
        up = y
        while up > 0 and fgD[up*W+x]: up -= 1
        dx = 1 if x < W // 2 else -1
        sx = x
        while 0 <= sx < W and fgD[y*W+sx]: sx += dx
        if 0 <= sx < W and abs(sx - x) < (y - up): lp[x, y] = px[min(W-1, max(0, sx + dx*2)), y]
        else: lp[x, y] = px[x, max(0, up - 2)]
soft = landimg.filter(ImageFilter.GaussianBlur(1.5)); spx = soft.load()   # 一列一列、一欄一欄的接縫柔化一點
for y in range(700, H):
    for x in range(W):
        if fgD[y*W+x]: lp[x, y] = spx[x, y]
# 鐘：半徑 14 以內換成同半徑、左下方向（沒有指針）的顏色
CX, CY = 1098, 664
import math
for y in range(CY-15, CY+16):
    for x in range(CX-15, CX+16):
        d = math.hypot(x-CX, y-CY)
        if d <= 14:
            sx = round(CX - d*0.7071); sy = round(CY + d*0.7071)
            lp[x, y] = px[sx, sy]
alpha_land = bytearray(W*H)
flagD = dilate(flag, 1)
for i in range(W*H):
    alpha_land[i] = 1 if (land[i] and not flagD[i] and not triHole[i]) else 0
la = mask_img(alpha_land, 0.6)
landimg.putalpha(la)
landimg.save(f'{out}/land.webp', quality=90)

# 前景
# 前景：原圖像素原封不動、完全不透明（含外擴的那一圈反鋸齒邊），底下那一層只補「被它蓋住」的範圍
# ⇒ 沒有錯開的時候，畫面跟原圖逐點相同（2026-11-04 使用者：「仔細看原版，左下跟右下樹叢邊緣是錯的」——
#    上一版把邊緣改塗內側顏色、又做半透明，邊緣變鋸齒、透出補色）
fgimg = im.copy(); fgimg.putalpha(mask_img(fgCover)); fgimg.save(f'{out}/fg.webp', lossless=True)

# 小圖：旗子＋每一個三角形，排成一張
parts = []
fb = bbox([(x, y) for y in range(H) for x in range(W) if flagD[y*W+x]], 1)
parts.append(('flag', fb))
for k, pts in enumerate(sorted(comps, key=lambda p: min(q[0] for q in p))):
    parts.append((f't{k}', bbox(pts, 1)))
sheetW = sum(b[2]-b[0] + 2 for _, b in parts); sheetH = max(b[3]-b[1] for _, b in parts)
sheet = Image.new('RGBA', (sheetW, sheetH), (0, 0, 0, 0))
full = im.convert('RGBA')
amask = {'flag': flagD, 'tri': triD}
xo = 0; meta = []
for name, b in parts:
    crop = full.crop(b)
    m = Image.new('L', crop.size, 0); mp = m.load(); cp2 = crop.load()
    src_mask = flagD if name == 'flag' else triD
    lo, hi = (60, 140) if name == 'flag' else (80, 160)   # 依紅色多寡算透明度：天空與山 r 50 上下，旗子與三角形 r 150 以上
    solid = []
    for yy in range(b[1], b[3]):
        for xx in range(b[0], b[2]):
            if not src_mask[yy*W+xx] or (name == 'flag' and xx < 1113): continue   # 旗桿留在小鎮那一層
            r = px[xx, yy][0]
            a = max(0, min(255, int((r - lo) * 255 / (hi - lo))))
            mp[xx-b[0], yy-b[1]] = a
            if a == 255: solid.append(px[xx, yy])
    avg = tuple(sum(c[k] for c in solid) // max(1, len(solid)) for k in range(3))
    for yy in range(crop.height):           # 半透明的邊換成主體顏色 ⇒ 疊在別的底上不會多一圈深色
        for xx in range(crop.width):
            if 0 < mp[xx, yy] < 255: cp2[xx, yy] = avg + (255,)
    crop.putalpha(m)
    sheet.paste(crop, (xo, 0))
    meta.append({'n': name, 'sx': xo, 'x': b[0], 'y': b[1], 'w': b[2]-b[0], 'h': b[3]-b[1]})
    xo += b[2]-b[0] + 2
sheet.save(f'{out}/parts.webp', quality=92)
json.dump(meta, open(f'{out}/parts.json', 'w'))

# 檢查用：三層上色疊在原圖上
chk = im.copy().convert('RGB'); cp = chk.load()
for y in range(H):
    for x in range(W):
        i = y*W+x
        r, g, b = cp[x, y]
        if fg[i]: cp[x, y] = (min(255, r+90), g, b)
        elif flag[i] or tri[i]: cp[x, y] = (r, min(255, g+120), b)
        elif not land[i]: cp[x, y] = (r, g, min(255, b+70))
chk.save(f'{out}/chk.png')
print('parts', meta)
print('land px', sum(land), 'fg px', sum(fg))
