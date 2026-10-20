/* ============================================================
   店家開的配桌房：最後一人離開也保留到開打時間（2026-10-21 使用者）
   ------------------------------------------------------------
   起因：POS 配桌列表把店家開桌房的最後一人移除，畫面寫
     「已移除 yuhsin，這桌沒有人了所以一併關閉」
   使用者：「移除最後一人，但時間還沒到，所以房間要保留」。

   規則（改三支，簽名都沒變 ⇒ CREATE OR REPLACE，授權不會掉）：
     店家開的房（source = 'pos' 店家開桌、'recurring' 固定牌局）
       ⇒ 走到 0 人也不關，空著等人報名，到期由 sweep_expired_queues_tx 標流局（店家開的房一定有到期時間）
     客人自己開的房（source = 'member'）
       ⇒ 照舊：最後一人走了就取消（沒有人的客人房留著沒有意義）
   三條路一起改：店員移除（pos_remove_queue_member_tx）、店員移到別房（pos_move_queue_member_tx）、
   客人自己退房（leave_match_queue_tx）—— 「最後一個人走了」怎麼處理不該因為誰按的而不一樣。
   📌 原本只有固定牌局保留；店家開桌在這之前會被一併關掉。
   ============================================================ */

create or replace function public.leave_match_queue_tx(p_org_id uuid, p_member uuid, p_queue uuid, p_reason text default null::text)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_opener uuid; v_status text; v_source text; v_next uuid; v_left int;
begin
  -- 【身分 2026-09-29】店員可以代客人操作；其他人只認登入的本人
  if not exists (select 1 from public.current_staff()) then
    p_member := public.current_member_id();
    if p_member is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  end if;
  select opened_by, status, source into v_opener, v_status, v_source
    from match_queues where id=p_queue and org_id=p_org_id for update;
  if not found then raise exception '房不存在'; end if;
  if v_status <> 'waiting' then raise exception '已成桌或已結束，無法退房'; end if;

  -- 標記離開：系統分類 quit + 使用者細原因存 leave_detail
  update match_queue_players set left_at=now(), leave_reason='quit', leave_detail=p_reason
   where queue_id=p_queue and member_id=p_member and left_at is null;

  select count(*) into v_left from match_queue_players where queue_id=p_queue and left_at is null;

  if v_left = 0 then
    -- ★ 店家開的房（固定牌局、店家開桌）：0 人不取消，繼續空著等人報名（到期由 sweep 標流局）
    --   2026-10-21 起店家開桌也算（原本只有固定牌局）
    if v_source in ('recurring', 'pos') then
      update match_queues set updated_at=now() where id=p_queue;
      return 'left';
    end if;
    -- 客人自己開的房：最後一人退出 → 房取消
    update match_queues set status='cancelled', updated_at=now() where id=p_queue;
    return 'cancelled';
  end if;

  -- 房主退桌 → 轉移給最早加入者（店家開的房 opened_by 是 null，不受影響）
  if p_member = v_opener then
    select member_id into v_next from match_queue_players
     where queue_id=p_queue and left_at is null order by joined_at asc limit 1;
    update match_queues set opened_by=v_next, updated_at=now() where id=p_queue;
  end if;
  return 'left';
end $function$;


create or replace function public.pos_remove_queue_member_tx(p_org uuid, p_queue uuid, p_member uuid, p_reason text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
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

  /* 以下兩段的行為與 leave_match_queue_tx 相同 ——
     「最後一個人走了」與「房主走了」的處理不該因為誰按的而不一樣。 */
  if v_left = 0 then
    -- 店家開的房（固定牌局、店家開桌）：0 人不取消，繼續空著等人報名（2026-10-21 起店家開桌也算）
    if v_source in ('recurring', 'pos') then
      update match_queues set updated_at = now() where id = p_queue;
      return jsonb_build_object('ok', true, 'queue_status', 'waiting', 'players', 0);
    end if;
    update match_queues set status = 'cancelled', updated_at = now() where id = p_queue;
    return jsonb_build_object('ok', true, 'queue_status', 'cancelled', 'players', 0);
  end if;

  -- 房主被移除 → 轉給最早加入的人（店家開的房 opened_by 是 null，不受影響）
  if p_member = v_opener then
    select member_id into v_next from match_queue_players
     where queue_id = p_queue and left_at is null order by joined_at asc limit 1;
    update match_queues set opened_by = v_next, updated_at = now() where id = p_queue;
  end if;

  return jsonb_build_object('ok', true, 'queue_status', 'waiting', 'players', v_left);
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

  /* 來源房的善後 —— 與移除那支、與會員自己退房那支一致
     （2026-10-21 起店家開的房清空也保留，只有客人自己開的房會被取消） */
  select count(*) into v_left
    from match_queue_players where queue_id = p_from_queue and left_at is null;
  if v_left = 0 and v_from_source not in ('recurring', 'pos') then
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
  (select case when count(*) = 3 then '✅ ① 三支都只有一個版本' else '🔴 ① 版本數 ' || count(*) end
     from pg_proc where pronamespace = 'public'::regnamespace
      and proname in ('leave_match_queue_tx', 'pos_remove_queue_member_tx', 'pos_move_queue_member_tx')) || E'\n' ||
  (select case when count(*) = 3 then '✅ ② 三支都把店家開桌（pos）算進「清空也保留」'
               else '🔴 ② 只有 ' || count(*) || ' 支改到' end
     from pg_proc where pronamespace = 'public'::regnamespace and prokind = 'f'
      and proname in ('leave_match_queue_tx', 'pos_remove_queue_member_tx', 'pos_move_queue_member_tx')
      and pg_get_functiondef(oid) ~ '(in|not in) \(''recurring'', ''pos''\)') || E'\n' ||
  (select case when count(*) = 3 then '✅ ③ 三支仍然會取消客人自己開的房（還有改成 cancelled 那一行）'
               else '🔴 ③ 有一支連客人房都不取消了' end
     from pg_proc where pronamespace = 'public'::regnamespace and prokind = 'f'
      and proname in ('leave_match_queue_tx', 'pos_remove_queue_member_tx', 'pos_move_queue_member_tx')
      and pg_get_functiondef(oid) ~ 'status\s*=\s*''cancelled''') || E'\n' ||
  (select case when bool_and(has_function_privilege('authenticated', oid, 'execute'))
               then '✅ ④ 三支 authenticated 都還叫得動（POS 與會員 App）' else '🔴 ④ 有一支叫不動了' end
     from pg_proc where pronamespace = 'public'::regnamespace
      and proname in ('leave_match_queue_tx', 'pos_remove_queue_member_tx', 'pos_move_queue_member_tx')) || E'\n' ||
  (select case when count(*) = 0 then '✅ ⑤ 店家開的房都有到期時間（清空後會由排程標流局，不會永遠掛著）'
               else '🔴 ⑤ 有 ' || count(*) || ' 間店家開的房沒有到期時間' end
     from match_queues where source = 'pos' and expires_at is null and status = 'waiting')
  as "驗證";
