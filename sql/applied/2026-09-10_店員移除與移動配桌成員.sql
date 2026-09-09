/* ============================================================
   店員移除／移動配桌成員　2026-09-10
   ============================================================
   使用者的需求與規則（原話）：
     「配桌列表的現場客人 店家應該要能自由移除或移動」
     「成桌之後移除一個人，那個房要怎麼辦？ **成桌前才能移除或移動**」

   ⇒ 兩支都硬性要求 `match_queues.status = 'waiting'`，
     與會員自己退房那支（`leave_match_queue_tx`）的擋牆逐字相同。
     成桌之後要動人是「換桌／退費」的問題，不是配桌房的問題。

   ── 動手前查證過的事實（不是推測）────────────────────────────
   · `uq_queue_member (queue_id, member_id) WHERE left_at IS NULL`
     ⇒ 移到別的房不會撞它；**同一個房來回**會（舊列還在時再插一次）
     ⇒ 所以移動一定是「先寫 left_at，再插新列」
   · `_check_join_conflict()` 掃的是「身上所有還沒結束的場」，
     **來源房自己就在裡面** ⇒ 不先離開的話它會跟自己撞
   · `match_queue_players_leave_reason_check` 目前允許
     quit / cancelled / expired / switched
     —— **`switched` 從來沒有任何函式寫過**（線上唯一那一列是手動改的）。
     那個字當初就是為「移動」保留的，只是沒有人把它接起來。
   · 現有 51 列的分布：expired 17／quit 8／switched 1／null 23

   ── 三個判斷，寫下來免得下次重新討論 ──────────────────────────
   ① **新增 `staff_removed`，不重用 `quit`。**
      `quit` 的意思是「他自己走了」。店員移除照樣寫 quit 的話，
      那個欄位就會**說一件沒發生的事** —— 這個專案記過七次的同一族病
      （一個名字兩個意思）。而它不報錯，只會讓日後的流失分析算錯。
   ② **移動保留原本的 `join_source`。**
      「這個人是在櫃檯登記的」是**入場事實**，不因為換了房就消失。
      重寫成 pos_walkin 會讓 App 自己報名的人被算成現場客。
   ③ **稽核欄位 `left_by_staff_id` 現在就加。**
      硬規則 5.6：稽核是**不可回溯**的利息 —— 今天不填，這段歷史永遠沒有。
      而且**不由前端送 staff_id**，一律從 `current_staff()` 取
      （硬規則：身分不可以由呼叫端宣告，2026-09-04 那批的通則）。

   🔴 **不用 `can('queue.remove')`。** 查過 `can()` 的本體：
     只有 `member.lookup` 會走「是不是店員」那一支，
     **其餘每一個碼都是 `role in ('hq','owner')`**
     ⇒ 新開一個 queue.* 的碼會變成總部限定，而配桌移除是**前場天天在做的事**，
       那會當場擋住真正的店員。這裡的權限就是「你是不是店員」，
       所以直接問 `current_staff()`。

   ⚠ **順帶發現、但這份不處理**：`leave_match_queue_tx` 是 anon 叫得動、
     而且 `p_member` 由呼叫端指定 ⇒ 任何人都能把別人踢出等待中的房。
     那與 `get_wallet_tx` 是**同一個已知的暴露面**（前端宣告身分），
     根治在待辦 14（JWT）——**不是這份新增的洞，也不能在這份修**
     （今天會員 App 就是靠 anon ＋ 前端送 member_id 在退房）。

   🔴 驗證段**不 raise**（硬規則 1.8）—— raise 會把上面的 DDL 一起回滾，
     而且六格照樣印綠的。行為測試（要造樣本、要回滾）另外放在
     `sql/checks/2026-09-10_驗店員移除與移動的擋牆.sql`。
   ============================================================ */

/* ⚠ 沒有 begin/commit —— Supabase SQL Editor 本來就是單一交易。
   ⇒ 驗證段看到的是**交易內**的狀態，不是提交後的狀態
     ⇒ 跑完之後由 Claude 另外查一次線上才算數（硬規則 1.8）。 */

/* ── ① 稽核欄位 ────────────────────────────────────────── */
alter table public.match_queue_players
  add column if not exists left_by_staff_id uuid references public.staff(id);

