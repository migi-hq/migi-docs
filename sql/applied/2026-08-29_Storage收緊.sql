/* ============================================================
   Storage 收緊：頭像的寫入全部搬到伺服器端
   2026-08-29

   🔴 **這一份必須在「頭像上傳真的能用」之前跑完。**
   我原本把它排在最後，那是錯的 —— 第一張照片就是第一個洞。

   ── 現況有多開 ────────────────────────────────────
   七條 policy **沒有一條檢查「是不是你自己的檔案」**，全部只比對 bucket_id：
   ```
   avatar_delete  [DELETE] to anon   條件 = bucket_id = 'member-avatars'
   avatar_insert  [INSERT] to anon   條件 = bucket_id = 'member-avatars'
   avatar_update  [UPDATE] to anon   條件 = bucket_id = 'member-avatars'
   avatar_read    [SELECT] to anon   條件 = bucket_id = 'member-avatars'
   store_photo_*  三條，同樣全開
   ```
   → **任何人可以刪掉、覆蓋任何會員的頭像照片。**

   🔴 而且有一條更難看的路徑：
   ```
   avatar_read ＋ .list()  →  列出所有資料夾名
   資料夾名就是 member_id  →  拿到全部會員 id
   get_wallet_tx(p_member_id) 是 anon 叫得動的  →  查得到每個人的餘額與消費明細
   ```
   那是待辦 14 那個洞的**實際利用路徑** ——
   原本要「知道 uuid」，這裡直接把 uuid 清單交出去。

   ── 🔴 為什麼 policy 寫不出「只能動自己的」──────────
   會員 App **用 anon key、沒有 auth session**，所以 policy 裡
   **沒有 `auth.uid()` 可以比對** —— 寫不出所有權條件。
   → 唯一能判斷「你是誰」的地方是**伺服器端**（驗 LINE 的 id_token）。
     所以寫入一律搬進 Edge Function `avatar-photo`，policy 直接清空。
   ✅ 前提已查證：`service_role` 的 `rolbypassrls = true`，
     policy 清空之後它照樣做得到所有事。

   ── 🎯 順便把 bucket 改成公開 ──────────────────────
   | | 私有 ＋ 簽名（現在） | 公開 ＋ 隨機檔名 |
   |---|---|---|
   | 列舉 member_id | 🔴 做得到 | ✅ 做不到（沒有 SELECT policy 就不能 list） |
   | 看別人的頭像 | 每次要簽名、快取、處理過期 | 直接用網址 |
   | 網址外洩 | 1 小時後失效 | 永久有效 |

   理由：**我們已經在存 LINE 的公開 CDN 網址**（`profile.line-scdn.net`）。
   自己的照片弄成私有、LINE 那張公開，是不一致而且沒換到任何東西 ——
   兩者都是「給同桌的人看的圖」。而真正的洞是 member_id 被列舉，
   公開 bucket 反而把它關掉（**公開 bucket 讀圖不需要 policy，
   但 `.list()` 需要** —— 所以 policy 清空 = 讀得到、列不出來）。
   ⚠ 代價用**隨機檔名**補：`{member_id}/{uuid}.webp`，猜不到。
   📌 LINE／Discord／Slack 的頭像都是這一套（公開 CDN ＋ 猜不到的路徑）。

   ── 順帶把上傳限制收緊 ────────────────────────────
   簽名上傳網址在有效期內可以放任何東西上去，所以**限制要在 bucket 上**：
   · `allowed_mime_types = {image/webp}` —— 前端一律裁成 webp，沒有例外
   · `file_size_limit` 3 MB → 512 KB（512×512 的 webp 約 30–60 KB）
   🔴 不設的話，一個外洩的簽名網址就能把這裡當免費檔案空間。

   ── store-photos 三條一起刪 ────────────────────────
   ✅ **0 個檔案、三個 repo 一次都沒引用過**（已 grep）。
     Supabase Dashboard 自己也跳了警告。
   ⚠ `stores.photos` 欄位存在但沒有資料 —— 要用的時候再建對的 policy。
   ============================================================ */

