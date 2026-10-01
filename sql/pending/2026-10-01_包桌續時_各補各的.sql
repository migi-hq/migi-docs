/* ============================================================
   包桌續時：各補各的（也可以替別人補）· 2026-10-01（同日第三版）
   📄 使用者 2026-10-01：「不用管一開始的代付，繼續打就是預設個別分開算（也可以代付）」

   ── 規則改了什麼 ──────────────────────────────────────
   之前   續時照**入座時**的付款關係算：A 入座時替 B 代付 ⇒ 續時也由 A 補 2 份
   現在   **每個人各補各的**，跟入座時誰替誰付無關；到櫃檯時也可以一個人替別人補
          （付錢的人自己不用補也可以，例如持當日暢打的人替朋友付）
   不變   入座時因當日暢打免收的人不用補；要補的人**全部**補完才升檔、解鎖

   ── 為什麼要一張新表 ──────────────────────────────────
   之前「誰補了」是從訂單推出來的：訂單的付款人 ＝ 被補的人（或他入座時代付的人）。
   現在一個人可以替**任何人**補，訂單上只看得到付款人 ⇒ 推不出「這一份是補給誰」。
   ⇒ session_extensions 一列 ＝ 一個人的一段延長：被補的人、補到哪一檔、誰付的、哪張訂單。
   ⚠ 延長訂單目前 0 筆（查證過），沒有舊資料要搬。

   ── 改動 ──────────────────────────────────────────────
   🆕 session_extensions（RLS 開、0 policy、前端讀不到）
   ✏️ _pkg_time        升檔判斷改看 session_extensions；players 的 payer_name 改成「誰替他補的」
   ✏️ pos_pkg_quote_tx / pos_pkg_extend_tx   多一個 p_for（替誰補，不給 ＝ 替自己）⇒ 簽名改了，先 DROP（硬規則 2）
   🗑 _pkg_shares       照入座代付算份數的那一支，已經沒有人用
   ⚠ 指向 members 的外鍵 +2（member_id、paid_by）：會員合併稿要搬的欄位又多兩個（錯誤儀表 ⑨ 那一格）
   ============================================================ */

-- ① 延長紀錄
create table if not exists public.session_extensions (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null,
  session_id  uuid not null references public.table_sessions(id),
  member_id   uuid not null references public.members(id),    -- 被補的人
  to_minutes  int  not null check (to_minutes in (300, 1440)), -- 補到哪一檔
  paid_by     uuid not null references public.members(id),    -- 付錢的人（可以是自己）
  order_id    uuid not null references public.orders(id),
  created_at  timestamptz not null default now(),
  created_by  uuid                                             -- 收款的店員（current_staff，不採信前端）
);
create unique index if not exists uq_session_extensions
  on public.session_extensions (session_id, member_id, to_minutes);
alter table public.session_extensions enable row level security;
revoke all on public.session_extensions from public, anon, authenticated;
comment on table public.session_extensions is
  '包桌續時：一列 ＝ 一個人的一段延長（被補的人、補到哪一檔、誰付的、哪張訂單）。2026-10-01 起續時各補各的，也可以替別人補';

-- ② 計時：升檔看延長紀錄（每一位在座、不是暢打免收的人都要有那一段的紀錄）
create or replace function public._pkg_time(p_session_id uuid, p_with_ids boolean default true)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  s        public.table_sessions;
  v_base   int; v_eff int; v_next int; v_sku text; v_ok boolean;
  v_start  timestamptz; v_exp timestamptz; v_phase text; v_players jsonb; v_payers jsonb;
  c_warn   constant interval := interval '30 minutes';
  c_grace  constant interval := interval '15 minutes';