comment on column public.match_queue_players.left_by_staff_id is
  '是誰讓這個人離開的。自己退房是 null；店員移除或移動時記下操作者。'
  ' 一律由 current_staff() 解析，不接受呼叫端指定。';

comment on column public.match_queue_players.leave_reason is
  '離開的系統分類：quit 自己退房／cancelled 房被取消／expired 到期流局／'
  'switched 被店員移到別的房／staff_removed 被店員移除。'
  ' 客人自己填的細節在 leave_detail。';

/* ── ② CHECK 放行新的分類 ──────────────────────────────── */
alter table public.match_queue_players
  drop constraint if exists match_queue_players_leave_reason_check;

alter table public.match_queue_players
  add constraint match_queue_players_leave_reason_check
  check (leave_reason = any (array['quit','cancelled','expired','switched','staff_removed']));

/* ============================================================
   ③ 店員移除一個人
   ============================================================ */
create or replace function public.pos_remove_queue_member_tx(
  p_org uuid, p_queue uuid, p_member uuid, p_reason text default null
) returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_staff uuid; v_status text; v_source text; v_opener uuid;
  v_left int; v_next uuid;
begin
  select staff_id into v_staff from current_staff();
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff');
  end if;
  if p_member is null then
    return jsonb_build_object('ok', false, 'reason', 'member_required');
  end if;

  select status, source, opened_by into v_status, v_source, v_opener
    from match_queues where id = p_queue and org_id = p_org for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  /* 🔴 使用者定的規則：成桌前才能動。
     成桌之後那個房已經配到桌、可能已經收過檯費，
     少一個人是「換桌／退費」的問題，不是配桌房能處理的。 */
  if v_status <> 'waiting' then
    return jsonb_build_object('ok', false, 'reason', 'not_waiting', 'status', v_status);
  end if;

  update match_queue_players
     set left_at = now(), leave_reason = 'staff_removed',
         leave_detail = p_reason, left_by_staff_id = v_staff
   where queue_id = p_queue and member_id = p_member and left_at is null;
  /* ⚠ UPDATE 之後一定要看 FOUND —— `register_member_tx` 就是少了這一行
     而謊報成功過（2026-08-26 修）。 */
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_in');
  end if;

  select count(*) into v_left
    from match_queue_players where queue_id = p_queue and left_at is null;

  /* 以下兩段的行為與 leave_match_queue_tx 逐字相同 ——
     「最後一個人走了」與「房主走了」的處理不該因為誰按的而不一樣。 */
  if v_left = 0 then
    -- 固定局：0 人不取消，繼續空著等人報名
    if v_source = 'recurring' then
      update match_queues set updated_at = now() where id = p_queue;
      return jsonb_build_object('ok', true, 'queue_status', 'waiting', 'players', 0);
    end if;
    update match_queues set status = 'cancelled', updated_at = now() where id = p_queue;
    return jsonb_build_object('ok', true, 'queue_status', 'cancelled', 'players', 0);
  end if;

  -- 房主被移除 → 轉給最早加入的人（固定局 opened_by 是 null，不受影響）
  if p_member = v_opener then
    select member_id into v_next from match_queue_players
     where queue_id = p_queue and left_at is null order by joined_at asc limit 1;
    update match_queues set opened_by = v_next, updated_at = now() where id = p_queue;
  end if;

  return jsonb_build_object('ok', true, 'queue_status', 'waiting', 'players', v_left);
end $function$;

/* ============================================================
   ④ 店員把一個人移到別的房
   ============================================================ */
create or replace function public.pos_move_queue_member_tx(
  p_org uuid, p_from_queue uuid, p_to_queue uuid, p_member uuid
) returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_staff uuid; v_join_source text;
  v_from_status text; v_from_source text; v_from_opener uuid;
  v_to_status text; v_to_seats int; v_to_expires timestamptz;
  v_to_play_at timestamptz; v_to_source text;
  v_cnt int; v_left int; v_next uuid; v_other uuid; v_fin jsonb;
