-- ════════════════════════════════════════════════════════════════════
-- 2026-10-15 修：換人上桌之後，被換下的人不能報名配桌（使用者回報）
--
-- 原因：換人只改了 session_players（牌局座位），**配桌房的名單（match_queue_players）沒改**。
--   被換下的 B 在那個房裡仍是「還在房裡」，而房的狀態是 seated、那張桌還開著
--   ⇒ _check_join_conflict 認定 B「還有一場沒打完」⇒ B 報不了新的配桌；
--   會員 App 的配桌頁也會把那一場當成 B 正在打的牌局。接手的 A 反而不在名單上。
-- 實例：今晚 yuhsin → Ren.（session 01f07eb9…，配桌來的，還開著）
--
-- 修法：
--   ① 名單新增一個離開原因 'swapped'（被換人上桌換下）——
--      🔴 不借用 'switched'：那個值已經專門表示「店員把人移到別的房」（2026-09-10），借來用就是一個詞兩種意思
--   ② tbl_swap_redeem_tx：換人時，這一場配桌房裡 B 那一列標成離開（swapped），再替 A 補一列（join_source = 'swap'）
--      ⇒ 房的人數不變；B 的配桌頁不再掛著這一場；A 的配桌紀錄有這一場
--   ③ 今晚已經換過的那一筆照同樣規則補修
--   ④ 換人紀錄多一欄 moved_queue_rows（換了幾個房的名單），稽核用
-- ════════════════════════════════════════════════════════════════════

-- ① 離開原因多一個值
alter table public.match_queue_players drop constraint match_queue_players_leave_reason_check;
alter table public.match_queue_players add constraint match_queue_players_leave_reason_check
  check (leave_reason = any (array['quit', 'cancelled', 'expired', 'switched', 'staff_removed', 'swapped']));

-- ④ 換人紀錄記下動了幾個房的名單
alter table public.session_seat_swaps add column if not exists moved_queue_rows integer;

-- ② 換人時連配桌名單一起換（其餘跟 2026-10-15_計分板換人上桌.sql 一字不差）
create or replace function public.tbl_swap_redeem_tx(p_token text, p_code text, p_commit boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  d public.table_devices; s public.session_seat_swaps; v_row public.session_players; v_sess public.table_sessions;
  v_code text; v_fails int; v_from text; v_to text; v_table text; v_hands int; v_moved int; v_queues int;
begin
  d := public._tbl_device(p_token);
  if d.kind <> 'phone' or d.member_id is null then
    return jsonb_build_object('ok', false, 'reason', 'phone_only', 'message', '要用接手的人自己的手機計分板輸入');
  end if;

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
  if s.from_member_id = d.member_id then
    return jsonb_build_object('ok', false, 'reason', 'self', 'message', '這就是你自己的位置');
  end if;
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

  select coalesce(display_name, '會員') into v_from from members where id = s.from_member_id;
  select coalesce(display_name, '會員') into v_to   from members where id = d.member_id;
  select label into v_table from tables where id = v_sess.table_id;
  select count(*) into v_hands from hands
   where session_id = s.session_id and status = 'confirmed' and result not in ('kala', 'bonus');

  if not p_commit then
    return jsonb_build_object('ok', true, 'preview', true,
      'from_name', v_from, 'to_name', v_to, 'table', v_table, 'seat', v_row.seat, 'hands', v_hands);
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
-- CREATE OR REPLACE、簽名沒變 ⇒ 原本的授權（anon, authenticated）不會掉

-- ③ 今晚已經換過的那幾筆，照同樣規則補修（只修「B 還掛在名單上」的）
do $$
declare w record; n int;
begin
  for w in select * from session_seat_swaps where used_at is not null loop
    with gone as (
      update match_queue_players qp
         set left_at = w.used_at, leave_reason = 'swapped', leave_detail = 'seat_swap'
        from match_queues q
       where q.id = qp.queue_id and q.matched_session_id = w.session_id
         and qp.member_id = w.from_member_id and qp.left_at is null
      returning qp.org_id, qp.queue_id
    )
    insert into match_queue_players (org_id, queue_id, member_id, join_source, joined_at)
    select g.org_id, g.queue_id, w.to_member_id, 'swap', w.used_at from gone g
     where not exists (select 1 from match_queue_players x
                        where x.queue_id = g.queue_id and x.member_id = w.to_member_id and x.left_at is null);
    get diagnostics n = row_count;
    update session_seat_swaps set moved_queue_rows = coalesce(moved_queue_rows, 0) + n where id = w.id;
  end loop;
end $$;

-- ════════════ 驗證（單一 SELECT，不 raise）════════════
select string_agg(x, E'\n' order by n) as "驗證" from (
  select 1 n, case when pg_get_constraintdef((select oid from pg_constraint where conname = 'match_queue_players_leave_reason_check')) ~ 'swapped'
                    and pg_get_constraintdef((select oid from pg_constraint where conname = 'match_queue_players_leave_reason_check')) ~ 'switched'
              then '✅ ① 離開原因多了 swapped（原本的 switched 還在）' else '🔴 ① 離開原因' end x
  union all
  select 2, case when pg_get_functiondef('public.tbl_swap_redeem_tx(text,text,boolean)'::regprocedure) ~ 'leave_reason = ''swapped'''
                  and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'tbl_swap_redeem_tx') = 1
              then '✅ ② 換人函式會一起換配桌名單（一個版本）' else '🔴 ② 換人函式沒改到' end
  union all
  select 3, case when has_function_privilege('anon', 'public.tbl_swap_redeem_tx(text, text, boolean)', 'execute')
              then '✅ ③ 計分板仍叫得動' else '🔴 ③ anon 叫不動' end
  union all
  -- ④ 每一筆換過的：被換下的人在那一場的房裡已經不在名單上
  select 4, case when not exists (
                   select 1 from session_seat_swaps w
                     join match_queues q on q.matched_session_id = w.session_id
                     join match_queue_players qp on qp.queue_id = q.id and qp.member_id = w.from_member_id and qp.left_at is null
                    where w.used_at is not null)
              then '✅ ④ 被換下的人都已經不在那一場的配桌名單上（共 '
                   || (select count(*) from session_seat_swaps where used_at is not null) || ' 筆換人）'
              else '🔴 ④ 還有人掛在名單上' end
  union all
  -- ⑤ 正對照：接手的人在名單上，而且房的人數沒少
  select 5, coalesce((select case when bool_and(exists (select 1 from match_queue_players qp where qp.queue_id = q.id and qp.member_id = w.to_member_id and qp.left_at is null))
                                then '✅ ⑤ 接手的人都補進名單了；房裡在名單上的人數：'
                                     || string_agg((select count(*) from match_queue_players qp where qp.queue_id = q.id and qp.left_at is null)::text, '、')
                                else '🔴 ⑤ 接手的人沒補進名單' end
                       from session_seat_swaps w join match_queues q on q.matched_session_id = w.session_id
                      where w.used_at is not null), '⚪ ⑤ 沒有配桌來的換人紀錄，這格測不了')
) t;
