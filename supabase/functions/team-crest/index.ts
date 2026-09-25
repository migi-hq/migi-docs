/* ============================================================
   team-crest —— 牌咖團團徽照片的上傳與刪除（唯一的寫入入口）
   2026-09-11 · MIGI 咪吉麻將

   ── 🔴 為什麼不是塞進 avatar-photo ─────────────────
   直覺是「上傳機制只留一套，加一個 kind 參數」。
   但 `avatar-photo` 這個名字會因此裝兩件事，而**函式名字改不掉**
   （前端是用名字叫它的）—— 那是這個專案記過八次的同一族病。

   ⚠ 而「共用」在 Edge Function 上本來就做不到：
     它們各自獨立部署，**沒有共用模組的機制**。
     `avatar-photo` 自己的註解就寫過這件事：驗身分那三十行
     與 `line-login` 的前半一樣，是**刻意各留一份**的。
   🎯 真正不可以重複的是「**決定**」—— 去哪個 bucket、路徑怎麼組、
     誰有權限。而那些在這支裡全部是獨有的，一行都沒有跟頭像共用。

   🔴 唯一真的共用的是「誰能換團徽」，而它在**資料庫**裡：
     `_is_team_leader()`，由 `set_team_crest_tx` / `team_crest_guard_tx` /
     `clear_team_crest_tx` 三支一起呼叫。
     判斷寫在這裡的話，會出現「App 裡改得動、上傳卻被擋」。

   ── 兩個模式 ────────────────────────────────────────
   | mode | 做什麼 |
   |---|---|
   | `sign_upload` | 驗 LINE → 問資料庫「他是不是團長」→ 發簽名上傳網址 |
   | `delete` | 驗 LINE → 清欄位（RPC 回傳舊路徑）→ 刪檔案 |

   ── 部署 ────────────────────────────────────────────
   Supabase Dashboard → Edge Functions → Deploy a new function
   名稱：**team-crest**（⚠ 前端是用這個名字叫它）
   環境變數：`LINE_CHANNEL_ID = 2011312117`（與另外兩支共用）
   ⚠ SUPABASE_URL 與 SUPABASE_SERVICE_ROLE_KEY 由平台自動注入。
   ⚠ bucket `team-crests` 要先建好（`sql/applied/2026-09-11_牌咖團團徽上傳.sql`）。
   ============================================================ */

const MIGI_ORG_ID = '11111111-1111-1111-1111-111111111111'
const LINE_CHANNEL_ID = Deno.env.get('LINE_CHANNEL_ID') ?? '2011312117'
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const BUCKET = 'team-crests'

/* 縮圖的路徑：`<team>/<uuid>.webp` → `<team>/<uuid>.s.webp`（2026-09-25）。
   ⚠ 與 `avatar-photo` 與 migi-web `lib/avatar.js` 的 `thumbOf()` **同一條規則**，
     改要三處一起改（Edge Function 之間沒有共用模組）。 */
const thumbOf = (p: string) => p.replace(/\.(webp|jpg)$/, '.s.$1')

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
   ⚠ 與 `avatar-photo` 逐行相同，理由見檔頭（Edge Function 沒有共用模組）。 */
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
    console.error('[team-crest] LINE verify 連線失敗', e)
    return { ok: false, status: 502, body: { ok: false, reason: 'line_unreachable', message: '連不上 LINE，請稍後再試' } }
  }

  const body = await res.json().catch(() => ({}))
  if (!res.ok) {
    return { ok: false, status: 401, body: { ok: false, reason: 'line_token_invalid', message: 'LINE 授權已失效，請重新開啟一次' } }
  }
  const sub = body?.sub
  if (!sub || typeof sub !== 'string') {
    console.error('[team-crest] 驗過了但沒有 sub，檢查 LIFF 的 openid scope')
    return { ok: false, status: 500, body: { ok: false, reason: 'no_sub', message: '取不到 LINE 識別碼，請找店員或客服' } }
  }
  if (body?.aud && String(body.aud) !== LINE_CHANNEL_ID) {
    return { ok: false, status: 401, body: { ok: false, reason: 'aud_mismatch', message: '授權來源不符' } }
  }

  return memberByLine(sub)
}

type Who = { ok: true; memberId: string } | { ok: false; status: number; body: unknown }

/* LINE 帳號 → 會員。兩條認人的路最後都走這一段，**只寫一份**。 */
async function memberByLine(lineId: string): Promise<Who> {
  const found = await api(
    `rest/v1/members?select=id&org_id=eq.${MIGI_ORG_ID}` +
    `&line_user_id=eq.${encodeURIComponent(lineId)}&deleted_at=is.null&limit=1`)
  const rows = await found.json().catch(() => null)
  const memberId = Array.isArray(rows) && rows[0]?.id
  if (!memberId) {
    return { ok: false, status: 404, body: { ok: false, reason: 'not_registered', message: '請先完成註冊' } }
  }
  return { ok: true, memberId }
}