begin
  select staff_id into v_staff from current_staff();
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff');
  end if;
  if p_member is null then
    return jsonb_build_object('ok', false, 'reason', 'member_required');
  end if;
  if p_from_queue = p_to_queue then
    return jsonb_build_object('ok', false, 'reason', 'same_queue');
  end if;

  /* 兩個房都要鎖，而且**依 id 排序**再鎖 ——
     兩個店員同時把 A 的人移到 B、把 B 的人移到 A 就會互等。
     固定的鎖定順序是唯一不用碰運氣的解法。 */
  perform 1 from match_queues
   where id = any(array[p_from_queue, p_to_queue]) and org_id = p_org
   order by id for update;

  select status, source, opened_by into v_from_status, v_from_source, v_from_opener
    from match_queues where id = p_from_queue and org_id = p_org;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'from_not_found');
  end if;
  if v_from_status <> 'waiting' then
    return jsonb_build_object('ok', false, 'reason', 'from_not_waiting', 'status', v_from_status);
  end if;

  select status, seats, expires_at, play_at, source
    into v_to_status, v_to_seats, v_to_expires, v_to_play_at, v_to_source
    from match_queues where id = p_to_queue and org_id = p_org;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'to_not_found');
  end if;
  if v_to_status <> 'waiting' then
    return jsonb_build_object('ok', false, 'reason', 'to_not_waiting', 'status', v_to_status);
  end if;
  if v_to_expires is not null and v_to_expires < now() then
    return jsonb_build_object('ok', false, 'reason', 'to_expired');
  end if;

  /* 來源房要有這個人 —— 順便把他的入場來源留下來。
     ⚠ 那個值是「他當初怎麼進來的」，移動不可以把它蓋掉。 */
  select join_source into v_join_source
    from match_queue_players
   where queue_id = p_from_queue and member_id = p_member and left_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_in');
  end if;

  if exists (select 1 from match_queue_players
              where queue_id = p_to_queue and member_id = p_member and left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'already_in');
  end if;

  select count(*) into v_cnt
    from match_queue_players where queue_id = p_to_queue and left_at is null;
  if v_cnt >= v_to_seats then
    return jsonb_build_object('ok', false, 'reason', 'to_full', 'players', v_cnt, 'seats', v_to_seats);
  end if;

  /* 黑名單照擋，理由與 pos_add_queue_member_tx 相同：
     「互相封鎖的兩個人被排在同一桌」是客人自己設的意思，
     不該因為換一個入口就繞過。擋下來店員可以當面問。 */
  for v_other in
    select member_id from match_queue_players
     where queue_id = p_to_queue and left_at is null
  loop
    if _blocked_between(p_org, p_member, v_other) then
      return jsonb_build_object('ok', false, 'reason', 'blocked');
    end if;
  end loop;

  /* 🔴 順序只能是「先離開來源，再檢查衝突，最後插進目標」——
     衝突檢查掃的是「身上所有還沒結束的場」，來源房自己就在裡面，
     不先離開的話它一定會跟自己撞。

     ⚠ 而「先離開」表示檢查失敗時已經寫進去了。所以整段包在
       begin…exception 裡：**那個區塊有隱含的 savepoint**，
       回傳之前會把離開那一筆退掉。
     📌 這與 2026-08-16 那個坑（回 {ok:false} 不會回滾、留下半筆帳）
       的差別就在這個 handler —— 那次是**沒有** handler。 */
  begin
    update match_queue_players
       set left_at = now(), leave_reason = 'switched',
           leave_detail = '店員移到別的房', left_by_staff_id = v_staff
     where queue_id = p_from_queue and member_id = p_member and left_at is null;

    perform _check_join_conflict(p_org, p_member, v_to_play_at, v_to_source);

    insert into match_queue_players(org_id, queue_id, member_id, join_source)
    values (p_org, p_to_queue, p_member, v_join_source);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'conflict', 'message', sqlerrm);
  end;

  /* 來源房的善後 —— 與移除那支、與會員自己退房那支完全一致 */
  select count(*) into v_left
    from match_queue_players where queue_id = p_from_queue and left_at is null;
  if v_left = 0 and v_from_source <> 'recurring' then
    update match_queues set status = 'cancelled', updated_at = now() where id = p_from_queue;
  elsif v_left > 0 and p_member = v_from_opener then
    select member_id into v_next from match_queue_players
     where queue_id = p_from_queue and left_at is null order by joined_at asc limit 1;
    update match_queues set opened_by = v_next, updated_at = now() where id = p_from_queue;
  else
    update match_queues set updated_at = now() where id = p_from_queue;
  end if;

  /* 目標房滿了就照既有的路走（改 matched、通知每個人、試著自動帶桌） */
  select count(*) into v_cnt
    from match_queue_players where queue_id = p_to_queue and left_at is null;
  if v_cnt >= v_to_seats then
    v_fin := _finalize_queue_full_tx(p_org, p_to_queue, v_staff);
    return jsonb_build_object('ok', true, 'full', true,
      'from_players', v_left,
      'status', v_fin->>'status', 'session_id', v_fin->>'session_id',
      'table_label', v_fin->>'table_label', 'seat_reason', v_fin->>'seat_reason');
  end if;

  return jsonb_build_object('ok', true, 'full', false,
    'from_players', v_left, 'players', v_cnt, 'seats', v_to_seats);
