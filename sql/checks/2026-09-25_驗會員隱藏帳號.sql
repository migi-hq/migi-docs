/* ============================================================
   驗「會員隱藏帳號」的行為（交易內造情境，最後整段回滾，一列都不留）
   2026-09-25 · 先跑 sql/pending/2026-09-25_會員隱藏帳號.sql 再跑這一份

   🔴 **故意 raise 回滾**（硬規則 1.8：這一份不要留下東西 ⇒ 才准 raise）。
     訊息設在 exception 處理器裡（硬規則 3.9），變數不會被回滾。
   ⚠ 身分用 request.jwt.claims 模擬 —— 與真的 JWT 走同一條 current_member_id()／can()。
   ⚠ 硬規則 3.57：前提在交易裡自己造（讓人離座、造一段牌咖關係），不賭線上狀態。

   E  會員身分叫總部隱藏            → forbidden
   F  總部、沒寫原因                → reason_required
   B  總部隱藏店員                  → is_staff
   C0 測試03 自己隱藏（還坐在桌上）  → in_session
   C  離座後自己隱藏                → 成功：問號、真名進保險箱、認不出身分、開機回 hidden、退團、留紀錄
   R  排名：隱藏前在榜上、隱藏後不在（前一半沒有就標 ⚪）
   K  牌咖：隱藏前看得到、隱藏後消失；對他送邀請被擋
   U  總部恢復                      → 真名與頭像回來、身分認得出來、牌咖回來
   D  再恢復一次                    → not_hidden
   M  總部隱藏測試02（有 73 點）    → 成功，**點數原封不動**（隱藏不擋也不動錢）
   ============================================================ */
do $$
declare
  v_msg text := '';
  v_out jsonb;
  v_org uuid;
  v_m02 uuid; v_m03 uuid; v_boss uuid;
  v_name text; v_src text; v_n int; v_bal bigint; v_before int;
  v_err text;
