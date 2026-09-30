/* ============================================================
   行為測試：起始積分後台 ＋ 牌局紀錄的追加積分（交易內，**全部回滾**）
   2026-09-30 · 配 sql/pending/2026-09-30_起始積分後台與追加積分紀錄.sql（先跑那份）

   ⓐ 後台兩支：用總部的真身分叫（JWT sub ＝ 總部 Email 帳號）
      列表 → 改值 → 記下是誰改的 → 範圍外被擋 → 找不到被擋；
      負對照：登入但不是店員 ⇒ 被拒；anon ⇒ 根本叫不動
   ⓑ bust_log：A1 那一場造 4 台平板（同 2026-09-30_驗爆卡與追加積分.sql）
      還在等決定時 bust_log 是空的 → 追加 500 之後有一列 → 那一列的將／風圈／局號對得上造成爆卡的那一局
   ⓒ bust_log：不追加 ⇒ 那一列是 ended

   ⚠ 故意 raise 回滾（硬規則 1.8 的例外），訊息設在 exception handler 裡（硬規則 3.9）
   ============================================================ */

create or replace function pg_temp.migi_setup() returns void language plpgsql as $$
declare v_sid uuid := '1ea984c6-e15e-4888-a4d6-9f99f0860120'; v_org uuid; v_store uuid; v_table uuid; g int; v_dev uuid;
begin
  select org_id, store_id, table_id into v_org, v_store, v_table from public.table_sessions where id = v_sid and status = 'open';
  if v_org is null then raise exception '🔴 A1 那一場已經不是進行中（可能已經收桌），這份測不了'; end if;
  update public.stake_levels set start_points = 300
   where id = (select stake_level_id from public.table_sessions where id = v_sid);
  for g in 1 .. 4 loop
    insert into public.table_devices (org_id, store_id, table_id, label, token_hash)
    values (v_org, v_store, v_table, '測試平板' || g, public._tbl_hash('migi-bustlog-test-seat-' || g || '-0123456789abcdef'))
    returning id into v_dev;
    update public.session_players set device_id = v_dev where session_id = v_sid and seat = g;
  end loop;
end $$;
create or replace function pg_temp.tok(g int) returns text language sql as $$ select 'migi-bustlog-test-seat-' || g || '-0123456789abcdef' $$;

-- ⓐ 後台兩支
do $$
declare v_sid uuid := '1ea984c6-e15e-4888-a4d6-9f99f0860120'; v_msg text := ''; v_ok int := 0; v_all int := 0;
  v_uid uuid; v_staff uuid; v_stake uuid; r jsonb; v_row jsonb; v_cnt int; v_pts int; v_by uuid;