/* 🔴 **2026-09-17：先用 Supabase 登入狀態認人，LINE id_token 只當退路。**
   使用者實機回報：上傳團徽 →「LINE 授權已失效，請重新開啟一次」。

   根因：LINE 的 id_token **登入之後大約一小時就過期**，而 LIFF 在 App 開著的
   時候**不會自己換新**（`liff.getIDToken()` 回的一直是登入那一刻拿到的那張）。
   ⇒ App 開超過一小時，任何走 id_token 的動作都會失敗 —— 頭像上傳也一樣。

   ✅ 會員 App 從 2026-09-05 起就有 **Supabase session**，而 supabase-js
     **會自己刷新**那張 JWT。前端把它放在 `Authorization` 送過來，
     這裡拿去問 `/auth/v1/user` 認人 —— 與資料庫的 `current_member_id()`
     是**同一條身分路徑**（`app_metadata.line_user_id`）。
   🔴 **只讀 `app_metadata`，絕對不讀 `user_metadata`** ——
     後者客戶端自己就改得到，讀它等於「填任何 LINE id 就變成他」（CLAUDE.md 待辦 14）。

   ⚠ 回 `null` 只代表「**沒有可用的 session**」（送的是 anon key、過期、
     或這個 user 沒有 LINE id），那時才退回 id_token。
     session 有效但查不到會員，照實回 404，不要退回去換一句話。
   ⚠ id_token 那條留著是 expand-safe：還沒更新的前端（舊版快取）照樣能用。 */
