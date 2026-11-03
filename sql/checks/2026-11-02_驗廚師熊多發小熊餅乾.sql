/* ============================================================
   驗廚師熊（2026-11-02_牌咖團顧問_廚師熊多發小熊餅乾.sql）
   唯讀效果：整段回滾
   ------------------------------------------------------------
   樣本：借一場已經有名次、正好 4 位不同會員的場次（優先挑全是測試帳號的），
   在交易裡自己造團、把名次清空再寫回去 ＝ 重演「名次寫進去那一刻」。
   自己造的團入團時間設在 1999／2000 年 ⇒ 一定是「最早湊齊的那一團」，
   不會被這四人真實的共同團搶走（同 _advisor_table_team 的挑法）。
   最後 raise 'migi_rollback' ⇒ 什麼都不留下（故意不提交的那一種，硬規則 1.8）。

   格子（同一場依序，負對照在前 —— 冪等鍵綁場次，發過一次就不會再發）：
     ① 廚師熊團只有其中 3 位 ⇒ 不發
     ② 四位另有一個更早的商人熊團 ⇒ 挑到商人熊，不發
     ③ 四位都在廚師熊團，但這場是好友練習賽 ⇒ 不發
     ④ 改回正式段位賽 ⇒ 四人各 1 個，原因 chef、記到這一場，顯示用的餅乾數也各 +1
     ⑤ 名次再寫一次 ⇒ 還是 4 筆（不重發）
   ============================================================ */
do $$
declare
  v_msg   text := '';
  v_sess  uuid;
  v_org   uuid;
  v_mem   uuid[];
  v_ranks jsonb;
  v_mode  text;
  v_chef  uuid;
  v_merch uuid;
  v_n     int;
  v_before jsonb;
  v_after  jsonb;
