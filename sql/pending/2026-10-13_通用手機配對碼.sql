-- ============================================================
-- 通用手機配對碼：後台直接產生、傳給任何一位，不用先找人；手機點「我是誰」就永久記住
-- 2026-10-13 · MIGI 咪吉麻將
--
-- 使用者：「最方便是直接生成，傳給任何一位，也不用找人」→ 選「點了我是誰就永久記住」
--
-- 流程：
--   ① 後台（總部，device.write）選門市 → admin_open_phone_code_tx(門市) 產生一組碼：不指定人，24 小時、用一次
--   ② 手機輸入碼（tbl_phone_redeem_tx）⇒ 一支「還沒選人」的手機（member_id null，記下門市）
--   ③ 手機打開 ⇒ tbl_phone_candidates_tx 列出「這間店開著的牌局裡，在座、座位還沒有裝置在用」的客人（依桌分組）
--   ④ 點自己 ⇒ tbl_phone_pick_tx：這支手機永久變成他的（member_id 寫上），同時接上他的座位
--      之後跟一般配對好的手機一樣：他坐哪一桌都跟著走
--
-- ⚠ 使用者知道的風險：拿到碼的人點錯人（或故意點別人），那支手機就會一直替那個人計分。
--   ⇒ 候選名單只列「座位還沒有裝置、或那台斷線超過 45 秒」的人 —— 已經有裝置在計分的人搶不走；
--     點完那一刻後端再檢查一次（兩支手機同時點同一個人，只有一支成功）。
--   點錯了：後台「客人的手機」停用那一支，重新發一組碼就好。
--
-- 改動：
--   · table_phone_codes.member_id 可以空著（＝通用碼）、加 store_id（通用碼是哪一間店的）
--   · tbl_phone_redeem_tx：通用碼兌換時手機記下門市；其餘一個字都不改
--   · 新函式三支：admin_open_phone_code_tx（後台）、tbl_phone_candidates_tx／tbl_phone_pick_tx（手機，憑平板憑證，同其他 tbl_*）
-- ============================================================

alter table public.table_phone_codes alter column member_id drop not null;
alter table public.table_phone_codes add column if not exists store_id uuid references public.stores(id);
comment on column public.table_phone_codes.store_id is
  '通用配對碼（member_id 空著）是哪一間店的：手機兌換後只列這間店的客人讓他選（2026-10-13）';

