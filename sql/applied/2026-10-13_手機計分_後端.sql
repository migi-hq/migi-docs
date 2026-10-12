-- ============================================================================
-- 2026-10-13 手機計分（後端）
-- 使用者拍板：客人用自己的手機計分 —— 把計分板「加到主畫面」，第一次輸入 6 位數配對碼，
--            之後這支手機記住是誰的，入座後打開圖示就直接是他的位置。Android 同一套。
--
-- 做法
--   ① 手機也是 table_devices 的一列：kind = 'phone'、綁一位會員（member_id），不綁桌。
--      _tbl_device() 認出是手機時，把「這位會員現在坐的那一場」的桌換進回傳值
--      ⇒ 其餘十幾支 tbl_* 用 d.table_id 找牌局，一行都不用改。
--   ② 配對碼 table_phone_codes：
--        · 成桌通知（app_notifications type = table_ok）一建立就發一組，24 小時有效、用一次 ⇒ 寫進 LINE 卡片。
--          用掉之後這支手機記住是這位會員的（bound_session_id = null）。
--        · 平板上「改用手機計分」發的碼只限這一場（bound_session_id = 那一場），收桌就失效，
--          而且兌換的那一刻直接接手那個位置 —— 平板上選人是靠互信，所以不讓它變成永久綁定。
--   ③ 每人一台：一個人已經綁了裝置，別台就選不了他；那台裝置 45 秒沒回應才允許接手。
--      「最後上線」改成 15 秒記一次（平板每 5 秒拿一次狀態），斷線判斷才準。
--
-- ⚠ 驗證段不用 raise（硬規則 1.8），最後一支 SELECT 讀回結果。
-- ============================================================================

-- ① table_devices 加「手機」這一種 ------------------------------------------------
alter table public.table_devices
  add column if not exists kind text not null default 'tablet',
  add column if not exists member_id uuid references public.members(id),
  add column if not exists bound_session_id uuid references public.table_sessions(id);

alter table public.table_devices alter column store_id drop not null;
alter table public.table_devices alter column table_id drop not null;

alter table public.table_devices drop constraint if exists table_devices_kind_check;
alter table public.table_devices add constraint table_devices_kind_check check (
  (kind = 'tablet' and table_id is not null and store_id is not null and member_id is null)
  or (kind = 'phone' and member_id is not null and table_id is null)
);

comment on column public.table_devices.kind is
  'tablet＝店裡的平板（綁一張桌）；phone＝客人自己的手機（綁一位會員，桌由他當下坐的那一場決定）';
comment on column public.table_devices.member_id is '手機才有：這支手機是哪位會員的';
comment on column public.table_devices.bound_session_id is
  '手機才有：有值＝只限這一場（平板上發的配對碼），那一場收桌就失效；null＝記住這支手機';

create index if not exists idx_table_devices_member on public.table_devices (member_id) where kind = 'phone' and is_active;

-- ② 配對碼 ------------------------------------------------------------------------
create table if not exists public.table_phone_codes (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null references public.orgs(id),
  member_id        uuid not null references public.members(id),
  code             text not null check (code ~ '^[0-9]{6}$'),
  session_id       uuid references public.table_sessions(id),      -- 有值＝平板發的、只限這一場
  notification_id  uuid references public.app_notifications(id),   -- LINE 卡片讀它
  issued_by_device uuid references public.table_devices(id),       -- 平板發的：哪一台
  expires_at       timestamptz not null,
  used_at          timestamptz,
  used_by_device   uuid references public.table_devices(id),
  created_at       timestamptz not null default now()
);
comment on table public.table_phone_codes is
  '手機計分配對碼（6 位數、用一次）。成桌通知發的會記住手機；平板發的只限那一場';
create index if not exists idx_phone_codes_code on public.table_phone_codes (code) where used_at is null;
create unique index if not exists uq_phone_codes_notif on public.table_phone_codes (notification_id) where notification_id is not null;
alter table public.table_phone_codes enable row level security;   -- 0 policy：只有 DEFINER 進得去

-- 猜錯紀錄（全站共用的上限：10 分鐘內猜錯 60 次就暫停兌換 10 分鐘）
create table if not exists public.table_phone_code_fails (
  at timestamptz not null default now()
);
create index if not exists idx_phone_code_fails_at on public.table_phone_code_fails (at);
alter table public.table_phone_code_fails enable row level security;

