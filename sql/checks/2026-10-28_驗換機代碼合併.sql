-- ============================================================
-- 2026-10-28 行為測試：換機代碼合併（sql/pending/2026-10-28_換機代碼合併.sql 跑完之後）
-- 在交易裡造一場店裡的牌局、一台平板（座位 1）、別人一支已配好的手機，最後整段退回、一筆都不留
--   ① 平板「改手機計分」拿到一組碼
--   ② 別人的手機輸入這一組 ⇒ 先預覽（接手誰）
--   ③ 確認 ⇒ 換人：座位 1 換成他、綁到他的手機、平板讓出
--   ④ 平板那一組標成用掉、換機紀錄有一筆
--   ⑤ 亂打一組 ⇒ 代碼不對（原本的錯誤路徑還在）
-- 跑法：Supabase SQL Editor 整份執行，看最後那一格
-- ============================================================
do $$
declare
  v_msg text := '';
  org uuid; st uuid; tb uuid; sk uuid; m uuid[]; m5 uuid; sid uuid; tab uuid; ph uuid;
  t_tab text := repeat('a', 40); t_ph text := repeat('b', 40);
  r jsonb; v_code text; ok boolean;
begin
  select array_agg(id order by created_at), min(org_id::text)::uuid into m, org
    from (select id, org_id, created_at from members where is_test and deleted_at is null and hidden_at is null
           order by created_at limit 4) x;
  select id into m5 from members where deleted_at is null and hidden_at is null and org_id = org and not (id = any(m))
   order by is_test desc, created_at limit 1;
  select t.id, t.store_id into tb, st from tables t join stores s on s.id = t.store_id
   where s.org_id = org and not s.is_virtual and t.is_active and t.deleted_at is null
     and not exists (select 1 from table_sessions x where x.table_id = t.id and x.status = 'open' and x.deleted_at is null)
   order by s.code, t.sort_order limit 1;
  select id into sk from stake_levels where org_id = org and label = '50/20';
  if coalesce(array_length(m, 1), 0) < 4 or m5 is null or tb is null then
    perform set_config('migi.x', '⚪ 測試帳號不夠或找不到空桌，測不了', true); return;
  end if;

  begin
    -- ⓪ 前提：第五個人身上沒有開著的位置；造一場、一台平板坐座位 1、第五個人一支配好的手機
    update session_players sp set left_at = now()
      from table_sessions ts where ts.id = sp.session_id and ts.status = 'open' and sp.member_id = m5 and sp.left_at is null;
    insert into table_sessions (org_id, store_id, table_id, mode, stake_level_id, status, planned_rounds, game_type, flower)
    values (org, st, tb, 'matched', sk, 'open', 2, '台麻', '無花') returning id into sid;
    insert into table_devices (org_id, store_id, table_id, label, token_hash)
    values (org, st, tb, 'TEST-1', public._tbl_hash(t_tab)) returning id into tab;
    insert into table_devices (org_id, kind, member_id, label, token_hash)
    values (org, 'phone', m5, '測試手機', public._tbl_hash(t_ph)) returning id into ph;
    insert into session_players (org_id, session_id, member_id, join_type, status, charged_points, seat, device_id)
    select org, sid, m[i], 'opener', 'playing', 0, i, case when i = 1 then tab end from generate_series(1, 4) i;

    -- ① 平板「改手機計分」
    r := public.tbl_phone_code_tx(t_tab);
    v_code := r ->> 'code';
    v_msg := v_msg || case when (r ->> 'ok')::boolean and v_code ~ '^\d{6}$' then '✅' else '🔴 ' || r::text end || ' ① 平板「改手機計分」拿到一組碼' || E'\n';

    -- ② 別人的手機輸入 ⇒ 預覽
    r := public.tbl_swap_redeem_tx(t_ph, v_code, false);
    v_msg := v_msg || case when (r ->> 'preview')::boolean and (r ->> 'seat')::int = 1 then '✅' else '🔴 ' || r::text end
                   || ' ② 別人的手機輸入平板那一組：先看到要接手座位 1' || E'\n';

    -- ③ 確認 ⇒ 換人
    r := public.tbl_swap_redeem_tx(t_ph, v_code, true);
    ok := (r ->> 'swapped')::boolean
      and (select member_id = m5 and device_id = ph and join_type = 'sub' from session_players where session_id = sid and seat = 1)
      and not exists (select 1 from session_players where session_id = sid and device_id = tab);
    v_msg := v_msg || case when ok then '✅' else '🔴 ' || r::text end || ' ③ 確認：座位 1 換成他、綁他的手機、平板讓出' || E'\n';

    -- ④ 平板那一組用掉、換機紀錄一筆
    ok := (select pc.used_at is not null and pc.used_by_device = ph from table_phone_codes pc
            where pc.code = v_code and pc.session_id = sid order by pc.created_at desc limit 1)
      and (select count(*) from session_seat_swaps where session_id = sid and used_at is not null and to_member_id = m5) = 1;
    v_msg := v_msg || case when coalesce(ok, false) then '✅' else '🔴' end || ' ④ 平板那一組標成用掉、換機紀錄一筆' || E'\n';

    -- ⑤ 亂打一組
    r := public.tbl_swap_redeem_tx(t_ph, '000000', false);
    v_msg := v_msg || case when r ->> 'reason' in ('bad_code', 'too_many') then '✅' else '🔴 ' || r::text end || ' ⑤ 亂打一組：代碼不對';

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm = 'migi_rollback' then
      perform set_config('migi.x', v_msg || E'\n（以上全部退回，資料庫沒有留下任何一筆）', true);
    else
      perform set_config('migi.x', v_msg || E'\n🔴 中途出錯：' || sqlerrm, true);
    end if;
  end;
end $$;
select coalesce(nullif(current_setting('migi.x', true), ''), '🔴 沒有訊息') as "換機代碼合併 · 行為測試";
