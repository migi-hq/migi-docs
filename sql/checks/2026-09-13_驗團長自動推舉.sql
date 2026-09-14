/* ============================================================
   驗「團長失聯自動推舉」真的會換人，而且換對人
   2026-09-13 · 搭配 sql/applied/2026-09-13_團長失聯自動推舉.sql
   ------------------------------------------------------------
   🔴 這一份**故意不留下任何東西**：交易內造樣本，最後 raise 回滾。
     所以它與那份 DDL 必須分兩個檔案（硬規則 1.8）。

   ── 第一版的樣本是錯的，修法記在這裡（2026-09-13）──────
   第一版讓「主力」與「元老」都坐進同樣那幾場，於是兩人都是 3 場、
   平手之後年資久的元老贏 —— 而我讀成「函式選錯人」。
   🔴 **函式完全照規則跑，錯的是樣本**（硬規則 3.57：
     驗證段紅了，先懷疑取樣與期望值）。
   📌 根因是 `on conflict do nothing`：我在同一場塞了兩次主力，
     唯一鍵擋掉一列之後那一桌變成三個人，而元老就在裡面。
   ⚠ 另一個自找的坑：三格的標籤寫成 `coalesce(檢查, '（不可）')`，
     而檢查**回 null 才是可以接任** ⇒ 標籤與事實相反。
     這一版一律印「✅ 可以接任」與實際的 reason，不要自己翻譯成是非。

   ── 這個樣本要證明什麼 ───────────────────────────
   ```
   元老   年資最久   0 場    ← 舊判準會選他
   主力   年資中間   3 場    ← 新判準要選他
   甲     年資最淺   3 場    ← 與主力平手，靠年資輸掉（證明平手規則有效）
   團長   失聯 200 天
   ```
   ⚠ `_team_session_ids` 的規則是「在座每一個都是團員」（≥2 人），
     所以那三場是主力 ＋ 團長 ＋ 甲 三個人，元老不在裡面。
   ============================================================ */
do $$
declare
  v_org   uuid := '11111111-1111-1111-1111-111111111111';
  v_team  uuid;
  v_lead  uuid;   -- 失聯的團長
  v_hi    uuid;   -- 主力：參與度最高
  v_old   uuid;   -- 元老：年資最久但 0 場
  v_mid   uuid;   -- 甲：與主力同場次數，年資較淺
  v_store uuid;
  v_table uuid;
  v_sess  uuid;
  v_msg   text := '';
  v_role  text;
  v_n     int;
  i       int;
