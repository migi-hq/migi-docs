/* ============================================================
   line-webhook —— 接收 MIGI 官方帳號（@254blful）的 LINE 事件
   2026-10-07 建立 · MIGI 咪吉麻將
   📄 預覽：https://claude.ai/artifact/3HytBmMi9f9d7i4SoPyMRz

   處理兩種事件，其餘一律不理（回 200）：
   · follow（加好友）     → 回一張歡迎卡片（內容由資料庫 line_welcome_flex_tx 組，開頭叫他的 LINE 名字）
   · postback attend:<房> → 配桌湊滿卡片上的「確定會到」→ line_attend_confirm_tx 記下來，回一句話
   ⚠ 兩種都是「回覆訊息」（reply），不扣每月免費則數。

   🔴 安全：每一個請求都先驗 X-Line-Signature（用 Messaging API 頻道的 Channel secret 做 HMAC-SHA256）。
     簽名不對 ⇒ 直接 401、什麼都不做 —— 別人假冒 LINE 打這個網址沒有用。
   ⇒ 這支**不用開 Verify JWT**（LINE 不會帶 Supabase 的登入憑證）。

   ── 部署 ────────────────────────────────────────────
   Supabase Dashboard → Edge Functions → 新增 `line-webhook` → 貼上 → **Verify JWT 關掉** → Deploy
   Secrets：
     LINE_CHANNEL_SECRET  = Messaging API 頻道（@254blful）Basic settings 裡的 Channel secret
     LINE_MESSAGING_TOKEN = （line-push 已經在用的那一個，共用）
   LINE Developers → Messaging API 分頁 → Webhook URL 填
     https://roksgepxxmcewlkshtzn.supabase.co/functions/v1/line-webhook
   → Verify → 打開 Use webhook。
   LINE Official Account Manager → 回應設定 → **加入好友的歡迎訊息關掉**（不然會收到兩則）。
   🔴 secret 與 token 只放 Secrets，不要貼進程式碼、SQL 或對話。
   ============================================================ */

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const CHANNEL_SECRET = Deno.env.get('LINE_CHANNEL_SECRET') ?? ''
const LINE_TOKEN = Deno.env.get('LINE_MESSAGING_TOKEN') ?? ''

const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { 'Content-Type': 'application/json' } })

const rpc = async (fn: string, args: Record<string, unknown>) => {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(args),
  })
  const body = await r.json().catch(() => null)
  if (!r.ok) throw new Error(`${fn} ${r.status} ${JSON.stringify(body)}`)
  return body
}

const line = (path: string, init: RequestInit = {}) =>
  fetch(`https://api.line.me${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${LINE_TOKEN}`, ...(init.headers ?? {}) },
  })

// 簽名：base64(HMAC-SHA256(channel secret, 原始 body))；逐字比對用固定時間，不讓時間差洩漏答案
async function signatureOk(raw: string, sig: string | null): Promise<boolean> {
  if (!sig || !CHANNEL_SECRET) return false
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(CHANNEL_SECRET), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(raw)))
  const want = btoa(String.fromCharCode(...mac))
  if (want.length !== sig.length) return false
  let diff = 0
  for (let i = 0; i < want.length; i++) diff |= want.charCodeAt(i) ^ sig.charCodeAt(i)
  return diff === 0
}

async function reply(replyToken: string, messages: unknown[]) {
  const r = await line('/v2/bot/message/reply', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ replyToken, messages }),
  })
  if (!r.ok) console.error('[line-webhook] 回覆失敗', r.status, await r.text())
}

type LineEvent = {
  type: string
  replyToken?: string
  source?: { userId?: string }
  postback?: { data?: string }
}

async function handle(ev: LineEvent) {
  const userId = ev.source?.userId
  if (!ev.replyToken || !userId) return

  if (ev.type === 'follow') {
    // 叫他的 LINE 名字；拿不到就不叫（卡片照樣送）
    let name: string | null = null
    try {
      const p = await line(`/v2/bot/profile/${encodeURIComponent(userId)}`)
      if (p.ok) name = ((await p.json()) as { displayName?: string }).displayName ?? null
    } catch { /* 拿不到名字不影響歡迎卡片 */ }
    const flex = await rpc('line_welcome_flex_tx', { p_name: name })
    await reply(ev.replyToken, [flex])
    return
  }

  if (ev.type === 'postback') {
    const data = ev.postback?.data ?? ''
    const m = /^attend:([0-9a-f-]{36})$/i.exec(data)
    if (!m) return
    const res = await rpc('line_attend_confirm_tx', { p_line_user_id: userId, p_queue_id: m[1] }) as { reply?: string }
    if (res?.reply) await reply(ev.replyToken, [{ type: 'text', text: res.reply }])
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: false, reason: 'method_not_allowed' }, 405)
  const raw = await req.text()
  if (!(await signatureOk(raw, req.headers.get('x-line-signature')))) {
    return json({ ok: false, reason: 'bad_signature' }, 401)
  }
  if (!LINE_TOKEN) console.error('[line-webhook] 沒有設 LINE_MESSAGING_TOKEN，回覆會失敗')

  let events: LineEvent[] = []
  try { events = (JSON.parse(raw).events ?? []) as LineEvent[] } catch { /* 不是 JSON 就當沒有事件 */ }

  // 一個事件出錯不影響其他事件；一律回 200（不然 LINE 會一直重送同一批）
  for (const ev of events) {
    try { await handle(ev) } catch (e) { console.error('[line-webhook] 事件處理失敗', ev.type, e) }
  }
  return json({ ok: true, n: events.length })
})
