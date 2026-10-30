-- ============================================================
-- 行為測試：牌咖與牌咖團邀請連結多回的卡片資料（sql/pending/2026-10-31_牌咖與牌咖團邀請卡片資料.sql）
-- 用測試帳號的真實身分（request.jwt.claims 的 sub ＝ 他的 LINE id）叫一次，最後整段退回、一筆都不留
--   ⓐ 牌咖：rank 跟 members.rank 一樣、season_rank 跟排行榜同一支算出來的一樣、win_pct 跟成績頁同一個算法
--   ⓑ 牌咖：把「誰能看我的成績」改成「只有自己」⇒ win_pct 變 null，段位與排名照給（正對照：前一格要有值才算數）
--   ⓒ 牌咖團：leader_name、member_count 跟資料表直接數的一樣
-- ============================================================
do $$
declare
  m uuid; l text; org uuid; r jsonb; v_msg text := '';
  v_from timestamptz; v_srank int; v_core jsonb; v_sc int; v_w int; v_min int; v_pct int;
  t_id uuid; t_leader uuid; t_lline text; v_lname text; v_cnt int;
begin
  select id, line_user_id, org_id into m, l, org from members
   where display_name = '測試02' and is_test and deleted_at is null and line_user_id is not null;
  if m is null then
    perform set_config('migi.x', '⚪ 找不到有 LINE id 的測試02，測不了', true); return;
  end if;
  begin
    -- ⓐ
    perform set_config('request.jwt.claims', json_build_object('sub', l, 'role', 'authenticated')::text, true);
    r := public.create_buddy_invite_link_tx();
    v_from := (public.current_season_tx(org) ->> 'starts_at')::timestamptz;
    select rank_no into v_srank from public.season_rank_rows_display_tx(org, v_from, null) where member_id = m;
    v_core := public._member_stats_core(org, m);
    v_sc := nullif(v_core -> 'season' ->> 'scored', '')::int;
    v_w := nullif(v_core -> 'season' ->> 'wins', '')::int;
    v_min := coalesce(nullif(v_core ->> 'min_games', '')::int, 0);
    v_pct := case when v_sc > 0 and v_sc >= v_min then round(coalesce(v_w, 0) * 100.0 / v_sc)::int end;
    v_msg := v_msg || case when (r ->> 'ok')::boolean
                            and r ? 'rank' and r ? 'season_rank' and r ? 'win_pct'
                            and (r ->> 'rank') is not distinct from (select rank from members where id = m)
                            and (r ->> 'season_rank')::int is not distinct from v_srank
                            and (r ->> 'win_pct')::int is not distinct from v_pct
                       then '✅ ⓐ 牌咖：段位 ' || coalesce(r ->> 'rank', '（無）') || '・排名 ' || coalesce(r ->> 'season_rank', '（不在榜上）')
                            || '・勝率 ' || coalesce((r ->> 'win_pct') || '%', '（未滿 ' || v_min || ' 場）') || '，跟排行榜與成績頁算的一樣'
                       else '🔴 ⓐ 對不上：' || r::text || ' 應為 排名 ' || coalesce(v_srank::text, 'null') || ' 勝率 ' || coalesce(v_pct::text, 'null') end;

    -- ⓑ 只有自己 ⇒ 勝率不給，段位與排名照給
    update members set see_score = '只有自己' where id = m;
    r := public.create_buddy_invite_link_tx();
    v_msg := v_msg || E'\n' || case
      when (r ->> 'win_pct') is null and (r ->> 'rank') is not distinct from (select rank from members where id = m)
           and (r ->> 'season_rank')::int is not distinct from v_srank
        then '✅ ⓑ 設成「只有自己」⇒ 勝率不給、段位與排名照給'
             || case when v_pct is null then '（⚠ 測試02 本來就沒有勝率，這一格證明不了「有值會被拿掉」）' else '（原本 ' || v_pct || '%）' end
      else '🔴 ⓑ 只有自己還是給了勝率：' || r::text end;

    -- ⓒ 牌咖團：找一個測試帳號當團長的團
    select t.id, tm.member_id, mm.line_user_id into t_id, t_leader, t_lline
      from teams t join team_members tm on tm.team_id = t.id and tm.left_at is null and tm.role = 'leader'
      join members mm on mm.id = tm.member_id and mm.is_test and mm.line_user_id is not null
     where t.deleted_at is null and t.org_id = org limit 1;
    if t_id is null then
      v_msg := v_msg || E'\n⚪ ⓒ 沒有測試帳號當團長的牌咖團，這一格測不了';
    else
      perform set_config('request.jwt.claims', json_build_object('sub', t_lline, 'role', 'authenticated')::text, true);
      r := public.create_team_invite_link_tx(t_id);
      select display_name into v_lname from members where id = t_leader;
      select count(*) into v_cnt from team_members where team_id = t_id and left_at is null;
      v_msg := v_msg || E'\n' || case
        when (r ->> 'ok')::boolean and r ->> 'leader_name' = v_lname and (r ->> 'member_count')::int = v_cnt
          then '✅ ⓒ 牌咖團「' || (r ->> 'team_name') || '」：團長 ' || v_lname || '・團員 ' || v_cnt || ' 人'
        else '🔴 ⓒ 對不上：' || r::text || ' 應為 團長 ' || coalesce(v_lname, 'null') || ' 團員 ' || v_cnt end;
    end if;

    perform set_config('request.jwt.claims', '{}', true);
    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm = 'migi_rollback' then
      perform set_config('migi.x', v_msg || E'\n（以上全部退回，資料庫沒有留下任何一筆）', true);
    else
      perform set_config('migi.x', v_msg || E'\n🔴 中途出錯：' || sqlerrm, true);
    end if;
  end;
end $$;
select coalesce(nullif(current_setting('migi.x', true), ''), '🔴 沒有訊息') as "行為測試";
