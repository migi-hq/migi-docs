-- ════════════════════════════════════════════════════════════════════
-- 2026-10-15 智慧計分板：換人上桌（使用者：「用 A 手機的計分器接 B 手機（正在打）的位置，帳號換過去、成績也接過去」）
--
-- 拍板（使用者選「換人上桌」，不是同一個人換手機）：
--   · A 坐上 B 的位置接著打；這個位置的帳號從 B 換成 A
--   · B 已經打的分數全部算 A 的（名次、桌上積分、段位分、牌局成就都在結算時照座位發給 A）
--   · B 這一場算沒打（他的那一列整列換成 A，B 在這一場不留任何成績）
--
-- 流程：
--   ① B 那台（平板或手機，要已經選了 B）按「換人上桌」→ tbl_swap_code_tx 給一組 6 位數代碼，10 分鐘內有效
--   ② A 打開自己手機上的計分板（手機已配對、身分是 A）→「接手別人的位置」→ 輸入代碼
--      → tbl_swap_redeem_tx(p_commit = false) 先回「你要接手誰、哪一桌」給 A 看
--      → A 按確認 → tbl_swap_redeem_tx(p_commit = true) 真的換
--   ⇒ 一定要 B 那台先產生代碼：B 不同意，沒有人搶得走他的位置
--
-- 換的時候：
--   · session_players 那一列：member_id B → A、device_id 換成 A 的手機、join_type = 'sub'（欄位早就預留這個值）
--   · 檯費：B 付過的 ⇒ 這個位置照樣算付過，A 不用再付。記成 paid_by = B（同「代付」：位置的錢是 B 出的），charged_points 歸 0
--     （原本的數字留在 session_seat_swaps.before_row）
--   · 包桌加的「2 小時」跟著位置走（B 已經付了那段時間）；
--     🔴 暢打不跟：暢打是 B 本人的（同一天到別桌仍然免），不可以變成兩個位置用一張暢打 ——
--       那一列若是用暢打免的，原因改記 'daypass_swapped'（金額照留，報表找得到），A 這個位置改成照時間算
--   · 擋：成績已經算好、有一局在等確認、有人爆卡還沒決定、A 已經在這一桌、A 在別桌還有牌局、A 的帳號已隱藏
--   · 錯太多次：同一支手機 10 分鐘內錯 8 次就先擋（代碼只有 6 位數，要防亂猜）
--
-- ⚠ 已知取捨：換人前 B 爆卡當下就發的成就（爆卡那一刻觸發）不收回；其餘牌局成就都在結算時才發，會發給 A
-- ⚠ 新增一個指向 members 的外鍵（from／to member）⇒ 會員合併的盤點（待辦 15）要多搬兩欄
-- ════════════════════════════════════════════════════════════════════

-- ① 換人紀錄（同時是代碼表與稽核）
create table if not exists public.session_seat_swaps (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.orgs(id) on delete restrict,
  session_id        uuid not null references public.table_sessions(id) on delete restrict,
  player_row_id     uuid not null references public.session_players(id) on delete restrict,
  from_member_id    uuid not null references public.members(id) on delete restrict,
  code              text not null check (code ~ '^[0-9]{6}$'),
  issued_device_id  uuid references public.table_devices(id),
  expires_at        timestamptz not null,
  created_at        timestamptz not null default now(),
  used_at           timestamptz,
  to_member_id      uuid references public.members(id) on delete restrict,
  to_device_id      uuid references public.table_devices(id),
  before_row        jsonb,          -- 換人前那一列的原樣（檯費、免收原因都在裡面）
  moved_extensions  integer
);
comment on table public.session_seat_swaps is
  '計分板換人上桌：B 那台產生代碼、A 的手機輸入代碼接手。used_at 有值＝真的換了；before_row 是換人前那一列的原樣（2026-10-15）';
create index if not exists idx_seat_swaps_code on public.session_seat_swaps (code) where used_at is null;
create index if not exists idx_seat_swaps_session on public.session_seat_swaps (session_id);
alter table public.session_seat_swaps enable row level security;   -- 0 條 policy：只有 DEFINER 函式進得去
revoke all on public.session_seat_swaps from anon, authenticated;

-- ② 輸錯紀錄（擋亂猜）
create table if not exists public.session_swap_tries (
  device_id  uuid not null references public.table_devices(id),
  at         timestamptz not null default now()
);
create index if not exists idx_swap_tries on public.session_swap_tries (device_id, at);
alter table public.session_swap_tries enable row level security;
revoke all on public.session_swap_tries from anon, authenticated;

