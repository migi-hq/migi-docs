-- 【成就系統・執行狀態待確認】總部專屬成就的授予權限控制 RPC。
-- ============================================================
-- MIGI 成就系統 · 總部專屬設定權限(加盟/店長唯讀)
-- 接在 成就系統_achievements_schema_RPC.sql 之後部署
--
-- 模型:
--   · 成就屬「品牌(org)層級」,該 org 底下所有門市/加盟共用同一份。
--     店長端只「看」成就清單與會員解鎖狀態,不能改定義。
--   · 只有總部/企劃部(staff.role = 'hq' / 'owner')能新增/修改/上下架成就。
--   · 鎖在「後端」:寫入一律走以下 SECURITY DEFINER RPC,且每支先檢查角色;
--     achievements / achievement_tiers 的直接寫入維持 service_role only(見產生檔 RLS)。
--     => 店長/加盟的 token 連 insert/update 的門都沒有,不是只靠前端藏按鈕。
--
--   (註:此處假設 MIGI 品牌 = 單一 org、各門市/加盟為其下 stores,成就因而全加盟共用。
--    若未來加盟改為各自獨立 org,需另做「品牌成就母表 → 各 org 同步」的層,屬後續架構。)
-- ============================================================

-- ---------- 結構化觸發欄(吃 {event, count});後端可依事件自動解鎖 ----------
alter table achievements add column if not exists trigger jsonb;  -- 例:{"event":"visit_completed","count":1}

-- ---------- 族群 / 系列 / 依賴 / 顯示 / 重置(避免 200 成就變垃圾牆) ----------
alter table achievements add column if not exists group_key    text;  -- 主題族群,如「牌型探索」「店內場景」
alter table achievements add column if not exists series        text;  -- 成長系列,如「新手系列」「打卡系列」
alter table achievements add column if not exists requires_code text;  -- 前置成就 code(需先解鎖才觸發);null=無前置
alter table achievements add column if not exists visibility    text;  -- visible / silhouette(灰階) / hidden
alter table achievements add column if not exists repeat_cycle  text;  -- once / monthly / quarterly

