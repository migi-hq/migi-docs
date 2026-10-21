/* ============================================================
   手機簡訊登入備援（店員 POS ＋ 會員 App，2026-10-21 使用者：「改用手機登入備援」「會員也要做，預設關」）
   ------------------------------------------------------------
   🔴 兩條都**預設關**：平常完全看不到，總部在後台「系統設定」打開才出現。
   會員那一半（2026-10-21 同日加）：
   ⑦ phone_otps.purpose 再多一個 'member_login'；otp_request_tx 一起認得
   ⑧ 新函式 get_member_by_phone_tx：用已驗證的手機找會員（只給伺服器）
   ⑨ orgs.member_login_phone_enabled（預設關）；get_login_methods_tx 多回 member_phone；
      admin_set_login_methods_tx 改成三個開關一起存
   ------------------------------------------------------------
   起因：使用者問「整個 LINE 商用帳號被停權會怎樣」——
     POS 只有 LINE 登入（staff-login），有人交班登出之後就沒人進得去、不能開桌收錢。
   ⇒ 加一條不靠 LINE 的路：輸入**已驗證的手機** → 收簡訊驗證碼 → 登入。
     簡訊走 MAAC Go（跟會員註冊同一家），跟 LINE 完全無關。

   這份 SQL 只做資料庫那一半（Edge Function staff-login 另外部署）：
   ① phone_otps.purpose 多一個值 'staff_login'（CHECK 換掉）
   ② otp_request_tx 認得 'staff_login'（其餘逐字照線上版）
      限流照舊：同一支號碼 60 秒一則、一小時 5 則；otp_verify_tx 最多試 5 次（不用改，它吃 purpose 參數）
   ③ 新函式 get_staff_by_phone_tx(p_org_id, p_phone)：用手機找店員
      · 只認 **phone_verified_at 有值** 的手機 —— 打錯的號碼不可以變成別人的登入入口
      · 只認綁了會員的 staff（總部 Email 那一列 member_id 是 null，本來就走 Email）
      · 一人多列取權限最高的，跟 get_staff_by_line_tx／current_staff() 同序
      · 只給 service_role（Edge Function 用），前端叫不到
   ============================================================ */

-- ① 用途多一個 staff_login
alter table public.phone_otps drop constraint if exists phone_otps_purpose_check;
alter table public.phone_otps add constraint phone_otps_purpose_check
  check (purpose = any (array['register', 'claim', 'change', 'staff_login', 'member_login']));

