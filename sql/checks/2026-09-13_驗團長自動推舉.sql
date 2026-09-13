/* ============================================================
   驗「團長失聯自動推舉」真的會換人，而且換對人
   2026-09-13 · 搭配 sql/pending/2026-09-13_團長失聯自動推舉.sql
   ------------------------------------------------------------
   🔴 這一份**故意不留下任何東西**：它在交易內造樣本，最後 raise 回滾。
     所以它與那份 DDL 必須分兩個檔案（硬規則 1.8）——
     一份要留下東西就不准 raise，一份要造樣本就只能 raise。

   ⚠ 樣本自己造，不要借線上最新的那一筆（硬規則 3.57）：
     線上只有一個團、一個人，而「世界會動」在這種測試上咬過四次。
   ============================================================ */
do $$
declare
  v_org   uuid := '11111111-1111-1111-1111-111111111111';
  v_team  uuid;
  v_lead  uuid;   -- 失聯的團長
  v_hi    uuid;   -- 參與度高、年資淺
  v_old   uuid;   -- 參與度 0、年資最久
  v_msg   text := '';
  v_role  text;
  v_n     int;
begin
  /* ── 造人。用固定前綴的假 line_user_id，回滾後不會留下 ── */
  insert into public.members (org_id, display_name, line_user_id, is_test,
                              last_app_active_at, last_visit_at)
  values (v_org, '測_失聯團長', 'Uchk20260913aaa', true,
          now() - interval '200 days', now() - interval '300 days')
  returning id into v_lead;

  insert into public.members (org_id, display_name, line_user_id, is_test)
  values (v_org, '測_元老零場', 'Uchk20260913bbb', true) returning id into v_old;

  insert into public.members (org_id, display_name, line_user_id, is_test)
  values (v_org, '測_主力', 'Uchk20260913ccc', true) returning id into v_hi;

  insert into public.teams (org_id, name, join_policy, created_by)
  values (v_org, '測_失聯團', 'approval', v_lead) returning id into v_team;

  /* 年資刻意排成：元老最久、主力最新。
     ⇒ 舊判準（年資）會選元老，新判準（參與度）要選主力。
     🎯 這正是這次改動的分水嶺，測試就是要讓兩者選不同的人。 */
  insert into public.team_members (org_id, team_id, member_id, role, joined_at) values
    (v_org, v_team, v_lead, 'leader', now() - interval '400 days'),
    (v_org, v_team, v_old,  'member', now() - interval '399 days'),
    (v_org, v_team, v_hi,   'member', now() - interval '10 days');

  /* ── ① 候選人是誰（不看場次也該選得出來，此時兩人都 0 場）── */
  v_msg := '① 還沒有場次時的候選人（0 場平手 ⇒ 年資久的元老）：'
    || coalesce((select display_name from public.members
                  where id = public._team_top_contributor(v_team, v_lead)), '🔴 算不出來');

  /* ── 造場次：讓主力有 3 場、元老 0 場 ──
     ⚠ 這裡直接借 `_team_session_ids` 認得的形狀。
       它算的是「整桌都是團員」的場次（牌咖團的既有規則）。 */
  declare
    v_store uuid;
    v_table uuid;
    v_sess  uuid;
    i int;
  begin
    select id into v_store from public.stores where org_id = v_org and deleted_at is null limit 1;
    select id into v_table from public.tables where store_id = v_store and deleted_at is null limit 1;

    for i in 1..3 loop
      insert into public.table_sessions (org_id, store_id, table_id, mode, status,
                                         started_at, ended_at, opened_by_staff_id)
      values (v_org, v_store, v_table, 'private', 'completed',
              now() - make_interval(days => i), now() - make_interval(days => i) + interval '3 hours', null)
      returning id into v_sess;

      /* 整桌四人都是團員 —— 少一個就不算這個團的場次。 */
      insert into public.session_players (org_id, session_id, member_id, charged_points, joined_at)
      values (v_org, v_sess, v_hi,   0, now() - make_interval(days => i)),
             (v_org, v_sess, v_lead, 0, now() - make_interval(days => i)),
             (v_org, v_sess, v_old,  0, now() - make_interval(days => i)),
             (v_org, v_sess, v_hi,   0, now() - make_interval(days => i))
      on conflict do nothing;
    end loop;
  end;

  /* ⚠ 上面那個 insert 有兩列是同一個人（唯一鍵會擋掉一列），
     所以實際上是三個人一桌。`_team_session_ids` 若要求滿四人，
     這一格就會是 0 —— 下一行把實際數字印出來讓人判讀，不要回是非題。 */
  select count(*) into v_n from public._team_session_ids(v_team);
  v_msg := v_msg || E'\n② 這個團算得出幾場（整桌都是團員才算）：' || v_n;

  /* ── ③ 判準對每個人的答案 ── */
  v_msg := v_msg || E'\n③ 判準的答案：'
    || '主力=' || coalesce(public._team_claim_check(v_team, v_hi),  '✅ 可以接任')
    || '　元老=' || coalesce(public._team_claim_check(v_team, v_old), '（不可）')
    || '　團長=' || coalesce(public._team_claim_check(v_team, v_lead), '（不可）');

  /* ── ④ 真的跑一次掃描 ── */
  perform public.sweep_team_leaders_tx(v_org);

  select role into v_role from public.team_members
   where team_id = v_team and member_id = v_hi and left_at is null;
  v_msg := v_msg || E'\n④ 掃完之後主力的角色（應為 leader）：' || coalesce(v_role, '🔴 查不到');

  select role into v_role from public.team_members
   where team_id = v_team and member_id = v_lead and left_at is null;
  v_msg := v_msg || E'\n⑤ 舊團長的角色（應為 member）：' || coalesce(v_role, '🔴 查不到');

  select count(*) into v_n from public.team_members
   where team_id = v_team and role = 'leader' and left_at is null;
  v_msg := v_msg || E'\n⑥ 團長只有一個（應為 1）：' || v_n;

  select count(*) into v_n from public.app_notifications
   where org_id = v_org and member_id in (v_hi, v_lead) and type = 'team_ok';
  v_msg := v_msg || E'\n⑦ 兩邊都收到通知（應為 2）：' || v_n;

  /* ── ⑧ 負對照：團長還活著的團不可以被動到（硬規則 3.55）──
     🔴 只驗「該換的換了」的話，一支**無條件換人**的實作也會全綠。 */
  update public.members set last_app_active_at = now() where id = v_hi;
  declare v_team2 uuid; v_lead2 uuid; v_mem2 uuid; begin
    insert into public.members (org_id, display_name, line_user_id, is_test, last_app_active_at)
    values (v_org, '測_活躍團長', 'Uchk20260913ddd', true, now()) returning id into v_lead2;
    insert into public.members (org_id, display_name, line_user_id, is_test)
    values (v_org, '測_一般團員', 'Uchk20260913eee', true) returning id into v_mem2;
    insert into public.teams (org_id, name, join_policy, created_by)
    values (v_org, '測_正常團', 'approval', v_lead2) returning id into v_team2;
    insert into public.team_members (org_id, team_id, member_id, role) values
      (v_org, v_team2, v_lead2, 'leader'), (v_org, v_team2, v_mem2, 'member');

    perform public.sweep_team_leaders_tx(v_org);

    select role into v_role from public.team_members
     where team_id = v_team2 and member_id = v_lead2 and left_at is null;
    v_msg := v_msg || E'\n⑧ 負對照 · 活躍團長沒被換掉（應為 leader）：' || coalesce(v_role, '🔴 查不到');
  end;

  /* ── ⑨ 只有團長一個人的團不會爆（也不該被動）── */
  declare v_team3 uuid; v_lead3 uuid; begin
    insert into public.members (org_id, display_name, line_user_id, is_test, last_app_active_at)
    values (v_org, '測_孤單團長', 'Uchk20260913fff', true, now() - interval '400 days')
    returning id into v_lead3;
    insert into public.teams (org_id, name, join_policy, created_by)
    values (v_org, '測_一人團', 'approval', v_lead3) returning id into v_team3;
    insert into public.team_members (org_id, team_id, member_id, role)
    values (v_org, v_team3, v_lead3, 'leader');

    perform public.sweep_team_leaders_tx(v_org);

    select role into v_role from public.team_members
     where team_id = v_team3 and member_id = v_lead3 and left_at is null;
    v_msg := v_msg || E'\n⑨ 一人團的團長還在（應為 leader）：' || coalesce(v_role, '🔴 查不到');
  end;

  /* 🔴 訊息設在 exception 之前會被回滾（硬規則 3.9）——
     所以先 set_config，再靠 handler 裡那一份保住它。 */
  perform set_config('migi.chk', v_msg, true);
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm <> 'migi_rollback' then
    perform set_config('migi.chk', coalesce(current_setting('migi.chk', true), '')
                       || E'\n🔴 中途出錯：' || sqlerrm, true);
  else
    perform set_config('migi.chk', v_msg, true);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "行為驗證";
