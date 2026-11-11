/* online-game 流程測試（零相依）：node supabase/functions/online-game/core.test.mjs
   用一個假的資料庫（照 sql/applied 那幾支函式的規則寫的縮小版）把整場打完，盯四件事：
   ① 每一家拿到的畫面裡沒有別家的手牌、牌山、seed　② 四支手機同時叫只會開出一將／一局
   ③ 每一局四家增減加起來是 0、整場積分總和不變　④ 逾時代打、版本對不上、不是你的回合都擋得住
   機器人只看「手機拿到的畫面」出牌 —— 所以也順便驗了畫面給的資訊夠不夠打完一場 */
import assert from 'node:assert/strict'
import { handle, stageOf, TURN_MS, NEXT_AFTER_MS } from './core.mjs'
import { KIND_CODES } from './engine.mjs'

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
].map(([code, tai, max_count, conflicts]) => ({ code, label: code, tai, max_count, conflicts, flower_conflicts: code === 'pinghu' ? ['menqing'] : [] }))

const json = (x) => JSON.parse(JSON.stringify(x))   // 進出資料庫都會變成 JSON：狀態裡不能有 JSON 存不了的東西
const sum = (a) => a.reduce((x, y) => x + y, 0)

/* 假的資料庫：規則照 SQL（online_start_round_tx／online_next_hand_tx／online_commit_tx／_tbl_round_state／爆卡夾帳） */
function fakeDb({ planned = 1, base = 50, unit = 20, start = 2000, flower = false } = {}) {
  const D = {
    session: { id: 's1', org_id: 'o1', status: 'open', flower, planned_rounds: planned, base, unit, stake_label: `${base}/${unit}`, is_hygiene: false, channel: 'ch' },
    game: { id: 'g1', status: 'playing' }, scored: false, bust: null, added: { 1: 0, 2: 0, 3: 0, 4: 0 },
    players: ['m1', 'm2', 'm3', 'm4'].map((m) => ({ member_id: m, seat: null, nickname: m })),
    rounds: [], ohands: [], hands: [], actions: [], calls: { startOk: 0, nextOk: 0 },
  }
  const roundState = (r) => {
    let dealer = r.first, wind = 1, ren = 0, pass = 0, n = 0, fin = false
    for (const h of D.hands.filter((x) => x.round === r.id)) {
      n++
      const stay = h.result === 'draw' ? true : h.winner_seat === dealer
      if (stay) ren++
      else {
        dealer = r.ring[(r.ring.indexOf(dealer) + 1) % 4]; ren = 0; pass++
        if (pass === 4) { pass = 0; wind++; if (wind > 4) { wind = 4; fin = true; break } }
      }
    }
    return { wind, dealer_seat: dealer, renzhuang: ren, hand_no: n + 1, finished: fin, confirmed_hands: n, seat_ring: r.ring }
  }
  const balances = () => {
    const b = { 1: start, 2: start, 3: start, 4: start }
    for (const s of [1, 2, 3, 4]) b[s] += D.added[s]
    for (const h of D.hands) for (const s of [1, 2, 3, 4]) b[s] += h.delta[s] || 0
    return b
  }
  const blockWhy = () => (D.session.status !== 'open' ? 'session_closed' : D.scored ? 'scored' : D.bust ? 'bust_pending' : null)
  const playingRound = () => D.rounds.find((r) => r.status === 'playing')
  const sameDice = (a, b) => JSON.stringify(a) === JSON.stringify(b)
  const db = {
    async ctx() {
      const r = D.rounds[D.rounds.length - 1], h = D.ohands[D.ohands.length - 1]
      return json({
        ok: true, session: D.session, game: D.game, scored: D.scored, rounds_done: D.rounds.filter((x) => x.status === 'finished').length,
        round: r ? { id: r.id, round_no: r.no, status: r.status, ring: r.ring, state: roundState(r) } : null,
        hand: h ? { ...h, applied: h.hand_ref != null ? D.hands[h.hand_ref].delta : null } : null,
        players: D.players, balances: balances(), bust: D.bust, cat: CAT, presence: {},
      })
    },
    async startRound(a) {
      a = json(a)
      const why = blockWhy(); if (why) return { ok: false, reason: why }
      if (playingRound()) return { ok: false, reason: 'round_playing' }
      const no = D.rounds.length + 1
      if (no > D.session.planned_rounds) return { ok: false, reason: 'all_rounds_done' }
      if (a.p_state.dealer !== 0 || a.p_state.ren !== 0 || !sameDice(a.p_state.dice, a.p_dealer_dice)) return { ok: false, reason: 'bad_state' }
      if (D.players.some((p) => p.seat == null)) D.players.forEach((p, i) => { p.seat = i + 1 })
      const east = ((sum(a.p_seat_dice) - 1) % 4) + 1
      const dealer = ((east - 1 + sum(a.p_dealer_dice) - 1) % 4) + 1
      const ring = [dealer, (dealer % 4) + 1, ((dealer + 1) % 4) + 1, ((dealer + 2) % 4) + 1]
      const r = { id: 'r' + no, no, status: 'playing', first: dealer, ring }
      D.rounds.push(r)
      D.ohands.push({ id: 'h' + (D.ohands.length + 1), round_id: r.id, hand_no: 1, version: 0, status: 'playing', phase: a.p_phase, deadline_at: a.p_deadline, dealer_seat: dealer, renzhuang: 0, dice: a.p_dealer_dice, seat_dice: a.p_seat_dice, state: a.p_state, started_at: null, ended_at: null })
      D.calls.startOk++
      return { ok: true, round_id: r.id, round_no: no, east_seat: east, dealer_seat: dealer, ring }
    },
    async nextHand(a) {
      a = json(a)
      const why = blockWhy(); if (why) return { ok: false, reason: why }
      const r = playingRound(); if (!r) return { ok: false, reason: 'no_round' }
      if (D.ohands.some((h) => h.status === 'playing')) return { ok: false, reason: 'hand_playing' }
      const rs = roundState(r)
      if (rs.finished) return { ok: false, reason: 'round_finished' }
      if (rs.hand_no !== a.p_hand_no || rs.dealer_seat !== a.p_dealer_seat || rs.renzhuang !== a.p_ren) return { ok: false, reason: 'out_of_sync' }
      if (a.p_state.dealer !== r.ring.indexOf(a.p_dealer_seat) || a.p_state.ren !== a.p_ren || !sameDice(a.p_state.dice, a.p_dice)) return { ok: false, reason: 'bad_state' }
      D.ohands.push({ id: 'h' + (D.ohands.length + 1), round_id: r.id, hand_no: a.p_hand_no, version: 0, status: 'playing', phase: a.p_phase, deadline_at: a.p_deadline, dealer_seat: a.p_dealer_seat, renzhuang: a.p_ren, dice: a.p_dice, seat_dice: null, state: a.p_state, started_at: null, ended_at: null })
      D.calls.nextOk++
      return { ok: true }
    },
    async commit(a) {
      a = json(a)
      const h = D.ohands.find((x) => x.id === a.p_hand)
      if (!h || h.status !== 'playing' || h.version !== a.p_version) return { ok: false, reason: 'stale' }
      h.state = a.p_state; h.phase = a.p_phase; h.deadline_at = a.p_deadline; h.version++
      D.actions.push({ hand: h.id, version: h.version, seat: a.p_seat, actor: a.p_actor, action: a.p_action })
      if (!a.p_result) return { ok: true, version: h.version }
      const d = a.p_result.deltas
      assert.equal(sum([1, 2, 3, 4].map((s) => d[s])), 0, '四家增減加起來要是 0')
      /* 爆卡：一個收的人、付的人最多付自己剩的（同 trg_hands_bust_clamp） */
      const bal = balances(), delta = { ...d }
      const recv = [1, 2, 3, 4].filter((s) => d[s] > 0)
      if (recv.length === 1) {
        let got = 0
        for (const s of [1, 2, 3, 4]) if (d[s] < 0) { const pay = Math.min(-d[s], Math.max(0, bal[s])); delta[s] = -pay; got += pay }
        delta[recv[0]] = got
      }
      const r = D.rounds.find((x) => x.id === h.round_id)
      D.hands.push({ round: r.id, hand_no: h.hand_no, result: a.p_result.type, winner_seat: a.p_result.winner_seat, deal_in_seat: a.p_result.deal_in_seat, tai: a.p_result.tai, patterns: a.p_result.patterns, delta, dealer_seat: h.dealer_seat })
      h.status = 'finished'; h.ended_at = a.p_ended_at || '2026-01-01T00:00:00.000Z'; h.hand_ref = D.hands.length - 1; h.deadline_at = null
      const nb = balances()
      const out = [1, 2, 3, 4].find((s) => nb[s] <= 0)
      if (out) D.bust = { seat: out }
      if (roundState(r).finished) {
        r.status = 'finished'
        if (r.no >= D.session.planned_rounds) { D.scored = true; D.game.status = 'finished' }
      }
      return { ok: true, version: h.version, applied: delta, round_finished: r.status === 'finished', scored: D.scored }
    },
    async bustDecide(a) {
      if (!D.bust) return { ok: false, reason: 'no_bust' }
      if (D.bust.seat !== a.p_seat) return { ok: false, reason: 'not_yours' }
      if (a.p_amount > 0) { D.added[a.p_seat] += a.p_amount; D.bust = null; return { ok: true, added: a.p_amount } }
      D.bust = null; for (const r of D.rounds) if (r.status === 'playing') r.status = 'finished'
      D.scored = true; D.game.status = 'finished'
      return { ok: true, ended: true }
    },
  }
  return { db, D, balances }
}