-- 發一組新的碼（避開目前還有效的碼）
create or replace function public._tbl_new_phone_code(
  p_org uuid, p_member uuid, p_session uuid, p_notif uuid, p_device uuid, p_expires timestamptz)
returns text
language plpgsql security definer set search_path to 'public'
as $$
declare v_code text; i int := 0;
begin
  loop
    i := i + 1;
    v_code := lpad((floor(random() * 1000000))::int::text, 6, '0');
    exit when not exists (select 1 from table_phone_codes
                           where code = v_code and used_at is null and expires_at > now());
    if i > 50 then raise exception '配對碼產生失敗'; end if;
  end loop;
  insert into table_phone_codes (org_id, member_id, code, session_id, notification_id, issued_by_device, expires_at)
  values (p_org, p_member, v_code, p_session, p_notif, p_device, p_expires);
  return v_code;
end $$;

-- 這台裝置是不是斷線了（45 秒沒回應，或已停用）
create or replace function public._tbl_device_stale(p_device uuid)
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select coalesce((select not d.is_active or d.last_seen_at is null or d.last_seen_at < now() - interval '45 seconds'
                     from table_devices d where d.id = p_device), true);
$$;

-- ③ 認裝置：手機換上「它主人現在坐的那一場」的桌 --------------------------------------
create or replace function public._tbl_device(p_token text)
returns table_devices
language plpgsql security definer set search_path to 'public'
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
    d.table_id := v_table;   -- 只改回傳值，不寫回資料表
    d.store_id := v_store;
  end if;
  return d;
end $function$;

-- ④ 選人：手機只能選自己；別台斷線 45 秒才能接手 ----------------------------------------
create or replace function public.tbl_claim_seat_tx(p_token text, p_player_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare d public.table_devices; v_session uuid; v_owner uuid; v_member uuid;
begin
  d := public._tbl_device(p_token);
  select id into v_session from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if v_session is null then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;

  select device_id, member_id into v_owner, v_member from session_players
   where id = p_player_id and session_id = v_session and left_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_in_session', 'message', '這個人不在這一桌');
  end if;
  if d.kind = 'phone' and v_member <> d.member_id then
    return jsonb_build_object('ok', false, 'reason', 'not_yours', 'message', '手機只能選你自己');
  end if;
  /* 每人一台：已經有別台的，那台要斷線 45 秒以上才能接手 */
  if v_owner is not null and v_owner <> d.id and not public._tbl_device_stale(v_owner) then
    return jsonb_build_object('ok', false, 'reason', 'taken', 'message', '這個人已經在另一台裝置上了');
  end if;

  -- 這台原本綁的是別人 ⇒ 先放掉
  update session_players set device_id = null
   where session_id = v_session and device_id = d.id and id <> p_player_id;
  begin
    update session_players set device_id = d.id where id = p_player_id;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'reason', 'taken', 'message', '這個人剛剛被另一台裝置選走了');
  end;

  perform public._tbl_ping(v_session);
  return jsonb_build_object('ok', true, 'took_over', v_owner is not null and v_owner <> d.id);
end $function$;

