/* ============================================================
   行為驗證：團長解散不了，而總部解散得了，而且沒有人被鎖在團裡
   2026-09-14
   ------------------------------------------------------------
   🔴 在交易裡造樣本，結尾一定 `raise exception` 回滾（硬規則 1.8）。
     DDL 在 `sql/applied/2026-09-14_解散團收歸總部.sql`。

   🎯 這份最重要的兩格不是「擋住了」：
     ⑤ **一人團的團長退得出來**（那是收歸總部最容易造成的死路）
     ⑦ **總部真的解散得掉**（少了它，一支永遠 forbidden 的實作也會全綠）

   身分切換：會員用 `sub = line_user_id`（今天還沒發 Supabase JWT），
   總部用 `sub = staff.auth_uid`（那是 uuid，`current_staff()` 認它）。
   ⚠ 總部那個帳號 `current_member_id()` 是 **null** —— 它不是會員。
     那正好順便測到 `_team_disband(p_by => null)` 那條路。
   ============================================================ */

do $$
declare
  v_msg  text := '';
  v_org  uuid;
  v_lead uuid; v_lead_line text;
  v_mem  uuid; v_mem_line  text;
  v_out  uuid;
  v_hq   uuid;                    -- 總部 staff 的 auth_uid
  v_a    uuid; v_b uuid;          -- 兩個團
  v_r    jsonb;
