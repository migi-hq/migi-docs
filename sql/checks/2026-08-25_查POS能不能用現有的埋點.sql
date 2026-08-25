/* ============================================================
   查：POS 能不能直接用現有的 log_app_event_tx
   2026-08-25 · 唯讀

   ── 兩個必須先確認的問題 ────────────────────────────
   ① `log_app_event_tx(p_org_id, p_member_id, p_event, p_props, p_client_ts)`
      **沒有 p_store_id**，但 `app_events.is_test` 是靠
      `set_is_test_from_store()` 帶入的。
      🔴 那個觸發器**怎麼知道是哪家店**？
        會員端可以從 member 的 home_store 推，**POS 沒有 member**。
   ② POS 沒有登入的會員 → p_member_id 要傳 null。
      `app_events.member_id` 若是 NOT NULL，整條路走不通。

   ⚠ 這兩件事**只有查了才知道**。猜「應該可以吧」然後寫一整套前端，
     結果是埋了但全部寫不進去，而且**不會有人發現** ——
     因為埋點失敗本來就是靜默的（送不出去就進離線佇列）。
   ============================================================ */

select 序, 項目, 內容 from (

  /* ① app_events 的欄位與可空性 —— member_id / store_id 是關鍵 */
  select 1 as 序, '① app_events 欄位' as 項目,
         coalesce((select string_agg(column_name || ' ' || data_type ||
                                     (case when is_nullable = 'NO' then ' 🔴NOT NULL' else '' end) ||
                                     coalesce('=' || column_default, ''),
                                     '　' order by ordinal_position)
                     from information_schema.columns
                    where table_schema = 'public' and table_name = 'app_events'),
                  '🔴 app_events 表不存在') as 內容

  union all
  /* ② log_app_event_tx 的完整定義 —— 它到底怎麼決定 store */
  select 2, '② log_app_event_tx 定義',
         coalesce((select pg_get_functiondef(p.oid)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname = 'log_app_event_tx'
                    limit 1), '🔴 不存在')

  union all
  /* ③ set_is_test_from_store() 的定義 —— 沒有 store 時它會怎樣 */
  select 3, '③ set_is_test_from_store 定義',
         coalesce((select pg_get_functiondef(p.oid)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname = 'set_is_test_from_store'
                    limit 1), '🔴 不存在')

  union all
  /* ④ app_events 上的觸發器（可能不只 is_test 那一個） */
  select 4, '④ app_events 觸發器',
         coalesce((select string_agg(tg.tgname || ' → ' || p.proname, '　│　')
                     from pg_trigger tg
                     join pg_class t on t.oid = tg.tgrelid
                     join pg_proc p on p.oid = tg.tgfoid
                    where t.relnamespace = 'public'::regnamespace
                      and t.relname = 'app_events' and not tg.tgisinternal),
                  '（沒有觸發器）')

  union all
  /* ⑤ 現在有多少事件、是誰寫的 —— 確認這條路真的通
        （會員端已經在用，所以應該有資料；沒有的話代表它其實也沒在寫） */
  select 5, '⑤ app_events 現況',
         coalesce((select '總計 ' || count(*)::text || ' 筆　' ||
                          'member_id 為 null ' || count(*) filter (where member_id is null)::text || ' 筆　' ||
                          'is_test ' || count(*) filter (where is_test)::text || ' 筆'
                     from app_events), '（讀不到）')

  union all
  /* ⑥ 最近出現過哪些事件名 —— 命名慣例要跟會員端一致，
        POS 的事件才不會變成第二套詞彙。 */
  select 6, '⑥ 最近的事件名',
         coalesce((select string_agg(t.e, '、' order by t.n desc)
                     from (select event as e, count(*) as n
                             from app_events group by event
                            order by 2 desc limit 12) t),
                  '（還沒有任何事件）')

  union all
  /* ⑦ staff 表的實際形狀（2026-08-25 加問）。
        使用者要把角色分成兩端：
          POS  店員／店長／門市營運／BOSS
          總部 BOSS／數據分析／財務／採購／行銷…
        現在是一欄 `role` 裝 floor/manager/hq/owner —— 兩個維度壓在一起。
        設計新形狀之前要先看現況：有沒有 store_id、能不能一人多列、
        role 的 CHECK 長什麼樣。 */
  select 7, '⑦ staff 欄位',
         coalesce((select string_agg(column_name || ' ' || data_type ||
                                     (case when is_nullable = 'NO' then '*' else '' end),
                                     '　' order by ordinal_position)
                     from information_schema.columns
                    where table_schema = 'public' and table_name = 'staff'),
                  '🔴 staff 表不存在')

  union all
  select 8, '⑧ staff 的約束',
         coalesce((select string_agg(c.conname || '　' || pg_get_constraintdef(c.oid), '　│　')
                     from pg_constraint c
                     join pg_class t on t.oid = c.conrelid
                    where t.relnamespace = 'public'::regnamespace
                      and t.relname = 'staff'),
                  '（沒有約束）')

  union all
  /* ⑨ 現有幾列、role 分佈 —— 目前應該只有一列（總部管理員），
        而它的 member_id 是 null（待辦 20 記過，LINE 接上也登不進去）。 */
  select 9, '⑨ staff 現況',
         coalesce((select string_agg(t.k, '　' order by t.k)
                     from (select coalesce(role,'(null)') || '：' || count(*)::text ||
                                  ' 列，member_id 為 null ' ||
                                  count(*) filter (where member_id is null)::text as k
                             from staff group by role) t),
                  '（staff 表是空的）')

  union all
  /* ⑩ 有沒有任何 RLS policy 在讀 role / current_staff()
        —— 待辦 21 說是 0 條，這裡重新確認一次（文件不是鏡像）。 */
  select 10, '⑩ 用到 current_staff/has_store_access 的 policy',
         coalesce((select string_agg(pol.polname || '@' || t.relname, '、')
                     from pg_policy pol
                     join pg_class t on t.oid = pol.polrelid
                    where t.relnamespace = 'public'::regnamespace
                      and (pg_get_expr(pol.polqual, pol.polrelid) ilike '%current_staff%'
                        or pg_get_expr(pol.polqual, pol.polrelid) ilike '%has_store_access%')),
                  '🔴 0 條 —— 角色目前完全沒有生效')

) x order by 序, 項目;