const me = (m) => ({ member_id: m, session_id: 's1' })
const MEMBERS = ['m1', 'm2', 'm3', 'm4']
let seedR = 20261111
const rand = () => { seedR = (seedR * 1103515245 + 12345) & 0x7fffffff; return seedR / 0x7fffffff }

/* 🔴 最重要的一格：這一份畫面可以送給這一家嗎 */
function assertNoLeak(v, who) {
  const t = v.table
  if (!t) return
  const s = JSON.stringify(v)
  assert.ok(!s.includes('"seed"'), who + '：畫面裡不可以有 seed')
  assert.ok(!('state' in (v.hand || {})), who + '：畫面裡不可以有整包狀態')
  const over = t.phase === 'over', yan = t.players[t.seat].yan
  if (!yan || over) assert.equal(over ? null : t.wall, null, who + '：沒眼牌看不到牌山')
  if (!over && !yan) t.players.forEach((p, i) => { if (i !== t.seat) assert.equal(p.hand, null, who + '：看到了第 ' + i + ' 家的手牌') })
  if (!over && !yan) t.players.forEach((p, i) => { if (i !== t.seat) p.melds.forEach((m) => { if (m.t === 'ckong') assert.equal(m.tiles, null, who + '：看到了別家的暗槓') }) })
}