-- ③ B 那台：產生換人代碼
create or replace function public.tbl_swap_code_tx(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare d public.table_devices; v_session uuid; v_row public.session_players; v_code text; v_exp timestamptz; i int;
begin
  d := public._tbl_device(p_token);
  select id into v_session from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if v_session is null then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  select * into v_row from session_players
   where session_id = v_session and device_id = d.id and left_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_seated', 'message', '這台還沒選人，選了自己之後才能換人');
  end if;
  if public._session_scored(v_session) then
    return jsonb_build_object('ok', false, 'reason', 'scored', 'message', '這一場成績已經算好了，不能換人');
  end if;

  -- 同一個位置之前給的碼一律作廢（只認最新的那一組）
  update session_seat_swaps set expires_at = now()
   where player_row_id = v_row.id and used_at is null and expires_at > now();

  v_exp := now() + interval '10 minutes';
  for i in 1..20 loop
    -- 亂數取自 gen_random_uuid（強亂數）：取 28 位元（一定是正數），再取 6 位數
    v_code := lpad((('x' || substr(md5(gen_random_uuid()::text), 1, 7))::bit(28)::int % 1000000)::text, 6, '0');
    exit when not exists (select 1 from session_seat_swaps
                           where code = v_code and used_at is null and expires_at > now());
    v_code := null;
  end loop;
  if v_code is null then
    return jsonb_build_object('ok', false, 'reason', 'busy', 'message', '系統忙碌中，請再按一次');
  end if;

  insert into session_seat_swaps (org_id, session_id, player_row_id, from_member_id, code, issued_device_id, expires_at)
  values (v_row.org_id, v_session, v_row.id, v_row.member_id, v_code, d.id, v_exp);

  return jsonb_build_object('ok', true, 'code', v_code, 'expires_at', v_exp);
end $function$;

-- ④ A 的手機：輸入代碼接手（p_commit = false 只回要接手的是誰，true 才真的換）
create or replace function public.tbl_swap_redeem_tx(p_token text, p_code text, p_commit boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  d public.table_devices; s public.session_seat_swaps; v_row public.session_players; v_sess public.table_sessions;
  v_code text; v_fails int; v_from text; v_to text; v_table text; v_hands int; v_moved int;
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
  update session_seat_swaps set moved_extensions = v_moved where id = s.id;

  -- 同一個位置還沒用掉的其他碼作廢
  update session_seat_swaps set expires_at = now()
   where player_row_id = v_row.id and used_at is null and expires_at > now();

  perform public._tbl_ping(s.session_id);
  return jsonb_build_object('ok', true, 'swapped', true,
    'from_name', v_from, 'to_name', v_to, 'table', v_table, 'seat', v_row.seat);
end $function$;

-- ⑤ 授權：計分板用 anon 金鑰 ＋ 裝置憑證認身分（同其他 tbl_ 函式）
revoke all on function public.tbl_swap_code_tx(text) from public;
revoke all on function public.tbl_swap_redeem_tx(text, text, boolean) from public;
grant execute on function public.tbl_swap_code_tx(text) to anon, authenticated;
grant execute on function public.tbl_swap_redeem_tx(text, text, boolean) to anon, authenticated;

-- ════════════ 驗證（單一 SELECT，不 raise）════════════
select string_agg(x, E'\n' order by n) as "驗證" from (
  select 1 n, case when to_regclass('public.session_seat_swaps') is not null
                    and (select relrowsecurity from pg_class where oid = 'public.session_seat_swaps'::regclass)
              then '✅ ① 換人紀錄表在、RLS 開著' else '🔴 ① 換人紀錄表' end x
  union all
  select 2, case when to_regclass('public.session_swap_tries') is not null
                  and (select relrowsecurity from pg_class where oid = 'public.session_swap_tries'::regclass)
              then '✅ ② 輸錯紀錄表在、RLS 開著' else '🔴 ② 輸錯紀錄表' end
  union all
  select 3, case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
                        and proname in ('tbl_swap_code_tx', 'tbl_swap_redeem_tx')) = 2
              then '✅ ③ 兩支函式各一個版本' else '🔴 ③ 函式數量不對' end
  union all
  select 4, case when has_function_privilege('anon', 'public.tbl_swap_code_tx(text)', 'execute')
                  and has_function_privilege('anon', 'public.tbl_swap_redeem_tx(text, text, boolean)', 'execute')
              then '✅ ④ 計分板叫得動（anon）' else '🔴 ④ anon 叫不動' end
  union all
  select 5, case when not has_table_privilege('anon', 'public.session_seat_swaps', 'select')
                  and not has_table_privilege('anon', 'public.session_swap_tries', 'select')
              then '✅ ⑤ 兩張表 anon 讀不到' else '🔴 ⑤ anon 讀得到' end
  union all
  select 6, coalesce((select '✅ ⑥ 擋亂猜：輸錯 ' || (regexp_match(pg_get_functiondef('public.tbl_swap_redeem_tx(text,text,boolean)'::regprocedure),
                       'v_fails >= (\d+)'))[1] || ' 次就擋'), '🔴 ⑥ 沒有擋亂猜')
) t;
