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

/* ── 共用：找或建立 Auth user ＋ 綁 staff.auth_uid ＋ 發一次性登入憑證 ───────
   LINE 與手機簡訊兩條路都走這裡（2026-10-21 抽出來）—— 「發 session」只能有一份寫法。
   ⚠ 已經綁過 auth_uid 的店員一律用**原本那個 Auth user**，不另外長一個：
     同一個人兩個登入帳號的話，staff_auth_uid_key 只綁得上一個，另一個會「登得進去但不是店員」。 */
type Staff = { staff_id: string; member_id: string | null; store_id: string | null; role: string; name: string; cross_store: boolean }

async function issueStaffSession(staff: Staff, wantEmail: string, meta: Record<string, unknown>,
                                 probe = false, steps: Record<string, unknown> = {}) {
  let userId: string | null = null
  let email = wantEmail

  // ⓪ 這位店員已經綁過登入帳號 → 用那一個（不管當初是 LINE 還是手機建的）
  const curRes = await api(`/rest/v1/staff?id=eq.${staff.staff_id}&select=auth_uid`)
  const cur = await curRes.json().catch(() => null)
  const boundUid: string | null = Array.isArray(cur) && cur[0]?.auth_uid ? cur[0].auth_uid : null
  if (boundUid) {
    const uRes = await api(`/auth/v1/admin/users/${boundUid}`)
    const u = await uRes.json().catch(() => null)
    if (uRes.ok && u?.email) { userId = boundUid; email = String(u.email).toLowerCase() }
    steps.bound_user = { status: uRes.status, found: !!userId }
    if (userId) {
      /* ⚠ 照原本 LINE 那條的做法：每次登入都更新 app_metadata —— `migi_role` 會變（升店長、離職），
           而 JWT 裡的 claim 是發的當下那一份。手機登入的人之後改用 LINE，line_user_id 也在這裡補上。 */
      const updRes = await api(`/auth/v1/admin/users/${userId}`, {
        method: 'PUT', body: JSON.stringify({ app_metadata: meta }),
      })
      steps.update_metadata = { status: updRes.status }
    }
  }

  if (!userId) {
    /* 🔴 `app_metadata` **不可以寫成 `user_metadata`**：
       後者**客戶端自己就能改**（`supabase.auth.updateUser({ data: … })`），
       而 `migi_jwt_line_id()` 讀的就是這個 claim
       ⇒ 寫錯的話等於「輸入任何 line_user_id 就能變成他」。
     ⚠ `email_confirm: true` —— 那個信箱永遠不會收信，不確認的話登不進去。 */
    const createRes = await api('/auth/v1/admin/users', {
      method: 'POST',
      body: JSON.stringify({ email, email_confirm: true, app_metadata: meta }),
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
        return { error: json({ ok: false, reason: 'auth_user_failed', message: '登入失敗，請稍後再試', steps: probe ? steps : undefined }, 502) }
      }
      userId = hit.id
      const updRes = await api(`/auth/v1/admin/users/${userId}`, {
        method: 'PUT',
        body: JSON.stringify({ app_metadata: meta }),
      })
      steps.update_metadata = { status: updRes.status }
    }
  }

  /* ── 把 auth_uid 寫回 staff ──────────────────────
     🎯 **這一步讓 `current_staff()` 的第一個條件成立**
       （`s.auth_uid = migi_jwt_uuid()`），也就是走**總部那條已經在跑的路**。
     ⚠ 冪等：值一樣就不用寫。
     ⚠ `staff_auth_uid_key` 是 UNIQUE —— 同一個 auth user 綁到第二列 staff
       會失敗，而**那個失敗是對的**（一個登入身分只能是一個人）。 */
  if (staff.staff_id && userId && !boundUid) {
    const bindRes = await api(
      `/rest/v1/staff?id=eq.${staff.staff_id}&auth_uid=is.null`,
      { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ auth_uid: userId }) })
    steps.bind_staff = { status: bindRes.status }
    if (!bindRes.ok) {
      // ⚠ 綁不上不是致命的（可能已經綁過）—— 記下來，繼續發 session。
      console.warn('[staff-login] auth_uid 綁定沒成功', bindRes.status, await bindRes.text())
    }
  }

  /* ── 產生登入用的一次性 token ────────────────────
     ⚠ 回傳裡有 token，`shape()` **只回 key 不回 value**。 */
  const linkRes = await api('/auth/v1/admin/generate_link', {
    method: 'POST',
    body: JSON.stringify({ type: 'magiclink', email }),
  })
  const link = await linkRes.json().catch(() => null)
  steps.generate_link = { status: linkRes.status, shape: probe ? shape(link) : undefined }

  if (!linkRes.ok) {
    console.error('[staff-login] generate_link 失敗', linkRes.status, link)
    return { error: json({ ok: false, reason: 'link_failed', message: '登入失敗，請稍後再試', steps: probe ? steps : undefined }, 502) }
  }
  /* GoTrue 有兩種版本的形狀（頂層 / properties 底下），兩個都接。 */
  const tokenHash = link?.hashed_token ?? link?.properties?.hashed_token ?? null
  const otpType = link?.verification_type ?? link?.properties?.verification_type ?? 'magiclink'
  return { tokenHash, otpType }
}