/* 只看畫面出牌的機器人（同 engine.test.mjs 的打法，差別是它只拿得到 viewFor 給的東西） */
function botAction(v) {
  const t = v.table, o = t && t.options
  if (!o) return null
  if (o.baozi) return { type: 'baozi', mult: o.baozi[Math.floor(rand() * o.baozi.length)] }
  if (o.claim) {
    const pick = []
    if (o.claim.hu) return { type: 'hu' }
    if (o.claim.pong) pick.push({ type: 'pong' })
    if (o.claim.kong) pick.push({ type: 'kong' })
    if (o.claim.chi) pick.push({ type: 'chi', tiles: o.claim.chi[0] })
    return pick.length && rand() < 0.5 ? pick[Math.floor(rand() * pick.length)] : { type: 'pass' }
  }
  if (o.discard) {
    if (o.tsumo) return { type: 'tsumo' }
    if (o.kongs && rand() < 0.4) return { type: 'kong', tile: o.kongs[0] }
    const h = t.players[t.seat].hand
    const lonely = (x) => {
      const k = KIND_CODES.indexOf(x)
      const near = (d) => (k + d >= 0 && k + d < 34 && (k < 27 ? Math.floor((k + d) / 9) === Math.floor(k / 9) : d === 0) ? h.filter((y) => y === KIND_CODES[k + d]).length : 0)
      return near(0) * 3 + near(-1) + near(1) + near(-2) * 0.5 + near(2) * 0.5
    }
    const tile = o.locked ? t.drawn : o.listen && rand() < 0.9 ? Object.keys(o.listen)[0] : [...h].sort((a, b) => lonely(a) - lonely(b))[0]
    return { type: 'discard', tile, migi: !!(o.migi && o.migi.includes(tile) && rand() < 0.5), yan: !!(o.yan && o.yan.includes(tile) && rand() < 0.15) }
  }
  return null
}

