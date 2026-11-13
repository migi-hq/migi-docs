/* online-game 測試與本機模擬共用的工具（2026-11-11 從 core.test.mjs 抽出來）
   · CAT       牌型主檔的測試副本
   · fakeDb    假的資料庫：規則照 SQL 那幾支函式寫的縮小版（開一將、下一局、寫回、爆卡）
   · botAction 只看「手機拿到的畫面」出牌的機器人
   用的人：core.test.mjs（流程測試）、dev-server.mjs（本機模擬後端，給 App 的牌桌畫面接著測） */
import assert from 'node:assert/strict'
import { KIND_CODES } from './engine.mjs'

export const CAT = [
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

export const json = (x) => JSON.parse(JSON.stringify(x))   // 進出資料庫都會變成 JSON：狀態裡不能有 JSON 存不了的東西
export const sum = (a) => a.reduce((x, y) => x + y, 0)

/* 假的資料庫：規則照 SQL（online_start_round_tx／online_next_hand_tx／online_commit_tx／_tbl_round_state／爆卡夾帳） */
/* clock：一局結束的時間怎麼來。測試不給（固定值，結果才能重現）；本機模擬給真的時鐘（「15 秒沒人按就自動下一局」才會動） */
/* special：這一場開了哪幾個特殊規則（同 friendly_games.special_rules）。不給 ＝ 資料庫還沒有這一欄的樣子（引擎照舊三個都算） */
export function fakeDb({ planned = 1, base = 50, unit = 20, start = 2000, flower = false, clock = null, special = undefined, bots = 0 } = {}) {
  const D = {
    session: { id: 's1', org_id: 'o1', status: 'open', flower, planned_rounds: planned, base, unit, stake_label: `${base}/${unit}`, is_hygiene: false, channel: 'ch', game_type: '台麻', started_at: new Date(Date.now() - 754000).toISOString(), ...(special ? { special_rules: special } : {}) },
    game: { id: 'g1', status: 'playing' }, scored: false, bust: null, added: { 1: 0, 2: 0, 3: 0, 4: 0 },
    /* bots：後面幾位是電腦對手（同 members.is_bot）。bots = 3 ⇒ m1 是真人、m2～m4 是電腦 */
    players: ['m1', 'm2', 'm3', 'm4'].map((m, i) => ({ member_id: m, seat: null, nickname: m, is_bot: i >= 4 - bots })),
    rounds: [], ohands: [], hands: [], actions: [], calls: { startOk: 0, nextOk: 0 },
    presence: {},   // 同 online_seats：座位號 → { auto_since }；電腦代打時記下來，本人自己動作就清掉（畫面的「斷線 · 代打中」看它）
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
        players: D.players, balances: balances(), bust: D.bust, cat: CAT, presence: D.presence,
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
    /* 同 online_set_auto_tx：自己開的代打記在 auto_on，跟逾時代打的 auto_since 分開；座位沒人坐就拒絕 */
    async setAuto(a) {
      a = json(a)
      if (a.p_seat == null || !D.players.some((p) => p.seat === a.p_seat)) return { ok: false, reason: 'bad_seat' }
      D.presence[a.p_seat] = { auto_since: null, ...(D.presence[a.p_seat] || {}), auto_on: !!a.p_on }
      return { ok: true, auto_on: !!a.p_on }
    },
    /* 同 online_emote_tx：座位要有人、代碼格式、同一個座位 2 秒內只能送一次；只記最後一個與時間 */
    async emote(a) {
      a = json(a)
      if (a.p_seat == null || !D.players.some((p) => p.seat === a.p_seat)) return { ok: false, reason: 'bad_seat' }
      if (!/^[a-z]{2,16}$/.test(a.p_code || '')) return { ok: false, reason: 'bad_emote' }
      const at = clock ? clock() : '2026-01-01T00:00:00.000Z', last = D.presence[a.p_seat] && D.presence[a.p_seat].emote_at
      if (last && Date.parse(at) - Date.parse(last) < 2000) return { ok: false, reason: 'too_fast' }
      D.presence[a.p_seat] = { auto_on: false, auto_since: null, ...(D.presence[a.p_seat] || {}), emote: a.p_code, emote_at: at }
      return { ok: true, emote: a.p_code }
    },
    iceTurn: null,                        // 測試要模擬「有 Cloudflare 金鑰」就設成一份假的轉送伺服器清單
    async iceServers() { return db.iceTurn },   // 預設沒有金鑰 ⇒ 流程退回公開位址
    /* 同 online_ice_issue_tx：要坐著、同桌有別的真人、24 小時內有資格不超過 30 次；每次都記（D.iceLog） */
    async iceIssue(a) {
      a = json(a)
      D.iceLog = D.iceLog || []
      const meP = D.players.find((p) => p.member_id === a.p_member)
      let why = null
      if (D.session.status !== 'open') why = 'not_open'
      else if (!meP || meP.seat == null) why = 'not_seated'
      else if (!D.players.some((p) => p.member_id !== a.p_member && !p.is_bot)) why = 'no_humans'
      else if (D.iceLog.filter((x) => x.member === a.p_member && x.eligible).length >= 30) why = 'daily_limit'
      D.iceLog.push({ member: a.p_member, eligible: !why, reason: why })
      return { ok: true, eligible: !why, reason: why }
    },
    async commit(a) {
      a = json(a)
      const h = D.ohands.find((x) => x.id === a.p_hand)
      if (!h || h.status !== 'playing' || h.version !== a.p_version) return { ok: false, reason: 'stale' }
      h.state = a.p_state; h.phase = a.p_phase; h.deadline_at = a.p_deadline; h.version++
      D.actions.push({ hand: h.id, version: h.version, seat: a.p_seat, actor: a.p_actor, action: a.p_action })
      if (a.p_seat != null) D.presence[a.p_seat] = { ...(D.presence[a.p_seat] || { auto_on: false }), auto_since: a.p_actor === 'player' ? null : (D.presence[a.p_seat] && D.presence[a.p_seat].auto_since) || 'auto' }
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
      h.status = 'finished'; h.ended_at = clock ? clock() : '2026-01-01T00:00:00.000Z'; h.hand_ref = D.hands.length - 1; h.deadline_at = null
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

/* 只看畫面出牌的機器人（同 engine.test.mjs 的打法，差別是它只拿得到 viewFor 給的東西） */
export function botAction(v, rand) {
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
