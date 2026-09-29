-- 2026-09-29 驗函式身分檢查（跑在 2026-09-29_補上函式的身分檢查.sql 之後）
-- ⚠ 交易內用三種身分實際呼叫：會員 A（非店員）、總部店員、anon；最後 raise 'migi_rollback' 全部退掉。
-- ⚠ 身分是用 request.jwt.claims 模擬的（同 2026-09-09 那份）：
--     會員  {"sub":<隨機>,"role":"authenticated","app_metadata":{"line_user_id":…}}
--     店員  {"sub":<staff.auth_uid>,"role":"authenticated"}
--     anon  {"role":"anon"}   ← 真的 PostgREST anon 也一定帶 claims（anon 金鑰本身是 JWT）
--     排程  claims 是空的     ← pg_cron 沒有 API 身分
-- ⚠ 訊息設在 exception 處理器裡（硬規則 3.9）；找不到樣本會出聲（硬規則 3.57）。

do $$
declare
  v_org uuid; v_store uuid; v_stake uuid; v_a uuid; v_a_line text; v_b uuid; v_c uuid; v_hq text;
  v_q uuid; v_sess uuid; r jsonb; v_n int; v_err text; v_msg text := '';
  c_member text; c_staff text; c_anon text := '{"role":"anon"}';
  ok text := '✅ '; bad text := '🔴 ';