const staffOut = (staff: Staff) => ({
  staff_id: staff.staff_id, member_id: staff.member_id,
  store_id: staff.store_id, role: staff.role,
  name: staff.name, cross_store: staff.cross_store,
})

/* ── 手機簡訊（2026-10-21 使用者：「改用手機登入備援」）──────────
   🔴 為什麼要有：整個 LINE 商用帳號被停權時，上面那條 LINE 登入是關著的 ——
     POS 有人交班登出之後就沒人進得去、不能開桌收錢。簡訊走 MAAC Go，跟 LINE 無關。
   ⚠ 這段寄簡訊是 line-login 的 sendSms 的**精簡版（只有 cresclab）**。
     Dashboard 部署是一支一個檔案，不能共用模組 ⇒ **換簡訊商時兩支一起改**。
   ⚠ 簽檔【MIGI咪吉麻將】剛好 8 字（NCC 規定括號內 4–8 字），中間不可以有空格 —— 見 line-login 的註解。 */
function smsConfigured(): boolean {
  return Deno.env.get('SMS_PROVIDER') === 'cresclab' && !!Deno.env.get('SMS_TOKEN')
}
const toE164TW = (local: string) => {
  const d = (local || '').replace(/\D/g, '')
  return d.startsWith('0') ? '+886' + d.slice(1) : (d.startsWith('886') ? '+' + d : local)
}
const maskPhone = (p: string) => {
  const d = (p || '').replace(/\D/g, '')
  return d.length >= 7 ? `${d.slice(0, 4)}***${d.slice(-3)}` : '***'
}
async function logSmsError(phone: string, status: number, detail: string) {
  // 事件名結尾是 _error ⇒ 錯誤儀表自動看得到；只放遮罩過的號碼
  try {
    await api('/rest/v1/rpc/log_app_event_tx', {
      method: 'POST',
      body: JSON.stringify({ p_org_id: MIGI_ORG_ID, p_member_id: null, p_event: 'sms_error',
        p_props: { provider: 'cresclab', via: 'staff-login', status, phone: maskPhone(phone), detail: (detail || '').slice(0, 400) } }),
    })
  } catch (e) { console.warn('[staff-login] sms_error 埋點寫不進去', e) }
}
async function sendSms(phone: string, text: string): Promise<boolean> {
  if (!smsConfigured()) { console.error('[staff-login] 簡訊商還沒設定'); return false }
  try {
    const res = await fetch(Deno.env.get('SMS_URL') ?? 'https://sms.cresclab.com/api/sms/send', {
      method: 'POST',
      headers: { Authorization: `Bearer ${Deno.env.get('SMS_TOKEN')}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        to: toE164TW(phone), body: text, type: 'otp',
        ...(Deno.env.get('SMS_FROM') ? { from: Deno.env.get('SMS_FROM') } : {}),
      }),
    })
    const out = await res.text()
    if (!res.ok) {
      console.error('[staff-login] cresclab 送出失敗', res.status, out.slice(0, 400))
      await logSmsError(phone, res.status, out)
      return false
    }
    return true
  } catch (e) {
    console.error('[staff-login] 簡訊送出失敗', e)
    await logSmsError(phone, 0, String(e))
    return false
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  if (req.method !== 'POST') return json({ ok: false, reason: 'method_not_allowed' }, 405)

  let body: { id_token?: string; mode?: string; code?: string; redirect_uri?: string; phone?: string; otp?: string }
  try { body = await req.json() } catch {
    return json({ ok: false, reason: 'bad_json', message: '請求格式錯誤' }, 400)
  }

  /* ── 後台「系統設定 → 店員登入方式」的開關（2026-10-21）──────────
     🔴 在這裡擋，不是只靠前端把按鈕藏起來 —— 直接打這支 API 也要被擋。
     · 手機簡訊**預設關**（使用者：平常不會有任何手機登入的入口，除非後台打開）
       ⇒ 一定要讀到「開」才放行；讀不到開關就擋。
     · LINE 預設開 ⇒ 讀到「關」才擋；讀不到（欄位還沒建、連線失敗）就放行 ——
       讀不到就擋 LINE 的話，等於設定壞掉 ＝ 全部店員進不去。 */
  const isPhone = body.mode === 'sms_send' || body.mode === 'sms_verify'
  let f: { line?: boolean; phone?: boolean } | null = null
  try {
    const fRes = await api(`/rest/v1/rpc/get_login_methods_tx`, { method: 'POST', body: JSON.stringify({ p_org_id: MIGI_ORG_ID }) })
    f = fRes.ok ? await fRes.json().catch(() => null) : null
  } catch (e) { console.warn('[staff-login] 讀不到登入開關', e) }
  if (isPhone && f?.phone !== true) {
    return json({ ok: false, reason: 'method_disabled', message: '手機簡訊登入沒有開放，請用 LINE 登入' }, 403)
  }
  if (!isPhone && f?.line === false) {
    return json({ ok: false, reason: 'method_disabled', message: 'LINE 登入已被總部關閉，請改用手機簡訊登入' }, 403)
  }

  /* ── 手機簡訊：① 寄驗證碼 ──────────────────────────
     🔴 先查「這支號碼是不是已驗證的店員手機」**再寄** ——
       不然這就是一顆「幫任何人付錢發簡訊」的按鈕。
     ⚠ 不是店員也回同一句話（不說「這支號碼不是店員」）：不讓人拿來試哪些號碼是店員。
     ⚠ 限流（60 秒一則、一小時 5 則）在 otp_request_tx 裡，這裡不重複實作。 */
  if (body.mode === 'sms_send') {
    const generic = { ok: true, sent: true, message: '如果這是已驗證的店員手機，驗證碼已經送出' }
    const stRes = await api('/rest/v1/rpc/get_staff_by_phone_tx', {
      method: 'POST', body: JSON.stringify({ p_org_id: MIGI_ORG_ID, p_phone: body.phone ?? '' }),
    })
    const st = await stRes.json().catch(() => null)
    if (st?.reason === 'phone_invalid') return json({ ok: false, reason: 'phone_invalid', message: '手機號碼格式不對（09 開頭 10 碼）' })
    if (!stRes.ok || st?.ok !== true) return json(generic)

    const rRes = await api('/rest/v1/rpc/otp_request_tx', {
      method: 'POST',
      body: JSON.stringify({ p_org_id: MIGI_ORG_ID, p_phone: body.phone ?? '', p_purpose: 'staff_login', p_line_user_id: null }),
    })
    const r = await rRes.json().catch(() => null)
    if (!rRes.ok || !r) return json({ ok: false, reason: 'otp_failed', message: '系統忙碌中，請稍後再試' }, 502)
    if (!r.ok) return json({ ok: false, reason: r.reason, retry_after: r.retry_after ?? null,
      message: r.reason === 'too_soon' || r.reason === 'rate_limited_phone' ? '剛剛才送過，請稍等再試' : '暫時無法發送，請稍後再試' })
    const sent = await sendSms(r.phone, `【MIGI咪吉麻將】POS 登入驗證碼 ${r.code}，5 分鐘內有效。`)
    if (!sent) return json({ ok: false, reason: 'sms_failed', message: '簡訊送不出去，請稍後再試' })
    return json(generic)
  }

  /* ── 手機簡訊：② 驗證碼登入 ────────────────────────
     ⚠ 嘗試次數上限（5 次）在 otp_verify_tx 裡。
     ⚠ 驗過之後**立刻用掉這一組**（consumed_at），同一組碼不能登入第二次。 */
  if (body.mode === 'sms_verify') {
    const vRes = await api('/rest/v1/rpc/otp_verify_tx', {
      method: 'POST',
      body: JSON.stringify({ p_org_id: MIGI_ORG_ID, p_phone: body.phone ?? '', p_code: body.otp ?? '', p_purpose: 'staff_login' }),
    })
    const v = await vRes.json().catch(() => null)
    if (!vRes.ok || !v) return json({ ok: false, reason: 'otp_failed', message: '系統忙碌中，請稍後再試' }, 502)
    if (v.ok !== true) {
      const msg = v.reason === 'wrong_code' ? `驗證碼不對，還可以試 ${v.left ?? 0} 次`
        : v.reason === 'expired' ? '驗證碼過期了，請重新寄一次'
        : v.reason === 'too_many_attempts' ? '試太多次了，請重新寄一次'
        : '請先寄驗證碼'
      return json({ ok: false, reason: v.reason, left: v.left ?? null, message: msg })
    }
    await api(`/rest/v1/phone_otps?org_id=eq.${MIGI_ORG_ID}&phone=eq.${encodeURIComponent(v.phone)}&purpose=eq.staff_login&consumed_at=is.null`,
      { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ consumed_at: new Date().toISOString() }) })

    // 驗過了再查一次是誰（寄碼之後到現在之間可能被移除）
    const stRes = await api('/rest/v1/rpc/get_staff_by_phone_tx', {
      method: 'POST', body: JSON.stringify({ p_org_id: MIGI_ORG_ID, p_phone: v.phone }),
    })
    const st = await stRes.json().catch(() => null)
    if (!stRes.ok || st?.ok !== true) {
      return json({ ok: false, reason: 'not_staff', message: '這支手機沒有店員權限，請找店長開通' }, 403)
    }
    /* 還沒有登入帳號的店員：有 LINE 的照 LINE 那條路的 email 建（之後用 LINE 登入是同一個帳號），
       沒有 LINE 的用 staff id 建。⚠ provider 寫 phone；GoTrue 可能覆寫這一格，不要依賴它（CLAUDE.md 待辦 20）。 */
    const sub: string | null = st.line_user_id ?? null
    const email = sub ? authEmail(sub) : `phone-${st.staff_id}@staff.migi.invalid`
    const meta: Record<string, unknown> = { provider: 'phone', migi_role: st.role, ...(sub ? { line_user_id: sub } : {}) }
    const out = await issueStaffSession(st as Staff, email, meta)
    if ('error' in out) return out.error
    if (!out.tokenHash) return json({ ok: false, reason: 'no_token_hash', message: '登入失敗，請稍後再試' }, 502)
    return json({ ok: true, token_hash: out.tokenHash, otp_type: out.otpType, staff: staffOut(st as Staff) })
  }

  let idToken = (body.id_token ?? '').trim()

  /* ── OAuth 那條路：先用 `code` 換 `id_token` ────────────
     🎯 **改動只有這一段** —— 換到 id_token 之後就併回下面的既有流程
       （驗簽 → 查 staff → 建 auth user → generate_link），一行都不用改。

     🔴 **為什麼從 LIFF 改成 OAuth**（2026-09-04，同日改兩次）：
       LIFF 的 `liff.login()` **帶不了 `initial_amr_display=lineqr`**
       ⇒ LINE 的桌面登入頁預設顯示 email＋密碼，而很多店員
         **從來沒設過 LINE 密碼**（手機號＋簡訊註冊的）
       ⇒ 那一頁對他們是**一條死路**，第一次還會以為自己需要密碼。
     ⚠ 我當天先改成 LIFF，理由是「工作量少一半」——
       **而那個判準漏掉了登入體驗**。純 OAuth 本來就是待辦 20 的原始規劃。

     ⚠ `redirect_uri` **必須跟 authorize 時送的完全一致**（LINE 會比對），
       所以由前端送過來而不是寫死在這裡 ——
       寫死的話 preview 網域就永遠登不進去。 */
  if (!idToken && body.code) {
    const secret = Deno.env.get('LINE_CHANNEL_SECRET')
    if (!secret) {
      /* 🔴 講清楚是哪個 secret 沒設。不然這個症狀（登入到一半失敗）
         會讓人去查 LINE 後台，而問題在 Edge Function 的 Secrets 裡。 */
      console.error('[staff-login] 沒有設 LINE_CHANNEL_SECRET')
      return json({ ok: false, reason: 'no_channel_secret', message: '伺服器設定不完整，請找工程師' }, 500)
    }
    let tokRes: Response
    try {
      tokRes = await fetch('https://api.line.me/oauth2/v2.1/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          grant_type: 'authorization_code',
          code: body.code,
          redirect_uri: body.redirect_uri ?? '',
          client_id: LINE_CHANNEL_ID,
          client_secret: secret,
        }),
      })
    } catch (e) {
      console.error('[staff-login] 換 token 連線失敗', e)
      return json({ ok: false, reason: 'line_unreachable', message: '連不上 LINE，請稍後再試' }, 502)
    }
    const tok = await tokRes.json().catch(() => null)
    if (!tokRes.ok || !tok?.id_token) {
      /* ⚠ 最常見的三個原因，log 出來省得猜：
         ① `redirect_uri` 跟 authorize 時不一致
         ② Callback URL 沒加進 channel 的白名單
         ③ `code` 用過了（它是一次性的） */
      console.warn('[staff-login] 換 token 失敗', tokRes.status, tok)
      return json({ ok: false, reason: 'code_exchange_failed',
        message: 'LINE 授權已失效，請重新登入' }, 401)
    }
    idToken = tok.id_token
  }

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

  /* ── ③～⑤ 找或建立 Auth user → 綁 staff.auth_uid → 發一次性登入憑證 ──────
     2026-10-21 抽成 issueStaffSession()，跟手機簡訊那條共用（見上面的說明）。 */
  const issued = await issueStaffSession(staff as Staff, authEmail(sub),
    { line_user_id: sub, provider: 'line', migi_role: staff.role }, probe, steps)
  if ('error' in issued) return issued.error
  const { tokenHash, otpType } = issued

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
    console.error('[staff-login] generate_link 沒有 hashed_token')
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