begin
  begin
    select id, org_id into v_m02, v_org from members where line_user_id = 'TEST-02' and deleted_at is null;
    select id into v_m03 from members where line_user_id = 'TEST-03' and deleted_at is null;
    select id into v_boss from members where line_user_id = 'U368caa174ee0dcef68190ed8f23b73db' and deleted_at is null;
    if v_m02 is null or v_m03 is null or v_boss is null then
      v_msg := '🔴 樣本不齊（測試02／03 或創辦人找不到），整份測不了';
      raise exception 'migi_rollback';
    end if;

    -- E
    perform set_config('request.jwt.claims', '{"sub":"TEST-02","role":"authenticated"}', true);
    v_out := public.admin_hide_member_tx(v_m03, '測試');
    v_msg := v_msg || case when v_out->>'reason' = 'forbidden'
      then '✅ E 會員身分叫不動總部隱藏' else '🔴 E 期望 forbidden，實際 ' || v_out::text end;

    -- 總部身分
    perform set_config('request.jwt.claims', '{"sub":"2485579b-966f-4da6-8ccd-d3adb7ba084b","role":"authenticated"}', true);
    v_out := public.admin_hide_member_tx(v_m03, '  ');
    v_msg := v_msg || E'\n' || case when v_out->>'reason' = 'reason_required'
      then '✅ F 沒寫原因被擋' else '🔴 F 期望 reason_required，實際 ' || v_out::text end;
    v_out := public.admin_hide_member_tx(v_boss, '驗證用');
    v_msg := v_msg || E'\n' || case when v_out->>'reason' = 'is_staff'
      then '✅ B 店員被擋：' || (v_out->>'message') else '🔴 B 期望 is_staff，實際 ' || v_out::text end;

    -- 造前提：02 與 03 互為牌咖（正對照用）；記下 03 在不在榜上
    insert into mahjong_buddies (org_id, member_id, buddy_id, origin) values (v_org, v_m02, v_m03, 'matched')
      on conflict do nothing;
    select count(*) into v_before from public.season_rank_rows_display_tx(v_org, null, null) where member_id = v_m03;

    -- C0 自己隱藏，但還坐在桌上
    perform set_config('request.jwt.claims', '{"sub":"TEST-03","role":"authenticated"}', true);
    v_out := public.hide_my_account_tx();
    v_msg := v_msg || E'\n' || case when v_out->>'reason' = 'in_session'
      then '✅ C0 在牌桌上被擋：' || (v_out->>'message')
      when coalesce((v_out->>'ok')::boolean, false) then '⚪ C0 測試03 已經不在牌桌上，這一格測不了'
      else '🔴 C0 期望 in_session，實際 ' || v_out::text end;

    update session_players sp set left_at = now()
      from table_sessions ts
     where ts.id = sp.session_id and ts.status = 'open' and sp.member_id = v_m03 and sp.left_at is null;

    -- C 真的隱藏
    v_out := public.hide_my_account_tx();
    select display_name, avatar_source into v_name, v_src from members where id = v_m03;
    select count(*) into v_n from team_members where member_id = v_m03 and left_at is null;
    v_msg := v_msg || E'\n' || case
      when coalesce((v_out->>'ok')::boolean, false)
           and v_name = '隱藏的會員' and v_src = 'hidden'
           and (select display_name from member_hidden where member_id = v_m03) = '測試03'
           and public.current_member_id() is null
           and (public.get_member_by_line_tx(v_org, 'TEST-03') ->> 'hidden')::boolean
           and v_n = 0
           and exists (select 1 from member_hide_log where member_id = v_m03 and action = 'hide' and source = 'self')
      then '✅ C 測試03 隱藏成功：別人看到問號、真名在保險箱、他自己認不出身分、開機回 hidden、已退團、有紀錄'
      else '🔴 C 不符：' || v_out::text || ' 名字=' || coalesce(v_name, 'null') || ' 頭像=' || coalesce(v_src, 'null')
           || ' 身分=' || coalesce(public.current_member_id()::text, 'null') || ' 仍在團=' || v_n end;

    -- R 排名
    select count(*) into v_n from public.season_rank_rows_display_tx(v_org, null, null) where member_id = v_m03;
    v_msg := v_msg || E'\n' || case
      when v_before = 0 then '⚪ R 測試03 本來就不在榜上（沒有已結算的牌局），這一格測不了'
      when v_n = 0 then '✅ R 隱藏前在榜上、隱藏後消失'
      else '🔴 R 隱藏後還在榜上' end;

    -- K 牌咖
    perform set_config('request.jwt.claims', '{"sub":"TEST-02","role":"authenticated"}', true);
    select count(*) into v_n from jsonb_array_elements(public.list_buddies_tx(v_org, v_m02)) e
     where e->>'id' = v_m03::text;
    v_err := null;
    begin
      perform public.send_buddy_invite_tx(v_org, v_m02, v_m03);
    exception when others then v_err := sqlerrm;
    end;
    v_msg := v_msg || E'\n' || case when v_n = 0 and v_err like '%無法加為牌咖%'
      then '✅ K 牌咖名單裡消失，對他送邀請被擋'
      else '🔴 K 名單裡還有 ' || v_n || ' 筆／邀請：' || coalesce(v_err, '沒有被擋') end;

    -- U 總部恢復
    perform set_config('request.jwt.claims', '{"sub":"2485579b-966f-4da6-8ccd-d3adb7ba084b","role":"authenticated"}', true);
    v_out := public.admin_unhide_member_tx(v_m03, '驗證用');
    select display_name, avatar_source into v_name, v_src from members where id = v_m03;
    perform set_config('request.jwt.claims', '{"sub":"TEST-02","role":"authenticated"}', true);
    select count(*) into v_n from jsonb_array_elements(public.list_buddies_tx(v_org, v_m02)) e
     where e->>'id' = v_m03::text;
    perform set_config('request.jwt.claims', '{"sub":"TEST-03","role":"authenticated"}', true);
    v_msg := v_msg || E'\n' || case
      when coalesce((v_out->>'ok')::boolean, false) and v_name = '測試03' and v_src <> 'hidden'
           and not exists (select 1 from member_hidden where member_id = v_m03)
           and public.current_member_id() = v_m03 and v_n = 1
      then '✅ U 恢復成功：真名與頭像回來、保險箱清空、身分認得出來、牌咖回來'
      else '🔴 U 不符：' || v_out::text || ' 名字=' || coalesce(v_name, 'null') || ' 牌咖=' || v_n end;

    -- D
    perform set_config('request.jwt.claims', '{"sub":"2485579b-966f-4da6-8ccd-d3adb7ba084b","role":"authenticated"}', true);
    v_out := public.admin_unhide_member_tx(v_m03, '驗證用');
    v_msg := v_msg || E'\n' || case when v_out->>'reason' = 'not_hidden'
      then '✅ D 沒被隱藏的人再恢復一次回 not_hidden' else '🔴 D 期望 not_hidden，實際 ' || v_out::text end;

    -- M 有點數也能隱藏，而且點數不動
    /* 🔴 2026-09-25 第一次跑這一格是紅的：測試02 還坐在 A1／A2／A3 三張開著的桌上，
       被 in_session 擋下 —— **擋對了，錯的是樣本沒先離座**（硬規則 3.57）。 */
    update session_players sp set left_at = now()
      from table_sessions ts
     where ts.id = sp.session_id and ts.status = 'open' and sp.member_id = v_m02 and sp.left_at is null;
    select balance into v_bal from wallets where member_id = v_m02;
    v_out := public.admin_hide_member_tx(v_m02, '驗證用');
    v_msg := v_msg || E'\n' || case
      when coalesce((v_out->>'ok')::boolean, false)
           and (select balance from wallets where member_id = v_m02) = v_bal
      then '✅ M 測試02（' || v_bal || ' 點）隱藏成功，點數原封不動'
      else '🔴 M 不符：' || v_out::text end;

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_msg := v_msg || E'\n🔴 中途例外：' || sqlerrm;
    end if;
    perform set_config('migi.v', v_msg || E'\n（以上全部回滾，線上一列都沒動）', true);
  end;
end $$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有訊息') as "驗證";
