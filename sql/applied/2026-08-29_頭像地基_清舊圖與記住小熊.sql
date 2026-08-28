/* ============================================================
   頭像地基：① 清掉那張測試圖的指標　② 加 `avatar_bear`
   2026-08-29

   ── ① 為什麼要先清指標 ────────────────────────────
   `member-avatars` 裡有一張 2026-08-04 上傳的測試小熊圖
   （`d73fdac2-…/1785777818508.webp`，274KB），
   而 `members.avatar_photo_path` 還指向它。

   🔴 **順序不能反：先清資料庫的指標，再去 Dashboard 刪檔案。**
     反了的話會留下「指向不存在檔案的路徑」，
     `resolveAvatarUrl()` 簽不出網址，畫面破圖或空白**而且不會報錯**
     —— 同硬規則 3.85 那一類。

   ⚠ 這支**不刪 Storage 的檔案**（SQL 刪不到 S3 上的物件）。
     跑完之後到 Dashboard → Storage → member-avatars 手動刪那個檔。

   ── ② 為什麼要加 `avatar_bear` ────────────────────
   🔴 現在「選了哪一隻小熊」**根本沒存進資料庫**：
   ```
   rewards.jsx  →  useBearAvatar()  →  set_avatar_tx(member,'bear')   只存 source
                →  setMyAvatarLocal(url, …)                            只寫 localStorage
   ```
   而下次載入時 `avatarSrc()` 回的是 `rankBearSrc(member.rank)` ——
   **段位對應的那一隻**。→ 換一台裝置就變回去了，跟手機那一列同一個病。

   ⚠ **刻意不加 CHECK**：小熊清單是**內容**不是狀態（同硬規則 10 的分法），
     日後會增加。加了 CHECK 每新增一隻就要跑一次 migration。
     壞值的後果也很輕微：`rankBearSrc()` 找不到就 fallback 回段位熊 ——
     那已經是現有行為，不會壞掉。
   ============================================================ */

-- ① 加欄位（可為 null = 沒選過，就用段位推導，維持現有行為）
alter table members add column if not exists avatar_bear text;

comment on column members.avatar_bear is
  '會員選用的小熊造型名稱（例：金牌熊）。null = 沒選過，依 rank 推導。'
  '刻意不加 CHECK：小熊清單是內容不是狀態，會增加；'
  '壞值時 rankBearSrc() 會 fallback 回段位熊，不會壞掉。';

-- ② 清掉那張測試圖的指標
do $$
declare
  v_member uuid := 'd73fdac2-d6b9-4b8a-bcff-b19c2786056f';
  v_path   text := 'd73fdac2-d6b9-4b8a-bcff-b19c2786056f/1785777818508.webp';
  v_n int;
  v_msg text;
begin
  /* ⚠ 條件寫死那個路徑：如果它已經被換成別張，這支應該什麼都不做，
     而不是把一個不知道是什麼的照片指標清掉。 */
  update members
     set avatar_photo_path = null,
         avatar_photo_at   = null,
         -- 若正在使用照片就切回小熊，否則畫面會指向不存在的檔案
         avatar_source     = case when avatar_source = 'photo' then 'bear' else avatar_source end,
         updated_at = now()
   where id = v_member
     and avatar_photo_path = v_path;

  get diagnostics v_n = row_count;

  if v_n = 1 then
    v_msg := '✅ 指標已清除，現在可以去 Dashboard 刪檔案了';
  else
    select '⚠ 沒有更新任何列 —— 它現在的 avatar_photo_path 是 '
           || coalesce(avatar_photo_path, 'null')
      into v_msg from members where id = v_member;
  end if;

  perform set_config('migi.av', v_msg, false);
end $$;


/* ============================================================
   驗證（單一 SELECT）

   ── 該看到什麼 ──────────────────────────────────────
   ① ✅ 指標已清除
   ② `avatar_bear` 欄位存在且全部是 null（沒人選過，行為與之前相同）
   ③ 四位會員都沒有 avatar_photo_path，且沒有人卡在 source='photo'
      —— 🔴 那個組合（source=photo 但 path=null）會讓畫面破圖
   ④ ⏳ 提醒：Storage 的檔案還在，要手動刪
   ============================================================ */
select 序, 項目, 內容 from (

  select 1 as 序, '① 清除結果' as 項目,
         coalesce(current_setting('migi.av', true), '🔴 DO 區塊沒執行') as 內容

  union all
  select 2, '② avatar_bear 欄位',
         (select 'type=' || data_type || '　可為 null=' || is_nullable
              || '　目前有值的會員數=' || (select count(*) filter (where avatar_bear is not null)::text from members)
            from information_schema.columns
           where table_schema='public' and table_name='members' and column_name='avatar_bear')

  union all
  select 3, '③ 四位會員的頭像狀態（不該有 source=photo 但 path=null）',
         (select string_agg(display_name || '　source=' || coalesce(avatar_source,'?')
                 || '　path=' || coalesce(avatar_photo_path,'（無）')
                 || case when avatar_source = 'photo' and avatar_photo_path is null
                         then '　🔴 破圖組合' else '' end,
                 E'\n' order by created_at)
            from members where deleted_at is null)

  union all
  select 4, '④ ⏳ 還要手動做的事',
         'Dashboard → Storage → member-avatars → d73fdac2-… → 刪掉 1785777818508.webp'
         || E'\n  ⚠ SQL 刪不到 S3 上的物件，只能清指標。'

) x order by 序;
