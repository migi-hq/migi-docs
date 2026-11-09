/* 牌局引擎測試（零相依）：node supabase/functions/_shared/mahjong/engine.test.mjs
   CAT 是牌型主檔的測試副本（2026-11-09 線上 scoring_patterns 撈出來的台數與互斥；正式跑時引擎讀資料庫那一份） */
import assert from 'node:assert/strict'
import { newGame, act, canWin, waits, counts, scoreWin, viewFor, autoAction, optionsFor, KEEP, KIND_CODES } from './engine.mjs'

const CAT = [
  ['zimo', 1, 1, []], ['triplet_wind', 1, 3, ['xiaosixi', 'dasixi']], ['triplet_dragon', 1, 2, ['xiaosanyuan', 'dasanyuan']],
  ['duting', 1, 1, []], ['qianggang', 1, 1, []], ['menqing', 1, 1, ['menqing_tsumo', 'quanqiuren']], ['gangshang', 1, 1, []],
  ['haidi', 1, 1, []], ['pinghu', 2, 1, ['baxian', 'duting', 'huagang', 'pengpenghu', 'qiqiangyi', 'sananke', 'sianke', 'triplet_dragon', 'triplet_wind', 'wuanke', 'zhenghua', 'ziyise']],
  ['menqing_tsumo', 3, 1, ['menqing', 'zimo', 'quanqiuren']], ['quanqiuren', 2, 1, []], ['pengpenghu', 4, 1, []],
  ['sananke', 2, 1, ['sianke', 'wuanke']], ['sianke', 5, 1, ['wuanke']], ['wuanke', 8, 1, []],
  ['xiaosanyuan', 4, 1, ['dasanyuan']], ['dasanyuan', 8, 1, []], ['xiaosixi', 8, 1, ['dasixi']], ['dasixi', 16, 1, []],
  ['hunyise', 4, 1, ['qingyise']], ['qingyise', 8, 1, []], ['ziyise', 16, 1, ['hunyise', 'qingyise']],
  ['zhenghua', 1, 2, []], ['huagang', 2, 2, []], ['qiqiangyi', 8, 1, ['zhenghua', 'huagang', 'baxian']], ['baxian', 8, 1, ['zhenghua', 'huagang']],
  ['quanhong', 1, 1, []], ['shaigui', 2, 1, []], ['baozi', 0, 2, []],
  ['tianhu', 24, 1, ['duting', 'menqing', 'menqing_tsumo', 'pinghu', 'zimo']], ['migi', 8, 1, []],
].map(([code, tai, max_count, conflicts]) => ({ code, tai, max_count, conflicts }))

let pass = 0, fail = 0
const t = (name, fn) => { try { fn(); pass++ } catch (e) { fail++; console.log('🔴 ' + name + '\n   ' + e.message) } }
const tiles = (s) => s.trim().split(/\s+/)

/* 造一個「胡牌那一刻」的局面，直接算台（不經過發牌） */
function scene({ hand, melds = [], flowers = [], win, kind = 'ron', winner = 1, dealer = 0, ren = 0, flower = false, dice = [2, 3, 5], baozi = 1, src = 'wall', last = false, migi = false, called = false, turns = [1, 1, 1, 1] }) {
  const st = newGame({ seed: 1, cat: CAT, flower, dealer, ren, base: 50, unit: 20 })
  st.hands = [[], [], [], []]; st.melds = [[], [], [], []]; st.flowers = [[], [], [], []]
  st.hands[winner] = tiles(hand)
  st.melds[winner] = melds.map(([tt, ts]) => ({ t: tt, tiles: tiles(ts), from: tt === 'ckong' ? null : 2 }))
  st.flowers[winner] = flowers
  st.dice = dice; st.baozi = baozi; st.src = src; st.last = last; st.migi[winner] = migi; st.called = called; st.turns = turns
  if (kind === 'ron' || kind === 'rob') st.hands[winner].push(win)
  return scoreWin(st, winner, { kind, tile: win, from: 2 })
}
const codes = (r) => Object.fromEntries(r.patterns.map((p) => [p.code, p.n]))