begin
  insert into public.members (org_id, display_name, line_user_id, is_test,
                              last_app_active_at, last_visit_at)
  values (v_org, '測_失聯團長', 'Uchk20260913aaa', true,
          now() - interval '200 days', now() - interval '300 days')
  returning id into v_lead;

  insert into public.members (org_id, display_name, line_user_id, is_test)
  values (v_org, '測_元老零場', 'Uchk20260913bbb', true) returning id into v_old;

  insert into public.members (org_id, display_name, line_user_id, is_test)
  values (v_org, '測_主力', 'Uchk20260913ccc', true) returning id into v_hi;

  insert into public.members (org_id, display_name, line_user_id, is_test)
  values (v_org, '測_甲', 'Uchk20260913ggg', true) returning id into v_mid;

  insert into public.teams (org_id, name, join_policy, created_by)
  values (v_org, '測_失聯團', 'approval', v_lead) returning id into v_team;

  /* 年資：元老最久 → 團長 → 主力 → 甲最淺。
     ⚠ 入團時間必須**早於**場次，否則 `_team_session_ids` 不把他算成團員。 */
  insert into public.team_members (org_id, team_id, member_id, role, joined_at) values
    (v_org, v_team, v_old,  'member', now() - interval '399 days'),
    (v_org, v_team, v_lead, 'leader', now() - interval '398 days'),
    (v_org, v_team, v_hi,   'member', now() - interval '10 days'),
    (v_org, v_team, v_mid,  'member', now() - interval '5 days');

  select id into v_store from public.stores where org_id = v_org and deleted_at is null limit 1;
  select id into v_table from public.tables where store_id = v_store and deleted_at is null limit 1;

  /* 三場，每場三個人：主力 ＋ 團長 ＋ 甲。元老一場都沒有。 */
  for i in 1..3 loop
    insert into public.table_sessions (org_id, store_id, table_id, mode, status,
                                       started_at, ended_at)
    values (v_org, v_store, v_table, 'private', 'completed',
            now() - make_interval(days => i), now() - make_interval(days => i) + interval '3 hours')
    returning id into v_sess;

    insert into public.session_players (org_id, session_id, member_id, charged_points, joined_at)
    values (v_org, v_sess, v_hi,   0, now() - make_interval(days => i)),
           (v_org, v_sess, v_lead, 0, now() - make_interval(days => i)),
           (v_org, v_sess, v_mid,  0, now() - make_interval(days => i));
  end loop;

  select count(*) into v_n from public._team_session_ids(v_team);
  v_msg := '① 這個團算得出幾場（應為 3）：' || v_n;

  /* ② 每個人近 90 天各幾場 —— 逐行印出來讓人判讀，不要回是非題（硬規則 3.5）。 */
  v_msg := v_msg || E'\n② 各自的場次：'
    || coalesce((select string_agg(m.display_name || '=' ||
         (select count(*) from public._team_session_ids(v_team) ts
           where ts.played_at >= now() - interval '90 days'
             and exists (select 1 from public.session_players sp
                          where sp.session_id = ts.session_id and sp.member_id = m.id)), '　')
         from public.members m where m.id in (v_old, v_hi, v_mid, v_lead)), '🔴 算不出來');

  v_msg := v_msg || E'\n③ 候選人（應為 測_主力）：'
    || coalesce((select display_name from public.members
                  where id = public._team_top_contributor(v_team, v_lead)), '🔴 算不出來');

  /* ④ 判準對每個人的答案。⚠ null ＝ 可以接任，所以這裡明講，不要用「不可」當預設字。 */
  v_msg := v_msg || E'\n④ 判準：'
    || '主力=' || coalesce(public._team_claim_check(v_team, v_hi),  '✅ 可以接任')
    || '　元老=' || coalesce(public._team_claim_check(v_team, v_old), '✅ 可以接任')
    || '　甲=' || coalesce(public._team_claim_check(v_team, v_mid), '✅ 可以接任')
    || '　團長=' || coalesce(public._team_claim_check(v_team, v_lead), '✅ 可以接任');

  perform public.sweep_team_leaders_tx(v_org);

  select role into v_role from public.team_members
   where team_id = v_team and member_id = v_hi and left_at is null;
  v_msg := v_msg || E'\n⑤ 掃完之後主力的角色（應為 leader）：' || coalesce(v_role, '🔴 查不到');

  select role into v_role from public.team_members
   where team_id = v_team and member_id = v_lead and left_at is null;
  v_msg := v_msg || E'\n⑥ 舊團長的角色（應為 member）：' || coalesce(v_role, '🔴 查不到');

  v_msg := v_msg || E'\n⑦ 元老沒有被選上（應為 member）：'
    || coalesce((select role from public.team_members
                  where team_id = v_team and member_id = v_old and left_at is null), '🔴 查不到');

  select count(*) into v_n from public.team_members
   where team_id = v_team and role = 'leader' and left_at is null;
  v_msg := v_msg || E'\n⑧ 團長只有一個（應為 1）：' || v_n;

  /* ⑨ 通知。⚠ 收件人是**新團長與舊團長**，而新團長是誰由函式決定 ——
     所以這裡用「這個團的成員收到幾則」，不要寫死是哪兩個人（上一版就是這樣數錯的）。 */
  select count(*) into v_n from public.app_notifications
   where org_id = v_org and type = 'team_ok'
     and member_id in (select member_id from public.team_members where team_id = v_team);
  v_msg := v_msg || E'\n⑨ 這個團發出幾則通知（應為 2）：' || v_n;

  /* ⑩ 負對照：團長還活著的團不可以被動到（硬規則 3.55）。
     🔴 少了這一格，一支**無條件換人**的實作也會讓上面每一格變綠。 */
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
    v_msg := v_msg || E'\n⑩ 負對照 · 活躍團長沒被換掉（應為 leader）：' || coalesce(v_role, '🔴 查不到');
  end;

  /* ⑪ 只有團長一個人的團：不該被動，也不該爆。 */
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
    v_msg := v_msg || E'\n⑪ 一人團的團長還在（應為 leader）：' || coalesce(v_role, '🔴 查不到');
  end;

  /* 🔴 訊息設在 raise 之前會被回滾（硬規則 3.9），所以 handler 裡要再設一次。 */
  perform set_config('migi.chk', v_msg, true);
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm <> 'migi_rollback' then
    perform set_config('migi.chk', coalesce(v_msg, '') || E'\n🔴 中途出錯：' || sqlerrm, true);
  else
    perform set_config('migi.chk', v_msg, true);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "行為驗證";
