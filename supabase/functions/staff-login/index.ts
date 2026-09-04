/* ============================================================
   staff-login —— 店員用 LINE 登入 POS，換一張真的 Supabase session
   2026-09-04 建立 · MIGI 咪吉麻將

   ── 🔴 為什麼不是「自己簽一張 JWT」──────────────────
   2026-09-04 查出這個專案的 JWT 是**非對稱的**：
   ```
   GET /auth/v1/.well-known/jwks.json
   → {"keys":[{"alg":"ES256","crv":"P-256","kty":"EC",...}]}
   ```
   ⇒ **私鑰在 Supabase 手上，Edge Function 拿不到** ——
     「用 SUPABASE_JWT_SECRET 自簽 HS256」那條路走不通。

   ✅ 所以走 **Supabase Auth 本身**建立 user，換一張真的 session。
   🎯 那條路有三個意外的好處：
   ① `sub` 是**真的 uuid** ⇒ 直接寫進 `staff.auth_uid`
      ⇒ 走的是**總部那條已經在跑的路**（`current_staff()` 的第一個條件），
        不是新的一條
   ② 🔴 **有 refresh token** ⇒ 平板整天開著不會突然被登出。
      自簽的 JWT 沒有這個，過期就要重新登入。
   ③ 它剛好就是 CLAUDE.md 待辦 14 說的「**把認證與身分分開**」——
      LINE 是**認證方式**（你怎麼證明你是誰），
      Supabase Auth user 是**身分載體**（你是誰）。

   ── 🔴 為什麼另開一支不併進 line-login ──────────────
   `line-login` 已經 700 行，而它的每一個 mode 都是**會員**流程
   （註冊／認領／改手機／頭像）。店員登入是**不同的對象、
   不同的授權、不同的失敗處理** —— 併進去就是「一個名字兩個意思」，
   而那是這個專案一再記錄的病。

   ── POS 走 LIFF 不走 OAuth callback（2026-09-04 查證後改）──
   CLAUDE.md 待辦 20 原本規劃「POS 走一般 OAuth web flow，非 LIFF」。
   ✅ **查 LINE 官方文件後改了**：LIFF 在**外部瀏覽器**也能拿 id_token ——
   ```
   liff.login() → 使用者登入 → liff.init() → liff.getIDToken()
   ```
   （官方原文：「If the user starts the LIFF app in an external browser,
     the LIFF SDK will get an ID token when these steps are satisfied.」）
   ⇒ 🎯 **POS 不需要 Channel Secret、不需要 callback 端點**，
     只要在**同一個 Provider 底下**再開一個 LIFF app，endpoint 指向
     `pos.migi.tw`，scope 勾 `openid`。
   🔴 **同一個 Provider 是硬條件**：LINE 的 `userId` 是 per-Provider，
     分成兩個 Provider 的話同一個人會有兩個 id，
     而 `members.line_user_id` 只有一欄 —— **接不起來，而且不報錯**。

   ── 部署 ────────────────────────────────────────────
   Supabase Dashboard → Edge Functions → 新增 `staff-login` → 貼上 → Deploy
   Secrets（跟 line-login 共用，不用重設）：
     LINE_CHANNEL_ID = 2011312117
   ⚠ SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 由平台自動注入。

   ── 🔴 第一次部署請先用 `mode: "probe"` ──────────────
   `generate_link` 的**實際回傳結構**，官方文件沒有寫清楚
   （查過 auth-admin-generatelink 與 auth-verifyotp 兩頁都沒有）。
   ⇒ 與其猜，不如**讓第一次執行告訴我們**：
     `probe` 會回報每一步的 HTTP 狀態與**回傳物件有哪些 key**
     （🔴 **只回 key 不回 value** —— 那裡面有 token）。
   ⚠ 確認結構之後這個 mode 可以留著，它不會洩漏任何東西。
   ============================================================ */

const MIGI_ORG_ID = '11111111-1111-1111-1111-111111111111'
const LINE_CHANNEL_ID = Deno.env.get('LINE_CHANNEL_ID') ?? '2011312117'
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

/* 這個 LINE 帳號在 Supabase Auth 裡的 email。
   ⚠ **它永遠不會被寄信** —— 我們用 generate_link 拿 token，不寄出去。
   ⚠ 用 `.invalid` 是 RFC 2606 保留給「保證不存在」的 TLD，
     所以不可能誤寄到真的網域，也不會有人註冊得到它。 */
const authEmail = (sub: string) => `line-${sub.toLowerCase()}@staff.migi.invalid`

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } })

