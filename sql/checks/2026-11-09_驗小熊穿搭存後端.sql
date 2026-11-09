/* ============================================================
   行為測試：小熊穿搭存後端（set_my_outfit_tx ／ get_my_closet_tx 的 outfit）
   跑在 sql/pending/2026-11-09_小熊穿搭存後端.sql 之後。
   ⚠ 整段在交易裡造樣本、最後 raise 'migi_rollback' 全部退掉 —— 一筆都不會留下（這份本來就不要留東西，見硬規則 1.8）
   做法：把 request.jwt.claims 設成某位會員的 LINE 身分，current_member_id() 就會認成他（跟真的登入走同一條路）
   ============================================================ */
do $$
declare
  v_msg text := '';
  v_line text; v_name text;         -- 有毛線帽的人
  v_line2 text; v_name2 text;       -- 沒有毛線帽的人（負對照）
  r jsonb;
begin
  begin
    select m.line_user_id, m.display_name into v_line, v_name
      from members m
     where m.deleted_at is null and m.hidden_at is null and m.line_user_id is not null
       and exists (select 1 from public._member_closet(m.id) c where c.item = 'beanie')
     order by m.is_test desc, m.created_at limit 1;
    select m.line_user_id, m.display_name into v_line2, v_name2
      from members m
     where m.deleted_at is null and m.hidden_at is null and m.line_user_id is not null
       and not exists (select 1 from public._member_closet(m.id) c where c.item = 'beanie')
     order by m.is_test desc, m.created_at limit 1;
    -- 找不到樣本要出聲，不可以安靜跳過（硬規則 3.57）
    if v_line is null then v_msg := v_msg || E'\n⚪ 找不到有毛線帽、綁了 LINE 的會員，ⓐ～ⓔ 測不了'; end if;
    if v_line2 is null then v_msg := v_msg || E'\n⚪ 找不到沒有毛線帽、綁了 LINE 的會員，ⓕ 測不了'; end if;

    if v_line is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated',
        'app_metadata', json_build_object('line_user_id', v_line))::text, true);
      v_msg := v_msg || E'\n（樣本：' || v_name || '）';

      r := public.set_my_outfit_tx('{"head":"beanie"}'::jsonb);
      v_msg := v_msg || E'\n' || case when (r->>'ok')::boolean and r->'outfit'->>'head' = 'beanie'
                                      then '✅ ⓐ 穿上自己有的毛線帽 ⇒ ok' else '🔴 ⓐ 穿毛線帽：' || r::text end;

      r := public.get_my_closet_tx();
      v_msg := v_msg || E'\n' || case when r->'outfit'->>'head' = 'beanie'
                                      then '✅ ⓑ 讀回來頭上是毛線帽' else '🔴 ⓑ 讀回來：' || coalesce(r->'outfit', 'null')::text end;

      r := public.set_my_outfit_tx('{"head":"antler"}'::jsonb);
      v_msg := v_msg || E'\n' || case when r->>'reason' = 'not_owned'
                                           and (public.get_my_closet_tx())->'outfit'->>'head' = 'beanie'
                                      then '✅ ⓒ 穿沒拿到的麋鹿角 ⇒ 拒絕，而且原本的毛線帽沒被改掉' else '🔴 ⓒ 穿麋鹿角：' || r::text end;

      r := public.set_my_outfit_tx('{"wing":"beanie"}'::jsonb);
      v_msg := v_msg || E'\n' || case when r->>'reason' = 'bad_slot'
                                      then '✅ ⓓ 不存在的部位 ⇒ 拒絕' else '🔴 ⓓ 不存在的部位：' || r::text end;

      r := public.set_my_outfit_tx('{}'::jsonb);
      v_msg := v_msg || E'\n' || case when (r->>'ok')::boolean and (public.get_my_closet_tx())->'outfit' = '{}'::jsonb
                                      then '✅ ⓔ 全部脫掉 ⇒ ok，讀回來是空的' else '🔴 ⓔ 全部脫掉：' || r::text end;
    end if;

    if v_line2 is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated',
        'app_metadata', json_build_object('line_user_id', v_line2))::text, true);
      r := public.set_my_outfit_tx('{"head":"beanie"}'::jsonb);
      v_msg := v_msg || E'\n' || case when r->>'reason' = 'not_owned'
                                      then '✅ ⓕ 沒贏過的人（' || v_name2 || '）穿毛線帽 ⇒ 拒絕' else '🔴 ⓕ 沒贏過的人穿毛線帽：' || r::text end;
    end if;

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then v_msg := v_msg || E'\n🔴 中途出錯：' || sqlerrm; end if;
    perform set_config('migi.t', v_msg, true);   -- 設在 handler 裡，才不會跟著回滾（硬規則 3.9）
  end;
end $$;
select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有測試訊息') as "行為測試";
