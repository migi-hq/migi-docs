// @ts-nocheck
/* 🔴 這個檔案是產生出來的（node supabase/functions/online-game/build.mjs），不要手改。
   它是 engine.mjs ＋ core.mjs ＋ index.ts 三支合起來的樣子，只用來貼進 Supabase Dashboard。
   要改東西請改那三支，跑測試，再重跑 build.mjs。 */
/* ============================================================
   online-game —— 線上好友房的後端入口（四支手機都打這一支）
   2026-11-11 建立 · MIGI 咪吉麻將
   📄 規格：docs/03-會員App與社交/線上好友房.md

   這一支很薄，只做三件事：
   ① 認人：拿客人自己的登入憑證（Authorization 標頭）去叫 online_me_tx —— 身分由資料庫的 current_member_id() 決定，
      手機送什麼會員編號都沒用（同硬規則 5.8：前端只送意圖）
   ② 把「叫資料庫」的幾支函式交給 core.mjs（流程）；core.mjs 再用 engine.mjs（規則）
   ③ 把 core.mjs 給的畫面原樣回給手機 —— 那一份已經過濾過，每一家只拿得到自己看得到的牌

   🔴 四家手牌與牌山只存在兩個地方：資料庫的 online_hands.state、這支函式跑的那幾毫秒。
      讀寫那張表用的是 service_role（平台自動注入），那把鑰匙不會離開這裡。

   手機怎麼叫：POST，本文是 JSON
     { "op": "view" }                                   讀現在的畫面（第一次有人讀就開第一將）
     { "op": "act", "version": 12, "action": {…} }      做一個動作（打牌、吃、碰、槓、胡、過、MIGI、眼牌、選豹子倍數）
     { "op": "tick" }                                   時間到了請後端處理（逾時代打、自動開下一局）
     { "op": "next" }                                   現在就開下一局／下一將
     { "op": "bust", "amount": 500 }                    爆卡的人決定：> 0 追加積分，0 結束整場
     { "op": "emote", "code": "nice" }                  送一個小熊表情（另外三家在那一家名牌下面看到）
     { "op": "ice" }                                    即時通話用的連線伺服器資料（有設 CF_TURN_KEY_ID／CF_TURN_KEY_TOKEN 才含轉送）

   ── 部署 ────────────────────────────────────────────
   原始碼是三支（為了能各自測試）：index.ts（這一支）、core.mjs（流程）、engine.mjs（牌局規則）。
   部署時**只貼一個檔案**：同資料夾的「部署用_整支貼上.ts」—— 它是那三支合起來的樣子，由 build.mjs 產生。
   Supabase Dashboard → Edge Functions → 新增 `online-game` → 把「部署用_整支貼上.ts」整個貼上 → Deploy
   **Verify JWT 要開著**（預設就是開的）：沒登入的人連這支都進不來。
   Secrets：不用另外設。SUPABASE_URL／SUPABASE_ANON_KEY／SUPABASE_SERVICE_ROLE_KEY 都由平台自動注入。
   前置：sql/applied/2026-11-11_線上好友房_資料表.sql 與 …_建局與動作.sql 都要先跑過。

   改規則 ⇒ 改 engine.mjs；改流程 ⇒ 改 core.mjs；兩支都有測試（同資料夾的 *.test.mjs，用 node 直接跑）。
   改完 ⇒ 跑測試 ⇒ `node supabase/functions/online-game/build.mjs` 重新產生 ⇒ 整個重貼、重新部署。
   🔴 不要直接改「部署用_整支貼上.ts」—— 下次重新產生就被蓋掉，而且那三支不會跟著變。
   ============================================================ */

