/* ============================================================
   補回前端 RPC 的 EXECUTE 權限
   2026-08-25 · 線上正在壞：permission denied for function topup_tx

   ✅ 已執行並驗證通過（2026-08-25）
      ① 這次補了 **1 支：topup_tx**
      ② 補完沒有其他缺權限的
      ③ 前端呼叫的 70 支 RPC **全部存在**（沒有 404 那種壞法）
      ④ **全部都是 SECURITY DEFINER**（沒有 INVOKER + anon 那個靜默失敗的組合）

   ── 病因（我第一次的判斷是錯的，這是更正後的）─────────
   ❌ 我先以為是「DROP FUNCTION 把 GRANT 帶走」。
      查證後推翻：2026-08-24 那支用的是 **CREATE OR REPLACE，沒有 DROP**，
      而 CREATE OR REPLACE **保留**既有權限。

   ✅ 真正的原因：**topup_tx 從來就沒有 anon EXECUTE，因為在 8/24 之前
      沒有任何前端直接呼叫它。**
      它一直只被 pos_checkout_with_topup_tx 這類 SECURITY DEFINER 的包裝
      **從內部**呼叫 —— 而在 DEFINER 函式裡面，呼叫端的權限根本不會被檢查。
      （CLAUDE.md 2026-08-15 就記過「POS 全專案沒有任何儲值 RPC 呼叫」。）

   🔴 **所以櫃檯儲值從上線那天起就沒有成功過一次**，
      不是「壞掉」而是「從來沒通」。第一次有人按下去就是 8/25。

   ── 真正的教訓 ───────────────────────────────────────
   **「函式在包裝裡跑得動」不代表「前端叫得動」。**
   權限是在**呼叫點**檢查的。一支長期只當內部被呼叫者的函式，
   可能整支從來沒有授權給 anon，而且不會有任何跡象 ——
   直到某天前端第一次直接叫它。

   → **讓前端第一次直接呼叫某支既有 RPC 時，必須確認它有 anon EXECUTE。**
     這跟「改簽名要 DROP」是兩件不同的事，兩條都要檢查。

   ── 這支做什麼 ───────────────────────────────────────
   名單來自**三個前端實際呼叫的 RPC**（grep api.js / rpc() / rpcRead()）。
   會被前端呼叫，就代表它本來就該讓 anon 執行。

   ⚠ **只補缺的，不重複授權**：DO 區塊先問 has_function_privilege，
     缺了才 GRANT，並把改過的名字記下來讓驗證段印出來。
     全部重新 GRANT 一遍也能動，但那樣就看不出「原來壞了幾支」——
     而那個數字才是我們要知道的。

   ⚠ 用 pg_get_function_identity_arguments 組簽名，所以**多載版本各自處理**，
     不會漏掉其中一個。
   ============================================================ */

do $$
declare
  r        record;
  v_fixed  text[] := '{}';
  v_names  text[] := array[
    -- ── migi-pos（api.js）──
    'activate_session_tx','calc_session_fee_tx','check_session_blocks_tx',
    'get_session_member_orders_tx','get_session_tx','has_daypass_tx',
    'join_session_tx','list_daypass_tx','list_fee_menu_tx','list_match_queues_tx',
    'list_products_tx','list_queue_tags_tx','list_stake_levels_tx','list_stores_tx',
    'list_tables_tx','list_topup_plans_tx','open_session_tx',
    'pos_add_queue_member_tx','pos_addon_checkout_tx','pos_checkout_with_topup_tx',
    'pos_close_queue_tx','pos_create_queue_tx','pos_create_recurring_tx',
    'pos_list_queues_tx','pos_list_recurring_tx','pos_member_detail_tx',
    'pos_queue_members_tx','pos_quick_checkout_tx','pos_search_members_tx',
    'pos_seat_queue_tx','pos_set_recurring_enabled_tx','pos_table_forecast_tx',
    'set_table_active_tx','set_table_auto_assign_tx','settle_session_tx',
    'topup_tx','void_session_tx',
    -- ── migi-web / migi-admin ──
    'dev_clear_my_queues_tx','get_my_active_queue_tx','get_my_availability_tx',
    'get_my_games_tx','get_my_orders_tx','get_my_profile_tx','get_wallet_tx',
    'like_player_tx','list_blocks_tx','list_buddies_tx',
    'list_match_queues_by_city_tx','list_members_tx','list_notifications_tx',
    'list_product_taxonomy_tx','list_recent_players_tx','list_stakes_tx',
    'log_app_event_tx','mark_app_active_tx','mark_notifs_read_tx',
    'register_member_tx','save_app_state_tx','set_avatar_tx','set_my_about_tx',
    'set_my_availability_tx','set_my_avatar_tx','set_my_baby_tile_tx',
    'set_my_home_store_tx','set_my_nickname_tx','set_my_sched_tx',
    'set_my_see_score_tx','set_my_style_tx','set_my_title_tx','unread_count_tx'
  ];
