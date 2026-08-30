/* ============================================================
   line-login —— 驗 LINE 的 id_token，然後**自己**呼叫 register_member_tx
   2026-08-28 建立 · 2026-08-29 加上頭像同步 · MIGI 咪吉麻將

   ── 🔴 為什麼不能只回傳 sub 給前端 ──────────────────
   直覺做法是「Edge Function 驗完簽，把 line_user_id 回傳，
   前端拿去呼叫 register_member_tx」。**那樣驗簽等於白做** ——
   前端拿到之後照樣可以把它改成別人的 id 再送出。

   → 所以這支函式**自己**用 service_role 呼叫 register_member_tx，
     前端從頭到尾拿不到「可以自由填的 p_line_user_id 參數」。

   ⚠ 這**不是**待辦 21 擋著的「JWT 換發」——
     我們沒有發任何 Supabase JWT，只是在伺服器端驗 LINE 的 token。
     那五個阻擋條件不適用。

   ── 三個模式 ────────────────────────────────────────
   | mode | 什麼時候用 | 做什麼 |
   |---|---|---|
   | （省略）＝ `register` | 註冊流程最後一步 | 驗簽 → register_member_tx → 存頭像 |
   | `sync_avatar` | 頭像抽屜按「同步」 | 驗簽 → 查會員 → 只更新頭像 |
   | `check_phone` | 註冊第 2 步按「下一步」 | 驗簽 → `phone_in_use_tx` → 只回一個布林 |
   | `otp_send` | 按「傳送驗證碼」 | 驗簽 → `otp_request_tx` → 發簡訊 |
   | `otp_verify` | 輸入六碼 | 驗簽 → `otp_verify_tx` |

   🔴 **`check_phone` 本質上是「這支號碼是不是會員」的查詢器**，
     所以它一定要在**驗簽之後**才執行 —— 也就是要有一個真的 LINE 帳號才問得到。
     ⚠ 回傳**只有一個布林**：不給 `member_id`、不給暱稱、不給任何東西。
     ⚠ 拿到之後也綁不進去（`register_member_tx` 的 A3 已於 2026-08-30 堵掉）。
   ⏳ 之後若要更嚴，是在這裡加**每個 `sub` 的次數上限**，
     不是把它改回不存在 —— 沒有它，客人要填完四步才知道被擋。

   🔴 **`sync_avatar` 不能重用 `register_member_tx`** ——
     它第一件事就是 `if v_name = '' then raise 'display_name required'`，
     而同步時前端沒有暱稱可送（也不該送，那會變成偷偷改名）。
     → 改用 service_role 直接查 `members`（service_role 不受 RLS 限制）。

   ── 🔴 為什麼頭像網址不能讓前端送 ──────────────────
   直覺是 `liff.getProfile()` 拿 `pictureUrl` 再送過來。**那不行** ——
   那個值是前端說的，等於「任何人可以把任何圖掛到任何人的頭像上」。
   🎯 正解：**LINE 的 verify 端點回傳的 payload 裡就有 `picture`**，
     跟 `sub` 是同一份、同一次驗簽。所以這裡自己取出來用。
   → `set_line_avatar_tx` 因此只授權 service_role（anon 明確=N、PUBLIC=N）。

   ── ⚠ 存頭像 ≠ 套用頭像 ────────────────────────────
   註冊完 `avatar_source` 仍然是 `bear`（DB 預設），**只是把網址存起來**。
   🔴 這是**隱私決定不是偷懶**：MIGI 是陌生人配桌的 App，
     未經詢問就把某人的真實臉孔顯示給同桌的陌生人，是替他做了決定。
     → 要不要用 LINE 頭像，由他自己在頭像抽屜裡點。

   ── 部署 ────────────────────────────────────────────
   Supabase Dashboard → Edge Functions → line-login → 貼上這份 → Deploy
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

const db = (path: string, init: RequestInit = {}) =>
  fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
      ...(init.headers ?? {}),
    },
  })

/* ── 發簡訊 ────────────────────────────────────────────
   🎯 **整支函式就是簡訊商的接縫。** 換一家只要改這裡，
     其餘（限流、雜湊、嘗試次數、前端）一個字都不用動。

   ⚠ 沒設定就**回 false 而不是拋錯** —— 呼叫端據此決定要不要交出 dev_code。
     拋錯的話「還沒接簡訊商」會長得像「簡訊商壞了」。

   ── 🔴 選簡訊商之前一定要先問這一題：**要不要綁 IP？** ──
   Supabase Edge Functions 跑在 Deno Deploy 上，**沒有固定對外 IP**
   （每次呼叫都可能從不同位址出去，官方文件明講不提供）。
   而**三竹的 API 要求把發送主機 IP 加進白名單**（寫信給客服綁定）。
   ⇒ 兩者直接衝突。要用三竹就得額外架一台固定 IP 的 proxy ——
     而那是「要有人維護的第三套東西」（硬規則 5.5）。
   → 所以優先選**用 token 認證、不綁 IP** 的（Twilio／AWS SNS 那一類）。

   ⏳ 設定（Dashboard → Edge Functions → Secrets）：
       SMS_PROVIDER = mitake
       SMS_USER     = <帳號>
       SMS_PASS     = <密碼>
       SMS_URL      = <客服給的 API 網址>   ← ⚠ 不要寫死
   ⚠ **網址一定要從 secret 來**：三竹的個人帳號（二站）與企業帳號（三站）
     網址不同，而且客服會依帳號給不同的位址。寫死一個等於賭它剛好對。
   ⚠ 三竹的回應是**純文字不是 JSON**（`[1]\nmsgid=...\nstatuscode=1`），
     `statuscode` 是 1/2/4 才算成功。不要用 res.ok 判斷 ——
     它送錯帳密也會回 HTTP 200。 */
