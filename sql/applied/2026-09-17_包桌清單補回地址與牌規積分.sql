/* ═══════════════════════════════════════════════════════════════════
   「接下來的包桌」點「查看」要開抽屜 —— 清單補回抽屜要印的四個值
   2026-09-17 · 使用者指定
   ═══════════════════════════════════════════════════════════════════

   使用者：右邊的「取消」改成「查看」，點了開抽屜顯示預約包桌資訊，
   取消按鈕搬到抽屜下面。

   抽屜印的是**與預約成功卡同一組九列**（牌咖團／類型／開打時間／門市／
   地址／玩法／積分／桌號／桌數）—— 同一筆預約在兩個畫面講一樣的話。
   而 `list_my_bookings_tx` **少了其中四個**：
     store_address   地址（抽屜那一列要能點去導航）
     game_type       牌規
     flower          花牌
     stake_label     積分
   📌 後三個是 2026-09-16 加進 `bookings` 的欄位 —— 寫入端當天就做了，
     **讀出來的這一支沒跟上**（手抄的東西只會抄當下需要的）。

   ✅ 只多回四個鍵，簽名不變 ⇒ CREATE OR REPLACE、不丟 GRANT。
   ⚠ 前端讀不到時一律顯示「—」⇒ 前端可以先上，這份晚跑也不會壞。
   ⚠ 這份要留下 DDL ⇒ 驗證段不 raise（硬規則 1.8）。
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.list_my_bookings_tx()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_me   uuid := public.current_member_id();
  v_rows jsonb;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  perform public._booking_expire(null);

  /* ⚠ 過去的只留 30 天 —— 再久的預約紀錄客人不會看，
     而一個越來越長的清單會把「下一筆什麼時候」埋掉。 */
  select coalesce(jsonb_agg(x order by x->>'play_at'), '[]'::jsonb)
    into v_rows
    from (
      select jsonb_build_object(
               'booking_id',    k.id,
               'store_id',      k.store_id,
               'store_name',    s.name,
               /* 🆕 2026-09-17：抽屜的「地址」那一列（可點去導航）。 */
               'store_address', s.address,
               'team_id',       k.team_id,
               'team_name',     t.name,
               'play_at',       k.play_at,
               'hours',         k.planned_hours,
               'table_count',   k.table_count,
               'party_size',    k.party_size,
               'note',          k.note,
               'status',        k.status,
               'table_label',   tb.label,
               /* 🆕 2026-09-17：預約時就決定的牌規與積分（09-16 寫入端就有，讀出來這裡沒跟上）。 */
               'game_type',     k.game_type,
               'flower',        k.flower,
               'stake_label',   sl.label,
               'mine',          k.member_id = v_me) as x
        from public.bookings k
        join public.stores s on s.id = k.store_id
        left join public.teams  t  on t.id  = k.team_id
        left join public.tables tb on tb.id = k.table_id
        left join public.stake_levels sl on sl.id = k.stake_level_id
       where (k.member_id = v_me
              or (k.team_id is not null and exists (
                    select 1 from public.team_members tm
                     where tm.team_id = k.team_id and tm.member_id = v_me and tm.left_at is null)))
         and k.play_at > now() - interval '30 days'
    ) q;

  return jsonb_build_object('ok', true, 'bookings', v_rows);
end $function$;


/* ═══ 驗證段（不 raise）═══ */
do $$
declare
  v_msg text := '';
  v_def text;
  v_n   int;
  v_ok  boolean;
begin
  select count(*) into v_n from pg_proc
   where pronamespace = 'public'::regnamespace and proname = 'list_my_bookings_tx';
  v_def := pg_get_functiondef('public.list_my_bookings_tx()'::regprocedure);
  v_msg := case when v_n = 1 and v_def ilike '%security definer%'
    then '✅ ① 版本數 1 · DEFINER' else '🔴 ① 版本數 ' || v_n || ' 或不是 DEFINER' end;

  /* ② 四個新鍵都在（掃的是 jsonb 鍵名的字面，連單引號一起比，避免被註解誤觸發） */
  v_msg := v_msg || E'\n' || case
    when v_def ilike '%''store_address''%' and v_def ilike '%''game_type''%'
     and v_def ilike '%''flower''%' and v_def ilike '%''stake_label''%'
    then '✅ ② 多回 store_address · game_type · flower · stake_label'
    else '🔴 ② 有鍵沒加到' end;

  /* ③ 舊的鍵一個都沒少（抽掉任何一個，POS 與會員 App 的清單會靜靜少一格） */
  v_msg := v_msg || E'\n' || case
    when v_def ilike '%''booking_id''%' and v_def ilike '%''table_label''%'
     and v_def ilike '%''team_name''%' and v_def ilike '%''mine''%' and v_def ilike '%''status''%'
    then '✅ ③ 原本的鍵都還在'
    else '🔴 ③ 原本的鍵少了' end;

  /* ④ 授權沒掉 */
  select has_function_privilege('authenticated', 'public.list_my_bookings_tx()', 'execute') into v_ok;
  v_msg := v_msg || E'\n' || case when v_ok
    then '✅ ④ authenticated 仍然叫得動' else '🔴 ④ 授權掉了' end;

  /* ⑤ 正對照：線上有幾筆預約帶了積分 —— 0 筆時新鍵回 null 是正常的，不是壞掉 */
  select count(*) into v_n from public.bookings where stake_level_id is not null;
  v_msg := v_msg || E'\n📌 ⑤ 目前帶積分的預約 ' || v_n || ' 筆（0 筆時抽屜的積分那一列會是「—」，那是資料不是 bug）';

  perform set_config('migi.verify_bookings_list', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify_bookings_list', true), ''), '🔴 沒有驗證訊息') as "驗證";