begin
  for r in
    select p.oid,
           p.proname,
           'public.' || quote_ident(p.proname) ||
             '(' || pg_get_function_identity_arguments(p.oid) || ')' as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = any (v_names)
       and not has_function_privilege('anon', p.oid, 'EXECUTE')
  loop
    execute 'grant execute on function ' || r.sig || ' to anon, authenticated';
    v_fixed := v_fixed || r.proname;
  end loop;

  perform set_config('migi.fixed',
    case when array_length(v_fixed, 1) is null
         then '（沒有任何一支缺權限）'
         else array_length(v_fixed, 1)::text || ' 支：' || array_to_string(v_fixed, '、')
    end, true);
end $$;


/* ============================================================
   驗證段（單一 SELECT）
   ① 這次補了哪幾支 —— 那個數字就是「原來壞了幾支」
   ② 全部名單的現況：有沒有權限、DEFINER 還是 INVOKER、存不存在
   ============================================================ */

with names(nm) as (
  select unnest(array[
    'activate_session_tx','calc_session_fee_tx','check_session_blocks_tx',
    'get_session_member_orders_tx','get_session_tx','has_daypass_tx',
    'join_session_tx','list_daypass_tx','list_fee_menu_tx','list_match_queues_tx',
    'list_products_tx','list_queue_tags_tx','list_stake_levels_tx','list_stores_tx',
    'list_tables_tx','list_topup_plans_tx','open_session_tx',
    'pos_add_queue_member_tx','pos_addon_checkout_tx','pos_checkout_with_topup_tx',
    'pos_close_queue_tx','pos_create_queue_tx','pos_create_recurring_tx',
    'pos_list_queues_tx','pos_list_recurring_tx','pos_member_detail_tx',
    'pos_queue_members_tx','pos_quick_checkout_tx','pos_search_members_tx',
    'pos_seat_queue_tx','pos_set_recurring_enabled_tx','pos_table_forecast_tx',
    'set_table_active_tx','set_table_auto_assign_tx','settle_session_tx',
    'topup_tx','void_session_tx',
    'dev_clear_my_queues_tx','get_my_active_queue_tx','get_my_availability_tx',
    'get_my_games_tx','get_my_orders_tx','get_my_profile_tx','get_wallet_tx',
    'like_player_tx','list_blocks_tx','list_buddies_tx',
    'list_match_queues_by_city_tx','list_members_tx','list_notifications_tx',
    'list_product_taxonomy_tx','list_recent_players_tx','list_stakes_tx',
    'log_app_event_tx','mark_app_active_tx','mark_notifs_read_tx',
    'register_member_tx','save_app_state_tx','set_avatar_tx','set_my_about_tx',
    'set_my_availability_tx','set_my_avatar_tx','set_my_baby_tile_tx',
    'set_my_home_store_tx','set_my_nickname_tx','set_my_sched_tx',
    'set_my_see_score_tx','set_my_style_tx','set_my_title_tx','unread_count_tx'
  ])
),
fns as (
  select n.nm,
         p.oid,
         p.prosecdef
    from names n
    left join pg_proc p
      on p.proname = n.nm
     and p.pronamespace = 'public'::regnamespace
)
select 序, 項目, 內容 from (

  select 0 as 序, '① 這次補了' as 項目,
         coalesce(current_setting('migi.fixed', true), '🔴 DO 區塊沒執行') as 內容

  union all
  select 1, '② 仍然沒有 anon 權限',
         coalesce((select string_agg(nm, '、' order by nm) from fns
                    where oid is not null
                      and not has_function_privilege('anon', oid, 'EXECUTE')),
                  '✅ 沒有了')

  union all
  /* 前端呼叫得到、但函式根本不存在 —— 那是另一種壞法（呼叫會 404）。
     順便查出來，不然永遠不會有人發現。 */
  select 2, '③ 前端在叫但函式不存在',
         coalesce((select string_agg(nm, '、' order by nm) from fns where oid is null),
                  '✅ 全部都在')

  union all
  /* 🔴 INVOKER + anon = 「什麼都沒發生而且不報錯」的組合（硬規則 4）。
     有權限執行不代表做得了事 —— RLS 會把它濾成空的。
     這一列不是這次要修的，但它是下一個要看的地方。 */
  select 3, '④ 是 INVOKER（anon 呼叫會被 RLS 濾成空的）',
         coalesce((select string_agg(nm, '、' order by nm) from fns
                    where oid is not null and not prosecdef),
                  '✅ 全部都是 DEFINER')

  union all
  select 4, '⑤ 總計',
         (select count(*) filter (where oid is not null)::text || ' 支存在　'
               || count(*) filter (where oid is null)::text || ' 支不存在'
            from fns)

) x order by 序, 項目;
