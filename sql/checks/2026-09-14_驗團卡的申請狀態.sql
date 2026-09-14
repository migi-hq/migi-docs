/* ============================================================
   行為驗證：`_team_card` 的 `my_request` 會不會說謊
   2026-09-14
   ------------------------------------------------------------
   🔴 這一份**在交易裡造樣本**，結尾一定 `raise exception 'migi_rollback'`
     把它們全部退掉（硬規則 1.8 的判準：這份不留下任何東西 ⇒ 才准 raise）。
     DDL 那一半在 `sql/pending/2026-09-14_團卡帶我的申請狀態.sql`，
     那一份**一個 raise 都沒有**。兩份不可以合併。

   ⚠ 沒有 staging（硬規則 5.7），所以造的每一列都要靠回滾收掉 ——
     中途不要自己加 `commit`，Supabase SQL Editor 本來就是單一交易。

   身分怎麼假裝：`current_member_id()` → `migi_jwt_line_id()` →
   `auth.jwt() ->> 'sub'`（今天還沒發 Supabase JWT，sub 直接是 LINE id），
   所以 `set_config('request.jwt.claims', …)` 就能換人。
   ⚠ **用資料庫裡真的 `line_user_id`**，不要自己編一個字串 ——
     編的那個查不到會員，八格會全部「正確地」回 null，**而那看起來像通過**。
   ============================================================ */

do $$
declare
  v_msg   text := '';
  v_org   uuid;
  v_me    uuid;
  v_other uuid;
  v_line  text;
  v_team  uuid;
  v_t2    uuid;
  v_got   text;