begin
  select m.id, m.line_user_id, m.org_id into v_lead, v_lead_line, v_org
    from public.members m
   where m.deleted_at is null and m.line_user_id is not null
   order by m.created_at limit 1;
  select m.id, m.line_user_id into v_mem, v_mem_line
    from public.members m
   where m.deleted_at is null and m.line_user_id is not null and m.id <> v_lead
   order by m.created_at limit 1;
  select m.id into v_out from public.members m
   where m.deleted_at is null and m.id not in (v_lead, v_mem) order by m.created_at limit 1;
  select s.auth_uid into v_hq from public.staff s
   where s.deleted_at is null and s.auth_uid is not null and s.role in ('hq','owner')
   order by s.created_at limit 1;

  if v_lead is null or v_mem is null or v_out is null then
    raise exception '🔴 取樣失敗：需要三個會員（前兩個要有 line_user_id）';
  end if;
  if v_hq is null then
    raise exception '🔴 取樣失敗：找不到有 auth_uid 的總部 staff，⑦ 那格測不了';
  end if;

  /* A 團：團長 ＋ 一個團員。B 團：只有團長，另外掛一筆待審申請。 */
  insert into public.teams (org_id, name, join_policy, created_by)
  values (v_org, '驗證解散A', 'approval', v_lead) returning id into v_a;
  insert into public.teams (org_id, name, join_policy, created_by)
  values (v_org, '驗證解散B', 'approval', v_lead) returning id into v_b;
  insert into public.team_members (org_id, team_id, member_id, role)
  values (v_org, v_a, v_lead, 'leader'), (v_org, v_a, v_mem, 'member'),
         (v_org, v_b, v_lead, 'leader');
  insert into public.team_requests (org_id, team_id, member_id, kind, created_by)
  values (v_org, v_b, v_out, 'apply', v_out);

  /* ── 團長身分 ── */
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_lead_line, 'role', 'authenticated')::text, true);
  v_msg := '① 身分（應為團長本人）：'
    || case when public.current_member_id() = v_lead then '✅' else '🔴 後面都不算數' end;

  /* ② 團長解散 → 擋下，而且團要完好無損。 */
  v_r := public.disband_team_tx(v_a);
  v_msg := v_msg || E'\n② 團長解散：' || coalesce(v_r->>'message', '🔴 竟然可以')
    || case when v_r->>'reason' = 'forbidden' then ' ✅ 擋下' else ' 🔴' end
    || '（團還在嗎：'
    || (select count(*)::text from public.teams where id = v_a and deleted_at is null)
    || '，團員還在嗎：'
    || (select count(*)::text from public.team_members where team_id = v_a and left_at is null)
    || '，應為 1 與 2）';

  /* ③ 團長在多人團按退出 → 仍然要先轉讓，而那句話**不可以再叫他去解散**。 */
  v_r := public.leave_team_tx(v_a);
  v_msg := v_msg || E'\n③ 團長退出（團裡還有別人）：' || coalesce(v_r->>'message', '🔴')
    || case when v_r->>'reason' = 'leader_must_transfer' then ' ✅' else ' 🔴' end
    || case when coalesce(v_r->>'message','') like '%解散%'
            then ' 🔴 訊息還在叫他去解散' else '　（訊息沒提解散 ✅）' end;

  /* ④ 一般團員退出 → 正常，團不受影響。 */
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_mem_line, 'role', 'authenticated')::text, true);
  v_r := public.leave_team_tx(v_a);
  v_msg := v_msg || E'\n④ 一般團員退出：' || coalesce(v_r->>'message', '🔴')
    || case when (v_r->>'ok')::boolean then ' ✅' else ' 🔴' end
    || '（離開原因：'
    || coalesce((select left_reason from public.team_members
                  where team_id = v_a and member_id = v_mem and left_at is not null), '🔴')
    || '，應為 quit　團還在嗎：'
    || (select count(*)::text from public.teams where id = v_a and deleted_at is null) || '）';

  /* ⑤ 🔴 這一格是重點：團長現在是最後一個人，他必須退得出來。
     舊的寫法會在這裡撞上「只有總部可以解散」而把他鎖死。 */
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_lead_line, 'role', 'authenticated')::text, true);
  v_r := public.leave_team_tx(v_a);
  v_msg := v_msg || E'\n⑤ 團長退出（只剩他自己）：'
    || case when (v_r->>'ok')::boolean then '✅ 退得出來' else '🔴 被鎖在團裡：' || coalesce(v_r->>'message','') end
    || '（團收掉了嗎：'
    || (select count(*)::text from public.teams where id = v_a and deleted_at is not null)
    || '，應為 1　他的離開原因：'
    || coalesce((select left_reason from public.team_members
                  where team_id = v_a and member_id = v_lead), '🔴') || '）';

  /* ⑥ 一般會員不是總部（確認 can() 沒有對所有人回 true）。 */
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_mem_line, 'role', 'authenticated')::text, true);
  v_msg := v_msg || E'\n⑥ 一般會員 can(team.disband)：'
    || coalesce(public.can('team.disband')::text, '（null）')
    || case when public.can('team.disband') then ' 🔴 不該是 true' else ' ✅' end;

  /* ⑦ 🎯 正對照：總部真的解散得掉，而且連待審申請一起收乾淨。 */
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_hq::text, 'role', 'authenticated')::text, true);
  v_msg := v_msg || E'\n⑦ 總部身分：current_staff 有嗎 '
    || coalesce((select count(*)::text from public.current_staff()), '🔴')
    || '（應為 1）　current_member_id '
    || coalesce(public.current_member_id()::text, '（null，總部不是會員 ✅）');
  v_r := public.disband_team_tx(v_b);
  v_msg := v_msg || E'\n   ↳ 總部解散 B 團：'
    || case when (v_r->>'ok')::boolean then '✅ 成功' else '🔴 ' || coalesce(v_r->>'message','') end
    || '（收掉了嗎：'
    || (select count(*)::text from public.teams where id = v_b and deleted_at is not null)
    || '，應為 1　那筆待審申請：'
    || coalesce((select status from public.team_requests where team_id = v_b and member_id = v_out), '🔴')
    || '，應為 cancelled）';

  /* ⑧ 冪等：同一個團再解散一次要好好說話，不要拋錯。 */
  v_r := public.disband_team_tx(v_b);
  v_msg := v_msg || E'\n⑧ 總部再解散一次：' || coalesce(v_r->>'message', '🔴')
    || case when v_r->>'reason' = 'already_gone' then ' ✅' else ' 🔴 應為 already_gone' end;

  raise exception E'\n%\n\n（以上樣本全部回滾，一列都沒有留下）', v_msg;
end $$;
