/* ============================================================
   驗「店員移除／移動配桌成員」的行為　2026-09-10
   ============================================================
   搭配 `sql/applied/2026-09-10_店員移除與移動配桌成員.sql`。

   🔴 **為什麼要分成兩份檔案**（硬規則 1.8 的判準）：
     那一份要**留下東西**（DDL）⇒ 一個字都不准 raise。
     這一份要**造樣本測行為**⇒ 非回滾不可 ⇒ 只能 raise。
     判準是「這份檔案要不要留下東西」，不是「要不要印訊息」。

   ✅ **這份跑完資料庫一列都不會多**（結尾 raise 'migi_rollback'）。
   ⚠ 訊息設在 exception handler 裡，不是設完再 raise ——
     `set_config(..., true)` 會跟著 savepoint 一起被回滾（硬規則 3.9）。

   ⚠ 樣本是**在交易裡自己造的**，不是挑線上最新的那一筆（硬規則 3.57）——
     借線上資料的驗證會跟真實世界賽跑，2026-09-06 連紅四次都是這個原因。
     唯一借的是「四個身上沒有進行中的房的測試會員」，找不到會出聲。

   🎯 **身分是假造的 JWT**：SQL Editor 跑起來是 postgres，
     `auth.jwt()` 是空的 ⇒ `current_staff()` 回 0 列 ⇒ 每一格都會是
     `not_staff`，而**那看起來會像擋牆全部生效**。
     所以第 ① 格刻意先在「沒有身分」的狀態下叫一次當**負對照**，
     再把身分種進去。
   ============================================================ */
do $$
declare
  v_msg text := '';
  v_org uuid; v_store uuid; v_stake uuid; v_staff uuid;
  v_m1 uuid; v_m2 uuid; v_m3 uuid; v_m4 uuid;
  v_q1 uuid; v_q2 uuid; v_q3 uuid;
  v_r jsonb; v_txt text; v_n int; v_uuid uuid; v_src1 text; v_src2 text;
