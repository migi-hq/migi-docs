/* ============================================================
   line-push —— 把寄件匣（notification_deliveries）裡待送的訊息推到客人的 LINE
   2026-10-05 建立 · MIGI 咪吉麻將

   誰會叫它：
   · 觸發器 _push_enqueue（有新通知排進寄件匣的那一刻，經 pg_net）
   · pg_cron `line-push-sweep`（每分鐘，有到期的待送才打）
   兩者都在 header 帶 `x-migi-worker-key`，取件時資料庫自己比對 vault 那一份 ——
   ⇒ 這支**不用開 Verify JWT**；別人亂打只會拿到空陣列，什麼都不會送。

   每一筆的流程：
   ① 先查「這個人有沒有加官方帳號好友」（取得個人資料 API，免費、不吃則數）
      404 ⇒ skipped / not_friend。
      🔴 不先查的話：直接推給沒加好友或封鎖的人，LINE 照樣回 200，訊息卻沒到 ——
        我們會以為送到了。
   ② 推播，帶 X-Line-Retry-Key = 那一筆的 retry_key
      ⇒ 重試、斷線重送、卡住被退回再送，LINE 都只會送一次（重複的回 409 ＝ 已送過）
   ③ 回報結果：sent／skipped／failed／retry（retry 由資料庫決定退避與上限）

   ── 部署 ────────────────────────────────────────────
   Supabase Dashboard → Edge Functions → 新增 `line-push` → 貼上 → **Verify JWT 關掉** → Deploy
   Secrets：
     LINE_MESSAGING_TOKEN = Messaging API channel（@254blful）的 channel access token（long-lived）
   ⚠ SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 由平台自動注入。
   🔴 token 只放 Secrets，不要貼進程式碼、SQL 或對話。
   ============================================================ */

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const LINE_TOKEN = Deno.env.get('LINE_MESSAGING_TOKEN') ?? ''

const BUDGET_MS = 40_000          // 一次最多跑 40 秒，剩下的交給下一分鐘的排程
const BATCH = 20

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

// messages：資料庫組好的訊息框（文字／卡片，最多 5 個，幾個都只算 1 則）；text 是舊版只有文字時的退路
type Job = { id: string; to: string; retry_key: string; text: string; messages?: unknown[] }
type Outcome = { outcome: 'sent' | 'skipped' | 'failed' | 'retry'; http?: number; reason?: string; request_id?: string; error?: string }

const line = (path: string, init: RequestInit = {}) =>
  fetch(`https://api.line.me${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${LINE_TOKEN}`, ...(init.headers ?? {}) },
  })

async function deliver(job: Job): Promise<Outcome> {
  // ① 是不是好友
  let prof: Response
  try {
    prof = await line(`/v2/bot/profile/${encodeURIComponent(job.to)}`)
  } catch (e) {
    return { outcome: 'retry', reason: 'network', error: String(e) }
  }
  if (prof.status === 404) return { outcome: 'skipped', http: 404, reason: 'not_friend' }
  if (prof.status === 401 || prof.status === 403) {
    // token 錯了或被撤銷 —— 每一筆都會一樣，回 retry 讓它留著，修好 token 之後自己會送出
    return { outcome: 'retry', http: prof.status, reason: 'bad_token', error: await prof.text() }
  }
  if (prof.status === 429 || prof.status >= 500) {
    return { outcome: 'retry', http: prof.status, reason: 'line_busy', error: await prof.text() }
  }
  // 其他狀態（例如 400：id 格式 LINE 不認）當成送不出去
  if (!prof.ok) return { outcome: 'failed', http: prof.status, reason: 'profile_' + prof.status, error: await prof.text() }

  // ② 推播
  let res: Response
  try {
    res = await line('/v2/bot/message/push', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Line-Retry-Key': job.retry_key },
      body: JSON.stringify({
        to: job.to,
        messages: Array.isArray(job.messages) && job.messages.length > 0
          ? job.messages.slice(0, 5)
          : [{ type: 'text', text: job.text }],
      }),
    })
  } catch (e) {
    return { outcome: 'retry', reason: 'network', error: String(e) }
  }
  const requestId = res.headers.get('x-line-request-id') ?? undefined

  if (res.ok) return { outcome: 'sent', http: res.status, request_id: requestId }
  // 409：同一把 retry key 之前已經被 LINE 收下 ⇒ 其實送過了
  if (res.status === 409) {
    return { outcome: 'sent', http: 409, request_id: res.headers.get('x-line-accepted-request-id') ?? requestId }
  }
  const text = await res.text()
  if (res.status === 429) {
    // 免費則數用完也是 429，但重試不會好 —— 分開記，錯誤儀表才看得出來
    if (/monthly limit/i.test(text)) return { outcome: 'failed', http: 429, reason: 'quota', error: text }
    return { outcome: 'retry', http: 429, reason: 'line_busy', error: text }
  }
  if (res.status === 401 || res.status === 403) return { outcome: 'retry', http: res.status, reason: 'bad_token', error: text }
  if (res.status >= 500) return { outcome: 'retry', http: res.status, reason: 'line_busy', error: text }
  return { outcome: 'failed', http: res.status, reason: 'http_' + res.status, error: text }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: false, reason: 'method_not_allowed' }, 405)
  const key = req.headers.get('x-migi-worker-key') ?? ''
  if (!key) return json({ ok: false, reason: 'no_key' }, 401)
  if (!LINE_TOKEN) {
    // 寄件匣的列會留在 pending，設好 token 之後下一分鐘自己送出去
    console.error('[line-push] 沒有設 LINE_MESSAGING_TOKEN')
    return json({ ok: false, reason: 'no_line_token' }, 500)
  }

  const started = Date.now()
  const tally: Record<string, number> = {}
  try {
    while (Date.now() - started < BUDGET_MS) {
      // 鑰匙不對時資料庫回空陣列 ⇒ 迴圈直接結束，什麼都不送
      const jobs = (await rpc('push_claim_tx', { p_key: key, p_limit: BATCH })) as Job[]
      if (!Array.isArray(jobs) || jobs.length === 0) break
      for (const job of jobs) {
        const o = await deliver(job)
        tally[o.outcome] = (tally[o.outcome] ?? 0) + 1
        if (o.outcome !== 'sent') console.warn('[line-push]', job.id, o.outcome, o.reason, o.http ?? '')
        await rpc('push_report_tx', {
          p_key: key, p_id: job.id, p_outcome: o.outcome,
          p_http: o.http ?? null, p_reason: o.reason ?? null,
          p_request_id: o.request_id ?? null, p_error: o.error ?? null,
        })
      }
    }
  } catch (e) {
    // 回報失敗的那一筆會停在 sending，5 分鐘後被退回 pending 再送（retry key 保證不會重複）
    console.error('[line-push] 中斷', e)
    return json({ ok: false, reason: 'aborted', tally }, 500)
  }
  return json({ ok: true, tally })
})
