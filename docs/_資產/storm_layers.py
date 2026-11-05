# 燈塔島的暴風雨（桌邊背景 code storm）：把插畫拆層，給計分板做景深與小動態（2026-11-05 使用者：「下一個記分板做燈塔島的暴風雨」）
# 正本：docs/_資產/燈塔島_原圖.webp（1671 × 941）
# 用法：python -I storm_layers.py "docs/_資產/燈塔島_原圖.webp" <輸出資料夾>
#   輸出 sky.webp／land.webp／beam.webp 改名成 bg-storm-{sky,land,beam}.webp，放進 migi-table 與 migi-web 的 src/assets（兩邊各一份）
# 拆法：
#   ① 燈塔、小屋、樹：從最上面一列往下長出天空，燈塔那一框裡長不到的就是它們（雨絲不要碰到這些細節）
#   ② 雨絲：細細一條、比四周亮一點 ⇒ 灰階開運算 9×9 把細線拿掉，比原圖暗 5 以上的點換成開運算的值；浪花（亮度 170 以上）不動
#   ③ 閃電：原圖那一道整個刪掉（2026-11-05 使用者：「原閃電可以刪掉 重畫動畫」），旁邊那團粉色光暈也扣掉
#   ④ 燈塔光束：光是「加上去的暖色」。天空與雲的 R−B 幾乎固定（−38），多出來的暖就是光 ⇒ 遠景扣掉光再柔一下；
#      beam ＝ 原圖減遠景（只有光，畫的時候用相加，全亮時疊回去就是原圖）；程式讓左右兩道輪流亮暗（燈在轉）
#   ⑤ 前景（島、燈塔、小屋、樹、海浪）：① 長不到的 ＋ 礁石（暖色）＋ 每一欄礁石以下、y 800 以下全部；
#      遠景被前景蓋住的地方往下延伸補色（只會露出錯開的那幾點）
import sys, json
from collections import deque
from PIL import Image, ImageFilter, ImageChops, ImageDraw

src, out = sys.argv[1], sys.argv[2]
im = Image.open(src).convert('RGB'); W, H = im.size; px = im.load()
lum = lambda c: (c[0] * 3 + c[1] * 6 + c[2]) / 10
SKYREF = (46, 58, 83)

# ── ① 天空往下長（在原圖上長：雨絲邊緣是軟的，不會擋住）
def grow(img, tol=7):
    p = img.load(); seen = bytearray(W * H); q = deque()
    for x in range(W): seen[x] = 1; q.append((x, 0))
    while q:
        x, y = q.popleft(); c = p[x, y]
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < W and 0 <= ny < H:
                i = ny * W + nx
                if not seen[i]:
                    n = p[nx, ny]
                    if max(abs(n[0] - c[0]), abs(n[1] - c[1]), abs(n[2] - c[2])) <= tol and lum(n) < 150: seen[i] = 1; q.append((nx, ny))
    return seen
sky0 = grow(im)
TOWER = (790, 320, 1265, 735)
obj = Image.new('L', (W, H), 0); op_ = obj.load()
for y in range(TOWER[1], TOWER[3]):
    for x in range(TOWER[0], TOWER[2]):
        if not sky0[y * W + x]: op_[x, y] = 255
# 燈室兩邊亮黃的那一截是光束不是燈塔（長不過去是因為太亮）：楔形裡、燈室那一欄以外、欄杆以上的拿掉
POLY_L = [(990, 388), (990, 462), (690, 530), (690, 345)]
POLY_R = [(1072, 388), (1072, 462), (1465, 548), (1465, 352)]
cut = Image.new('L', (W, H), 0); dc = ImageDraw.Draw(cut); dc.polygon(POLY_L, fill=255); dc.polygon(POLY_R, fill=255)
cp_ = cut.load()
for y in range(TOWER[1], 470):
    for x in range(TOWER[0], TOWER[2]):
        # 欄杆（x 960～1102、y 452 以下）是燈塔；欄杆以上、燈室那一欄以外是光
        if cp_[x, y] and (not (960 <= x <= 1102) if y >= 452 else not (985 <= x <= 1078)): op_[x, y] = 0
obj = obj.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.MaxFilter(3))
objd = obj.filter(ImageFilter.MaxFilter(7)).load()

