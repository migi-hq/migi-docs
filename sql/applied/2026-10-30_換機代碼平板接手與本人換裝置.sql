-- ════════════════════════════════════════════════════════════════════
-- 2026-10-30 換機代碼補兩條路（使用者：「開始做這兩件」）
--
-- 簡化之後平板與手機的「換一支手機或平板」都產生**同一種換機代碼**（tbl_swap_code_tx）。
-- 線上原本只通兩條：
--   · 還沒配對的新手機在配對頁輸入 ＝ 同一個人換手機（tbl_phone_redeem_tx，10-20 起）
--   · 別人已經配好的手機在「接手別人的位置」輸入 ＝ 換人上桌（tbl_swap_redeem_tx）
-- 這一份補另外兩條，都是「同一個人換一台裝置，帳號與分數都不變」：
--
--   ① 平板在待機畫面「改手機計分」輸入換機代碼 ⇒ 那個位置換到這台平板
--      例：A3 那台平板沒電，店員拿 A5 空著的平板過去接。
--      · 平板原本綁死在自己那一桌；這一台接手之後記住「我現在在打哪一場」（table_devices.bound_session_id，
--        手機本來就有這一欄），_tbl_device 回傳時把桌換成那一場的桌 ⇒ 計分板其他函式一行不用改
--      · 🔴 自動回家：那一場收桌、或這台平板不再坐在那個位置上（讓出位置、被別人接手），
--        下一次 _tbl_device 就清掉綁定、回到它原本那一桌 —— 不用任何人記得去還
--      · 擋：別間店的平板不能接（店員在店裡拿的平板一定是同一間店）、好友練習賽只能用手機、
--        這台平板正坐在別的牌局的位置上（先在那邊讓出位置）
--   ② 本人已經配好的手機輸入自己那個位置的代碼 ⇒ 位置換到這支手機
--      例：位置在平板上（或在另一支他自己的手機上），他想改用這支。
--      · 原本回「這就是你自己的位置」擋掉；現在照換，位置已經在這支手機上才擋
--
--   兩條都記在 session_seat_swaps（to_member_id ＝ from_member_id ＝ 換裝置，同 10-20 的換手機），
--   同一個位置其他沒用掉的代碼一起作廢。
--   換人上桌那一條（別人的手機）照舊，預覽多回 from_avatar（被接手那位的頭像，畫「舊頭像 → 新頭像」）。
--
-- ⚠ 已知、刻意不處理：
--   · 管理後台「智慧計分板」頁仍把借出去的平板列在它原本那一桌下面
--   · 借來的平板只認「坐在位置上」：那一場裡讓出位置就回家，不會停在那一桌的「我是誰」
--
-- 改的兩支都是 create or replace、簽名不變 ⇒ 權限照舊（硬規則 2）。
-- 驗證：最後一格；行為測試 sql/checks/2026-10-30_驗換機代碼平板接手與本人換裝置.sql
-- ════════════════════════════════════════════════════════════════════

