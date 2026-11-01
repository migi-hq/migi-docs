/* ============================================================
   2026-11-01  牌咖團顧問（第一段：選顧問）
   ------------------------------------------------------------
   使用者 2026-11-01 拍板：建團時從兩位顧問選一位，選了不能換。
     chef      廚師熊   每打完一場，每人多 1 個小熊餅乾
     merchant  商人熊   檯費每人少 50 元（直營店、每人每天一次）
     兩位的加成都要「整桌 4 位都是團員」才有。

   這一份只做「選」：
     ① teams 加 advisor（＋ 誰選的、什麼時候選的）
     ② create_team_tx 多收 p_advisor（建團彈窗選的那一位）
     ③ set_team_advisor_tx：舊團（沒有顧問的）由團長補選一次
     ④ _team_card 回傳 advisor，團頁才畫得出來

   ⚠ 加成本身**還沒有接**：
     · 商人熊要改結帳計價（_cart_pricing），另一份
     · 廚師熊要先把小熊餅乾改成後端記帳 —— 現在餅乾存在
       member_app_state.bear.snacks，那份是前端整包覆寫的，
       後端加的餅乾會被下一次存檔蓋掉（而且不報錯）

   「選了不能換」靠 update ... where advisor is null 擋，
   不是先查再寫（先查再寫有競態，兩支手機同時按會兩個都成功）。
   ============================================================ */

-- ① 欄位
alter table public.teams add column if not exists advisor        text;
alter table public.teams add column if not exists advisor_set_at timestamptz;
alter table public.teams add column if not exists advisor_set_by uuid references public.members(id);

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.teams'::regclass and conname = 'teams_advisor_check') then
    alter table public.teams add constraint teams_advisor_check
      check (advisor is null or advisor in ('chef', 'merchant'));
  end if;
end $$;

comment on column public.teams.advisor is
  '牌咖團顧問：chef 廚師熊／merchant 商人熊。null ＝ 還沒選（2026-11-01 之前建的團）。選了不能換。';
comment on column public.teams.advisor_set_at is '顧問是什麼時候選的（稽核）';
comment on column public.teams.advisor_set_by is '顧問是誰選的（稽核，值從登入身分取，不收前端）';


-- ② 建團多收 p_advisor（改簽名 ⇒ 先 DROP，最後補 GRANT）
drop function if exists public.create_team_tx(text, text, text, text, uuid);