# ── ② 雨絲
opened = im.filter(ImageFilter.MinFilter(9)).filter(ImageFilter.MaxFilter(9)); opp = opened.load()
rain = Image.new('L', (W, H), 0); rp = rain.load()
for y in range(H):
    for x in range(W):
        if objd[x, y]: continue
        c = px[x, y]
        if lum(c) >= 170: continue
        if lum(c) - lum(opp[x, y]) > 5: rp[x, y] = 255
rain = rain.filter(ImageFilter.MaxFilter(3))
soft = opened.filter(ImageFilter.GaussianBlur(1.5))
base = Image.composite(soft, im, rain.filter(ImageFilter.GaussianBlur(1)))
derained = base.copy()
bp = base.load()

# ── ③ 閃電：方框裡很亮的點，漲 4 點，每一列左右補，再柔一下
BOLT = (238, 222, 350, 445)
bm = Image.new('L', (W, H), 0); bmp = bm.load()
for y in range(BOLT[1], BOLT[3]):
    for x in range(BOLT[0], BOLT[2]):
        if lum(px[x, y]) > 120: bmp[x, y] = 255
bm = bm.filter(ImageFilter.MaxFilter(9)); bmp = bm.load()
for y in range(BOLT[1] - 6, BOLT[3] + 6):
    xs = [x for x in range(BOLT[0] - 8, BOLT[2] + 8) if bmp[x, y]]
    if not xs: continue
    l, r = xs[0] - 1, xs[-1] + 1
    cl, cr = bp[l, y], bp[r, y]
    for x in range(l + 1, r):
        k = (x - l) / (r - l); bp[x, y] = tuple(round(cl[i] * (1 - k) + cr[i] * k) for i in range(3))
box = (BOLT[0] - 12, BOLT[1] - 10, BOLT[2] + 12, BOLT[3] + 10)
patch = base.crop(box).filter(ImageFilter.GaussianBlur(3))
pm = bm.crop(box).filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.GaussianBlur(4))
base.paste(patch, box[:2], pm); bp = base.load()

# 天空與雲的 R−B（固定值）
ws = sorted(bp[x, y][0] - bp[x, y][2] for y in range(20, 640, 4) for x in range(0, W, 4)
            if not objd[x, y] and lum(bp[x, y]) < 150 and not (650 < x < 1500 and 330 < y < 560) and not ((x - 305) ** 2 + (y - 300) ** 2 < 170 ** 2))