create or replace function public._tbl_device(p_token text)
 returns table_devices
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare d public.table_devices; v_table uuid; v_store uuid;
begin
  if p_token is null or length(p_token) < 32 then
    raise exception '這台平板還沒配對，請找店員' using errcode = '28000';
  end if;
  select * into d from table_devices
   where token_hash = public._tbl_hash(p_token) and is_active;
  if not found then
    raise exception '這台平板還沒配對或已停用，請找店員' using errcode = '28000';
  end if;
  /* 最後上線時間：15 秒寫一次（平板每 5 秒拿一次狀態）。
     「斷線接手」看它：45 秒沒更新就算斷線（_tbl_device_stale）。原本一分鐘一次，判斷不了 45 秒 */
  if d.last_seen_at is null or d.last_seen_at < now() - interval '15 seconds' then
    update table_devices set last_seen_at = now() where id = d.id;
  end if;

  if d.kind = 'phone' then
    /* 平板發的配對碼只限那一場：那一場收了，這支手機就不能再用 */
    if d.bound_session_id is not null and not exists (
         select 1 from table_sessions where id = d.bound_session_id and status = 'open' and deleted_at is null) then
      raise exception '這一場已經結束，手機計分已失效' using errcode = '28000';
    end if;
    /* 這位會員現在坐在哪一桌（沒有就是 null ⇒ 狀態回「目前沒有牌局」） */
    select ts.table_id, ts.store_id into v_table, v_store
      from session_players sp join table_sessions ts on ts.id = sp.session_id
     where sp.member_id = d.member_id and sp.left_at is null
       and ts.status = 'open' and ts.deleted_at is null
       and (d.bound_session_id is null or ts.id = d.bound_session_id)
     order by ts.created_at desc limit 1;
    /* 後台照門市列手機（2026-10-13）：記下這支手機最後在哪間店用 —— 桌不寫回，桌每一場都不同 */
    if v_store is not null and d.store_id is distinct from v_store then
      update table_devices set store_id = v_store where id = d.id;
    end if;
    d.table_id := v_table;   -- 只改回傳值，不寫回資料表
    d.store_id := v_store;
  elsif d.bound_session_id is not null then
    /* 借來的平板（2026-10-30）：用換機代碼接了別桌的位置 ⇒ 那一場還開著、而且它還坐在那個位置上，就算那一桌。
       否則（收桌、讓出位置、被別人接手）清掉綁定，回到它原本那一桌 */
    select ts.table_id into v_table
      from session_players sp join table_sessions ts on ts.id = sp.session_id
     where ts.id = d.bound_session_id and ts.status = 'open' and ts.deleted_at is null
       and sp.device_id = d.id and sp.left_at is null
     limit 1;
    if v_table is not null then
      d.table_id := v_table;   -- 只改回傳值；table_devices.table_id 永遠是它原本那一桌
    else
      update table_devices set bound_session_id = null where id = d.id;
      d.bound_session_id := null;
    end if;
  end if;
  return d;
end $function$;

create or replace function public.tbl_swap_redeem_tx(p_token text, p_code text, p_commit boolean default false)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  d public.table_devices; s public.session_seat_swaps; v_row public.session_players; v_sess public.table_sessions;
  v_code text; v_fails int; v_from text; v_to text; v_table text; v_hands int; v_moved int; v_queues int;
  v_avatar jsonb; v_move boolean;
