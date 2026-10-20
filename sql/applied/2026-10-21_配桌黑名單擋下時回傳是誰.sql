/* ============================================================
   配桌黑名單擋下時，回傳「跟誰互為黑名單」（2026-10-21 使用者）
   ------------------------------------------------------------
   起因：POS 配桌列表「加現場客人」被擋下時，畫面只寫
     「這位客人與桌上某人互為封鎖，請幫他換一桌」
   使用者：不要寫某人，直接寫與誰黑名單；有 3 位就 3 位都列出來。

   改兩支（簽名都沒變 ⇒ CREATE OR REPLACE，授權不會掉）：
     pos_add_queue_member_tx    店員把現場客人加進配桌房
     pos_move_queue_member_tx   店員把客人移到別的配桌房
   擋下時多回一個陣列：桌上每一位跟他互為黑名單的人的暱稱（依報名先後）。
   原本找到第一位就停，現在掃完整桌。

   ⚠ 只有 POS 這兩支回名字。客人自己在 App 報名（join_match_queue_tx）
     維持只說「此桌目前無法加入」—— 告訴客人「誰封鎖了你」不行。
   ⚠ 被隱藏的會員暱稱本來就換成問號名字，這裡讀到的也是那個，不會洩漏。
   ============================================================ */

create or replace function public.pos_add_queue_member_tx(p_org uuid, p_queue uuid, p_member uuid, p_staff uuid default null::uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_seats int; v_cnt int; v_status text; v_expires timestamptz;
  v_play_at timestamptz; v_source text; v_names jsonb; v_fin jsonb;
begin
  -- 【身分 2026-09-29】從 API 進來的只有店員能叫（排程沒有 API 身分，照常）
  perform public._api_staff_only();
  if p_member is null then return jsonb_build_object('ok', false, 'reason', 'member_required'); end if;

  select seats, status, expires_at, play_at, source
    into v_seats, v_status, v_expires, v_play_at, v_source
    from match_queues where id = p_queue and org_id = p_org for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_status <> 'waiting' then return jsonb_build_object('ok', false, 'reason', 'not_waiting', 'status', v_status); end if;
  if v_expires is not null and v_expires < now() then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;

  if exists (select 1 from match_queue_players
              where queue_id = p_queue and member_id = p_member and left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'already_in');
  end if;

  /* ⚠ 黑名單與衝突檢查照樣做，跟 App 那條路一致。
     店員在現場、看得到人，但「互相封鎖的兩個人被排在同一桌」是客人自己設的意思，
     不該因為換一個入口就繞過。擋下來之後店員可以當面問，那比事後尷尬好。 */
  begin
    perform _check_join_conflict(p_org, p_member, v_play_at, v_source);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'conflict', 'message', sqlerrm);
  end;

  -- 2026-10-21：掃完整桌，把每一位互為黑名單的人都列出來（店員要知道是誰）
  select coalesce(jsonb_agg(m.display_name order by p.joined_at), '[]'::jsonb)
    into v_names
    from match_queue_players p
    join members m on m.id = p.member_id
   where p.queue_id = p_queue and p.left_at is null
     and _blocked_between(p_org, p_member, p.member_id);
  if jsonb_array_length(v_names) > 0 then
    return jsonb_build_object('ok', false, 'reason', 'blocked', 'blocked_names', v_names);
  end if;

  -- join_source = 'pos_walkin'：這是之後分析「現場登記 vs App 自己報名」的唯一依據，
  -- 沿用 'browse' 就永遠分不出來了
  insert into match_queue_players(org_id, queue_id, member_id, join_source)
  values (p_org, p_queue, p_member, 'pos_walkin')
  on conflict do nothing;

  select count(*) into v_cnt from match_queue_players where queue_id = p_queue and left_at is null;
  if v_cnt >= v_seats then
    v_fin := _finalize_queue_full_tx(p_org, p_queue, p_staff);
    return jsonb_build_object('ok', true, 'full', true,
      'status', v_fin->>'status', 'session_id', v_fin->>'session_id',
      'table_label', v_fin->>'table_label', 'seat_reason', v_fin->>'seat_reason');
  end if;

  return jsonb_build_object('ok', true, 'full', false, 'players', v_cnt, 'seats', v_seats);
end $function$;


create or replace function public.pos_move_queue_member_tx(p_org uuid, p_from_queue uuid, p_to_queue uuid, p_member uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_staff uuid; v_join_source text;
  v_from_status text; v_from_source text; v_from_opener uuid;
  v_to_status text; v_to_seats int; v_to_expires timestamptz;
  v_to_play_at timestamptz; v_to_source text;
  v_cnt int; v_left int; v_next uuid; v_names jsonb; v_fin jsonb;
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
     不該因為換一個入口就繞過。擋下來店員可以當面問。
     2026-10-21：掃完整桌，把每一位互為黑名單的人都列出來。 */
  select coalesce(jsonb_agg(m.display_name order by p.joined_at), '[]'::jsonb)
    into v_names
    from match_queue_players p
    join members m on m.id = p.member_id
   where p.queue_id = p_to_queue and p.left_at is null
     and _blocked_between(p_org, p_member, p.member_id);
  if jsonb_array_length(v_names) > 0 then
    return jsonb_build_object('ok', false, 'reason', 'blocked', 'blocked_names', v_names);
  end if;

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


/* ── 驗證（單一 SELECT，不 raise）──────────────────────────── */
select
  (select case when count(*) = 2 then '✅ ① 兩支都只有一個版本' else '🔴 ① 版本數 ' || count(*) end
     from pg_proc where pronamespace = 'public'::regnamespace
      and proname in ('pos_add_queue_member_tx', 'pos_move_queue_member_tx')) || E'\n' ||
  (select case when count(*) = 2 then '✅ ② 兩支擋下時都回名字清單' else '🔴 ② 只有 ' || count(*) || ' 支回名字' end
     from pg_proc where pronamespace = 'public'::regnamespace and prokind = 'f'
      and proname in ('pos_add_queue_member_tx', 'pos_move_queue_member_tx')
      and pg_get_functiondef(oid) ~ '''blocked_names'',\s*v_names') || E'\n' ||
  (select case when count(*) = 2 then '✅ ③ 兩支仍然用 _blocked_between 判斷（雙向）' else '🔴 ③ 判斷不見了' end
     from pg_proc where pronamespace = 'public'::regnamespace and prokind = 'f'
      and proname in ('pos_add_queue_member_tx', 'pos_move_queue_member_tx')
      and pg_get_functiondef(oid) ~ '_blocked_between\(p_org, p_member, p\.member_id\)') || E'\n' ||
  (select case when bool_and(has_function_privilege('authenticated', oid, 'execute'))
               then '✅ ④ POS 叫得動（authenticated 仍有執行權）' else '🔴 ④ authenticated 叫不動了' end
     from pg_proc where pronamespace = 'public'::regnamespace
      and proname in ('pos_add_queue_member_tx', 'pos_move_queue_member_tx')) || E'\n' ||
  (select case when pg_get_functiondef(oid) !~ 'blocked_names'
               then '✅ ⑤ App 報名那支沒有被改到（客人看不到是誰封鎖他）' else '🔴 ⑤ App 那支也回名字了' end
     from pg_proc where pronamespace = 'public'::regnamespace and proname = 'join_match_queue_tx')
  as "驗證";
