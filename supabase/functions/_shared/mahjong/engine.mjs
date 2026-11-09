/* ============================================================
   台灣十六張麻將 · 牌局引擎（線上好友房，2026-11-09 開始寫）
   📄 規格：docs/03-會員App與社交/線上好友房.md（規則都從那裡來，改規則先改那份）

   · 純函式、沒有任何相依：Deno（Edge Function）與 Node（測試）都能直接 import
   · 🔴 **只有後端跑這一份**：手機不算規則，只畫 viewFor() 給的畫面與可以按的按鈕
     （同硬規則 5.8：前端只送意圖。兩份規則一定會漂）
   · 狀態是一個可以整包存進 jsonb 的物件；每一個動作 act(st, seat, action) 回傳新的狀態，不改舊的
   · 台數與互斥一律讀牌型主檔（scoring_patterns，建局時放進 st.cat），這裡不寫死任何台數
   · 牌面代碼照 docs/10-牌譜與AI辨識/牌面編碼對照表.md：1m–9m、1p–9p、1t–9t、E0 S0 W0 N0、C0 F0 B0、H1–H8

   座位 0–3，(s + 1) % 4 是下家。風位：莊家是東，往下家依序南西北。
   ============================================================ */

/* ── 牌 ─────────────────────────────────────────────────────── */

