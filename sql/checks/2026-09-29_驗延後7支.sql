-- 2026-09-29 驗延後 7 支（跑在 2026-09-29_延後的7支補身分檢查.sql 之後）
-- ⚠ 交易內用真的身分實際呼叫，最後 raise 'migi_rollback' 全部退掉。
-- 🎯 最重要的是第 ① 格：**客人自己按報名、湊滿第 4 人** ⇒ 成桌 ⇒ 自動帶桌，
--   整條路上都是客人的身分，而路上會經過 pos_seat_queue_tx → 隊列名單、自動帶桌 → 桌況預測。
--   這次把那幾支的外層加了「限店員」，內部呼叫改接內層 —— 接錯一個，這一格就會紅。
-- ⚠ 身分模擬同 2026-09-29_驗函式身分檢查.sql；找不到樣本會出聲（硬規則 3.57）。

do $$
declare
  v_org uuid; v_store uuid; v_stake uuid; v_a uuid; v_a_line text; v_hq text;
  v_m uuid[]; v_q uuid; v_err text; v_st text; v_msg text := ''; r jsonb;
  c_member text; c_staff text;
  ok text := '✅ '; bad text := '🔴 ';
begin
  -- 會員 A：有 LINE、不是店員、身上沒有進行中的房（不然 _check_join_conflict 會咬到樣本）
  select m.id, m.line_user_id, m.org_id into v_a, v_a_line, v_org from members m
   where m.deleted_at is null and m.hidden_at is null and m.line_user_id is not null
     and not exists (select 1 from staff s where s.member_id = m.id and s.deleted_at is null)
     /* ⚠ seated 的房要「那一桌還開著」才算進行中 —— 帶到桌之後房會一直停在 seated（打完也是），
          第一版把 seated 全算進去，結果每個會員都被排除、印「樣本不足」（硬規則 3.57：取樣條件錯） */
     and not exists (select 1 from match_queue_players qp join match_queues q on q.id = qp.queue_id
                      where qp.member_id = m.id and qp.left_at is null
                        and (q.status in ('waiting','matched')
                             or (q.status = 'seated' and exists (select 1 from table_sessions ts
                                   where ts.id = q.matched_session_id and ts.status = 'open' and ts.deleted_at is null))))
   order by m.created_at limit 1;
  select array_agg(id) into v_m from (
    select m.id from members m
     where m.deleted_at is null and m.hidden_at is null and m.org_id = v_org and m.id <> v_a
       and not exists (select 1 from match_queue_players qp join match_queues q on q.id = qp.queue_id
                        where qp.member_id = m.id and qp.left_at is null
                          and (q.status in ('waiting','matched')
                               or (q.status = 'seated' and exists (select 1 from table_sessions ts
                                     where ts.id = q.matched_session_id and ts.status = 'open' and ts.deleted_at is null))))
     order by m.created_at limit 3) x;
  select s.auth_uid::text into v_hq from staff s where s.deleted_at is null and s.auth_uid is not null and s.role in ('hq','owner') limit 1;
  -- 挑一間有「空著、可自動配」的桌的測試門市
  select t.store_id into v_store from tables t join stores s on s.id = t.store_id
   where s.org_id = v_org and s.is_test and t.deleted_at is null and t.auto_assign
     and not exists (select 1 from table_sessions ts where ts.table_id = t.id and ts.status = 'open' and ts.deleted_at is null)
   limit 1;
  select id into v_stake from stake_levels where org_id = v_org and deleted_at is null order by created_at limit 1;
  if v_a is null or coalesce(array_length(v_m, 1), 0) < 3 or v_hq is null or v_store is null or v_stake is null then
    perform set_config('migi.t', '⚪ 樣本不足（有 LINE 的非店員會員、另外 3 位空閒會員、總部店員、有空桌的測試門市），這份測不了', false); return;
  end if;
  c_member := json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated',
                                'app_metadata', json_build_object('line_user_id', v_a_line))::text;
  c_staff  := json_build_object('sub', v_hq, 'role', 'authenticated')::text;

  -- ── ① 客人自己報名、湊滿第 4 人 ⇒ 成桌 ⇒ 自動帶桌，中間不可以被「限店員」擋下 ──
  perform set_config('request.jwt.claims', '', true);
  insert into match_queues (org_id, store_id, stake_level_id, play_at, status, opened_by, game_type, flower, seats, source)
  values (v_org, v_store, v_stake, now() + interval '90 minutes', 'waiting', v_m[1], '台麻', '無花', 4, 'member') returning id into v_q;
  insert into match_queue_players (org_id, queue_id, member_id, join_source)
  select v_org, v_q, x, 'browse' from unnest(v_m) x;

  perform set_config('request.jwt.claims', c_member, true);
  v_err := null;
  begin perform public.join_match_queue_tx(v_org, v_a, v_q, 'browse'); exception when others then v_err := sqlstate || ' ' || sqlerrm; end;
  select status into v_st from match_queues where id = v_q;
  v_msg := v_msg || (case when v_err is null and v_st in ('matched', 'seated') then ok else bad end)
           || '① 客人報名湊滿第 4 人 ⇒ 成桌照常：' || coalesce(v_err, '狀態 ' || v_st) || E'\n';
  v_msg := v_msg || (case when v_st = 'seated' then ok else '⚪ ' end)
           || '①-1 而且自動帶到桌了（有經過名單與預測的內層）：' || coalesce(v_st, '?')
           || case when v_st = 'seated' then '' else '（沒帶桌的話這一格測不到內層，不算失敗）' end || E'\n';

  -- ── ② 客人直接叫那幾支外層 ⇒ 42501 ──
  v_err := null; begin perform public.pos_queue_members_tx(v_org, v_q); exception when others then v_err := sqlstate; end;
  v_msg := v_msg || (case when v_err = '42501' then ok else bad end) || '② 客人叫隊列名單被擋：' || coalesce(v_err, '沒有被擋') || E'\n';
  v_err := null; begin perform public.pos_list_queues_tx(v_org, v_store); exception when others then v_err := sqlstate; end;
  v_msg := v_msg || (case when v_err = '42501' then ok else bad end) || '②-1 客人叫 POS 配桌列表被擋：' || coalesce(v_err, '沒有被擋') || E'\n';
  v_err := null; begin perform public.has_daypass_tx(v_org, v_m[1], v_store); exception when others then v_err := sqlstate; end;
  v_msg := v_msg || (case when v_err = '42501' then ok else bad end) || '②-2 客人查別人有沒有暢打被擋：' || coalesce(v_err, '沒有被擋') || E'\n';
  v_err := null; begin perform public._try_auto_seat_tx(v_org, v_q, null); exception when others then v_err := sqlstate; end;
  v_msg := v_msg || (case when v_err = '42501' then ok else bad end) || '②-3 客人直接叫自動帶桌被擋：' || coalesce(v_err, '沒有被擋') || E'\n';

  -- ── ③ 正對照：店員（POS）照常 ──
  perform set_config('request.jwt.claims', c_staff, true);
  v_err := null;
  begin
    perform public.pos_queue_members_tx(v_org, v_q);
    perform public.pos_list_queues_tx(v_org, v_store);
    perform public.pos_list_recurring_tx(v_org, v_store);
    perform public.pos_table_forecast_tx(v_org, v_store);
    perform public.has_daypass_tx(v_org, v_m[1], v_store);
  exception when others then v_err := sqlerrm; end;
  v_msg := v_msg || (case when v_err is null then ok else bad end) || '③ 正對照：店員叫這 5 支照常：' || coalesce(v_err, '成功') || E'\n';

  -- ── ④ 排程（沒有 API 身分）跑自動帶桌照常 ──
  perform set_config('request.jwt.claims', '', true);
  v_err := null;
  begin perform public.sweep_auto_seat_tx(v_org); exception when others then v_err := sqlerrm; end;
  v_msg := v_msg || (case when v_err is null then ok else bad end) || '④ 排程跑自動帶桌照常：' || coalesce(v_err, '成功');

  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.t', v_msg, false);
  else
    perform set_config('migi.t', '🔴 中途失敗：' || sqlerrm || E'\n已經跑完的：\n' || coalesce(v_msg, ''), false);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有訊息') as "驗證";
