-- ============================================================
-- 收掉 POS 五支寫入函式的 anon 與 PUBLIC（2026-09-20）
--
--   open_session_tx · activate_session_tx
--   set_table_active_tx · set_table_auto_assign_tx · _try_auto_seat_tx
--
-- ============================================================
-- 🔴 先更正我自己講過的一句錯話
-- ============================================================
-- 我說 `open_session_tx` 是「唯一還留著 anon ＋ PUBLIC 的營運函式」——
-- **那是從 8 支樣本推出來的全稱，實際不是**。全庫實查：
-- ```
-- anon 叫得動      98 支
-- PUBLIC 叫得動    95 支
-- 只靠 PUBLIC 進來  0 支   ← 每一支有 PUBLIC 的也都有明確的 anon
-- ```
-- 📌 最後那一格有意義：**單收 PUBLIC 完全不會有效果**（硬規則 2.6b 的反面），
--   所以下面每一支都收兩行。
--
-- ⇒ 正確的範圍不是「誰有 anon」，是「**POS 呼叫的 50 支裡誰還是 anon**」：
-- ```
-- 🟢 讀取類 16   list_* × 12 · get_session_tx · list_blocks_tx
--                list_buddies_tx · list_daypass_tx        ← 這一批不動，見下
-- 🔴 寫入類  5   就是這一份要收的
-- ```
--
-- ============================================================
-- ✅ 為什麼今天收是安全的（全部查證過，不是推測）
-- ============================================================
-- ### ① 「POS 用 anon 所以不能收」這個理由**已經過期**
-- POS 2026-09-04 起有真的 Supabase session。而它同一批在用的
-- `checkout_tx` / `topup_tx` / `settle_session_tx` / `void_session_tx` /
-- `join_session_tx` / `pos_addon_checkout_tx` / `pos_quick_checkout_tx`
-- **早就只有 `authenticated`，而 POS 照常運作** —— 那是最硬的證據。
-- 🎯 CLAUDE.md 待辦 20 那句「收了會當場打壞收銀機」停在店員登入之前。
--
-- ### ② 呼叫端查完了，全部是 POS
-- ```
-- 前端    migi-pos/src/lib/api.js  ×5（:155 :441 :145 :482 :767）
--         migi-web 那一處是註解、migi-admin 完全沒有
-- 資料庫  _try_auto_seat_tx ← _finalize_queue_full_tx · sweep_auto_seat_tx
--         open_session_tx   ← pos_seat_queue_tx
--         其餘三支沒有任何函式呼叫
-- ```
--
-- ### ③ 🔴 內部呼叫**也會**檢查 EXECUTE —— 所以這一格非查不可
-- 「它是 DEFINER 所以內部呼叫不用管權限」是**錯的**：權限檢查看的是
-- **呼叫當下的有效身分**。查證結果讓它安全：
-- ```
-- 五支被收的         全部 DEFINER，owner = postgres
-- 兩支呼叫它們的包裝  全部 DEFINER，owner = postgres
-- pg_cron auto-seat-matched   username = postgres
-- ```
-- ⇒ 進到包裝裡面身分就是 `postgres`（owner 永遠有 EXECUTE）⇒ 鏈路不斷。
--
-- ### ⚠ 讀取那 16 支刻意不動
-- 其中 `list_stores_tx` / `list_member_tiers_tx` / `list_product_taxonomy_tx`
-- 那一類**本來就該公開**（會員 App 也在讀）。
-- 🔴 **一起掃掉就是「過度阻擋跟沒擋一樣糟」**（硬規則 3.55）——
--   要逐支看過再決定，那是另一批。
--
-- ⚠ 這份要留下授權變更 ⇒ 驗證段一個字都不准 raise（硬規則 1.8）。
-- ============================================================

-- 🔴 兩個方向都要收（硬規則 2.6b）：
--   舊函式的 anon 可能來自 PUBLIC 繼承，新建的來自 default privileges 明確授權。
--   收錯方向的症狀跟沒收一模一樣。
-- ⚠ 不帶參數列是刻意的：有多載時 Postgres 會直接報錯而不是安靜收錯一支。

revoke execute on function public.open_session_tx          from public;
revoke execute on function public.open_session_tx          from anon;
revoke execute on function public.activate_session_tx      from public;
revoke execute on function public.activate_session_tx      from anon;
revoke execute on function public.set_table_active_tx      from public;
revoke execute on function public.set_table_active_tx      from anon;
revoke execute on function public.set_table_auto_assign_tx from public;
revoke execute on function public.set_table_auto_assign_tx from anon;
revoke execute on function public._try_auto_seat_tx        from public;
revoke execute on function public._try_auto_seat_tx        from anon;


-- ============================================================
-- 驗證
-- ============================================================
do $$
declare
  v_msg text := '';
  v_n   int;
  v_txt text;
  v_fns text[] := array['open_session_tx','activate_session_tx','set_table_active_tx',
                        'set_table_auto_assign_tx','_try_auto_seat_tx'];