end $function$;

/* ============================================================
   ⑤ 授權 —— 兩個方向都要收（硬規則 2.6b）
   ============================================================
   · 舊的管理函式：anon 是從 **PUBLIC 繼承** ⇒ revoke from public
   · **新建的函式**：這個專案的 default privileges 會**明確**授權給 anon
     ⇒ 還要 revoke from anon
   只收一邊的話，症狀跟完全沒收一模一樣。 */
revoke execute on function public.pos_remove_queue_member_tx(uuid, uuid, uuid, text) from public;
revoke execute on function public.pos_remove_queue_member_tx(uuid, uuid, uuid, text) from anon;
grant  execute on function public.pos_remove_queue_member_tx(uuid, uuid, uuid, text) to authenticated, service_role;

revoke execute on function public.pos_move_queue_member_tx(uuid, uuid, uuid, uuid) from public;
revoke execute on function public.pos_move_queue_member_tx(uuid, uuid, uuid, uuid) from anon;
grant  execute on function public.pos_move_queue_member_tx(uuid, uuid, uuid, uuid) to authenticated, service_role;

/* ============================================================
   驗證段 —— **一律唯讀、一律不 raise**（硬規則 1.8）
   ============================================================
   raise 會把上面整批 DDL 回滾，而每一格照樣印綠的
   —— 2026-09-09 就是這樣「六格全綠而函式一行都沒改」。
   ⚠ 這裡只驗「東西有沒有落地」。**行為（擋牆會不會擋）驗不了**，
     那要造樣本、要回滾，放在
     `sql/checks/2026-09-10_驗店員移除與移動的擋牆.sql`。
   ============================================================ */
do $$
declare
  v_msg text := '';
  v_def text; v_n int; v_missing text;
