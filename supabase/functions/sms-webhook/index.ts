/* ============================================================
   sms-webhook —— 接收 MAAC Go（漸強實驗室）的簡訊送達／失敗通知
   2026-10-17 建立 · MIGI 咪吉麻將

   起因：10-16 13:23 起 MAAC Go 往電信送不出去（gateway_error），但它是**先收下、事後才判定失敗**，
     line-login 當下拿到成功，會員 App 寫「已寄出」⇒ 客人等不到碼、一直按重送。
   這支收到失敗通知 → 寫進 phone_otps.sms_status = failed → 會員 App 的驗證碼畫面輪詢時看到，
     顯示「簡訊沒送到，請稍後再試」。

   🔴 安全：每一個請求先驗 X-Cresclab-Signature ＝ hex(HMAC-SHA256(webhook secret, 原始 body))
     （官方套件 @maacgo/sms README 的寫法）。不對 ⇒ 401、什麼都不做。
   ⇒ **Verify JWT 要關掉**（MAAC Go 不會帶 Supabase 的登入憑證）。

   ⚠ 通知的欄位名稱官方只寫了 `event`（例：sms.delivered），其餘這裡多認幾種寫法：
     訊息 ID：message_id／id／data.message_id／data.id
     失敗原因：error／reason／error_code／data.error／data.reason／data.error_code
     認不出訊息 ID、或是失敗通知 ⇒ 整包（手機號碼遮罩）寫進 app_events 的 sms_error，錯誤儀表看得到，
     第一次真的收到時就知道格式，要調就改這支。

   ── 部署 ────────────────────────────────────────────
   Supabase Dashboard → Edge Functions → 新增 `sms-webhook` → 貼上 → **Verify JWT 關掉** → Deploy
   Secrets：SMS_WEBHOOK_SECRET ＝ MAAC Go 後台 Webhooks 頁給的 secret（或我們自己設、同時填到 MAAC Go）
   MAAC Go 後台 → Webhooks → URL 填
     https://roksgepxxmcewlkshtzn.supabase.co/functions/v1/sms-webhook
   🔴 secret 只放 Secrets，不要貼進程式碼、SQL 或對話。
   ============================================================ */

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const SECRET = Deno.env.get('SMS_WEBHOOK_SECRET') ?? ''
const MIGI_ORG_ID = '11111111-1111-1111-1111-111111111111'

const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { 'Content-Type': 'application/json' } })

const rpc = async (fn: string, args: Record<string, unknown>) => {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(args),
  })
  const body = await r.json().catch(() => null)
  if (!r.ok) throw new Error(`${fn} ${r.status} ${JSON.stringify(body)}`)
  return body
}

// 簽章：hex(HMAC-SHA256(secret, 原始 body))；逐字比對用固定時間，不讓時間差洩漏答案
async function signatureOk(raw: string, sig: string | null): Promise<boolean> {
  if (!sig || !SECRET) return false
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(SECRET), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(raw)))
  const want = [...mac].map((b) => b.toString(16).padStart(2, '0')).join('')
  const got = sig.trim().toLowerCase().replace(/^sha256=/, '')
  if (want.length !== got.length) return false
  let diff = 0
  for (let i = 0; i < want.length; i++) diff |= want.charCodeAt(i) ^ got.charCodeAt(i)
  return diff === 0
}

// 手機號碼遮罩（09xxxxxxxx、+8869xxxxxxxx）—— 記進資料庫的內容不放完整號碼
const mask = (s: string) =>
  s.replace(/(\+?886|0)(9\d{2})\d{3}(\d{3})/g, (_m, a, b, c) => `${a}${b}***${c}`)

// 驗證碼本身也遮掉（訊息內容可能整段回拋）
const maskCode = (s: string) => s.replace(/驗證碼是\s*\d{4,8}/g, '驗證碼是 ******')

async function logSmsEvent(detail: string, status: number) {
  try {
    await rpc('log_app_event_tx', {
      p_org_id: MIGI_ORG_ID, p_member_id: null, p_event: 'sms_error',
      p_props: { provider: 'cresclab', via: 'webhook', status, detail: maskCode(mask(detail)).slice(0, 1500) },
    })
  } catch (e) {
    console.warn('[sms-webhook] sms_error 埋點寫不進去', e)
  }
}

const pick = (o: Record<string, unknown> | null | undefined, ...keys: string[]) => {
  for (const k of keys) {
    const v = o && o[k]
    if (typeof v === 'string' && v) return v
  }
  return null
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: false, reason: 'method_not_allowed' }, 405)
  const raw = await req.text()
  if (!(await signatureOk(raw, req.headers.get('x-cresclab-signature')))) {
    return json({ ok: false, reason: 'bad_signature' }, 401)
  }

  let body: Record<string, unknown> | null = null
  try { body = JSON.parse(raw) } catch { /* 下面當成認不出格式 */ }
  const data = (body && typeof body.data === 'object' ? body.data : null) as Record<string, unknown> | null

  const event = (pick(body, 'event', 'type') ?? '').toLowerCase()
  const st = (pick(body, 'status') ?? pick(data, 'status') ?? '').toLowerCase()
  const id = pick(body, 'message_id', 'id') ?? pick(data, 'message_id', 'id')
  const reason = pick(body, 'error', 'reason', 'error_code') ?? pick(data, 'error', 'reason', 'error_code')

  // 事件 → 狀態：名稱或 status 裡有 fail ⇒ failed；有 deliver ⇒ delivered
  const kind = /fail|undeliver|reject|error/.test(event + ' ' + st) ? 'failed'
    : /deliver/.test(event + ' ' + st) ? 'delivered' : null

  if (!id || !kind) {
    // 認不出格式：整包記下來，回 200（不要讓 MAAC Go 一直重送一個我們看不懂的東西）
    await logSmsEvent(`認不出的通知 event=${event} status=${st} body=${raw}`, 200)
    return json({ ok: true, ignored: true })
  }

  try {
    const r = await rpc('sms_delivery_tx', { p_message_id: id, p_status: kind, p_reason: reason })
    if (kind === 'failed') {
      await logSmsEvent(`送達失敗 ${id} ${reason ?? ''}（對到驗證碼 ${r?.matched ?? 0} 組）`, 200)
    }
    return json({ ok: true, matched: r?.matched ?? 0 })
  } catch (e) {
    console.error('[sms-webhook] 寫入失敗', e)
    // 回 500 ⇒ MAAC Go 會依它的退避規則重送（0s → 2s → 8s）
    return json({ ok: false, reason: 'db_failed' }, 500)
  }
})
