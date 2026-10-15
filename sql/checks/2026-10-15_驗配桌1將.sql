-- ════════════════════════════════════════════════════════════════════
-- 2026-10-15 驗「配桌開放 1 將、打完 1 將也算段位分」（交易內自己造樣本，最後整份回滾）
-- 先跑 sql/pending/2026-10-15_配桌開放1將.sql，再跑這一份
--
-- 桌 1：約 1 將，用 open_session_tx 開（驗開得出來），測試01～04 入座，打一局後把那一將標成打完
--       ⇒ 觸發器自動結算 ⇒ 要有名次、有段位分；測試01 當成新客人（交易內把他過去的名次清掉）⇒ 定位賽加倍
-- 桌 2（正對照）：約 2 將，只打完 1 將 ⇒ 有名次、**不算**段位分（10-01 的規則不能被這次改壞）
-- ════════════════════════════════════════════════════════════════════
do $$
declare
  v_msg text := '';
  v_org uuid; v_store uuid; v_t1 uuid; v_t2 uuid; v_stake uuid; r jsonb;
  v_s1 uuid; v_s2 uuid; v_r1 uuid; v_r2 uuid;
  m uuid[]; i int; v_before int; v_after int; n int; v_fee jsonb;
begin
  begin
    select array_agg(id order by phone) into m from members where is_test and phone in ('0910000001','0910000002','0910000003','0910000004');
    if coalesce(array_length(m, 1), 0) <> 4 then raise exception '四個測試帳號不齊'; end if;
    if exists (select 1 from session_players sp join table_sessions ts on ts.id = sp.session_id
                where sp.member_id = any(m) and sp.left_at is null and ts.status = 'open') then
      raise exception '測試帳號現在有牌局，這份測不了';
    end if;
    select t.id, t.store_id, t.org_id into v_t1, v_store, v_org from tables t
     where t.deleted_at is null and t.is_active
       and not exists (select 1 from table_sessions s where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
     order by t.label desc limit 1;
    select t.id into v_t2 from tables t
     where t.deleted_at is null and t.is_active and t.store_id = v_store and t.id <> v_t1
       and not exists (select 1 from table_sessions s where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
     order by t.label desc limit 1;
    if v_t1 is null or v_t2 is null then raise exception '同一間店找不到兩張空桌'; end if;
    select id into v_stake from stake_levels where org_id = v_org and coalesce(is_hygiene, false) = false limit 1;

    -- ① 約 1 將的配桌開得出來
    r := public.open_session_tx(v_t1, 'matched', v_stake, 1, null, null, 'manual', null, '台麻', '無花');
    v_s1 := (r ->> 'session_id')::uuid;
    v_msg := v_msg || case when (r ->> 'ok')::boolean and v_s1 is not null then '✅ ① 約 1 將的配桌開得出來' else '🔴 ① 開桌：' || r::text end;

    -- ② 檯費試算：1 將收 SVC-TBL-M1 的價格（封測期間同 2 將 100）
    v_fee := public.calc_session_fee_tx(v_s1, 'opener', m[1]);
    v_msg := v_msg || E'\n' || case when v_fee::text ~ 'SVC-TBL-M1' or v_fee::text ~ '"unit_price": ?100\b|: ?100\b'
                                    then '✅ ② 檯費試算：' || left(v_fee::text, 120) else '🔴 ② 檯費試算：' || v_fee::text end;

    -- 測試01 當成新客人：交易內把他過去的名次清掉（回滾後原樣）
    update session_players set finish_rank = null where member_id = m[1] and finish_rank is not null;
    select rating into v_before from members where id = m[1];

    for i in 1..4 loop
      insert into session_players (org_id, session_id, member_id, seat) values (v_org, v_s1, m[i], i);
    end loop;
    insert into session_rounds (org_id, session_id, round_no, first_dealer_seat, status, started_at)
    values (v_org, v_s1, 1, 1, 'playing', now()) returning id into v_r1;
    -- 一局：座位 1 胡、座位 4 放槍 ⇒ 名次 1、2、3、4 依座位
    insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, result, winner_seat, deal_in_seat, status, score_delta, confirmed_at)
    values (v_org, v_s1, v_r1, 1, 1, 1, 'ron', 1, 4, 'confirmed', '{"1": 100, "4": -100}'::jsonb, now());

    -- ③ 那一將打完 ⇒ 觸發器自動結算
    update session_rounds set status = 'finished', finished_at = now() where id = v_r1;
    select count(*) into n from session_players where session_id = v_s1 and finish_rank is not null and score_points is not null;
    v_msg := v_msg || E'\n' || case when n = 4 then '✅ ③ 約 1 將打完 ⇒ 自動結算，四位都有名次也有段位分'
                                    else '🔴 ③ 有段位分的只有 ' || n || ' 位' end;

    -- ④ 定位賽加倍：測試01 第 1 名 ⇒ +30 × 2 = +60
    select rating into v_after from members where id = m[1];
    v_msg := v_msg || E'\n' || case when v_after - v_before = 60 then '✅ ④ 新客人只打 1 將，定位賽加倍：第 1 名 +60'
                                    else '🔴 ④ 新客人段位分變動 ' || (v_after - v_before) || '（應為 +60）' end;

    -- ⑤ 正對照：約 2 將、只打完 1 將就結算 ⇒ 有名次、沒有段位分
    r := public.open_session_tx(v_t2, 'matched', v_stake, 2, null, null, 'manual', null, '台麻', '無花');
    v_s2 := (r ->> 'session_id')::uuid;
    for i in 1..4 loop
      insert into session_players (org_id, session_id, member_id, seat) values (v_org, v_s2, m[i], i);
    end loop;
    insert into session_rounds (org_id, session_id, round_no, first_dealer_seat, status, started_at)
    values (v_org, v_s2, 1, 1, 'playing', now()) returning id into v_r2;
    insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, result, winner_seat, deal_in_seat, status, score_delta, confirmed_at)
    values (v_org, v_s2, v_r2, 1, 1, 1, 'ron', 2, 3, 'confirmed', '{"2": 100, "3": -100}'::jsonb, now());
    update session_rounds set status = 'finished', finished_at = now() where id = v_r2;   -- 約 2 將，第 1 將打完不會自動結算
    select count(*) into n from session_players where session_id = v_s2 and finish_rank is not null;
    v_msg := v_msg || E'\n' || case when n = 0 then '✅ ⑤ 約 2 將打完第 1 將：還不會自動結算（照舊）' else '🔴 ⑤ 約 2 將第 1 將就結算了' end;
    r := public._score_settle_tx(v_s2);   -- 等同沒打完就收桌
    select count(*) into n from session_players where session_id = v_s2 and finish_rank is not null and score_points is null;
    v_msg := v_msg || E'\n' || case when n = 4 and not coalesce((r ->> 'rated')::boolean, false)
                                    then '✅ ⑤-2 約 2 將只打完 1 將就收桌：有名次、不算段位分（10-01 規則沒被改壞）'
                                    else '🔴 ⑤-2 ' || r::text end;

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then v_msg := v_msg || E'\n🔴 中途出錯：' || sqlerrm; end if;
    perform set_config('migi.r1', v_msg, true);
  end;
end $$;
select coalesce(nullif(current_setting('migi.r1', true), ''), '🔴 沒有訊息') as "配桌 1 將 行為測試（已回滾）";
