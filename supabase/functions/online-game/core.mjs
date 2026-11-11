/* ============================================================
   online-game 的流程（線上好友房，2026-11-11）
   📄 規格：docs/03-會員App與社交/線上好友房.md

   這一支只管「順序」：讀整包 → 跑引擎 → 寫回。規則全在 engine.mjs，資料庫的檢查全在 SQL。
   · 純邏輯、不碰網路：index.ts 把「叫資料庫」的幾支函式（db）傳進來 ⇒ Node 用假的資料庫跑同一份（core.test.mjs）
   · 座位兩種編號：資料庫 1～4（代表人）、引擎 0～3（這一將的出牌順序）。換算只在這裡做：引擎第 i 位 ＝ ring[i]
   · 🔴 給手機的東西一律經過 viewFor()（每一家只拿自己看得到的那一份）；state 整包絕對不往外送

   op：
     view  讀現在的畫面（第一次有人讀的時候順便開第一將）
     act   做一個動作：{ action, version }（version ＝ 你畫面上那一版；對不上就不做，回最新畫面）
     tick  時間到了請後端處理：逾時的人由電腦代打；一局打完超過一段時間自動開下一局
     next  不等了，現在就開下一局／下一將（任何一家按都可以）
     bust  爆卡的人決定：{ amount }（> 0 追加積分，0 結束整場）
   ============================================================ */
import { newGame, act, viewFor, autoAction } from './engine.mjs'

export const TURN_MS = 15000        // 出牌 15 秒（含莊家選豹子倍數）
export const CLAIM_MS = 5000        // 別人打牌後要不要吃碰槓胡 5 秒
export const DEAL_MS = 7000         // 發牌動畫的時間：新的一局第一步多給這麼久
export const ROUND_MS = 9000        // 開一將還要演兩次擲骰子：再多給這麼久
export const NEXT_AFTER_MS = 15000  // 一局打完沒人按「下一局」，過這麼久自動開

const ms = (t) => (t ? new Date(t).getTime() : null)
const iso = (n) => (n == null ? null : new Date(n).toISOString())

export function deadlineFor(st, now, extra = 0) {
  if (st.phase === 'discard' || st.phase === 'baozi') return iso(now + TURN_MS + extra)
  if (st.phase === 'claim') return iso(now + CLAIM_MS + extra)
  return null
}

/* 打完的一局換成資料庫要的樣子（座位換回 1～4）。tai ＝ 牌型台（已乘豹子、不含莊家台），同計分板 hands.tai_pattern */
export function resultFor(st, ring) {
  if (st.phase !== 'over' || !st.result) return null
  const r = st.result
  const deltas = {}
  for (let i = 0; i < 4; i++) deltas[String(ring[i])] = r.payments[i] || 0
  if (r.type === 'draw') return { type: 'draw', winner_seat: null, deal_in_seat: null, patterns: [], tai: 0, deltas }
  return {
    type: r.type, winner_seat: ring[r.winner], deal_in_seat: r.type === 'ron' ? ring[r.from] : null,
    patterns: (r.patterns || []).map((p) => ({ code: p.code, n: p.n })), tai: r.tai || 0, deltas,
  }
}

const seatOf = (ctx, memberId) => { const p = (ctx.players || []).find((x) => x.member_id === memberId); return p ? p.seat : null }
const playing = (ctx) => (ctx.hand && ctx.hand.status === 'playing' ? ctx.hand : null)
const engineArgs = (ctx) => ({ flower: !!ctx.session.flower, base: ctx.session.base, unit: ctx.session.unit, cat: ctx.cat || [] })
const blocked = (ctx) => ctx.scored || !!ctx.bust || ctx.session.status !== 'open'

/* 現在卡在哪：playing 正在打／hand_over 這一局打完等下一局／round_over 這一將打完等下一將／
   game_over 整場打完（成績已算）／bust 有人爆卡等他決定／starting 還沒開第一將 */
export function stageOf(ctx) {
  if (ctx.scored) return 'game_over'
  if (ctx.bust) return 'bust'
  if (playing(ctx)) return 'playing'
  if (!ctx.round) return 'starting'
  if (ctx.round.status === 'playing' && !(ctx.round.state && ctx.round.state.finished)) return 'hand_over'
  return ctx.rounds_done < ctx.session.planned_rounds ? 'round_over' : 'game_over'
}