let pass = 0, fail = 0
const t = async (name, fn) => { try { await fn(); pass++ } catch (e) { fail++; console.log('🔴 ' + name + '\n   ' + (e.stack || e.message).split('\n').slice(0, 4).join('\n   ')) } }

await t('四支手機同時進來：只開出一將、每個人都拿到自己的座位與畫面', async () => {
  const { db, D } = fakeDb()
  const vs = await Promise.all(MEMBERS.map((m) => handle(db, me(m), { op: 'view' }, 1000, rand)))
  assert.equal(D.calls.startOk, 1)
  assert.equal(D.rounds.length, 1); assert.equal(D.ohands.length, 1)
  for (const m of MEMBERS) {
    const v = await handle(db, me(m), { op: 'view' }, 1100, rand)
    assert.equal(v.stage, 'playing'); assert.ok(v.me.seat >= 1 && v.me.seat <= 4); assert.equal(v.round.ring[v.me.idx], v.me.seat)
    assert.equal(v.table.players[v.me.idx].hand.length, v.table.players[v.me.idx].count)
    assertNoLeak(v, m)
  }
  assert.ok(vs.every((v) => v.ok))
  assert.equal(new Set(D.players.map((p) => p.seat)).size, 4)
  assert.equal(D.ohands[0].state.dealer, 0)                                   // 每一將第一局：引擎的莊家是第 0 位
  assert.deepEqual(D.ohands[0].state.dice, D.ohands[0].dice)                   // 第一局的骰子就是定莊家那一擲
  assert.equal(D.rounds[0].ring[0], D.rounds[0].first)
})

await t('負對照：檢查漏牌的那一格真的抓得到（塞一手別家的牌、塞整包狀態、塞牌山都要紅）', async () => {
  const { db } = fakeDb()
  await handle(db, me('m1'), { op: 'view' }, 1000, rand)
  const v = await handle(db, me('m1'), { op: 'view' }, 1100, rand)
  assertNoLeak(v, '原本的畫面')                                                // 正對照：原本的要過
  const a = json(v); a.table.players[(a.table.seat + 1) % 4].hand = ['1m', '2m']
  assert.throws(() => assertNoLeak(a, 'x'), /手牌/)
  const b = json(v); b.hand.state = { hands: [] }
  assert.throws(() => assertNoLeak(b, 'x'), /整包狀態/)
  const c = json(v); c.table.wall = ['1m']
  assert.throws(() => assertNoLeak(c, 'x'), /牌山/)
  const d = json(v); d.table.seed = 123
  assert.throws(() => assertNoLeak(d, 'x'), /seed/)
})