W0 = ws[len(ws) // 2]

def unwarm(mask, ref_pts):
    # 區域裡比天空「暖」的部分當成加上去的光扣掉；光的顏色取 ref_pts 裡最暖的那些點
    mp = mask.load()
    cand = sorted(((bp[x, y][0] - bp[x, y][2], bp[x, y]) for (x, y) in ref_pts), reverse=True)[:40]
    top = tuple(sum(c[1][i] for c in cand) / len(cand) for i in range(3))
    cb = tuple(max(1, top[i] - SKYREF[i]) for i in range(3)); den = cb[0] - cb[2]
    x0, y0, x1, y1 = mask.getbbox()
    for y in range(y0, y1):
        for x in range(x0, x1):
            a = mp[x, y] / 255
            if a <= 0 or objd[x, y]: continue
            c = bp[x, y]
            k = max(0.0, min(1.1, ((c[0] - c[2]) - W0) / den)) * a
            if k < 0.01: continue
            bp[x, y] = tuple(max(0, round(c[i] - k * cb[i])) for i in range(3))
    return cb

# 閃電的光暈（粉色那一團）
gm = Image.new('L', (W, H), 0); ImageDraw.Draw(gm).ellipse((305 - 170, 300 - 170, 305 + 170, 300 + 170), fill=255)
gm = gm.filter(ImageFilter.GaussianBlur(30))
glow_c = unwarm(gm, [(x, y) for y in range(250, 350, 2) for x in range(255, 360, 2) if not bmp[x, y]])
base = Image.composite(base.filter(ImageFilter.GaussianBlur(4)), base, gm); bp = base.load()   # 扣過的地方柔掉方格痕

# ── ④ 光束
wm = Image.new('L', (W, H), 0); d = ImageDraw.Draw(wm)
d.polygon(POLY_L, fill=255); d.polygon(POLY_R, fill=255)
wm = wm.filter(ImageFilter.MaxFilter(9)).filter(ImageFilter.GaussianBlur(4))
beam_c = unwarm(wm, [(x, y) for y in range(380, 470) for x in list(range(950, 990)) + list(range(1072, 1110))])
# 扣過的地方柔一下（光束原本的邊、裡面的筆觸會留下細線）
sm = base.filter(ImageFilter.GaussianBlur(3))
base = Image.composite(sm, base, wm); bp = base.load()

# ── ⑤ 前景（先不含島）：天空長不到的地方 ＋ y 800 以下；燈塔那一框以 ① 為準（光束扣掉之後，光的邊不要被當成前景）
#   🗑 原本還用「每一欄第一個暖色點以下」當前景，大浪上方那幾顆水滴也偏暖，整欄天空被切成一根根柱子 ⇒ 拿掉，島在 ⑥ 另外切
land = Image.new('L', (W, H), 0); lp = land.load()
sky1 = grow(base)
ISL = (705, 640, 1460, 900)          # 礁石可能在的範圍（左側暗面躲在大浪後面，要放寬到 705）
for x in range(W):
    for y in range(H):
        if y >= 800 or not sky1[y * W + x]: lp[x, y] = 255
        # 礁石那一帶：浪花的陰影跟天空顏色很近，會被當成天空留在遠景，浪起伏時變成殘影 ⇒ 亮一點（105 以上）的算前景；天空很暗，不受影響
        elif ISL[0] <= x < ISL[2] and y >= 700 and lum(bp[x, y]) >= 105: lp[x, y] = 255
for y in range(TOWER[1], TOWER[3]):
    for x in range(TOWER[0], TOWER[2]):
        if y < 640: lp[x, y] = 255 if obj.getpixel((x, y)) else 0
land = land.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.MaxFilter(3))
# 前景裡的光束（燈塔那一條）不拆，光照在燈塔上的部分就留在燈塔上
# beam ＝ 去雨的原圖減遠景（只在光束那一帶）
beam = ImageChops.subtract(derained, base)
bmask = wm.point(lambda v: 255 if v > 0 else 0)
beam = Image.composite(beam, Image.new('RGB', (W, H)), bmask)

# ── ⑥ 前景再拆成兩張：島（礁石、燈塔、小屋、樹）／海（海水與浪花，程式讓它一波一波起伏）
#   礁石暗面（R−B 約 −27）與海水（約 −39）只差一點點藍 ⇒ 先把範圍裡「像礁石」的點都找出來（偏暖、不太亮），
#   只留跟燈塔腳下相連的那一大塊，再把裡面的小洞補起來（礁石面上的小水滴）。
#   前面的浪花從外面咬進來的缺口跟外面的海相通，不算洞 ⇒ 留給海那一張
ROCK_BOTTOM = 880
dp = derained.load()
rockish = bytearray(W * H)
for y in range(ISL[1], ROCK_BOTTOM):
    for x in range(ISL[0], ISL[2]):
        c = dp[x, y]
        # 礁石暗面與灰面：偏暖一點、亮度 135 以下；礁石亮面：明顯紅棕（R−B 5 以上）。
        # 浪花背光那一面也偏暖（R−B 約 −20）但亮度 140 以上 ⇒ 兩條都不符合，才不會跟礁石連成一塊（不然浪起伏時留下殘影）
        rb, lm = c[0] - c[2], lum(c)
        if objd[x, y] or (rb > W0 + 4 and lm < 135) or (rb > 5 and lm < 158): rockish[y * W + x] = 1
for y in range(TOWER[1], TOWER[3]):                      # 燈塔、小屋、樹本身一定算（才會跟礁石連成一塊）
    for x in range(TOWER[0], TOWER[2]):
        if op_[x, y]: rockish[y * W + x] = 1
comp = bytearray(W * H); q = deque([(1030, 720)]); comp[720 * W + 1030] = 1
while q:
    x, y = q.popleft()
    for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
        if 0 <= nx < W and 0 <= ny < H:
            i = ny * W + nx
            if rockish[i] and not comp[i]: comp[i] = 1; q.append((nx, ny))