/* ── 胡牌判斷 ── */
t('五組一對可以胡', () => assert.ok(canWin(counts(tiles('1m 2m 3m 4m 5m 6m 7m 8m 9m 1p 1p 1p 2t 3t 4t E0 E0')), 5)))
t('差一張不能胡', () => assert.ok(!canWin(counts(tiles('1m 2m 3m 4m 5m 6m 7m 8m 9m 1p 1p 1p 2t 3t 5t E0 E0')), 5)))
t('字牌不能組順子', () => assert.ok(!canWin(counts(tiles('E0 S0 W0 1m 2m 3m 4m 5m 6m 7m 8m 9m 1p 1p 1p C0 C0')), 5)))
t('聽兩面', () => assert.deepEqual(waits(counts(tiles('1m 2m 3m 4m 5m 6m 7m 8m 9m 1p 1p 1p 2t 3t E0 E0')), 5).map((k) => KIND_CODES[k]), ['1t', '4t']))
t('聽中洞只有一種', () => assert.deepEqual(waits(counts(tiles('1m 2m 3m 4m 5m 6m 7m 8m 9m 1p 1p 1p 2t 4t E0 E0')), 5).map((k) => KIND_CODES[k]), ['3t']))

/* ── 算台（照店內台數表） ── */
t('平胡：胡別人、全順子、無字、聽兩面 ⇒ 門清 1 ＋ 平胡 2 ＝ 3', () => {
  const r = scene({ hand: '1m 2m 3m 4m 5m 6m 7m 8m 9m 2p 3p 4p 2t 3t 5t 5t', win: '4t' })
  assert.deepEqual(codes(r), { pinghu: 1, menqing: 1 }); assert.equal(r.tai, 3)
})
t('自摸沒有平胡：門清自摸 3（已含自摸）', () => {
  const r = scene({ hand: '1m 2m 3m 4m 5m 6m 7m 8m 9m 2p 3p 4p 2t 3t 4t 5t 5t', win: '4t', kind: 'tsumo' })
  assert.deepEqual(codes(r), { menqing_tsumo: 1 }); assert.equal(r.tai, 3)
})
t('中洞沒有平胡，給獨聽 1', () => {
  const r = scene({ hand: '1m 2m 3m 4m 5m 6m 7m 8m 9m 2p 3p 4p 2t 4t 5t 5t', win: '3t' })
  assert.ok(!codes(r).pinghu); assert.equal(codes(r).duting, 1)
})
t('正獨聽才有台：邊張但還能胡別張就不算', () => {
  // 2t3t4t5t：單吊 5t 也能看成 3t4t5t ＋ 單吊 2t ⇒ 聽 2t、5t 兩種，胡 5t 不算獨聽
  const r = scene({ hand: '1m 2m 3m 4m 5m 6m 7m 8m 9m 1p 1p 1p 2t 3t 4t 5t', win: '5t' })
  assert.ok(!codes(r).duting)
  // 對照：1m2m 只聽 3m ⇒ 獨聽
  assert.equal(codes(scene({ hand: '1m 2m 4m 5m 6m 7m 8m 9m 1p 1p 1p 2t 3t 4t E0 E0', win: '3m' })).duting, 1)
})
t('有字牌的順子胡沒有平胡', () => {
  const r = scene({ hand: '1m 2m 3m 4m 5m 6m 7m 8m 9m 2p 3p 4p 2t 3t E0 E0', win: '4t' })
  assert.ok(!codes(r).pinghu)
})
t('碰碰胡＋三暗刻（胡別人那張湊成的刻子不算暗）', () => {
  const r = scene({ hand: '1m 1m 1m 5p 5p 5p 9t 9t 9t 2m 2m 2m E0 E0 C0 C0', melds: [], win: 'C0' })
  // 四組手上刻子，但 C0 是胡別人湊成的 ⇒ 暗刻 4（1m 5p 9t 2m）＋ C0 那組不算暗；E0 對子
  assert.equal(codes(r).pengpenghu, 1); assert.equal(codes(r).sianke, 1); assert.equal(codes(r).triplet_dragon, 1)
})
t('大三元 8，不另算中發白', () => {
  const r = scene({ hand: 'C0 C0 C0 F0 F0 F0 B0 B0 B0 1m 2m 3m 5p 6p 7p 9t', win: '9t' })
  assert.equal(codes(r).dasanyuan, 1); assert.ok(!codes(r).triplet_dragon)
})
t('小四喜 8：三組風刻＋風對子', () => {
  const r = scene({ hand: 'E0 E0 E0 S0 S0 S0 W0 W0 W0 N0 N0 1m 2m 3m 7p 8p', win: '9p' })
  assert.equal(codes(r).xiaosixi, 1); assert.ok(!codes(r).triplet_wind)
})
t('見字有台：東南西北每組 1', () => {
  const r = scene({ hand: 'E0 E0 E0 W0 W0 W0 1m 2m 3m 4m 5m 6m 7p 8p 9p 5t', win: '5t' })
  assert.equal(codes(r).triplet_wind, 2)
})
t('清一色 8／混一色 4／字一色 16', () => {
  assert.equal(codes(scene({ hand: '1m 1m 1m 2m 3m 4m 5m 6m 7m 7m 8m 9m 9m 9m 5m 5m', win: '5m' })).qingyise, 1)
  assert.equal(codes(scene({ hand: '1m 1m 1m 2m 3m 4m 5m 6m 7m E0 E0 E0 9m 9m 9m C0', win: 'C0' })).hunyise, 1)
  assert.equal(codes(scene({ hand: 'E0 E0 E0 S0 S0 S0 C0 C0 C0 F0 F0 F0 B0 B0 N0 N0', win: 'N0' })).ziyise, 1)
})
t('全求 2：五組都吃碰出去、單吊胡別人', () => {
  const r = scene({ hand: '5p', melds: [['chi', '1m 2m 3m'], ['pong', '7t 7t 7t'], ['chi', '4p 5p 6p'], ['pong', 'E0 E0 E0'], ['chi', '7m 8m 9m']], win: '5p', called: true })
  assert.equal(codes(r).quanqiuren, 1); assert.ok(!codes(r).menqing)
})
t('吃過牌的自摸：自摸 1（不是門清自摸）', () => {
  const r = scene({ hand: '1m 2m 3m 4m 5m 6m 2p 3p 4p 2t 3t 4t 5t 5t', melds: [['chi', '7m 8m 9m']], win: '4t', kind: 'tsumo', called: true })
  assert.equal(codes(r).zimo, 1); assert.ok(!codes(r).menqing_tsumo)
})
t('槓上開花、海底撈月', () => {
  assert.equal(codes(scene({ hand: '1m 2m 3m 4m 5m 6m 2p 3p 4p 2t 3t 4t 5t 5t', melds: [['ckong', '9p 9p 9p 9p']], win: '4t', kind: 'tsumo', src: 'kong' })).gangshang, 1)
  assert.equal(codes(scene({ hand: '1m 2m 3m 4m 5m 6m 7m 8m 9m 2p 3p 4p 2t 3t 4t 5t 5t', win: '4t', kind: 'tsumo', last: true })).haidi, 1)
})
t('MIGI 另外加 8 台、全紅 1（骰子都是一或四）', () => {
  const r = scene({ hand: '1m 2m 3m 4m 5m 6m 7m 8m 9m 2p 3p 4p 2t 3t 5t 5t', win: '4t', migi: true, dice: [1, 4, 4] })
  assert.equal(codes(r).migi, 1); assert.equal(codes(r).quanhong, 1); assert.equal(r.tai, 3 + 8 + 1)
})
t('骰龜 2：骰子是順子（順序不拘）；不是順子不算', () => {
  const H = { hand: '1m 2m 3m 4m 5m 6m 7m 8m 9m 2p 3p 4p 2t 3t 5t 5t', win: '4t' }
  for (const d of [[1, 2, 3], [4, 2, 3], [5, 3, 4], [6, 4, 5]]) assert.equal(codes(scene({ ...H, dice: d })).shaigui, 1, d.join())
  for (const d of [[1, 2, 4], [2, 2, 3], [6, 6, 6], [1, 3, 5]]) assert.ok(!codes(scene({ ...H, dice: d })).shaigui, d.join())
})
t('豹子：照莊家開局選的 ×2／×3／放棄', () => {
  const H = { hand: '1m 2m 3m 4m 5m 6m 7m 8m 9m 2p 3p 4p 2t 3t 5t 5t', win: '4t' }
  const r2 = scene({ ...H, dice: [6, 6, 6], baozi: 2 })
  assert.equal(codes(r2).baozi, 1); assert.equal(r2.mult, 2); assert.equal(r2.tai, 3 * 2)
  const r3 = scene({ ...H, dice: [6, 6, 6], baozi: 3 })
  assert.equal(codes(r3).baozi, 2); assert.equal(r3.mult, 3); assert.equal(r3.tai, 3 * 3)
  const r0 = scene({ ...H, dice: [6, 6, 6], baozi: 1 })               // 放棄
  assert.ok(!codes(r0).baozi); assert.equal(r0.mult, 1)
  const r1 = scene({ ...H, dice: [1, 1, 1], baozi: 2 })               // 1-1-1 同時是全紅與豹子
  assert.equal(codes(r1).quanhong, 1); assert.equal(r1.tai, (3 + 1) * 2)
})
t('擲出豹子：開局停在莊家選倍數，別人不能先打；沒擲出豹子直接開打', () => {
  let found = null, plain = null
  for (let s = 1; s < 3000 && (!found || !plain); s++) {
    const g = newGame({ seed: s, cat: CAT, dealer: 1 })
    if (g.phase === 'baozi' && !found) found = g
    if (g.phase === 'discard' && !plain) plain = g
  }
  assert.ok(found, '3000 個 seed 裡應該擲得出豹子')
  assert.equal(plain.phase, 'discard')
  assert.deepEqual(optionsFor(found, 1), { baozi: [2, 3, 1] }); assert.equal(optionsFor(found, 0), null)
  assert.equal(act(found, 0, { type: 'baozi', mult: 3 }).error, 'not_your_turn')
  assert.equal(act(found, 1, { type: 'discard', tile: found.hands[1][0] }).error, 'bad_action')
  const after = act(found, 1, { type: 'baozi', mult: 3 }).st
  assert.equal(after.baozi, 3); assert.equal(after.phase, 'discard')
  assert.deepEqual(autoAction(found, 1), { type: 'baozi', mult: 1 })     // 沒選 ⇒ 當作放棄
})
t('豹子的錢：(底 ＋ 台 ×（牌型 ＋ 莊家台）) × 2', () => {
  let st = newGame({ seed: 9, cat: CAT, dealer: 1, base: 50, unit: 20 })
  st.dice = [3, 3, 3]; st.baozi = 2
  st.hands[0] = tiles('1m 2m 3m 4m 5m 6m 7m 8m 9m 2p 3p 4p 2t 3t 5t 5t')
  st.hands[1] = tiles('4t 1p 2p 5p 6p 8p 9p 1t 7t 8t E0 S0 W0 N0 C0 F0 B0')
  st.turn = 1; st.phase = 'discard'
  st = act(st, 1, { type: 'discard', tile: '4t' }).st              // 莊家（1 號）放槍給 0 號
  for (const o of Object.keys(st.claim.options || {})) if (+o !== 0 && !st.claim.resp[o]) st = act(st, +o, { type: 'pass' }).st
  if (st.phase === 'claim') st = act(st, 0, { type: 'hu' }).st
  assert.equal(st.result.winner, 0)
  // 門清 1 ＋ 平胡 2 ＝ 3 台，×2 ＝ 6；莊家台 1 ×2 ＝ 2 ⇒ 50×2 ＋ 20×(6＋2) ＝ 260
  assert.equal(st.result.payments[1], -260)
})
t('天胡 24，不疊門清自摸', () => {
  const r = scene({ hand: '1m 2m 3m 4m 5m 6m 7m 8m 9m 2p 3p 4p 2t 3t 4t 5t 5t', win: '4t', kind: 'tsumo', winner: 0, dealer: 0, turns: [0, 0, 0, 0] })
  assert.equal(codes(r).tianhu, 1); assert.ok(!codes(r).menqing_tsumo); assert.ok(!codes(r).zimo)
})
t('有花：手上有花就沒有平胡；正花照風位', () => {
  const r = scene({ hand: '1m 2m 3m 4m 5m 6m 7m 8m 9m 2p 3p 4p 2t 3t 5t 5t', win: '4t', flower: true, flowers: ['H2', 'H6', 'H3'], winner: 1, dealer: 0 })
  assert.ok(!codes(r).pinghu); assert.equal(codes(r).zhenghua, 2)
})