begin
  select auth_uid, id into v_uid, v_staff from public.staff where role = 'hq' and auth_uid is not null order by id limit 1;
  if v_uid is null then raise exception '🔴 找不到總部 Email 帳號，這一段測不了'; end if;
  select stake_level_id into v_stake from public.table_sessions where id = v_sid;

  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- ① 列表：筆數對得上、A1 用的那個級距「正在打」至少 1 桌
  r := public.admin_list_stake_levels_tx();
  select count(*) into v_cnt from public.stake_levels where org_id = (select org_id from public.table_sessions where id = v_sid) and deleted_at is null;
  select x into v_row from jsonb_array_elements(r -> 'rows') x where x ->> 'id' = v_stake::text;
  v_all := v_all + 1;
  if (r ->> 'ok')::boolean and jsonb_array_length(r -> 'rows') = v_cnt and (v_row ->> 'open_tables')::int >= 1
    then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ① 總部列表：' || coalesce(jsonb_array_length(r -> 'rows'), -1) || ' 列（期望 ' || v_cnt || '）、A1 的級距正在打 '
        || coalesce(v_row ->> 'open_tables', '∅') || ' 桌' || E'\n';

  -- ② 改成 1234 ⇒ 成功、值寫進去、記下的是總部那一列
  r := public.admin_set_stake_start_points_tx(v_stake, 1234);
  reset role;
  select start_points, updated_by into v_pts, v_by from public.stake_levels where id = v_stake;
  set local role authenticated;
  v_all := v_all + 1;
  if (r ->> 'ok')::boolean and v_pts = 1234 and v_by = v_staff and (r ->> 'open_tables')::int >= 1
    then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ② 改成 1234 → ' || r::text || '；資料庫 ' || coalesce(v_pts::text, '∅')
        || '、記在 ' || case when v_by = v_staff then '總部那一列' else coalesce(v_by::text, 'null') end || E'\n';

  -- ③ 範圍外
  v_all := v_all + 1;
  if public.admin_set_stake_start_points_tx(v_stake, 0) ->> 'reason' = 'bad_points'
     and public.admin_set_stake_start_points_tx(v_stake, 10000000) ->> 'reason' = 'bad_points'
    then v_ok := v_ok + 1; v_msg := v_msg || '✅ ③ 0 與 10,000,000 都被擋（bad_points）' || E'\n';
    else v_msg := v_msg || '🔴 ③ 範圍外沒被擋' || E'\n'; end if;

  -- ④ 找不到
  r := public.admin_set_stake_start_points_tx(gen_random_uuid(), 500);
  v_all := v_all + 1;
  if r ->> 'reason' = 'not_found' then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ④ 不存在的級距 → ' || coalesce(r ->> 'reason', r::text) || E'\n';

  -- ⑤ 登入但不是店員 ⇒ 兩支都被拒
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  v_all := v_all + 1;
  if public.admin_list_stake_levels_tx() ->> 'reason' = 'forbidden'
     and public.admin_set_stake_start_points_tx(v_stake, 777) ->> 'reason' = 'forbidden'
    then v_ok := v_ok + 1; v_msg := v_msg || '✅ ⑤ 不是店員：兩支都回 forbidden' || E'\n';
    else v_msg := v_msg || '🔴 ⑤ 不是店員竟然沒被拒' || E'\n'; end if;
  reset role;

  -- ⑥ anon 根本叫不動
  set local role anon;
  v_all := v_all + 1;
  begin
    r := public.admin_set_stake_start_points_tx(v_stake, 777);
    v_msg := v_msg || '🔴 ⑥ anon 叫得動：' || r::text || E'\n';
  exception when insufficient_privilege then
    v_ok := v_ok + 1; v_msg := v_msg || '✅ ⑥ anon 叫不動（permission denied）' || E'\n';
  end;
  reset role;

  v_msg := 'ⓐ 後台：通過 ' || v_ok || ' / ' || v_all || E'\n' || v_msg;
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then perform set_config('migi.a', v_msg, true);
  else perform set_config('migi.a', v_msg || '🔴 中途出錯：' || sqlstate || ' ' || sqlerrm, true); end if;
end $$;

-- ⓑ 追加 ⇒ bust_log 一列
do $$
declare v_sid uuid := '1ea984c6-e15e-4888-a4d6-9f99f0860120'; r jsonb; st jsonb; e jsonb; v_hand uuid; v_msg text := ''; v_ok int := 0; v_all int := 0;
  v_round int; v_wind int; v_no int; v_log0 int;
