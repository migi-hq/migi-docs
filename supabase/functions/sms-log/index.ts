/* ============================================================
   sms-log —— 管理後台「簡訊紀錄」：最近寄出的驗證碼簡訊，連同那組驗證碼
   2026-11-20 建立 · MIGI 咪吉麻將

   起因（使用者 11-20）：客人有時候收不到簡訊，要能在管理後台看到驗證碼，店員唸給客人聽。

   ── 為什麼要跟 MAAC Go 拿，不是我們自己存 ───────────────
   我們的資料庫只存驗證碼的雜湊（phone_otps.code_hash），**刻意看不到原本的數字**；
   MAAC Go 的發送紀錄存著簡訊全文。⇒ 這支用我們的 API 金鑰去 MAAC Go 列最近 200 封，
   再用訊息 ID 對上我們自己的 phone_otps（手機號碼、用途、有沒有驗證成功都以我們這邊為準 ——
   MAAC Go 的 webhook 回傳的號碼是遮罩過的，列表 API 可能也是）。

   ── 🔴 安全 ───────────────────────────────────────────
   看得到驗證碼 ＝ 能替任何手機完成驗證（包括自助認領別人的帳號，換 LINE 那條路）。
   ⇒ 只給總部（can('member.read')，hq／owner），每一次讀取都記一筆 admin_sms_view（誰、幾筆、查了哪個號碼末三碼）。
   ⚠ MAAC Go 後台本來就看得到同樣的內容（admin@migi.tw），這一頁沒有多開一扇門，只是把那扇門搬進後台、而且有紀錄。

   ── 部署 ────────────────────────────────────────────
   Supabase Dashboard → Edge Functions → 新增 `sms-log` → 貼上 → **Verify JWT 開著**（只給登入的後台叫）→ Deploy
   Secrets：沿用 line-login 的 SMS_TOKEN（MAAC Go 正式金鑰，要有 sms.read 權限 —— 11-20 截圖確認有）
   🔴 金鑰只放 Secrets，不要貼進程式碼、SQL 或對話。
   ============================================================ */

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!
const SMS_TOKEN = Deno.env.get('SMS_TOKEN') ?? ''
const MAAC = 'https://sms.cresclab.com/api'
const MIGI_ORG_ID = '11111111-1111-1111-1111-111111111111'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } })

// 用「呼叫者自己的登入」叫 RPC（權限判斷要以他的身分問）
const asUser = async (token: string, fn: string, args: Record<string, unknown>) => {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: ANON_KEY, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(args),
  })
  return r.ok ? r.json() : null
}
// 用服務身分讀資料表（phone_otps、members 前端碰不到）
const asService = async (path: string) => {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
  })
  if (!r.ok) throw new Error(`${path.split('?')[0]} ${r.status}`)
  return r.json()
}
const logView = async (props: Record<string, unknown>) => {
  try {
    await fetch(`${SUPABASE_URL}/rest/v1/rpc/log_app_event_tx`, {
      method: 'POST',
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_org_id: MIGI_ORG_ID, p_member_id: null, p_event: 'admin_sms_view', p_props: props }),
    })
  } catch { /* 紀錄寫不進去不擋查詢 */ }
}

const digits = (s: unknown) => String(s ?? '').replace(/\D/g, '')
// +886912345678 → 0912345678
const localPhone = (s: unknown) => { const d = digits(s); return d.startsWith('886') ? '0' + d.slice(3) : d }
// 簡訊全文裡的驗證碼（line-login：「你的驗證碼是 123456」；店員登入那支寫法可能不同，所以只認「驗證碼」後面第一串數字）
const codeOf = (body: unknown) => { const m = String(body ?? '').match(/驗證碼[^0-9]{0,6}(\d{4,8})/); return m ? m[1] : null }