-- ② 發驗證碼：認得 staff_login（只改用途清單那一行）
create or replace function public.otp_request_tx(p_org_id uuid, p_phone text, p_purpose text, p_line_user_id text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_phone text; v_b bytea; v_code text; v_recent timestamptz;
  v_hour int; v_line_hour int; v_free_at timestamptz;
begin
  -- 2026-10-21：多 staff_login（POS 店員）與 member_login（會員 App）兩種手機簡訊登入
  if p_purpose is null or p_purpose not in ('register','claim','change','staff_login','member_login') then
    return jsonb_build_object('ok', false, 'reason', 'bad_purpose');
  end if;

  v_phone := public.migi_norm_phone(p_phone);
  if v_phone is null then
    return jsonb_build_object('ok', false, 'reason', 'phone_invalid');
  end if;

  -- 限流 ①：同一支號碼 60 秒內只發一次
  select max(sent_at) into v_recent from phone_otps
   where org_id = p_org_id and phone = v_phone;
  if v_recent is not null and v_recent > now() - interval '60 seconds' then
    return jsonb_build_object('ok', false, 'reason', 'too_soon',
      'retry_after', ceil(extract(epoch from (v_recent + interval '60 seconds' - now()))));
  end if;

  -- 限流 ②：同一支號碼一小時 5 則
  select count(*) into v_hour from phone_otps
   where org_id = p_org_id and phone = v_phone and sent_at > now() - interval '1 hour';
  if v_hour >= 5 then
    /* 🎯 **第 5 新的那一則**掉出一小時視窗時就空出名額。
       ⚠ 用 `max(sent_at)` 算的話會多等將近一小時 —— 而且是錯的。 */
    select sent_at into v_free_at from phone_otps
     where org_id = p_org_id and phone = v_phone and sent_at > now() - interval '1 hour'
     order by sent_at desc offset 4 limit 1;
    return jsonb_build_object('ok', false, 'reason', 'rate_limited_phone',
      'retry_after', greatest(1, ceil(extract(epoch from (v_free_at + interval '1 hour' - now())))));
  end if;

  -- 限流 ③：同一個 LINE 帳號一小時 10 則
  if p_line_user_id is not null then
    select count(*) into v_line_hour from phone_otps
     where line_user_id = p_line_user_id and sent_at > now() - interval '1 hour';
    if v_line_hour >= 10 then
      select sent_at into v_free_at from phone_otps
       where line_user_id = p_line_user_id and sent_at > now() - interval '1 hour'
       order by sent_at desc offset 9 limit 1;
      return jsonb_build_object('ok', false, 'reason', 'rate_limited_account',
        'retry_after', greatest(1, ceil(extract(epoch from (v_free_at + interval '1 hour' - now())))));
    end if;
  end if;

  v_b := extensions.gen_random_bytes(4);
  v_code := lpad(((get_byte(v_b,0)::bigint * 16777216
                 + get_byte(v_b,1) * 65536
                 + get_byte(v_b,2) * 256
                 + get_byte(v_b,3)) % 1000000)::text, 6, '0');

  update phone_otps set consumed_at = now()
   where org_id = p_org_id and phone = v_phone and consumed_at is null;

  insert into phone_otps (org_id, phone, code_hash, purpose, line_user_id, expires_at)
  values (p_org_id, v_phone,
          encode(extensions.digest(v_code || ':' || v_phone, 'sha256'), 'hex'),
          p_purpose, p_line_user_id, now() + interval '5 minutes');

  return jsonb_build_object('ok', true, 'code', v_code, 'phone', v_phone, 'expires_in', 300);
end $function$;

-- ③ 用手機找店員（只給 Edge Function）
create or replace function public.get_staff_by_phone_tx(p_org_id uuid, p_phone text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v_phone text; v_r jsonb;
begin
  /* 形狀照 get_staff_by_line_tx，多回 line_user_id（Edge Function 要用它認出同一個登入帳號）。
     ⚠ auth_uid 不回 —— Edge Function 需要時自己用 service key 查 staff 表。 */
  v_phone := public.migi_norm_phone(p_phone);
  if v_phone is null then
    return jsonb_build_object('ok', false, 'reason', 'phone_invalid');
  end if;

  select jsonb_build_object(
           'ok', true,
           'staff_id',     s.id,
           'member_id',    s.member_id,
           'store_id',     s.store_id,
           'role',         s.role,
           'name',         coalesce(s.name, m.display_name),
           'cross_store',  s.role in ('hq', 'owner'),   -- 與 can() 同一份判準
           'line_user_id', m.line_user_id
         )
    into v_r
    from staff s
    join members m on m.id = s.member_id and m.deleted_at is null
   where s.deleted_at is null
     and s.org_id = p_org_id
     and m.phone = v_phone
     and m.phone_verified_at is not null      -- 🔴 只認驗證過的手機
   order by case s.role when 'hq' then 1 when 'owner' then 1
                        when 'manager' then 2 else 3 end
   limit 1;

  return coalesce(v_r, jsonb_build_object('ok', false, 'reason', 'not_staff'));
end $function$;

revoke execute on function public.get_staff_by_phone_tx(uuid, text) from public, anon, authenticated;
grant  execute on function public.get_staff_by_phone_tx(uuid, text) to service_role;


/* ── ④ 登入方式的開關（2026-10-21 使用者：「LINE 登入跟手機登入，在總部後台新增開關」「會員也要做，預設關」）──
   放在 orgs（全系統一份），後台「系統設定」頁改它。
   · 店員：管 POS 與管理後台的店員登入（都走 staff-login）
     🔴 LINE 與手機至少要留一個開著：兩個都關的話所有店員都進不了 POS，後端直接擋
     ⚠ 管理後台的 Email 備用登入不受影響 —— 那是最後一道門（break-glass）
   · 會員：只有手機簡訊這一個開關（會員 App 的 LINE 登入不給關 —— 那是客人唯一的註冊路）
   · 🔴 **兩個手機簡訊都預設關**：平常完全看不到，總部打開才出現
   · 擋是在 Edge Function（staff-login／line-login）裡擋，不是只把前端按鈕藏起來 */
alter table public.orgs add column if not exists staff_login_line_enabled   boolean not null default true;
-- 🔴 手機簡訊預設**關**（使用者：「平常不會有任何手機登入的連結或提示，除非後台把手機登入開關打開」）
alter table public.orgs add column if not exists staff_login_phone_enabled  boolean not null default false;
alter table public.orgs add column if not exists member_login_phone_enabled boolean not null default false;
comment on column public.orgs.staff_login_line_enabled   is '店員可以用 LINE 登入 POS／管理後台（後台「系統設定」改；與店員手機簡訊至少要開一個）';
comment on column public.orgs.staff_login_phone_enabled  is '店員可以用手機簡訊驗證碼登入 POS（後台「系統設定」改；預設關）';
comment on column public.orgs.member_login_phone_enabled is '會員可以用手機簡訊驗證碼登入會員 App（後台「系統設定」改；預設關；LINE 停權時的備用路）';

-- ⑤ 登入頁讀開關：還沒登入就要知道顯示哪幾種 ⇒ anon 也叫得到（只回三個布林，沒有敏感資料）
create or replace function public.get_login_methods_tx(p_org_id uuid)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select coalesce(
    (select jsonb_build_object('line', o.staff_login_line_enabled, 'phone', o.staff_login_phone_enabled,
                               'member_phone', o.member_login_phone_enabled)
       from orgs o where o.id = p_org_id and o.deleted_at is null),
    jsonb_build_object('line', true, 'phone', false, 'member_phone', false))   -- 找不到機構時照預設
$function$;
revoke execute on function public.get_login_methods_tx(uuid) from public;
grant  execute on function public.get_login_methods_tx(uuid) to anon, authenticated, service_role;

-- ⑥ 後台改開關：總部／老闆才能改（can()），機構與操作者都從登入身分取，不收前端送的
create or replace function public.admin_set_login_methods_tx(p_line boolean, p_phone boolean, p_member_phone boolean)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_org uuid := public.current_org_id(); v_staff uuid;
begin
  if not public.can('settings.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '只有總部或老闆可以改登入方式');
  end if;
  if p_line is null or p_phone is null or p_member_phone is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_input', 'message', '設定不完整，請重新整理再試');
  end if;
  -- 🔴 店員兩個都關 ＝ 沒有店員進得了 POS
  if not p_line and not p_phone then
    return jsonb_build_object('ok', false, 'reason', 'need_one', 'message', '店員至少要留一種登入方式，不然都進不了 POS');
  end if;
  select staff_id into v_staff from public.current_staff();
  update orgs
     set staff_login_line_enabled = p_line, staff_login_phone_enabled = p_phone,
         member_login_phone_enabled = p_member_phone,
         updated_at = now(), updated_by = v_staff
   where id = v_org;
  return jsonb_build_object('ok', true, 'line', p_line, 'phone', p_phone, 'member_phone', p_member_phone);
end $function$;
revoke execute on function public.admin_set_login_methods_tx(boolean, boolean, boolean) from public, anon;
grant  execute on function public.admin_set_login_methods_tx(boolean, boolean, boolean) to authenticated, service_role;

-- ⑧ 用手機找會員（只給 Edge Function line-login）
create or replace function public.get_member_by_phone_tx(p_org_id uuid, p_phone text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v_phone text; v_r jsonb;
begin
  /* 會員手機簡訊登入（2026-10-21）。
     · 只認 **phone_verified_at 有值** 的手機 —— 打錯的號碼不可以變成別人的登入入口
     · 回 line_user_id：會員的登入身分（current_member_id）是從 LINE id 解析的，
       Edge Function 要用它發出「跟 LINE 登入同一個人」的 session；沒有 LINE id 的會員登不了（回 no_line）
     · 被隱藏的帳號回 hidden，Edge Function 不發 session */
  v_phone := public.migi_norm_phone(p_phone);
  if v_phone is null then
    return jsonb_build_object('ok', false, 'reason', 'phone_invalid');
  end if;
  select jsonb_build_object('ok', true, 'member_id', m.id, 'line_user_id', m.line_user_id,
                            'display_name', m.display_name, 'hidden', m.hidden_at is not null)
    into v_r
    from members m
   where m.org_id = p_org_id and m.deleted_at is null
     and m.phone = v_phone and m.phone_verified_at is not null
   limit 1;
  return coalesce(v_r, jsonb_build_object('ok', false, 'reason', 'not_found'));
end $function$;
revoke execute on function public.get_member_by_phone_tx(uuid, text) from public, anon, authenticated;
grant  execute on function public.get_member_by_phone_tx(uuid, text) to service_role;


/* ── 驗證（單一 SELECT，不 raise）──────────────────────────── */
select
  (select case when pg_get_constraintdef(oid) like '%staff_login%' and pg_get_constraintdef(oid) like '%member_login%'
               then '✅ ① phone_otps 認得 staff_login 與 member_login' else '🔴 ① CHECK 沒換到' end
     from pg_constraint where conrelid = 'public.phone_otps'::regclass and conname = 'phone_otps_purpose_check') || E'\n' ||
  (select case when count(*) = 1 and bool_and(pg_get_functiondef(oid) ~ '''staff_login'',''member_login''')
               then '✅ ② otp_request_tx 認得兩種登入用途（1 個版本）' else '🔴 ② otp_request_tx 沒改到' end
     from pg_proc where pronamespace = 'public'::regnamespace and proname = 'otp_request_tx') || E'\n' ||
  (select case when has_function_privilege('service_role', 'public.get_staff_by_phone_tx(uuid,text)', 'execute')
                and not has_function_privilege('anon', 'public.get_staff_by_phone_tx(uuid,text)', 'execute')
                and not has_function_privilege('authenticated', 'public.get_staff_by_phone_tx(uuid,text)', 'execute')
                and has_function_privilege('service_role', 'public.get_member_by_phone_tx(uuid,text)', 'execute')
                and not has_function_privilege('anon', 'public.get_member_by_phone_tx(uuid,text)', 'execute')
                and not has_function_privilege('authenticated', 'public.get_member_by_phone_tx(uuid,text)', 'execute')
               then '✅ ③ 用手機找店員／找會員：只有伺服器叫得動' else '🔴 ③ 授權不對' end) || E'\n' ||
  (select '✅ ④ 能用手機登入的店員 ' || (select count(*) from staff s join members m on m.id = s.member_id and m.deleted_at is null
                                        where s.deleted_at is null and m.phone_verified_at is not null)
          || ' 位、會員 ' || (select count(*) from members where deleted_at is null and not is_test
                                and phone_verified_at is not null and line_user_id is not null) || ' 位（手機已驗證）') || E'\n' ||
  (select case when count(*) = 3 then '✅ ⑤ orgs 有三個登入開關欄位' else '🔴 ⑤ 開關欄位只有 ' || count(*) || ' 個' end
     from information_schema.columns
    where table_schema = 'public' and table_name = 'orgs'
      and column_name in ('staff_login_line_enabled', 'staff_login_phone_enabled', 'member_login_phone_enabled')) || E'\n' ||
  (select case when public.get_login_methods_tx('11111111-1111-1111-1111-111111111111'::uuid)
                    = '{"line": true, "phone": false, "member_phone": false}'::jsonb
               then '✅ ⑥ 開關現況：店員 LINE 開、店員手機關、會員手機關（平常看不到手機登入）'
               else '⚠ ⑥ 開關現況：' || public.get_login_methods_tx('11111111-1111-1111-1111-111111111111'::uuid)::text end) || E'\n' ||
  (select case when has_function_privilege('anon', 'public.get_login_methods_tx(uuid)', 'execute')
                and has_function_privilege('authenticated', 'public.admin_set_login_methods_tx(boolean,boolean,boolean)', 'execute')
                and not has_function_privilege('anon', 'public.admin_set_login_methods_tx(boolean,boolean,boolean)', 'execute')
                and pg_get_functiondef('public.admin_set_login_methods_tx(boolean,boolean,boolean)'::regprocedure) ~ 'can\(''settings\.write''\)'
               then '✅ ⑦ 讀開關誰都叫得到；改開關要登入且由函式自己檢查總部權限' else '🔴 ⑦ 授權或權限檢查不對' end)
  as "驗證";
