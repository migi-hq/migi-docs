/* ============================================================
   驗「離開團要讓當事人知道」的行為
   2026-09-15

   ✅ **2026-09-15 跑過，9/9 全過。**
   ⚠ Supabase SQL Editor 會把它顯示成 **`ERROR: P0001`** —— 那不是失敗，
     **那就是回滾機制本身**：訊息印在錯誤裡，交易跟著被丟掉。
     這一份**每一次跑都會是紅的**，而紅色在這裡等於「東西沒留下」。
   ✅ 跑完另外查過線上（不拿自己的訊息當證據）：
     殘留的驗證團 0 ／ team_out 通知 0 ／ 被移出的紀錄 0。

   🔴 這一份**故意不留下任何東西** —— 在交易裡造樣本、跑真的 RPC、
     最後 `raise exception 'migi_rollback'` 整個退掉（硬規則 1.8 的另一半）。
     migration 那一份（sql/applied/ 或 pending/）不准有 raise，
     這一份**只能**用 raise。判準：這個檔案要不要留下東西？

   ⚠ 樣本自己造（硬規則 3.57）：團是這裡 INSERT 的，
     只有「人」借用既有的 is_test 會員當演員 —— 而借人是安全的，
     因為這份不會寫進他們身上任何東西（通知列也會跟著回滾）。
   ============================================================ */

do $$
declare
  v_msg  text := '';
  v_org  uuid;
  v_a    uuid;  v_a_line text;   -- 團長
  v_b    uuid;                   -- 被移出的人
  v_c    uuid;                   -- 解散時還在團裡的人
  v_t1   uuid := gen_random_uuid();
  v_t2   uuid := gen_random_uuid();
  v_t3   uuid := gen_random_uuid();
  /* 🔴 ⑨ 一定要用**另一個**團：團一在 ② 移出之後只剩團長一人，
     拿它去驗「退不了」會走進解散那條路，而那一格會因此永遠綠 ——
     一個永遠綠的負對照等於沒有負對照（硬規則 3.55 的反面）。 */
  v_t4   uuid := gen_random_uuid();
  v_r    jsonb;
  v_n    int;
  v_txt  text;
  v_typ  text;