begin
  select * into s from table_sessions where id = p_session_id and deleted_at is null;
  if s.id is null or s.mode <> 'private' then return null; end if;
  if s.status <> 'open' then return jsonb_build_object('phase', 'closed'); end if;

  v_base := case when coalesce(s.planned_minutes, 0) <= 120 then 120
                 when s.planned_minutes <= 300 then 300 else 1440 end;

  -- 已經補完的延長段：在座、入座時不是暢打免收的每一個人，都要有那一段的延長紀錄（誰付的不管）
  v_eff := v_base;
  while v_eff < 1440 loop
    v_next := case v_eff when 120 then 300 else 1440 end;
    select not exists (
      select 1 from session_players sp
       where sp.session_id = s.id and sp.member_id is not null and sp.left_at is null
         and coalesce(sp.fee_waived_reason, '') <> 'daypass'
         and not exists (select 1 from session_extensions e
                          where e.session_id = s.id and e.member_id = sp.member_id and e.to_minutes = v_next))
      into v_ok;
    exit when not v_ok;
    v_eff := v_next;
  end loop;

  if v_eff >= 1440 then
    v_next := null; v_sku := null;
  else
    v_next := case v_eff when 120 then 300 else 1440 end;
    v_sku  := case v_next when 300 then 'SVC-TBL-PX05' else 'SVC-TBL-PX24' end;
  end if;

  -- 桌上每一位各一列（依座位）。payer_name ＝ 替他補這一段的人（他自己補的就是 null）
  select jsonb_agg(jsonb_build_object(
           'seat',       sp.seat,
           'name',       coalesce(m.display_name, '會員'),
           'status',     case when coalesce(sp.fee_waived_reason, '') = 'daypass' then 'daypass'
                              when v_next is null or e.id is not null then 'paid'
                              else 'owed' end,
           'payer_name', case when e.id is not null and e.paid_by <> sp.member_id
                              then coalesce(pm.display_name, '會員') end)
         || case when p_with_ids then jsonb_build_object('member_id', sp.member_id) else '{}'::jsonb end
         order by sp.seat nulls last, m.display_name)
    into v_players
    from session_players sp
    left join members m  on m.id = sp.member_id
    left join session_extensions e on e.session_id = s.id and e.member_id = sp.member_id and e.to_minutes = v_next
    left join members pm on pm.id = e.paid_by
   where sp.session_id = s.id and sp.member_id is not null and sp.left_at is null;

  -- payers：還沒補的人，每人 1 份（POS 提示條、舊版平板的退回顯示用）
  select jsonb_agg(jsonb_build_object('name', x ->> 'name', 'shares', 1, 'paid', 0, 'owed', 1)
           || case when p_with_ids then jsonb_build_object('member_id', x -> 'member_id') else '{}'::jsonb end)
    into v_payers
    from jsonb_array_elements(coalesce(v_players, '[]'::jsonb)) x
   where x ->> 'status' = 'owed';

  select min(r.started_at) into v_start
    from session_rounds r where r.session_id = s.id and r.status <> 'voided';

  if v_eff >= 1440 then
    v_phase := 'capped';
  elsif v_start is null then
    v_phase := 'not_started';
  else
    v_exp := v_start + make_interval(mins => v_eff);
    v_phase := case when now() <  v_exp - c_warn  then 'ok'
                    when now() <  v_exp           then 'warn'
                    when now() <  v_exp + c_grace then 'grace'
                    else 'locked' end;
  end if;

  return jsonb_build_object(
    'phase',        v_phase,
    'locked',       v_phase = 'locked',
    'now',          now(),
    'started_at',   v_start,
    'base_minutes', v_base,
    'tier_minutes', v_eff,
    'expires_at',   v_exp,
    'warn_at',      v_exp - c_warn,
    'lock_at',      v_exp + c_grace,
    'next_minutes', v_next,
    'next_sku',     v_sku,
    'players',      coalesce(v_players, '[]'::jsonb),
    'payers',       coalesce(v_payers, '[]'::jsonb),
    'owed_shares',  coalesce(jsonb_array_length(v_payers), 0));
end $$;

-- ③ 報價與收款：多一個 p_for（替誰補；不給 ＝ 替自己）⇒ 簽名改了，先 DROP 舊的
drop function if exists public.pos_pkg_extend_tx(uuid, uuid, bigint, jsonb, text);
drop function if exists public.pos_pkg_quote_tx(uuid, uuid);