async function sendSms(phone: string, text: string): Promise<boolean> {
  const provider = Deno.env.get('SMS_PROVIDER')
  const user = Deno.env.get('SMS_USER')
  const pass = Deno.env.get('SMS_PASS')
  if (!provider || !user || !pass) {
    console.warn('[line-login] 簡訊商還沒設定，這則沒有送出')
    return false
  }
  if (provider !== 'mitake') {
    console.error('[line-login] 不認得的簡訊商', provider)
    return false
  }
  try {
    const url = Deno.env.get('SMS_URL') ?? 'https://smsapi.mitake.com.tw/api/mtk/SmSend?CharsetURL=UTF8'
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' },
      body: new URLSearchParams({ username: user, password: pass, dstaddr: phone, smbody: text }),
    })
    const raw = await res.text()
    const m = raw.match(/statuscode\s*=\s*(\w+)/)
    const okCodes = ['1', '2', '4']
    if (!m || !okCodes.includes(m[1])) {
      console.error('[line-login] 三竹回報失敗', res.status, raw.slice(0, 200))
      return false
    }
    return true
  } catch (e) {
    console.error('[line-login] 簡訊送出失敗', e)
    return false
  }
}

/* 把驗過簽的 picture 寫進 members.avatar_url。
   ⚠ 回傳 null 代表沒寫成（沒有 picture、或 RPC 拒絕），
     由呼叫端決定那是不是致命的 —— 註冊時不是，同步時是。 */
