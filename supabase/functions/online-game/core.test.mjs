/* online-game 流程測試（零相依）：node supabase/functions/online-game/core.test.mjs
   用一個假的資料庫（照 sql/applied 那幾支函式的規則寫的縮小版）把整場打完，盯四件事：
   ① 每一家拿到的畫面裡沒有別家的手牌、牌山、seed　② 四支手機同時叫只會開出一將／一局
   ③ 每一局四家增減加起來是 0、整場積分總和不變　④ 逾時代打、版本對不上、不是你的回合都擋得住
   機器人只看「手機拿到的畫面」出牌 —— 所以也順便驗了畫面給的資訊夠不夠打完一場 */
import assert from 'node:assert/strict'
import { handle, stageOf, TURN_MS, NEXT_AFTER_MS } from './core.mjs'

import { CAT, fakeDb, botAction as bot, json } from './testkit.mjs'

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

const botAction = (v) => bot(v, rand)

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

await t('自己開電腦代打：另外三家的畫面看得到、自己出牌不會把它清掉、關得掉；逾時代打記在另一格', async () => {
  const { db, D } = fakeDb()
  let now = 2_000_000
  const v0 = await handle(db, me('m1'), { op: 'view' }, now, rand)
  const seat = v0.me.seat
  // 開之前：沒有人開著
  assert.ok(!Object.values(v0.presence || {}).some((p) => p.auto_on))
  // 開：我自己的回傳與別人讀到的畫面都看得到，而且只有我這個座位
  const a = await handle(db, me('m1'), { op: 'auto', on: true }, now + 1, rand)
  assert.equal(a.ok, true); assert.equal(a.presence[seat].auto_on, true)
  const other = await handle(db, me('m2'), { op: 'view' }, now + 2, rand)
  assert.equal(other.presence[seat].auto_on, true)
  assert.ok(!(other.presence[other.me.seat] && other.presence[other.me.seat].auto_on), '別人的座位不該跟著變成代打中')
  // 輪到誰就讓誰動一次；輪到我時我自己的手機送出動作（actor 是 player）⇒ auto_on 還在
  for (let i = 0; i < 12; i++) {
    let moved = false
    for (const m of MEMBERS) {
      const v = await handle(db, me(m), { op: 'view' }, now, rand); const act1 = v.stage === 'playing' ? botAction(v) : null
      if (act1 && !moved) { await handle(db, me(m), { op: 'act', version: v.hand.version, action: act1 }, now, rand); moved = true }
    }
    now += 5
  }
  assert.ok(D.actions.some((x) => x.seat === seat && x.actor === 'player'), '這一段裡我至少要自己動過一次，這一格才有測到東西')
  assert.equal(D.presence[seat].auto_on, true); assert.equal(D.presence[seat].auto_since, null)
  // 正對照：放著不動讓時間到 ⇒ 被後端代打的人記的是 auto_since，不會變成 auto_on
  const before = JSON.stringify(D.presence)
  now += TURN_MS * 3
  await handle(db, me('m1'), { op: 'tick' }, now, rand)
  const timedOut = Object.entries(D.presence).filter(([, p]) => p.auto_since)
  assert.ok(timedOut.length > 0, '時間到了應該有人被代打：' + before + ' → ' + JSON.stringify(D.presence))
  assert.ok(timedOut.every(([s, p]) => Number(s) === seat || !p.auto_on), '被逾時代打的別人不該被標成「自己開的」')
  // 關
  const off = await handle(db, me('m1'), { op: 'auto', on: false }, now + 1, rand)
  assert.equal(off.ok, true); assert.equal(off.presence[seat].auto_on, false)
})

console.log(`\n${fail ? '🔴' : '✅'} online-game 流程 ${pass} 項通過${fail ? '、' + fail + ' 項失敗' : ''}`)
process.exit(fail ? 1 : 0)
