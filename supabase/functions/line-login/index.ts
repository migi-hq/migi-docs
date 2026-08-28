/* ============================================================
   line-login —— 驗 LINE 的 id_token，然後**自己**呼叫 register_member_tx
   2026-08-28 · MIGI 咪吉麻將

   ── 🔴 為什麼不能只回傳 sub 給前端 ──────────────────
   直覺做法是「Edge Function 驗完簽，把 line_user_id 回傳，
   前端拿去呼叫 register_member_tx」。**那樣驗簽等於白做** ——
   前端拿到之後照樣可以把它改成別人的 id 再送出。

   → 所以這支函式**自己**用 service_role 呼叫 register_member_tx，
     前端從頭到尾拿不到「可以自由填的 p_line_user_id 參數」。

   ⚠ 這**不是**待辦 21 擋著的「JWT 換發」——
     我們沒有發任何 Supabase JWT，只是在伺服器端驗 LINE 的 token。
     那五個阻擋條件不適用。

   ── 範圍：只做身分，不做個人資料 ────────────────────
   生日與性別**不經過這裡**，前端拿到 member_id 之後照舊呼叫
   set_my_profile_basics_tx。
   ⚠ 那支仍然吃前端傳的 member_id —— 那是待辦 14 既有的問題，
     不因這次而變糟，也不該在這裡順手解決（範圍會爆炸）。

   ── 部署 ────────────────────────────────────────────
   Supabase Dashboard → Edge Functions → Deploy a new function
   名稱：line-login　（⚠ 名稱要一致，前端是用這個名字叫它）
   需要的環境變數（Dashboard → Edge Functions → Secrets）：
     LINE_CHANNEL_ID = 2011312117
   ⚠ SUPABASE_URL 與 SUPABASE_SERVICE_ROLE_KEY 由平台自動注入，不用自己設。
   ⚠ Channel ID **不是機密**（它就在 LIFF ID 的前半段），
     放 secret 只是為了換 channel 時不用改程式碼。
   ============================================================ */

// MIGI 品牌 org（seed 建立的固定 UUID，與前端 lib/supabase.js 同一個值）
const MIGI_ORG_ID = '11111111-1111-1111-1111-111111111111'

// ⚠ 有 fallback 是刻意的：Channel ID 不是機密，忘了設 secret 也不該整支掛掉。
const LINE_CHANNEL_ID = Deno.env.get('LINE_CHANNEL_ID') ?? '2011312117'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

/* CORS：前端在 app.migi.tw，跟 Edge Function 不同網域，
   沒有這一段的話瀏覽器連 preflight 都過不了，而且錯誤訊息只會說
   「CORS policy」—— 看不出是這裡的問題。 */
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  })

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  if (req.method !== 'POST') return json({ ok: false, reason: 'method_not_allowed' }, 405)

  let body: { id_token?: string; display_name?: string; phone?: string }
  try {
    body = await req.json()
  } catch {
    return json({ ok: false, reason: 'bad_json', message: '請求格式錯誤' }, 400)
  }

  const idToken = (body.id_token ?? '').trim()
  if (!idToken) {
    return json({ ok: false, reason: 'id_token_required', message: '缺少 LINE 授權資訊' }, 400)
  }

  /* ── ① 向 LINE 驗簽 ──────────────────────────────
     用 LINE 的 verify 端點，不自己實作 JWKS 驗證：
     少了「抓公鑰、快取、輪替」三個會出錯的地方，代價是一次網路往返。
     ⚠ 這個端點會一起檢查簽章、`iss`、`exp`，以及 `aud` 是否等於 client_id。 */
  let lineRes: Response
  try {
    lineRes = await fetch('https://api.line.me/oauth2/v2.1/verify', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ id_token: idToken, client_id: LINE_CHANNEL_ID }),
    })
  } catch (e) {
    // 連不到 LINE ≠ token 有問題。分開回報，否則客人會看到「授權失敗」而一直重試。
    console.error('[line-login] LINE verify 連線失敗', e)
    return json({ ok: false, reason: 'line_unreachable', message: '連不上 LINE，請稍後再試' }, 502)
  }

  const lineBody = await lineRes.json().catch(() => ({}))
  if (!lineRes.ok) {
    console.warn('[line-login] LINE 拒絕了 id_token', lineRes.status, lineBody)
    return json({
      ok: false,
      reason: 'line_token_invalid',
      message: 'LINE 授權已失效，請重新開啟一次',
    }, 401)
  }

  const sub = lineBody?.sub
  if (!sub || typeof sub !== 'string') {
    // 🔴 驗過了卻沒有 sub —— 多半是 scope 沒勾 openid。
    console.error('[line-login] 驗證通過但沒有 sub，檢查 LIFF 的 openid scope', lineBody)
    return json({
      ok: false,
      reason: 'no_sub',
      message: '取不到 LINE 識別碼，請洽櫃檯',
    }, 500)
  }

  /* ⚠ 再自己比對一次 aud。
     LINE 的端點已經驗過，但這是**零成本的第二道** ——
     萬一哪天換了端點或參數寫錯，這裡會擋下來而不是靜靜放行。 */
  const aud = lineBody?.aud
  if (aud && String(aud) !== LINE_CHANNEL_ID) {
    console.error('[line-login] aud 不符', aud, LINE_CHANNEL_ID)
    return json({ ok: false, reason: 'aud_mismatch', message: '授權來源不符' }, 401)
  }

  /* ── ② 用 service_role 呼叫 register_member_tx ──────
     🔴 這裡是整支函式存在的理由：line_user_id 只能從上面驗過的 sub 來，
       前端沒有任何辦法指定它。

     ⚠ 暱稱與手機**仍然是前端送的** —— 那是客人自己填的資料，
       本來就該由他決定；後端的 migi_norm_* 與 CHECK 會把關格式。
       真正不能讓前端決定的只有「他是誰」。 */
  let rpcRes: Response
  try {
    rpcRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/register_member_tx`, {
      method: 'POST',
      headers: {
        apikey: SERVICE_KEY,
        Authorization: `Bearer ${SERVICE_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        p_org_id: MIGI_ORG_ID,
        p_display_name: body.display_name ?? '',
        p_phone: body.phone ?? null,
        p_line_user_id: sub,
      }),
    })
  } catch (e) {
    console.error('[line-login] 呼叫 register_member_tx 失敗', e)
    return json({ ok: false, reason: 'db_unreachable', message: '系統忙碌中，請稍後再試' }, 502)
  }

  const rpcBody = await rpcRes.json().catch(() => null)

  if (!rpcRes.ok) {
    /* register_member_tx 的業務錯誤是 raise（P0001），PostgREST 會回 4xx，
       訊息在 `message` 欄位裡，而且是**英文代碼**（phone_invalid 那些）。
       ⚠ 這裡原樣往上丟，讓前端的 REG_ERR 對照表去翻 ——
         翻譯只維護一份，不要在這裡再抄一份中文。 */
    console.warn('[line-login] register_member_tx 回錯', rpcRes.status, rpcBody)
    return json({
      ok: false,
      reason: 'register_failed',
      message: rpcBody?.message ?? '註冊失敗，請再試一次',
    }, 400)
  }

  /* 成功。action ∈ existing_line / rebound / line_conflict / existing_phone / created
     ⚠ line_conflict **不是錯誤而是業務結果**（這支手機的會員已綁別的 LINE），
       原樣回給前端，由它決定怎麼講。 */
  return json({ ok: true, ...rpcBody })
})