async function saveLineAvatar(memberId: string, picture: unknown): Promise<string | null> {
  const url = typeof picture === 'string' ? picture.trim() : ''
  if (!url) {
    /* 🔴 沒有 picture 多半是 LIFF 的 scope 沒勾 `profile`。
       不要讓它靜靜消失 —— 那會變成「同步按了沒反應」而查不出原因。 */
    console.warn('[line-login] token 裡沒有 picture，檢查 LIFF 的 profile scope')
    return null
  }
  try {
    const res = await db('rpc/set_line_avatar_tx', {
      method: 'POST',
      body: JSON.stringify({ p_member_id: memberId, p_url: url }),
    })
    const body = await res.json().catch(() => null)
    if (!res.ok || !body?.ok) {
      console.warn('[line-login] set_line_avatar_tx 沒寫成', res.status, body)
      return null
    }
    return body.avatar_url as string
  } catch (e) {
    console.warn('[line-login] set_line_avatar_tx 連線失敗', e)
    return null
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  if (req.method !== 'POST') return json({ ok: false, reason: 'method_not_allowed' }, 405)

  let body: {
    id_token?: string; display_name?: string; phone?: string; mode?: string
    code?: string; purpose?: string
  }
  try {
    body = await req.json()
  } catch {
    return json({ ok: false, reason: 'bad_json', message: '請求格式錯誤' }, 400)
  }

  const idToken = (body.id_token ?? '').trim()
  if (!idToken) {
    return json({ ok: false, reason: 'id_token_required', message: '缺少 LINE 授權資訊' }, 400)
  }
  const syncOnly = body.mode === 'sync_avatar'
  const checkPhone = body.mode === 'check_phone'

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
      message: '取不到 LINE 識別碼，請找店員或客服',
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

  /* ── ②a 只檢查手機有沒有人用（註冊第 2 步）────────
     ⚠ 放在驗簽**之後** —— 這是這一段唯一的防線：要有真的 LINE 帳號才問得到。
     ⚠ 正規化交給 `phone_in_use_tx` 裡的 `migi_norm_phone()`，
       這裡**不要自己算** —— 多一個地方算就多一個會算歪的地方，
       而 `uq_members_phone` 是字串比對（`0912-345-678` ≠ `0912345678`）。 */
  if (checkPhone) {
    const phone = (body.phone ?? '').trim()
    if (!phone) return json({ ok: true, in_use: false })
    let r: Response
    try {
      r = await db('rpc/phone_in_use_tx', {
        method: 'POST',
        body: JSON.stringify({ p_org_id: MIGI_ORG_ID, p_phone: phone }),
      })
    } catch (e) {
      /* 🔴 查不到就說「沒被用」（fail open）。
         把人因為網路問題擋在門外比較糟，而**送出那一步還有一道**
         （register_member_tx 會回 phone_taken）。 */
      console.error('[line-login] phone_in_use_tx 連線失敗', e)
      return json({ ok: true, in_use: false, degraded: true })
    }
    if (!r.ok) {
      console.warn('[line-login] phone_in_use_tx 回錯', r.status)
      return json({ ok: true, in_use: false, degraded: true })
    }
    const used = await r.json().catch(() => null)
    // 🔴 只回布林。不回 member_id、不回暱稱、不回任何可以辨識那個人的東西。
    return json({ ok: true, in_use: used === true })
  }

  /* ── ②b 發驗證碼 ──────────────────────────────────
     ⚠ 一樣放在驗簽之後 —— 沒有 LINE 帳號就發不出簡訊，
       否則這支就是一個「幫任何人付錢發簡訊」的按鈕。
     ⚠ 限流三道都在 `otp_request_tx` 裡（同號碼 60 秒／1 小時 5 則／
       同一個 LINE 1 小時 10 則），這裡不重複實作 —— 兩個地方算就會不一致。 */
  if (body.mode === 'otp_send') {
    const purpose = body.purpose ?? 'register'
    let r: Response
    try {
      r = await db('rpc/otp_request_tx', {
        method: 'POST',
        body: JSON.stringify({
          p_org_id: MIGI_ORG_ID, p_phone: body.phone ?? '',
          p_purpose: purpose, p_line_user_id: sub,
        }),
      })
    } catch (e) {
      console.error('[line-login] otp_request_tx 連線失敗', e)
      return json({ ok: false, reason: 'db_unreachable', message: '系統忙碌中，請稍後再試' }, 502)
    }
    const out = await r.json().catch(() => null)
    if (!r.ok || !out) {
      return json({ ok: false, reason: 'otp_failed', message: '系統忙碌中，請稍後再試' }, 502)
    }
    if (!out.ok) {
      /* 🔴 限流與格式錯是**業務結果不是錯誤**，所以回 `ok: true`。
         前端的 `callFn` 看到 `ok: false` 會把整個 data 換成一個 error 物件 ——
         那樣 `retry_after`（還要等幾秒）就消失了，客人只會看到
         一句「操作失敗」。同 `line_conflict` 那次的教訓。 */
      return json({ ok: true, sent: false, reason: out.reason, retry_after: out.retry_after })
    }

    /* 🔴 **開頭的「【MIGI 咪吉麻將】」不可以拿掉。**
       台灣 NCC 要求發到台灣的簡訊，訊息開頭必須清楚標示
       品牌／組織／活動名稱 —— 那是法規不是排版。
       ⚠ 這種前綴看起來很像可以「順手清乾淨」的東西，所以在這裡寫清楚。
       ⚠ 也不要改成英文縮寫：規定要的是**看得懂是誰發的**。 */
    const sent = await sendSms(out.phone, `【MIGI 咪吉麻將】你的驗證碼是 ${out.code}，5 分鐘內有效。`)

    /* 🔴 **簡訊商還沒接通時，把碼交給前端**（`dev_code`）。
       這是一個旁路，而硬規則 5.7 說旁路一旦存在就會被忘記 ——
       所以它**自帶到期日**（寫死在 `otp_request_tx` 裡的 2026-09-30），
       時間到了資料庫就不再回 `dev_code`，這裡也就沒東西可傳。
       ⚠ **不要在這裡自己判斷日期** —— 那等於多一個可以偷偷改的地方。
         唯一的開關在資料庫函式裡，改它會留下一份 applied/ 的 SQL。
       ⚠ 簡訊真的送出去了就**不回** dev_code —— 有簡訊就不需要旁路。 */
    return json({
      ok: true, sent,
      ...(sent ? {} : { dev_code: out.dev_code ?? null, dev_until: out.dev_until ?? null }),
    })
  }

  /* ── ②c 驗證碼 ────────────────────────────────────
     ⚠ 嘗試次數上限在 `otp_verify_tx` 裡（5 次）。
       6 位數只有 100 萬種組合，沒有上限的話暴力猜解幾分鐘就會成功。 */
  if (body.mode === 'otp_verify') {
    let r: Response
    try {
      r = await db('rpc/otp_verify_tx', {
        method: 'POST',
        body: JSON.stringify({
          p_org_id: MIGI_ORG_ID, p_phone: body.phone ?? '',
          p_code: body.code ?? '', p_purpose: body.purpose ?? 'register',
        }),
      })
    } catch (e) {
      console.error('[line-login] otp_verify_tx 連線失敗', e)
      return json({ ok: false, reason: 'db_unreachable', message: '系統忙碌中，請稍後再試' }, 502)
    }
    const out = await r.json().catch(() => null)
    if (!r.ok || !out) {
      return json({ ok: false, reason: 'otp_failed', message: '系統忙碌中，請稍後再試' }, 502)
    }
    /* 🔴 **「驗證碼不對」是業務結果不是錯誤** —— 所以外層一律 `ok: true`，
       把「對了沒」放在 `verified`。
       回 `ok: false` 的話前端的 `callFn` 會把 data 換成 error 物件，
       而 `left`（還可以試幾次）就消失了 —— 客人只會看到
       「操作失敗，請再試一次」，那正是最沒用的一句話。 */
    return json({ ok: true, verified: out.ok === true, reason: out.reason ?? null, left: out.left ?? null })
  }

  /* ── ②b 只同步頭像（頭像抽屜的「同步」按鈕）──────── */
  if (syncOnly) {
    let found: Response
    try {
      /* service_role 不受 RLS 限制，所以查得到。
         ⚠ 一併比對 org_id，跟 register_member_tx 的查法一致。 */
      found = await db(
        `members?select=id&org_id=eq.${MIGI_ORG_ID}` +
        `&line_user_id=eq.${encodeURIComponent(sub)}&deleted_at=is.null&limit=1`)
    } catch (e) {
      console.error('[line-login] 查會員失敗', e)
      return json({ ok: false, reason: 'db_unreachable', message: '系統忙碌中，請稍後再試' }, 502)
    }
    const rows = await found.json().catch(() => null)
    const memberId = Array.isArray(rows) && rows[0]?.id
    if (!memberId) {
      // 這個 LINE 帳號還沒有會員 —— 不是錯誤，是還沒註冊。
      return json({ ok: false, reason: 'not_registered', message: '請先完成註冊' }, 404)
    }

    const avatarUrl = await saveLineAvatar(memberId, lineBody?.picture)
    if (!avatarUrl) {
      /* 🔴 同步時「沒寫成」就是失敗，不可以回 ok ——
         客人按了同步、畫面說成功、頭像沒變，那比報錯更糟。 */
      return json({
        ok: false,
        reason: 'avatar_unavailable',
        message: '取不到你的 LINE 頭像，請確認 LINE 上有設定大頭貼',
      }, 400)
    }
    return json({ ok: true, action: 'avatar_synced', member_id: memberId, avatar_url: avatarUrl })
  }

  /* ── ②b 註冊：用 service_role 呼叫 register_member_tx ──
     🔴 這裡是整支函式存在的理由：line_user_id 只能從上面驗過的 sub 來，
       前端沒有任何辦法指定它。

     ⚠ 暱稱與手機**仍然是前端送的** —— 那是客人自己填的資料，
       本來就該由他決定；後端的 migi_norm_* 與 CHECK 會把關格式。
       真正不能讓前端決定的只有「他是誰」。 */
  let rpcRes: Response
  try {
    rpcRes = await db('rpc/register_member_tx', {
      method: 'POST',
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

  /* ── ③ 存 LINE 頭像（不套用）──────────────────────
     ⚠ **失敗不影響註冊**。頭像是附加品，而註冊已經成立了 ——
       這時回「註冊失敗」是騙人的，而且客人再按一次只會走到
       existing_line 分支、看起來更像壞掉（同前端第二支 RPC 的處理方式）。
     ⚠ `line_conflict` 時不寫 —— 那個 member_id 是**別人的帳號**。 */
  let avatarUrl: string | null = null
  if (rpcBody?.member_id && rpcBody?.action !== 'line_conflict') {
    avatarUrl = await saveLineAvatar(rpcBody.member_id, lineBody?.picture)
  }

  /* 成功。action ∈ existing_line / rebound / line_conflict / existing_phone / created
     ⚠ line_conflict **不是錯誤而是業務結果**（這支手機的會員已綁別的 LINE），
       原樣回給前端，由它決定怎麼講。 */
  return json({ ok: true, ...rpcBody, avatar_url: avatarUrl })
})