await t('不是你的回合、畫面不是最新的那一版，都不做', async () => {
  const { db, D } = fakeDb()
  await handle(db, me('m1'), { op: 'view' }, 1000, rand)
  const h = D.ohands[0], ring = D.rounds[0].ring
  if (h.state.phase === 'baozi') await handle(db, me(D.players.find((p) => p.seat === ring[0]).member_id), { op: 'act', action: { type: 'baozi', mult: 1 } }, 1500, rand)
  const turnSeat = ring[D.ohands[0].state.turn]
  const other = D.players.find((p) => p.seat !== turnSeat).member_id, mine = D.players.find((p) => p.seat === turnSeat).member_id
  const v0 = D.ohands[0].version
  const a = await handle(db, me(other), { op: 'act', action: { type: 'discard', tile: '1m' } }, 2000, rand)
  assert.equal(a.ok, false); assert.equal(a.reason, 'not_your_turn'); assert.equal(D.ohands[0].version, v0)
  const mv = await handle(db, me(mine), { op: 'view' }, 2000, rand)
  const b = await handle(db, me(mine), { op: 'act', version: mv.hand.version + 5, action: botAction(mv) }, 2000, rand)
  assert.equal(b.reason, 'stale'); assert.equal(D.ohands[0].version, v0)
  const c = await handle(db, me(mine), { op: 'act', version: mv.hand.version, action: botAction(mv) }, 2000, rand)
  assert.equal(c.ok, true); assert.equal(D.ohands[0].version, v0 + 1)
  assert.equal(D.actions[D.actions.length - 1].actor, 'player'); assert.equal(D.actions[D.actions.length - 1].seat, turnSeat)
})

await t('逾時：時間沒到不代打；到了由電腦代打，紀錄寫 auto', async () => {
  const { db, D } = fakeDb()
  await handle(db, me('m1'), { op: 'view' }, 1000, rand)
  const dl = new Date(D.ohands[0].deadline_at).getTime()
  await handle(db, me('m2'), { op: 'tick' }, dl - 10, rand)
  assert.equal(D.ohands[0].version, 0)
  await handle(db, me('m2'), { op: 'tick' }, dl + 10, rand)
  assert.ok(D.ohands[0].version >= 1)
  assert.ok(D.actions.every((x) => x.actor === 'auto'))
  assert.ok(new Date(D.ohands[0].deadline_at).getTime() > dl || D.ohands[0].status === 'finished')
})

await t('整場打完（約 1 將）：每一局帳都對、積分總和不變、沒有漏牌、局號與莊家跟資料庫算的一樣', async () => {
  const { db, D, balances } = fakeDb({ start: 200000 })     // 起始積分給很多：這一格不測爆卡
  let now = 1000, steps = 0
  await handle(db, me('m1'), { op: 'view' }, now, rand)
  while (!D.scored) {
    if (++steps > 60000) throw new Error('打不完（第 ' + D.hands.length + ' 局）')
    now += 700
    const ctx = await db.ctx()
    const st = stageOf(ctx)
    if (st === 'hand_over' || st === 'round_over') {
      // 一半用「有人按下一局」、一半用「沒人按，時間到自動開」
      if (steps % 2) await handle(db, me('m3'), { op: 'next' }, now, rand)
      else { now += NEXT_AFTER_MS + 10; D.ohands[D.ohands.length - 1].ended_at = new Date(now - NEXT_AFTER_MS - 5).toISOString(); await handle(db, me('m3'), { op: 'tick' }, now, rand) }
      continue
    }
    assert.equal(st, 'playing')
    // 每一家各看一次畫面：都不可以漏；有事要做的那一家照機器人出
    let moved = false
    for (const m of MEMBERS) {
      const v = await handle(db, me(m), { op: 'view' }, now, rand)
      assertNoLeak(v, m)
      const a = botAction(v)
      if (!a || moved) continue
      if (rand() < 0.08) { now += TURN_MS + 10; await handle(db, me(m), { op: 'tick' }, now, rand); moved = true; continue }   // 偶爾發呆 ⇒ 逾時代打
      const r = await handle(db, me(m), { op: 'act', version: v.hand.version, action: a }, now, rand)
      assert.ok(r.ok, m + ' 做 ' + JSON.stringify(a) + ' 失敗：' + r.reason)
      moved = true
    }
    if (!moved) { now += TURN_MS + 10; await handle(db, me('m1'), { op: 'tick' }, now, rand) }
  }
  const b = balances()
  assert.equal(b[1] + b[2] + b[3] + b[4], 800000)
  for (const h of D.hands) assert.equal(h.delta[1] + h.delta[2] + h.delta[3] + h.delta[4], 0)
  assert.equal(D.rounds.length, 1); assert.equal(D.rounds[0].status, 'finished')
  assert.equal(D.calls.nextOk + D.calls.startOk, D.ohands.length)
  assert.deepEqual(D.ohands.map((h) => h.hand_no), D.ohands.map((_, i) => i + 1))
  const kinds = D.hands.reduce((m, h) => { m[h.result] = (m[h.result] || 0) + 1; return m }, {})
  const autos = D.actions.filter((x) => x.actor === 'auto').length
  console.log('   一將 ' + D.hands.length + ' 局：' + JSON.stringify(kinds) + '，動作 ' + D.actions.length + ' 個（其中電腦代打 ' + autos + ' 個）')
  assert.ok(kinds.ron || kinds.tsumo, '整將都沒人胡，測不到結算')
  const v = await handle(db, me('m2'), { op: 'view' }, now, rand)
  assert.equal(v.stage, 'game_over'); assert.equal(v.table.phase, 'over'); assert.ok(v.hand.applied)
})