begin
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.migi_setup();
  v_log0 := jsonb_array_length(public.tbl_state_tx(pg_temp.tok(1)) -> 'log');

  r := public.tbl_submit_hand_tx(pg_temp.tok(1), 'ron', 2::smallint, '[{"code":"hunyise","n":1}]'::jsonb);
  v_hand := (r ->> 'hand_id')::uuid;
  r := public.tbl_confirm_hand_tx(pg_temp.tok(2), v_hand, true);
  select sr.round_no, h.wind, h.hand_no into v_round, v_wind, v_no
    from public.hands h join public.session_rounds sr on sr.id = h.round_id where h.id = v_hand;

  -- ① 還在等他決定 ⇒ bust_log 是空的（等待中畫面上另有提示）
  st := public.tbl_state_tx(pg_temp.tok(3));
  v_all := v_all + 1;
  if st -> 'bust' <> 'null'::jsonb and jsonb_array_length(st -> 'bust_log') = 0
    then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ① 等待決定中：bust_log ' || coalesce(jsonb_array_length(st -> 'bust_log'), -1) || ' 列（期望 0）' || E'\n';

  -- ② 追加 500 ⇒ 一列 added
  r := public.tbl_bust_decide_tx(pg_temp.tok(2), 500);
  st := public.tbl_state_tx(pg_temp.tok(4));
  e := st -> 'bust_log' -> 0;
  v_all := v_all + 1;
  if jsonb_array_length(st -> 'bust_log') = 1 and e ->> 'decision' = 'added' and (e ->> 'added_points')::int = 500
     and (e ->> 'seat')::int = 2 and e ->> 'at' is not null
    then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ② 追加 500 之後：' || coalesce(e::text, '∅') || E'\n';

  -- ③ 將／風圈／局號 ＝ 造成爆卡的那一局（紀錄頁的篩選靠它）
  v_all := v_all + 1;
  if (e ->> 'round_no')::int = v_round and (e ->> 'wind')::int = v_wind and (e ->> 'hand_no')::int = v_no
    then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ③ 第 ' || coalesce(e ->> 'round_no', '∅') || ' 將・風 ' || coalesce(e ->> 'wind', '∅') || '・第 ' || coalesce(e ->> 'hand_no', '∅')
        || ' 局（期望 ' || v_round || '・' || v_wind || '・' || v_no || '）' || E'\n';

  -- ④ 原本的 log 沒被混進東西：只多了那一局
  v_all := v_all + 1;
  if jsonb_array_length(st -> 'log') = v_log0 + 1 and not exists (select 1 from jsonb_array_elements(st -> 'log') x where x ? 'decision')
    then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ④ log ' || v_log0 || ' → ' || jsonb_array_length(st -> 'log') || ' 列（只多那一局，沒有混進追加）' || E'\n';

  v_msg := 'ⓑ 追加紀錄：通過 ' || v_ok || ' / ' || v_all || E'\n' || v_msg;
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then perform set_config('migi.b', v_msg, true);
  else perform set_config('migi.b', v_msg || '🔴 中途出錯：' || sqlstate || ' ' || sqlerrm, true); end if;
end $$;

-- ⓒ 不追加 ⇒ bust_log 一列 ended
do $$
declare r jsonb; st jsonb; e jsonb; v_hand uuid; v_msg text := ''; v_ok int := 0; v_all int := 0;
begin
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.migi_setup();
  r := public.tbl_submit_hand_tx(pg_temp.tok(1), 'ron', 2::smallint, '[{"code":"hunyise","n":1}]'::jsonb);
  v_hand := (r ->> 'hand_id')::uuid;
  r := public.tbl_confirm_hand_tx(pg_temp.tok(2), v_hand, true);
  r := public.tbl_bust_decide_tx(pg_temp.tok(2), 0);
  st := public.tbl_state_tx(pg_temp.tok(1));
  e := st -> 'bust_log' -> 0;
  v_all := v_all + 1;
  if jsonb_array_length(st -> 'bust_log') = 1 and e ->> 'decision' = 'ended' and (e ->> 'seat')::int = 2
    then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' 不追加 → ' || coalesce(e::text, '∅') || E'\n';

  v_msg := 'ⓒ 不追加紀錄：通過 ' || v_ok || ' / ' || v_all || E'\n' || v_msg;
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then perform set_config('migi.c', v_msg, true);
  else perform set_config('migi.c', v_msg || '🔴 中途出錯：' || sqlstate || ' ' || sqlerrm, true); end if;
end $$;

select coalesce(nullif(current_setting('migi.a', true), ''), '🔴 ⓐ 沒有訊息') || E'\n'
    || coalesce(nullif(current_setting('migi.b', true), ''), '🔴 ⓑ 沒有訊息') || E'\n'
    || coalesce(nullif(current_setting('migi.c', true), ''), '🔴 ⓒ 沒有訊息') as "行為測試";
