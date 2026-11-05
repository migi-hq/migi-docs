# 冰川峽灣的極光（桌邊背景 code aurora）：把插畫拆層，給計分板做景深與小動態（2026-11-05）
#   使用者選「極光整段用程式重畫」⇒ 圖上的極光整片抹掉（換成那一列的天空色），程式用粉色 token 畫會飄的極光
#   遠景 sky.webp：天空、雲、星星（極光已抹掉）
#   地面 land.webp（透明）：雪山、瀑布、海面、冰山；小帆船挖掉補色；水裡倒影的綠色調成粉紫
#   小圖 parts.webp：小帆船（透明），位置抄進 bg.jsx 與 tablebg.jsx 的 AURORA.boat
#   另外印出：星星位置（AURORA.stars）、極光下緣（AURORA.curve）
# 用法：python -I aurora_layers.py "docs/_資產/極光_原圖.png" <輸出資料夾>
#   輸出的三張改名成 bg-aurora-{sky,land,parts}.webp，放進 migi-table 與 migi-web 的 src/assets（兩邊各一份）
# 座標都是寫死的原圖像素（1670×941）；換圖要重量、重調
import sys, json, colorsys
from collections import deque
from PIL import Image, ImageFilter

src, out = sys.argv[1], sys.argv[2]
im = Image.open(src).convert('RGB')
W, H = im.size
px = im.load()

def diff(a, b):
    return max(abs(a[0]-b[0]), abs(a[1]-b[1]), abs(a[2]-b[2]))