await t('爆卡：只付得出剩下的、不能開下一局；別人不能替他決定；追加之後才繼續', async () => {
  const { db, D, balances } = fakeDb({ start: 60 })          // 起始只有 60：第一次有人放槍或被自摸就會歸零
  let now = 1000, steps = 0
  await handle(db, me('m1'), { op: 'view' }, now, rand)
  while (!D.bust) {
    if (++steps > 60000) throw new Error('一直沒有人爆卡')
    now += 700
    const st = stageOf(await db.ctx())
    if (st !== 'playing') { await handle(db, me('m1'), { op: 'next' }, now, rand); continue }
    let moved = false
    for (const m of MEMBERS) {
      const v = await handle(db, me(m), { op: 'view' }, now, rand); const a = botAction(v)
      if (a && !moved) { await handle(db, me(m), { op: 'act', version: v.hand.version, action: a }, now, rand); moved = true }
    }
    if (!moved) { now += TURN_MS + 10; await handle(db, me('m1'), { op: 'tick' }, now, rand) }
  }
  const b = balances()
  assert.ok(Object.values(b).every((x) => x >= 0), '積分不會變成負的：' + JSON.stringify(b))
  assert.equal(b[1] + b[2] + b[3] + b[4], 240)
  const n = D.ohands.length
  const v = await handle(db, me('m1'), { op: 'next' }, now + 1, rand)
  assert.equal(v.stage, 'bust'); assert.equal(D.ohands.length, n)
  const who = D.players.find((p) => p.seat === D.bust.seat).member_id, notWho = D.players.find((p) => p.seat !== D.bust.seat).member_id
  const x = await handle(db, me(notWho), { op: 'bust', amount: 500 }, now + 2, rand)
  assert.equal(x.ok, false); assert.equal(x.reason, 'not_yours'); assert.ok(D.bust)
  const y = await handle(db, me(who), { op: 'bust', amount: 500 }, now + 3, rand)
  assert.equal(y.ok, true); assert.equal(D.bust, null)
  const z = await handle(db, me(who), { op: 'next' }, now + 4, rand)
  assert.ok(z.stage === 'playing' || z.stage === 'game_over' || z.stage === 'round_over')
})

console.log(`\n${fail ? '🔴' : '✅'} online-game 流程 ${pass} 項通過${fail ? '、' + fail + ' 項失敗' : ''}`)
process.exit(fail ? 1 : 0)