-- ⑤ 兌換配對碼（手機還沒有憑證，所以 anon 叫得到） --------------------------------------
create or replace function public.tbl_phone_redeem_tx(p_code text, p_token text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_code text := regexp_replace(coalesce(p_code, ''), '\D', '', 'g');
  c public.table_phone_codes; d public.table_devices; v_token text; v_name text;
begin
  if (select count(*) from table_phone_code_fails where at > now() - interval '10 minutes') >= 60 then
    return jsonb_build_object('ok', false, 'reason', 'busy', 'message', '輸入錯誤太多次，請 10 分鐘後再試');
  end if;
  if length(v_code) <> 6 then
    return jsonb_build_object('ok', false, 'reason', 'bad_code', 'message', '配對碼是 6 位數字');
  end if;

  select * into c from table_phone_codes
   where code = v_code and used_at is null and expires_at > now()
   order by created_at desc limit 1
   for update;
  if not found then
    insert into table_phone_code_fails default values;
    return jsonb_build_object('ok', false, 'reason', 'bad_code', 'message', '配對碼不對，或已經用過、過期了');
  end if;
  if c.session_id is not null and not exists (
       select 1 from table_sessions where id = c.session_id and status = 'open' and deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'session_closed', 'message', '這一場已經結束了');
  end if;

  /* 這支手機已經配對過（換成別人的碼）⇒ 沿用同一個憑證，改成新主人 */
  if p_token is not null and length(p_token) >= 32 then
    select * into d from table_devices
     where token_hash = public._tbl_hash(p_token) and is_active and kind = 'phone';
  end if;
  if d.id is not null then
    update table_devices set member_id = c.member_id, bound_session_id = c.session_id, org_id = c.org_id,
                             last_seen_at = now()
     where id = d.id;
    v_token := p_token;
  else
    v_token := encode(extensions.gen_random_bytes(32), 'hex');
    insert into table_devices (org_id, kind, member_id, bound_session_id, label, token_hash, last_seen_at)
    values (c.org_id, 'phone', c.member_id, c.session_id, '手機', public._tbl_hash(v_token), now())
    returning * into d;
  end if;

  update table_phone_codes set used_at = now(), used_by_device = d.id where id = c.id;

  /* 平板發的碼：兌換的那一刻直接接手那個位置（原本那台平板變成沒有位置 ⇒ 觀看） */
  if c.session_id is not null then
    update session_players set device_id = null
     where session_id = c.session_id and device_id = d.id and member_id <> c.member_id;
    update session_players set device_id = d.id
     where session_id = c.session_id and member_id = c.member_id and left_at is null;
    perform public._tbl_ping(c.session_id);
  end if;

  select display_name into v_name from members where id = c.member_id;
  return jsonb_build_object('ok', true, 'token', v_token, 'name', v_name, 'this_game_only', c.session_id is not null);
end $function$;

-- ⑥ 平板「改用手機計分」：替這台平板選的那個人發一組只限這一場的碼 ------------------------
create or replace function public.tbl_phone_code_tx(p_token text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare d public.table_devices; s public.table_sessions; v_member uuid; v_code text;
begin
  d := public._tbl_device(p_token);
  if d.kind <> 'tablet' then
    return jsonb_build_object('ok', false, 'reason', 'not_tablet', 'message', '請在平板上操作');
  end if;
  select * into s from table_sessions where table_id = d.table_id and status = 'open' and deleted_at is null;
  if s.id is null then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  select member_id into v_member from session_players
   where session_id = s.id and device_id = d.id and left_at is null;
  if v_member is null then
    return jsonb_build_object('ok', false, 'reason', 'no_seat', 'message', '請先選你自己');
  end if;
  -- 同一台平板再按一次：舊的碼作廢，只留最新的一組
  update table_phone_codes set expires_at = now()
   where issued_by_device = d.id and session_id = s.id and used_at is null and expires_at > now();
  v_code := public._tbl_new_phone_code(s.org_id, v_member, s.id, null, d.id, now() + interval '12 hours');
  return jsonb_build_object('ok', true, 'code', v_code);
end $function$;

-- ⑦ 成桌通知一建立就發一組（LINE 卡片讀它） -------------------------------------------
create or replace function public._tbl_phone_code_on_table_ok()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
begin
  if new.type = 'table_ok' and new.member_id is not null then
    perform public._tbl_new_phone_code(new.org_id, new.member_id, null, new.id, null, now() + interval '24 hours');
  end if;
  return null;
end $$;
drop trigger if exists trg_app_notifications_phone_code on public.app_notifications;
create trigger trg_app_notifications_phone_code
  after insert on public.app_notifications
  for each row when (new.type = 'table_ok')
  execute function public._tbl_phone_code_on_table_ok();

-- ⑧ LINE 卡片的欄位多一個 phone_code ------------------------------------------------
do $$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('public._push_fields(uuid)'::regprocedure);
  v_new := replace(v_def,
    $s$'name',     q.my_name,$s$,
    $s$'phone_code', (select pc.code from table_phone_codes pc where pc.notification_id = n.id
                      and pc.used_at is null and pc.expires_at > now()),   -- 手機計分配對碼（2026-10-13）
    'name',     q.my_name,$s$);
  if v_new = v_def then raise exception '_push_fields：找不到要插入的位置'; end if;
  execute v_new;
end $$;

-- ⑨ LINE 卡片：加一格配對碼、一條「第一次用？加到主畫面」 ------------------------------
do $$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('public._push_flex(uuid)'::regprocedure);
  -- 配對碼那一格放在「請準時到店」上面
  v_new := replace(v_def,
    $s$jsonb_build_object('type', 'text', 'text', '請準時到店，到櫃檯報到就能入座。',$s$,
    $s$jsonb_build_object('type', 'box', 'layout', 'vertical', 'margin', 'lg', 'paddingAll', '10px',
                             'backgroundColor', '#FFF6F8', 'cornerRadius', 'md',
            'contents', case when f ->> 'phone_code' is null then jsonb_build_array(
                jsonb_build_object('type', 'text', 'text', '手機計分：配對碼已用過，打開主畫面的計分板就好', 'size', 'xxs',
                                   'color', '#8B8582', 'wrap', true))
              else jsonb_build_array(
                jsonb_build_object('type', 'text', 'text', '手機計分配對碼', 'size', 'xs', 'color', '#8B8582'),
                jsonb_build_object('type', 'text', 'text', substr(f ->> 'phone_code', 1, 3) || ' ' || substr(f ->> 'phone_code', 4, 3),
                                   'size', 'xl', 'weight', 'bold', 'color', '#2E2B2C', 'margin', 'xs'),
                jsonb_build_object('type', 'text', 'text', '打開手機主畫面的「MIGI 計分板」輸入；輸入過一次，之後就不用了。', 'size', 'xxs',
                                   'color', '#8B8582', 'wrap', true, 'margin', 'xs')) end),
          jsonb_build_object('type', 'text', 'text', '請準時到店，到櫃檯報到就能入座。',$s$);
  if v_new = v_def then raise exception '_push_flex：找不到配對碼要插入的位置'; end if;
  -- 「查看牌局詳情」下面一行小連結：跳出 LINE、用手機的瀏覽器開（LINE 裡的瀏覽器不能加到主畫面）
  v_def := v_new;
  v_new := replace(v_def,
    $s$jsonb_build_object('type', 'text', 'text', '查看牌局詳情', 'size', 'sm', 'weight', 'bold',
                                 'color', '#2E2B2C', 'align', 'center')))))));$s$,
    $s$jsonb_build_object('type', 'text', 'text', '查看牌局詳情', 'size', 'sm', 'weight', 'bold',
                                 'color', '#2E2B2C', 'align', 'center'))),
          jsonb_build_object('type', 'text', 'text', '第一次用？把計分板加到手機主畫面', 'size', 'xs',
                             'color', '#2A62C9', 'decoration', 'underline', 'align', 'center', 'margin', 'md',
                             'action', jsonb_build_object('type', 'uri', 'label', '加到主畫面',
                                                          'uri', 'https://table.migi.tw/?install=1&openExternalBrowser=1'))))));$s$);
  if v_new = v_def then raise exception '_push_flex：找不到按鈕的位置'; end if;
  execute v_new;