create function public.pos_pkg_quote_tx(p_session_id uuid, p_member_id uuid, p_for uuid[] default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_pkg jsonb; v_cover uuid[]; v_bad text; v_pid uuid; v_org uuid; v_items jsonb; v_price jsonb;
begin
  perform public._api_staff_only();
  v_pkg := public._pkg_time(p_session_id, true);
  if v_pkg is null then
    return jsonb_build_object('ok', false, 'reason', 'not_private', 'message', '這一場不是包桌');
  end if;
  if v_pkg ->> 'phase' = 'closed' then
    return jsonb_build_object('ok', false, 'reason', 'session_closed', 'message', '這一場已經收桌');
  end if;
  if v_pkg ->> 'phase' = 'capped' then
    return jsonb_build_object('ok', false, 'reason', 'capped', 'message', '已經是最高時數，不用再補');
  end if;
  if not exists (select 1 from session_players
                  where session_id = p_session_id and member_id = p_member_id and left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'not_seated', 'message', '付錢的人要在這一桌');
  end if;

  -- 替誰補：不給 ＝ 替自己；自己不用補（已補過或暢打免收）就沒有東西可以收
  select array_agg(distinct x) into v_cover
    from unnest(coalesce(p_for, array[p_member_id])) x where x is not null;
  if p_for is null and not exists (
       select 1 from jsonb_array_elements(v_pkg -> 'players') e
        where (e ->> 'member_id')::uuid = p_member_id and e ->> 'status' = 'owed') then
    return jsonb_build_object('ok', false, 'reason', 'nothing_owed', 'message', '這位客人不用補檯費', 'pkg', v_pkg);
  end if;
  if v_cover is null or cardinality(v_cover) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'nothing_owed', 'message', '沒有選要替誰補', 'pkg', v_pkg);
  end if;

  -- 每一位都要是「這一段還沒補」的人
  select string_agg(coalesce(y.e ->> 'name', '有一位不在這一桌的人'), '、') into v_bad
    from unnest(v_cover) c
    left join lateral (select e from jsonb_array_elements(v_pkg -> 'players') e
                        where (e ->> 'member_id')::uuid = c) y on true
   where y.e is null or y.e ->> 'status' <> 'owed';
  if v_bad is not null then
    return jsonb_build_object('ok', false, 'reason', 'not_owed', 'message', v_bad || ' 不用補或已經補過', 'pkg', v_pkg);
  end if;

  select org_id into v_org from table_sessions where id = p_session_id;
  select id into v_pid from products
   where org_id = v_org and sku = v_pkg ->> 'next_sku' and deleted_at is null limit 1;
  if v_pid is null then
    return jsonb_build_object('ok', false, 'reason', 'product_not_found', 'message', '找不到包桌延長商品');
  end if;

  v_items := jsonb_build_array(jsonb_build_object('product_id', v_pid, 'qty', cardinality(v_cover)));
  v_price := public._cart_pricing(v_org, p_member_id, v_items, null);   -- 等級折扣看付錢的人
  return jsonb_build_object('ok', true, 'owed', cardinality(v_cover), 'cover', to_jsonb(v_cover),
    'next_minutes', (v_pkg ->> 'next_minutes')::int, 'items', v_items,
    'amount', (v_price ->> 'payable')::bigint, 'pricing', v_price, 'pkg', v_pkg);
end $$;