/* 給某一家手機的畫面 */
export function buildView(ctx, memberId, now) {
  const seat = seatOf(ctx, memberId)
  const ring = ctx.round ? ctx.round.ring : null
  const idx = ring && seat != null ? ring.indexOf(seat) : -1
  const h = ctx.hand
  const labels = Object.fromEntries((ctx.cat || []).map((p) => [p.code, { label: p.label, tai: p.tai }]))
  return {
    ok: true, now: iso(now), stage: stageOf(ctx),
    me: { seat, idx },
    session: { flower: ctx.session.flower, planned_rounds: ctx.session.planned_rounds, base: ctx.session.base, unit: ctx.session.unit,
      stake_label: ctx.session.stake_label, is_hygiene: ctx.session.is_hygiene, channel: ctx.session.channel,
      // 牌桌右下角那一行要用的：玩法、這一場幾點開始（畫面自己算已經打了多久）
      game_type: ctx.session.game_type || null, started_at: ctx.session.started_at || null },
    game: ctx.game, scored: ctx.scored, rounds_done: ctx.rounds_done,
    round: ctx.round ? { round_no: ctx.round.round_no, ring, ...(ctx.round.state || {}) } : null,
    hand: h ? { id: h.id, version: h.version, hand_no: h.hand_no, status: h.status, deadline_at: h.deadline_at, dice: h.dice, seat_dice: h.seat_dice,
      dealer_seat: h.dealer_seat, renzhuang: h.renzhuang, applied: h.applied, started_at: h.started_at, ended_at: h.ended_at } : null,
    /* 🔴 唯一會帶牌的地方：一定經過 viewFor（別家手牌只有張數、暗槓蓋著、seed 不給） */
    table: h && idx >= 0 ? viewFor(h.state, idx) : null,
    players: ctx.players, balances: ctx.balances, bust: ctx.bust, presence: ctx.presence, labels,
  }
}

const roll3 = (rand) => [0, 0, 0].map(() => 1 + Math.floor(rand() * 6))
const seed32 = (rand) => Math.floor(rand() * 4294967296) >>> 0

/* 新的一局如果一發完牌就結束（八仙過海、發牌時牌就摸完這種極少數情況）⇒ 馬上把結果寫回 */
async function settleIfOver(db, sid, st, ring) {
  if (st.phase !== 'over') return
  const c = await db.ctx(sid)
  const h = playing(c)
  if (h) await db.commit({ p_hand: h.id, p_version: h.version, p_state: st, p_phase: 'over', p_deadline: null, p_seat: null, p_actor: 'system', p_action: { type: 'end' }, p_result: resultFor(st, ring) })
}

async function startRound(db, ctx, now, rand) {
  const seatDice = roll3(rand), dealerDice = roll3(rand), seed = seed32(rand)
  // 每一將的順序從這一將第一個莊家排起 ⇒ 引擎的莊家是第 0 位；定莊家那一擲就是第一局的骰子
  const st = newGame({ seed, dealer: 0, ren: 0, dice: dealerDice, ...engineArgs(ctx) })
  const r = await db.startRound({ p_session: ctx.session.id, p_seat_dice: seatDice, p_dealer_dice: dealerDice, p_seed: seed, p_state: st, p_phase: st.phase, p_deadline: deadlineFor(st, now, DEAL_MS + ROUND_MS) })
  if (r && r.ok) await settleIfOver(db, ctx.session.id, st, r.ring)
  return r
}

async function nextHand(db, ctx, now, rand) {
  const rs = ctx.round.state, ring = ctx.round.ring, seed = seed32(rand)
  const st = newGame({ seed, dealer: ring.indexOf(rs.dealer_seat), ren: rs.renzhuang, ...engineArgs(ctx) })   // 第二局起骰子由引擎用 seed 自己擲
  const r = await db.nextHand({ p_session: ctx.session.id, p_hand_no: rs.hand_no, p_seed: seed, p_dice: st.dice, p_dealer_seat: rs.dealer_seat, p_ren: rs.renzhuang, p_state: st, p_phase: st.phase, p_deadline: deadlineFor(st, now, DEAL_MS) })
  if (r && r.ok) await settleIfOver(db, ctx.session.id, st, ring)
  return r
}

/* 該開新的一局／一將就開。force ＝ 有人按了「下一局」；不然要等上一局結束超過 NEXT_AFTER_MS。
   四支手機同時叫也沒關係：資料庫那邊鎖著這一場，只有第一個會成功，其他的拿到 round_playing／hand_playing，重讀就好 */