async function whoAmIFromSession(req: Request): Promise<Who | null> {
  const tok = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '').trim()
  if (!tok) return null
  let res: Response
  try {
    res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${tok}` },
    })
  } catch (e) {
    console.error('[team-crest] 查 session 失敗，退回 id_token', e)
    return null
  }
  if (!res.ok) return null
  const u = await res.json().catch(() => null)
  const lineId = u?.app_metadata?.line_user_id
  if (!lineId || typeof lineId !== 'string') return null
  return memberByLine(lineId)
}

/* 🔴 `team_id` 會被組進 Storage 的路徑，所以**一定要驗格式**。
   少了這一行，`../` 或 `/` 那一類的值會把檔案寫到別的資料夾去 ——
   而權限那一關是靠「路徑以 team_id 開頭」在守的。
   ⚠ 這與「他是不是團長」是兩件事，兩道都要有。 */
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  if (req.method !== 'POST') return json({ ok: false, reason: 'method_not_allowed' }, 405)

  let body: { id_token?: string; mode?: string; mime?: string; team_id?: string }
  try { body = await req.json() } catch {
    return json({ ok: false, reason: 'bad_json', message: '請求格式錯誤' }, 400)
  }

  const teamId = (body.team_id ?? '').trim()
  if (!UUID.test(teamId)) {
    return json({ ok: false, reason: 'bad_team_id', message: '牌咖團識別碼不正確' }, 400)
  }

  /* 先 session、再 id_token（理由見 `whoAmIFromSession`）。兩個都沒有才擋。 */
  const idToken = (body.id_token ?? '').trim()
  const me = (await whoAmIFromSession(req)) ?? (idToken ? await whoAmI(idToken) : null)
  if (!me) {
    return json({ ok: false, reason: 'not_logged_in', message: '登入狀態已過期，請關閉 MIGI 再重新開啟' }, 401)
  }
  if (!me.ok) return json(me.body, me.status)

  /* ── sign_upload ───────────────────────────────────
     🔴 順序是「**先問資料庫他是不是團長，再發網址**」。
       反過來的話，任何會員都能拿到一個寫得進 bucket 的簽名網址 ——
       而簽名網址一旦發出去就攔不住了。 */
  if (body.mode === 'sign_upload') {
    const g = await api('rest/v1/rpc/team_crest_guard_tx', {
      method: 'POST',
      body: JSON.stringify({ p_team_id: teamId, p_member_id: me.memberId }),
    })
    const guard = await g.json().catch(() => null)
    if (!g.ok || !guard?.ok) {
      /* ⚠ 把後端那句中文原樣往上傳，不要在這裡再寫一份 ——
         「只有團長可以換團徽」與「這個團的自訂團徽已停用」是兩件事，
         翻譯只維護一份（同 `social.js` 對 `useLineAvatar` 的做法）。 */
      return json({
        ok: false,
        reason: guard?.reason ?? 'guard_failed',
        message: guard?.message ?? '不能換這個團的團徽',
      }, guard?.reason === 'not_found' ? 404 : 403)
    }

    /* 副檔名由前端送來的**實際**型別決定，但只認白名單裡的兩種。
       🔴 iOS 的 Safari 不支援 webp 編碼，`canvas.toBlob` 會靜靜退回 JPEG
         ——「一律 .webp」是錯的假設（2026-08-29 實機打臉過）。
       ⚠ 白名單放在這裡而不是只放 bucket：bucket 擋得住上傳，
         但錯的副檔名已經寫進路徑了，之後看起來就是一個 `.webp` 的 JPEG。 */
    const EXT: Record<string, string> = { 'image/webp': 'webp', 'image/jpeg': 'jpg' }
    const ext = EXT[String(body.mime ?? '').toLowerCase()]
    if (!ext) {
      return json({ ok: false, reason: 'mime_not_allowed', message: '這種圖片格式不支援，請換一張' }, 400)
    }

    /* 🔴 路徑由這裡決定，前端沒有任何機會指定它。
       資料夾是 **team_id**（不是 member_id）—— 團徽屬於團，
       換了團長之後那些檔案仍然是那個團的。
       ⚠ 檔名用 UUID 不是時間戳：bucket 是公開的，時間戳猜得到。 */
    const path = `${teamId}/${crypto.randomUUID()}.${ext}`

    /* ⚠ body 一定要送 `{}`，不可以省略 —— `api()` 帶了 JSON 的
       Content-Type，而 POST 沒有 body 時 Storage 會解析失敗。
       📌 照 `@supabase/storage-js` 的 `createSignedUploadUrl` 打。 */
    const res = await api(`storage/v1/object/upload/sign/${BUCKET}/${path}`, {
      method: 'POST', body: JSON.stringify({}),
    })
    const out = await res.json().catch(() => null)
    if (!res.ok || !out?.url) {
      console.error('[team-crest] 產生簽名上傳網址失敗', res.status, out)
      return json({
        ok: false, reason: 'sign_failed',
        message: '上傳失敗（S' + res.status + '），請再試一次',
      }, 502)
    }
    const token = String(out.url).split('token=')[1] ?? ''

    /* 縮圖（2026-09-25）：同一張圖的 128px 版本，給團卡清單用。
       ⚠ 失敗不擋原圖 —— 少了 thumb_token，前端就只傳原圖、畫面讀原圖。 */
    const thumbPath = thumbOf(path)
    const tr = await api(`storage/v1/object/upload/sign/${BUCKET}/${thumbPath}`, {
      method: 'POST', body: JSON.stringify({}),
    })
    const tout = await tr.json().catch(() => null)
    const thumb = tr.ok && tout?.url
      ? { thumb_path: thumbPath, thumb_token: String(tout.url).split('token=')[1] ?? '' }
      : {}
    if (!tr.ok) console.warn('[team-crest] 縮圖簽名失敗（只傳原圖）', tr.status, tout)

    return json({ ok: true, path, token, url: `${SUPABASE_URL}/storage/v1${out.url}`, ...thumb })
  }

  /* ── delete ────────────────────────────────────────
     🎯 先清資料庫、再刪檔案：
       先刪檔案失敗 → 欄位指向不存在的檔案（**看得見、會壞畫面**）
       先清欄位失敗 → 孤兒檔案（看不見、不影響任何東西）
     ⚠ 要刪哪一個檔案由 `clear_team_crest_tx` **回傳**，
       不採信前端送來的路徑 —— 那會變成「刪別人的檔案」。 */
  if (body.mode === 'delete') {
    const res = await api('rest/v1/rpc/clear_team_crest_tx', {
      method: 'POST',
      body: JSON.stringify({ p_team_id: teamId, p_member_id: me.memberId }),
    })
    const out = await res.json().catch(() => null)
    if (!res.ok || !out?.ok) {
      console.error('[team-crest] clear_team_crest_tx 失敗', res.status, out)
      return json({
        ok: false,
        reason: out?.reason ?? 'clear_failed',
        message: out?.message ?? '刪除失敗，請再試一次',
      }, out?.reason === 'not_leader' ? 403 : 502)
    }
    if (out.path) {
      const rm = await api(`storage/v1/object/${BUCKET}`, {
        method: 'DELETE', body: JSON.stringify({ prefixes: [out.path, thumbOf(out.path)] }),
      })
      /* ⚠ 檔案刪不掉**不回失敗** —— 欄位已經清了，畫面是對的，
         留下的只是一個沒有人指向的孤兒檔案。
         這時說「刪除失敗」會讓客人一直按。 */
      if (!rm.ok) console.warn('[team-crest] 檔案沒刪掉（孤兒檔）', await rm.text().catch(() => ''))
    }
    return json({ ok: true })
  }

  return json({ ok: false, reason: 'bad_mode', message: '未知的操作' }, 400)
})
