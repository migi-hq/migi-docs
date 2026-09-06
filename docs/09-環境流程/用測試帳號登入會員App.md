# 用測試帳號登入會員 App（不需要 LINE 帳號）

> 建於 2026-09-05，配合 `sql/applied/2026-09-05_測試帳號給真身分.sql`。
>
> **為什麼需要這一份**：待辦 14 把會員身分改成「由 JWT 說了算」之後，
> 沒有 `line_user_id` 的帳號就進不去 —— 而測試01～04 一個都沒有。
> 多人社交（配桌湊四人、牌咖邀請、按讚、封鎖）**本來就需要四個身分**，
> 而註冊四個真的 LINE 帳號需要四支能收簡訊的手機。

---

## 🔴 這不是旁路，差別在哪

硬規則 5.7 明列「**開發用的 JWT 旁路**」永遠不要做。這一份不是那個：

| | |
|---|---|
| 🔴 **旁路** | 「給我一個 member id 就發 JWT」—— **不用證明就給你身分** |
| ✅ **這一份** | 測試帳號**有**一個真的身分，要用密碼向 Supabase Auth 證明 |

具體差在四點：

- **產品碼零改動** —— Edge Function、前端、那 21 支 RPC 一行都沒動
- 走**完全一樣**的路徑：`JWT.app_metadata.line_user_id → migi_jwt_line_id() → current_member_id()`
- 後端**分不出**這張 session 是測試帳號還是真客人 —— 因為它們是同一種東西
- 密碼的雜湊、比對、rate limit 全部由 **Supabase Auth** 負責
  （硬規則 5.7 的「一律用託管的」）

🎯 也就是說：**上線之後這條路可以留著，因為它沒有洞可以忘記拿掉。**

---

## 一次性設定

### ① 在 Dashboard 建四個 auth user

```
Supabase Dashboard → Authentication → Users → Add user   ×4
  Email     test01@migi.invalid  …  test04@migi.invalid
  Password  你自己設（四個可以一樣）
  ☑ Auto Confirm User          ← 🔴 不勾的話登不進去
```

⚠ `.invalid` 是 RFC 2606 保留給「保證不存在」的 TLD ——
那幾個信箱永遠收不到信，也不可能被別人註冊走。

### ② 跑一次 SQL

`sql/applied/2026-09-05_測試帳號給真身分.sql`
（給會員合成的 `line_user_id`，並把它寫進 auth user 的 `app_metadata`）。

⚠ 少建一個 auth user，那份 SQL 會**整份停下來**並告訴你少哪一個 ——
不會留下「兩個能登入、兩個不能」的半套狀態，
而那種狀態最難查，因為它看起來像「有時候會壞」。

---

## 每次要用測試帳號時

打開 `https://app.migi.tw`（或本機 `http://localhost:5173`），
開瀏覽器主控台，貼這一段：

### 🔴 貼之前先做兩件事（每個新視窗都要）

1. 主控台**用打的**輸入 `allow pasting` 按 Enter
   （Chrome 的防護，而它警告的正是「有人給你程式碼叫你貼進主控台」——
   那個提醒是對的，貼之前先看懂它做什麼）
2. **如果上一次貼失敗過，先 F5 重新整理**（理由見下面那個坑）

```js
// ── 只改這兩行 ──────────────────────────────
const N  = '01'              // 01 / 02 / 03 / 04
const PW = '你設的密碼'
// ───────────────────────────────────────────

// 🔴 **不要叫 `URL`** —— 那是瀏覽器內建的全域 class（`new URL(...)`）
const SB_URL = 'https://roksgepxxmcewlkshtzn.supabase.co'
const ORG    = '11111111-1111-1111-1111-111111111111'

// anon key 本來就會被打包進瀏覽器拿得到的 JS，所以直接從那裡撈，不用翻 .env
let ANON = null
for (const s of [...document.querySelectorAll('script[src]')].map(x => x.src)) {
  const m = (await (await fetch(s)).text())
    .match(/eyJ[\w-]{10,}\.[\w-]{10,}\.[\w-]{10,}/)
  if (m) { ANON = m[0]; break }
}
if (!ANON) throw new Error('撈不到 anon key —— 從 migi-web\\.env 手動填 VITE_SUPABASE_ANON_KEY')

const { createClient } = await import('https://esm.sh/@supabase/supabase-js@2')

// 同一個 URL ⇒ 預設的 storageKey 一樣 ⇒ 寫進 App 自己那一格 localStorage
const sb = createClient(SB_URL, ANON)
const { error } = await sb.auth.signInWithPassword({
  email: `test${N}@migi.invalid`, password: PW })
if (error) throw error

// 🎯 用剛拿到的 JWT 問後端「我是誰」，不要抄 uuid
const { data: me, error: e2 } = await sb.rpc('get_my_profile_tx', {
  p_org_id: ORG, p_member_id: null })
if (e2 || !me?.id) throw (e2 || new Error('身分解析不到 —— SQL 那一步沒跑完'))

localStorage.setItem('migi_member', JSON.stringify({ id: me.id, name: me.nickname }))
sessionStorage.setItem('migi_line_login_tried', '1')  // 🔴 保險絲：不要自動導去 LINE
console.log('✅ 現在是', me.nickname, me.id)
location.reload()
```