/* ── 一整局：發牌、截胡、眼牌、MIGI、看得到什麼 ── */
t('發牌：莊 17、閒 16、牌山留到 14 張就流局', () => {
  const st = newGame({ seed: 7, cat: CAT, dealer: 2 })
  assert.deepEqual(st.hands.map((h) => h.length), [16, 16, 17, 16])
  assert.equal(st.turn, 2); assert.equal(st.phase, 'discard')
  assert.equal(st.wall.length, 136 - 65)
})
t('有花：發完牌手上沒有花，總數 144', () => {
  const st = newGame({ seed: 11, cat: CAT, flower: true })
  assert.ok(st.hands.every((h) => !h.some((x) => x[0] === 'H')))
  const total = st.wall.length + st.hands.flat().length + st.flowers.flat().length
  assert.equal(total, 144)
})
t('別家看不到我的手牌與牌山；seed 不給', () => {
  const st = newGame({ seed: 3, cat: CAT })
  const v = viewFor(st, 1)
  assert.equal(v.players[0].hand, null); assert.ok(Array.isArray(v.players[1].hand)); assert.equal(v.wall, null)
  assert.ok(!('seed' in v))
})
t('順位胡：兩家都能胡，離打牌的人近的那家胡', () => {
  let st = newGame({ seed: 5, cat: CAT, dealer: 0 })
  st.hands[0] = tiles('1m 2m 3m 4m 5m 6m 7m 8m 9m 1p 1p 1p 2t 3t 4t E0 9p')
  st.hands[2] = tiles('1m 2m 3m 4m 5m 6m 7m 8m 9m 1p 1p 1p 2t 3t 4t 9p')
  st.hands[3] = tiles('1s'.replace('1s', '1m') + ' 2m 3m 4m 5m 6m 7m 8m 9m 2p 2p 2p 6t 7t 8t 9p'.replace(/^/, '')) // 13+…
  st.hands[3] = tiles('1m 2m 3m 4m 5m 6m 7m 8m 9m 2p 2p 2p 6t 7t 8t 9p')
  st.hands[1] = tiles('1p 4p 7p 2t 5t 8t 3m 6m 9m E0 S0 W0 N0 C0 F0 B0')
  st = act(st, 0, { type: 'discard', tile: '9p' }).st
  assert.equal(st.phase, 'claim'); assert.ok(st.claim.options[2].hu && st.claim.options[3].hu)
  st = act(st, 3, { type: 'hu' }).st
  assert.equal(st.phase, 'claim')                                   // 2 號還沒回應，不能先決定
  if (st.claim.options[1]) st = act(st, 1, { type: 'pass' }).st
  st = act(st, 2, { type: 'hu' }).st
  assert.equal(st.result.winner, 2); assert.equal(st.result.from, 0)
  assert.equal(st.result.payments.reduce((a, b) => a + b, 0), 0)
})
t('MIGI：只有自己前兩手、沒人鳴牌、打完要聽', () => {
  let st = newGame({ seed: 5, cat: CAT, dealer: 0 })
  st.hands[0] = tiles('1m 2m 3m 4m 5m 6m 7m 8m 9m 1p 1p 1p 2t 3t 4t E0 9p')
  assert.equal(act(st, 0, { type: 'discard', tile: '1m', migi: true }).error, 'migi_not_allowed')   // 打 1m 不聽
  const ok = act(st, 0, { type: 'discard', tile: '9p', migi: true })
  assert.ok(ok.ok); assert.equal(ok.st.migi[0], true)
  st.turns[0] = 2
  assert.equal(act(st, 0, { type: 'discard', tile: '9p', migi: true }).error, 'migi_not_allowed')   // 第三手（莊家無第三手）
  st.turns[0] = 0; st.called = true
  assert.equal(act(st, 0, { type: 'discard', tile: '9p', migi: true }).error, 'migi_not_allowed')   // 有人鳴牌了
})
t('眼牌：鎖牌、摸到能胡就自動胡；沒胡的人付 1 台不算底', () => {
  let st = newGame({ seed: 9, cat: CAT, dealer: 0, base: 50, unit: 20 })
  st.hands[0] = tiles('1m 2m 3m 4m 5m 6m 7m 8m 9m 1p 1p 1p 2t 3t 4t E0 9p')
  st = act(st, 0, { type: 'discard', tile: '9p', yan: true }).st   // 聽 E0 單吊
  assert.equal(st.yan[0], true)
  const v = viewFor(st, 0)
  assert.ok(Array.isArray(v.players[1].hand) && Array.isArray(v.wall))  // 眼牌看得到別家與牌山
  // 讓別家一路過、輪到莊家摸到 E0 ⇒ 自動胡
  st.wall.splice(KEEP, 0)
  let guard = 0
  while (st.phase !== 'over' && guard++ < 400) {
    if (st.phase === 'claim') { for (const o of Object.keys(st.claim.options)) if (!st.claim.resp[o]) st = act(st, +o, { type: 'pass' }).st; continue }
    if (st.turn === 0) throw new Error('眼牌的人不該停在自己的出牌階段')
    if (st.turn === 1 && guard === 1) { st.wall.unshift('E0') }       // 下一張給莊家…先讓 1 號打掉一張
    st = act(st, st.turn, autoAction(st, st.turn)).st
  }
  assert.equal(st.phase, 'over')
})
t('眼牌沒胡要付 1 台給胡的人', () => {
  let st = newGame({ seed: 9, cat: CAT, dealer: 0, base: 50, unit: 20 })
  st.yan[3] = true
  st.hands[0] = tiles('1m 2m 3m 4m 5m 6m 7m 8m 9m 2p 3p 4p 2t 3t 4t 5t 5t')
  st = act(st, 0, { type: 'tsumo' }).st
  const p = st.result.payments
  assert.equal(p[0], -(p[1] + p[2] + p[3]))
  assert.equal(p[3] - p[1], -20)                                     // 3 號多付 1 台（20）、不算底
  assert.deepEqual(st.result.yanPaid, [3])
})