end $$;

-- ⑩ 平板狀態：每個人多兩格（is_mine：這支手機的主人；stale：綁的那台斷線了），裝置多 kind 與主人 ------
do $$
declare v_def text; v_new text; n int;
begin
  v_def := pg_get_functiondef('public._tbl_state_for_device(public.table_devices)'::regprocedure);
  v_new := replace(v_def,
    $s$'bound', sp.device_id is not null, 'is_me', sp.device_id = d.id)$s$,
    $s$'bound', sp.device_id is not null, 'is_me', sp.device_id = d.id,
           'is_mine', d.kind = 'phone' and sp.member_id = d.member_id,
           'stale', sp.device_id is not null and sp.device_id <> d.id and public._tbl_device_stale(sp.device_id),
           'device_label', (select td.label from table_devices td where td.id = sp.device_id))$s$);
  if v_new = v_def then raise exception '_tbl_state_for_device：找不到玩家欄位'; end if;
  n := (length(v_new) - length(replace(v_new, $s$jsonb_build_object('label', d.label, 'table', v_table, 'store', v_store)$s$, '')))
       / length($s$jsonb_build_object('label', d.label, 'table', v_table, 'store', v_store)$s$);
  if n < 1 then raise exception '_tbl_state_for_device：找不到裝置欄位'; end if;
  v_new := replace(v_new,
    $s$jsonb_build_object('label', d.label, 'table', v_table, 'store', v_store)$s$,
    $s$jsonb_build_object('label', d.label, 'table', v_table, 'store', v_store, 'kind', d.kind,
                          'owner', (select m.display_name from members m where m.id = d.member_id))$s$);
  execute v_new;
  perform set_config('migi.state_dev_n', n::text, true);
