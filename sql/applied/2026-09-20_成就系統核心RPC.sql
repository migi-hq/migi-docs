-- ============================================================
-- 成就系統 · 第二步：核心 RPC（事件驅動 ＋ 三種判定 ＋ 展示櫃）
-- 2026-09-20　前置：2026-09-20_成就系統建表.sql（已執行）
--
-- 📄 接線指南  docs/03-會員App與社交/成就與稱號設計.md §3
--
-- 🔴 **架構照抄 `_設計稿未落地/`，但那九個問題裡屬於 RPC 的五個全部修掉，
--   外加一個複查時才發現的第十個。**
--
--   ① grant_points_tx 不存在        → **整段發點數的程式碼不寫**（見下）
--   ② 沒有任何 revoke               → 兩個方向都收（硬規則 2.6b）
--   ③ 四支核心 RPC 缺 definer       → 全部 security definer set search_path
--   ④ 會員 id 由呼叫端指定           → ach_pin_tx 改 current_member_id()
--   ⑨ ach_pin_tx 寫死「最多 3 枚」   → **1 枚 ＋ 切換語意**
--   🆕 ⑩ **累積型沒有冪等**          → 加 last_idem（見下）
--
-- 【① 為什麼不寫發點數】
--   `grant_points_tx` 2026-09-19 實查**不存在** ⇒ 照抄會在第一次解鎖時 runtime 炸，
--   而 `CREATE FUNCTION` 不檢查函式體（硬規則 7）—— 建立時完全不會報錯。
--   而且 §8.5 的鐵則本來就是「成就給徽章與稱號，點數是最克制的那一層」。
--   ⇒ `reward_points` 欄位留著，但**沒有任何程式碼會讀它**。日後要發再接。
--
-- 【🆕 ⑩ 累積型的冪等 —— 設計稿漏掉的】
--   設計稿的 ach_progress_tx 收 p_idem，但它**只把那個值傳給 grant_points_tx**，
--   自己完全沒有去重 ⇒ 同一個事件送兩次，current_value 加兩次。
--   🔴 而我們不發點數 ⇒ p_idem 徹底沒有用途 ⇒ 冪等性歸零。
--   ⇒ 結帳重試一次，「飲料愛好者」就多算一杯，**而且沒有任何症狀**。
--
--   ✅ 修法：`member_achievements.last_idem`，同一把鑰匙再來就跳過。
--   ⚠ **已知限制**：只擋得住「連續重複」，擋不住「A→B→A」交錯重送。
--     實務上重試就是連續的，所以夠用；真的要完整去重要另開一張事件表，
--     而那張表會隨著每一次推進長一列 —— 今天不值得。
--
-- 【授權分工】
--   ach_pin_tx        anon ✅   客人自己按的，身分從 JWT
--   其餘五支          service_role only 🔴
--                     「系統判定你達成了」不可以讓客人自己宣告
-- ============================================================

-- ---------- ⑩ 冪等欄位 ----------
alter table member_achievements add column if not exists last_idem text;
comment on column member_achievements.last_idem is
  '上一次推進用的冪等鍵。同一把鑰匙再送一次會被跳過。
   ⚠ 只擋連續重複，擋不住交錯重送（A→B→A）—— 實務上重試是連續的，夠用。';


-- ---------- 內部：取進度列（鎖），不存在則建 ----------
create or replace function public._ma_row(p_member uuid, p_ach uuid, p_org uuid)
returns member_achievements
language plpgsql security definer set search_path = public as $$
declare r member_achievements;
begin
  select * into r from member_achievements
   where member_id = p_member and achievement_id = p_ach
   for update;
  if not found then
    insert into member_achievements(org_id, member_id, achievement_id)
    values (p_org, p_member, p_ach)
    returning * into r;
  end if;
  return r;
end $$;


-- ---------- 內部：成就是否在有效視窗 ----------
create or replace function public._ach_live(a achievements)
returns boolean language sql immutable as $$
  select a.is_active
     and a.deleted_at is null
     and (a.valid_from is null or now() >= a.valid_from)
     and (a.valid_to   is null or now() <  a.valid_to)
