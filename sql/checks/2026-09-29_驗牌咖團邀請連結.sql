-- 2026-09-29 驗牌咖團邀請連結（跑在 2026-09-29_牌咖團邀請連結.sql 之後）
-- ⚠ 交易內造一個團，用三位有 LINE 的非店員會員走完整條路，最後 raise 'migi_rollback' 全部退掉。
--   L＝團長、B＝收到連結的朋友、C＝拿到轉貼連結的第三人。身分模擬同 2026-09-29_驗函式身分檢查.sql。

do $$
declare
  v_org uuid; v_ids uuid[]; v_lines text[]; v_team uuid; r jsonb; v_tok text; v_tok2 text; v_n int; v_msg text := '';
  c_l text; c_b text; c_c text;
  ok text := '✅ '; bad text := '🔴 ';
begin
  select array_agg(id order by created_at), array_agg(line_user_id order by created_at), min(org_id::text)::uuid
    into v_ids, v_lines, v_org
    from (select m.id, m.line_user_id, m.org_id, m.created_at from members m
           where m.deleted_at is null and m.hidden_at is null and m.line_user_id is not null
             and not exists (select 1 from staff s where s.member_id = m.id and s.deleted_at is null)
           order by m.created_at limit 3) x;
  if coalesce(array_length(v_ids, 1), 0) < 3 then
    perform set_config('migi.t', '⚪ 要 3 位有 LINE 的非店員會員，這份測不了', false); return;
  end if;
  c_l := json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated', 'app_metadata', json_build_object('line_user_id', v_lines[1]))::text;
  c_b := json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated', 'app_metadata', json_build_object('line_user_id', v_lines[2]))::text;
  c_c := json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated', 'app_metadata', json_build_object('line_user_id', v_lines[3]))::text;

  -- 造一個「需要審核」的團，L 是團長（B、C 都不在團裡）
  insert into teams (org_id, name, join_policy, created_by) values (v_org, '測試邀請連結團', 'approval', v_ids[1]) returning id into v_team;
  insert into team_members (org_id, team_id, member_id, role) values (v_org, v_team, v_ids[1], 'leader');

  -- ① 非團長發連結 ⇒ 擋
  perform set_config('request.jwt.claims', c_b, true);
  r := public.create_team_invite_link_tx(v_team);
  v_msg := v_msg || (case when r->>'reason' = 'not_leader' then ok else bad end) || '① 不是團長發連結被擋：' || coalesce(r->>'reason', r::text) || E'\n';

  -- ② 團長發連結
  perform set_config('request.jwt.claims', c_l, true);
  r := public.create_team_invite_link_tx(v_team);
  v_tok := r->>'token';
  v_msg := v_msg || (case when (r->>'ok')::boolean and length(v_tok) = 32 then ok else bad end) || '② 團長拿到一次性連結（32 字元）' || E'\n';

  -- ③ 團長自己點 ⇒ 已在團裡、不消耗
  r := public.redeem_team_invite_tx(v_tok);
  select count(*) into v_n from team_invite_links where token = v_tok and used_at is null;
  v_msg := v_msg || (case when (r->>'already_member')::boolean and v_n = 1 then ok else bad end) || '③ 團長點自己的連結：已在團裡，連結沒被用掉' || E'\n';

  -- ④ B 點 ⇒ 直接入團（這個團是「需要審核」，連結照樣直接進）
  perform set_config('request.jwt.claims', c_b, true);
  r := public.redeem_team_invite_tx(v_tok);
  select count(*) into v_n from team_members where team_id = v_team and member_id = v_ids[2] and left_at is null;
  v_msg := v_msg || (case when (r->>'joined')::boolean and v_n = 1 then ok else bad end) || '④ 朋友點連結直接入團（不經審核）：' || coalesce(r->>'message', r::text) || E'\n';
  select count(*) into v_n from app_notifications where member_id = v_ids[1] and type = 'team_ok' and created_at > now() - interval '1 minute';
  v_msg := v_msg || (case when v_n >= 1 then ok else bad end) || '④-1 團長收到「某某用邀請連結加入了」的通知' || E'\n';

  -- ⑤ C 拿到轉貼的同一條 ⇒ 已用過
  perform set_config('request.jwt.claims', c_c, true);
  r := public.redeem_team_invite_tx(v_tok);
  v_msg := v_msg || (case when r->>'reason' = 'used' then ok else bad end) || '⑤ 同一條被轉貼給第三人：已用過，進不來' || E'\n';

  -- ⑥ 過期的連結 ⇒ 進不來，而且不消耗
  perform set_config('request.jwt.claims', c_l, true);
  v_tok2 := (public.create_team_invite_link_tx(v_team))->>'token';
  update team_invite_links set expires_at = now() - interval '1 second' where token = v_tok2;
  perform set_config('request.jwt.claims', c_c, true);
  r := public.redeem_team_invite_tx(v_tok2);
  v_msg := v_msg || (case when r->>'reason' = 'expired' then ok else bad end) || '⑥ 過期的連結進不來' || E'\n';

  -- ⑦ 亂打的 token ⇒ 不存在
  r := public.redeem_team_invite_tx('0123456789abcdef0123456789abcdef');
  v_msg := v_msg || (case when r->>'reason' = 'invalid' then ok else bad end) || '⑦ 猜的連結進不來' || E'\n';

  -- ⑧ 沒登入 ⇒ 請先登入
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  r := public.redeem_team_invite_tx(v_tok2);
  v_msg := v_msg || (case when r->>'reason' = 'not_logged_in' then ok else bad end) || '⑧ 沒登入的人點連結：請先登入（前端會先帶去註冊）';

  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.t', v_msg, false);
  else
    perform set_config('migi.t', '🔴 中途失敗：' || sqlerrm || E'\n已經跑完的：\n' || coalesce(v_msg, ''), false);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有訊息') as "驗證";
