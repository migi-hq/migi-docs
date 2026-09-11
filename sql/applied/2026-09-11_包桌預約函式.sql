/* ============================================================
   包桌預約 RPC：客人四支 ＋ 店員三支 ＋ 內部一支
   2026-09-11 · 接在 `2026-09-11_包桌預約地基.sql`（已跑，6/6）之後

   ⚠ 要留下函式 ⇒ 整份不准 `raise`（硬規則 1.8）。
     行為測試在 `sql/checks/2026-09-11_驗包桌預約流程.sql`。

   ── 誰叫得動 ────────────────────────────────────────
   ```
   客人  booking_capacity_tx · create_booking_tx
         cancel_booking_tx   · list_my_bookings_tx      身分 ＝ JWT
   店員  pos_list_bookings_tx · pos_seat_booking_tx
         pos_mark_booking_tx                            身分 ＝ current_staff()
   ```
   🔴 **POS 這三支也授權給 `authenticated` 不是 `anon`。**
     POS 從 2026-09-04 起有真的 Supabase session（`staff-login` 發的），
     `restoreStaff()` 讀的就是它 ⇒ 請求是以 authenticated 送出的。
   🔴 **權限不走 `can()`** —— 撈過它：除了 `member.lookup`，每一個碼都是
     `role in ('hq','owner')`，開一個 `booking.*` 會變成總部限定，
     而接預約是**前場天天在做的事**。這裡的權限就是「你是不是店員」。

   ── 🔴 為什麼「帶到桌」不順便開桌 ───────────────────
   開桌要牌規、花牌、積分級距、模式（`open_session_tx` 那一整套），
   而**那些不是預約知道的事** —— 客人訂位時還沒決定打台麻還是美麻。
   ⇒ 店員照原本的流程開桌，然後把那個場次掛回預約
     （`p_session_id`，可空）。
   ⚠ 在這裡複製一份開桌邏輯，就是「同一件事兩個做法」——
     而其中一份一定會漏掉下一次改的東西。

   ── 過期不靠排程（硬規則 5.5）────────────────────────
   `play_at + planned_hours` 過了還掛著 `booked` 的，在**列出與建立時**
   順手收成 `expired`。
   🔴 不收的話它會**永遠佔著那個時段的容量**，而症狀是
     「明明沒人訂卻說滿了」—— 一個沒有人查得出原因的拒絕。
   ============================================================ */


/* ─────────────────────────────────────────────────────────
   ① 過期清理（內部）
   ───────────────────────────────────────────────────────── */
create or replace function public._booking_expire(p_store_id uuid default null)
returns int
language plpgsql
as $$
declare v_n int;
begin
  update public.bookings
     set status = 'expired', updated_at = now()
   where status = 'booked'
     and play_at + make_interval(hours => planned_hours) < now()
     and (p_store_id is null or store_id = p_store_id);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

revoke execute on function public._booking_expire(uuid) from public;
revoke execute on function public._booking_expire(uuid) from anon, authenticated;


/* ─────────────────────────────────────────────────────────
   ② booking_capacity_tx —— 送出前先看還剩幾桌
   ───────────────────────────────────────────────────────── */
/* 🎯 這一支存在的理由是**不要讓人填完整張表才被拒絕**。
   ⚠ 它回的數字與 `create_booking_tx` 用的是**同一支**判定 ——
     兩邊各算一份的話會出現「畫面說還有 3 桌，按下去說滿了」。 */