# ── 1. 每一列的天空底色：最左、最右兩條（沒有極光）取中位數
def med(v):
    v = sorted(v); return v[len(v)//2]
BG = []
for y in range(H):
    cs = [px[x, y] for x in list(range(0, 80)) + list(range(W-75, W))]
    BG.append(tuple(med([c[k] for c in cs]) for k in range(3)))

# ── 2. 極光：方框裡跟那一列天空差超過 7 的點，連成一大片的才算（星星是小點，留著）
BX0, BX1, BY0, BY1 = 80, 1610, 60, 640
raw = bytearray(W*H)
for y in range(BY0, BY1):
    b = BG[y]
    for x in range(BX0, BX1):
        if diff(px[x, y], b) > 7: raw[y*W+x] = 1
seen = bytearray(W*H); aur = bytearray(W*H)
for y in range(BY0, BY1):
    for x in range(BX0, BX1):
        i = y*W+x
        if raw[i] and not seen[i]:
            comp = []; q = deque([(x, y)]); seen[i] = 1
            while q:
                cx, cy = q.popleft(); comp.append(cy*W+cx)
                for nx, ny in ((cx+1,cy),(cx-1,cy),(cx,cy+1),(cx,cy-1)):
                    if BX0 <= nx < BX1 and BY0 <= ny < BY1:
                        j = ny*W+nx
                        if raw[j] and not seen[j]: seen[j] = 1; q.append((nx, ny))
            if len(comp) > 3000:
                for j in comp: aur[j] = 1
m = Image.frombytes('L', (W, H), bytes(255 if v else 0 for v in aur))
m = m.filter(ImageFilter.MaxFilter(17)).filter(ImageFilter.GaussianBlur(6))
mp = m.load()
clean = im.copy(); cp = clean.load()
for y in range(BY0 - 20, BY1 + 20):
    b = BG[y]
    for x in range(BX0 - 20, BX1 + 20):
        a = mp[x, y] / 255
        if a > 0:
            c = px[x, y]
            cp[x, y] = tuple(round(c[k]*(1-a) + b[k]*a) for k in range(3))

# 極光下緣：每一欄最下面那個「很亮」的點（原圖）—— 程式畫的極光沿著這條線垂下來
curve = []
for x in range(100, 1600, 20):
    ys = [y for y in range(250, 640) if aur[y*W+x] and sum(px[x, y]) - sum(BG[y]) > 150]
    curve.append([x, ys[-1] if ys else None])

# ── 3. 天空 vs 地面：從最上面一列往下長（跟小鎮那張同一個做法）
cpx = clean.load()
SKY_TOL = 6
sky = bytearray(W*H); q = deque()
for x in range(W): sky[x] = 1; q.append((x, 0))
while q:
    x, y = q.popleft(); c = cpx[x, y]
    for nx, ny in ((x+1,y),(x-1,y),(x,y+1),(x,y-1)):
        if 0 <= nx < W and 0 <= ny < 846:
            i = ny*W+nx
            if not sky[i] and diff(cpx[nx, ny], c) <= SKY_TOL: sky[i] = 1; q.append((nx, ny))
land = bytearray(W*H); q = deque()
for x in range(W): land[(H-1)*W+x] = 1; q.append((x, H-1))
while q:
    x, y = q.popleft()
    for nx, ny in ((x+1,y),(x-1,y),(x,y+1),(x,y-1)):
        if 0 <= nx < W and 0 <= ny < H:
            i = ny*W+nx
            if not land[i] and not sky[i]: land[i] = 1; q.append((nx, ny))

# ── 4. 小帆船：方框裡從船身往外長，只走暖色（帆、船身、旗子、窗；後面的雪是偏藍的淡紫）
BB = (1128, 768, 1262, 884)
warm = lambda c: c[0] >= 105 and c[0] - c[2] >= -14
boat = bytearray(W*H); q = deque([(1190, 860)]); boat[860*W+1190] = 1
while q:
    x, y = q.popleft()
    for nx in (x-1, x, x+1):
        for ny in (y-1, y, y+1):
            if BB[0] <= nx < BB[2] and BB[1] <= ny < BB[3]:
                i = ny*W+nx
                if not boat[i] and warm(px[nx, ny]): boat[i] = 1; q.append((nx, ny))
bm = Image.frombytes('L', (W, H), bytes(255 if v else 0 for v in boat)).filter(ImageFilter.MaxFilter(3))
bmp = bm.load()
# 船的小圖：原圖像素 ＋ 透明度（外圈一點點半透明，貼回去才不會有硬邊）
alpha = bm.filter(ImageFilter.GaussianBlur(0.6))
part = Image.new('RGBA', (BB[2]-BB[0], BB[3]-BB[1]))
pp = part.load(); ap = alpha.load()
for y in range(BB[1], BB[3]):
    for x in range(BB[0], BB[2]):
        a = ap[x, y]
        if a > 8: pp[x-BB[0], y-BB[1]] = px[x, y] + (min(255, a*2),)
# 地面上被船蓋住的地方：每一列用左右兩邊沒被蓋住的顏色補（船會上下晃 2～3 點，露出來的只有邊）
cover = bm.filter(ImageFilter.MaxFilter(5)).load()
for y in range(BB[1], BB[3]):
    xs = [x for x in range(BB[0]-4, BB[2]+4) if cover[x, y]]
    if not xs: continue
    l, r = xs[0]-1, xs[-1]+1
    cl, cr = cpx[l, y], cpx[r, y]
    for x in range(l+1, r):
        k = (x-l)/(r-l)
        cpx[x, y] = tuple(round(cl[c]*(1-k) + cr[c]*k) for c in range(3))
        land[y*W+x] = 1 if (land[y*W+l] or land[y*W+r]) else land[y*W+x]

# ── 5. 水裡倒影、瀑布兩側崖壁上的綠色調成粉紫（極光改成粉色，映出來的光要跟著）
#   判斷「多綠」：綠比藍的 0.75 倍多出多少（海水本身是藍，綠永遠比藍的 0.75 倍少）
#   ⚠ 瀑布、雪、冰山很亮也偏青，排除（亮度合計 500 以上不動、瀑布那一框不動）
FALL = (686, 790, 932, 846)
def tint(c):
    r, g, b = c
    if g <= r or r + g + b >= 500: return c
    k = max(0, min(1, (g - 0.75*b - 4) / 26))
    if k <= 0: return c
    h, s, v = colorsys.rgb_to_hsv(r/255, g/255, b/255)
    rr, gg, bb = colorsys.hsv_to_rgb(0.86, max(s, 0.3), v)   # 粉紫
    return tuple(round(a*(1-k) + n*255*k) for a, n in zip(c, (rr, gg, bb)))
# 🗑 第三版（2026-11-05 使用者：「極光越做越糟」）改回保留原圖的極光 ⇒ 倒影也維持原圖的顏色，不再調色
TINT = False
if TINT:
    for y in range(700, H):
        for x in range(W):
            if FALL[0] <= x < FALL[2] and FALL[1] <= y < FALL[3]: continue
            cpx[x, y] = tint(cpx[x, y])

# ── 5b. 極光層（第三版）：原圖像素 ＋ 抹掉時用的同一張遮罩當透明度
#   遠景那張是「極光換成天空色」，這張疊回去 ⇒ 不動時跟原圖一模一樣；程式把它切直條錯開、掃亮光，讓它動
AB = (BX0 - 20, BY0 - 20, BX1 + 20, BY1 + 20)
aurl = Image.new('RGBA', (AB[2]-AB[0], AB[3]-AB[1]), (0, 0, 0, 0)); alp = aurl.load()
for y in range(AB[1], AB[3]):
    for x in range(AB[0], AB[2]):
        a = mp[x, y]
        if a > 0: alp[x-AB[0], y-AB[1]] = px[x, y] + (a,)
# 極光層裡的星星也照 6b 的比例減（光簾附近的星星在這一層，不在遠景那張）：
#   找又亮又偏白的小點，而且外圍一圈是暗的天空（排除極光下緣那條也偏白的亮邊）；大的四角星留著，其餘四顆留一顆
cand = []; aseen = bytearray(W*H)
for y in range(AB[1], AB[3]):
    for x in range(AB[0], AB[2]):
        i = y*W+x; c = px[x, y]
        if mp[x, y] and not aseen[i] and sum(c) > 480 and max(c) - min(c) < 70:
            comp = []; q = deque([(x, y)]); aseen[i] = 1
            while q:
                cx, cy = q.popleft(); comp.append((cx, cy))
                for nx, ny in ((cx+1,cy),(cx-1,cy),(cx,cy+1),(cx,cy-1)):
                    if AB[0] <= nx < AB[2] and AB[1] <= ny < AB[3]:
                        j = ny*W+nx; cc = px[nx, ny]
                        if not aseen[j] and sum(cc) > 480 and max(cc) - min(cc) < 70: aseen[j] = 1; q.append((nx, ny))
            if 2 <= len(comp) < 120:
                sx = sum(p[0] for p in comp)//len(comp); sy = sum(p[1] for p in comp)//len(comp)
                r = int(len(comp) ** 0.5 * 1.3) + 4
                ring = [px[xx, yy] for yy in range(sy-r-5, sy+r+6) for xx in range(sx-r-5, sx+r+6)
                        if 0 <= xx < W and 0 <= yy < H and r+2 <= ((xx-sx)**2 + (yy-sy)**2) ** 0.5 <= r+5]
                rc = tuple(med([p[k] for p in ring]) for k in range(3))
                if sum(rc) < 330: cand.append((sx, sy, r, rc))
cand.sort()
for i, (sx, sy, r, rc) in enumerate(cand):
    if i % 4 == 0: continue
    for y in range(sy-r, sy+r+1):
        for x in range(sx-r, sx+r+1):
            if AB[0] <= x < AB[2] and AB[1] <= y < AB[3] and ((x-sx)**2 + (y-sy)**2) ** 0.5 <= r:
                a = alp[x-AB[0], y-AB[1]][3]
                if a: alp[x-AB[0], y-AB[1]] = rc + (a,)
print("極光層的星星", len(cand), "抹掉", len([1 for i in range(len(cand)) if i % 4]))

# ── 6. 星星（抹掉極光後的天空裡的亮點），給程式挑幾顆慢慢閃
stars = []; sseen = bytearray(W*H)
for y in range(0, 700):
    for x in range(W):
        i = y*W+x
        if not land[i] and not sseen[i] and sum(cpx[x, y]) > 420:
            comp = []; q = deque([(x, y)]); sseen[i] = 1
            while q:
                cx, cy = q.popleft(); comp.append((cx, cy))
                for nx, ny in ((cx+1,cy),(cx-1,cy),(cx,cy+1),(cx,cy-1)):
                    if 0 <= nx < W and 0 <= ny < 700:
                        j = ny*W+nx
                        if not land[j] and not sseen[j] and sum(cpx[nx, ny]) > 420: sseen[j] = 1; q.append((nx, ny))
            if 2 <= len(comp) < 600:
                sx = sum(p[0] for p in comp)//len(comp); sy = sum(p[1] for p in comp)//len(comp)
                stars.append([sx, sy, len(comp)])

# ── 6b. 星星減少（2026-11-05 使用者：「天空星星減少一點，讓極光比較顯眼」）
#   大的四角星（200 點以上）全留；其餘照 x 排序每四顆留一顆（同日第一次是三顆留一顆，使用者看了仍嫌多）
#   抹法：星星中心一圈（半徑照大小）換成外圍一圈的中位數顏色 —— 靠近雲的地方也接得起來
small = sorted([s for s in stars if s[2] < 200], key=lambda s: s[0])
drop = [s for i, s in enumerate(small) if i % 4 != 0]
for (sx, sy, n) in drop:
    r = int(n ** 0.5 * 1.3) + 4
    ring = [cpx[x, y] for y in range(sy-r-5, sy+r+6) for x in range(sx-r-5, sx+r+6)
            if 0 <= x < W and 0 <= y < H and r+2 <= ((x-sx)**2 + (y-sy)**2) ** 0.5 <= r+5]
    if not ring: continue
    c = tuple(med([p[k] for p in ring]) for k in range(3))
    for y in range(sy-r, sy+r+1):
        for x in range(sx-r, sx+r+1):
            if 0 <= x < W and 0 <= y < H and not land[y*W+x] and ((x-sx)**2 + (y-sy)**2) ** 0.5 <= r:
                cpx[x, y] = c
stars = [s for s in stars if s not in drop]
print('星星留', len(stars), '抹掉', len(drop))
print('會閃的（最大的 10 顆）', sorted(stars, key=lambda s: -s[2])[:10])

# ── 7. 倒影水波（2026-11-05 使用者：「倒影的水波要生動一點」）
#   瀑布前到船那一帶（RIP 方框）的水面切橫條左右錯開；方框裡的小冰山另外拆出來（ice.webp）不跟著晃
#   water.webp：方框裡的水面，冰山的位置用左右兩邊的水補起來（橫條錯開時才不會拖出冰山的殘影）
#   冰山＝又亮又不太有色彩（最亮與最暗的通道差 60 以內、三色合計 480 以上）；粉色倒影再亮也有色彩，不會被當成冰山
#   船的倒影（x 1130 以右）不算冰山，要跟著晃
RIP = (520, 846, 1300, H)
isice = lambda c: sum(c) > 480 and max(c) - min(c) < 60
icem = Image.new('L', (W, H), 0); imp = icem.load()
# ⚠ 只在冰山的框裡找：瀑布正下方的亮倒影、水平線那條亮帶也是「又亮又沒什麼顏色」，它們要跟著晃
ICEBOX = [(520, 846, 545, 857), (555, 850, 590, 867), (620, 876, 681, 901), (994, 850, 1077, 877), (1085, 882, 1119, 901)]
for (x0, y0, x1, y1) in ICEBOX:
    for y in range(y0, y1):
        for x in range(x0, x1):
            if isice(cpx[x, y]): imp[x, y] = 255
icem = icem.filter(ImageFilter.MaxFilter(5)); imp = icem.load()
water = clean.crop(RIP); wp = water.load()
ice = Image.new('RGBA', (RIP[2]-RIP[0], RIP[3]-RIP[1]), (0, 0, 0, 0)); ip = ice.load()
for y in range(RIP[1], RIP[3]):
    xs = [x for x in range(RIP[0], RIP[2]) if imp[x, y]]
    for x in xs: ip[x-RIP[0], y-RIP[1]] = cpx[x, y] + (255,)
    # 每一段連續的冰山，用兩端外面的水內插補起來
    i = 0
    while i < len(xs):
        j = i
        while j + 1 < len(xs) and xs[j+1] == xs[j] + 1: j += 1
        l, r = max(RIP[0], xs[i]-1), min(RIP[2]-1, xs[j]+1)
        cl, cr = cpx[l, y], cpx[r, y]
        for x in range(xs[i], xs[j]+1):
            k = (x-l)/max(1, r-l)
            wp[x-RIP[0], y-RIP[1]] = tuple(round(cl[c]*(1-k) + cr[c]*k) for c in range(3))
        i = j + 1

# ── 8. 船上的小旗子（2026-11-05 使用者選的小動態 ①）：從船的小圖切下來另存，程式切成一條一條讓它飄
#   旗桿在 x 1195，留在船上；旗面 x 1197～1222、y 779～797
FL = (1197, 779, 1223, 798)
flag = part.crop((FL[0]-BB[0], FL[1]-BB[1], FL[2]-BB[0], FL[3]-BB[1]))
fpp = part.load()
for y in range(FL[1], FL[3]):
    for x in range(FL[0], FL[2]):
        fpp[x-BB[0], y-BB[1]] = (0, 0, 0, 0)
flag.save(out + '/flag.webp', lossless=True)
part.save(out + '/parts.webp', lossless=True)

# ── 輸出
aurl.save(out + '/aur.webp', quality=90)
print('aurora layer at', AB[:2], aurl.size)
water.save(out + '/water.webp', quality=88)
ice.save(out + '/ice.webp', lossless=True)
skyimg = clean.copy()   # 遠景整張不透明（地面那層蓋上去）
skyimg.save(out + '/sky.webp', quality=88)
lim = clean.convert('RGBA'); lp = lim.load()
for y in range(H):
    for x in range(W):
        if not land[y*W+x]: lp[x, y] = (0, 0, 0, 0)
lim.save(out + '/land.webp', quality=90)
part.save(out + '/parts.webp', lossless=True)
json.dump({'boat': {'x': BB[0], 'y': BB[1], 'w': BB[2]-BB[0], 'h': BB[3]-BB[1]},
           'stars': stars, 'curve': curve}, open(out + '/aurora.json', 'w'))
# 檢查用：遮罩
m.save(out + '/_aurmask.png'); bm.save(out + '/_boatmask.png')
print('stars', len(stars), 'boat px', sum(boat))