# 補洞：從範圍外框往裡長「不是島」的地方，長不到的就是洞
out_ = bytearray(W * H); q = deque()
X0, Y0, X1, Y1 = ISL[0] - 1, TOWER[1] - 1, ISL[2] + 1, ROCK_BOTTOM + 1
for x in range(X0, X1):
    for y in (Y0, Y1 - 1): out_[y * W + x] = 1; q.append((x, y))
for y in range(Y0, Y1):
    for x in (X0, X1 - 1): out_[y * W + x] = 1; q.append((x, y))
while q:
    x, y = q.popleft()
    for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
        if X0 <= nx < X1 and Y0 <= ny < Y1:
            i = ny * W + nx
            if not comp[i] and not out_[i]: out_[i] = 1; q.append((nx, ny))
isl = Image.new('L', (W, H), 0); ikp_ = isl.load()
for y in range(Y0, Y1):
    for x in range(X0, X1):
        if comp[y * W + x]: ikp_[x, y] = 255
# 洞只補小的（600 點以下：礁石面上的小水滴）；大的是被礁石包住的浪花，要留給海，不然浪起伏時會留下殘影
seen_ = bytearray(W * H)
for y in range(Y0, Y1):
    for x in range(X0, X1):
        i = y * W + x
        if comp[i] or out_[i] or seen_[i]: continue
        hole = []; q = deque([(x, y)]); seen_[i] = 1
        while q:
            cx_, cy_ = q.popleft(); hole.append((cx_, cy_))
            for nx, ny in ((cx_ + 1, cy_), (cx_ - 1, cy_), (cx_, cy_ + 1), (cx_, cy_ - 1)):
                j = ny * W + nx
                if X0 <= nx < X1 and Y0 <= ny < Y1 and not comp[j] and not out_[j] and not seen_[j]: seen_[j] = 1; q.append((nx, ny))
        if len(hole) <= 600:
            for (hx, hy) in hole: ikp_[hx, hy] = 255
isl = isl.filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.MinFilter(3))
# 島那張：每一欄從島的最上面往下，不是島的地方（前面浪花蓋住的礁石下半）用上面的礁石往下補，補到 y 900；
#   海浪起伏時露出來的才是礁石。補的地方會是一條條直紋 ⇒ 再用大一點的模糊柔開
islim = derained.copy(); ip = islim.load(); ikp = isl.load(); lpm = land.load()
filled = Image.new('L', (W, H), 0); fp = filled.load()
for x in range(ISL[0], ISL[2]):
    lastc = None
    for y in range(640, ROCK_BOTTOM + 20):
        if ikp[x, y]: lastc = ip[x, y]
        elif lastc is not None and lpm[x, y]: ip[x, y] = lastc; fp[x, y] = 255   # 只補原本是海或浪花的地方（天空不補）
islim = Image.composite(islim.filter(ImageFilter.GaussianBlur(8)), islim, filled.filter(ImageFilter.MaxFilter(3)))
region = ImageChops.lighter(isl, filled)
land = ImageChops.lighter(land, isl)                      # 前景 ＝ 上面那些 ＋ 島