begin
  /* ── 取演員。找不到要出聲，不可以安靜跳過（硬規則 3.57） ── */
  select m.id, m.org_id, m.line_user_id into v_a, v_org, v_a_line
    from public.members m
   where m.is_test and m.deleted_at is null and m.line_user_id is not null
   order by m.created_at limit 1;
  select m.id into v_b from public.members m
   where m.is_test and m.deleted_at is null and m.id <> v_a order by m.created_at limit 1;
  select m.id into v_c from public.members m
   where m.is_test and m.deleted_at is null and m.id not in (v_a, v_b) order by m.created_at limit 1;

  if v_a is null or v_b is null or v_c is null then
    raise exception '🔴 取樣失敗：需要三個有綁 LINE 的測試會員，現在湊不齊';
  end if;

  /* 用團長的身分說話 —— 兩支 RPC 都靠 current_member_id() 認人 */
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a_line, 'role', 'authenticated')::text, true);

  if public.current_member_id() is distinct from v_a then
    raise exception '🔴 身分沒切過去：current_member_id() = %，期望 %',
      public.current_member_id(), v_a;
  end if;

  /* ── 造三個團 ─────────────────────────────────────── */
  insert into public.teams (id, org_id, name, created_by) values
    (v_t1, v_org, '驗證團一', v_a), (v_t2, v_org, '驗證團二', v_a),
    (v_t3, v_org, '驗證團三', v_a), (v_t4, v_org, '驗證團四', v_a);
  insert into public.team_members (org_id, team_id, member_id, role) values
    (v_org, v_t1, v_a, 'leader'), (v_org, v_t1, v_b, 'member'),
    (v_org, v_t2, v_a, 'leader'), (v_org, v_t2, v_b, 'member'), (v_org, v_t2, v_c, 'member'),
    (v_org, v_t3, v_a, 'leader'),
    (v_org, v_t4, v_a, 'leader'), (v_org, v_t4, v_c, 'member');

  /* ── ① 正對照：動手之前，他身上一則都沒有 ──────────
     🔴 少了這一格，一支「本來就有一堆通知」的資料庫會讓 ② 假通過。 */
  select count(*) into v_n from public.app_notifications
   where member_id = v_b and type = 'team_out';
  v_msg := v_msg || case when v_n = 0 then '✅' else '🔴' end
        || ' ① 動手前 他的離團通知 ' || v_n || ' 則（期望 0）';

  /* ── ② 移出團員 → 他收到一則，而且不是借來的型別 ──── */
  v_r := public.kick_team_member_tx(v_t1, v_b);
  select count(*) into v_n from public.app_notifications
   where member_id = v_b and type = 'team_out';
  select n.payload ->> 'text', n.type into v_txt, v_typ
    from public.app_notifications n
   where n.member_id = v_b and n.type = 'team_out'
   order by n.created_at desc limit 1;

  v_msg := v_msg || E'\n' || case when (v_r ->> 'ok') = 'true' and v_n = 1 then '✅' else '🔴' end
        || ' ② 移出：RPC ' || coalesce(v_r ->> 'ok', 'null')
        || '　通知 ' || v_n || ' 則　型別 ' || coalesce(v_typ, '（沒有）')
        || E'\n      話術：' || coalesce(v_txt, '（空的）');

  /* ── ③ 話術不可以說成「他自己走的」 ────────────────
     資料層寫 kicked 就是為了不說那句話（那支函式自己的註解），
     畫面更不可以說。
     ⚠ 這一格掃的是**話術欄位**不是函式全文，所以不受硬規則 3.5 影響。 */
  v_msg := v_msg || E'\n' || case when coalesce(v_txt, '') not like '%已離開%' then '✅' else '🔴' end
        || ' ③ 話術沒有把「被移出」說成自己離開';

  /* ── ④ 離開的原因仍然分得出來（負對照：別把欄位改壞） ── */
  select left_reason into v_txt from public.team_members
   where team_id = v_t1 and member_id = v_b;
  v_msg := v_msg || E'\n' || case when v_txt = 'kicked' then '✅' else '🔴' end
        || ' ④ left_reason = ' || coalesce(v_txt, 'null') || '（不可以是自己走的那個值）';

  /* ── ⑤ 解散：還在團裡的人都收到，而按下去的人不用 ──── */
  v_r := public._team_disband(v_t2, v_a);
  select count(*) into v_n from public.app_notifications
   where member_id in (v_b, v_c) and type = 'team_out'
     and payload ->> 'team_id' = v_t2::text;
  v_msg := v_msg || E'\n' || case when v_n = 2 then '✅' else '🔴' end
        || ' ⑤ 解散：其他兩人收到 ' || v_n || ' 則（期望 2）';

  select count(*) into v_n from public.app_notifications
   where member_id = v_a and payload ->> 'team_id' = v_t2::text;
  v_msg := v_msg || E'\n' || case when v_n = 0 then '✅' else '🔴' end
        || ' ⑥ 按下去的那個人自己 ' || v_n || ' 則（期望 0 —— 不用通知他按了什麼）';

  /* ── ⑦ 一人團的團長退出：團收掉，而且沒有人要通知 ────
     這一格同時驗兩件事：那條路仍然走得通（不會被總部那道門鎖住），
     以及「沒有別人」時不會冒出一則寄給空氣的通知。 */
  v_r := public.leave_team_tx(v_t3);
  select count(*) into v_n from public.app_notifications
   where payload ->> 'team_id' = v_t3::text;
  v_msg := v_msg || E'\n' || case when (v_r ->> 'ok') = 'true' and v_n = 0 then '✅' else '🔴' end
        || ' ⑦ 一人團團長退出：RPC ' || coalesce(v_r ->> 'ok', 'null')
        || '（不可以被「只有總部可以解散」擋住）　通知 ' || v_n || ' 則（期望 0）';

  select (deleted_at is not null) into v_typ from public.teams where id = v_t3;
  v_msg := v_msg || E'\n' || case when v_typ = 'true' then '✅' else '🔴' end
        || ' ⑧ 那個團真的收掉了 = ' || coalesce(v_typ, '?');

  /* ── ⑨ 負對照：還有別人時，團長退不了（擋牆沒被弄壞） ── */
  v_r := public.leave_team_tx(v_t4);
  v_msg := v_msg || E'\n' || case when (v_r ->> 'ok') = 'false' then '✅' else '🔴' end
        || ' ⑨ 團裡還有人時團長退出 → ' || coalesce(v_r ->> 'reason', '（竟然成功了）');

  raise exception E'\n%\n\n📌 以上全部在交易內，馬上回滾，一列都不會留下。', v_msg;
end $$;