-- ── ① member-avatars 改公開，並收緊上傳限制 ────────
update storage.buckets
   set public = true,
       file_size_limit = 524288,                      -- 512 KB
       allowed_mime_types = array['image/webp']
 where id = 'member-avatars';

-- ── ② 清掉 member-avatars 的四條 policy ─────────────
--    寫入改走 Edge Function（service_role 繞過 RLS）；
--    讀取靠公開 bucket，不需要 policy。
drop policy if exists avatar_read   on storage.objects;
drop policy if exists avatar_insert on storage.objects;
drop policy if exists avatar_update on storage.objects;
drop policy if exists avatar_delete on storage.objects;

-- ── ③ 清掉 store-photos 的三條 policy ───────────────
--    0 檔案、0 引用。要用的時候再建對的。
drop policy if exists store_photo_read   on storage.objects;
drop policy if exists store_photo_write  on storage.objects;
drop policy if exists store_photo_delete on storage.objects;


/* ============================================================
   驗證（單一 SELECT）

   ① bucket 設定
   ② policy 應該一條都不剩
   ③ 🎯 正對照：**RLS 本身仍然是開的**
      —— policy 清空 ≠ RLS 關掉。若有人不小心關了 RLS，
        那才是真的門戶大開，而症狀跟「policy 清空」長得一模一樣。
   ④ 🎯 正對照：service_role 仍然繞得過 RLS
      —— 這是整個設計成立的前提。它若是 false，Edge Function 會上傳失敗，
        而那時前端只會顯示「上傳失敗」，看不出原因在這裡。
   ⑤ 現有檔案（應該是 0，還沒有人成功留下照片）
   ============================================================ */
select 序, 項目, 內容 from (

  select 1 as 序, '① bucket 設定' as 項目,
         (select string_agg(id
                 || '　public=' || case when public then '✅ true' else 'false' end
                 || '　上限=' || coalesce((file_size_limit/1024)::text || ' KB', '無')
                 || '　允許型別=' || coalesce(array_to_string(allowed_mime_types, ','), '（不限）'),
                 E'\n' order by id)
            from storage.buckets) as 內容

  union all
  select 2, '② storage.objects 的 policy（應該一條都不剩）',
         coalesce((select string_agg(policyname || '　[' || cmd || ']', E'\n' order by policyname)
                     from pg_policies where schemaname = 'storage' and tablename = 'objects'),
                  '✅ 一條都沒有 —— 寫入只剩 service_role（Edge Function）')

  union all
  /* 🔴 policy 清空 ≠ RLS 關掉。
     RLS 開著 ＋ 0 條 policy = 除了 bypassrls 的角色，誰都做不了任何事（正確）。
     RLS 關掉 ＋ 0 條 policy = **所有人都做得到任何事**（災難）。
     兩者在 ② 那一段長得一模一樣，所以一定要單獨驗（硬規則 3.55）。 */
  select 3, '③ 🎯 正對照：storage.objects 的 RLS 仍然開著',
         (select case when c.relrowsecurity
                      then '✅ RLS = 開　（0 條 policy ⇒ 除了 service_role 誰都動不了）'
                      else '🔴 RLS = 關！　0 條 policy ＋ RLS 關 = 所有人都能動' end
            from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'storage' and c.relname = 'objects')

  union all
  select 4, '④ 🎯 正對照：service_role 仍然繞得過 RLS（這份設計的前提）',
         (select case when rolbypassrls
                      then '✅ bypassrls = true　Edge Function 照樣讀寫得了'
                      else '🔴 bypassrls = false　—— 上傳會壞掉，而且前端只會說「上傳失敗」' end
            from pg_roles where rolname = 'service_role')

  union all
  select 5, '⑤ 現有檔案',
         (select coalesce(string_agg(bucket_id || ' ' || n::text || ' 個', '　'), '兩個 bucket 都是空的')
            from (select bucket_id, count(*) n from storage.objects group by 1) t)

) x order by 序;