const api = (path: string, init: RequestInit = {}) =>
  fetch(`${SUPABASE_URL}${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
      ...(init.headers ?? {}),
    },
  })

/* 只回 key 不回 value —— 診斷用。
   🔴 回傳裡有 token，**絕對不能整包 log 出去**。 */
const shape = (o: unknown): unknown => {
  if (o === null || typeof o !== 'object') return typeof o
  if (Array.isArray(o)) return [`array(${o.length})`, o.length ? shape(o[0]) : null]
  const out: Record<string, unknown> = {}
  for (const k of Object.keys(o as Record<string, unknown>)) {
    const v = (o as Record<string, unknown>)[k]
    out[k] = (v !== null && typeof v === 'object') ? shape(v) : typeof v
  }
  return out
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  if (req.method !== 'POST') return json({ ok: false, reason: 'method_not_allowed' }, 405)

  let body: { id_token?: string; mode?: string }
  try { body = await req.json() } catch {
    return json({ ok: false, reason: 'bad_json', message: '請求格式錯誤' }, 400)
  }

  const idToken = (body.id_token ?? '').trim()
  if (!idToken) return json({ ok: false, reason: 'id_token_required', message: '缺少 LINE 授權資訊' }, 400)

  const probe = body.mode === 'probe'
  const steps: Record<string, unknown> = {}

  /* ── ① 向 LINE 驗簽 ──────────────────────────────
     跟 `line-login` 用同一個端點與同一個 channel。
     ⚠ 不自己實作 JWKS 驗證：少了「抓公鑰、快取、輪替」三個會出錯的地方。 */
  let lineRes: Response
  try {
    lineRes = await fetch('https://api.line.me/oauth2/v2.1/verify', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ id_token: idToken, client_id: LINE_CHANNEL_ID }),
    })
  } catch (e) {
    console.error('[staff-login] LINE verify 連線失敗', e)
    return json({ ok: false, reason: 'line_unreachable', message: '連不上 LINE，請稍後再試' }, 502)
  }
  const lineBody = await lineRes.json().catch(() => ({}))
  if (!lineRes.ok) {
    console.warn('[staff-login] LINE 拒絕了 id_token', lineRes.status, lineBody)
    return json({ ok: false, reason: 'line_token_invalid', message: 'LINE 授權已失效，請重新登入' }, 401)
  }
  const sub = lineBody?.sub
  if (!sub || typeof sub !== 'string') {
    console.error('[staff-login] 驗過了卻沒有 sub，檢查 LIFF 的 openid scope', lineBody)
    return json({ ok: false, reason: 'no_sub', message: '取不到 LINE 識別碼' }, 500)
  }
  /* 零成本的第二道：萬一哪天換了端點或參數寫錯，這裡會擋下來而不是靜靜放行。 */
  if (lineBody?.aud && String(lineBody.aud) !== LINE_CHANNEL_ID) {
    console.error('[staff-login] aud 不符', lineBody.aud)
    return json({ ok: false, reason: 'aud_mismatch', message: '授權來源不符' }, 401)
  }
  steps.line_verify = { status: lineRes.status, has_sub: true }

  /* ── ② 這個 LINE 帳號是不是店員 ────────────────────
     🔴 **這一步一定要在建立 Auth user 之前** ——
       不然每一個下載 POS 網址的客人都會在 auth.users 裡長出一筆。
     ⚠ 用 `get_staff_by_line_tx`（只給 service_role）而不是 `current_staff()`：
       後者讀 `auth.jwt()`，而這裡手上只有驗過簽的 sub，沒有 JWT context。 */
  const stRes = await api('/rest/v1/rpc/get_staff_by_line_tx', {
    method: 'POST',
    body: JSON.stringify({ p_org_id: MIGI_ORG_ID, p_line_user_id: sub }),
  })
  const staff = await stRes.json().catch(() => null)
  steps.staff_lookup = { status: stRes.status, ok: staff?.ok === true }
  if (!stRes.ok || staff?.ok !== true) {
    /* ⚠ 「不是店員」是**業務結果不是錯誤**，但這裡回 403 是刻意的 ——
       POS 的登入頁需要明確地拒絕，而不是讓人以為登入成功了。
       ⚠ 訊息不要說「你不是店員」以外的事（例如「這個 LINE 沒有註冊」）——
         那會洩漏「哪些帳號存在」。 */
    return json({ ok: false, reason: 'not_staff', message: '這個 LINE 帳號沒有店員權限，請找店長開通' }, 403)
  }

  /* ── ③ 找或建立 Supabase Auth user ────────────────
     🔴 `app_metadata` **不可以寫成 `user_metadata`**：
       後者**客戶端自己就能改**（`supabase.auth.updateUser({ data: … })`），
       而 `migi_jwt_line_id()` 讀的就是這個 claim
       ⇒ 寫錯的話等於「輸入任何 line_user_id 就能變成他」。
     ⚠ `email_confirm: true` —— 那個信箱永遠不會收信，不確認的話登不進去。 */
  const email = authEmail(sub)
  let userId: string | null = null

  const createRes = await api('/auth/v1/admin/users', {
    method: 'POST',
    body: JSON.stringify({
      email, email_confirm: true,
      app_metadata: { line_user_id: sub, provider: 'line', migi_role: staff.role },
    }),
  })
  const created = await createRes.json().catch(() => null)
  steps.create_user = { status: createRes.status, shape: probe ? shape(created) : undefined }

  if (createRes.ok && created?.id) {
    userId = created.id
  } else {
    /* 已經存在（GoTrue 對重複的 email 回 422）→ 查出來並**更新 app_metadata**。
       ⚠ 一定要更新：`migi_role` 會變（升店長、離職），
         而 JWT 裡的 claim 是**發的當下**那一份 —— 不更新就會一直用舊的。
       ⚠ `filter` 是 GoTrue 的模糊查詢；用完整 email 比對回傳結果，
         **不要相信它只回一筆**。 */
    const listRes = await api(`/auth/v1/admin/users?page=1&per_page=50&filter=${encodeURIComponent(email)}`)
    const list = await listRes.json().catch(() => null)
    const users = Array.isArray(list?.users) ? list.users : []
    const hit = users.find((u: { email?: string }) => (u.email || '').toLowerCase() === email)
    steps.find_user = {
      status: listRes.status, returned: users.length, matched: !!hit,
      shape: probe ? shape(list) : undefined,
    }
    if (!hit?.id) {
      console.error('[staff-login] 建不了也找不到 auth user', createRes.status, created)
      return json({ ok: false, reason: 'auth_user_failed', message: '登入失敗，請稍後再試', steps: probe ? steps : undefined }, 502)
    }
    userId = hit.id
    const updRes = await api(`/auth/v1/admin/users/${userId}`, {
      method: 'PUT',
      body: JSON.stringify({ app_metadata: { line_user_id: sub, provider: 'line', migi_role: staff.role } }),
    })
    steps.update_metadata = { status: updRes.status }
  }

  /* ── ④ 把 auth_uid 寫回 staff ──────────────────────
     🎯 **這一步讓 `current_staff()` 的第一個條件成立**
       （`s.auth_uid = migi_jwt_uuid()`），也就是走**總部那條已經在跑的路**。
     ⚠ 冪等：值一樣就不用寫。
     ⚠ `staff_auth_uid_key` 是 UNIQUE —— 同一個 auth user 綁到第二列 staff
       會失敗，而**那個失敗是對的**（一個登入身分只能是一個人）。 */
  if (staff.staff_id && userId) {
    const bindRes = await api(
      `/rest/v1/staff?id=eq.${staff.staff_id}&auth_uid=is.null`,
      { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ auth_uid: userId }) })
    steps.bind_staff = { status: bindRes.status }
    if (!bindRes.ok) {
      // ⚠ 綁不上不是致命的（可能已經綁過）—— 記下來，繼續發 session。
      console.warn('[staff-login] auth_uid 綁定沒成功', bindRes.status, await bindRes.text())
    }
  }

  /* ── ⑤ 產生登入用的一次性 token ────────────────────
     🔴 **官方文件沒有寫清楚回傳結構**（查過 generateLink 與 verifyOtp 兩頁）。
       所以這裡**不猜**：把可能的位置都試一遍，並在 probe 模式回報實際形狀。
     ⚠ 回傳裡有 token，`shape()` **只回 key 不回 value**。 */
  const linkRes = await api('/auth/v1/admin/generate_link', {
    method: 'POST',
    body: JSON.stringify({ type: 'magiclink', email }),
  })
  const link = await linkRes.json().catch(() => null)
  steps.generate_link = { status: linkRes.status, shape: probe ? shape(link) : undefined }

  if (!linkRes.ok) {
    console.error('[staff-login] generate_link 失敗', linkRes.status, link)
    return json({ ok: false, reason: 'link_failed', message: '登入失敗，請稍後再試', steps: probe ? steps : undefined }, 502)
  }

  /* GoTrue 有兩種版本的形狀（頂層 / properties 底下），兩個都接。
     ⚠ 這**不是**「以防萬一」的防禦性程式碼 —— 是因為文件沒寫，
       而 probe 會告訴我們實際是哪一個。確認之後可以刪掉另一半。 */
  const tokenHash = link?.hashed_token ?? link?.properties?.hashed_token ?? null
  const otpType = link?.verification_type ?? link?.properties?.verification_type ?? 'magiclink'

  if (probe) {
    return json({
      ok: true, mode: 'probe',
      有拿到_token_hash: !!tokenHash,
      verification_type: otpType,
      staff: { role: staff.role, name: staff.name, cross_store: staff.cross_store },
      steps,
      /* 🔴 下一步要拿這個去 `supabase.auth.verifyOtp({ token_hash, type })`，
         而 `type` 的正確值要看上面的 verification_type。 */
    })
  }

  if (!tokenHash) {
    console.error('[staff-login] generate_link 沒有 hashed_token', shape(link))
    return json({ ok: false, reason: 'no_token_hash', message: '登入失敗，請稍後再試' }, 502)
  }

  /* 🔴 **回傳的是「一次性換 session 的憑證」不是 session 本身。**
     前端拿它呼叫 `supabase.auth.verifyOtp({ token_hash, type })`，
     由 supabase-js 存進它自己的 storage 並負責 refresh。
     ⚠ **不要在這裡自己組 session 物件** —— 那樣 refresh 會沒有人管，
       而平板是整天開著的。 */
  return json({
    ok: true,
    token_hash: tokenHash,
    otp_type: otpType,
    staff: {
      staff_id: staff.staff_id, member_id: staff.member_id,
      store_id: staff.store_id, role: staff.role,
      name: staff.name, cross_store: staff.cross_store,
    },
  })
})