const NUMS = ['1', '2', '3', '4', '5', '6', '7', '8', '9']
export const KIND_CODES = [
  ...NUMS.map((n) => n + 'm'), ...NUMS.map((n) => n + 'p'), ...NUMS.map((n) => n + 't'),
  'E0', 'S0', 'W0', 'N0', 'C0', 'F0', 'B0',
]
/* 春夏秋冬 H1–H4、梅蘭竹菊 H5–H8；東位的正花是 H1、H5，南位 H2、H6，以此類推 */
export const FLOWER_CODES = ['H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'H7', 'H8']
const IDX = Object.fromEntries(KIND_CODES.map((c, i) => [c, i]))
export const isFlower = (c) => c[0] === 'H'
const kindOf = (c) => IDX[c]
const isHonor = (k) => k >= 27
const isWind = (k) => k >= 27 && k <= 30
const isDragon = (k) => k >= 31
const suitOf = (k) => (k < 27 ? Math.floor(k / 9) : 3)
const rankOf = (k) => k % 9

/* 鐵七敦：最後 14 張不摸，牌山剩 14 張就流局（店內「桌上規則及禮儀」） */
export const KEEP = 14
export const SETS = 5        // 十六張：五組 ＋ 一對
const MIGI_TURNS = 2         // 前八張以內、莊家無第三手 ⇒ 每一家只有自己的前兩手能喊
const RED_DICE = [1, 4]      // 骰子的一點、四點是紅色（全紅）

/* 可以重現的亂數：同一個 seed 一定洗出同一副牌（牌譜、除錯用） */
function rng(seed) {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) | 0
    let t = Math.imul(a ^ (a >>> 15), 1 | a)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

export function counts(tiles) {
  const c = new Array(34).fill(0)
  for (const t of tiles) if (!isFlower(t)) c[kindOf(t)]++
  return c
}
const sum = (c) => c.reduce((a, b) => a + b, 0)

export function sortTiles(tiles) {
  const ord = (t) => (isFlower(t) ? 100 + Number(t[1]) : kindOf(t))
  return [...tiles].sort((a, b) => ord(a) - ord(b))
}

/* ── 胡牌判斷 ──────────────────────────────────────────────── */

function setsOk(c, n) {
  if (n === 0) return c.every((x) => x === 0)
  const i = c.findIndex((x) => x > 0)
  if (i < 0) return false
  if (c[i] >= 3) { c[i] -= 3; const ok = setsOk(c, n - 1); c[i] += 3; if (ok) return true }
  if (i < 27 && rankOf(i) <= 6 && c[i + 1] > 0 && c[i + 2] > 0) {
    c[i]--; c[i + 1]--; c[i + 2]--
    const ok = setsOk(c, n - 1)
    c[i]++; c[i + 1]++; c[i + 2]++
    if (ok) return true
  }
  return false
}

/* c 是手上（不含已經吃碰槓出去的）牌的張數，n 是還要湊幾組 */
export function canWin(c, n) {
  if (sum(c) !== 3 * n + 2) return false
  for (let k = 0; k < 34; k++) {
    if (c[k] >= 2) { c[k] -= 2; const ok = setsOk(c, n); c[k] += 2; if (ok) return true }
  }
  return false
}

/* 聽哪幾種牌（c 是 3n＋1 張）。自己手上已經四張的那一種不算 */
export function waits(c, n) {
  const out = []
  for (let k = 0; k < 34; k++) {
    if (c[k] >= 4) continue
    c[k]++
    if (canWin(c, n)) out.push(k)
    c[k]--
  }
  return out
}

/* 所有拆法（算台時挑最多台的那一種） */
function allSets(c, n, acc, out) {
  if (n === 0) { if (c.every((x) => x === 0)) out.push(acc.slice()); return }
  const i = c.findIndex((x) => x > 0)
  if (i < 0) return
  if (c[i] >= 3) { c[i] -= 3; acc.push({ t: 'pung', k: i }); allSets(c, n - 1, acc, out); acc.pop(); c[i] += 3 }
  if (i < 27 && rankOf(i) <= 6 && c[i + 1] > 0 && c[i + 2] > 0) {
    c[i]--; c[i + 1]--; c[i + 2]--
    acc.push({ t: 'chow', k: i }); allSets(c, n - 1, acc, out); acc.pop()
    c[i]++; c[i + 1]++; c[i + 2]++
  }
}
export function decompositions(c, n) {
  const out = []
  for (let k = 0; k < 34; k++) {
    if (c[k] < 2) continue
    c[k] -= 2
    const sets = []
    allSets(c, n, [], sets)
    c[k] += 2
    for (const s of sets) out.push({ pair: k, sets: s })
  }
  return out
}

/* ── 建局 ──────────────────────────────────────────────────── */

/* cat：牌型主檔 [{ code, tai, max_count, conflicts }]（只放啟用中的）
   base／unit：底與每台的積分；dealer／ren：莊家座位與連莊數（上一局的 result.next） */
export function newGame({ seed, flower = false, dealer = 0, ren = 0, base = 0, unit = 0, cat = [] }) {
  const r = rng(seed)
  const wall = []
  for (const c of KIND_CODES) for (let i = 0; i < 4; i++) wall.push(c)
  if (flower) wall.push(...FLOWER_CODES)
  for (let i = wall.length - 1; i > 0; i--) { const j = Math.floor(r() * (i + 1)); [wall[i], wall[j]] = [wall[j], wall[i]] }
  const dice = [0, 0, 0].map(() => 1 + Math.floor(r() * 6))

  const st = {
    v: 1, seed, flower, dealer, ren, base, unit, dice,
    cat: cat.map((p) => ({ code: p.code, tai: p.tai, max_count: p.max_count || 1, conflicts: p.conflicts || [] })),
    wall, hands: [[], [], [], []], melds: [[], [], [], []], flowers: [[], [], [], []], discards: [[], [], [], []],
    turn: dealer, phase: 'deal', drawn: null, src: null, last: false,
    turns: [0, 0, 0, 0], called: false, migi: [false, false, false, false], yan: [false, false, false, false],
    claim: null, result: null, log: [{ e: 'start', dealer, ren, dice }],
    baozi: 1,   // 豹子倍數：1 ＝ 沒有或放棄、2、3（莊家開局選的）
  }
  /* 發牌：每家 16 張，莊家多一張（不用摸，第一手直接打） */
  for (let i = 0; i < 16; i++) for (let k = 0; k < 4; k++) st.hands[(dealer + k) % 4].push(st.wall.shift())
  st.hands[dealer].push(st.wall.shift())
  /* 補花：從莊家開始，花放到桌上、從牌尾補 */
  for (let k = 0; k < 4 && st.phase === 'deal'; k++) {
    const s = (dealer + k) % 4
    while (st.phase === 'deal' && st.hands[s].some(isFlower)) {
      const f = st.hands[s].find(isFlower)
      st.hands[s].splice(st.hands[s].indexOf(f), 1)
      takeFlower(st, s, f)
      if (st.phase !== 'deal') break
      if (st.wall.length <= KEEP) { endDraw(st); break }
      st.hands[s].push(st.wall.pop())
    }
  }
  if (st.phase === 'deal') {
    st.turn = dealer; st.src = 'deal'
    /* 豹子（三顆骰子一樣）：開局先由莊家決定這一局 ×2、×3 或放棄，選完才開始打（2026-11-09 使用者） */
    st.phase = dice[0] === dice[1] && dice[1] === dice[2] ? 'baozi' : 'discard'
  }
  return st
}

/* 拿到一張花：八張全到手 ⇒ 八仙過海；別家已經有七張、自己拿到第八張 ⇒ 那一家七搶一 */
function takeFlower(st, s, f) {
  st.flowers[s].push(f)
  st.log.push({ e: 'flower', s, tile: f })
  if (st.flowers[s].length === 8) { win(st, s, { kind: 'baxian' }); return }
  const seven = [0, 1, 2, 3].find((o) => o !== s && st.flowers[o].length === 7)
  if (seven !== undefined && st.flowers[s].length === 1) win(st, seven, { kind: 'qiqiangyi', from: s, tile: f })
}

/* 摸牌：src ＝ wall（正常）／kong（槓之後從牌尾補）。花一樣從牌尾補，但「是不是槓上」跟著原本那一張 */
function drawFor(st, s, src) {
  if (st.wall.length <= KEEP) { endDraw(st); return }
  const t = src === 'wall' ? st.wall.shift() : st.wall.pop()
  st.turn = s
  if (isFlower(t)) {
    takeFlower(st, s, t)
    if (st.phase === 'over') return
    drawFor(st, s, src === 'wall' ? 'flower' : src)
    return
  }
  st.hands[s].push(t)
  st.drawn = t
  st.src = src
  st.last = st.wall.length === KEEP          // 海底：這一張之後就沒得摸了
  st.phase = 'discard'
  st.claim = null
  st.log.push({ e: 'draw', s, tile: t, src })
  if (st.yan[s]) autoAfterYan(st, s)
}

/* 眼牌的人：能自摸就自動胡，不然摸什麼打什麼 */
function autoAfterYan(st, s) {
  if (canWin(counts(st.hands[s]), SETS - st.melds[s].length)) { win(st, s, { kind: 'tsumo', tile: st.drawn }); return }
  doDiscard(st, s, st.drawn, {})
}

function endDraw(st) {
  st.phase = 'over'
  st.claim = null
  st.result = { type: 'draw', payments: [0, 0, 0, 0], next: { dealer: st.dealer, ren: st.ren + 1 } }
  st.log.push({ e: 'end', type: 'draw' })
}

/* ── 動作 ──────────────────────────────────────────────────── */

const fail = (st, error) => ({ ok: false, error, st })

/* 回傳 { ok, st, error }。st 是新物件，舊的不動。
   出牌階段（輪到的人）：{ type: 'discard', tile, migi?, yan? }／{ type: 'tsumo' }／{ type: 'kong', tile }
   搶牌階段（有選項的人）：{ type: 'hu' }／{ type: 'pong' }／{ type: 'kong' }／{ type: 'chi', tiles: [a, b] }／{ type: 'pass' } */
export function act(st0, seat, a) {
  const st = structuredClone(st0)
  if (st.phase === 'over') return fail(st0, 'game_over')
  if (st.phase === 'baozi') {
    if (seat !== st.dealer) return fail(st0, 'not_your_turn')
    if (a.type !== 'baozi' || ![1, 2, 3].includes(a.mult)) return fail(st0, 'bad_action')
    st.baozi = a.mult
    st.log.push({ e: 'baozi', s: seat, mult: a.mult })
    st.phase = 'discard'
    return { ok: true, st }
  }
  if (st.phase === 'discard') {
    if (seat !== st.turn) return fail(st0, 'not_your_turn')
    if (a.type === 'discard') {
      const h = st.hands[seat]
      if (!h.includes(a.tile)) return fail(st0, 'no_such_tile')
      if (st.yan[seat] && a.tile !== st.drawn) return fail(st0, 'locked')
      if (a.migi && !migiOk(st, seat, a.tile)) return fail(st0, 'migi_not_allowed')
      if (a.yan && !yanOk(st, seat, a.tile)) return fail(st0, 'yan_not_allowed')
      doDiscard(st, seat, a.tile, a)
      return { ok: true, st }
    }
    if (a.type === 'tsumo') {
      if (!canWin(counts(st.hands[seat]), SETS - st.melds[seat].length)) return fail(st0, 'not_winning')
      win(st, seat, { kind: 'tsumo', tile: st.drawn })
      return { ok: true, st }
    }
    if (a.type === 'kong') {
      if (st.yan[seat]) return fail(st0, 'locked')
      if (st.wall.length <= KEEP) return fail(st0, 'wall_empty')
      const k = kindOf(a.tile)
      const c = counts(st.hands[seat])
      if (c[k] === 4) {                                   // 暗槓（不算鳴牌）
        removeN(st.hands[seat], a.tile, 4)
        st.melds[seat].push({ t: 'ckong', tiles: [a.tile, a.tile, a.tile, a.tile], from: null })
        st.log.push({ e: 'ckong', s: seat, tile: a.tile })
        st.drawn = null
        drawFor(st, seat, 'kong')
        return { ok: true, st }
      }
      const m = st.melds[seat].find((x) => x.t === 'pong' && x.tiles[0] === a.tile)
      if (m && c[k] >= 1) {                               // 加槓：別家可以搶槓
        removeN(st.hands[seat], a.tile, 1)
        st.drawn = null
        openClaim(st, seat, a.tile, 'rob')
        return { ok: true, st }
      }
      return fail(st0, 'cannot_kong')
    }
    return fail(st0, 'bad_action')
  }
  if (st.phase === 'claim') {
    const cl = st.claim
    const opts = cl.options[seat]
    if (!opts) return fail(st0, 'no_options')
    if (cl.resp[seat]) return fail(st0, 'already_responded')
    if (a.type === 'pass') cl.resp[seat] = { type: 'pass' }
    else if (a.type === 'hu' && opts.hu) cl.resp[seat] = { type: 'hu' }
    else if (a.type === 'pong' && opts.pong) cl.resp[seat] = { type: 'pong' }
    else if (a.type === 'kong' && opts.kong) cl.resp[seat] = { type: 'kong' }
    else if (a.type === 'chi' && opts.chi && opts.chi.some((p) => sameTiles(p, a.tiles))) cl.resp[seat] = { type: 'chi', tiles: a.tiles }
    else return fail(st0, 'bad_action')
    resolveClaim(st)
    return { ok: true, st }
  }
  return fail(st0, 'bad_phase')
}

const sameTiles = (a, b) => Array.isArray(b) && a.length === b.length && sortTiles(a).join() === sortTiles(b).join()
function removeN(h, t, n) { for (let i = 0; i < n; i++) h.splice(h.indexOf(t), 1) }

/* 打牌之後的手（3n＋1 張）聽不聽 */
function tenpaiAfter(st, s, tile) {
  const h = st.hands[s].slice()
  h.splice(h.indexOf(tile), 1)
  return waits(counts(h), SETS - st.melds[s].length).length > 0
}
/* MIGI：四家都還沒有人鳴牌、自己的前兩手、還沒喊過，而且打這張之後聽牌 */
export function migiOk(st, s, tile) {
  return !st.called && st.turns[s] < MIGI_TURNS && !st.migi[s] && st.hands[s].includes(tile) && tenpaiAfter(st, s, tile)
}
/* 眼牌：還沒眼過，打這張之後聽牌 */
export function yanOk(st, s, tile) {
  return !st.yan[s] && st.hands[s].includes(tile) && tenpaiAfter(st, s, tile)
}

function doDiscard(st, s, tile, a) {
  st.hands[s].splice(st.hands[s].indexOf(tile), 1)
  st.discards[s].push(tile)
  st.turns[s]++
  st.drawn = null
  if (a.migi) { st.migi[s] = true; st.log.push({ e: 'migi', s }) }
  if (a.yan) { st.yan[s] = true; st.log.push({ e: 'yan', s }) }
  st.log.push({ e: 'discard', s, tile })
  openClaim(st, s, tile, 'discard')
}

/* 別家能不能要這張：胡（任何一家）、碰／明槓（任何一家）、吃（只有下家）。眼牌的人只能胡、而且自動胡 */
function openClaim(st, from, tile, kind) {
  const options = {}
  const resp = {}
  const k = kindOf(tile)
  for (let d = 1; d <= 3; d++) {
    const o = (from + d) % 4
    const c = counts(st.hands[o])
    const n = SETS - st.melds[o].length
    const op = {}
    c[k]++
    if (canWin(c, n)) op.hu = true
    c[k]--
    if (kind === 'discard' && !st.yan[o]) {
      if (c[k] >= 2) op.pong = true
      if (c[k] >= 3 && st.wall.length > KEEP) op.kong = true
      if (d === 1 && !isHonor(k)) {
        const chi = []
        const r = rankOf(k)
        const tk = (x) => KIND_CODES[x]
        if (r >= 2 && c[k - 2] && c[k - 1]) chi.push([tk(k - 2), tk(k - 1)])
        if (r >= 1 && r <= 7 && c[k - 1] && c[k + 1]) chi.push([tk(k - 1), tk(k + 1)])
        if (r <= 6 && c[k + 1] && c[k + 2]) chi.push([tk(k + 1), tk(k + 2)])
        if (chi.length) op.chi = chi
      }
    }
    if (Object.keys(op).length) {
      options[o] = op
      if (st.yan[o]) resp[o] = op.hu ? { type: 'hu' } : { type: 'pass' }
    }
  }
  st.claim = { from, tile, kind, options, resp }
  st.phase = 'claim'
  resolveClaim(st)
}

/* 等每一個有選項的人都回應了才決定。順位胡：從打牌的人往下數，最近的那一家胡；沒人胡才輪到碰槓，再來才是吃 */
function resolveClaim(st) {
  const cl = st.claim
  const seats = Object.keys(cl.options).map(Number)
  if (seats.some((o) => !cl.resp[o])) return
  const order = [1, 2, 3].map((d) => (cl.from + d) % 4)
  const hu = order.find((o) => cl.resp[o] && cl.resp[o].type === 'hu')
  if (hu !== undefined) {
    if (cl.kind === 'discard') st.discards[cl.from].pop()   // 胡走的那張不留在牌河（加槓那張本來就不在牌河）
    st.hands[hu].push(cl.tile)
    win(st, hu, { kind: cl.kind === 'rob' ? 'rob' : 'ron', from: cl.from, tile: cl.tile })
    return
  }
  if (cl.kind === 'rob') {                                 // 沒人搶槓 ⇒ 加槓成立，從牌尾補
    const m = st.melds[cl.from].find((x) => x.t === 'pong' && x.tiles[0] === cl.tile)
    m.t = 'akong'; m.tiles.push(cl.tile)
    st.log.push({ e: 'akong', s: cl.from, tile: cl.tile })
    st.claim = null
    drawFor(st, cl.from, 'kong')
    return
  }
  const take = (o) => { st.discards[cl.from].pop(); st.called = true; st.claim = null; st.turn = o; st.drawn = null }
  const pk = order.find((o) => cl.resp[o] && (cl.resp[o].type === 'pong' || cl.resp[o].type === 'kong'))
  if (pk !== undefined) {
    const isKong = cl.resp[pk].type === 'kong'
    removeN(st.hands[pk], cl.tile, isKong ? 3 : 2)
    st.melds[pk].push({ t: isKong ? 'mkong' : 'pong', tiles: new Array(isKong ? 4 : 3).fill(cl.tile), from: cl.from })
    st.log.push({ e: isKong ? 'mkong' : 'pong', s: pk, tile: cl.tile, from: cl.from })
    take(pk)
    if (isKong) drawFor(st, pk, 'kong')
    else st.phase = 'discard'
    return
  }
  const ch = order.find((o) => cl.resp[o] && cl.resp[o].type === 'chi')
  if (ch !== undefined) {
    const two = cl.resp[ch].tiles
    for (const t of two) removeN(st.hands[ch], t, 1)
    st.melds[ch].push({ t: 'chi', tiles: sortTiles([...two, cl.tile]), from: cl.from })
    st.log.push({ e: 'chi', s: ch, tiles: [...two], tile: cl.tile, from: cl.from })
    take(ch)
    st.phase = 'discard'
    return
  }
  st.claim = null
  drawFor(st, (cl.from + 1) % 4, 'wall')
}

/* ── 算台與結算 ────────────────────────────────────────────── */

/* ctx.kind：tsumo／ron／rob（搶槓）／baxian（八仙過海）／qiqiangyi（七搶一） */
function win(st, w, ctx) {
  const score = scoreWin(st, w, ctx)
  const tsumoLike = ctx.kind === 'tsumo' || ctx.kind === 'baxian'
  const payers = tsumoLike ? [0, 1, 2, 3].filter((x) => x !== w) : [ctx.from]
  const pay = [0, 0, 0, 0]
  const dx = (x) => (x === st.dealer || w === st.dealer ? 1 + 2 * st.ren : 0)   // 莊家台 2N＋1（同計分板 rules.js）
  for (const x of payers) {
    const amt = st.base * score.mult + st.unit * (score.tai + score.mult * dx(x))
    pay[x] -= amt; pay[w] += amt
  }
  /* 眼牌沒胡：付 1 台給胡牌的人、不算底（流局不用付，所以只在這裡） */
  const yanPaid = []
  for (let x = 0; x < 4; x++) {
    if (x !== w && st.yan[x]) { pay[x] -= st.unit; pay[w] += st.unit; yanPaid.push(x) }
  }
  const stay = w === st.dealer
  st.result = {
    type: tsumoLike ? 'tsumo' : 'ron', kind: ctx.kind, winner: w, from: tsumoLike ? null : ctx.from, tile: ctx.tile || null,
    patterns: score.patterns, tai: score.tai, mult: score.mult, dealerTai: 1 + 2 * st.ren, yanPaid, payments: pay,
    next: stay ? { dealer: st.dealer, ren: st.ren + 1 } : { dealer: (st.dealer + 1) % 4, ren: 0 },
  }
  st.phase = 'over'
  st.claim = null
  st.log.push({ e: 'end', type: st.result.type, winner: w, from: st.result.from })
}

/* 胡牌那一手值幾台：所有拆法、胡的那張放在哪一組都試一次，取最多台的（台麻慣例：對胡牌的人最有利的算法） */
export function scoreWin(st, w, ctx) {
  const melds = st.melds[w]
  const open = melds.filter((m) => m.t !== 'ckong')
  const fl = st.flowers[w]
  const seatWind = (w - st.dealer + 4) % 4
  const flowerPats = []
  if (st.flower) {
    const zh = fl.filter((f) => Number(f[1]) === seatWind + 1 || Number(f[1]) === seatWind + 5).length
    if (zh) flowerPats.push(['zhenghua', zh])
    const hg = [[1, 2, 3, 4], [5, 6, 7, 8]].filter((g) => g.every((n) => fl.includes('H' + n))).length
    if (hg) flowerPats.push(['huagang', hg])
  }
  const diceRed = st.dice.every((d) => RED_DICE.includes(d))
  /* 骰龜：三顆骰子是順子（1-2-3、2-3-4、3-4-5、4-5-6，順序不拘；2026-11-09 使用者） */
  const ds = [...st.dice].sort((a, b) => a - b)
  const diceRun = ds[1] === ds[0] + 1 && ds[2] === ds[1] + 1
  /* 豹子：三顆骰子一樣，莊家開局選 ×2／×3／放棄（st.baozi）⇒ 整筆乘（含底與莊家台，同計分板 rules.js）。
     主檔 baozi 的次數 ＝ 倍數 − 1（同計分板按 1 次 ×2、按 2 次 ×3）；不管誰胡都算（2026-11-09 使用者） */
  const baoziN = (st.baozi || 1) - 1
  const common = (add) => {
    if (st.migi[w]) add('migi')
    if (diceRed) add('quanhong')
    if (diceRun) add('shaigui')
    if (baoziN) add('baozi', baoziN)
    for (const [c, n] of flowerPats) add(c, n)
  }

  if (ctx.kind === 'baxian' || ctx.kind === 'qiqiangyi') {
    return finalize(st, (add) => { add(ctx.kind); if (st.migi[w]) add('migi'); if (diceRed) add('quanhong'); if (diceRun) add('shaigui'); if (baoziN) add('baozi', baoziN) })
  }

  const tsumo = ctx.kind === 'tsumo'
  const c = counts(st.hands[w])
  const n = SETS - melds.length
  const tk = kindOf(ctx.tile)
  const before = c.slice(); before[tk]--
  const w8 = waits(before, n)
  const tianhu = tsumo && w === st.dealer && st.turns.every((x) => x === 0) && !st.called && melds.length === 0
  const meldGroups = melds.map((m) => ({ t: m.t === 'chi' ? 'chow' : 'pung', k: kindOf(m.tiles[0]), conc: m.t === 'ckong' }))

  let best = null
  for (const d of decompositions(c, n)) {
    const handGroups = d.sets.map((s) => ({ ...s, conc: true }))
    const groups = [...handGroups, ...meldGroups]
    /* 胡的那一張可能在哪一組：手上那幾組裡含這種牌的，或是那一對 */
    const spots = handGroups.filter((g) => (g.t === 'pung' ? g.k === tk : tk >= g.k && tk <= g.k + 2))
    const cands = [...spots, ...(d.pair === tk ? ['pair'] : [])]
    for (const spot of cands) {
      const r = finalize(st, (add) => {
        const pungs = groups.filter((g) => g.t === 'pung')
        const anke = pungs.filter((g) => g.conc && !(g === spot && !tsumo)).length   // 胡別人那張湊成的刻子不算暗刻
        const kinds = [...groups.flatMap((g) => (g.t === 'chow' ? [g.k, g.k + 1, g.k + 2] : [g.k])), d.pair]
        const honors = kinds.some(isHonor)
        const suits = new Set(kinds.filter((k) => !isHonor(k)).map(suitOf))
        const winds = pungs.filter((g) => isWind(g.k)).length
        const dragons = pungs.filter((g) => isDragon(g.k)).length

        if (tsumo) add(open.length === 0 ? 'menqing_tsumo' : 'zimo')
        else {
          if (open.length === 0) add('menqing')
          if (open.length === SETS) add('quanqiuren')
        }
        if (w8.length === 1) add('duting')                          // 正獨聽才有台
        if (ctx.kind === 'rob') add('qianggang')
        if (tsumo && st.src === 'kong') add('gangshang')
        if (tsumo && st.last) add('haidi')
        const twoSided = spot !== 'pair' && spot.t === 'chow' &&
          ((tk === spot.k && rankOf(spot.k) <= 5) || (tk === spot.k + 2 && rankOf(spot.k) >= 1))
        if (!tsumo && pungs.length === 0 && !honors && !(st.flower && fl.length) && w8.length >= 2 && twoSided) add('pinghu')
        if (pungs.length === SETS) add('pengpenghu')
        if (anke >= 5) add('wuanke'); else if (anke === 4) add('sianke'); else if (anke === 3) add('sananke')
        if (dragons === 3) add('dasanyuan')
        else if (dragons === 2 && isDragon(d.pair)) add('xiaosanyuan')
        else if (dragons) add('triplet_dragon', dragons)
        if (winds === 4) add('dasixi')
        else if (winds === 3 && isWind(d.pair)) add('xiaosixi')
        else if (winds) add('triplet_wind', winds)
        if (suits.size === 0) add('ziyise')
        else if (suits.size === 1) add(honors ? 'hunyise' : 'qingyise')
        if (tianhu) add('tianhu')
        common(add)
      })
      if (!best || r.tai > best.tai) best = r
    }
  }
  return best || finalize(st, common)
}

/* 照主檔收尾：主檔沒有的（停用的）不算；次數不超過上限；互斥的兩個只留台數高的（雙向看 conflicts） */
function finalize(st, fill) {
  const raw = {}
  fill((code, n = 1) => { raw[code] = (raw[code] || 0) + n })
  const cat = Object.fromEntries(st.cat.map((p) => [p.code, p]))
  const list = Object.entries(raw)
    .filter(([code]) => cat[code])
    .map(([code, n]) => { const p = cat[code]; const m = Math.min(n, p.max_count || 1); return { code, n: m, tai: p.tai * m } })
    .sort((a, b) => b.tai - a.tai)
  const kept = []
  const clash = (a, b) => (cat[a].conflicts || []).includes(b) || (cat[b].conflicts || []).includes(a)
  for (const p of list) if (!kept.some((k) => clash(k.code, p.code))) kept.push(p)
  const baozi = kept.find((p) => p.code === 'baozi')
  const mult = 1 + (baozi ? baozi.n : 0)
  return { patterns: kept, tai: kept.reduce((t, p) => t + p.tai, 0) * mult, mult }
}

/* ── 給手機看的（每一家只拿到自己看得到的那一份）─────────────── */

/* 輪到誰、能按什麼。出牌時附「打哪張會聽、聽什麼」當提示 */
export function optionsFor(st, s) {
  if (st.phase === 'baozi') return s === st.dealer ? { baozi: [2, 3, 1] } : null   // 1 ＝ 放棄
  if (st.phase === 'discard' && st.turn === s) {
    const h = st.hands[s]
    const n = SETS - st.melds[s].length
    const c = counts(h)
    const o = { discard: true, locked: st.yan[s], tsumo: canWin(c, n) }
    if (!st.yan[s] && st.wall.length > KEEP) {
      const kongs = []
      for (let k = 0; k < 34; k++) {
        if (c[k] === 4) kongs.push(KIND_CODES[k])
        else if (c[k] >= 1 && st.melds[s].some((m) => m.t === 'pong' && kindOf(m.tiles[0]) === k)) kongs.push(KIND_CODES[k])
      }
      if (kongs.length) o.kongs = kongs
    }
    if (!st.yan[s]) {
      const listen = {}
      for (const t of new Set(h)) {
        const hh = h.slice(); hh.splice(hh.indexOf(t), 1)
        const wt = waits(counts(hh), n)
        if (wt.length) listen[t] = wt.map((k) => KIND_CODES[k])
      }
      if (Object.keys(listen).length) {
        o.listen = listen
        o.migi = Object.keys(listen).filter((t) => migiOk(st, s, t))
        o.yan = Object.keys(listen)
      }
    }
    return o
  }
  if (st.phase === 'claim' && st.claim.options[s] && !st.claim.resp[s]) return { claim: st.claim.options[s], tile: st.claim.tile }
  return null
}

/* 逾時時電腦替他做什麼：出牌就打剛摸的（沒有就打最後一張），搶牌就跳過 */
export function autoAction(st, s) {
  if (st.phase === 'baozi' && s === st.dealer) return { type: 'baozi', mult: 1 }   // 莊家沒選 ⇒ 當作放棄（不替他加重輸贏）
  if (st.phase === 'discard' && st.turn === s) return { type: 'discard', tile: st.drawn || st.hands[s][st.hands[s].length - 1] }
  if (st.phase === 'claim' && st.claim.options[s] && !st.claim.resp[s]) return { type: 'pass' }
  return null
}

/* 🔴 這一份才可以送給 s 那一家的手機：別家的手牌只給張數；暗槓蓋著。
   眼牌的人看得到別家手牌、暗槓與牌山；牌局結束全部攤開。seed 永遠不給（拿到就算得出整副牌山） */
export function viewFor(st, s) {
  const see = st.yan[s] || st.phase === 'over'
  return {
    seat: s, dealer: st.dealer, ren: st.ren, turn: st.turn, phase: st.phase, flower: st.flower, dice: st.dice, baozi: st.baozi,
    wallLeft: Math.max(0, st.wall.length - KEEP),
    wall: st.yan[s] && st.phase !== 'over' ? st.wall.slice(0, st.wall.length - KEEP) : null,
    players: [0, 1, 2, 3].map((x) => ({
      count: st.hands[x].length,
      hand: x === s || see ? sortTiles(st.hands[x]) : null,
      melds: st.melds[x].map((m) => (m.t === 'ckong' && x !== s && !see ? { t: 'ckong', tiles: null } : m)),
      flowers: st.flowers[x], discards: st.discards[x], migi: st.migi[x], yan: st.yan[x],
    })),
    drawn: st.turn === s ? st.drawn : null,
    claim: st.claim ? { from: st.claim.from, tile: st.claim.tile, kind: st.claim.kind } : null,
    options: optionsFor(st, s),
    result: st.result,
  }
}