async function advance(db, ctx, now, rand, force) {
  if (blocked(ctx) || playing(ctx) || ctx.game.status !== 'playing') return ctx
  const st = stageOf(ctx)
  const waited = !ctx.hand || !ctx.hand.ended_at || now - ms(ctx.hand.ended_at) >= NEXT_AFTER_MS
  if (st === 'starting') await startRound(db, ctx, now, rand)                       // 第一將：有人進來就開
  else if (st === 'hand_over' && (force || waited)) await nextHand(db, ctx, now, rand)
  else if (st === 'round_over' && (force || waited)) await startRound(db, ctx, now, rand)
  else return ctx
  return db.ctx(ctx.session.id)
}

/* 時間到了：該動而沒動的人，由電腦替他做（出牌 ⇒ 打剛摸的那張；要不要吃碰槓胡 ⇒ 過；莊家選豹子 ⇒ 放棄） */
async function timeout(db, ctx, now) {
  const h = playing(ctx)
  if (!h || !h.deadline_at || now < ms(h.deadline_at)) return ctx
  const ring = ctx.round.ring
  let st = h.state, ver = h.version
  for (let i = 0; i < 4; i++) {
    const a = autoAction(st, i)
    if (!a) continue
    const r = act(st, i, a)
    if (!r.ok) continue
    const c = await db.commit({ p_hand: h.id, p_version: ver, p_state: r.st, p_phase: r.st.phase, p_deadline: deadlineFor(r.st, now), p_seat: ring[i], p_actor: 'auto', p_action: a, p_result: resultFor(r.st, ring) })
    if (!c || !c.ok) break      // 別人剛好先動了（版本對不上）⇒ 這一輪不做，重讀
    st = r.st; ver = c.version
    if (st.phase === 'over') break
  }
  return db.ctx(ctx.session.id)
}

/* me ＝ online_me_tx 的回傳（已經用客人的登入憑證認過人）；body ＝ 手機送來的；now ＝ 毫秒；rand ＝ 0～1 的亂數 */
export async function handle(db, me, body, now, rand) {
  let ctx = await db.ctx(me.session_id)
  if (!ctx || !ctx.ok) return { ok: false, reason: (ctx && ctx.reason) || 'no_ctx' }
  const op = (body && body.op) || 'view'
  const out = (extra = {}) => ({ ...buildView(ctx, me.member_id, now), ...extra })

  if (op === 'view') { ctx = await advance(db, ctx, now, rand, false); return out() }
  if (op === 'next') { ctx = await advance(db, ctx, now, rand, true); return out() }
  if (op === 'tick') { ctx = await timeout(db, ctx, now); ctx = await advance(db, ctx, now, rand, false); return out() }

  if (op === 'bust') {
    const seat = seatOf(ctx, me.member_id)
    const r = await db.bustDecide({ p_session: ctx.session.id, p_seat: seat, p_amount: Math.max(0, Math.floor(Number(body.amount) || 0)) })
    ctx = await db.ctx(ctx.session.id)
    return r && r.ok ? out() : out({ ok: false, reason: (r && r.reason) || 'bust_failed', message: r && r.message })
  }

  /* 自己開／關「電腦代打」（牌桌左下角那顆）：記在座位上，另外三家的畫面才標得出「某某 電腦代打中」。
     只記旗標 —— 真正替他出牌的是他自己的手機（開著時手機自動送動作）；手機沒開著就照舊等逾時由後端代打 */
  if (op === 'auto') {
    const seat = seatOf(ctx, me.member_id)
    const r = await db.setAuto({ p_session: ctx.session.id, p_seat: seat, p_on: !!body.on })
    ctx = await db.ctx(ctx.session.id)
    return r && r.ok ? out() : out({ ok: false, reason: (r && r.reason) || 'auto_failed' })
  }

  if (op === 'act') {
    const h = playing(ctx)
    const seat = seatOf(ctx, me.member_id)
    if (!h) return out({ ok: false, reason: 'no_hand' })
    const idx = ctx.round.ring.indexOf(seat)
    if (idx < 0) return out({ ok: false, reason: 'not_seated' })
    if (body.version != null && body.version !== h.version) return out({ ok: false, reason: 'stale' })   // 你看到的不是最新的那一版
    const r = act(h.state, idx, body.action || {})
    if (!r.ok) return out({ ok: false, reason: r.error })
    const c = await db.commit({ p_hand: h.id, p_version: h.version, p_state: r.st, p_phase: r.st.phase, p_deadline: deadlineFor(r.st, now), p_seat: seat, p_actor: 'player', p_action: body.action, p_result: resultFor(r.st, ctx.round.ring) })
    ctx = await db.ctx(ctx.session.id)
    return c && c.ok ? out() : out({ ok: false, reason: (c && c.reason) || 'commit_failed' })
  }
  return out({ ok: false, reason: 'bad_op' })
}