/* ═══════════ 牌局規則（engine.mjs）═══════════ */
const ENGINE = (() => {
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
  const KIND_CODES = [
    ...NUMS.map((n) => n + 'm'), ...NUMS.map((n) => n + 'p'), ...NUMS.map((n) => n + 't'),
    'E0', 'S0', 'W0', 'N0', 'C0', 'F0', 'B0',
  ]
  /* 春夏秋冬 H1–H4、梅蘭竹菊 H5–H8；東位的正花是 H1、H5，南位 H2、H6，以此類推 */
  const FLOWER_CODES = ['H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'H7', 'H8']
  const IDX = Object.fromEntries(KIND_CODES.map((c, i) => [c, i]))
  const isFlower = (c) => c[0] === 'H'
  const kindOf = (c) => IDX[c]
  const isHonor = (k) => k >= 27
  const isWind = (k) => k >= 27 && k <= 30
  const isDragon = (k) => k >= 31
  const suitOf = (k) => (k < 27 ? Math.floor(k / 9) : 3)
  const rankOf = (k) => k % 9

  /* 鐵七敦：最後 14 張不摸，牌山剩 14 張就流局（店內「桌上規則及禮儀」） */
  const KEEP = 14
  const SETS = 5        // 十六張：五組 ＋ 一對
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

  function counts(tiles) {
    const c = new Array(34).fill(0)
    for (const t of tiles) if (!isFlower(t)) c[kindOf(t)]++
    return c
  }
  const sum = (c) => c.reduce((a, b) => a + b, 0)

  function sortTiles(tiles) {
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
  function canWin(c, n) {
    if (sum(c) !== 3 * n + 2) return false
    for (let k = 0; k < 34; k++) {
      if (c[k] >= 2) { c[k] -= 2; const ok = setsOk(c, n); c[k] += 2; if (ok) return true }
    }
    return false
  }

  /* 聽哪幾種牌（c 是 3n＋1 張）。自己手上已經四張的那一種不算 */
  function waits(c, n) {
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
  function decompositions(c, n) {
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
     base／unit：底與每台的積分；dealer／ren：莊家座位與連莊數（上一局的 result.next）
     dice：每一局都擲一次骰子（2026-11-11 使用者：「每一局都要骰」），骰子台看這一擲。
           第一局要傳「定莊家那一擲」進來（開局擲兩次：定座位、定莊家，骰子台看定莊家那次）；
           第二局起不傳，由 seed 自己擲
     rules：這一場開了哪幾個特殊規則（2026-11-11 使用者：開一場時「特殊規則」可以勾 骰龜／豹子／全紅，預設都不開）。
           給陣列 ⇒ 只算裡面有的（例 ['shaigui']；空陣列 ＝ 三個都不算）；**不給 ⇒ 三個都算**（這個選項出現之前開的局、以及既有測試的行為） */
  const SPECIAL_RULES = ['quanhong', 'shaigui', 'baozi']
  const ruleOn = (st, code) => !st.rules || st.rules.includes(code)
  /* yan：這一場能不能喊眼牌。預設可以（既有測試與舊的局）；牌桌後端目前一律傳 false ——
          2026-11-11 使用者：「眼牌功能先隱藏」。傳 false ⇒ 沒有人拿得到眼牌這個選項，硬送也會被擋 */
  function newGame({ seed, flower = false, dealer = 0, ren = 0, base = 0, unit = 0, cat = [], dice: given = null, rules = null, yan = true }) {
    const r = rng(seed)
    const wall = []
    for (const c of KIND_CODES) for (let i = 0; i < 4; i++) wall.push(c)
    if (flower) wall.push(...FLOWER_CODES)
    for (let i = wall.length - 1; i > 0; i--) { const j = Math.floor(r() * (i + 1)); [wall[i], wall[j]] = [wall[j], wall[i]] }
    /* 照樣先擲（不管有沒有傳進來）⇒ 同一個 seed 洗出來的牌永遠一樣 */
    const rolled = [0, 0, 0].map(() => 1 + Math.floor(r() * 6))
    if (given != null && !(Array.isArray(given) && given.length === 3 && given.every((d) => Number.isInteger(d) && d >= 1 && d <= 6))) {
      throw new Error('dice_invalid')
    }
    const dice = given ? [...given] : rolled

    const st = {
      v: 1, seed, flower, dealer, ren, base, unit, dice,
      /* 有花的局要多加的互斥（flower_conflicts，例：平胡 ↔ 門清）在這裡併進去，之後算台只看 conflicts */
      cat: cat.map((p) => ({ code: p.code, tai: p.tai, max_count: p.max_count || 1,
        conflicts: [...(p.conflicts || []), ...(flower ? p.flower_conflicts || [] : [])] })),
      wall, hands: [[], [], [], []], melds: [[], [], [], []], flowers: [[], [], [], []], discards: [[], [], [], []],
      turn: dealer, phase: 'deal', drawn: null, src: null, last: false,
      turns: [0, 0, 0, 0], called: false, migi: [false, false, false, false], yan: [false, false, false, false],
      claim: null, result: null, log: [{ e: 'start', dealer, ren, dice }],
      baozi: 1,   // 豹子倍數：1 ＝ 沒有或放棄、2、3（莊家開局選的）
      rules: Array.isArray(rules) ? SPECIAL_RULES.filter((c) => rules.includes(c)) : null,   // 開了哪幾個特殊規則；null ＝ 三個都算（舊的局）
      noYan: yan === false,   // 這一場眼牌沒開
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
      st.phase = ruleOn(st, 'baozi') && dice[0] === dice[1] && dice[1] === dice[2] ? 'baozi' : 'discard'   // 沒開豹子這條規則 ⇒ 擲出三顆一樣也直接開打
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
  function act(st0, seat, a) {
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
  function migiOk(st, s, tile) {
    return !st.called && st.turns[s] < MIGI_TURNS && !st.migi[s] && st.hands[s].includes(tile) && tenpaiAfter(st, s, tile)
  }
  /* 眼牌：還沒眼過，打這張之後聽牌 */
  function yanOk(st, s, tile) {
    if (st.noYan) return false   // 這一場眼牌沒開（2026-11-11 使用者：眼牌功能先隱藏）
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

  /* 別家能不能要這張：胡（任何一家）、碰（任何一家）、明槓（上家打的不行）、吃（只有下家）。眼牌的人只能胡、而且自動胡
     🆕 2026-11-12 使用者：「不能槓上家」—— d === 1 的那一家就是打牌那一家的下家，也就是說打牌的人是他的上家 ⇒ 不給槓（碰照舊） */
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
        if (d !== 1 && c[k] >= 3 && st.wall.length > KEEP) op.kong = true
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
      /* tiles 照舊排好序（算台看 tiles[0] 是哪一順）；take ＝ 吃來的那一張，畫面用它把那張排在中間（2026-11-12 使用者） */
      st.melds[ch].push({ t: 'chi', tiles: sortTiles([...two, cl.tile]), take: cl.tile, from: cl.from })
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
  function scoreWin(st, w, ctx) {
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
    /* 三個骰子規則各自要「這一場有開」才算（沒開的話擲出來也只是骰子） */
    const diceRed = ruleOn(st, 'quanhong') && st.dice.every((d) => RED_DICE.includes(d))
    /* 骰龜：三顆骰子是順子（1-2-3、2-3-4、3-4-5、4-5-6，順序不拘；2026-11-09 使用者） */
    const ds = [...st.dice].sort((a, b) => a - b)
    const diceRun = ruleOn(st, 'shaigui') && ds[1] === ds[0] + 1 && ds[2] === ds[1] + 1
    /* 豹子：三顆骰子一樣，莊家開局選 ×2／×3／放棄（st.baozi）⇒ 整筆乘（含底與莊家台，同計分板 rules.js）。
       主檔 baozi 的次數 ＝ 倍數 − 1（同計分板按 1 次 ×2、按 2 次 ×3）；不管誰胡都算（2026-11-09 使用者） */
    const baoziN = ruleOn(st, 'baozi') ? (st.baozi || 1) - 1 : 0
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
          /* 平胡：手上有花就沒有平胡；有花的局平胡跟門清只能二選一（主檔 flower_conflicts，建局時併進 conflicts） */
          if (!tsumo && !(st.flower && fl.length) && pungs.length === 0 && !honors && w8.length >= 2 && twoSided) add('pinghu')
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
  function optionsFor(st, s) {
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
          if (!st.noYan) o.yan = Object.keys(listen)
        }
      }
      return o
    }
    if (st.phase === 'claim' && st.claim.options[s] && !st.claim.resp[s]) return { claim: st.claim.options[s], tile: st.claim.tile }
    return null
  }

  /* 逾時時電腦替他做什麼：出牌就打剛摸的（沒有就打最後一張），搶牌就跳過 */
  function autoAction(st, s) {
    if (st.phase === 'baozi' && s === st.dealer) return { type: 'baozi', mult: 1 }   // 莊家沒選 ⇒ 當作放棄（不替他加重輸贏）
    if (st.phase === 'discard' && st.turn === s) return { type: 'discard', tile: st.drawn || st.hands[s][st.hands[s].length - 1] }
    if (st.phase === 'claim' && st.claim.options[s] && !st.claim.resp[s]) return { type: 'pass' }
    return null
  }

  /* ── 電腦的打法（牌理）────────────────────────────────────────
     2026-11-11 使用者：電腦對手與電腦代打用**同一套**牌理；會吃碰槓；MIGI 該喊就喊；眼牌先隱藏所以不喊。
     做法是「規則式」（市面上休閒麻將的電腦大多是這一級），不用任何資料庫、也不用牌譜：
       · 向聽數：這手牌離聽牌還差幾步（-1 ＝ 已經胡、0 ＝ 聽牌）
       · 進張數：摸到哪幾種牌會讓向聽數變小，那幾種牌外面還剩幾張
     出牌：每一張試著打掉，留向聽數最小的；一樣小就留進張最多的；再一樣就先丟字牌與么九。
     吃碰槓：能讓向聽數變小才叫（槓是不變差就槓，多摸一張）。能胡就胡。
     🔴 只看「這一家自己看得到的東西」：吃的是 viewFor 給的那一份畫面，所以它拿不到別家的手牌與牌山 —— 電腦不偷看。
     ⚠ 還不會的：防守（有人聽牌時改打安全牌）、算台數挑大牌、記別人打過什麼來猜牌。它只會顧自己的手牌最快聽、最快胡。
     ⚠ 莊家擲出豹子時一律放棄（不替人加重輸贏；電腦對手也一樣） */

  /* 向聽數。c 是手上牌的張數（3n＋1 或 3n＋2 張都可以，後者等於「打掉最沒用的一張之後」），n 是還要湊幾組。
     算法：萬、筒、索、字四門各自列出「可以拆出幾組完成的、幾個搭子、有沒有留一對當眼」的所有組合，再四門合起來挑最好的。
     一門只有 9 種牌，組合很少，而且**算過的記起來**（同一門同樣的張數一定同一個答案）——
     電腦挑牌時要算幾百次，每次只動到一門，其他三門直接拿記好的。
     🗑 第一版是整手 34 種牌一起遞迴，最慢的一步要 820 毫秒，對後端太久 */
  const SUIT_MEMO = new Map()
  function suitCombos(a, honor) {
    const key = (honor ? 'h' : 's') + a.join('')
    const hit = SUIT_MEMO.get(key)
    if (hit) return hit
    const out = new Set(), c = a.slice(), L = c.length
    const scan = (i, m, t, pair) => {
      while (i < L && c[i] === 0) i++
      if (i >= L) { out.add(m * 100 + t * 10 + pair); return }
      if (c[i] >= 3) { c[i] -= 3; scan(i, m + 1, t, pair); c[i] += 3 }
      if (!honor && i <= L - 3 && c[i + 1] > 0 && c[i + 2] > 0) { c[i]--; c[i + 1]--; c[i + 2]--; scan(i, m + 1, t, pair); c[i]++; c[i + 1]++; c[i + 2]++ }
      if (c[i] >= 2) {
        c[i] -= 2
        if (!pair) scan(i, m, t, 1)      // 這一對當眼
        scan(i, m, t + 1, pair)          // 這一對當搭子（等第三張）
        c[i] += 2
      }
      if (!honor && i <= L - 2 && c[i + 1] > 0) { c[i]--; c[i + 1]--; scan(i, m, t + 1, pair); c[i]++; c[i + 1]++ }
      if (!honor && i <= L - 3 && c[i + 2] > 0) { c[i]--; c[i + 2]--; scan(i, m, t + 1, pair); c[i]++; c[i + 2]++ }
      const k = c[i]; c[i] = 0; scan(i + 1, m, t, pair); c[i] = k    // 這一種剩下的都當成用不到的孤張
    }
    scan(0, 0, 0, 0)
    /* 只留不會被別的組合完全比下去的（組數、搭子數、有沒有眼都不輸它的） */
    const all = [...out].map((x) => [Math.floor(x / 100), Math.floor(x / 10) % 10, x % 10])
    const keep = all.filter((p) => !all.some((q) => q !== p && q[0] >= p[0] && q[1] >= p[1] && q[2] >= p[2] && (q[0] > p[0] || q[1] > p[1] || q[2] > p[2])))
    if (SUIT_MEMO.size > 20000) SUIT_MEMO.clear()
    SUIT_MEMO.set(key, keep)
    return keep
  }
  function shanten(c, n) {
    let acc = [[0, 0, 0]]
    for (const [from, to, honor] of [[0, 9, false], [9, 18, false], [18, 27, false], [27, 34, true]]) {
      const part = suitCombos(c.slice(from, to), honor)
      const next = new Map()
      for (const [m1, t1, p1] of acc) for (const [m2, t2, p2] of part) {
        if (p1 + p2 > 1) continue                       // 眼只有一對
        const m = m1 + m2, t = t1 + t2, p = p1 + p2
        next.set(m * 100 + t * 10 + p, [m, t, p])
      }
      acc = [...next.values()]
    }
    let best = 2 * n
    for (const [m0, t, p] of acc) {
      const m = Math.min(m0, n)
      const v = 2 * n - 2 * m - Math.min(t, n - m) - p
      if (v < best) best = v
    }
    return best
  }

  /* 電腦這一步要做什麼。v ＝ viewFor(st, 座位) 給的那一份畫面（跟真人手機拿到的一模一樣）。沒事可做回 null */
  function botMove(v) {
    const o = v && v.options
    if (!o) return null
    if (o.baozi) return { type: 'baozi', mult: 1 }
    const me = v.players[v.seat], hand = me.hand || [], n = SETS - me.melds.length
    /* 看得到的牌：四家的牌河、亮出來的吃碰槓、自己的手牌 ⇒ 每一種牌外面最多還剩幾張 */
    const seen = new Array(34).fill(0)
    const see = (t) => { if (t && !isFlower(t)) seen[kindOf(t)]++ }
    v.players.forEach((p) => { p.discards.forEach(see); p.melds.forEach((m) => (m.tiles || []).forEach(see)) })
    hand.forEach(see)
    const left = (k) => Math.max(0, 4 - seen[k])
    const c = counts(hand)

    if (o.claim) {
      if (o.claim.hu) return { type: 'hu' }
      const now = shanten(c, n), k = kindOf(o.tile)
      let best = null
      const consider = (action, s, ok) => { if (ok && (!best || s < best.s)) best = { s, action } }
      if (o.claim.kong && c[k] >= 3) { c[k] -= 3; const s = shanten(c, n - 1); c[k] += 3; consider({ type: 'kong' }, s, s <= now) }
      if (o.claim.pong && c[k] >= 2) { c[k] -= 2; const s = shanten(c, n - 1); c[k] += 2; consider({ type: 'pong' }, s, s < now) }
      for (const pair of (Array.isArray(o.claim.chi) ? o.claim.chi : [])) {
        const [a, b] = pair.map(kindOf)
        if (c[a] < 1 || c[b] < 1) continue
        c[a]--; c[b]--; const s = shanten(c, n - 1); c[a]++; c[b]++
        consider({ type: 'chi', tiles: pair }, s, s < now)
      }
      return best ? best.action : { type: 'pass' }
    }

    if (o.discard) {
      if (o.tsumo) return { type: 'tsumo' }
      if (o.locked) return { type: 'discard', tile: v.drawn || hand[hand.length - 1] }   // 喊過眼牌：只能摸什麼打什麼
      const now = shanten(c, n)
      for (const t of o.kongs || []) {
        const k = kindOf(t)
        if (c[k] === 4) { c[k] = 0; const s = shanten(c, n - 1); c[k] = 4; if (s <= now) return { type: 'kong', tile: t } }          // 暗槓
        else if (c[k] >= 1) { c[k]--; const s = shanten(c, n); c[k]++; if (s <= now) return { type: 'kong', tile: t } }              // 加槓：那一張本來就用不到
      }
      /* 打完就聽牌：挑外面還剩最多張的那一種聽法；能喊 MIGI 的優先（MIGI 該喊就喊） */
      const listen = o.listen ? Object.entries(o.listen) : []
      if (listen.length) {
        const score = ([t, ws]) => ws.reduce((a, w) => a + left(kindOf(w)), 0) + (o.migi && o.migi.includes(t) ? 1000 : 0)
        const [tile] = listen.slice().sort((a, b) => score(b) - score(a))[0]
        return { type: 'discard', tile, migi: !!(o.migi && o.migi.includes(tile)) }
      }
      /* 還沒聽：每一種牌試著打掉 */
      let cand = [...new Set(hand)].map((t) => { const k = kindOf(t); c[k]--; const s = shanten(c, n); c[k]++; return { t, k, s } })
      const min = Math.min(...cand.map((x) => x.s))
      cand = cand.filter((x) => x.s === min)
      if (cand.length > 1) {
        for (const x of cand) {
          c[x.k]--
          let u = 0
          for (let j = 0; j < 34; j++) {
            if (left(j) === 0 || c[j] >= 4) continue
            c[j]++; if (shanten(c, n) < min) u += left(j); c[j]--
          }
          c[x.k]++
          x.u = u
        }
        const edge = (k) => (isHonor(k) ? 3 : rankOf(k) === 0 || rankOf(k) === 8 ? 2 : rankOf(k) === 1 || rankOf(k) === 7 ? 1 : 0)
        cand.sort((a, b) => b.u - a.u || edge(b.k) - edge(a.k))
      }
      return { type: 'discard', tile: cand[0].t }
    }
    return null
  }

  /* 🔴 這一份才可以送給 s 那一家的手機：別家的手牌只給張數；暗槓蓋著。
     眼牌的人看得到別家手牌、暗槓與牌山；牌局結束全部攤開。seed 永遠不給（拿到就算得出整副牌山） */
  function viewFor(st, s) {
    const see = st.yan[s] || st.phase === 'over'
    return {
      seat: s, dealer: st.dealer, ren: st.ren, turn: st.turn, phase: st.phase, flower: st.flower, dice: st.dice, baozi: st.baozi,
      rules: st.rules || SPECIAL_RULES,   // 這一場開了哪幾個特殊規則（畫面的骰子標籤只標有開的）
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

  return { newGame, act, viewFor, autoAction, botMove }
})()

/* ═══════════ 流程（core.mjs）═══════════ */
const CORE = (() => {
  const { newGame, act, viewFor, autoAction, botMove } = ENGINE
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
       emote 送一個小熊表情：{ code }（只收 EMOTES 裡的）
       ice   即時通話用的連線伺服器資料（回 { iceServers }；有設 Cloudflare 轉送金鑰才含轉送）
     ============================================================ */

  const TURN_MS = 15000        // 出牌 15 秒（含莊家選豹子倍數）
  const CLAIM_MS = 5000        // 別人打牌後要不要吃碰槓胡 5 秒
  const DEAL_MS = 7000         // 發牌動畫的時間：新的一局第一步多給這麼久
  const ROUND_MS = 9000        // 開一將還要演兩次擲骰子：再多給這麼久
  const NEXT_AFTER_MS = 15000  // 一局打完沒人按「下一局」，過這麼久自動開
  /* 小熊表情的代碼（2026-11-13）：讚啦、加油、快一點、好險、謝謝、拍謝。句子與小熊動作寫在 App 那一層；要加一個就兩邊一起加 */
  const EMOTES = ['nice', 'cheer', 'hurry', 'close', 'thanks', 'sorry']
  /* 即時通話的公開位址伺服器（STUN，免費、不用帳號）：轉送金鑰還沒設、或 Cloudflare 那邊拿不到時用這份 ⇒ 大部分網路照樣直接互連 */
  const FALLBACK_ICE = [{ urls: ['stun:stun.cloudflare.com:3478', 'stun:stun.l.google.com:19302'] }]

  const ms = (t) => (t ? new Date(t).getTime() : null)
  const iso = (n) => (n == null ? null : new Date(n).toISOString())

  function deadlineFor(st, now, extra = 0) {
    if (st.phase === 'discard' || st.phase === 'baozi') return iso(now + TURN_MS + extra)
    if (st.phase === 'claim') return iso(now + CLAIM_MS + extra)
    return null
  }

  /* 打完的一局換成資料庫要的樣子（座位換回 1～4）。tai ＝ 牌型台（已乘豹子、不含莊家台），同計分板 hands.tai_pattern */
  function resultFor(st, ring) {
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
  /* rules：這一場開了哪幾個特殊規則（骰龜／豹子／全紅）。資料庫給陣列就照它（空陣列 ＝ 都不算）；
     沒給（這一欄出現之前的資料庫）⇒ 不傳，引擎照舊三個都算 */
  /* 眼牌功能先隱藏（2026-11-11 使用者）：新開的每一局都不給喊。要打開時把這裡改成 true、重新部署就好（引擎與畫面都還在） */
  const YAN_OPEN = false
  const engineArgs = (ctx) => ({ flower: !!ctx.session.flower, base: ctx.session.base, unit: ctx.session.unit, cat: ctx.cat || [],
    rules: Array.isArray(ctx.session.special_rules) ? ctx.session.special_rules : null,
    yan: YAN_OPEN })
  const blocked = (ctx) => ctx.scored || !!ctx.bust || ctx.session.status !== 'open'

  /* 現在卡在哪：playing 正在打／hand_over 這一局打完等下一局／round_over 這一將打完等下一將／
     game_over 整場打完（成績已算）／bust 有人爆卡等他決定／starting 還沒開第一將 */
  function stageOf(ctx) {
    if (ctx.scored) return 'game_over'
    if (ctx.bust) return 'bust'
    if (playing(ctx)) return 'playing'
    if (!ctx.round) return 'starting'
    if (ctx.round.status === 'playing' && !(ctx.round.state && ctx.round.state.finished)) return 'hand_over'
    return ctx.rounds_done < ctx.session.planned_rounds ? 'round_over' : 'game_over'
  }

  /* 給某一家手機的畫面 */
  function buildView(ctx, memberId, now) {
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
        game_type: ctx.session.game_type || null, started_at: ctx.session.started_at || null,
        special_rules: Array.isArray(ctx.session.special_rules) ? ctx.session.special_rules : null },
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
      /* 逾時過一次 ⇒ 替他把「電腦代打」打開（2026-11-11 使用者：逾時被接手的人也要跟著加快 ⇒「要」）。
         之後輪到他就走 autoFast（1.2 秒），不用每一手都等滿倒數。只有一個概念、一顆開關：
         他回來時自己手機左下角那顆是亮的，按一下就關掉、拿回來自己打（op auto off）。
         不另外做一套「逾時的人也加快」：那樣他回來沒有東西可以按，每一手只剩 1.2 秒搶 */
      if (!autoSeat(ctx, ring[i])) await db.setAuto({ p_session: ctx.session.id, p_seat: ring[i], p_on: true })
      if (st.phase === 'over') break
    }
    return db.ctx(ctx.session.id)
  }

  /* 由電腦出手的座位：自己開了「電腦代打」的人（座位上的 auto_on），以及電腦對手（players 的 is_bot）。
     2026-11-11 使用者：兩者**同一套牌理**（engine.mjs 的 botMove：會吃碰槓、能胡就胡、MIGI 該喊就喊），爆卡都**直接結束整場**。
     · 不等倒數：輪到他 AUTO_MS 之後就出手
     · 這一步什麼時候開始：期限 − 這一種步驟給的秒數。新的一局第一步的期限多加了發牌動畫的時間，
       所以算出來的「開始」剛好落在發完牌之後，不會牌還在發就打出去
     · 一次只做一步（出牌、吃碰槓、胡）：下一步要重新等 AUTO_MS，不然桌上好幾個電腦時牌會一瞬間打完。
       「過」可以幾個人一起（那一步本來就在等大家回答）
     · 牌理算不出東西、或引擎不接受時，退回最保守的做法（打剛摸的、過）——寧可打得笨，不可以卡住
     · 誰來觸發：任何一家的手機讀畫面（view）或報時間到（tick）時順便做 —— 後端自己不會醒來
     🗑 原本能胡的那一步會跳過不做（留給本人的手機）：電腦對手沒有手機，會每次白等滿倒數；現在一律能胡就胡 */
  const AUTO_MS = 1200
  const isBot = (ctx, seat) => (ctx.players || []).some((p) => p.seat === seat && p.is_bot)
  const autoSeat = (ctx, seat) => isBot(ctx, seat) || !!(ctx.presence && ctx.presence[seat] && ctx.presence[seat].auto_on)
  async function autoFast(db, ctx, now) {
    const h = playing(ctx)
    if (!h || !h.deadline_at || !ctx.round) return ctx
    const ring = ctx.round.ring
    if (!ring.some((s) => autoSeat(ctx, s))) return ctx
    const span = h.state.phase === 'claim' ? CLAIM_MS : TURN_MS
    if (now < ms(h.deadline_at) - span + AUTO_MS) return ctx
    let st = h.state, ver = h.version, did = false
    for (let i = 0; i < 4; i++) {
      if (!autoSeat(ctx, ring[i])) continue
      let a = null, r = null
      try { a = botMove(viewFor(st, i)) } catch (e) { a = null }
      if (a) r = act(st, i, a)
      if (!a || !r.ok) { a = autoAction(st, i); if (!a) continue; r = act(st, i, a); if (!r.ok) continue }
      const c = await db.commit({ p_hand: h.id, p_version: ver, p_state: r.st, p_phase: r.st.phase, p_deadline: deadlineFor(r.st, now), p_seat: ring[i], p_actor: 'auto', p_action: a, p_result: resultFor(r.st, ring) })
      if (!c || !c.ok) break      // 別人剛好先動了（版本對不上）⇒ 這一輪不做，重讀
      st = r.st; ver = c.version; did = true
      if (a.type !== 'pass' || st.phase === 'over') break
    }
    return did ? db.ctx(ctx.session.id) : ctx
  }
  /* 爆卡的是電腦對手、或開著電腦代打的人 ⇒ 不等他決定，直接結束整場（2026-11-11 使用者：「兩者爆卡都直接結束」） */
  async function autoBust(db, ctx) {
    if (!ctx.bust || ctx.scored || !autoSeat(ctx, ctx.bust.seat)) return ctx
    const r = await db.bustDecide({ p_session: ctx.session.id, p_seat: ctx.bust.seat, p_amount: 0 })
    return r && r.ok ? db.ctx(ctx.session.id) : ctx
  }


  /* me ＝ online_me_tx 的回傳（已經用客人的登入憑證認過人）；body ＝ 手機送來的；now ＝ 毫秒；rand ＝ 0～1 的亂數 */
  async function handle(db, me, body, now, rand) {
    let ctx = await db.ctx(me.session_id)
    if (!ctx || !ctx.ok) return { ok: false, reason: (ctx && ctx.reason) || 'no_ctx' }
    const op = (body && body.op) || 'view'
    const out = (extra = {}) => ({ ...buildView(ctx, me.member_id, now), ...extra })

    if (op === 'view') { ctx = await autoBust(db, ctx); ctx = await autoFast(db, ctx, now); ctx = await advance(db, ctx, now, rand, false); return out() }
    if (op === 'next') { ctx = await autoBust(db, ctx); ctx = await advance(db, ctx, now, rand, true); return out() }
    // 先讓電腦用牌理出手，再處理逾時：反過來的話，期限過了的電腦座位會先被「逾時代打」用最笨的打法打掉
    if (op === 'tick') { ctx = await autoBust(db, ctx); ctx = await autoFast(db, ctx, now); ctx = await timeout(db, ctx, now); ctx = await advance(db, ctx, now, rand, false); return out() }

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

    /* 小熊表情（2026-11-13 使用者）：記在座位上（同電腦代打），另外三家重讀時在那一家名牌下面冒泡泡。
       只收 EMOTES 裡的代碼；句子寫在 App（onlineTable.jsx 的 EMOTE_TEXT），這裡只管「是不是合法的那幾個」。
       同一個座位 2 秒內只能送一次 —— 資料庫那支（online_emote_tx）自己擋 */
    if (op === 'emote') {
      const seat = seatOf(ctx, me.member_id)
      const code = body && body.code
      if (!EMOTES.includes(code)) return out({ ok: false, reason: 'bad_emote' })
      const r = await db.emote({ p_session: ctx.session.id, p_seat: seat, p_code: code })
      ctx = await db.ctx(ctx.session.id)
      return r && r.ok ? out() : out({ ok: false, reason: (r && r.reason) || 'emote_failed' })
    }

    /* 即時通話（2026-11-13 使用者選 A：四支手機直接互連傳聲音，不經過收費的語音公司）。
       這一支只發「連線用的伺服器資料」（ICE servers）：直接連不上時改走 Cloudflare 的轉送（TURN），轉送要短期憑證，金鑰只放在後端。
       配對（誰跟誰連、交換連線位址）走牌桌本來就有的即時頻道，聲音本身不經過我們的伺服器，也不錄、不存 */
    if (op === 'ice') {
      const servers = await db.iceServers()
      return { ok: true, iceServers: Array.isArray(servers) && servers.length ? servers : FALLBACK_ICE }
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

  return { handle }
})()
const { handle } = CORE

/* ═══════════ 入口（index.ts）═══════════ */
// deno-lint-ignore-file no-explicit-any

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } })

/* auth 有給 ＝ 用客人的身分叫（只有 online_me_tx）；沒給 ＝ 用後端的身分叫（其餘全部） */
async function rpc(fn: string, args: Record<string, unknown>, auth?: string): Promise<any> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: auth ? ANON_KEY : SERVICE_KEY,
      Authorization: auth ?? `Bearer ${SERVICE_KEY}`,
    },
    body: JSON.stringify(args),
  })
  const text = await r.text()
  if (!r.ok) throw new Error(`${fn} ${r.status}: ${text.slice(0, 300)}`)
  return text ? JSON.parse(text) : null
}

const db = {
  ctx: (sid: string) => rpc('_online_ctx', { p_session: sid }),
  startRound: (a: Record<string, unknown>) => rpc('online_start_round_tx', a),
  nextHand: (a: Record<string, unknown>) => rpc('online_next_hand_tx', a),
  commit: (a: Record<string, unknown>) => rpc('online_commit_tx', a),
  bustDecide: (a: Record<string, unknown>) => rpc('online_bust_decide_tx', a),
  setAuto: (a: Record<string, unknown>) => rpc('online_set_auto_tx', a),
  emote: (a: Record<string, unknown>) => rpc('online_emote_tx', a),
  iceServers,
}

/* 即時通話的轉送伺服器（Cloudflare Realtime TURN）：拿後端的金鑰換一份 24 小時有效的短期憑證給手機。
   Secrets：CF_TURN_KEY_ID、CF_TURN_KEY_TOKEN（Cloudflare 後台 → Realtime → TURN Server 建一把 key 拿到的兩個值）。
   沒設、或 Cloudflare 回錯 ⇒ 回 null，流程改用免費的公開位址（core.mjs 的 FALLBACK_ICE），大部分網路照樣通 */
async function iceServers(): Promise<unknown[] | null> {
  const id = Deno.env.get('CF_TURN_KEY_ID'), token = Deno.env.get('CF_TURN_KEY_TOKEN')
  if (!id || !token) return null
  try {
    const r = await fetch(`https://rtc.live.cloudflare.com/v1/turn/keys/${id}/credentials/generate-ice-servers`, {
      method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ ttl: 86400 }),
    })
    const j: any = await r.json().catch(() => null)
    if (!r.ok || !j || !j.iceServers) { console.error('turn', r.status, JSON.stringify(j).slice(0, 200)); return null }
    return Array.isArray(j.iceServers) ? j.iceServers : [j.iceServers]
  } catch (e) {
    console.error('turn', String(e)); return null
  }
}