begin
  select m.id, m.line_user_id, m.org_id into v_a, v_a_line, v_org from members m
   where m.deleted_at is null and m.hidden_at is null and m.line_user_id is not null
     and not exists (select 1 from staff s where s.member_id = m.id and s.deleted_at is null)
   order by m.created_at limit 1;
  select id into v_b from members where org_id = v_org and deleted_at is null and hidden_at is null and id <> v_a order by created_at limit 1;
  select id into v_c from members where org_id = v_org and deleted_at is null and hidden_at is null and id not in (v_a, v_b) order by created_at limit 1;
  select s.auth_uid::text into v_hq from staff s where s.deleted_at is null and s.auth_uid is not null and s.role in ('hq','owner') limit 1;
  select id into v_store from stores where org_id = v_org and is_test and deleted_at is null order by code limit 1;
  select id into v_stake from stake_levels where deleted_at is null limit 1;
  if v_a is null or v_b is null or v_c is null or v_hq is null or v_store is null or v_stake is null then
    perform set_config('migi.t', '⚪ 樣本不足（要一位有 LINE 的非店員會員、另外兩位會員、一位總部店員），這份測不了', false); return;
  end if;
  c_member := json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated',
                                'app_metadata', json_build_object('line_user_id', v_a_line))::text;
  c_staff  := json_build_object('sub', v_hq, 'role', 'authenticated')::text;

  -- 前提：會員身分真的解析得出 A、而且不是店員（否則整份驗證沒有意義）
  perform set_config('request.jwt.claims', c_member, true);
  v_msg := v_msg || (case when public.current_member_id() = v_a and not exists (select 1 from public.current_staff()) then ok else bad end)
           || '⓪ 模擬的會員身分解析得出 A，而且不是店員' || E'\n';

  -- ① anon 叫會員功能 ⇒ 28000
  perform set_config('request.jwt.claims', c_anon, true);
  v_err := null;
  begin perform public.list_notifications_tx(v_org, v_b); exception when others then v_err := sqlstate; end;
  v_msg := v_msg || (case when v_err = '28000' then ok else bad end) || '① anon 讀別人的通知被拒：' || coalesce(v_err, '沒有被擋') || E'\n';

  -- ② 會員 A 冒名 B 封鎖 C ⇒ 寫進去的是「A 封鎖 C」
  perform set_config('request.jwt.claims', c_member, true);
  perform public.block_member_tx(v_org, v_b, v_c);
  select count(*) into v_n from member_blocks where blocker_id = v_a and blocked_id = v_c;
  v_msg := v_msg || (case when v_n = 1 then ok else bad end) || '② A 冒名 B 去封鎖，結果記在 A 自己身上' || E'\n';
  select count(*) into v_n from member_blocks where blocker_id = v_b and blocked_id = v_c;
  v_msg := v_msg || (case when v_n = 0 then ok else bad end) || '②-1 負對照：B 沒有被冒名封鎖任何人' || E'\n';

  -- ③ 配桌：B 開房並在房裡；A 冒名 B 退房 ⇒ B 還在房裡
  perform set_config('request.jwt.claims', '', true);
  insert into match_queues (org_id, store_id, stake_level_id, play_at, status, opened_by, game_type, flower)
  values (v_org, v_store, v_stake, now() + interval '3 hours', 'waiting', v_b, '台麻', '無花') returning id into v_q;
  insert into match_queue_players (org_id, queue_id, member_id) values (v_org, v_q, v_b);
  perform set_config('request.jwt.claims', c_member, true);
  v_err := null;
  begin perform public.leave_match_queue_tx(v_org, v_b, v_q, 'test'); exception when others then v_err := sqlerrm; end;
  select count(*) into v_n from match_queue_players where queue_id = v_q and member_id = v_b and left_at is null;
  v_msg := v_msg || (case when v_n = 1 then ok else bad end) || '③ A 冒名讓 B 退房，B 還在房裡' || E'\n';

  -- ④ A 改 B 開的房的開打時間 ⇒ 被擋；店員 ⇒ 可以
  v_err := null;
  begin perform public.update_play_at_tx(v_org, v_q, now() + interval '5 hours'); exception when others then v_err := sqlstate; end;
  v_msg := v_msg || (case when v_err = '42501' then ok else bad end) || '④ A 改別人開的房的時間被擋：' || coalesce(v_err, '沒有被擋') || E'\n';
  perform set_config('request.jwt.claims', c_staff, true);
  v_err := null;
  begin perform public.update_play_at_tx(v_org, v_q, now() + interval '5 hours'); exception when others then v_err := sqlerrm; end;
  v_msg := v_msg || (case when v_err is null then ok else bad end) || '④-1 正對照：店員改得動：' || coalesce(v_err, '成功') || E'\n';

  -- ⑤ 限店員：會員 A 查別人的會員詳情（手機、餘額）⇒ 42501；店員 ⇒ 可以
  perform set_config('request.jwt.claims', c_member, true);
  v_err := null;
  begin perform public.pos_member_detail_tx(v_org, v_b); exception when others then v_err := sqlstate; end;
  v_msg := v_msg || (case when v_err = '42501' then ok else bad end) || '⑤ 會員查別人的會員詳情被擋：' || coalesce(v_err, '沒有被擋') || E'\n';
  perform set_config('request.jwt.claims', c_staff, true);
  v_err := null;
  begin perform public.pos_member_detail_tx(v_org, v_b); exception when others then v_err := sqlerrm; end;
  v_msg := v_msg || (case when v_err is null then ok else bad end) || '⑤-1 正對照：店員查得到：' || coalesce(v_err, '成功') || E'\n';

  -- ⑥ 排程（沒有 API 身分）照常能跑限店員的函式；anon 不行
  perform set_config('request.jwt.claims', '', true);
  v_err := null;
  begin perform public.cleanup_empty_sessions_tx(100000); exception when others then v_err := sqlerrm; end;
  v_msg := v_msg || (case when v_err is null then ok else bad end) || '⑥ 排程身分照常能跑空桌回收：' || coalesce(v_err, '成功') || E'\n';
  perform set_config('request.jwt.claims', c_anon, true);
  v_err := null;
  begin perform public.cleanup_empty_sessions_tx(100000); exception when others then v_err := sqlstate; end;
  v_msg := v_msg || (case when v_err = '42501' then ok else bad end) || '⑥-1 anon 叫空桌回收被擋：' || coalesce(v_err, '沒有被擋') || E'\n';

  -- ⑦ 公開清單沒被誤擋：anon 看配桌房間清單照常
  v_err := null;
  begin perform public.list_match_queues_tx(v_org, v_b, v_store); exception when others then v_err := sqlerrm; end;
  v_msg := v_msg || (case when v_err is null then ok else bad end) || '⑦ 正對照：anon 看配桌清單照常：' || coalesce(v_err, '成功') || E'\n';

  -- ⑧ 店員代客人查牌咖（POS 在用）照常；會員冒名查別人 ⇒ 回自己的
  perform set_config('request.jwt.claims', c_staff, true);
  v_err := null;
  begin perform public.list_buddies_tx(v_org, v_b); exception when others then v_err := sqlerrm; end;
  v_msg := v_msg || (case when v_err is null then ok else bad end) || '⑧ 正對照：店員代客人查牌咖照常：' || coalesce(v_err, '成功') || E'\n';
  perform set_config('request.jwt.claims', c_member, true);
  v_msg := v_msg || (case when public.list_buddies_tx(v_org, v_b) is not distinct from public.list_buddies_tx(v_org, v_a) then ok else bad end)
           || '⑧-1 會員冒名查別人的牌咖，拿到的是自己的';

  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.t', v_msg, false);
  else
    perform set_config('migi.t', '🔴 中途失敗：' || sqlerrm || E'\n已經跑完的：\n' || coalesce(v_msg, ''), false);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有訊息') as "驗證";