-- 回填:visibility 由舊 is_hidden 推導;repeat_cycle 預設 once
update achievements set visibility   = case when is_hidden then 'hidden' else 'visible' end where visibility is null;
update achievements set repeat_cycle = 'once' where repeat_cycle is null;
alter table achievements alter column visibility   set default 'visible';
alter table achievements alter column repeat_cycle set default 'once';
do $$ begin
  alter table achievements add constraint chk_ach_visibility   check (visibility   in ('visible','silhouette','hidden'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table achievements add constraint chk_ach_repeat_cycle check (repeat_cycle in ('once','monthly','quarterly'));
exception when duplicate_object then null; end $$;
-- 註:visibility 為唯一真相;is_hidden 由 upsert 自動同步(= visibility='hidden'),供既有邏輯沿用,不雙管。

-- ---------- 權限檢查:只有總部可設定成就 ----------
create or replace function assert_ach_admin(p_staff_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_role text;
begin
  select role into v_role from staff where id = p_staff_id;
  if v_role is null then
    raise exception '店員不存在,無權設定成就';
  end if;
  if v_role not in ('hq','owner') then
    raise exception '成就僅限總部/企劃部設定(目前角色 %,需 hq 或 owner)', v_role
      using errcode = '42501';   -- insufficient_privilege
  end if;
end $$;

-- ---------- 新增 / 修改成就(總部專用;全加盟共用一份) ----------
create or replace function upsert_achievement_tx(
  p_staff_id      uuid,
  p_org_id        uuid,
  p_code          text,
  p_name          text,
  p_struct        text,
  p_motivation    text,
  p_flavor        text        default null,
  p_visibility    text        default 'visible',   -- visible / silhouette / hidden(取代 is_hidden)
  p_group_key     text        default null,        -- 主題族群
  p_series        text        default null,        -- 成長系列
  p_requires_code text        default null,        -- 前置成就 code
  p_repeat_cycle  text        default 'once',       -- once / monthly / quarterly
  p_condition_text text       default null,
  p_trigger       jsonb       default null,
  p_grants_title  text        default null,
  p_is_signature  boolean     default false,
  p_reward_points bigint      default 0,
  p_valid_from    timestamptz default null,
  p_valid_to      timestamptz default null,
  p_sort          int         default 0
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform assert_ach_admin(p_staff_id);                    -- 權限鎖:非總部直接擋下

  insert into achievements(
    org_id, code, name, struct, is_hidden, visibility, motivation, flavor,
    group_key, series, requires_code, repeat_cycle,
    condition_text, trigger, grants_title, is_signature, reward_points,
    valid_from, valid_to, is_active, sort
  ) values (
    p_org_id, p_code, p_name, p_struct, (p_visibility = 'hidden'), p_visibility, p_motivation, p_flavor,
    p_group_key, p_series, p_requires_code, p_repeat_cycle,
    p_condition_text, p_trigger, p_grants_title, p_is_signature, p_reward_points,
    p_valid_from, p_valid_to, true, p_sort
  )
  on conflict (org_id, code) where deleted_at is null
  do update set
    name          = excluded.name,
    struct        = excluded.struct,
    is_hidden     = (excluded.visibility = 'hidden'),
    visibility    = excluded.visibility,
    motivation    = excluded.motivation,
    flavor        = excluded.flavor,
    group_key     = excluded.group_key,
    series        = excluded.series,
    requires_code = excluded.requires_code,
    repeat_cycle  = excluded.repeat_cycle,
    condition_text= excluded.condition_text,
    trigger       = excluded.trigger,
    grants_title  = excluded.grants_title,
    is_signature  = excluded.is_signature,
    reward_points = excluded.reward_points,
    valid_from    = excluded.valid_from,
    valid_to      = excluded.valid_to,
    sort          = excluded.sort,
    updated_at    = now()
  returning id into v_id;

  return jsonb_build_object('achievement_id', v_id, 'code', p_code);
end $$;

-- ---------- 新增 / 修改分級(累積·連續成就的 I/II/III/IV;總部專用) ----------
create or replace function upsert_achievement_tier_tx(
  p_staff_id      uuid,
  p_achievement_id uuid,
  p_tier_level    int,
  p_tier_name     text,
  p_threshold     bigint,
  p_reward_points bigint default 0
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_id uuid;
begin
  perform assert_ach_admin(p_staff_id);
  select org_id into v_org from achievements where id = p_achievement_id and deleted_at is null;
  if v_org is null then raise exception '成就不存在'; end if;

  insert into achievement_tiers(org_id, achievement_id, tier_level, tier_name, threshold, reward_points)
    values(v_org, p_achievement_id, p_tier_level, p_tier_name, p_threshold, p_reward_points)
  on conflict (achievement_id, tier_level)
  do update set tier_name     = excluded.tier_name,
                threshold     = excluded.threshold,
                reward_points = excluded.reward_points
  returning id into v_id;

  return jsonb_build_object('tier_id', v_id, 'tier_level', p_tier_level);
end $$;

-- ---------- 上 / 下架成就(總部專用) ----------
create or replace function set_achievement_active_tx(
  p_staff_id uuid, p_achievement_id uuid, p_active boolean
) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform assert_ach_admin(p_staff_id);
  update achievements set is_active = p_active, updated_at = now()
    where id = p_achievement_id and deleted_at is null;
  if not found then raise exception '成就不存在'; end if;
  return jsonb_build_object('achievement_id', p_achievement_id, 'is_active', p_active);
end $$;

-- ---------- 軟刪除成就(總部專用) ----------
create or replace function soft_delete_achievement_tx(
  p_staff_id uuid, p_achievement_id uuid
) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform assert_ach_admin(p_staff_id);
  update achievements set deleted_at = now(), is_active = false, updated_at = now()
    where id = p_achievement_id and deleted_at is null;
  if not found then raise exception '成就不存在或已刪除'; end if;
  return jsonb_build_object('achievement_id', p_achievement_id, 'deleted', true);
end $$;

-- 註:成就的「解鎖」(會員達成)走既有 ach_unlock_tx / ach_progress_tx / ach_streak_tx,
--     那是系統依事件觸發、與「設定權限」無關;此處只鎖「定義成就」這件事給總部。