-- ① 後台產生通用配對碼
create or replace function public.admin_open_phone_code_tx(p_store_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_staff uuid := (select staff_id from public.current_staff());
  st public.stores;
  v_code text; i int := 0;
  v_exp timestamptz := now() + interval '24 hours';
begin
  if v_staff is null or not public.can('device.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '發配對碼是總部的權限');
  end if;
  select * into st from stores where id = p_store_id and org_id = (select org_id from staff where id = v_staff);
  if st.id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這間店');
  end if;
  -- 跟 _tbl_new_phone_code 同一種產生法（那支一定要會員，這裡沒有，所以自己插）
  loop
    i := i + 1;
    v_code := lpad((floor(random() * 1000000))::int::text, 6, '0');
    exit when not exists (select 1 from table_phone_codes where code = v_code and used_at is null and expires_at > now());
    if i > 50 then raise exception '配對碼產生失敗'; end if;
  end loop;
  insert into table_phone_codes (org_id, member_id, store_id, code, expires_at, issued_by_staff_id)
  values (st.org_id, null, st.id, v_code, v_exp, v_staff);
  return jsonb_build_object('ok', true, 'code', v_code, 'store', st.name, 'expires_at', v_exp);
end $function$;
grant execute on function public.admin_open_phone_code_tx(uuid) to authenticated;

-- ② 兌換：通用碼 ⇒ 手機記下門市（store_id），member_id 空著等他自己選
create or replace function public.tbl_phone_redeem_tx(p_code text, p_token text DEFAULT NULL::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
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
                             store_id = coalesce(c.store_id, store_id),   -- 通用碼：記下門市（2026-10-13）
                             last_seen_at = now()
     where id = d.id;
    v_token := p_token;
  else
    v_token := encode(extensions.gen_random_bytes(32), 'hex');
    insert into table_devices (org_id, kind, member_id, bound_session_id, store_id, label, token_hash, last_seen_at)
    values (c.org_id, 'phone', c.member_id, c.session_id, c.store_id, '手機', public._tbl_hash(v_token), now())
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
  return jsonb_build_object('ok', true, 'token', v_token, 'name', v_name, 'this_game_only', c.session_id is not null,
                            'pick', c.member_id is null);   -- 通用碼：下一步要自己選「我是誰」
end $function$;

-- ③ 還沒選人的手機：列出這間店可以選的人
create or replace function public.tbl_phone_candidates_tx(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  d public.table_devices := public._tbl_device(p_token);
  v_store uuid;
begin
  if d.kind <> 'phone' or d.member_id is not null then
    return jsonb_build_object('ok', false, 'reason', 'not_open', 'message', '這支手機已經是某一位的了');
  end if;
  select store_id into v_store from table_devices where id = d.id;   -- _tbl_device 回傳的門市會被清掉，直接讀表
  return jsonb_build_object('ok', true, 'players', coalesce((
    select jsonb_agg(jsonb_build_object('player_id', sp.id, 'name', m.display_name, 'table', t.label, 'seat', sp.seat,
                                        'avatar_source', m.avatar_source, 'avatar_bear', m.avatar_bear,
                                        'avatar_photo_path', m.avatar_photo_path, 'avatar_url', m.avatar_url)
                     order by t.sort_order, t.label, sp.seat nulls last, sp.joined_at)
      from session_players sp
      join table_sessions ts on ts.id = sp.session_id
      join tables t on t.id = ts.table_id
      join members m on m.id = sp.member_id
     where ts.store_id = v_store and ts.status = 'open' and ts.deleted_at is null
       and sp.left_at is null and m.hidden_at is null
       and (sp.device_id is null or public._tbl_device_stale(sp.device_id))), '[]'::jsonb));
end $function$;
grant execute on function public.tbl_phone_candidates_tx(text) to anon, authenticated;

-- ④ 點自己：這支手機永久變成他的，同時接上他的座位
create or replace function public.tbl_phone_pick_tx(p_token text, p_player_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  d public.table_devices := public._tbl_device(p_token);
  v_store uuid;
  sp public.session_players;
begin
  if d.kind <> 'phone' or d.member_id is not null then
    return jsonb_build_object('ok', false, 'reason', 'not_open', 'message', '這支手機已經是某一位的了');
  end if;
  select store_id into v_store from table_devices where id = d.id;
  select p.* into sp from session_players p
    join table_sessions ts on ts.id = p.session_id
   where p.id = p_player_id and p.left_at is null
     and ts.store_id = v_store and ts.status = 'open' and ts.deleted_at is null
   for update of p;
  if sp.id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '這位已經不在牌局裡了');
  end if;
  -- 點完那一刻再檢查一次：已經有裝置在計分（而且沒斷線）就搶不走
  if sp.device_id is not null and not public._tbl_device_stale(sp.device_id) then
    return jsonb_build_object('ok', false, 'reason', 'taken', 'message', '這位已經在另一台裝置上計分了');
  end if;
  update table_devices set member_id = sp.member_id, last_seen_at = now() where id = d.id and member_id is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_open', 'message', '這支手機已經是某一位的了');
  end if;
  update session_players set device_id = d.id where id = sp.id;
  perform public._tbl_ping(sp.session_id);
  return jsonb_build_object('ok', true, 'name', (select display_name from members where id = sp.member_id));
end $function$;
grant execute on function public.tbl_phone_pick_tx(text, uuid) to anon, authenticated;


-- ============================================================
-- 驗證（單一 SELECT，不 raise）
--   ① 欄位：配對碼的會員可以空著、有 store_id
--   ② 四支函式都在、DEFINER
--   ③ 授權：後台那支只給登入的；手機兩支 anon 叫得到（憑平板憑證，同其他 tbl_*）
--   ④ 兌換會記門市、回 pick
--   ⑤ 擋牆：後台那支沒有身分 ⇒ forbidden；手機兩支給假憑證 ⇒ 拋錯（不會回資料）
-- ============================================================
select concat_ws(E'\n',
  case when (select not attnotnull from pg_attribute where attrelid = 'public.table_phone_codes'::regclass and attname = 'member_id')
        and exists (select 1 from information_schema.columns where table_name = 'table_phone_codes' and column_name = 'store_id')
       then '① ✅ 配對碼可以不指定人、有門市欄位' else '① 🔴 欄位沒改到' end,
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and prosecdef
               and proname in ('admin_open_phone_code_tx', 'tbl_phone_redeem_tx', 'tbl_phone_candidates_tx', 'tbl_phone_pick_tx')) = 4
       then '② ✅ 四支函式都在（DEFINER）' else '② 🔴 函式不齊' end,
  case when has_function_privilege('authenticated', 'public.admin_open_phone_code_tx(uuid)', 'execute')
        and not has_function_privilege('anon', 'public.admin_open_phone_code_tx(uuid)', 'execute')
        and has_function_privilege('anon', 'public.tbl_phone_candidates_tx(text)', 'execute')
        and has_function_privilege('anon', 'public.tbl_phone_pick_tx(text, uuid)', 'execute')
       then '③ ✅ 授權對' else '③ 🔴 授權不對' end,
  case when (select pg_get_functiondef('public.tbl_phone_redeem_tx'::regproc) ~ 'store_id = coalesce\(c\.store_id'
                and pg_get_functiondef('public.tbl_phone_redeem_tx'::regproc) ~ '''pick'', c\.member_id is null')
       then '④ ✅ 兌換會記門市、告訴手機要自己選人' else '④ 🔴 兌換沒改到' end,
  case when public.admin_open_phone_code_tx((select id from stores limit 1)) ->> 'reason' = 'forbidden'
       then '⑤ ✅ 後台那支：沒有總部身分 ⇒ 擋下（沒有產生碼）' else '⑤ 🔴 沒有身分也產生得出碼' end
) as "驗證";
