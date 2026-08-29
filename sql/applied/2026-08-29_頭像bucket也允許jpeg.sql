/* ============================================================
   member-avatars 也允許 image/jpeg
   2026-08-29

   ── 🔴 現場 ────────────────────────────────────────
   iPhone 實測上傳，畫面回：
   ```
   上傳失敗：mime type image/png is not supported
   ```

   **iOS 的 Safari（LINE 的 WebView 就是它）不支援 webp 編碼**，
   而 `canvas.toBlob(cb, 'image/webp', q)` 遇到不支援的型別
   **不會失敗，會靜靜退回 PNG**。

   ⚠ **這件事在鎖 mime 之前就已經錯了** ——
     那時 bucket 不檢查型別，存進去的是「PNG 的位元組，標籤寫 webp」。
     不報錯、圖也看得到（瀏覽器會自己嗅探），所以完全沒有症狀。
     🎯 **是把限制加在 bucket 上才讓它現形** ——
       一個「加了限制才發現原本就是錯的」的例子。

   ── 修法（三處一起）────────────────────────────────
   ① 前端：`toBlob` 之後**看 `blob.type` 的實際值**，
      不是相信我們要求的型別；不是 webp 就改用 **JPEG**（不是 PNG ——
      同一張照片 PNG 可以大 5–10 倍，而上限只有 512 KB）。
   ② Edge Function：副檔名依實際型別決定，並對照白名單
      （`image/webp` → `.webp`、`image/jpeg` → `.jpg`）。
      🔴 白名單放在函式裡而不是只靠 bucket：bucket 擋得住上傳，
        但錯的副檔名**已經寫進路徑**了，之後就是一個 `.webp` 的 JPEG。
   ③ **這一份**：bucket 的 `allowed_mime_types` 加上 `image/jpeg`。

   ⚠ 刻意**不加 `image/png`**：頭像已經鋪了白底、沒有透明需求，
     而 PNG 對照片來說又大又沒必要。前端會轉成 JPEG，不需要放行 PNG。
   ============================================================ */

update storage.buckets
   set allowed_mime_types = array['image/webp', 'image/jpeg']
 where id = 'member-avatars';


/* ============================================================
   驗證（單一 SELECT）

   ① bucket 現在允許哪些型別
   ② 🎯 正對照：**其餘設定沒有被一起改掉**
      —— 一個寫太寬的 update 也會讓 ① 看起來是對的，
        而 `public` 或 `file_size_limit` 被順手改掉不會有任何症狀
        （硬規則 3.55）。
   ③ 🎯 正對照：`image/png` **仍然不在名單裡**
      —— 這是刻意的決定不是遺漏，驗證段要把它記下來，
        否則日後有人看到「iOS 送 PNG」會直接加上去。
   ============================================================ */
select 序, 項目, 內容 from (

  select 1 as 序, '① member-avatars 允許的型別' as 項目,
         (select coalesce(array_to_string(allowed_mime_types, '、'), '（不限）')
            from storage.buckets where id = 'member-avatars') as 內容

  union all
  select 2, '② 🎯 正對照：其餘設定沒被一起改掉',
         (select 'public=' || public::text
              || '　上限=' || coalesce((file_size_limit/1024)::text || ' KB', '無')
              || case when public and file_size_limit = 524288
                      then '　✅ 與 2026-08-29 Storage 收緊時相同'
                      else '　🔴 被動到了' end
            from storage.buckets where id = 'member-avatars')

  union all
  select 3, '③ 🎯 正對照：image/png 仍然不在名單裡（刻意的）',
         (select case when 'image/png' = any(allowed_mime_types)
                      then '🔴 被加進去了 —— 頭像不需要 PNG，前端會轉 JPEG'
                      else '✅ 不在名單裡（正確）' end
            from storage.buckets where id = 'member-avatars')

) x order by 序;
