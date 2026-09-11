/* ============================================================
   驗牌咖團的加入流程與治理：**真的用四個人的身分走一遍**
   2026-09-11 · 在交易裡建團、申請、核准、轉讓、接管、解散，最後整份回滾

   ── 為什麼非要這一份不可（硬規則 7）──────────────
   `2026-09-11_牌咖團函式_加入與治理.sql` 的驗證段只證明
   「函式建立了、授權對了、權限判斷會擋」。**那證明不了它做對事。**
   `CREATE FUNCTION` 不檢查函式體裡的欄位存不存在 ——
   `dev_reset_test_data_tx` 從建立以來一次都沒成功執行過，卻被當成完成。

   而這一批特別需要真的跑，因為它有**四種不會報錯的錯**：
   ```
   ① 名冊把 member_id 交給非團長   → 等於公開發送通行證，而畫面完全正常
   ② 轉讓團長順序寫反             → 撞部分唯一索引，但**要看資料列順序**
                                     ⇒ 在某些資料上通過、某些資料上失敗
   ③ 失聯接管沒判「年資最久」      → 團長一失聯就被新人搶走
   ④ 解散只做一半                 → 團刪了而團員還掛在上面
   ```

   ── 這份會寫入，但一列都留不下來 ─────────────────
   `raise exception 'migi_rollback'`。🔴 訊息一定要設在 exception handler
   裡（硬規則 3.9），寫在 raise 之前會跟著被回滾。
   ⚠ 這份**不歸檔到 `applied/`**。

   ── 身分靠 `request.jwt.claims` 切換 ─────────────────
   模擬的是今天的形狀：還沒發 Supabase JWT 時 `sub` 直接就是 LINE user id
   （`migi_jwt_line_id()` 的第 ② 條路）。四個會員都綁了 LINE，實查過。
   🔴 不切身分就測不到任何權限判斷 —— 而權限判斷正是這一批的重點。
   ============================================================ */

/* 通知的基準筆數，最後一格拿它比對（不可以寫死數字）。 */
select set_config('migi.noti0',
       (select count(*)::text from public.app_notifications), true);

do $$
declare
  v_msg  text := '';
  v_a    uuid; v_la text;   -- 團長
  v_b    uuid; v_lb text;
  v_c    uuid; v_lc text;
  v_d    uuid; v_ld text;
  v_team uuid;
  v_req  uuid;
  v_r    jsonb;
  v_n    int;
  v_txt  text;