begin
  select ts.id, ts.org_id, ts.mode into v_sess, v_org, v_mode
    from table_sessions ts
    join session_players sp on sp.session_id = ts.id
    join members m on m.id = sp.member_id
   where coalesce(ts.mode, '') <> 'friendly'
     and exists (select 1 from session_players x where x.session_id = ts.id and x.finish_rank is not null)
   group by ts.id, ts.org_id, ts.mode
  having count(distinct sp.member_id) = 4 and count(*) = 4
   order by bool_and(m.is_test) desc, max(ts.ended_at) desc nulls last
   limit 1;
  if v_sess is null then raise exception '找不到樣本：沒有已結算、正好 4 位的場次'; end if;

  select array_agg(member_id order by member_id), jsonb_object_agg(id, finish_rank)
    into v_mem, v_ranks
    from session_players where session_id = v_sess;

  v_msg := '樣本場次 ' || v_sess || '（' || v_mode || '）'
        || coalesce('　這四人真實的顧問團：' || (select advisor || ' ' || team_name from public._advisor_table_team(v_org, v_mem)), '　這四人沒有真實的顧問團');

  -- ① 廚師熊團只有其中 3 位
  insert into teams (org_id, name, created_by, advisor, created_at)
  values (v_org, '驗廚師熊' || left(md5(random()::text), 6), v_mem[1], 'chef', '2000-01-01')
  returning id into v_chef;
  insert into team_members (org_id, team_id, member_id, role, joined_at)
  select v_org, v_chef, x, case when x = v_mem[1] then 'leader' else 'member' end, '2000-01-01'
    from unnest(v_mem[1:3]) x;

  update session_players set finish_rank = null where session_id = v_sess;
  update session_players sp set finish_rank = (v_ranks ->> sp.id::text)::int where sp.session_id = v_sess;
  select count(*) into v_n from snack_grants where reason = 'chef' and ref_id = v_sess;
  v_msg := v_msg || E'\n① ' || case when v_n = 0 then '✅ 廚師熊團只有 3 位：不發' else '🔴 發了 ' || v_n || ' 筆' end;

  -- ② 補上第 4 位，但四人另有一個更早的商人熊團
  insert into team_members (org_id, team_id, member_id, role, joined_at)
  values (v_org, v_chef, v_mem[4], 'member', '2000-01-01');
  insert into teams (org_id, name, created_by, advisor, created_at)
  values (v_org, '驗商人熊' || left(md5(random()::text), 6), v_mem[1], 'merchant', '1999-01-01')
  returning id into v_merch;
  insert into team_members (org_id, team_id, member_id, role, joined_at)
  select v_org, v_merch, x, case when x = v_mem[1] then 'leader' else 'member' end, '1999-01-01'
    from unnest(v_mem) x;

  update session_players set finish_rank = null where session_id = v_sess;
  update session_players sp set finish_rank = (v_ranks ->> sp.id::text)::int where sp.session_id = v_sess;
  select count(*) into v_n from snack_grants where reason = 'chef' and ref_id = v_sess;
  v_msg := v_msg || E'\n② ' || case when v_n = 0
                                     and (select advisor from public._advisor_table_team(v_org, v_mem)) = 'merchant'
                                then '✅ 挑到更早的商人熊團：不發' else '🔴 發了 ' || v_n || ' 筆' end;

  -- ③ 商人熊團解散 ⇒ 剩廚師熊團；但這場改成好友練習賽
  update teams set deleted_at = now() where id = v_merch;
  begin
    update table_sessions set mode = 'friendly' where id = v_sess;
    update session_players set finish_rank = null where session_id = v_sess;
    update session_players sp set finish_rank = (v_ranks ->> sp.id::text)::int where sp.session_id = v_sess;
    select count(*) into v_n from snack_grants where reason = 'chef' and ref_id = v_sess;
    v_msg := v_msg || E'\n③ ' || case when v_n = 0 then '✅ 好友練習賽：不發' else '🔴 發了 ' || v_n || ' 筆' end;
    update table_sessions set mode = v_mode where id = v_sess;
  exception when others then
    v_msg := v_msg || E'\n③ ⚪ 這場改不成好友練習賽，這一格測不了（' || left(sqlerrm, 80) || '）';
  end;

  -- ④ 正式段位賽、四位都在廚師熊團 ⇒ 各 1 個
  select coalesce(jsonb_object_agg(x, coalesce((select (bear -> 'snacks' ->> 'cookie')::int from member_app_state where member_id = x), 0)), '{}')
    into v_before from unnest(v_mem) x;

  update session_players set finish_rank = null where session_id = v_sess;
  update session_players sp set finish_rank = (v_ranks ->> sp.id::text)::int where sp.session_id = v_sess;

  select coalesce(jsonb_object_agg(x, coalesce((select (bear -> 'snacks' ->> 'cookie')::int from member_app_state where member_id = x), 0)), '{}')
    into v_after from unnest(v_mem) x;
  select count(*) into v_n from snack_grants
   where reason = 'chef' and ref_id = v_sess and kind = 'cookie' and qty = 1 and member_id = any (v_mem);
  v_msg := v_msg || E'\n④ ' || case when v_n = 4
                                     and (select bool_and((v_after ->> x::text)::int = (v_before ->> x::text)::int + 1) from unnest(v_mem) x)
                                then '✅ 四人各 1 個小熊餅乾（原因 chef、記到這一場），顯示的餅乾數各 +1'
                                else '🔴 筆數 ' || v_n || '　前 ' || v_before::text || '　後 ' || v_after::text end;

  -- ⑤ 名次再寫一次 ⇒ 不重發
  update session_players set finish_rank = null where session_id = v_sess;
  update session_players sp set finish_rank = (v_ranks ->> sp.id::text)::int where sp.session_id = v_sess;
  select count(*) into v_n from snack_grants where reason = 'chef' and ref_id = v_sess;
  v_msg := v_msg || E'\n⑤ ' || case when v_n = 4 then '✅ 再結算一次：還是 4 筆，不重發' else '🔴 變成 ' || v_n || ' 筆' end;

  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.t', v_msg, false);
  else
    perform set_config('migi.t', coalesce(v_msg, '') || E'\n🔴 中途拋錯：' || sqlerrm, false);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有訊息') as "驗廚師熊（整段已回滾）";
