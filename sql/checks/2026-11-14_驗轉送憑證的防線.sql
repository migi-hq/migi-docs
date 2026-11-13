/* 驗「即時通話轉送憑證的防線」的行為（2026-11-14）—— 唯讀檢查：整段在交易裡造樣本，最後故意 raise 回滾，什麼都不會留下。
   先跑過 sql/pending/2026-11-14_即時通話轉送憑證的防線.sql 才有意義。

   樣本：最近一場「已收桌、有兩個以上真人」的線上牌局，在交易裡暫時改回進行中、座位改回還坐著（收桌時每一家都寫了 left_at）。
   ⚠ 找不到樣本要出聲（硬規則 3.57），不要安靜跳過 */
do $$
declare v_sid uuid; v_a uuid; v_msg text := ''; v_ok int := 0; r jsonb;
begin
  select g.session_id into v_sid from friendly_games g join table_sessions ts on ts.id = g.session_id
   where g.play_mode = 'online' and ts.status = 'completed'
     and (select count(*) from session_players sp join members m on m.id = sp.member_id where sp.session_id = g.session_id and not m.is_bot) >= 2
   order by g.created_at desc limit 1;
  if v_sid is null then perform set_config('migi.ice_t', '⚪ 找不到有兩個真人、已收桌的線上牌局，這份測不了', true); return; end if;
  select sp.member_id into v_a from session_players sp join members m on m.id = sp.member_id
   where sp.session_id = v_sid and not m.is_bot order by sp.seat limit 1;

  -- 🔴 造樣本一定要在這個 begin…exception 裡面：回滾只退得掉這一段
  begin
    -- ① 還沒改回進行中 ⇒ not_open（沒有資格，但有記一筆）
    r := public.online_ice_issue_tx(v_sid, v_a);
    if r->>'eligible' = 'false' and r->>'reason' = 'not_open' then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ① 已收桌的牌局沒有資格（not_open）';
    else v_msg := v_msg || E'\n🔴 ① ' || r::text; end if;

    update table_sessions set status = 'open', ended_at = null where id = v_sid;
    update session_players set left_at = null where session_id = v_sid;

    -- ② 正對照：進行中、坐著、同桌有別的真人 ⇒ 有資格
    r := public.online_ice_issue_tx(v_sid, v_a);
    if r->>'eligible' = 'true' then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ② 進行中、坐著、同桌有真人 ⇒ 有資格';
    else v_msg := v_msg || E'\n🔴 ② 該有資格卻沒有：' || r::text; end if;

    -- ③ 不在這一場的人 ⇒ not_seated
    r := public.online_ice_issue_tx(v_sid, gen_random_uuid());
    if r->>'reason' = 'not_seated' then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ③ 不在這一場的人沒有資格（not_seated）';
    else v_msg := v_msg || E'\n🔴 ③ ' || r::text; end if;

    -- ④ 同桌其他人都離開 ⇒ no_humans
    update session_players set left_at = now() where session_id = v_sid and member_id <> v_a;
    r := public.online_ice_issue_tx(v_sid, v_a);
    if r->>'reason' = 'no_humans' then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ④ 同桌沒有別的真人 ⇒ 沒有資格（no_humans）';
    else v_msg := v_msg || E'\n🔴 ④ ' || r::text; end if;
    update session_players set left_at = null where session_id = v_sid;

    -- ⑤ 24 小時內已經有資格 30 次 ⇒ daily_limit
    insert into online_ice_log (org_id, session_id, member_id, eligible)
      select (select org_id from table_sessions where id = v_sid), v_sid, v_a, true from generate_series(1, 29);
    r := public.online_ice_issue_tx(v_sid, v_a);
    if r->>'reason' = 'daily_limit' then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ⑤ 24 小時內第 31 次 ⇒ 沒有資格（daily_limit）';
    else v_msg := v_msg || E'\n🔴 ⑤ ' || r::text; end if;

    -- ⑥ 每一次都有記（① not_open、② 有資格、③ not_seated、④ no_humans、29 筆造的、⑤ daily_limit ＝ 34 筆）
    if (select count(*) from online_ice_log where session_id = v_sid) = 34 then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ⑥ 每一次都有記一筆（34 筆）';
    else v_msg := v_msg || E'\n🔴 ⑥ 記錄筆數不對：' || (select count(*) from online_ice_log where session_id = v_sid); end if;

    raise exception 'migi_rollback';
  exception when others then
    perform set_config('migi.ice_t', case when sqlerrm = 'migi_rollback' then v_ok || ' / 6' || v_msg else '🔴 出錯：' || sqlerrm || v_msg end, true);
  end;
end $$;
select coalesce(nullif(current_setting('migi.ice_t', true), ''), '🔴 沒有訊息') as "行為測試";
