-- 2026-11-18 同桌文字評價：行為測試（交易內造樣本，跑完整筆回滾，什麼都不留）
-- ⚠ 要在 Dashboard 跑（要切換成會員身分；唯讀 MCP 沒有權限切換角色）
-- ⚠ 先跑 sql/pending/2026-11-18_同桌文字評價.sql
--
-- 借一場「兩位測試帳號都坐過、而且都有 LINE id」的牌局當樣本；讚與倒讚在交易裡直接寫，不呼叫 like_player_tx（避免發餅乾）

do $$
declare
  v_s    uuid;   -- 牌局
  v_a    uuid;   -- 寫的人
  v_b    uuid;   -- 被評的人
  v_c    uuid;   -- 沒坐那一場的測試帳號
  v_la   text;
  v_lb   text;
  v_org  uuid;
  v_r    jsonb;
  v_rid  uuid;
  v_msg  text := '';
  v_n    int;
begin
  select sp1.session_id, sp1.member_id, sp2.member_id, m1.line_user_id, m2.line_user_id, ts.org_id
    into v_s, v_a, v_b, v_la, v_lb, v_org
    from session_players sp1
    join session_players sp2 on sp2.session_id = sp1.session_id and sp2.member_id <> sp1.member_id
    join members m1 on m1.id = sp1.member_id
    join members m2 on m2.id = sp2.member_id
    join table_sessions ts on ts.id = sp1.session_id
   where m1.is_test and m2.is_test and m1.line_user_id is not null and m2.line_user_id is not null
     and m1.hidden_at is null and m2.hidden_at is null and ts.mode <> 'friendly'
   order by ts.created_at desc limit 1;
  if v_s is null then raise exception '找不到樣本：沒有兩位測試帳號同桌過的牌局'; end if;
  select m.id into v_c from members m
   where m.is_test and m.line_user_id is not null and m.id not in (v_a, v_b)
     and not exists (select 1 from session_players where session_id = v_s and member_id = m.id)
   limit 1;

  -- 清掉這一場 A→B 原本的讚、倒讚、留言（交易內，最後回滾）
  delete from member_likes    where liker_id = v_a and target_id = v_b and session_id = v_s;
  delete from member_dislikes where rater_id = v_a and target_id = v_b and session_id = v_s;
  delete from member_reviews  where rater_id = v_a and target_id = v_b and session_id = v_s;

  -- 以 A 的身分
  perform set_config('request.jwt.claims', json_build_object('sub', v_la, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- ⓐ 沒按讚也沒倒讚 ⇒ 不能留
  v_r := public.set_review_tx(v_b, v_s, '下次再約');
  v_msg := v_msg || case when v_r->>'reason' = 'no_vote' then '✅' else '🔴' end || ' ⓐ 沒按讚不能留言：' || coalesce(v_r::text, 'null') || E'\n';

  -- ⓑ 按讚之後留 ⇒ 好評
  reset role;
  insert into member_likes (org_id, liker_id, target_id, session_id) values (v_org, v_a, v_b, v_s);
  set local role authenticated;
  v_r := public.set_review_tx(v_b, v_s, '  下次再約！  自摸那把超帥 ');
  v_msg := v_msg || case when (v_r->>'ok')::boolean and (v_r->>'good')::boolean then '✅' else '🔴' end || ' ⓑ 按讚後留言＝好評：' || coalesce(v_r::text, 'null') || E'\n';

  -- ⓒ 禁字擋下（電話）、ⓓ 太長擋下
  v_r := public.set_review_tx(v_b, v_s, '加我 0912-345-678');
  v_msg := v_msg || case when v_r->>'reason' = 'blocked_word' then '✅' else '🔴' end || ' ⓒ 電話被擋：' || coalesce(v_r->>'message', 'null') || E'\n';
  v_r := public.set_review_tx(v_b, v_s, repeat('好', 31));
  v_msg := v_msg || case when v_r->>'reason' = 'too_long' then '✅' else '🔴' end || ' ⓓ 31 個字被擋：' || coalesce(v_r->>'reason', 'null') || E'\n';

  -- ⓔ 讀得到、而且不回傳是誰寫的；空白有收乾淨
  v_r := public.list_member_reviews_tx(v_b, 'all', null, 30);
  v_msg := v_msg || case when (v_r->>'good')::int >= 1
                          and exists (select 1 from jsonb_array_elements(v_r->'items') e where e->>'body' = '下次再約！ 自摸那把超帥')
                          and not exists (select 1 from jsonb_array_elements(v_r->'items') e where e ? 'rater_id' or e ? 'store')
                     then '✅' else '🔴' end || ' ⓔ 列得出來、沒有寫的人與門市：好評 ' || coalesce(v_r->>'good', 'null') || E'\n';

  -- ⓕ 讚換成倒讚 ⇒ 好評那則跟著消失；再留 ⇒ 負評
  reset role;
  delete from member_likes where liker_id = v_a and target_id = v_b and session_id = v_s;
  select count(*) into v_n from member_reviews where rater_id = v_a and target_id = v_b and session_id = v_s;
  insert into member_dislikes (org_id, rater_id, target_id, session_id) values (v_org, v_a, v_b, v_s);
  set local role authenticated;
  v_r := public.set_review_tx(v_b, v_s, '牌品有待加強');
  v_msg := v_msg || case when v_n = 0 and (v_r->>'ok')::boolean and not (v_r->>'good')::boolean then '✅' else '🔴' end
                 || ' ⓕ 收回讚留言跟著刪（剩 ' || v_n || ' 則），倒讚後留言＝負評' || E'\n';

  -- ⓖ 檢舉：A 不是被評的人 ⇒ 不行；換成 B ⇒ 可以
  reset role;
  select id into v_rid from member_reviews where rater_id = v_a and target_id = v_b and session_id = v_s;
  set local role authenticated;
  v_r := public.report_review_tx(v_rid);
  v_msg := v_msg || case when v_r->>'reason' = 'not_found' then '✅' else '🔴' end || ' ⓖ 寫的人不能檢舉：' || coalesce(v_r->>'reason', 'null') || E'\n';
  perform set_config('request.jwt.claims', json_build_object('sub', v_lb, 'role', 'authenticated')::text, true);
  v_r := public.report_review_tx(v_rid);
  v_msg := v_msg || case when (v_r->>'ok')::boolean then '✅' else '🔴' end || ' ⓖ 被評的人可以檢舉' || E'\n';
  v_r := public.list_member_reviews_tx(v_b, 'bad', null, 30);
  v_msg := v_msg || case when (v_r->>'mine')::boolean
                          and exists (select 1 from jsonb_array_elements(v_r->'items') e where (e->>'reported')::boolean)
                     then '✅' else '🔴' end || ' ⓖ 本人看得到自己檢舉過' || E'\n';

  -- ⓗ 沒坐那一場的人不能被評
  perform set_config('request.jwt.claims', json_build_object('sub', v_la, 'role', 'authenticated')::text, true);
  if v_c is not null then
    v_r := public.set_review_tx(v_c, v_s, '下次再約');
    v_msg := v_msg || case when v_r->>'reason' = 'not_tablemates' then '✅' else '🔴' end || ' ⓗ 沒同桌不能評：' || coalesce(v_r->>'reason', 'null') || E'\n';
  else
    v_msg := v_msg || '⚪ ⓗ 這一格測不了（找不到沒坐那一場的測試帳號）' || E'\n';
  end if;

  -- ⓘ 清空 ⇒ 刪掉
  v_r := public.set_review_tx(v_b, v_s, '');
  reset role;
  select count(*) into v_n from member_reviews where rater_id = v_a and target_id = v_b and session_id = v_s;
  v_msg := v_msg || case when (v_r->>'cleared')::boolean and v_n = 0 then '✅' else '🔴' end || ' ⓘ 清空就刪掉' || E'\n';

  -- ⓙ 下架之後客人看不到、重新送出也不會回來
  insert into member_reviews (org_id, session_id, rater_id, target_id, good, body, removed_at)
  values (v_org, v_s, v_a, v_b, false, '測試下架', now());
  set local role authenticated;
  v_r := public.set_review_tx(v_b, v_s, '改一下再送');
  reset role;
  select count(*) into v_n from member_reviews where rater_id = v_a and target_id = v_b and session_id = v_s and removed_at is null;
  v_msg := v_msg || case when v_n = 0 then '✅' else '🔴' end || ' ⓙ 被下架的重新送出不會回來' || E'\n';

  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.rev', v_msg, true);
  else
    perform set_config('migi.rev', v_msg || '🔴 中途例外：' || sqlerrm, true);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.rev', true), ''), '🔴 沒有訊息') as "同桌文字評價 行為測試";
