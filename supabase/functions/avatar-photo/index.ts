/* ============================================================
   avatar-photo —— 頭像照片的上傳與刪除（唯一的寫入入口）
   2026-08-29 · MIGI 咪吉麻將

   ── 🔴 為什麼一定要有這一支 ────────────────────────
   會員 App **用 anon key、沒有 auth session**，所以 Storage 的 policy 裡
   **沒有 `auth.uid()` 可以比對** —— 寫不出「只能動自己的檔案」。
   在這之前那四條 policy 只比對 `bucket_id`，也就是
   **任何人可以刪掉、覆蓋任何會員的頭像照片**。

   → 唯一能判斷「你是誰」的地方是伺服器端（驗 LINE 的 id_token）。
     所以 policy 全部清空，寫入只剩 `service_role`，而 service_role
     只存在於這支函式裡。

   ── 三個模式 ────────────────────────────────────────
   | mode | 做什麼 |
   |---|---|
   | `sign_upload` | 驗身分 → 產生**隨機路徑**的簽名上傳網址交給前端 |
   | `delete` | 驗身分 → 清 DB 欄位 → 刪檔案 |
   | （其他） | 400 |

   🎯 **上傳不經過這支函式的記憶體。**
   直覺做法是把圖片 base64 塞進 JSON 送過來再轉存，但那樣
   每張圖都要進出函式一次（多 33% 體積、多一次逾時的機會）。
   簽名上傳網址讓前端**直接傳給 Storage**，這裡只負責「決定路徑並授權」。

   ── ⚠ 路徑一定要由伺服器決定 ────────────────────────
   `{member_id}/{crypto.randomUUID()}.webp`
   · `member_id` 從**驗過簽的 sub** 查出來，不是前端送的
   · 檔名用 UUID 不是時間戳 —— bucket 是公開的，
     時間戳猜得到，UUID 猜不到（路徑本身就是憑證）

   ── 部署 ────────────────────────────────────────────
   Supabase Dashboard → Edge Functions → Deploy a new function
   名稱：**avatar-photo**（⚠ 前端是用這個名字叫它）
   需要的環境變數：`LINE_CHANNEL_ID = 2011312117`（與 line-login 共用）
   ⚠ SUPABASE_URL 與 SUPABASE_SERVICE_ROLE_KEY 由平台自動注入。
   ============================================================ */

const MIGI_ORG_ID = '11111111-1111-1111-1111-111111111111'
const LINE_CHANNEL_ID = Deno.env.get('LINE_CHANNEL_ID') ?? '2011312117'
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const BUCKET = 'member-avatars'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status, headers: { ...CORS, 'Content-Type': 'application/json' },
  })