begin
  /* ── ① CHECK：新值進去了，而且四個舊值一個都沒掉 ───────── */
  select pg_get_constraintdef(c.oid) into v_def
    from pg_constraint c
   where c.conname = 'match_queue_players_leave_reason_check'
     and c.conrelid = 'public.match_queue_players'::regclass;

  if v_def is null then
    v_msg := v_msg || '① 🔴 找不到那條 CHECK —— 被 drop 掉沒建回來';
  else
    select coalesce(string_agg(w, '、'), '') into v_missing
      from unnest(array['quit','cancelled','expired','switched']) w
     where position(w in v_def) = 0;
    /* 🎯 正對照就是這一格：只驗「新值在不在」的話，
       一份把 CHECK 整個換成只剩新值的 SQL 也會全綠。 */
    v_msg := v_msg || case
      when position('staff_removed' in v_def) = 0 then '① 🔴 新的分類沒進 CHECK'
      when v_missing <> '' then '① 🔴 舊的分類被弄丟了：' || v_missing
      else '① ✅ CHECK 五個值都在（四個舊的沒被誤傷）'
    end;
  end if;

  /* ── ② 稽核欄位 ───────────────────────────────────── */
  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'match_queue_players'
     and column_name = 'left_by_staff_id' and data_type = 'uuid';
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '② ✅ 稽核欄位在，型別是 uuid'
    else '② 🔴 稽核欄位沒建起來' end;

  select count(*) into v_n
    from pg_constraint c
   where c.conrelid = 'public.match_queue_players'::regclass
     and c.contype = 'f'
     and c.confrelid = 'public.staff'::regclass;
  v_msg := v_msg || E'\n' || case when v_n >= 1
    then '②b ✅ 它有外鍵指向 staff（填不進一個不存在的店員）'
    else '②b 🔴 沒有外鍵 —— 這欄可以填任何 uuid' end;

  /* ── ③ 兩支函式在不在、是不是 DEFINER ─────────────────── */
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname in ('pos_remove_queue_member_tx','pos_move_queue_member_tx')
     and p.prosecdef;
  v_msg := v_msg || E'\n' || case when v_n = 2
    then '③ ✅ 兩支都在，而且都是 SECURITY DEFINER'
    else '③ 🔴 應該有 2 支 DEFINER，實際 ' || v_n end;

  /* ── ④ 授權：兩個方向分開印（硬規則 2.6b）───────────────
     只印 has_function_privilege 的話，「明確授權」與「PUBLIC 繼承」
     長得一模一樣，收錯方向時看到的症狀跟沒收一樣。 */
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('pos_remove_queue_member_tx','pos_move_queue_member_tx')
     and exists (select 1 from aclexplode(p.proacl) a
                  where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE');
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '④ ✅ 明確授權給 anon 的：0 支'
    else '④ 🔴 還有 ' || v_n || ' 支明確授權給 anon' end;

  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('pos_remove_queue_member_tx','pos_move_queue_member_tx')
     and (p.proacl is null
          or exists (select 1 from aclexplode(p.proacl) a
                      where a.grantee = 0 and a.privilege_type = 'EXECUTE'));
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '④b ✅ 從 PUBLIC 進得來的：0 支'
    else '④b 🔴 還有 ' || v_n || ' 支 PUBLIC 叫得動' end;

  /* 正對照：該通的有沒有通。少了這一格，兩支「誰都叫不動」的函式也會全綠。 */
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('pos_remove_queue_member_tx','pos_move_queue_member_tx')
     and exists (select 1 from aclexplode(p.proacl) a
                  where a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE')
     and exists (select 1 from aclexplode(p.proacl) a
                  where a.grantee = 'service_role'::regrole::oid and a.privilege_type = 'EXECUTE');
  v_msg := v_msg || E'\n' || case when v_n = 2
    then '④c ✅ 登入的店員與 service_role 兩支都叫得動'
    else '④c 🔴 該通的沒通，只有 ' || v_n || ' 支' end;

  /* ── ⑤ 負對照：會員自己退房那支一根寒毛都沒動 ────────────
     它是會員 App 現在唯一的退房路徑，而且今天必須 anon 叫得動
     （前端還在送 member_id，待辦 14 未做）。
     ⚠ 收掉它會讓客人「按了退房沒反應」而且不報錯。 */
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'leave_match_queue_tx'
     and p.prosecdef
     and has_function_privilege('anon', p.oid, 'execute');
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '⑤ ✅ 會員自己退房那支沒被波及（還在、DEFINER、anon 仍叫得動）'
    else '⑤ 🔴 會員退房那支被動到了 —— 客人會退不了房' end;

  /* ── ⑥ 誰在寫這兩種離開分類 ───────────────────────────
     ⚠ 這一格是掃函式全文，而 pg_get_functiondef 會連註解一起回
       （硬規則 3.5，已踩三次）。所以移動那支的註解裡
       **刻意沒有寫出移除的那個分類字串**，只用文字描述。

     🔴 **樣式要連單引號一起比對，不可以只比對那個詞。**
       寫這份時就踩到了：`clear_avatar_photo_tx` 裡有一個
       `'switched_to_bear'`（頭像從照片換回小熊），跟離開分類毫無關係，
       而它會讓「只有 1 支」永遠是紅的 —— 而**一個永遠紅的檢查
       會讓人學會忽略紅色**，那比沒有檢查更危險。
     📌 期望值是查出來的不是憑印象寫的（硬規則 3.56）：
       跑之前 `'staff_removed'` 0 支、`'switched'` 0 支（那個頭像的不算）。 */
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and pg_get_functiondef(p.oid) like '%' || '''staff_removed''' || '%';
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '⑥ ✅ 只有移除那一支會寫「店員移除」'
    else '⑥ 🔴 應該只有 1 支，實際 ' || v_n || ' 支' end;

  /* 正對照：換一個值再掃一次。兩格都非零才證明這個掃描真的會動。 */
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and pg_get_functiondef(p.oid) like '%' || '''switched''' || '%';
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '⑥b ✅ 只有移動那一支會寫「被移到別的房」（這個字之前沒有任何函式在寫）'
    else '⑥b 🔴 應該只有 1 支，實際 ' || v_n || ' 支' end;

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息 —— 驗證段沒跑到') as "驗證";