/* ── 亂打 600 局：不當機、牌不會多不會少、輸贏加起來是 0 ── */
t('亂打 600 局', () => {
  let r = 12345
  const rand = () => { r = (r * 1103515245 + 12345) & 0x7fffffff; return r / 0x7fffffff }
  const ends = { draw: 0, tsumo: 0, ron: 0 }
  for (let g = 0; g < 600; g++) {
    const flower = g % 2 === 1
    let st = newGame({ seed: g + 1, cat: CAT, flower, dealer: g % 4, base: 50, unit: 20 })
    const total = flower ? 144 : 136
    let steps = 0
    while (st.phase !== 'over') {
      if (++steps > 2000) throw new Error('第 ' + g + ' 局停不下來')
      const movers = st.phase === 'claim' ? Object.keys(st.claim.options).map(Number).filter((o) => !st.claim.resp[o]) : [st.turn]
      const s = movers[Math.floor(rand() * movers.length)]
      const o = optionsFor(st, s)
      let a = autoAction(st, s)
      if (o && o.claim) {
        const pick = []
        if (o.claim.hu) pick.push({ type: 'hu' })
        if (o.claim.pong) pick.push({ type: 'pong' })
        if (o.claim.kong) pick.push({ type: 'kong' })
        if (o.claim.chi) pick.push({ type: 'chi', tiles: o.claim.chi[0] })
        if (pick.length && rand() < 0.6) a = pick[Math.floor(rand() * pick.length)]
      } else if (o && o.discard) {
        if (o.tsumo && rand() < 0.9) a = { type: 'tsumo' }
        else if (o.kongs && rand() < 0.5) a = { type: 'kong', tile: o.kongs[0] }
        else {
          /* 出牌不要完全亂打（不然幾乎每局流局，胡牌與算台都測不到）：
             聽牌了就打掉不影響聽牌的那張；沒聽就打最孤單的那張（同樣與相鄰的牌最少），偶爾亂打 */
          const h = st.hands[s]
          const lonely = (x) => {
            const k = KIND_CODES.indexOf(x)
            if (k < 0) return 0
            const near = (d) => (k + d >= 0 && k + d < 34 && (k < 27 ? Math.floor((k + d) / 9) === Math.floor(k / 9) : d === 0) ? h.filter((y) => y === KIND_CODES[k + d]).length : 0)
            return near(0) * 3 + near(-1) + near(1) + near(-2) * 0.5 + near(2) * 0.5
          }
          const best = [...h].sort((a, b) => lonely(a) - lonely(b))[0]
          const tile = o.locked ? st.drawn
            : o.listen && rand() < 0.9 ? Object.keys(o.listen)[Math.floor(rand() * Object.keys(o.listen).length)]
            : rand() < 0.85 ? best : h[Math.floor(rand() * h.length)]
          a = { type: 'discard', tile, migi: !!(o.migi && o.migi.includes(tile) && rand() < 0.5), yan: !!(o.yan && o.yan.includes(tile) && rand() < 0.2) }
        }
      }
      const res = act(st, s, a)
      if (!res.ok) throw new Error(`第 ${g} 局 ${s} 號 ${JSON.stringify(a)} 被拒：${res.error}`)
      st = res.st
      const n = st.wall.length + st.hands.flat().length + st.melds.flat().reduce((x, m) => x + m.tiles.length, 0) + st.flowers.flat().length + st.discards.flat().length
      if (n !== total) throw new Error(`第 ${g} 局牌數 ${n} ≠ ${total}`)
    }
    ends[st.result.type]++
    assert.equal(st.result.payments.reduce((a, b) => a + b, 0), 0)
    if (st.result.type !== 'draw') assert.ok(st.result.tai >= 0)
  }
  console.log('   600 局：流局 ' + ends.draw + '、自摸 ' + ends.tsumo + '、胡別人 ' + ends.ron)
})

console.log(`\n${fail ? '🔴' : '✅'} 牌局引擎 ${pass} 項通過${fail ? '、' + fail + ' 項失敗' : ''}`)
process.exit(fail ? 1 : 0)