begin
  -- ① 五支都沒有多載（有的話上面的 revoke 會報錯，但這一格是那個假設的證據）
  select count(*) into v_n from pg_proc
   where pronamespace='public'::regnamespace and proname = any(v_fns);
  v_msg := case when v_n = 5
    then '✅ ① 五支各一個版本，沒有多載'
    else '🔴 ① 共 ' || v_n || ' 支，表示有多載 —— revoke 可能收錯對象' end;

  -- ② 🔴 三件事要一起印（硬規則 2.6b）：
  --    明確給 anon 了沒 / PUBLIC 有沒有 / authenticated 還在不在
  --    只印其中一個的話，收錯方向與沒收長得一模一樣
  select string_agg(x, E'\n' order by x) into v_txt from (
    select '　　' || p.proname
           || '：anon=' || case when exists (select 1 from aclexplode(p.proacl) a
                  where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE')
                then '🔴有' else '✅沒有' end
           || '　PUBLIC=' || case when exists (select 1 from aclexplode(p.proacl) a
                  where a.grantee=0 and a.privilege_type='EXECUTE')
                then '🔴有' else '✅沒有' end
           || '　authenticated=' || case when exists (select 1 from aclexplode(p.proacl) a
                  where a.grantee='authenticated'::regrole::oid and a.privilege_type='EXECUTE')
                then '✅有' else '🔴沒有' end
           || '　實際上 anon 叫得動嗎='
           || case when has_function_privilege('anon', p.oid, 'execute')
                then '🔴 叫得動' else '✅ 叫不動' end as x
      from pg_proc p
     where p.pronamespace='public'::regnamespace and p.proname = any(v_fns)) s;
  v_msg := v_msg || E'\n' || coalesce(v_txt, '⚪ 這一格取不到（0 列）');
  --   ⚠ `has_function_privilege` 分不出「明確授權」與「PUBLIC 繼承」（硬規則 2.6），
  --     所以它只拿來驗**結果**；上面那兩欄才是「從哪裡來」。

  -- ③ 一句話的總結：五支都要 anon 叫不動、authenticated 叫得動
  select count(*) into v_n from pg_proc p
   where p.pronamespace='public'::regnamespace and p.proname = any(v_fns)
     and not has_function_privilege('anon', p.oid, 'execute')
     and has_function_privilege('authenticated', p.oid, 'execute');
  v_msg := v_msg || E'\n' || case when v_n = 5
    then '✅ ③ 五支都是「anon 叫不動、authenticated 叫得動」'
    else '🔴 ③ 只有 ' || v_n || ' 支符合，應為 5' end;

  -- ④ 🔴 負對照：POS 讀取那 16 支的 anon **不可以被誤收**
  --    只驗「收掉了」的話，把整個 POS 打壞也會全綠（硬規則 3.55）
  select count(*) into v_n from pg_proc p
   where p.pronamespace='public'::regnamespace
     and p.proname in ('list_tables_tx','list_products_tx','list_stores_tx',
                       'list_member_tiers_tx','list_product_taxonomy_tx','list_stake_levels_tx',
                       'list_topup_plans_tx','list_queue_tags_tx','list_fee_menu_tx',
                       'list_daypass_tx','list_match_queues_tx','list_blocks_tx',
                       'list_buddies_tx','get_session_tx')
     and has_function_privilege('anon', p.oid, 'execute');
  v_msg := v_msg || E'\n' || case when v_n = 14
    then '✅ ④ POS 的 14 支讀取函式 anon 全部沒被誤收'
    else '🔴 ④ 只剩 ' || v_n || ' 支讀取函式給 anon（應為 14）—— 收過頭了' end;

  -- ⑤ 🔴 內部呼叫鏈：包裝與 pg_cron 都要是 postgres，否則鏈路會斷
  --    （內部呼叫一樣檢查 EXECUTE，看的是呼叫當下的有效身分）
  select string_agg(p.proname || '=' ||
           case when p.prosecdef and p.proowner::regrole::text='postgres'
                then '✅' else '🔴' end, '　' order by p.proname)
    into v_txt
    from pg_proc p
   where p.pronamespace='public'::regnamespace
     and p.proname in ('pos_seat_queue_tx','_finalize_queue_full_tx','sweep_auto_seat_tx');
  v_msg := v_msg || E'\n' || '　　⑤ 呼叫它們的包裝（DEFINER＋owner=postgres）：'
                 || coalesce(v_txt, '⚪ 取不到');

  select coalesce(string_agg(j.username, '　'), '⚪ 找不到那個排程') into v_txt
    from cron.job j where j.jobname = 'auto-seat-matched';
  v_msg := v_msg || E'\n' || '　　⑤ pg_cron auto-seat-matched 跑在：' || v_txt
                 || '（要是 postgres）';

  -- ⑥ 全庫還有幾支 anon 叫得動 —— 讓「還剩多少」看得見，不要靠記性
  select count(*) into v_n from pg_proc p
   where p.pronamespace='public'::regnamespace and p.prokind='f'
     and has_function_privilege('anon', p.oid, 'execute');
  v_msg := v_msg || E'\n' || '　　⑥ 全庫 anon 叫得動的函式：' || v_n
                 || ' 支（收之前是 98）—— 其餘多數是觸發器、身分函式與會員 App 真的要讀的';

  perform set_config('migi.verify', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify', true), ''), '🔴 沒有驗證訊息') as "驗證";