🔴 **member id 一律問後端，不要從文件抄。**
2026-09-01 就是抄了一個文件裡的 uuid，結果**造了三場戰績給錯的帳號**，
而畫面上什麼都沒變（硬規則 3 與踩坑第 29 條）。
🎯 而且「問得到 id」本身就是驗證 —— 問不到就代表身分那條路沒通，
片段會**當場丟例外**而不是留下一個半好半壞的狀態。

⚠ **`sessionStorage` 是分頁作用域** —— 開新分頁要重跑一次，
否則 `App.jsx` 會把你導去 LINE 登入頁。
📌 測多人社交時本來就要開多個分頁（或多個瀏覽器設定檔），
每個分頁跑一次、`N` 各填不同的號碼。
🔴 **同一個瀏覽器的不同分頁共用 `localStorage`** ——
所以四個帳號要用**四個瀏覽器設定檔或無痕視窗**，不是四個分頁。

---

## 🔴 一個會讓人查很久的坑：主控台的 `const` 會覆蓋內建全域

2026-09-05 實際踩到，而且它製造了**兩個看起來無關的症狀**。

Chrome 主控台是 REPL 模式，**頂層 `let` / `const` 會掛到全域上**
（好讓你下一行還能用）。所以 `const URL = 'https://…'` 會把
**瀏覽器內建的 `URL` class 覆蓋掉**。

而 supabase-js 內部就是 `new URL(supabaseUrl)` 在驗網址：

```
Uncaught Error: Invalid supabaseUrl: Provided URL is malformed.
```

🔴 **那個訊息完全指不到真正的原因** —— 網址是對的，壞的是 `URL` 這個名字。

⚠ **改變數名不夠**：第一次貼下去的殘留還在全域上，
所以改成 `SB_URL` 之後**症狀一模一樣**。
✅ **唯一可靠的還原是 F5 重新整理**（手動 `window.URL = …` 救不回來，
原本那個 class 已經沒有參照了）—— 同硬規則 11.6：
**收拾要整個收，而 reload 一次全部歸零。**

📌 同類地雷：`URL` / `name` / `top` / `status` / `length` / `origin`
在瀏覽器主控台都是內建全域，當變數名都會出這種指不到原因的錯。

**判斷方式**：主控台打 `URL` 按 Enter ——
印出 `ƒ URL()` 是正常，印出一個字串就是被覆蓋了。

### 🎯 為什麼要三樣東西，少一樣就不行

| 放哪 | 是什麼 | 少了會怎樣 |
|---|---|---|
| `localStorage['sb-…-auth-token']` | **真的 session** | 21 支 RPC 全部 `not_authenticated`，畫面停在讀取中 |
| `localStorage['migi_member']` | 本機身分快取 | `App.jsx:96` 直接把你丟進**註冊流程** |
| `sessionStorage['migi_line_login_tried']` | 重導保險絲 | `App.jsx:113` 把你**導去 LINE 登入頁** |

📌 前兩者是 `localStorage`（會留著），第三個是 `sessionStorage`（每個分頁要重設）——
那是刻意的，理由見 `lib/line.js:152`。

---

## 登出測試帳號

```js
localStorage.clear(); sessionStorage.clear(); location.reload()
```

⚠ 這也會清掉頭像快取與埋點佇列。那沒關係，它們都會自我修復。

---

## ⚠ 上線之後

這四個帳號**留著**（使用者 2026-09-05 決定）——
常設測試帳號是每個正式系統都有的東西。

🔴 **但它們的資料會混進真客人的畫面，而那部分今天還沒做**：
配桌房間／最近同桌／牌咖清單／門市清單**四道濾網都還沒加**
（只有排行榜濾了 `is_test`）。

→ 完整說明與順序見 `docs/09-環境流程/上線當天要設的東西.md` 的 **②.5**。
🔴 最痛的是配桌房間：真客人會看到「測試01 開的房」、報名進去、
然後等一個永遠不會來的人 —— 而**那看起來完全像是系統壞了**。