begin
  begin
    /* ── 取樣：四個綁了 LINE 的會員（依建立時間，答案是唯一的）── */
    select m.id, m.line_user_id into v_a, v_la from public.members m
     where m.line_user_id is not null and m.deleted_at is null
     order by m.created_at offset 0 limit 1;
    select m.id, m.line_user_id into v_b, v_lb from public.members m
     where m.line_user_id is not null and m.deleted_at is null
     order by m.created_at offset 1 limit 1;
    select m.id, m.line_user_id into v_c, v_lc from public.members m
     where m.line_user_id is not null and m.deleted_at is null
     order by m.created_at offset 2 limit 1;
    select m.id, m.line_user_id into v_d, v_ld from public.members m
     where m.line_user_id is not null and m.deleted_at is null
     order by m.created_at offset 3 limit 1;

    if v_d is null then
      v_msg := '🔴 取樣失敗：需要四個綁了 LINE 的會員，這份測不了';
      raise exception 'migi_rollback';
    end if;

    /* ── ① A 建團 ──────────────────────────────────── */
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_la, 'role', 'authenticated')::text, true);
    v_r := public.create_team_tx('＿探針團＿加入', '🐻', '這是測試', 'approval', null);
    v_team := (v_r->'team'->>'id')::uuid;
    v_msg := v_msg || case when (v_r->>'ok')::boolean and v_r->>'my_role' = 'leader'
      then '① ✅ 建團成功，建的人就是團長'
      else '① 🔴 建團失敗：' || coalesce(v_r::text,'null') end;
    if v_team is null then raise exception 'migi_rollback'; end if;

    /* ── ② 同名再建一次要被擋（唯一索引，不是先查再插）─ */
    v_r := public.create_team_tx('＿探針團＿加入', null, null, 'open', null);
    v_msg := v_msg || E'\n' || case when coalesce(v_r->>'reason','') = 'name_taken'
      then '② ✅ 同名團被擋下來了'
      else '② 🔴 同名團建出來了：' || coalesce(v_r::text,'null') end;

    /* ── ③ B 申請加入 ────────────────────────────── */
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_lb, 'role', 'authenticated')::text, true);
    v_r := public.apply_team_tx(v_team);
    v_req := (v_r->>'request_id')::uuid;
    v_msg := v_msg || E'\n' || case
      when (v_r->>'ok')::boolean and (v_r->>'joined')::boolean = false and v_req is not null
      then '③ ✅ B 送出申請（approval 的團不會直接加入）'
      else '③ 🔴 申請的結果不對：' || coalesce(v_r::text,'null') end;

    /* ── ④ 團長收到 team_req 通知 ──────────────────── */
    select count(*) into v_n from public.app_notifications n
     where n.member_id = v_a and n.type = 'team_req' and n.ref_id = v_req;
    v_msg := v_msg || E'\n' || case when v_n = 1
      then '④ ✅ 團長收到一則 team_req，ref_id 指向那筆申請'
      else '④ 🔴 團長的 team_req 有 ' || v_n || ' 則，預期 1' end;

    /* ── ⑤ 非團長不能核准 ──────────────────────────── */
    /* 🔴 這一格與 ⑥ 缺一不可：只驗「團長核准得了」的話，
       一支**完全不判斷身分**的實作也會通過（硬規則 3.55）。 */
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_lc, 'role', 'authenticated')::text, true);
    v_r := public.respond_team_request_tx(v_req, true);
    v_msg := v_msg || E'\n' || case when coalesce(v_r->>'reason','') = 'not_leader'
      then '⑤ ✅ 別人核准不了 B 的申請'
      else '⑤ 🔴 非團長核准成功了：' || coalesce(v_r::text,'null') end;

    /* ── ⑥ 團長核准，B 入團 ────────────────────────── */
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_la, 'role', 'authenticated')::text, true);
    v_r := public.respond_team_request_tx(v_req, true);
    select count(*) into v_n from public.team_members tm
     where tm.team_id = v_team and tm.member_id = v_b and tm.left_at is null;
    v_msg := v_msg || E'\n' || case when (v_r->>'ok')::boolean and v_n = 1
      then '⑥ ✅ 團長核准後 B 真的進團了'
      else '⑥ 🔴 核准回 ' || coalesce(v_r::text,'null') || '，B 在團裡的列數 ' || v_n end;

    /* ── ⑦ 名冊：團長拿得到 member_id，團員拿不到 ───── */
    /* 🔴 這是 2026-09-04 排行榜定下的原則：不需要身分就不要交出身分。
       而它**只有真的呼叫才驗得出來** —— 讀函式定義看不出前端拿到什麼。 */
    v_r := public.get_team_tx(v_team);
    v_n := case when v_r->'members'->0->>'member_id' is not null then 1 else 0 end;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_lb, 'role', 'authenticated')::text, true);
    v_r := public.get_team_tx(v_team);
    v_msg := v_msg || E'\n' || case
      when v_n = 1 and v_r->'members'->0->>'member_id' is null
      then '⑦ ✅ 團長的名冊帶 member_id，團員的名冊不帶'
      when v_n = 0
      then '⑦ 🔴 連團長都拿不到 member_id —— 移除與轉讓會按不下去'
      else '⑦ 🔴 一般團員也拿得到 member_id —— 等於公開發送通行證' end;

    /* ── ⑧ 申請與邀請撞在一起 → 直接成交 ───────────── */
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_lc, 'role', 'authenticated')::text, true);
    perform public.apply_team_tx(v_team);
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_la, 'role', 'authenticated')::text, true);
    v_r := public.invite_to_team_tx(v_team, v_c);
    v_msg := v_msg || E'\n' || case
      when (v_r->>'ok')::boolean and (v_r->>'joined')::boolean and v_r->>'via' = 'apply'
      then '⑧ ✅ 他已經在申請時，團長按邀請＝直接成交（不是報「已經有一筆在談」）'
      else '⑧ 🔴 撞在一起的處理不對：' || coalesce(v_r::text,'null') end;

    /* ── ⑨ 過期的申請不可以還能核准 ────────────────── */
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_ld, 'role', 'authenticated')::text, true);
    v_r := public.apply_team_tx(v_team);
    v_req := (v_r->>'request_id')::uuid;
    update public.team_requests set expires_at = now() - interval '1 day' where id = v_req;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_la, 'role', 'authenticated')::text, true);
    v_r := public.respond_team_request_tx(v_req, true);
    v_msg := v_msg || E'\n' || case when v_r->>'status' = 'expired'
      then '⑨ ✅ 過期的申請核准不了，而且話術說得出「已經過期」'
      else '⑨ 🔴 過期的申請還能處理：' || coalesce(v_r::text,'null') end;

    /* ── ⑩ 團長不能直接退團 ────────────────────────── */
    /* 🔴 讓他走的話那個團會變成沒有團長的團 ——
       沒有人能審核、沒有人能改名，而畫面上完全看不出來。 */
    v_r := public.leave_team_tx(v_team);
    v_msg := v_msg || E'\n' || case when coalesce(v_r->>'reason','') = 'leader_must_transfer'
      then '⑩ ✅ 團長要先轉讓或解散，不能直接退'
      else '⑩ 🔴 團長直接退掉了：' || coalesce(v_r::text,'null') end;

    /* ── ⑪ 移除要寫 kicked，不可以寫 quit ──────────── */
    v_r := public.kick_team_member_tx(v_team, v_b);
    select tm.left_reason into v_txt from public.team_members tm
     where tm.team_id = v_team and tm.member_id = v_b order by tm.joined_at desc limit 1;
    v_msg := v_msg || E'\n' || case when (v_r->>'ok')::boolean and v_txt = 'kicked'
      then '⑪ ✅ 移除寫的是 kicked（不是 quit —— 那會讓欄位說一件沒發生的事）'
      else '⑪ 🔴 移除的結果：' || coalesce(v_r::text,'null') || '，離開理由＝' || coalesce(v_txt,'null') end;

    /* ── ⑫ 轉讓團長：一團仍然只有一個團長 ──────────── */
    v_r := public.transfer_team_leader_tx(v_team, v_c);
    select count(*) into v_n from public.team_members tm
     where tm.team_id = v_team and tm.role = 'leader' and tm.left_at is null;
    select tm.role into v_txt from public.team_members tm
     where tm.team_id = v_team and tm.member_id = v_a and tm.left_at is null;
    v_msg := v_msg || E'\n' || case when (v_r->>'ok')::boolean and v_n = 1 and v_txt = 'member'
      then '⑫ ✅ 轉讓後只有一個團長，原團長降成團員'
      else '⑫ 🔴 轉讓的結果：' || coalesce(v_r::text,'null')
           || '，團長數 ' || v_n || '，原團長角色＝' || coalesce(v_txt,'null') end;

    /* ── ⑬ 團長還活著時接管不了 ────────────────────── */
    v_r := public.claim_team_leader_tx(v_team);
    v_msg := v_msg || E'\n' || case when coalesce(v_r->>'reason','') = 'leader_active'
      then '⑬ ✅ 團長還在活動中，接管被擋下來'
      else '⑬ 🔴 活著的團長被接管了：' || coalesce(v_r::text,'null') end;

    /* ── ⑭ 團長失聯 100 天 → 年資最久的接任 ────────── */
    /* ⚠ 兩個欄位都要推老。只推 App 那個的話，
       「常來店但不開 App」的團長會被誤判失聯，而那正是老闆型團長的樣子。 */
    update public.members
       set last_app_active_at = now() - interval '100 days',
           last_visit_at      = now() - interval '100 days'
     where id = v_c;
    v_r := public.claim_team_leader_tx(v_team);
    select tm.role into v_txt from public.team_members tm
     where tm.team_id = v_team and tm.member_id = v_a and tm.left_at is null;
    v_msg := v_msg || E'\n' || case when (v_r->>'ok')::boolean and v_txt = 'leader'
      then '⑭ ✅ 團長失聯 100 天，團裡待最久的 A 接任成功'
      else '⑭ 🔴 接管的結果：' || coalesce(v_r::text,'null') || '，A 現在是 ' || coalesce(v_txt,'null') end;

    /* ── ⑮ 不是年資最久的人接管不了 ────────────────── */
    /* 🔴 少了這一格，一支「誰先按誰接任」的實作會讓 ⑭ 照樣變綠 ——
       而那等於團長一失聯就被新人搶走。

       ⚠ 2026-09-11 第一次跑時這一格報紅，而**函式完全正確，錯的是前提**：
         走到這裡時團裡只有 A（團長）與 C，C 就是唯一的非團長
         ⇒ 他本來就是「年資最久的非團長」⇒ 讓他接管是對的。
         **要測這件事，團裡至少要有兩個非團長。**

       🔴 而更根本的一個坑：**`now()` 在一個交易裡是常數。**
         所有 `joined_at` 的預設值在這份腳本裡完全相同 ⇒ 年資全部同分
         ⇒ 比較只會落到 `member_id` 的 uuid 順序去，
         **而那會讓這一格在不同資料上給出不同結果**。
         ⇒ 年資一定要明著設，不可以靠插入的先後。 */

    -- 先讓團裡有第二個非團長（D 在 ⑨ 那筆過期了，重來一次）
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_ld, 'role', 'authenticated')::text, true);
    v_r := public.apply_team_tx(v_team);
    v_req := (v_r->>'request_id')::uuid;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_la, 'role', 'authenticated')::text, true);
    perform public.respond_team_request_tx(v_req, true);

    -- 明著把年資拉開：C 早三十天，D 只有一天
    update public.team_members set joined_at = now() - interval '30 days'
     where team_id = v_team and member_id = v_c and left_at is null;
    update public.team_members set joined_at = now() - interval '1 day'
     where team_id = v_team and member_id = v_d and left_at is null;

    -- 現任團長 A 失聯
    update public.members
       set last_app_active_at = now() - interval '100 days',
           last_visit_at      = now() - interval '100 days'
     where id = v_a;

    -- D 是最晚加入的，不可以接管
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_ld, 'role', 'authenticated')::text, true);
    v_r := public.claim_team_leader_tx(v_team);
    v_msg := v_msg || E'\n' || case when coalesce(v_r->>'reason','') = 'not_eligible'
      then '⑮ ✅ 最晚加入的人接管不了（要由團裡待最久的那位接任）'
      else '⑮ 🔴 任何人都能接管：' || coalesce(v_r::text,'null') end;

    /* ⚠ 刻意**不**接著讓 C 成功接管 —— ⑭ 已經驗過成功那一半，
       而讓團長在這裡換人會把 ⑯ 的前提抽掉（第一次跑就是這樣連錯三格）。
       🎯 同硬規則 3.57：每一格開始前重建自己的前提。 */

    /* ── ⑯ 解散要一次做完三件事 ────────────────────── */
    /* ⚠ **現任團長是誰，自己查**，不要沿用上面某一格留下的假設 ——
       第一次跑就是因為 ⑮ 換掉了團長，這一格拿舊身分去解散，
       回 `not_leader` 什麼也沒做，然後 ⑯⑰ 一起變紅。 */
    select m.line_user_id into v_txt
      from public.team_members tm join public.members m on m.id = tm.member_id
     where tm.team_id = v_team and tm.role = 'leader' and tm.left_at is null;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_txt, 'role', 'authenticated')::text, true);
    v_r := public.disband_team_tx(v_team);
    select count(*) into v_n from public.team_members tm
     where tm.team_id = v_team and tm.left_at is null;
    v_msg := v_msg || E'\n' || case
      when (v_r->>'ok')::boolean
       and v_n = 0
       and (select deleted_at from public.teams where id = v_team) is not null
       and not exists (select 1 from public.team_requests r
                        where r.team_id = v_team and r.status = 'pending')
      then '⑯ ✅ 解散做完三件事：團刪了、所有人離開了、還在談的都取消了'
      else '⑯ 🔴 解散只做了一半 —— 還在團的人 ' || v_n
           || '，團的刪除時間＝' || coalesce((select deleted_at::text from public.teams where id = v_team),'null') end;

    /* ── ⑰ 解散之後那個團名可以再用 ────────────────── */
    /* ⚠ `uq_teams_name` 帶 `where deleted_at is null`，所以應該放得出來。
       放不出來的話，解散過的團名會永久佔位而且沒有人查得出原因。 */
    v_r := public.create_team_tx('＿探針團＿加入', null, null, 'open', null);
    v_msg := v_msg || E'\n' || case when (v_r->>'ok')::boolean
      then '⑰ ✅ 解散之後同名團建得起來（團名沒有被永久佔住）'
      else '⑰ 🔴 解散過的團名還被佔著：' || coalesce(v_r->>'reason','null') end;

    raise exception 'migi_rollback';

  exception when others then
    /* ⚠ 只有自己丟的那個字串是「刻意回滾」。其餘一律當成真的錯誤 ——
       一律吞掉的話，「腳本寫錯」會偽裝成「函式寫錯」。 */
    if sqlerrm <> 'migi_rollback' then
      v_msg := v_msg || E'\n🔴 中途拋出例外：' || sqlerrm;
    end if;
    perform set_config('request.jwt.claims', '', true);
    perform set_config('migi.chk', v_msg, true);
  end;