begin
  d := public._tbl_device(p_token);

  select count(*) into v_fails from session_swap_tries
   where device_id = d.id and at > now() - interval '10 minutes';
  if v_fails >= 8 then
    return jsonb_build_object('ok', false, 'reason', 'too_many', 'message', '輸入錯太多次，請 10 分鐘後再試');
  end if;

  v_code := regexp_replace(coalesce(p_code, ''), '\D', '', 'g');
  select * into s from session_seat_swaps
   where code = v_code and used_at is null and expires_at > now()
   order by created_at desc limit 1;
  if not found then
    insert into session_swap_tries (device_id) values (d.id);
    return jsonb_build_object('ok', false, 'reason', 'bad_code', 'message', '代碼不對或已經過期，請對方重新產生一組');
  end if;

  select * into v_sess from table_sessions where id = s.session_id;
  if v_sess.status <> 'open' or v_sess.deleted_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'closed', 'message', '這一場已經結束了');
  end if;
  select * into v_row from session_players where id = s.player_row_id;
  if v_row.member_id <> s.from_member_id or v_row.left_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'gone', 'message', '這個位置已經換過人了');
  end if;

  select coalesce(display_name, '會員'),
         jsonb_build_object('avatar_source', avatar_source, 'avatar_url', avatar_url,
                            'avatar_bear', avatar_bear, 'avatar_photo_path', avatar_photo_path)
    into v_from, v_avatar
    from members where id = s.from_member_id;
  select label into v_table from tables where id = v_sess.table_id;
  select count(*) into v_hands from hands
   where session_id = s.session_id and status = 'confirmed' and result not in ('kala', 'bonus');

  /* ── 同一個人換一台裝置（2026-10-30）：平板接手，或本人自己的手機 ── */
  v_move := d.kind = 'tablet' or d.member_id = s.from_member_id;
  if v_move then
    if v_row.device_id = d.id then
      return jsonb_build_object('ok', false, 'reason', 'self', 'message', '這個位置已經在這台計分板上了');
    end if;
    if d.kind = 'tablet' then
      if d.store_id is distinct from v_sess.store_id then
        return jsonb_build_object('ok', false, 'reason', 'other_store', 'message', '這台平板是別間店的，不能接這一桌');
      end if;
      if exists (select 1 from stores where id = v_sess.store_id and is_virtual) then
        return jsonb_build_object('ok', false, 'reason', 'phone_only', 'message', '好友練習賽只能用手機計分');
      end if;
      if exists (select 1 from session_players sp join table_sessions ts on ts.id = sp.session_id
                  where sp.device_id = d.id and sp.left_at is null and ts.id <> s.session_id
                    and ts.status = 'open' and ts.deleted_at is null) then
        return jsonb_build_object('ok', false, 'reason', 'tablet_busy', 'message', '這台平板正在別的牌局計分，先在那一桌讓出位置');
      end if;
    end if;

    if not p_commit then
      return jsonb_build_object('ok', true, 'preview', true, 'move', true,
        'from_name', v_from, 'from_avatar', v_avatar, 'table', v_table, 'seat', v_row.seat, 'hands', v_hands);
    end if;

    update session_seat_swaps
       set used_at = now(), to_member_id = s.from_member_id, to_device_id = d.id, before_row = to_jsonb(v_row)
     where id = s.id and used_at is null;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'gone', 'message', '這組代碼剛剛被用掉了');
    end if;
    update session_players set device_id = null
     where session_id = s.session_id and device_id = d.id;          -- 保險：這台不會同時綁兩個位置
    update session_players set device_id = d.id where id = v_row.id;
    if d.kind = 'tablet' then
      update table_devices set bound_session_id = s.session_id where id = d.id;   -- 借來的平板記住這一場（_tbl_device 自動回家）
    end if;
    update session_seat_swaps set expires_at = now()
     where player_row_id = v_row.id and used_at is null and expires_at > now();
    perform public._tbl_ping(s.session_id);
    return jsonb_build_object('ok', true, 'moved', true,
      'from_name', v_from, 'table', v_table, 'seat', v_row.seat);
  end if;

  /* ── 換人上桌：別人已配好的手機（2026-10-15，照舊） ── */
  if public._session_scored(s.session_id) then
    return jsonb_build_object('ok', false, 'reason', 'scored', 'message', '這一場成績已經算好了，不能換人');
  end if;
  if exists (select 1 from session_players where session_id = s.session_id and member_id = d.member_id) then
    return jsonb_build_object('ok', false, 'reason', 'already_here', 'message', '你已經在這一桌了');
  end if;
  if exists (select 1 from session_players sp join table_sessions ts on ts.id = sp.session_id
              where sp.member_id = d.member_id and sp.left_at is null
                and ts.status = 'open' and ts.deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'busy_elsewhere', 'message', '你在別桌還有牌局，要先收桌才能接手');
  end if;
  if exists (select 1 from members where id = d.member_id and hidden_at is not null) then
    return jsonb_build_object('ok', false, 'reason', 'hidden', 'message', '你的帳號已隱藏，請洽櫃檯');
  end if;
  if exists (select 1 from hands where session_id = s.session_id and status = 'pending') then
    return jsonb_build_object('ok', false, 'reason', 'pending', 'message', '有一局還在等確認，確認完再換人');
  end if;
  if exists (select 1 from session_busts where session_id = s.session_id and decision = 'pending') then
    return jsonb_build_object('ok', false, 'reason', 'bust', 'message', '有人爆卡還沒決定，決定完再換人');
  end if;

  select coalesce(display_name, '會員') into v_to from members where id = d.member_id;

  if not p_commit then
    return jsonb_build_object('ok', true, 'preview', true,
      'from_name', v_from, 'from_avatar', v_avatar, 'to_name', v_to, 'table', v_table, 'seat', v_row.seat, 'hands', v_hands);
  end if;

  -- ── 真的換 ──
  update session_seat_swaps
     set used_at = now(), to_member_id = d.member_id, to_device_id = d.id, before_row = to_jsonb(v_row)
   where id = s.id and used_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'gone', 'message', '這組代碼剛剛被用掉了');
  end if;

  update session_players set device_id = null
   where session_id = s.session_id and device_id = d.id;          -- 保險：這支手機不會同時綁兩個位置
  update session_players
     set member_id         = d.member_id,
         device_id         = d.id,
         join_type         = 'sub',
         paid_by           = coalesce(paid_by, s.from_member_id),   -- 位置的檯費是 B 出的
         charged_points    = 0,
         fee_waived_reason = case when fee_waived_reason = 'daypass' then 'daypass_swapped' else fee_waived_reason end
   where id = v_row.id;

  -- 包桌加的 2 小時跟著位置走；暢打升級是 B 本人的，不搬
  update session_extensions set member_id = d.member_id
   where session_id = s.session_id and member_id = s.from_member_id and kind = '2h';
  get diagnostics v_moved = row_count;

  -- 🆕 配桌房的名單也換（2026-10-15 修）：B 那一列標成被換下，A 補一列 —— 不然 B 一直被當成「還有一場沒打完」
  with gone as (
    update match_queue_players qp
       set left_at = now(), leave_reason = 'swapped', leave_detail = 'seat_swap'
      from match_queues q
     where q.id = qp.queue_id and q.matched_session_id = s.session_id
       and qp.member_id = s.from_member_id and qp.left_at is null
    returning qp.org_id, qp.queue_id
  )
  insert into match_queue_players (org_id, queue_id, member_id, join_source)
  select g.org_id, g.queue_id, d.member_id, 'swap' from gone g
   where not exists (select 1 from match_queue_players x
                      where x.queue_id = g.queue_id and x.member_id = d.member_id and x.left_at is null);
  get diagnostics v_queues = row_count;

  update session_seat_swaps set moved_extensions = v_moved, moved_queue_rows = v_queues where id = s.id;

  -- 同一個位置還沒用掉的其他碼作廢
  update session_seat_swaps set expires_at = now()
   where player_row_id = v_row.id and used_at is null and expires_at > now();

  perform public._tbl_ping(s.session_id);
  return jsonb_build_object('ok', true, 'swapped', true,
    'from_name', v_from, 'to_name', v_to, 'table', v_table, 'seat', v_row.seat);
end $function$;

-- ── 驗證（單一 SELECT）────────────────────────────────────────────
select
  case when pg_get_functiondef('public._tbl_device(text)'::regprocedure) like '%elsif d.bound_session_id is not null then%'
       then '✅' else '🔴' end || ' ① 借來的平板會換到那一場的桌、離開位置就回家'                       as "①",
  case when pg_get_functiondef('public.tbl_swap_redeem_tx(text,text,boolean)'::regprocedure) like '%v_move := d.kind = ''tablet''%'
        and pg_get_functiondef('public.tbl_swap_redeem_tx(text,text,boolean)'::regprocedure) like '%''from_avatar''%'
       then '✅' else '🔴' end || ' ② 兌換換機代碼認平板與本人手機、預覽回頭像'                         as "②",
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('_tbl_device', 'tbl_swap_redeem_tx')) = 2
        and exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.oid = 'public.tbl_swap_redeem_tx(text,text,boolean)'::regprocedure
                       and a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
       then '✅' else '🔴' end || ' ③ 兩支各一個版本、平板手機照樣叫得動'                                as "③";
