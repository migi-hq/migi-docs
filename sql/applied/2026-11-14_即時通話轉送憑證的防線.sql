/* ============================================================
   線上好友房：即時通話轉送憑證的防線（2026-11-14 使用者：「123 做」的第 2 項）
   📄 規格：docs/03-會員App與社交/線上好友房.md（Cloudflare 轉送暫緩那一段）

   背景：轉送（Cloudflare TURN）的短期憑證是發給手機的，有人挖出來就能拿去當免費代理（只要轉送開通了）。
   Cloudflare 這類用量計費沒有硬上限 ⇒ 開通之前先把「誰拿得到、拿幾次、看得到用量」做好。
   今天轉送還沒開通（沒設 CF_TURN_KEY_ID），這一份先上線：開通那一刻防線已經在了。

   一、online_ice_log：每次 Edge Function 要發轉送憑證就記一筆（誰、哪一場、有沒有資格）。RLS 開著、0 policy ⇒ 只有後端讀寫
   二、online_ice_issue_tx(session, member)：判斷這個人現在有沒有資格拿轉送憑證，並記一筆
       · 這一場要是線上好友練習賽、還在進行中（status = open）
       · 這個人要坐在位置上（有座位、沒離開）
       · 同桌至少一個別的真人（電腦對手不算 —— 只有電腦就不需要通話）
       · 同一個人 24 小時內最多 30 次有資格（重新整理、斷線重連都算一次；正常一晚用不到 10 次）
       不合格 ⇒ 回 eligible: false 與原因，Edge Function 只給免費的公開位址（STUN），通話照樣能直接互連
   ============================================================ */

create table if not exists public.online_ice_log (
  id         bigserial primary key,
  org_id     uuid not null,
  session_id uuid not null,
  member_id  uuid not null,
  eligible   boolean not null,
  reason     text,
  created_at timestamptz not null default now()
);
create index if not exists online_ice_log_member_at on public.online_ice_log (member_id, created_at desc);
alter table public.online_ice_log enable row level security;   -- 0 policy：前端讀不到也寫不了

create or replace function public.online_ice_issue_tx(p_session uuid, p_member uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare s table_sessions; v_why text := null; v_n int;
begin
  select * into s from table_sessions where id = p_session;
  if s.id is null or s.mode <> 'friendly'
     or not exists (select 1 from friendly_games g where g.session_id = s.id and g.play_mode = 'online') then
    return jsonb_build_object('ok', false, 'eligible', false, 'reason', 'not_online');   -- 不是線上牌局：連記都不記
  end if;
  if s.status <> 'open' then v_why := 'not_open';
  elsif not exists (select 1 from session_players sp where sp.session_id = s.id and sp.member_id = p_member and sp.seat is not null and sp.left_at is null) then v_why := 'not_seated';
  elsif not exists (select 1 from session_players sp join members m on m.id = sp.member_id
                     where sp.session_id = s.id and sp.member_id <> p_member and sp.left_at is null and not m.is_bot) then v_why := 'no_humans';
  else
    select count(*) into v_n from online_ice_log
     where member_id = p_member and eligible and created_at > now() - interval '24 hours';
    if v_n >= 30 then v_why := 'daily_limit'; end if;
  end if;
  insert into online_ice_log (org_id, session_id, member_id, eligible, reason) values (s.org_id, s.id, p_member, v_why is null, v_why);
  return jsonb_build_object('ok', true, 'eligible', v_why is null, 'reason', v_why);
end $function$;

-- 預設權限是全關（硬規則 2.7）；只給 Edge Function 用的 service_role
grant execute on function public.online_ice_issue_tx(uuid, uuid) to service_role;

/* ── 驗證（硬規則 1.8：不用 raise，結果放 set_config，最後一支 SELECT 讀回來）── */
do $$
declare v_msg text := ''; v_ok int := 0; v_all int := 5; v_oid oid;
begin
  -- ① 表在、RLS 開著、0 policy
  if to_regclass('public.online_ice_log') is not null
     and (select relrowsecurity from pg_class where oid = 'public.online_ice_log'::regclass)
     and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'online_ice_log')
    then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ① online_ice_log 在、RLS 開著、0 policy';
    else v_msg := v_msg || E'\n🔴 ① online_ice_log 不在、或 RLS／policy 不對'; end if;

  -- ② 前端角色碰不到這張表（預設全關的正對照）
  if not has_table_privilege('anon', 'public.online_ice_log', 'SELECT') and not has_table_privilege('authenticated', 'public.online_ice_log', 'SELECT')
    then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ② 前端讀不到 online_ice_log';
    else v_msg := v_msg || E'\n🔴 ② 前端讀得到 online_ice_log'; end if;

  select oid into v_oid from pg_proc where pronamespace = 'public'::regnamespace and proname = 'online_ice_issue_tx';
  -- ③ 函式在、DEFINER、一個版本
  if v_oid is not null and (select prosecdef from pg_proc where oid = v_oid)
     and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'online_ice_issue_tx') = 1
    then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ③ online_ice_issue_tx 在、DEFINER、一個版本';
    else v_msg := v_msg || E'\n🔴 ③ online_ice_issue_tx 不在、不是 DEFINER、或有多載'; end if;

  -- ④ 只有 service_role 叫得動（明確授權與 PUBLIC 兩個方向都看）
  if v_oid is not null
     and exists (select 1 from aclexplode((select proacl from pg_proc where oid = v_oid)) a where a.grantee = 'service_role'::regrole::oid and a.privilege_type = 'EXECUTE')
     and not has_function_privilege('anon', v_oid, 'EXECUTE') and not has_function_privilege('authenticated', v_oid, 'EXECUTE')
    then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ④ 只有 service_role 叫得動';
    else v_msg := v_msg || E'\n🔴 ④ 權限不對'; end if;

  -- ⑤ 不是線上牌局的場次：回 not_online，而且不記（隨便拿一個不存在的場次）
  if (public.online_ice_issue_tx(gen_random_uuid(), gen_random_uuid()))->>'reason' = 'not_online'
     and (select count(*) from online_ice_log) = 0
    then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ⑤ 不是線上牌局 ⇒ not_online、沒有記錄';
    else v_msg := v_msg || E'\n🔴 ⑤ 不是線上牌局的處理不對'; end if;

  perform set_config('migi.ice', v_ok || ' / ' || v_all || v_msg, true);
end $$;
select coalesce(nullif(current_setting('migi.ice', true), ''), '🔴 沒有訊息') as "驗證";