create or replace function public.booking_capacity_tx(p_store_id uuid,
                                                      p_play_at  timestamptz,
                                                      p_hours    int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me  uuid := public.current_member_id();
  v_org uuid := public.current_org_id();
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_hours not in (2, 5, 24) then
    return jsonb_build_object('ok', false, 'reason', 'bad_hours', 'message', '時長只能選 2、5 或 24 小時');
  end if;
  if not exists (select 1 from public.stores s
                  where s.id = p_store_id and s.org_id = v_org and s.deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'bad_store', 'message', '找不到那間門市');
  end if;

  perform public._booking_expire(p_store_id);
  return jsonb_build_object('ok', true)
      || public._booking_capacity(p_store_id, p_play_at, p_hours);
end $$;


/* ─────────────────────────────────────────────────────────
   ③ create_booking_tx
   ───────────────────────────────────────────────────────── */
create or replace function public.create_booking_tx(p_store_id    uuid,
                                                    p_play_at     timestamptz,
                                                    p_hours       int,
                                                    p_table_count int  default 1,
                                                    p_team_id     uuid default null,
                                                    p_party_size  int  default null,
                                                    p_note        text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me   uuid := public.current_member_id();
  v_org  uuid := public.current_org_id();
  v_cap  jsonb;
  v_id   uuid;
  v_name text;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_hours not in (2, 5, 24) then
    return jsonb_build_object('ok', false, 'reason', 'bad_hours', 'message', '時長只能選 2、5 或 24 小時');
  end if;
  if coalesce(p_table_count, 1) < 1 or p_table_count > 10 then
    return jsonb_build_object('ok', false, 'reason', 'bad_count', 'message', '桌數請填 1 到 10');
  end if;

  /* 🔴 兩道時間牆，兩個不同的理由：
     · 太近 —— 店員來不及看到那筆預約，客人到了櫃檯還是要現場處理，
       而畫面已經跟他說「預約成功」了。**那是一個做不到的承諾。**
     · 太遠 —— 三個月後的事誰都說不準，而它會一路佔著容量。 */
  if p_play_at is null or p_play_at < now() + interval '30 minutes' then
    return jsonb_build_object('ok', false, 'reason', 'too_soon',
                              'message', '請至少提前 30 分鐘預約，現在要用請直接到櫃檯');
  end if;
  if p_play_at > now() + interval '90 days' then
    return jsonb_build_object('ok', false, 'reason', 'too_far', 'message', '最多只能預約 90 天內');
  end if;

  select s.name into v_name from public.stores s
   where s.id = p_store_id and s.org_id = v_org and s.deleted_at is null;
  if v_name is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_store', 'message', '找不到那間門市');
  end if;

  /* 掛團的話，**我必須在那個團裡** —— 不然任何人都能用別人的團名訂位，
     而帳算在那個團頭上。 */
  if p_team_id is not null and not exists (
       select 1 from public.team_members tm
        join public.teams t on t.id = tm.team_id and t.deleted_at is null
       where tm.team_id = p_team_id and tm.member_id = v_me and tm.left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'not_member', 'message', '你不在那個牌咖團裡');
  end if;

  perform public._booking_expire(p_store_id);

  /* 🔴 同一組人同一個時段不要重複訂。
     判準是「同一個團」，沒有團就退回「同一個人」——
     而那正是 `team_id` 可空所帶來的兩種身分。 */
  if exists (
       select 1 from public.bookings k
        where k.store_id = p_store_id and k.status = 'booked'
          and (case when p_team_id is not null then k.team_id = p_team_id
                    else k.team_id is null and k.member_id = v_me end)
          and p_play_at < k.play_at + make_interval(hours => k.planned_hours)
          and k.play_at < p_play_at + make_interval(hours => p_hours)) then
    return jsonb_build_object('ok', false, 'reason', 'already_booked',
                              'message', '這個時段你已經有一筆預約了');
  end if;

  v_cap := public._booking_capacity(p_store_id, p_play_at, p_hours);
  if (v_cap->>'free')::int < p_table_count then
    /* ⚠ 話術要給數字，不要只說「滿了」——「還剩 1 桌」他可能就改訂 1 桌。 */
    return jsonb_build_object('ok', false, 'reason', 'no_capacity',
                              'message', '這個時段只剩 ' || (v_cap->>'free') || ' 桌',
                              'capacity', v_cap);
  end if;

  insert into public.bookings (org_id, store_id, team_id, member_id,
                               play_at, planned_hours, table_count, party_size, note)
  values (v_org, p_store_id, p_team_id, v_me,
          p_play_at, p_hours, coalesce(p_table_count, 1), p_party_size,
          nullif(btrim(coalesce(p_note, '')), ''))
  returning id into v_id;

  return jsonb_build_object('ok', true, 'booking_id', v_id, 'store_name', v_name,
                            'message', '已預約 ' || v_name);
end $$;


/* ─────────────────────────────────────────────────────────
   ④ cancel_booking_tx —— 訂的人或團長可以取消
   ───────────────────────────────────────────────────────── */
create or replace function public.cancel_booking_tx(p_booking_id uuid,
                                                    p_reason     text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := public.current_member_id();
  v_b  record;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  select * into v_b from public.bookings where id = p_booking_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這筆預約');
  end if;
  if v_b.status <> 'booked' then
    return jsonb_build_object('ok', false, 'reason', 'already_decided', 'status', v_b.status,
                              'message', case v_b.status
                                when 'seated'    then '這筆已經帶到桌了'
                                when 'cancelled' then '這筆已經取消過了'
                                when 'no_show'   then '這筆已經記成沒有出現'
                                else '這筆已經過期了' end);
  end if;

  /* 訂的人，或那個團的團長。
     🎯 團長也能取消是刻意的 —— 訂的人可能臨時聯絡不上，
       而一筆沒有人取消得掉的預約會一路佔著容量。 */
  if v_b.member_id <> v_me and not (
       v_b.team_id is not null and public._is_team_leader(v_b.team_id, v_me)) then
    return jsonb_build_object('ok', false, 'reason', 'not_yours', 'message', '只有訂位的人或團長可以取消');
  end if;

  /* 🔴 開始時間過了就不給客人自己取消 —— 那時它已經不是「取消」
     而是「沒有出現」，而那兩件事在報表上必須分得開（爽約率）。
     ⚠ 話術要講得出下一步，不要只說不行。 */
  if v_b.play_at <= now() then
    return jsonb_build_object('ok', false, 'reason', 'too_late',
                              'message', '已經過了預約時間，請直接跟門市說一聲');
  end if;

  update public.bookings
     set status = 'cancelled',
         cancelled_reason = coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'member'),
         updated_at = now()
   where id = p_booking_id;

  return jsonb_build_object('ok', true, 'message', '已取消預約');
end $$;


/* ─────────────────────────────────────────────────────────
   ⑤ list_my_bookings_tx —— 我的與我團的
   ───────────────────────────────────────────────────────── */
create or replace function public.list_my_bookings_tx()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me   uuid := public.current_member_id();
  v_rows jsonb;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  perform public._booking_expire(null);

  /* ⚠ 過去的只留 30 天 —— 再久的預約紀錄客人不會看，
     而一個越來越長的清單會把「下一筆什麼時候」埋掉。 */
  select coalesce(jsonb_agg(x order by x->>'play_at'), '[]'::jsonb)
    into v_rows
    from (
      select jsonb_build_object(
               'booking_id',  k.id,
               'store_id',    k.store_id,
               'store_name',  s.name,
               'team_id',     k.team_id,
               'team_name',   t.name,
               'play_at',     k.play_at,
               'hours',       k.planned_hours,
               'table_count', k.table_count,
               'party_size',  k.party_size,
               'note',        k.note,
               'status',      k.status,
               'table_label', tb.label,
               'mine',        k.member_id = v_me) as x
        from public.bookings k
        join public.stores s on s.id = k.store_id
        left join public.teams  t  on t.id  = k.team_id
        left join public.tables tb on tb.id = k.table_id
       where (k.member_id = v_me
              or (k.team_id is not null and exists (
                    select 1 from public.team_members tm
                     where tm.team_id = k.team_id and tm.member_id = v_me and tm.left_at is null)))
         and k.play_at > now() - interval '30 days'
    ) q;

  return jsonb_build_object('ok', true, 'bookings', v_rows);
end $$;


/* ─────────────────────────────────────────────────────────
   ⑥ pos_list_bookings_tx —— 店員看某一天
   ───────────────────────────────────────────────────────── */
create or replace function public.pos_list_bookings_tx(p_store_id uuid,
                                                       p_day      date default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff uuid;
  v_day   date;
  v_from  timestamptz;
  v_rows  jsonb;
begin
  select staff_id into v_staff from public.current_staff();
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '請先登入');
  end if;

  perform public._booking_expire(p_store_id);

  /* 日期用台北日曆日，與當日暢打同一個判準 —— 系統裡不要有第二種「今天」。 */
  v_day  := coalesce(p_day, (now() at time zone 'Asia/Taipei')::date);
  v_from := (v_day::timestamp at time zone 'Asia/Taipei');

  select coalesce(jsonb_agg(x order by x->>'play_at'), '[]'::jsonb)
    into v_rows
    from (
      select jsonb_build_object(
               'booking_id',  k.id,
               /* 🔴 回 `member_id` 是刻意的，而且**只有這一支回** ——
                  店員要能跳到會員查詢確認身分與聯絡。
                  ⚠ **不回手機**：POS 已經有會員查詢那條路，
                    在這裡多帶一份個資是白白擴大暴露面。 */
               'member_id',   k.member_id,
               'nickname',    m.display_name,
               'team_name',   t.name,
               'play_at',     k.play_at,
               'hours',       k.planned_hours,
               'table_count', k.table_count,
               'party_size',  k.party_size,
               'note',        k.note,
               'status',      k.status,
               'table_id',    k.table_id,
               'table_label', tb.label) as x
        from public.bookings k
        join public.members m on m.id = k.member_id
        left join public.teams  t  on t.id  = k.team_id
        left join public.tables tb on tb.id = k.table_id
       where k.store_id = p_store_id
         and k.play_at >= v_from
         and k.play_at <  v_from + interval '1 day'
    ) q;

  return jsonb_build_object('ok', true, 'day', v_day, 'bookings', v_rows);
end $$;


/* ─────────────────────────────────────────────────────────
   ⑦ pos_seat_booking_tx —— 指定桌（開桌是另一條路）
   ───────────────────────────────────────────────────────── */
create or replace function public.pos_seat_booking_tx(p_booking_id uuid,
                                                      p_table_id   uuid,
                                                      p_session_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff uuid;
  v_b     record;
  v_label text;
begin
  select staff_id into v_staff from public.current_staff();
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '請先登入');
  end if;

  select * into v_b from public.bookings where id = p_booking_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這筆預約');
  end if;
  if v_b.status <> 'booked' then
    return jsonb_build_object('ok', false, 'reason', 'bad_status', 'status', v_b.status,
                              'message', '這筆預約的狀態不能帶到桌');
  end if;

  /* 🔴 那張桌必須是**這間店**的。少了這道，店員在 A 店可以把
     B 店的桌指給這筆預約，而兩邊的桌況都會說謊。 */
  select tb.label into v_label from public.tables tb
   where tb.id = p_table_id and tb.store_id = v_b.store_id
     and tb.is_active and tb.deleted_at is null;
  if v_label is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_table', 'message', '那張桌不屬於這間門市');
  end if;

  update public.bookings
     set status = 'seated', table_id = p_table_id,
         seated_session_id = p_session_id, updated_at = now()
   where id = p_booking_id;

  return jsonb_build_object('ok', true, 'table_label', v_label,
                            'message', '已帶到 ' || v_label);
end $$;


/* ─────────────────────────────────────────────────────────
   ⑧ pos_mark_booking_tx —— 沒出現／店家取消
   ───────────────────────────────────────────────────────── */
/* 🔴 `no_show` 與 `cancelled` **不可以合併**。
   前者是客人沒來，後者是取消了 —— 而「爽約率」是日後要不要收訂金
   的唯一依據。合成一個的話那個數字永遠算不出來。 */
create or replace function public.pos_mark_booking_tx(p_booking_id uuid,
                                                      p_status     text,
                                                      p_reason     text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff uuid;
  v_b     record;
begin
  select staff_id into v_staff from public.current_staff();
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '請先登入');
  end if;
  if p_status not in ('no_show', 'cancelled') then
    return jsonb_build_object('ok', false, 'reason', 'bad_status', 'message', '只能標記沒出現或取消');
  end if;

  select * into v_b from public.bookings where id = p_booking_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這筆預約');
  end if;
  if v_b.status <> 'booked' then
    return jsonb_build_object('ok', false, 'reason', 'already_decided', 'status', v_b.status,
                              'message', '這筆已經處理過了');
  end if;

  update public.bookings
     set status = p_status,
         /* ⚠ `cancelled` 一定要有理由（CHECK 擋著）。這裡填 `staff`
            而不是空字串 —— 「誰取消的」在報表上分得開才有意義。 */
         cancelled_reason = case when p_status = 'cancelled'
                                 then coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'staff') end,
         updated_at = now()
   where id = p_booking_id;

  return jsonb_build_object('ok', true, 'message', case p_status
    when 'no_show' then '已記成沒有出現' else '已取消' end);
end $$;


/* ─────────────────────────────────────────────────────────
   ⑨ 授權
   ───────────────────────────────────────────────────────── */
do $$
declare v_sig text;
begin
  foreach v_sig in array array[
    'public.booking_capacity_tx(uuid, timestamptz, int)',
    'public.create_booking_tx(uuid, timestamptz, int, int, uuid, int, text)',
    'public.cancel_booking_tx(uuid, text)',
    'public.list_my_bookings_tx()',
    'public.pos_list_bookings_tx(uuid, date)',
    'public.pos_seat_booking_tx(uuid, uuid, uuid)',
    'public.pos_mark_booking_tx(uuid, text, text)'
  ] loop
    execute format('revoke execute on function %s from public', v_sig);
    execute format('revoke execute on function %s from anon', v_sig);
    execute format('grant  execute on function %s to authenticated', v_sig);
  end loop;
end $$;


/* ============================================================
   驗證（唯讀，不准 raise）
   ============================================================ */
do $$
declare
  v_msg  text := '';
  v_n    int;
  v_line text;
  v_r    jsonb;
begin
  /* ① 八支都在且各一個版本 */
  select count(*) into v_n from pg_proc
   where pronamespace = 'public'::regnamespace
     and proname in ('_booking_expire','booking_capacity_tx','create_booking_tx',
                     'cancel_booking_tx','list_my_bookings_tx','pos_list_bookings_tx',
                     'pos_seat_booking_tx','pos_mark_booking_tx');
  v_msg := v_msg || case when v_n = 8
    then '① ✅ 八支都在，各只有一個版本'
    else '① 🔴 共 ' || v_n || ' 支，預期 8 —— 大於 8 表示建出了多載版本' end;

  /* ② 七支對外：anon 與 PUBLIC 都要是 0 */
  select count(*) into v_n
    from pg_proc p left join lateral aclexplode(p.proacl) a on true
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('booking_capacity_tx','create_booking_tx','cancel_booking_tx',
                       'list_my_bookings_tx','pos_list_bookings_tx','pos_seat_booking_tx',
                       'pos_mark_booking_tx')
     and (a.grantee = 'anon'::regrole::oid or a.grantee = 0)
     and a.privilege_type = 'EXECUTE';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '② ✅ 七支都收掉了 anon 與 PUBLIC'
    else '② 🔴 還有 ' || v_n || ' 筆 anon／PUBLIC 的執行權' end;

  select count(*) into v_n
    from pg_proc p join lateral aclexplode(p.proacl) a on true
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('booking_capacity_tx','create_booking_tx','cancel_booking_tx',
                       'list_my_bookings_tx','pos_list_bookings_tx','pos_seat_booking_tx',
                       'pos_mark_booking_tx')
     and a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE';
  v_msg := v_msg || E'\n' || case when v_n = 7
    then '③ ✅ 七支都授權給 authenticated（正對照 —— 沒有連前端一起關掉）'
    else '③ 🔴 只有 ' || v_n || '/7 —— 預約整條會 403' end;

  select count(*) into v_n
    from pg_proc p left join lateral aclexplode(p.proacl) a on true
   where p.pronamespace = 'public'::regnamespace and p.proname = '_booking_expire'
     and (a.grantee = 'anon'::regrole::oid or a.grantee = 0
          or a.grantee = 'authenticated'::regrole::oid)
     and a.privilege_type = 'EXECUTE';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '④ ✅ _booking_expire 前端叫不到'
    else '④ 🔴 內部函式被授權出去了（' || v_n || ' 筆）' end;

  /* ⑤ 🔴 容量只有一份定義 —— 建立那支必須呼叫同一支判定。
     各算一份的症狀是「畫面說還有 3 桌，按下去說滿了」。 */
  v_msg := v_msg || E'\n' || case
    when position('_booking_capacity' in
           pg_get_functiondef('public.create_booking_tx(uuid,timestamptz,integer,integer,uuid,integer,text)'::regprocedure)) > 0
     and position('_booking_capacity' in
           pg_get_functiondef('public.booking_capacity_tx(uuid,timestamptz,integer)'::regprocedure)) > 0
    then '⑤ ✅ 試算與建立用的是同一支容量判定'
    else '⑤ 🔴 兩邊沒有共用判定 —— 畫面與實際會給不同答案' end;

  /* ⑥⑦ 借真身分實際跑（硬規則 7）。
     ⚠ 這位會員不是店員 ⇒ POS 那支正確答案是 not_staff，
       **那個「被擋下來」才是證據**，證明權限判斷真的走到了。 */
  select m.line_user_id into v_line from public.members m
   where m.line_user_id is not null and m.deleted_at is null
   order by m.created_at limit 1;

  if v_line is null then
    v_msg := v_msg || E'\n⑥⑦ 🔴 找不到綁了 LINE 的會員 —— 測不了，而測不了不等於通過';
  else
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_line, 'role', 'authenticated')::text, true);

    v_r := public.list_my_bookings_tx();
    v_msg := v_msg || E'\n' || case when (v_r->>'ok')::boolean
      then '⑥ ✅ list_my_bookings_tx 跑得動，回 '
           || jsonb_array_length(v_r->'bookings') || ' 筆（還沒有預約，0 是對的）'
      else '⑥ 🔴 回 ' || coalesce(v_r->>'reason', '(沒有 reason)') end;

    /* 真的算一次容量，而且用有桌位的那一間。 */
    v_r := public.booking_capacity_tx(
             (select t.store_id from public.tables t
               where t.is_active and t.deleted_at is null
               group by t.store_id order by count(*) desc limit 1),
             now() + interval '1 day', 5);
    v_msg := v_msg || E'\n' || case when (v_r->>'ok')::boolean
      then '⑦ ✅ booking_capacity_tx 跑得動 · 總 ' || (v_r->>'total')
           || ' · 已訂 ' || (v_r->>'booked') || ' · 可再接 ' || (v_r->>'free')
      else '⑦ 🔴 回 ' || coalesce(v_r->>'reason', '(沒有 reason)') end;

    /* ⑧ 負對照：一般會員叫 POS 那一支要被擋下來。 */
    v_r := public.pos_list_bookings_tx('00000000-0000-0000-0000-000000000000'::uuid);
    v_msg := v_msg || E'\n' || case when coalesce(v_r->>'reason', '') = 'not_staff'
      then '⑧ ✅ 負對照：不是店員的人叫 POS 那支被擋下（權限判斷有走到）'
      else '⑧ 🔴 一般會員叫得動店員的函式：' || coalesce(v_r::text, 'null') end;

    perform set_config('request.jwt.claims', '', true);
  end if;

  /* ⑨ 這份是唯讀的驗證，不該留下任何預約。 */
  select count(*) into v_n from public.bookings;
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '⑨ ✅ 驗證段沒有建出任何預約'
    else '⑨ ⚠ 現在有 ' || v_n || ' 筆預約 —— 若不是真的客人訂的，回頭看驗證段' end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