create function public.pos_pkg_extend_tx(p_session_id uuid, p_member_id uuid, p_for uuid[] default null,
  p_points_used bigint default 0, p_payments jsonb default null, p_idempotency_key text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_q jsonb; v_res jsonb; v_order uuid; v_org uuid;
begin
  perform public._api_staff_only();
  v_q := public.pos_pkg_quote_tx(p_session_id, p_member_id, p_for);
  if not coalesce((v_q ->> 'ok')::boolean, false) then return v_q; end if;

  v_res := public.pos_addon_checkout_tx(p_session_id, p_member_id, v_q -> 'items', null,
             coalesce(p_points_used, 0), p_payments, p_idempotency_key, null);
  if not coalesce((v_res ->> 'ok')::boolean, false) then return v_res; end if;

  v_order := nullif(v_res ->> 'order_id', '')::uuid;
  if v_order is null then
    -- 錢收了卻找不到訂單 ⇒ 記不了「補給誰」⇒ 整筆退回（例外會回滾收款），不留半筆帳
    raise exception '包桌延長：收款成功但找不到訂單，整筆取消';
  end if;
  select org_id into v_org from table_sessions where id = p_session_id;

  insert into session_extensions (org_id, session_id, member_id, to_minutes, paid_by, order_id, created_by)
  select v_org, p_session_id, c::uuid, (v_q ->> 'next_minutes')::int, p_member_id, v_order,
         (select staff_id from public.current_staff())
    from jsonb_array_elements_text(v_q -> 'cover') c
  on conflict (session_id, member_id, to_minutes) do nothing;

  perform public._tbl_ping(p_session_id);   -- 讓計分板馬上重新拿狀態
  return v_res || jsonb_build_object('pkg', public._pkg_time(p_session_id, true));
end $$;

revoke execute on function public.pos_pkg_quote_tx(uuid, uuid, uuid[]) from public, anon;
revoke execute on function public.pos_pkg_extend_tx(uuid, uuid, uuid[], bigint, jsonb, text) from public, anon;
grant  execute on function public.pos_pkg_quote_tx(uuid, uuid, uuid[]) to authenticated;
grant  execute on function public.pos_pkg_extend_tx(uuid, uuid, uuid[], bigint, jsonb, text) to authenticated;

-- ④ 照入座代付算份數的那一支已經沒有人用
drop function if exists public._pkg_shares(uuid);

-- ⑤ 驗證（只讀狀態、不寫東西，不用 raise —— 硬規則 1.8）
do $$
declare v_msg text := ''; v_n int; v_ok boolean;
begin
  select count(*) into v_n from pg_indexes where tablename = 'session_extensions' and indexname = 'uq_session_extensions';
  v_ok := to_regclass('public.session_extensions') is not null and v_n = 1
      and (select relrowsecurity from pg_class where oid = 'public.session_extensions'::regclass)
      and not has_table_privilege('authenticated', 'public.session_extensions', 'select')
      and not has_table_privilege('anon', 'public.session_extensions', 'select');
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ① 延長紀錄表：有唯一索引、RLS 開、前端讀不到' || E'\n';

  v_ok := pg_get_functiondef('public._pkg_time(uuid,boolean)'::regprocedure) ~ 'from session_extensions e'
      and pg_get_functiondef('public._pkg_time(uuid,boolean)'::regprocedure) !~ '_pkg_shares\(';
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ② 計時改看延長紀錄，不再照入座代付算' || E'\n';

  select count(*) into v_n from pg_proc
   where pronamespace = 'public'::regnamespace and proname in ('pos_pkg_quote_tx', 'pos_pkg_extend_tx');
  v_ok := v_n = 2
      and has_function_privilege('authenticated', 'public.pos_pkg_quote_tx(uuid,uuid,uuid[])', 'execute')
      and has_function_privilege('authenticated', 'public.pos_pkg_extend_tx(uuid,uuid,uuid[],bigint,jsonb,text)', 'execute')
      and not has_function_privilege('anon', 'public.pos_pkg_quote_tx(uuid,uuid,uuid[])', 'execute')
      and not has_function_privilege('anon', 'public.pos_pkg_extend_tx(uuid,uuid,uuid[],bigint,jsonb,text)', 'execute');
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end
        || ' ③ 報價與收款各一個版本（新簽名多 p_for），只給登入的人；版本數 ' || v_n || E'\n';

  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and (p.proname = '_pkg_shares' or pg_get_functiondef(p.oid) ~ '(perform|select|from|join)\s+(public\.)?_pkg_shares\(');
  v_msg := v_msg || case when v_n = 0 then '✅' else '🔴' end || ' ④ 舊的份數函式已拿掉，也沒有人在叫它（' || v_n || '）' || E'\n';

  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname in ('tbl_state_tx', 'list_tables_tx', 'pos_pkg_state_tx', 'tbl_submit_hand_tx', 'tbl_start_round_tx')
     and pg_get_functiondef(p.oid) ~ '_pkg_time\(';
  v_msg := v_msg || case when v_n = 5 then '✅' else '🔴' end || ' ⑤ 五支既有函式仍然接著計時（' || v_n || '/5）';

  perform set_config('migi.pkg3', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.pkg3', true), ''), '🔴 沒有驗證訊息') as "驗證";