# 遠景：前景蓋住的地方用四周天空的顏色平均補（模糊「天空 × 遮罩」再除以模糊的遮罩）
#   🗑 原本是每一欄把上面最後一個天空色往下延伸 —— 會留下一條條直紋，浪往下沉時露出來（同日使用者：「海浪有線」）
#   用金字塔補：一層一層縮小（天空 × 遮罩、遮罩各自平均），最小那一層一定補得滿；再一層一層放大回來，
#   每一層只有「周圍天空夠多」的點用自己算的顏色，其餘用上一層放大的顏色（遮罩很小時直接相除會放大誤差，出現一圈圈彩色等高線）
big = land.filter(ImageFilter.MaxFilter(13))
keep = ImageChops.invert(big)                              # 天空 ＝ 255
def inpaint(img, keep):
    nums, keeps = [ImageChops.multiply(img, keep.convert('RGB'))], [keep]
    while min(nums[-1].size) > 8:
        w, h = nums[-1].size
        nums.append(nums[-1].resize((max(1, w // 2), max(1, h // 2)), Image.BOX))
        keeps.append(keeps[-1].resize((max(1, w // 2), max(1, h // 2)), Image.BOX))
    up = None
    for lv in range(len(nums) - 1, -1, -1):
        n, k = nums[lv].load(), keeps[lv].load(); w, h = nums[lv].size
        out = Image.new('RGB', (w, h)); op2 = out.load()
        u = up.resize((w, h), Image.BILINEAR).load() if up else None
        done = [[False] * w for _ in range(h)]
        for y in range(h):
            for x in range(w):
                kv = k[x, y]
                # 周圍天空要夠多（40 以上）才用自己算的顏色；太少時相除會把誤差放大成怪顏色（綠、紫）
                t = max(0.0, min(1.0, (kv - 40) / 160))
                col = tuple(min(255, round(n[x, y][i] * 255 / kv)) for i in range(3)) if kv > 0 else (0, 0, 0)
                if u: col = tuple(round(col[i] * t + u[x, y][i] * (1 - t)) for i in range(3)); done[y][x] = True
                elif kv > 40: done[y][x] = True
                op2[x, y] = col
        if not u:                                          # 最小那一層：沒天空的格子用相鄰補好的格子一圈一圈往裡填
            while not all(all(r) for r in done):
                nxt = [r[:] for r in done]
                for y in range(h):
                    for x in range(w):
                        if done[y][x]: continue
                        nb = [op2[xx, yy] for xx, yy in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)) if 0 <= xx < w and 0 <= yy < h and done[yy][xx]]
                        if nb: op2[x, y] = tuple(sum(c[i] for c in nb) // len(nb) for i in range(3)); nxt[y][x] = True
                done = nxt
        up = out
    return up
filled_sky = inpaint(base, keep)
skyim = Image.composite(filled_sky, base, big.filter(ImageFilter.GaussianBlur(3)))
ia = ImageChops.lighter(region, obj).filter(ImageFilter.GaussianBlur(0.6))
islim.putalpha(ia)
# 海那張：前景減掉島；最下面多補 40 列（往上起伏時底下不會露空）
sa = ImageChops.subtract(land, isl)                       # 黑白相減再柔邊（先柔再減，燈塔邊緣會留一圈淡淡的殘影跟著浪動）
ImageDraw.Draw(sa).rectangle((0, 0, W, 600), fill=0)     # 海只在 y 600 以下
sa = sa.filter(ImageFilter.GaussianBlur(0.6))
# 兩道浪之間，前景是從 y 800 一刀切下去的 ⇒ 海起伏時這條切口會變成一條橫線跟著跑（同日使用者：「海浪有線」）。
#   那些「只因為 y 800 以下才算前景」的點，在 800～830 之間慢慢淡入；底下的遠景是補過的平順顏色
sap = sa.load()
FEATHER = 30
for y in range(800, 800 + FEATHER):
    f = (y - 800 + 0.5) / FEATHER
    for x in range(W):
        if sky1[y * W + x] and sap[x, y]: sap[x, y] = round(sap[x, y] * f)
seaim = derained.copy(); seaim.putalpha(sa)
EXT = 40
sea2 = Image.new('RGBA', (W, H + EXT)); sea2.paste(seaim, (0, 0))
sea2.paste(seaim.crop((0, H - EXT, W, H)).transpose(Image.FLIP_TOP_BOTTOM), (0, H))

skyim.save(out + '/sky.webp', quality=90)
# 小圖只留有東西的那一框（左上角的位置記在 STORM.island／STORM.sea／STORM.beam）
ib = ia.getbbox(); islim.crop(ib).save(out + '/island.webp', quality=90)
sb = sea2.getchannel('A').getbbox(); sea2.crop(sb).save(out + '/sea.webp', quality=90)
bb = beam.convert('L').point(lambda v: 255 if v > 2 else 0).getbbox(); beam.crop(bb).save(out + '/beam.webp', quality=92)
print('island at', ib[:2], 'sea at', sb[:2], 'beam at', bb[:2])
chk = skyim.copy(); chk.paste(islim, (0, 0), islim); chk.paste(seaim, (0, 0), seaim); chk = ImageChops.add(chk, beam); chk.save(out + '/_check.png')
isl.save(out + '/_island.png'); region.save(out + '/_region.png')
json.dump({'W0': W0, 'beam_color': beam_c, 'glow_color': glow_c, 'island': ib[:2], 'sea': sb[:2], 'beam': bb[:2]}, open(out + '/storm.json', 'w'))
print('W0', W0, 'beam', beam_c, 'glow', glow_c)
