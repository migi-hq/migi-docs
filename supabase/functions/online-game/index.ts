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
// deno-lint-ignore-file no-explicit-any
// @ts-ignore：core.mjs 是純 JS（Node 的測試也要能直接載入），沒有型別檔
import { handle } from './core.mjs'

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
