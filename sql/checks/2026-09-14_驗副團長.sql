/* ============================================================
   行為驗證：副團長真的邀得動，而且**只**邀得動
   2026-09-14
   ------------------------------------------------------------
   🔴 這一份在交易裡造樣本，結尾一定 `raise exception 'migi_rollback'`
     全部退掉（硬規則 1.8）。DDL 那一半在
     `sql/pending/2026-09-14_副團長.sql`，那一份一個 raise 都沒有。

   🎯 這份存在的理由是**負對照**：只驗「副團長邀得動」的話，
     一份把每一支守衛都放寬的改動也會全綠 —— 而那正是這個功能
     最不該發生的事（規格是「只有一個功能」）。

   身分切換：`current_member_id()` → `migi_jwt_line_id()` → JWT 的 `sub`，
   所以 `set_config('request.jwt.claims', …)` 就能換人。
   ⚠ 用資料庫裡真的 `line_user_id`，不要自己編。
   ============================================================ */

do $$
declare
  v_msg  text := '';
  v_org  uuid;
  v_lead uuid; v_lead_line text;
  v_co   uuid; v_co_line   text;
  v_mem  uuid;
  v_out  uuid;                        -- 團外的人，用來當邀請對象
  v_team uuid;
  v_r    jsonb;
begin
  /* ── 取樣：需要四個人（團長／副團長／團員／團外的邀請對象）。
     找不到就大聲停下，不要安靜跳過（硬規則 3.57）。 ── */
  select m.id, m.line_user_id, m.org_id into v_lead, v_lead_line, v_org
    from public.members m
   where m.deleted_at is null and m.line_user_id is not null
   order by m.created_at limit 1;
  select m.id, m.line_user_id into v_co
    from public.members m
   where m.deleted_at is null and m.line_user_id is not null and m.id <> v_lead
   order by m.created_at limit 1;
  select m.id into v_mem from public.members m
   where m.deleted_at is null and m.id not in (v_lead, v_co) order by m.created_at limit 1;
  select m.id into v_out from public.members m
   where m.deleted_at is null and m.id not in (v_lead, v_co, v_mem) order by m.created_at limit 1;
  select m.line_user_id into v_co_line from public.members m where m.id = v_co;

  if v_lead is null or v_co is null or v_mem is null or v_out is null then
    raise exception '🔴 取樣失敗：需要四個會員（前兩個要有 line_user_id），這份驗不了';
  end if;

  /* ── 造一個團：v_lead 是團長，v_co 與 v_mem 是團員 ── */
  insert into public.teams (org_id, name, join_policy, created_by)
  values (v_org, '驗證副團長', 'approval', v_lead) returning id into v_team;
  insert into public.team_members (org_id, team_id, member_id, role)
  values (v_org, v_team, v_lead, 'leader'), (v_org, v_team, v_co, 'member'),
         (v_org, v_team, v_mem, 'member');

  /* ── 以團長身分 ── */
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_lead_line, 'role', 'authenticated')::text, true);

  v_msg := '① 身分（應為團長本人）：'
    || case when public.current_member_id() = v_lead then '✅' else '🔴 解析不到，後面都不算數' end;

  /* ② 升為副團長 */
  v_r := public.set_team_co_leader_tx(v_team, v_co, true);
  v_msg := v_msg || E'\n② 團長把他升為副團長：' || coalesce(v_r->>'message', '🔴 沒回話')
    || '　role=' || coalesce(v_r->>'role', '（無）')
    || case when (v_r->>'ok')::boolean and v_r->>'role' = 'co_leader' then ' ✅' else ' 🔴' end;

  /* ③ 冪等：再按一次不可以報錯 */
  v_r := public.set_team_co_leader_tx(v_team, v_co, true);
  v_msg := v_msg || E'\n③ 再按一次（冪等）：' || coalesce(v_r->>'message', '🔴')
    || case when (v_r->>'ok')::boolean and (v_r->>'changed')::boolean = false then ' ✅' else ' 🔴 應為 ok 且沒有變動' end;

  /* ④ 名冊排序：團長第一、副團長第二。
     🔴 這一格就是「不要靠字母巧合」那個坑 —— 字串序會把 co_leader 排最前。 */
  v_r := public.get_team_tx(v_team);
  v_msg := v_msg || E'\n④ 名冊順序：'
    || coalesce((select string_agg(e->>'role', ' → ') from jsonb_array_elements(v_r->'members') e), '🔴')
    || case when (v_r->'members'->0->>'role') = 'leader'
              and (v_r->'members'->1->>'role') = 'co_leader'
             then ' ✅' else ' 🔴 團長必須排第一' end;

  /* ── 換成副團長身分 ── */
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_co_line, 'role', 'authenticated')::text, true);
  v_msg := v_msg || E'\n⑤ 身分（應為副團長本人）：'
    || case when public.current_member_id() = v_co then '✅' else '🔴 後面都不算數' end;

  /* ⑥ 🎯 正對照：他真的邀得動（少了這一格，一支永遠拒絕的實作也會全綠） */
  v_r := public.invite_to_team_tx(v_team, v_out);
  v_msg := v_msg || E'\n⑥ 副團長邀人：' || coalesce(v_r->>'message', '🔴 沒回話')
    || case when (v_r->>'ok')::boolean then ' ✅' else ' 🔴 應該要成功' end;
  v_msg := v_msg || E'\n   ↳ 真的留下一筆邀請嗎：'
    || (select count(*)::text from public.team_requests r
         where r.team_id = v_team and r.member_id = v_out
           and r.kind = 'invite' and r.status = 'pending' and r.created_by = v_co)
    || ' 筆（應為 1，而且 created_by 是副團長）';

  /* ── ⑦–⑩ 負對照：規格說「只有一個功能」 ── */
  v_r := public.list_team_requests_tx(v_team);
  v_msg := v_msg || E'\n⑦ 副團長看待審核：' || coalesce(v_r->>'message', '🔴 竟然看得到')
    || case when v_r->>'reason' = 'not_leader' then ' ✅ 擋下' else ' 🔴' end;

  v_r := public.kick_team_member_tx(v_team, v_mem);
  v_msg := v_msg || E'\n⑧ 副團長移除團員：' || coalesce(v_r->>'message', '🔴 竟然可以')
    || case when v_r->>'reason' = 'not_leader' then ' ✅ 擋下' else ' 🔴' end
    || '（那個人還在嗎：'
    || (select count(*)::text from public.team_members
         where team_id = v_team and member_id = v_mem and left_at is null) || '，應為 1）';

  v_r := public.update_team_tx(v_team, '被改掉的團名', null, null, null, false, null);
  v_msg := v_msg || E'\n⑨ 副團長改團名：' || coalesce(v_r->>'message', '🔴 竟然可以')
    || case when v_r->>'reason' = 'not_leader' then ' ✅ 擋下' else ' 🔴' end
    || '（團名現在是「'
    || coalesce((select t.name from public.teams t where t.id = v_team), '🔴') || '」）';

  v_r := public.disband_team_tx(v_team);
  v_msg := v_msg || E'\n⑩ 副團長解散團：' || coalesce(v_r->>'message', '🔴 竟然可以')
    || case when v_r->>'reason' = 'not_leader' then ' ✅ 擋下' else ' 🔴' end
    || '（團還在嗎：'
    || (select count(*)::text from public.teams t where t.id = v_team and t.deleted_at is null)
    || '，應為 1）';

  /* ⑪ 🔴 副團長不能再任命副團長 —— 收權限的人只有一個。 */
  v_r := public.set_team_co_leader_tx(v_team, v_mem, true);
  v_msg := v_msg || E'\n⑪ 副團長任命別人當副團長：' || coalesce(v_r->>'message', '🔴 竟然可以')
    || case when v_r->>'reason' = 'not_leader' then ' ✅ 擋下' else ' 🔴' end;

  /* ⑫ 一般團員仍然邀不動（確認門不是對所有人開的）。 */
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select line_user_id from public.members where id = v_mem),
                      'role', 'authenticated')::text, true);
  if public.current_member_id() = v_mem then
    v_r := public.invite_to_team_tx(v_team, v_out);
    v_msg := v_msg || E'\n⑫ 一般團員邀人：' || coalesce(v_r->>'message', '🔴 竟然可以')
      || case when v_r->>'reason' = 'not_leader' then ' ✅ 擋下' else ' 🔴' end;
  else
    v_msg := v_msg || E'\n⑫ 一般團員邀人：⚪ 這個人沒有 line_user_id，換不了身分（這一格測不了）';
  end if;

  /* ⑬ 降回團員之後就邀不動了 —— 收得回來才算真的是權限。 */
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_lead_line, 'role', 'authenticated')::text, true);
  v_r := public.set_team_co_leader_tx(v_team, v_co, false);
  v_msg := v_msg || E'\n⑬ 團長取消副團長：' || coalesce(v_r->>'message', '🔴')
    || '　role=' || coalesce(v_r->>'role', '（無）');
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_co_line, 'role', 'authenticated')::text, true);
  v_r := public.invite_to_team_tx(v_team, v_lead);   -- 對象不重要，看守衛就好
  v_msg := v_msg || E'\n   ↳ 他現在再邀人：' || coalesce(v_r->>'message', '🔴 竟然可以')
    || case when v_r->>'reason' = 'not_leader' then ' ✅ 擋下' else ' 🔴 權限收不回來' end;

  raise exception E'\n%\n\n（以上樣本全部回滾，一列都沒有留下）', v_msg;
end $$;
