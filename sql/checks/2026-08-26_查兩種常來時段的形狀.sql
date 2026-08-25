/* ============================================================
   查：兩種「常來時段」的實際形狀，以及行為推斷的原料齊不齊
   2026-08-26 · 唯讀

   ── 使用者的分法（2026-08-26）────────────────────────
   A **行為推斷**（系統算）：通常何時報名／何時開打／能等多久／
     等多久會成桌／通常可打時段／**會不會遲到**
     → 🔴 只給系統與總部，**不對客人顯示**（連他本人都不該看到）
   B **自我宣告**（客人填）：「我都打早上」
     → 給其他客人看，是自我介紹

   ✅ 這個分法跟 schema 已有的 `member_availability.source` 對得上，
     也跟 `03-會員App與社交/會員情報體系.md` 的四維度
     （作息／耐心／人格／路程）同一個框架。
   ⚠ 隱私邊界與 `M2技術設計:465`「合拍度只後台用，不在客人前端出現」同一條規則：
     「他通常等 12 分鐘就走」對他本人都不該顯示 ——
     那會讓人覺得被監視，而且**測量行為本身會改變行為**。

   ── 這支要回答四件事 ────────────────────────────────
   ① 兩套各自存在哪、允許值是什麼
   ② member_availability 是不是空的（決定它是「設計好沒人用」還是「有在用」）
   ③ 行為推斷的原料齊不齊 —— 特別是**「約幾點打」有沒有存**
      （沒有預定時間就沒有東西可以跟實際入座比對 → 遲到推斷做不出來）
   ④ 四維度裡其他三個（耐心／人格／路程）有沒有落地
   ============================================================ */

select 序, 項目, 內容 from (

  /* ① B 那套：set_my_sched_tx 寫到哪 */
  select 1 as 序, '① set_my_sched_tx 定義' as 項目,
         coalesce((select pg_get_functiondef(p.oid)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname = 'set_my_sched_tx'
                    limit 1), '🔴 不存在') as 內容

  union all
  /* ② A 那套：member_availability 的允許值
        source 是關鍵 —— 它應該就是「自填 vs 推斷」的分野。 */
  select 2, '② member_availability 的 CHECK',
         coalesce((select string_agg(c.conname || '　' || pg_get_constraintdef(c.oid), '　│　')
                     from pg_constraint c
                     join pg_class t on t.oid = c.conrelid
                    where t.relnamespace = 'public'::regnamespace
                      and t.relname = 'member_availability' and c.contype = 'c'),
                  '（沒有 CHECK —— 任何字串都能寫）')

  union all
  select 3, '③ member_availability 現況',
         coalesce((select case when count(*) = 0 then '（空的 —— 設計好了沒人用）'
                               else count(*)::text || ' 列　source 分佈：' ||
                                    coalesce(string_agg(distinct source, '、'), '?') end
                     from member_availability), '（讀不到）')

  union all
  /* ④ members 上有沒有 B 那套的欄位（作息偏好字串） */
  select 4, '④ members 的作息／風格欄位',
         coalesce((select string_agg(column_name || ' ' || data_type, '　'
                                     order by column_name)
                     from information_schema.columns
                    where table_schema = 'public' and table_name = 'members'
                      and (column_name ilike '%sched%' or column_name ilike '%style%'
                        or column_name ilike '%patien%' or column_name ilike '%wait%'
                        or column_name ilike '%rating%' or column_name ilike '%about%')),
                  '🔴 一個都沒有')

  union all
  /* ⑤ 🔴 行為推斷的原料：match_queues 有沒有「約幾點打」
        沒有預定開打時間，就沒有東西可以跟實際入座時間比對
        → 「會不會遲到」推斷不出來。 */
  select 5, '⑤ match_queues 的時間欄位',
         coalesce((select string_agg(column_name || ' ' || data_type, '　'
                                     order by ordinal_position)
                     from information_schema.columns
                    where table_schema = 'public' and table_name = 'match_queues'
                      and (data_type ilike '%time%' or column_name ilike '%at%'
                        or column_name ilike '%time%' or column_name ilike '%slot%')),
                  '🔴 沒有時間欄位')

  union all
  /* ⑥ 實際入座時間：session_players 有沒有記「什麼時候坐下」 */
  select 6, '⑥ session_players 的時間欄位',
         coalesce((select string_agg(column_name || ' ' || data_type, '　'
                                     order by ordinal_position)
                     from information_schema.columns
                    where table_schema = 'public' and table_name = 'session_players'),
                  '🔴 表不存在')

  union all
  /* ⑦ 報名 → 結果 的時間差算不算得出來（等多久會走／等多久成桌）
        先看實際資料：expired / cancelled 的房，從建立到結束隔多久。 */
  select 7, '⑦ 現有配桌房的等待時長（分鐘）',
         q.status || '：' || count(*)::text || ' 房　中位數 ' ||
         coalesce(round(percentile_cont(0.5) within group (
           order by extract(epoch from (coalesce(q.updated_at, now()) - q.created_at))/60
         ))::text, '?') || ' 分'
    from match_queues q
   group by q.status

  union all
  /* ⑧ 四維度的其他三個有沒有落地
        （會員情報體系.md：作息／耐心／人格／路程）
        member_rating 2026-08-26 已確認不存在，這裡看還有沒有別的。 */
  select 8, '⑧ 四維度相關的表',
         coalesce((select string_agg(c.relname, '　' order by c.relname)
                     from pg_class c
                    where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
                      and (c.relname ilike '%availab%' or c.relname ilike '%rating%'
                        or c.relname ilike '%patien%' or c.relname ilike '%persona%'
                        or c.relname ilike '%distance%' or c.relname ilike '%geo%')),
                  '🔴 只有 member_availability')

) x order by 序, 項目, 內容;