begin
  /* ── 前置：撈出這次要用的東西，一個都不可以寫死 ────────────
     2026-09-01 就是照抄文件裡的會員 id，結果把三場戰績造給錯的帳號，
     而畫面上什麼都沒變。 */
  select s.id, s.org_id into v_staff, v_org
    from staff s where s.deleted_at is null and s.auth_uid is not null
    order by case s.role when 'hq' then 1 when 'owner' then 1 else 2 end limit 1;
  select id into v_store from stores where org_id = v_org order by created_at limit 1;
  select id into v_stake from stake_levels where org_id = v_org order by created_at limit 1;

  if v_staff is null or v_store is null or v_stake is null then
    v_msg := '🔴 前置資料不齊（店員／門市／積分級距）—— 這份沒有跑';
    perform set_config('migi.chk', v_msg, true);
    return;
  end if;

  /* 只挑「身上沒有任何進行中的房」的測試會員 —— 否則
     `_check_join_conflict` 會咬我自己的樣本，而症狀看起來會像函式壞了。 */
  create temp table _free on commit drop as
  select m.id, row_number() over (order by m.created_at) rn
    from members m
   where m.deleted_at is null and m.is_test
     and not exists (
       select 1 from match_queue_players qp join match_queues q on q.id = qp.queue_id
        where qp.member_id = m.id and qp.left_at is null
          and (q.status in ('waiting','matched')
               or (q.status = 'seated' and migi_seat_is_live(q.matched_session_id))));

  select count(*) into v_n from _free;
  if v_n < 4 then
    /* ⚠ 找不到樣本要**出聲**，不要 if…then 安靜跳過 ——
       2026-09-04 那次兩格沒出現，我以為全過。 */
    v_msg := '🔴 只找到 ' || v_n || ' 個沒有進行中房間的測試會員（要 4 個）—— 這份沒有跑';
    perform set_config('migi.chk', v_msg, true);
    return;
  end if;
  select id into v_m1 from _free where rn = 1;
  select id into v_m2 from _free where rn = 2;
  select id into v_m3 from _free where rn = 3;
  select id into v_m4 from _free where rn = 4;

  begin
    /* ── ① 負對照：沒有店員身分時，兩支都不該動作 ───────────
       ⚠ 這一格必須在種身分**之前**跑。 */
    perform set_config('request.jwt.claims', '', true);

    insert into match_queues(org_id, store_id, stake_level_id, game_type, flower,
                             seats, status, opened_by, play_at, source)
    values (v_org, v_store, v_stake, '台麻', '無花', 4, 'waiting', v_m1,
            now() + interval '3 days', 'pos')
    returning id into v_q1;
    insert into match_queue_players(org_id, queue_id, member_id, join_source, joined_at)
    values (v_org, v_q1, v_m1, 'pos_walkin', now() - interval '3 minutes'),
           (v_org, v_q1, v_m2, 'browse',     now() - interval '2 minutes'),
           (v_org, v_q1, v_m3, 'pos_walkin', now() - interval '1 minutes');

    v_r := pos_remove_queue_member_tx(v_org, v_q1, v_m3);
    v_msg := v_msg || case when v_r->>'reason' = 'not_staff'
      then '① ✅ 沒有店員身分時擋下來了（' || (v_r->>'reason') || '）'
      else '① 🔴 沒有身分也做得動：' || v_r::text end;

    /* 種進總部那個 staff 的身分。走的是 auth_uid 那條路。 */
    perform set_config('request.jwt.claims',
      json_build_object('sub', (select auth_uid from staff where id = v_staff),
                        'role', 'authenticated')::text, true);
    select staff_id into v_uuid from current_staff();
    v_msg := v_msg || E'\n' || case when v_uuid = v_staff
      then '①b ✅ 假造的身分解析得出來（' || coalesce((select name from staff where id = v_staff), '?') || '）'
      else '①b 🔴 身分種不進去 —— 下面每一格都會是 not_staff，不要相信它們' end;

    /* ── ② 移除一個人：三個欄位都要對 ─────────────────── */
    v_r := pos_remove_queue_member_tx(v_org, v_q1, v_m3, '客人臨時說不打了');
    select count(*) into v_n from match_queue_players
     where queue_id = v_q1 and member_id = v_m3
       and left_at is not null and leave_reason = 'staff_removed'
       and left_by_staff_id = v_staff and leave_detail = '客人臨時說不打了';
    v_msg := v_msg || E'\n' || case
      when coalesce((v_r->>'ok')::boolean, false) and (v_r->>'players')::int = 2 and v_n = 1
      then '② ✅ 移除成功，剩 2 人；分類、操作者、細節三欄都寫對了'
      else '② 🔴 ' || v_r::text || '（欄位對得上的列數 ' || v_n || '，期望 1）' end;

    /* ── ③ 房主被移除 → 轉給最早加入的人 ─────────────────
       ⚠ 期望值是「最早 joined_at 的那一個」＝ v_m2（上面刻意錯開了時間）。 */
    v_r := pos_remove_queue_member_tx(v_org, v_q1, v_m1);
    select opened_by into v_uuid from match_queues where id = v_q1;
    v_msg := v_msg || E'\n' || case when v_uuid = v_m2
      then '③ ✅ 房主被移除後，房主轉給最早加入的人'
      else '③ 🔴 房主沒轉對：' || coalesce(v_uuid::text, 'null') || '（期望最早那位）' end;

    /* ── ④ 移動：來源清空 → 房取消；入場來源不可以被改寫 ────── */
    insert into match_queues(org_id, store_id, stake_level_id, game_type, flower,
                             seats, status, opened_by, play_at, source)
    values (v_org, v_store, v_stake, '台麻', '無花', 4, 'waiting', v_m4,
            now() + interval '3 days', 'pos')
    returning id into v_q2;
    insert into match_queue_players(org_id, queue_id, member_id, join_source)
    values (v_org, v_q2, v_m4, 'pos_walkin');

    select join_source into v_src1 from match_queue_players
     where queue_id = v_q1 and member_id = v_m2 and left_at is null;
    v_r := pos_move_queue_member_tx(v_org, v_q1, v_q2, v_m2);
    select join_source into v_src2 from match_queue_players
     where queue_id = v_q2 and member_id = v_m2 and left_at is null;
    select status into v_txt from match_queues where id = v_q1;
    select count(*) into v_n from match_queue_players
     where queue_id = v_q1 and member_id = v_m2 and leave_reason = 'switched'
       and left_by_staff_id = v_staff;

    v_msg := v_msg || E'\n' || case
      when coalesce((v_r->>'ok')::boolean, false) and v_txt = 'cancelled' and v_n = 1
      then '④ ✅ 移動成功；來源房沒人了就取消，來源那一列記成「被移到別的房」'
      else '④ 🔴 ' || v_r::text || '（來源房 ' || coalesce(v_txt,'?') || '、switched 列數 ' || v_n || '）' end;
    /* 🎯 這一格單獨拉出來：入場來源被改寫是**不會報錯**的那一種錯，
       症狀是三個月後「現場登記 vs App 報名」的比例莫名其妙。 */
    v_msg := v_msg || E'\n' || case when v_src2 = v_src1 and v_src1 is not null
      then '④b ✅ 入場來源保住了（' || v_src1 || ' → ' || v_src2 || '）'
      else '④b 🔴 入場來源被改掉：' || coalesce(v_src1,'null') || ' → ' || coalesce(v_src2,'null') end;

    /* ── ⑤ 移到同一個房 ─────────────────────────────── */
    v_r := pos_move_queue_member_tx(v_org, v_q2, v_q2, v_m2);
    v_msg := v_msg || E'\n' || case when v_r->>'reason' = 'same_queue'
      then '⑤ ✅ 移到同一個房被擋下'
      else '⑤ 🔴 ' || v_r::text end;

    /* ── ⑥ 使用者那條規則：成桌之後兩支都不能動 ────────────── */
    update match_queues set status = 'matched' where id = v_q2;
    v_r := pos_remove_queue_member_tx(v_org, v_q2, v_m4);
    v_txt := v_r->>'reason';
    v_r := pos_move_queue_member_tx(v_org, v_q2, v_q1, v_m4);
    v_msg := v_msg || E'\n' || case
      when v_txt = 'not_waiting' and v_r->>'reason' = 'from_not_waiting'
      then '⑥ ✅ 成桌之後移除與移動都被擋下（成桌前才能動）'
      else '⑥ 🔴 移除回 ' || coalesce(v_txt,'?') || '、移動回 ' || coalesce(v_r->>'reason','?') end;
    update match_queues set status = 'waiting' where id = v_q2;

    /* ── ⑦ 目標房已經滿了 ───────────────────────────── */
    insert into match_queues(org_id, store_id, stake_level_id, game_type, flower,
                             seats, status, play_at, source)
    values (v_org, v_store, v_stake, '台麻', '無花', 2, 'waiting',
            now() + interval '3 days', 'pos')
    returning id into v_q3;
    insert into match_queue_players(org_id, queue_id, member_id, join_source, joined_at)
    values (v_org, v_q3, v_m1, 'browse', now() - interval '2 minutes'),
           (v_org, v_q3, v_m3, 'browse', now() - interval '1 minutes');

    v_r := pos_move_queue_member_tx(v_org, v_q2, v_q3, v_m2);
    select count(*) into v_n from match_queue_players
     where queue_id = v_q2 and member_id = v_m2 and left_at is null;
    /* 🔴 第二個條件才是重點：被擋下時**不可以留下半筆帳**。
       只驗 reason 的話，一支「先把人踢出來源房才發現目標滿了」的實作
       也會全綠。 */
    v_msg := v_msg || E'\n' || case when v_r->>'reason' = 'to_full' and v_n = 1
      then '⑦ ✅ 目標房滿了擋下來，而且人還好好留在原本的房'
      else '⑦ 🔴 ' || v_r::text || '（人還在原房的列數 ' || v_n || '，期望 1）' end;

    /* ── ⑧ 移除一個不在那個房裡的人 ───────────────────── */
    v_r := pos_remove_queue_member_tx(v_org, v_q3, v_m4);
    v_msg := v_msg || E'\n' || case when v_r->>'reason' = 'not_in'
      then '⑧ ✅ 移除不在房裡的人 → not_in（不是假裝成功）'
      else '⑧ 🔴 ' || v_r::text end;

    /* ── ⑨ 空出一個位子 ───────────────────────────── */
    v_r := pos_remove_queue_member_tx(v_org, v_q3, v_m3);
    v_msg := v_msg || E'\n' || case
      when coalesce((v_r->>'ok')::boolean, false) and (v_r->>'players')::int = 1
      then '⑨ ✅ 移除後目標房剩 1 人（2 個位子）'
      else '⑨ 🔴 ' || v_r::text end;

    /* ── ⑩ 正對照：移動把目標房補滿 → 走既有的成桌那條路 ──────
       ⚠ 這一格是整份的正對照。少了它，一支**永遠回 ok:false**
         的實作在 ①⑤⑥⑦⑧ 全部都會是綠的。 */
    v_r := pos_move_queue_member_tx(v_org, v_q2, v_q3, v_m2);
    select status into v_txt from match_queues where id = v_q3;
    v_msg := v_msg || E'\n' || case
      when coalesce((v_r->>'full')::boolean, false) and v_txt in ('matched','seated')
      then '⑩ ✅ 移動把房補滿 → 成桌（現在是 ' || v_txt || '）'
      else '⑩ 🔴 ' || v_r::text || '（目標房 ' || coalesce(v_txt,'?') || '）' end;

    /* ── ⑪ 負對照：不該被動到的沒有被動到 ─────────────────
       v_m2 不是 v_q2 的房主，把他移走不可以改到 opened_by，
       也不可以把還有人的房取消掉。 */
    select status into v_txt from match_queues where id = v_q2;
    select opened_by into v_uuid from match_queues where id = v_q2;
    select count(*) into v_n from match_queue_players
     where queue_id = v_q2 and left_at is null;
    v_msg := v_msg || E'\n' || case
      when v_txt = 'waiting' and v_uuid = v_m4 and v_n = 1
      then '⑪ ✅ 來源房還有人時沒被取消，房主也沒被亂換'
      else '⑪ 🔴 來源房 ' || coalesce(v_txt,'?') || '、房主 '
           || coalesce(v_uuid::text,'null') || '、剩 ' || v_n || ' 人' end;

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      /* 🔴 handler 不可以只記「失敗了」，要記**為什麼** ——
         2026-09-09 就是把例外吞掉只存 -1，結果把「工具用錯」
         偽裝成「系統壞了」，得到一個完全誤導的結論。 */
      v_msg := v_msg || E'\n🔴 中途炸了（後面的格子沒跑）：' || sqlerrm;
    end if;
    perform set_config('migi.chk', v_msg, true);
  end;
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息 —— 整段沒跑到') as "行為驗證";