begin
  /* ── 取樣。找不到就大聲停下，不要安靜跳過（硬規則 3.57）── */
  select m.id, m.line_user_id, m.org_id into v_me, v_line, v_org
    from public.members m
   where m.deleted_at is null and m.line_user_id is not null
   order by m.created_at limit 1;
  if v_me is null then
    raise exception '🔴 取樣失敗：找不到任何有 line_user_id 的會員，這份驗不了';
  end if;

  select m.id into v_other
    from public.members m
   where m.deleted_at is null and m.id <> v_me
   order by m.created_at limit 1;
  if v_other is null then
    raise exception '🔴 取樣失敗：只有一個會員，做不出「別人的申請」那一格';
  end if;

  /* ── 自己造團，不要借線上的（硬規則 3.57：借來的樣本會跟真實世界賽跑）── */
  insert into public.teams (org_id, name, join_policy, created_by)
  values (v_org, '驗證團A', 'approval', v_other) returning id into v_team;
  insert into public.teams (org_id, name, join_policy, created_by)
  values (v_org, '驗證團B', 'approval', v_other) returning id into v_t2;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_line, 'role', 'authenticated')::text, true);

  /* ① 前置：身分真的換過來了嗎。
     🔴 少了這一格，下面每一格都會「正確地」回空白而看起來全過。 */
  v_msg := '① 身分解析（應為我自己）：'
    || case when public.current_member_id() = v_me then '✅ 是我'
            else '🔴 解析不到我（後面每一格都不算數）' end;

  /* ② 什麼都沒有 → null。這是預設狀態，畫面要畫「申請」。 */
  v_got := public._team_card(v_team) ->> 'my_request';
  v_msg := v_msg || E'\n② 沒有任何一筆時：「' || coalesce(v_got, '（空）')
    || '」' || case when v_got is null then ' ✅' else ' 🔴 應為空' end;

  /* ③ 送出申請 → apply。畫面要畫「申請中」並且不給按。 */
  insert into public.team_requests (org_id, team_id, member_id, kind, created_by)
  values (v_org, v_team, v_me, 'apply', v_me);
  v_got := public._team_card(v_team) ->> 'my_request';
  v_msg := v_msg || E'\n③ 我送出申請之後：「' || coalesce(v_got, '（空）')
    || '」' || case when v_got = 'apply' then ' ✅' else ' 🔴 應為 apply' end;

  /* ④ 🔴 過期的那一筆要當成沒有。
     `_team_expire_requests` 是被動的，status 會一直停在 pending ——
     只看 status 的寫法會在這一格說謊（永遠「申請中」、按鈕鎖死）。 */
  update public.team_requests set expires_at = now() - interval '1 day'
   where team_id = v_team and member_id = v_me and status = 'pending';
  v_got := public._team_card(v_team) ->> 'my_request';
  v_msg := v_msg || E'\n④ 那一筆過期之後：「' || coalesce(v_got, '（空）')
    || '」' || case when v_got is null then ' ✅' else ' 🔴 應為空（它已經失效了）' end;

  /* ⑤ 已審過的（accepted／rejected）也不算「還在談」。 */
  update public.team_requests
     set status = 'rejected', decided_by = v_other, decided_at = now(),
         expires_at = now() + interval '7 days'
   where team_id = v_team and member_id = v_me;
  v_got := public._team_card(v_team) ->> 'my_request';
  v_msg := v_msg || E'\n⑤ 被拒絕之後：「' || coalesce(v_got, '（空）')
    || '」' || case when v_got is null then ' ✅' else ' 🔴 應為空' end;

  /* ⑥ 團長邀我 → invite。
     🎯 這一格是這份存在的理由之一：`apply_team_tx` 對 invite 是
       **當場入團**，所以畫面不可以寫「申請中」。 */
  insert into public.team_requests (org_id, team_id, member_id, kind, created_by)
  values (v_org, v_t2, v_me, 'invite', v_other);
  v_got := public._team_card(v_t2) ->> 'my_request';
  v_msg := v_msg || E'\n⑥ 團長邀我：「' || coalesce(v_got, '（空）')
    || '」' || case when v_got = 'invite' then ' ✅' else ' 🔴 應為 invite' end;

  /* ⑦ 「申請與邀請同時在」**資料庫層就不可能** ——
     `uq_team_request_pending (team_id, member_id) where status='pending'`。
     🎯 所以這一格驗的是那道索引還在，而不是去處理一個不會發生的情況。
     ⚠ 用 `begin…exception` 接住，不然這一格會把整份帶走。 */
  begin
    insert into public.team_requests (org_id, team_id, member_id, kind, created_by)
    values (v_org, v_t2, v_me, 'apply', v_me);
    v_msg := v_msg || E'\n⑦ 同一個團再塞第二筆 pending：🔴 竟然成功了'
      || '（uq_team_request_pending 不見了 ⇒ _team_card 要改成挑一筆）';
  exception when unique_violation then
    v_msg := v_msg || E'\n⑦ 同一個團再塞第二筆 pending：✅ 被唯一索引擋下'
      || '（所以「一個人對一個團只有一筆」是後端保證的）';
  end;

  /* ⑧ 負對照：**別人**的申請不可以算到我頭上。
     🔴 少了這一格，一支忘了比對 member_id 的實作會讓上面全部變綠。 */
  insert into public.teams (org_id, name, join_policy, created_by)
  values (v_org, '驗證團C', 'approval', v_other) returning id into v_team;
  insert into public.team_requests (org_id, team_id, member_id, kind, created_by)
  values (v_org, v_team, v_other, 'apply', v_other);
  v_got := public._team_card(v_team) ->> 'my_request';
  v_msg := v_msg || E'\n⑧ 只有別人申請的團：「' || coalesce(v_got, '（空）')
    || '」' || case when v_got is null then ' ✅' else ' 🔴 別人的申請被算到我頭上' end;

  /* ⑨ 沒登入 → null，而且不可以炸。
     ⚠ 前端的找團頁在 JWT 之前本來就可能沒有身分。 */
  perform set_config('request.jwt.claims', '', true);
  v_got := public._team_card(v_t2) ->> 'my_request';
  v_msg := v_msg || E'\n⑨ 沒登入時：「' || coalesce(v_got, '（空）')
    || '」' || case when v_got is null then ' ✅' else ' 🔴 應為空' end;

  /* ⑩ 其餘 14 個鍵沒有被我改壞（這支同時餵四支列表 RPC）。 */
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_line, 'role', 'authenticated')::text, true);
  v_msg := v_msg || E'\n⑩ 團卡鍵數：'
    || (select count(*)::text from jsonb_object_keys(public._team_card(v_t2)))
    || '（應為 15）　團名：「'
    || coalesce(public._team_card(v_t2) ->> 'name', '🔴 沒有') || '」';

  raise exception E'\n%\n\n（以上樣本全部回滾，一列都沒有留下）', v_msg;
end $$;