$$;


-- ---------- 一次性：達成即解鎖（specific / prestige）----------
create or replace function public.ach_unlock_tx(
  p_member uuid, p_code text, p_idem text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid; a achievements; r member_achievements;
begin
  select org_id into v_org from members where id = p_member and deleted_at is null;
  if v_org is null then return jsonb_build_object('ok', false, 'reason', 'member_not_found'); end if;

  select * into a from achievements
   where org_id = v_org and code = p_code and deleted_at is null;
  if not found then return jsonb_build_object('ok', false, 'reason', 'achievement_not_found'); end if;
  if not _ach_live(a) then return jsonb_build_object('ok', true, 'skipped', 'out_of_window'); end if;

  r := _ma_row(p_member, a.id, v_org);
  if r.status = 'unlocked' then return jsonb_build_object('ok', true, 'already', true); end if;

  update member_achievements
     set status = 'unlocked', current_tier = 1, unlocked_at = now(),
         last_idem = coalesce(p_idem, last_idem), updated_at = now()
   where id = r.id;

  -- ⚠ 這裡**刻意沒有發點數** —— grant_points_tx 不存在（見檔頭①）
  return jsonb_build_object('ok', true, 'unlocked', true,
                            'code', p_code, 'title', a.grants_title);
end $$;


-- ---------- 累積：加計數，跨門檻自動解級 ----------
create or replace function public.ach_progress_tx(
  p_member uuid, p_code text, p_delta bigint default 1, p_idem text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid; a achievements; r member_achievements;
  v_new bigint; v_tier int; v_max int;
begin
  select org_id into v_org from members where id = p_member and deleted_at is null;
  if v_org is null then return jsonb_build_object('ok', false, 'reason', 'member_not_found'); end if;

  select * into a from achievements
   where org_id = v_org and code = p_code and deleted_at is null;
  if not found then return jsonb_build_object('ok', false, 'reason', 'achievement_not_found'); end if;
  if a.struct not in ('cumulative','streak') then
    return jsonb_build_object('ok', false, 'reason', 'not_cumulative');
  end if;
  if not _ach_live(a) then return jsonb_build_object('ok', true, 'skipped', 'out_of_window'); end if;

  r := _ma_row(p_member, a.id, v_org);
  if r.status = 'unlocked' then
    return jsonb_build_object('ok', true, 'already', true, 'value', r.current_value);
  end if;

  -- 🔴 ⑩ 冪等：同一把鑰匙再送一次就跳過（設計稿漏掉的）
  if p_idem is not null and r.last_idem = p_idem then
    return jsonb_build_object('ok', true, 'dedup', true, 'value', r.current_value);
  end if;

  v_new := r.current_value + p_delta;
  select coalesce(max(tier_level), 0) into v_max
    from achievement_tiers where achievement_id = a.id;
  select coalesce(max(tier_level), 0) into v_tier
    from achievement_tiers where achievement_id = a.id and threshold <= v_new;

  update member_achievements
     set current_value = v_new,
         current_tier  = greatest(current_tier, v_tier),
         status = case when v_max > 0 and v_tier >= v_max then 'unlocked'
                       when v_new > 0 then 'in_progress' else 'locked' end,
         unlocked_at = case when v_max > 0 and v_tier >= v_max and unlocked_at is null
                            then now() else unlocked_at end,
         last_idem = coalesce(p_idem, last_idem),
         updated_at = now()
   where id = r.id;

  return jsonb_build_object('ok', true, 'value', v_new, 'tier', v_tier, 'max', v_max);
end $$;


-- ---------- 連續：advance=true 接續、false 歸 1 ----------
create or replace function public.ach_streak_tx(
  p_member uuid, p_code text, p_period_key text,
  p_advance boolean default true, p_idem text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid; a achievements; r member_achievements;
  v_new bigint; v_tier int; v_max int;
begin
  if p_period_key is null or p_period_key = '' then
    return jsonb_build_object('ok', false, 'reason', 'period_key_required');
  end if;

  select org_id into v_org from members where id = p_member and deleted_at is null;
  if v_org is null then return jsonb_build_object('ok', false, 'reason', 'member_not_found'); end if;

  select * into a from achievements
   where org_id = v_org and code = p_code and deleted_at is null;
  if not found then return jsonb_build_object('ok', false, 'reason', 'achievement_not_found'); end if;
  if a.struct <> 'streak' then return jsonb_build_object('ok', false, 'reason', 'not_streak'); end if;
  if not _ach_live(a) then return jsonb_build_object('ok', true, 'skipped', 'out_of_window'); end if;

  r := _ma_row(p_member, a.id, v_org);
  if r.status = 'unlocked' then
    return jsonb_build_object('ok', true, 'already', true, 'value', r.current_value);
  end if;

  -- 🎯 連續型天然冪等：同一個期間鍵重送不會重複計
  if r.last_period is not null and r.last_period = p_period_key then
    return jsonb_build_object('ok', true, 'dedup', true, 'value', r.current_value);
  end if;

  v_new := case when p_advance then r.current_value + 1 else 1 end;
  select coalesce(max(tier_level), 0) into v_max
    from achievement_tiers where achievement_id = a.id;
  select coalesce(max(tier_level), 0) into v_tier
    from achievement_tiers where achievement_id = a.id and threshold <= v_new;

  update member_achievements
     set current_value = v_new,
         current_tier  = greatest(current_tier, v_tier),
         last_period   = p_period_key,
         status = case when v_max > 0 and v_tier >= v_max then 'unlocked'
                       when v_new > 0 then 'in_progress' else 'locked' end,
         unlocked_at = case when v_max > 0 and v_tier >= v_max and unlocked_at is null
                            then now() else unlocked_at end,
         last_idem = coalesce(p_idem, last_idem),
         updated_at = now()
   where id = r.id;

  return jsonb_build_object('ok', true, 'value', v_new, 'tier', v_tier, 'max', v_max);
end $$;


-- ---------- 🎯 展示櫃：只能放 1 枚，而且是切換語意 ----------
create or replace function public.ach_pin_tx(p_code text, p_on boolean default true)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me uuid; v_org uuid; a achievements; r member_achievements;
begin
  -- 🔴 身分一律從 JWT 取，不收 p_member_id（同 2026-09-20 那 21 支的通則）
  v_me := public.current_member_id();
  if v_me is null then
    raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000';
  end if;
  select org_id into v_org from members where id = v_me;

  select * into a from achievements
   where org_id = v_org and code = p_code and deleted_at is null;
  if not found then return jsonb_build_object('ok', false, 'reason', 'achievement_not_found'); end if;

  select * into r from member_achievements
   where member_id = v_me and achievement_id = a.id for update;
  if not found or r.status <> 'unlocked' then
    return jsonb_build_object('ok', false, 'reason', 'not_unlocked');
  end if;

  if p_on then
    -- 🎯 切換語意：先把舊的取消，不要叫客人先取下再釘
    --   （把「最多 3 枚」改成「最多 1 枚」而不改語意的話，
    --     客人會遇到「展示櫃滿了」而那是一句沒有意義的話）
    update member_achievements
       set pinned = false, updated_at = now()
     where member_id = v_me and pinned and id <> r.id;
  end if;

  update member_achievements
     set pinned = p_on, updated_at = now()
   where id = r.id;

  return jsonb_build_object('ok', true, 'pinned', p_on, 'code', p_code);
end $$;


-- ---------- 🎯 事件驅動：後端動作發生時丟一個事件 ----------
create or replace function public.fire_event_tx(
  p_member     uuid,
  p_event      text,
  p_delta      bigint default 1,
  p_period_key text   default null,
  p_idem       text   default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r record; v_res jsonb := '[]'::jsonb; v_one jsonb; v_idem text; v_org uuid;
begin
  select org_id into v_org from members where id = p_member and deleted_at is null;
  if v_org is null then return jsonb_build_object('ok', false, 'reason', 'member_not_found'); end if;

  for r in
    select code, struct, requires_code
      from achievements
     where org_id = v_org
       and deleted_at is null
       and is_active
       and (trigger->>'event') = p_event
       and (valid_from is null or now() >= valid_from)
       and (valid_to   is null or now() <  valid_to)
     order by sort, code
  loop
    -- 前置依賴：沒解鎖前置就跳過（系列成就不會跳級）
    if r.requires_code is not null then
      if not exists (
        select 1 from member_achievements ma
          join achievements a2 on a2.id = ma.achievement_id
         where ma.member_id = p_member
           and a2.code = r.requires_code
           and ma.status = 'unlocked')
      then continue; end if;
    end if;

    -- 每個成就各自一把冪等鍵：同一個來源事件不會把同一枚重複計
    v_idem := coalesce(p_idem, 'evt') || ':' || p_event || ':' || r.code;

    if r.struct in ('specific','prestige') then
      v_one := public.ach_unlock_tx(p_member, r.code, v_idem);
    elsif r.struct = 'cumulative' then
      v_one := public.ach_progress_tx(p_member, r.code, p_delta, v_idem);
    elsif r.struct = 'streak' then
      if p_period_key is null then
        v_one := jsonb_build_object('ok', false, 'reason', 'period_key_required');
      else
        v_one := public.ach_streak_tx(p_member, r.code, p_period_key, true, v_idem);
      end if;
    else
      continue;
    end if;

    v_res := v_res || jsonb_build_array(
      jsonb_build_object('code', r.code, 'struct', r.struct, 'result', v_one));
  end loop;

  return jsonb_build_object('ok', true, 'event', p_event, 'matched', v_res);
end $$;


-- ============================================================
-- 授權：🔴 兩個方向都要收（硬規則 2.6b）
--   舊函式的 anon 從 PUBLIC 繼承 → revoke from public
--   新建的函式是 default privileges **明確授權** → revoke from anon
--   兩條路都收才乾淨
-- ============================================================
do $$
declare f text;
begin
  foreach f in array array[
    'public._ma_row(uuid,uuid,uuid)',
    'public._ach_live(achievements)',
    'public.ach_unlock_tx(uuid,text,text)',
    'public.ach_progress_tx(uuid,text,bigint,text)',
    'public.ach_streak_tx(uuid,text,text,boolean,text)',
    'public.fire_event_tx(uuid,text,bigint,text,text)'
  ] loop
    execute 'revoke execute on function ' || f || ' from public';
    execute 'revoke execute on function ' || f || ' from anon, authenticated';
    execute 'grant  execute on function ' || f || ' to service_role';
  end loop;
end $$;

-- 🎯 唯一給客人叫的一支：身分從 JWT，沒有 JWT 會拿到 28000
revoke execute on function public.ach_pin_tx(text, boolean) from public;
grant  execute on function public.ach_pin_tx(text, boolean) to anon, authenticated, service_role;


-- ============================================================
-- 驗證（🔴 不可以用 raise —— 這一份要留下函式，硬規則 1.8）
-- ⚠ 行為測試（造樣本、要回滾）另外跑 sql/checks/ 那一份
-- ============================================================
do $$
declare v_msg text := ''; v_n int; v_t text;
begin
  -- ① 六支都建好了
  select count(*) into v_n from pg_proc
  where pronamespace='public'::regnamespace
    and proname in ('_ma_row','_ach_live','ach_unlock_tx','ach_progress_tx',
                    'ach_streak_tx','ach_pin_tx','fire_event_tx');
  v_msg := v_msg || case when v_n = 7
    then '✅ ① 七支函式都建好了' else '🔴 ① 只有 ' || v_n || ' 支' end;

  -- ② 全部是 SECURITY DEFINER（設計稿有四支是 INVOKER，那會被 RLS 擋住）
  select count(*) into v_n from pg_proc
  where pronamespace='public'::regnamespace
    and proname in ('_ma_row','ach_unlock_tx','ach_progress_tx',
                    'ach_streak_tx','ach_pin_tx','fire_event_tx')
    and prosecdef;
  v_msg := v_msg || E'\n' || case when v_n = 6
    then '✅ ② 六支都是 SECURITY DEFINER'
    else '🔴 ② 只有 ' || v_n || ' 支是 DEFINER —— INVOKER 會被 RLS 濾成靜默失敗' end;

  -- ③ 🔴 anon 只能叫得動 ach_pin_tx
  select coalesce(string_agg(p.proname, '、' order by p.proname), '(沒有)') into v_t
  from pg_proc p
  where p.pronamespace='public'::regnamespace
    and p.proname in ('_ma_row','_ach_live','ach_unlock_tx','ach_progress_tx',
                      'ach_streak_tx','ach_pin_tx','fire_event_tx')
    and exists (select 1 from aclexplode(p.proacl) a
                where a.grantee = 'anon'::regrole::oid and a.privilege_type='EXECUTE');
  v_msg := v_msg || E'\n' || case when v_t = 'ach_pin_tx'
    then '✅ ③ anon 只叫得動 ach_pin_tx（其餘全收）'
    else '🔴 ③ anon 叫得動：' || v_t end;

  -- ④ 🔴 PUBLIC 那條路也要收（同一個症狀兩個來源，硬規則 2.6b）
  select count(*) into v_n from pg_proc p
  where p.pronamespace='public'::regnamespace
    and p.proname in ('_ma_row','_ach_live','ach_unlock_tx','ach_progress_tx',
                      'ach_streak_tx','fire_event_tx')
    and (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                                      where a.grantee = 0 and a.privilege_type='EXECUTE'));
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ④ PUBLIC 那條路也收乾淨了'
    else '🔴 ④ 還有 ' || v_n || ' 支的 PUBLIC 沒收 —— 收 anon 對它們沒有效果' end;

  -- ⑤ ach_pin_tx 不收 p_member_id（身分不可以由呼叫端宣告）
  select pg_get_function_identity_arguments(oid) into v_t
  from pg_proc where pronamespace='public'::regnamespace and proname='ach_pin_tx';
  v_msg := v_msg || E'\n' || case when v_t !~ 'member'
    then '✅ ⑤ ach_pin_tx 不收會員 id（' || v_t || '）'
    else '🔴 ⑤ ach_pin_tx 收了 ' || v_t end;

  -- ⑥ 展示櫃是切換語意，不是「滿了就拒絕」
  select count(*) into v_n from pg_proc
  where pronamespace='public'::regnamespace and proname='ach_pin_tx'
    and pg_get_functiondef(oid) ~ 'set pinned = false';
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '✅ ⑥ 釘新的會自動取消舊的（切換語意）'
    else '🔴 ⑥ 沒有取消舊的那段 —— 客人會遇到「展示櫃滿了」' end;

  -- ⑦ 🔴 負對照：整批不可以有任何發點數的程式碼
  select count(*) into v_n from pg_proc
  where pronamespace='public'::regnamespace
    and proname in ('ach_unlock_tx','ach_progress_tx','ach_streak_tx','fire_event_tx')
    and pg_get_functiondef(oid) ~ 'grant_points';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ⑦ 沒有任何一支會呼叫不存在的 grant_points_tx'
    else '🔴 ⑦ 有 ' || v_n || ' 支會在第一次解鎖時 runtime 炸' end;

  -- ⑧ 累積型的冪等欄位在
  select count(*) into v_n from information_schema.columns
  where table_schema='public' and table_name='member_achievements' and column_name='last_idem';
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '✅ ⑧ last_idem 建好了（設計稿漏掉的那個冪等）'
    else '🔴 ⑧ 沒有 last_idem —— 事件重送會重複計' end;

  perform set_config('migi.verify', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify', true), ''), '🔴 沒有驗證訊息') as "驗證";
