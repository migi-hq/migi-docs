-- ============================================================
-- 會員 App：客人自己產生手機計分配對碼（事先設定好，不用等成桌）
-- 2026-10-13 · MIGI 咪吉麻將
--
-- 使用者：「理想狀況是讓每位玩家都能事先把計分器設定好，不要等成桌才配對」
--   → 選「會員 App 自己產生」（同日撤掉了不指定人的通用碼：會點錯人）
--
-- 做法：會員 App 已經用 LINE 登入（JWT），後端知道他是誰 ⇒ 身分一律 current_member_id()，不收前端傳的會員。
--   · get_my_phone_scoreboard_tx()：我的手機計分板現況（配對好的手機幾支、最後一次用是什麼時候）
--   · my_phone_code_tx()：幫我產生一組配對碼（永久配對，同成桌卡片那一種：24 小時、用一次）
--     自己再按一次 ⇒ 自己上一組還沒用的作廢（成桌卡片、後台發的不動）
--   · table_phone_codes.self_issued：這組是客人在 App 裡自己產生的（後台稽核分得出來源）
-- 原本三條路照舊：成桌 LINE 卡片、平板「改用手機計分」、後台指定人發碼。已經配對好的手機完全不受影響。
-- ============================================================

alter table public.table_phone_codes add column if not exists self_issued boolean not null default false;
comment on column public.table_phone_codes.self_issued is
  '客人在會員 App 裡自己產生的配對碼（2026-10-13）。成桌通知、平板、後台發的是 false';

create or replace function public.get_my_phone_scoreboard_tx()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_me uuid := public.current_member_id();
begin
  if v_me is null then
    raise exception '未登入，請從 LINE 重新開啟' using errcode = '28000';
  end if;
  return jsonb_build_object('ok', true,
    'phones', (select count(*) from table_devices d
                where d.member_id = v_me and d.kind = 'phone' and d.is_active and d.revoked_at is null
                  and d.bound_session_id is null),
    'last_seen_at', (select max(d.last_seen_at) from table_devices d
                      where d.member_id = v_me and d.kind = 'phone' and d.is_active and d.revoked_at is null
                        and d.bound_session_id is null));
end $function$;

create or replace function public.my_phone_code_tx()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_me uuid := public.current_member_id();
  v_org uuid;
  v_code text;
  v_exp timestamptz := now() + interval '24 hours';
begin
  if v_me is null then
    raise exception '未登入，請從 LINE 重新開啟' using errcode = '28000';
  end if;
  select org_id into v_org from members where id = v_me;

  -- 自己上一組還沒用的作廢，只留最新一組（成桌卡片、後台發的不動）
  update table_phone_codes set expires_at = now()
   where member_id = v_me and self_issued and used_at is null and expires_at > now();

  v_code := public._tbl_new_phone_code(v_org, v_me, null, null, null, v_exp);
  update table_phone_codes set self_issued = true
   where code = v_code and member_id = v_me and used_at is null and expires_at = v_exp;

  return jsonb_build_object('ok', true, 'code', v_code, 'expires_at', v_exp,
    'url', 'https://table.migi.tw/?install=1&code=' || v_code);
end $function$;

-- 2026-09-29 起新建的函式預設全關（硬規則 2.7）⇒ 會員 App（登入的人）要叫得到就明確開給 authenticated
grant execute on function public.get_my_phone_scoreboard_tx() to authenticated;
grant execute on function public.my_phone_code_tx() to authenticated;


-- ============================================================
-- 驗證（單一 SELECT，不 raise —— 硬規則 1.8）
--   ① 欄位在
--   ② 兩支函式在、DEFINER、身分用 current_member_id()
--   ③ 授權：登入的叫得到、沒登入的（anon）叫不到
--   ④ ℹ 客人自己產生過幾組（剛建好是 0）；沒登入身分會拋 28000 的那一半，在會員 App 實際按一次驗
-- ============================================================
with t as (
  select count(*) as n from table_phone_codes where self_issued
)
select concat_ws(E'\n',
  case when exists (select 1 from information_schema.columns where table_name = 'table_phone_codes' and column_name = 'self_issued')
       then '① ✅ table_phone_codes.self_issued 在' else '① 🔴 欄位沒建' end,
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and prosecdef
               and proname in ('get_my_phone_scoreboard_tx', 'my_phone_code_tx')
               and pg_get_functiondef(oid) ~ 'current_member_id\(\)') = 2
       then '② ✅ 兩支函式在（DEFINER、身分用 current_member_id）' else '② 🔴 函式不對' end,
  case when has_function_privilege('authenticated', 'public.my_phone_code_tx()', 'execute')
        and has_function_privilege('authenticated', 'public.get_my_phone_scoreboard_tx()', 'execute')
        and not has_function_privilege('anon', 'public.my_phone_code_tx()', 'execute')
        and not has_function_privilege('anon', 'public.get_my_phone_scoreboard_tx()', 'execute')
       then '③ ✅ 會員 App 叫得到、沒登入的叫不到' else '③ 🔴 授權不對' end,
  '④ ℹ 目前客人自己產生過的碼：' || (select n from t) || ' 組（剛建好應該是 0；實際產生請在會員 App 試）'
) as "驗證";