end $$;

/* ⚠ 交易外的真實狀態。這一段不是形式：
   🔴 ⑭⑮ 真的改過 `members.last_app_active_at` —— 那是**正式資料庫**
     （沒有 staging），沒退掉的話兩個會員會憑空變成「100 天沒來」，
     而那會讓日後的流失分析與失聯接管都算錯。 */
select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息')
       || E'\n\n── 回滾確認（交易外的真實狀態）──'
       || E'\n⑱ ' || case
            when (select count(*) from public.teams) = 0
             and (select count(*) from public.team_members) = 0
             and (select count(*) from public.team_requests) = 0
            then '✅ 團、團員、申請三張表都沒有留下東西'
            else '🔴 留下了 teams ' || (select count(*)::text from public.teams)
                 || ' · members ' || (select count(*)::text from public.team_members)
                 || ' · requests ' || (select count(*)::text from public.team_requests) end
       || E'\n⑲ ' || case
            when (select count(*)::text from public.app_notifications)
                 = current_setting('migi.noti0', true)
            then '✅ 通知筆數還是跑之前那個數字（'
                 || current_setting('migi.noti0', true) || ' 筆）'
            else '🔴 通知從 ' || coalesce(current_setting('migi.noti0', true),'?')
                 || ' 變成 ' || (select count(*)::text from public.app_notifications) end
       || E'\n⑳ ' || case
            when (select count(*) from public.members
                   where last_app_active_at < now() - interval '90 days') = 0
            then '✅ 沒有任何會員被留在「100 天沒來」的狀態（⑭⑮ 那兩個 update 退掉了）'
            else '🔴 有 ' || (select count(*)::text from public.members
                              where last_app_active_at < now() - interval '90 days')
                 || ' 個會員的最後活動時間被改壞了 —— 立刻查 members.updated_at' end
       as "驗證";