/* 洗牌的種子與骰子用系統的亂數（不是 Math.random —— 那個猜得出來） */
const rand = () => crypto.getRandomValues(new Uint32Array(1))[0] / 4294967296

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS })
  if (req.method !== 'POST') return json({ ok: false, reason: 'method_not_allowed' }, 405)
  const auth = req.headers.get('Authorization')
  if (!auth) return json({ ok: false, reason: 'unauthorized', message: '請先登入' }, 401)

  let body: any = {}
  try { body = await req.json() } catch { body = {} }

  let me: any
  try {
    me = await rpc('online_me_tx', {}, auth)
  } catch (e) {
    console.error('online_me_tx', String(e))
    return json({ ok: false, reason: 'unauthorized', message: '登入已過期，請重新開啟 App' }, 401)
  }
  if (!me || !me.ok) return json(me ?? { ok: false, reason: 'no_game' })

  try {
    return json(await handle(db, me, body, Date.now(), rand))
  } catch (e) {
    // 資料庫拒絕（例如帳對不起來）或連不上：記下來、告訴手機稍後再試。不把內部訊息原樣丟給手機
    console.error('online-game', body && body.op, String(e))
    return json({ ok: false, reason: 'server_error', message: '系統忙碌中，請稍後再試' }, 500)
  }
})