end $$;

-- ⑪ 授權：兩支新的給前端（手機還沒憑證 ⇒ anon）；內部用的三支不開 --------------------------
grant execute on function public.tbl_phone_redeem_tx(text, text) to anon, authenticated;
grant execute on function public.tbl_phone_code_tx(text) to anon, authenticated;
revoke execute on function public._tbl_new_phone_code(uuid, uuid, uuid, uuid, uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public._tbl_device_stale(uuid) from public, anon, authenticated;
revoke execute on function public._tbl_phone_code_on_table_ok() from public, anon, authenticated;

-- ============================================================================
-- 驗證（單一 SELECT）
-- ============================================================================
select concat_ws(E'\n',
  case when (select count(*) from information_schema.columns where table_schema='public' and table_name='table_devices'
              and column_name in ('kind','member_id','bound_session_id')) = 3
       then '✅ ① table_devices 多了 kind／member_id／bound_session_id' else '🔴 ① 欄位不齊' end,
  case when (select count(*) from table_devices where kind <> 'tablet') = 0
            and (select count(*) from table_devices where table_id is null) = 0
       then '✅ ① 既有 ' || (select count(*) from table_devices) || ' 台平板全部是 tablet、都還綁著桌（沒被誤動）'
       else '🔴 ① 既有平板被動到' end,
  case when to_regclass('public.table_phone_codes') is not null and to_regclass('public.table_phone_code_fails') is not null
       then '✅ ② 配對碼兩張表建好了' else '🔴 ② 配對碼的表不在' end,
  case when pg_get_functiondef('public._tbl_device(text)'::regprocedure) ~ 'd\.kind = ''phone'''
            and pg_get_functiondef('public._tbl_device(text)'::regprocedure) ~ '15 seconds'
       then '✅ ③ _tbl_device 認得手機、15 秒記一次上線' else '🔴 ③ _tbl_device 沒改到' end,
  case when pg_get_functiondef('public.tbl_claim_seat_tx(text,uuid)'::regprocedure) ~ '_tbl_device_stale\(v_owner\)'
            and pg_get_functiondef('public.tbl_claim_seat_tx(text,uuid)'::regprocedure) ~ 'not_yours'
       then '✅ ④ 選人：手機只能選自己、斷線才能接手' else '🔴 ④ 選人沒改到' end,
  case when has_function_privilege('anon', 'public.tbl_phone_redeem_tx(text,text)', 'execute')
            and has_function_privilege('anon', 'public.tbl_phone_code_tx(text)', 'execute')
       then '✅ ⑤⑥ 兌換與發碼 anon 叫得到（手機與平板都沒登入）' else '🔴 ⑤⑥ 前端叫不到' end,
  case when not has_function_privilege('anon', 'public._tbl_new_phone_code(uuid,uuid,uuid,uuid,uuid,timestamptz)', 'execute')
            and not has_function_privilege('anon', 'public._tbl_device_stale(uuid)', 'execute')
       then '✅ ⑪ 內部函式前端叫不到' else '🔴 ⑪ 內部函式開給了前端' end,
  case when exists (select 1 from pg_trigger where tgname = 'trg_app_notifications_phone_code' and not tgisinternal)
       then '✅ ⑦ 成桌通知會發配對碼' else '🔴 ⑦ 觸發器不在' end,
  case when pg_get_functiondef('public._push_fields(uuid)'::regprocedure) ~ 'phone_code'
            and pg_get_functiondef('public._push_flex(uuid)'::regprocedure) ~ '手機計分配對碼'
            and pg_get_functiondef('public._push_flex(uuid)'::regprocedure) ~ 'openExternalBrowser'
       then '✅ ⑧⑨ LINE 卡片有配對碼與「加到主畫面」' else '🔴 ⑧⑨ 卡片沒改到' end,
  case when pg_get_functiondef('public._tbl_state_for_device(public.table_devices)'::regprocedure) ~ 'is_mine'
            and pg_get_functiondef('public._tbl_state_for_device(public.table_devices)'::regprocedure) ~ '''kind'', d\.kind'
       then '✅ ⑩ 平板狀態多了 is_mine／stale／kind（裝置欄位換了 '
            || coalesce(nullif(current_setting('migi.state_dev_n', true), ''), '?') || ' 處）'
       else '🔴 ⑩ 狀態沒改到' end
) as "驗證";