create function public.create_team_tx(
  p_name          text,
  p_crest_emoji   text default null,
  p_intro         text default null,
  p_join_policy   text default 'approval',
  p_home_store_id uuid default null,
  p_advisor       text default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_me   uuid := public.current_member_id();
  v_org  uuid := public.current_org_id();
  v_name text := btrim(coalesce(p_name, ''));
  v_adv  text := nullif(btrim(coalesce(p_advisor, '')), '');
  v_lead int;
  v_join int;
  v_id   uuid;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  if char_length(v_name) < 2 or char_length(v_name) > 20 then
    return jsonb_build_object('ok', false, 'reason', 'bad_name', 'message', '團名請取 2 到 20 個字');
  end if;
  if coalesce(p_join_policy, 'approval') not in ('open', 'approval', 'closed') then
    return jsonb_build_object('ok', false, 'reason', 'bad_policy', 'message', '加入方式不正確');
  end if;
  /* 顧問可以不帶（還沒更新的舊版 App），帶了就要是兩位之一 */
  if v_adv is not null and v_adv not in ('chef', 'merchant') then
    return jsonb_build_object('ok', false, 'reason', 'bad_advisor', 'message', '找不到這位顧問');
  end if;
  if p_home_store_id is not null and not exists (
       select 1 from public.stores s
        where s.id = p_home_store_id and s.org_id = v_org and s.deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'bad_store', 'message', '找不到那間門市');
  end if;

  /* 兩道護欄，都不是產品規則是防洗版。
     ⚠ 數字放在這裡而不是設定表 —— 今天沒有人要調它，
       建一張設定表就是第 N 個「建了沒人讀」。 */
  select count(*) into v_lead from public.team_members tm
    join public.teams t on t.id = tm.team_id and t.deleted_at is null
   where tm.member_id = v_me and tm.left_at is null and tm.role = 'leader';
  if v_lead >= 3 then
    return jsonb_build_object('ok', false, 'reason', 'too_many_leading',
                              'message', '你已經是 3 個牌咖團的團長了');
  end if;

  select count(*) into v_join from public.team_members tm
    join public.teams t on t.id = tm.team_id and t.deleted_at is null
   where tm.member_id = v_me and tm.left_at is null;
  if v_join >= 10 then
    return jsonb_build_object('ok', false, 'reason', 'too_many_teams',
                              'message', '你已經加入 10 個牌咖團了');
  end if;

  begin
    insert into public.teams (org_id, name, crest_emoji, intro, join_policy,
                              home_store_id, created_by,
                              advisor, advisor_set_at, advisor_set_by)
    values (v_org, v_name, nullif(btrim(coalesce(p_crest_emoji, '')), ''),
            nullif(btrim(coalesce(p_intro, '')), ''),
            coalesce(p_join_policy, 'approval'), p_home_store_id, v_me,
            v_adv,
            case when v_adv is not null then now() end,
            case when v_adv is not null then v_me end)
    returning id into v_id;
  exception when unique_violation then
    /* 🔴 這一格靠 `uq_teams_name` 擋，不是靠先查一次再插入 ——
       先查再插有競態，兩個人同時建同名團會兩個都成功。 */
    return jsonb_build_object('ok', false, 'reason', 'name_taken',
                              'message', '已經有人用這個團名了，換一個吧');
  end;

  insert into public.team_members (org_id, team_id, member_id, role)
  values (v_org, v_id, v_me, 'leader');

  return jsonb_build_object('ok', true, 'team', public._team_card(v_id), 'my_role', 'leader');
end $function$;

revoke execute on function public.create_team_tx(text, text, text, text, uuid, text) from public, anon;
grant  execute on function public.create_team_tx(text, text, text, text, uuid, text) to authenticated;


-- ③ 舊團由團長補選一次
create or replace function public.set_team_advisor_tx(p_team_id uuid, p_advisor text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_me  uuid := public.current_member_id();
  v_adv text := nullif(btrim(coalesce(p_advisor, '')), '');
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if v_adv is null or v_adv not in ('chef', 'merchant') then
    return jsonb_build_object('ok', false, 'reason', 'bad_advisor', 'message', '找不到這位顧問');
  end if;
  /* 只有團長能選（副團長不行，同改團名、團徽） */
  if not exists (select 1 from public.team_members tm
                   join public.teams t on t.id = tm.team_id and t.deleted_at is null
                  where tm.team_id = p_team_id and tm.member_id = v_me
                    and tm.left_at is null and tm.role = 'leader') then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以選顧問');
  end if;

  update public.teams
     set advisor = v_adv, advisor_set_at = now(), advisor_set_by = v_me, updated_at = now()
   where id = p_team_id and advisor is null and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'already_set', 'message', '這個團已經有顧問了，選了就不能更換');
  end if;

  return jsonb_build_object('ok', true, 'team', public._team_card(p_team_id));
end $function$;

revoke execute on function public.set_team_advisor_tx(uuid, text) from public, anon;
grant  execute on function public.set_team_advisor_tx(uuid, text) to authenticated;


-- ④ 團卡回傳顧問（簽名不變，CREATE OR REPLACE 不會丟授權）
create or replace function public._team_card(p_team_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_t      record;
  v_from   timestamptz;
  v_played int;
  v_month  int;
  v_cnt    int;
  v_me     uuid := public.current_member_id();
  v_req    text;
begin
  select t.*, s.name as store_name
    into v_t
    from public.teams t
    left join public.stores s on s.id = t.home_store_id
   where t.id = p_team_id and t.deleted_at is null;
  if not found then return null; end if;

  /* 「本月」用台北日曆月，與當日暢打同一個判準 ——
     系統裡不要有第二種「這個月是哪一段」。 */
  v_from := (date_trunc('month', (now() at time zone 'Asia/Taipei')) at time zone 'Asia/Taipei');

  select count(*), count(*) filter (where played_at >= v_from)
    into v_played, v_month
    from public._team_session_ids(p_team_id);

  select count(*) into v_cnt
    from public.team_members where team_id = p_team_id and left_at is null;

  /* 我跟這個團之間還在談的那一筆是什麼。
     ⚠ 沒登入時 `v_me` 是 null ⇒ 這段查不到東西 ⇒ 回 null，那是對的。
     ⚠ 不需要 order by / limit：部分唯一索引保證同一人對同一團最多一筆在談。 */
  select r.kind into v_req
    from public.team_requests r
   where r.team_id = p_team_id and r.member_id = v_me
     and r.status = 'pending' and r.expires_at > now();

  return jsonb_build_object(
    'id',              v_t.id,
    'name',            v_t.name,
    'intro',           v_t.intro,
    'crest_emoji',     v_t.crest_emoji,
    /* 🔴 2026-09-17：`crest_path` 是**正在用的那張** —— source 是 photo 才給。
       所有畫團徽的地方（名冊、團卡、熱門榜、成功卡）都只讀這一欄，
       所以「照片存著但選用預設」時它們自動畫預設，一行都不用改。
       ⚠ 被總部下架（crest_blocked）時仍然一律 null。 */
    'crest_path',      case when v_t.crest_blocked or v_t.crest_source <> 'photo'
                            then null else v_t.crest_path end,
    /* 存著的那張（不管有沒有在用）—— 只有換團徽抽屜要讀。 */
    'crest_photo_path', case when v_t.crest_blocked then null else v_t.crest_path end,
    'crest_source',    v_t.crest_source,
    'join_policy',     v_t.join_policy,
    'home_store_id',   v_t.home_store_id,
    'home_store_name', v_t.store_name,
    'monthly_goal',    v_t.monthly_goal,
    'member_limit',    v_t.member_limit,
    'member_count',    v_cnt,
    'played',          v_played,
    'month_played',    v_month,
    'my_request',      v_req,
    'advisor',         v_t.advisor,          -- 2026-11-01 牌咖團顧問，null ＝ 還沒選
    'created_at',      v_t.created_at);
end $function$;


/* ── 驗證（單一 SELECT，不用 raise —— 硬規則 1.8） ─────────── */
select
  (select count(*) from information_schema.columns
    where table_schema = 'public' and table_name = 'teams'
      and column_name in ('advisor', 'advisor_set_at', 'advisor_set_by'))                 as "① 三個欄位（應為 3）",
  (select pg_get_constraintdef(oid) from pg_constraint
    where conrelid = 'public.teams'::regclass and conname = 'teams_advisor_check')        as "① 顧問只收兩種",
  (select count(*) from pg_proc
    where pronamespace = 'public'::regnamespace and proname = 'create_team_tx')            as "② 建團函式版本數（應為 1）",
  (select pg_get_function_identity_arguments(oid) from pg_proc
    where pronamespace = 'public'::regnamespace and proname = 'create_team_tx' limit 1)    as "② 建團簽名（最後是 p_advisor）",
  (select string_agg(a.grantee::regrole::text, ',' order by a.grantee::regrole::text)
     from pg_proc p, aclexplode(p.proacl) a
    where p.pronamespace = 'public'::regnamespace and p.proname = 'create_team_tx')        as "② 建團授權（要有 authenticated、不可有 anon）",
  (select string_agg(a.grantee::regrole::text, ',' order by a.grantee::regrole::text)
     from pg_proc p, aclexplode(p.proacl) a
    where p.pronamespace = 'public'::regnamespace and p.proname = 'set_team_advisor_tx')   as "③ 補選授權（要有 authenticated、不可有 anon）",
  (select pg_get_functiondef('public._team_card'::regproc) ~ '''advisor'',\s+v_t\.advisor') as "④ 團卡有回傳顧問（應為 true）",
  (select count(*) from public.teams where deleted_at is null and advisor is not null)     as "現有團已選顧問數（剛跑完應為 0）";