const api = (path: string, init: RequestInit = {}) =>
  fetch(`${SUPABASE_URL}/${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
      ...(init.headers ?? {}),
    },
  })

/* 驗 LINE 的 id_token 並換成 member_id。
   ⚠ 這一段跟 line-login 的前半是同一件事，但**刻意各留一份** ——
     Edge Function 之間沒有共用模組的機制（各自獨立部署），
     硬要共用就要靠複製貼上或 import_map，兩者都比這 30 行更容易走鐘。
   🔴 真正不可以重複的是「決定」（路徑怎麼組、誰有權限），那些只有這裡有。 */
async function whoAmI(idToken: string): Promise<
  { ok: true; memberId: string } | { ok: false; status: number; body: unknown }
> {
  let res: Response
  try {
    res = await fetch('https://api.line.me/oauth2/v2.1/verify', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ id_token: idToken, client_id: LINE_CHANNEL_ID }),
    })
  } catch (e) {
    console.error('[avatar-photo] LINE verify 連線失敗', e)
    return { ok: false, status: 502, body: { ok: false, reason: 'line_unreachable', message: '連不上 LINE，請稍後再試' } }
  }

  const body = await res.json().catch(() => ({}))
  if (!res.ok) {
    return { ok: false, status: 401, body: { ok: false, reason: 'line_token_invalid', message: 'LINE 授權已失效，請重新開啟一次' } }
  }
  const sub = body?.sub
  if (!sub || typeof sub !== 'string') {
    console.error('[avatar-photo] 驗過了但沒有 sub，檢查 LIFF 的 openid scope')
    return { ok: false, status: 500, body: { ok: false, reason: 'no_sub', message: '取不到 LINE 識別碼，請洽櫃檯' } }
  }
  // ⚠ 零成本的第二道：LINE 已經驗過 aud，但換端點或參數寫錯時這裡會擋下來
  if (body?.aud && String(body.aud) !== LINE_CHANNEL_ID) {
    return { ok: false, status: 401, body: { ok: false, reason: 'aud_mismatch', message: '授權來源不符' } }
  }

  const found = await api(
    `rest/v1/members?select=id&org_id=eq.${MIGI_ORG_ID}` +
    `&line_user_id=eq.${encodeURIComponent(sub)}&deleted_at=is.null&limit=1`)
  const rows = await found.json().catch(() => null)
  const memberId = Array.isArray(rows) && rows[0]?.id
  if (!memberId) {
    return { ok: false, status: 404, body: { ok: false, reason: 'not_registered', message: '請先完成註冊' } }
  }
  return { ok: true, memberId }
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

  const me = await whoAmI(idToken)
  if (!me.ok) return json(me.body, me.status)

  /* ── sign_upload ───────────────────────────────────
     🔴 路徑由這裡決定，前端**沒有任何機會指定它** ——
       那是「只能傳到自己資料夾」這件事唯一的保證。 */
  if (body.mode === 'sign_upload') {
    const path = `${me.memberId}/${crypto.randomUUID()}.webp`
    /* 🔴 body 一定要送 `{}`，不可以省略。
       `api()` 帶了 `Content-Type: application/json`，而 POST 沒有 body 時
       Storage 會解析失敗 —— 第一版就是這樣，上傳一路失敗到這裡才看得出來。
       📌 查證方式：讀 `@supabase/storage-js` 自己的 `createSignedUploadUrl`，
         它送的是 `post(fetch, url, {}, { headers })`。
         **官方 client 怎麼打，就照著打** —— 這種細節猜不出來。 */
    const res = await api(`storage/v1/object/upload/sign/${BUCKET}/${path}`, {
      method: 'POST', body: JSON.stringify({}),
    })
    const out = await res.json().catch(() => null)
    if (!res.ok || !out?.url) {
      console.error('[avatar-photo] 產生簽名上傳網址失敗', res.status, out)
      /* ⚠ 把狀態碼帶回去。這是**我們自己基礎設施**的錯誤碼，不是機密，
         而少了它，前端只會顯示「上傳失敗」—— 客人回報之後還是查不到原因。 */
      return json({
        ok: false, reason: 'sign_failed',
        message: '上傳失敗（S' + res.status + '），請再試一次',
      }, 502)
    }
    /* Storage 回的是相對路徑（`/object/upload/sign/...?token=…`）。
       ⚠ 前端用 supabase-js 的 `uploadToSignedUrl(path, token)`，只需要 token，
         但一併回完整網址，之後若改用純 fetch 上傳不用再改這支。 */
    const token = String(out.url).split('token=')[1] ?? ''
    return json({ ok: true, path, token, url: `${SUPABASE_URL}/storage/v1${out.url}` })
  }

  /* ── delete ────────────────────────────────────────
     🎯 順序是「先清資料庫、再刪檔案」（同 2026-08-29 那個 bug 的結論）：
       先刪檔案失敗 → 欄位指向不存在的檔案（看得見、會壞畫面）
       先清欄位失敗 → 孤兒檔案（看不見、不影響任何東西）
     ⚠ 要刪哪一個檔案由 `clear_avatar_photo_tx` **回傳**，
       不採信前端送來的路徑 —— 那又會變成「刪別人的檔案」。 */
  if (body.mode === 'delete') {
    const res = await api('rest/v1/rpc/clear_avatar_photo_tx', {
      method: 'POST', body: JSON.stringify({ p_member_id: me.memberId }),
    })
    const out = await res.json().catch(() => null)
    if (!res.ok || !out?.ok) {
      console.error('[avatar-photo] clear_avatar_photo_tx 失敗', res.status, out)
      return json({ ok: false, reason: 'clear_failed', message: '刪除失敗，請再試一次' }, 502)
    }
    if (out.path) {
      const rm = await api(`storage/v1/object/${BUCKET}`, {
        method: 'DELETE', body: JSON.stringify({ prefixes: [out.path] }),
      })
      /* ⚠ 檔案刪不掉**不回失敗** —— 欄位已經清了，畫面是對的，
         留下的只是一個沒有人指向的孤兒檔案。
         這時說「刪除失敗」會讓客人一直按。 */
      if (!rm.ok) console.warn('[avatar-photo] 檔案沒刪掉（孤兒檔）', await rm.text().catch(() => ''))
    }
    return json({ ok: true, switched_to_bear: !!out.switched_to_bear })
  }

  return json({ ok: false, reason: 'bad_mode', message: '未知的操作' }, 400)
})