type Maac = { id: string; to?: string; body?: string; status?: string; sent_at?: string; delivered_at?: string; error?: string | null }

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  if (req.method !== 'POST') return json({ ok: false, reason: 'method_not_allowed' }, 405)

  const token = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '')
  // 權限：以呼叫者身分問 can('member.read') —— 跟後台會員頁同一個碼（總部才有）
  const allowed = token ? await asUser(token, 'can', { p_perm: 'member.read' }) : null
  if (allowed !== true) return json({ ok: false, reason: 'forbidden', message: '只有總部看得到簡訊紀錄' }, 403)
  if (!SMS_TOKEN) return json({ ok: false, reason: 'no_token', message: '後端沒有設定 MAAC Go 金鑰（SMS_TOKEN）' }, 500)

  let q = ''
  try { q = digits((await req.json())?.phone) } catch { /* 沒帶條件 ⇒ 全部 */ }

  // ① MAAC Go 最近 200 封（它一次最多給 200）
  const mr = await fetch(`${MAAC}/sms/list?limit=200`, { headers: { Authorization: `Bearer ${SMS_TOKEN}` } })
  const mj = await mr.json().catch(() => null)
  if (!mr.ok || !mj?.ok) {
    console.error('[sms-log] MAAC Go 列表失敗', mr.status, JSON.stringify(mj).slice(0, 300))
    return json({ ok: false, reason: 'maac_failed', message: `簡訊商（MAAC Go）那邊讀不到紀錄（${mr.status}）` }, 502)
  }
  const msgs: Maac[] = Array.isArray(mj.messages) ? mj.messages : []

  // ② 用訊息 ID 對上我們自己的驗證碼紀錄
  const ids = msgs.map((m) => m.id).filter(Boolean)
  const otps: Record<string, any> = {}
  for (let i = 0; i < ids.length; i += 80) {
    const part = ids.slice(i, i + 80).map((x) => `"${x}"`).join(',')
    const rows = await asService(`phone_otps?select=sms_message_id,phone,purpose,sent_at,expires_at,verified_at,attempts,sms_status,sms_fail_reason&sms_message_id=in.(${encodeURIComponent(part)})`)
    for (const r of rows) otps[r.sms_message_id] = r
  }
  // ③ 手機號碼對到哪一位會員（沒註冊完的人對不到，那是正常的）
  const phones = [...new Set(Object.values(otps).map((o: any) => localPhone(o.phone)).filter(Boolean))]
  const names: Record<string, string> = {}
  if (phones.length) {
    const ms = await asService(`members?select=phone,display_name&deleted_at=is.null&phone=in.(${encodeURIComponent(phones.map((p) => `"${p}"`).join(','))})`)
    for (const m of ms) names[localPhone(m.phone)] = m.display_name
  }

  const now = Date.now()
  let rows = msgs.map((m) => {
    const o = otps[m.id]
    const phone = o ? localPhone(o.phone) : localPhone(m.to)
    const st = String(m.status ?? o?.sms_status ?? '').toLowerCase()
    return {
      id: m.id,
      at: m.sent_at ?? o?.sent_at ?? null,
      phone,
      name: names[phone] ?? null,
      purpose: o?.purpose ?? null,                 // register／change_phone…；對不到 = 不是驗證碼（例如店員登入）
      status: st === 'delivered' ? 'delivered' : st === 'failed' ? 'failed' : 'pending',
      error: m.error ?? o?.sms_fail_reason ?? null,
      code: codeOf(m.body),
      verified: !!o?.verified_at,
      expired: o?.expires_at ? new Date(o.expires_at).getTime() < now : null,
      attempts: o?.attempts ?? null,
    }
  })
  if (q) rows = rows.filter((r) => r.phone.includes(q))

  // 誰看的：登入帳號（auth uid）—— 對得到 staff.auth_uid
  let uid: string | null = null
  try {
    const u = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: ANON_KEY, Authorization: `Bearer ${token}` } })
    uid = u.ok ? (await u.json())?.id ?? null : null
  } catch { /* 拿不到就記 null */ }
  await logView({ n: rows.length, q_tail: q ? q.slice(-3) : null, viewer_uid: uid })
  return json({ ok: true, rows, total: msgs.length })
})
