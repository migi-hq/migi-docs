-- ============================================================================
-- 2026-10-12  成就新增「升上銅牌熊」（rank_18）
-- ----------------------------------------------------------------------------
-- 起點：使用者給了七枚段位徽章（銅、銀、金、白金、鑽石、紫盾、皇冠），
--      而段位區只有「升上銀牌熊」起跳，銅牌那一枚沒有成就可以掛 ⇒ 使用者選「新增」。
--
-- 三件事：
--   ① 新增成就 rank_18「升上銅牌熊」，排在「第一次升級」前面（sort 96，段位區內最前）
--   ② trg_members_rank_events 的跨階迴圈原本寫「sort >= 2」，刻意跳過銅牌 ——
--      改成從銅牌開始發。新會員第一場打完段位從「沒有」變成「銅牌熊 III」，
--      那一刻發 rank_reach_bronze。⚠ 函式只改那一個數字，其餘逐字照線上版
--   ③ 補發：目前已經有段位的會員（銅牌以上）都沒走過那一刻，用 fire_event_tx 補，
--      冪等鍵固定（重跑不會重複）。順帶會讓 ach_meta_tx 重算「段位收藏家」——
--      那是對的（多一枚段位成就，可能剛好湊滿 5 枚）。
--      📌 解鎖不會發通知（member_achievements 沒有觸發器，ach_unlock_tx 也不發），
--        所以補發不會吵到任何人。
--
-- 徽章圖另外上傳（ach_rank_18.webp），badge_path 由之後那份回填處理。
-- ============================================================================

-- ① 新增成就（照 rank_02 的機構建，已經有就跳過）
insert into public.achievements
  (org_id, code, name, description, condition_text, group_key, ui_category,
   struct, motivation, rarity, visibility, trigger, sort)
select a.org_id, 'rank_18', '升上銅牌熊', '段位這條路的第一步', '段位達到銅牌熊（打完第一場就有）',
       '段位', 'game', 'prestige', 'prestige', 'norm', 'visible',
       '{"event":"rank_reach_bronze"}'::jsonb, 96
  from public.achievements a
 where a.code = 'rank_02' and a.deleted_at is null
   and not exists (select 1 from public.achievements x
                    where x.org_id = a.org_id and x.code = 'rank_18' and x.deleted_at is null);

-- ② 跨階迴圈從銅牌開始
create or replace function public.trg_members_rank_events()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_ot text; v_nt text; v_os int; v_ns int; v_bs int; v_ob int; v_nb int;
  v_idem text; t record;
begin
  if new.deleted_at is not null then return null; end if;
  begin
    v_ot := public._rank_tier_of(old.rank);
    v_nt := public._rank_tier_of(new.rank);
    select sort into v_os from public.rank_tiers where code = v_ot;
    select sort into v_ns from public.rank_tiers where code = v_nt;
    select sort into v_bs from public.rank_tiers where code = old.best_rank_tier;
    v_idem := 'rank:' || new.id::text || ':' || coalesce(new.rank, '') || ':' || coalesce(new.rating, 0)::text;

    -- 同階升級：級數 IV → III → II → I
    if v_ot is not null and v_ot = v_nt then
      v_ob := case when old.rank ~ ' IV$' then 1 when old.rank ~ ' III$' then 2 when old.rank ~ ' II$' then 3 when old.rank ~ ' I$' then 4 end;
      v_nb := case when new.rank ~ ' IV$' then 1 when new.rank ~ ' III$' then 2 when new.rank ~ ' II$' then 3 when new.rank ~ ' I$' then 4 end;
      if v_ob is not null and v_nb is not null and v_nb > v_ob then
        perform public.fire_event_tx(new.id, 'rank_band_up', 1, null, v_idem);
      end if;
    end if;

    -- 跨階：一次跳好幾階時，中間每一階都算到過。
    -- 2026-10-12 起從銅牌開始（原本跳過銅牌）：段位從「沒有」變成銅牌也算跨階
    if v_ns is not null and v_ns > coalesce(v_os, 0) then
      for t in select code from public.rank_tiers
                where sort > coalesce(v_os, 0) and sort <= v_ns and sort >= 1
                order by sort loop
        perform public.fire_event_tx(new.id, 'rank_reach_' || t.code, 1, null, v_idem);
      end loop;
    end if;

    -- 段位分門檻（達到就算，之後掉下去不收回）
    if coalesce(new.rating, 0) >= 300 then perform public.fire_event_tx(new.id, 'rating_300', 1, null, v_idem); end if;
    if coalesce(new.rating, 0) >= 600 then perform public.fire_event_tx(new.id, 'rating_600', 1, null, v_idem); end if;
    if coalesce(new.rating, 0) >= 900 then perform public.fire_event_tx(new.id, 'rating_900', 1, null, v_idem); end if;

    -- 回到巔峰：之前掉到最高階以下，這一次回到最高階
    if v_bs is not null and v_os is not null and v_ns is not null and v_os < v_bs and v_ns >= v_bs then
      perform public.fire_event_tx(new.id, 'rank_back_to_peak', 1, null, v_idem);
    end if;
  exception when others then null;   -- 成就失敗不可以擋住段位寫入
  end;
  return null;
end $function$;

-- ③ 補發給已經有段位的會員
do $$
declare m record;
begin
  for m in select id from public.members where rank is not null and deleted_at is null loop
    perform public.fire_event_tx(m.id, 'rank_reach_bronze', 1, null, 'backfill:2026-10-12:' || m.id::text);
  end loop;
end $$;

-- ── 驗證（單一 SELECT，不 raise）───────────────────────────────────────────
-- 正對照：有段位的人數 ＝ 解鎖 rank_18 的人數；負對照：沒有段位的人一個都不該有
with a as (select id from public.achievements where code = 'rank_18' and deleted_at is null),
     has_rank as (select id from public.members where rank is not null and deleted_at is null),
     no_rank  as (select id from public.members where rank is null and deleted_at is null),
     got as (select ma.member_id from public.member_achievements ma join a on a.id = ma.achievement_id
              where ma.status = 'unlocked')
select concat_ws(E'\n',
  case when (select count(*) from a) = 1 then '✅ 成就 rank_18 一筆' else '🔴 成就 rank_18 筆數：' || (select count(*) from a) end,
  case when (select count(*) from pg_proc where proname = 'trg_members_rank_events' and pronamespace = 'public'::regnamespace) = 1
        and (select pg_get_functiondef(oid) from pg_proc where proname = 'trg_members_rank_events' and pronamespace = 'public'::regnamespace) ~ 'sort >= 1'
       then '✅ 觸發器從銅牌開始發' else '🔴 觸發器沒換到' end,
  case when (select count(*) from has_rank) = (select count(*) from got where member_id in (select id from has_rank))
       then '✅ 有段位的 ' || (select count(*) from has_rank) || ' 人全部解鎖'
       else '🔴 有段位 ' || (select count(*) from has_rank) || ' 人，解鎖 ' || (select count(*) from got where member_id in (select id from has_rank)) end,
  case when not exists (select 1 from got where member_id in (select id from no_rank))
       then '✅ 沒有段位的 ' || (select count(*) from no_rank) || ' 人沒被誤發'
       else '🔴 沒有段位的人也解鎖了' end
) as "驗證";
