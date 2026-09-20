-- ============================================================
-- ① 匯入傳說兩枚（MIGI／十次 MIGI）　② 累積型的進度也畫得出來
-- 2026-09-20　使用者指定「傳說兩個要放上」
--
-- 📄 來源：`docs/03-會員App與社交/成就系統企劃.md` §咪幾＝MIGI＝牌型 8 台
--    **全系統只有這兩枚是傳說。**
--
-- 🔴 **兩枚共用同一個事件 `migi_hu`，而那是設計不是疏漏。**
--    對照表寫過「不可以讓兩枚共用一個事件名」，那條針對的是**兩枚都 specific**
--    （一次事件會把那一批全開）。這裡是 specific ＋ cumulative：
--      migi_01  specific    → ach_unlock_tx    第一次就解鎖
--      migi_02  cumulative  → ach_progress_tx  同一次 +1
--    ⇒ 第一次 MIGI 同時解鎖「MIGI」並讓「十次 MIGI」的進度走一格，正是要的行為。
--
-- 🔴 ② **累積型的門檻不在 `trigger` 裡，在 `achievement_tiers`**
--    （`ach_progress_tx` 讀 `max(tier_level)` 與 `threshold` 判斷達標）。
--    而 `get_my_achievements_tx` 的 `target` **只看 `trigger->>'count'`**
--    ⇒ 十次 MIGI 的 target 會是 null ⇒ **進度條畫不出來，而且不會報錯**。
--    ⚠ 那是一個「等著發生」的洞：今天沒有任何 cumulative 成就，所以踩不到。
--    ⇒ 這一批補上它，否則匯入的當下就會有一枚成就的進度條是啞的。
--
-- ⚠ 驗證段一個字都不准 raise（硬規則 1.8）。
-- ============================================================

-- ---------- ① 兩枚傳說 ----------
/* ⚠ `is_active = true`（使用者指定「放上」）—— 即使 `migi_hu` 這個事件
     今天發不出來（要等 M4 電子計分判定牌型 8 台）。
   🎯 那與 C 區 31 枚牌型的處理**不一樣**，是刻意的：
     使用者拍板「成就要讓人知道有什麼可以追」⇒ 旗艦那兩枚要看得見。
   📌 C 區與 A 區那 11 枚今天仍是 `is_active = false`（清單上看不到）——
     要不要一起打開是另一個決定，不在這一批。
   ✅ **使用者當天就拍板「全部打開」** → `2026-09-20_打開其餘42枚成就.sql`。
     ⚠ 那份**要在這一份之後跑**（它的驗證段會數「關著的還有幾枚」，
       而這兩枚是 active 的，先後順序會讓那個期望值對不上）。 */
insert into achievements (
  org_id, code, name, description, condition_text, group_key, ui_category,
  struct, motivation, rarity, visibility, trigger, is_signature, sort, is_active)
select o.id, v.code, v.name, v.description, v.cond, '旗艦', 'game',
       v.struct, 'prestige', 'legend', 'visible',
       jsonb_build_object('event', 'migi_hu'), true, v.sort, true
  from orgs o
 cross join (values
   ('migi_01', 'MIGI',      '我 MIGI 了！',       '第一次 MIGI 胡牌', 'specific',   88),
   ('migi_02', '十次 MIGI', '這不是運氣，是實力', '累積 MIGI 10 次',  'cumulative', 89)
 ) v(code, name, description, cond, struct, sort)
 where o.deleted_at is null
   and not exists (select 1 from achievements a
                    where a.org_id = o.id and a.code = v.code and a.deleted_at is null);

/* 累積型的門檻。⚠ `tier_name` 是 NOT NULL —— 它是「第幾階叫什麼」，
   十次 MIGI 只有一階，所以就叫它自己的名字。 */
insert into achievement_tiers (org_id, achievement_id, tier_level, tier_name, threshold)
select a.org_id, a.id, 1, '十次 MIGI', 10
  from achievements a
 where a.code = 'migi_02' and a.deleted_at is null
   and not exists (select 1 from achievement_tiers t where t.achievement_id = a.id);

-- ---------- ② 讀取端：累積型的 target 也拿得到 ----------
create or replace function public.get_my_achievements_tx()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_member uuid;
  v_org    uuid;
  v_rows   jsonb;
  v_total  int;
  v_done   int;
begin
  v_member := public.current_member_id();
  if v_member is null then
    raise exception '未登入，無法讀取成就' using errcode = '28000';
  end if;

  select org_id into v_org from members where id = v_member and deleted_at is null;
  if v_org is null then
    raise exception '會員不存在' using errcode = '28000';
  end if;

  select coalesce(jsonb_agg(x order by x.ord, x.code), '[]'::jsonb),
         count(*)::int,
         count(*) filter (where x.status = 'unlocked')::int
    into v_rows, v_total, v_done
  from (
    select
      a.code,
      case when a.visibility = 'silhouette'
                and coalesce(ma.status, 'locked') <> 'unlocked'
           then '？？？' else a.name end                          as name,
      case when a.visibility = 'silhouette'
                and coalesce(ma.status, 'locked') <> 'unlocked'
           then null else a.description end                       as description,
      case when a.visibility = 'silhouette'
                and coalesce(ma.status, 'locked') <> 'unlocked'
           then null else a.condition_text end                    as condition_text,
      a.ui_category                                               as category,
      a.rarity,
      a.group_key,
      a.is_signature                                              as signature,
      (a.visibility = 'silhouette'
        and coalesce(ma.status, 'locked') <> 'unlocked')          as masked,
      coalesce(ma.status, 'locked')                               as status,
      /* 🎯 **進度的分子**，兩種來源（不同機制）：
           cumulative  `ach_progress_tx` 一路累加，值就在 member_achievements
           meta        沒有人累加 ⇒ 當下數一次，與 ach_meta_tx 同一支函式 */
      case when a.trigger ? 'count'
           then coalesce(public.ach_meta_count_tx(
                  v_member, a.trigger->>'scope', a.trigger->>'value'), 0)
           else coalesce(ma.current_value, 0) end                 as current_value,
      /* 🔴 **分母也有兩種來源，而這是 2026-09-20 補的**：
           meta        `trigger->>'count'`
           cumulative  `achievement_tiers` 的最大 threshold（ach_progress_tx 讀的就是它）
         ⚠ 少了第二條，累積型成就的 target 是 null ⇒ **進度條畫不出來而且不報錯**。
           今天踩不到只是因為在此之前一枚 cumulative 都沒有。 */
      coalesce(
        case when a.trigger ? 'count' then (a.trigger->>'count')::int end,
        (select max(t.threshold)::int from achievement_tiers t
          where t.achievement_id = a.id)
      )                                                           as target,
      coalesce(ma.pinned, false)                                  as pinned,
      ma.unlocked_at,
      a.sort                                                      as ord
      from achievements a
      left join member_achievements ma
             on ma.achievement_id = a.id and ma.member_id = v_member
     where a.org_id = v_org
       and a.deleted_at is null
       and a.is_active
       and (a.valid_from is null or now() >= a.valid_from)
       and (a.valid_to   is null or now() <  a.valid_to)
       and not (a.visibility = 'hidden'
                and coalesce(ma.status, 'locked') <> 'unlocked')
  ) x;

  return jsonb_build_object(
    'ok', true,
    'total', v_total,
    'unlocked', v_done,
    'achievements', v_rows
  );
end $$;

revoke execute on function public.get_my_achievements_tx() from public;
revoke execute on function public.get_my_achievements_tx() from anon;
grant  execute on function public.get_my_achievements_tx() to authenticated;

-- ============================================================
-- 驗證（🔴 不准 raise）
-- ============================================================
do $$
declare
  v_msg    text := '';
  v_txt    text;
  v_n      int;
  v_member uuid;
  v_line   text;
  v_r      jsonb;
  v_row    jsonb;
begin
  -- ---------- ① 兩枚都在，而且是傳說 ----------
  select count(*) into v_n from achievements
   where code in ('migi_01','migi_02') and deleted_at is null
     and rarity = 'legend' and is_active and visibility = 'visible';
  v_msg := case when v_n = 2
    then '✅ ① 傳說兩枚都在（legend · active · 不遮）'
    else '🔴 ① 只有 ' || v_n || ' 枚符合，應為 2' end;

  -- ---------- ② 🔴 全系統只有這兩枚是傳說 ----------
  -- 企劃第 879 行寫著這句。多一枚就表示有人把別的成就升級了
  select count(*) into v_n from achievements
   where deleted_at is null and rarity = 'legend';
  v_msg := v_msg || E'\n' || case when v_n = 2
    then '✅ ② 全系統傳說正好 2 枚（企劃：只有咪幾那兩枚）'
    else '🔴 ② 傳說有 ' || v_n || ' 枚 —— 那個名字會變得不特別' end;

  -- ---------- ③ 共用事件是設計：一個 specific ＋ 一個 cumulative ----------
  select count(*) into v_n from achievements
   where code in ('migi_01','migi_02') and deleted_at is null
     and trigger->>'event' = 'migi_hu';
  /* ⚠ `coalesce` 不可省：兩枚都沒建的話子查詢回 null，
       而 `字串 || null = null` 會把前面兩格一起抹掉（硬規則 3.555）。 */
  select coalesce(string_agg(code || '=' || struct, '、' order by code), '（一枚都沒有）')
    into v_txt
    from achievements where code in ('migi_01','migi_02') and deleted_at is null;
  v_msg := v_msg || E'\n' || case when v_n = 2
    then '✅ ③ 兩枚共用 migi_hu（specific 解鎖 ＋ cumulative +1，同一次事件）　' || v_txt
    else '🔴 ③ 事件名對不上：' || v_txt end;

  -- ---------- ④ 累積型的門檻 ----------
  select count(*) into v_n
    from achievement_tiers t join achievements a on a.id = t.achievement_id
   where a.code = 'migi_02' and t.threshold = 10 and t.tier_level = 1;
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '✅ ④ 十次 MIGI 的門檻在 achievement_tiers（threshold 10）'
    else '🔴 ④ 門檻沒建 —— ach_progress_tx 的 v_max 會是 0，永遠不會解鎖' end;

  -- ---------- ⑤ 🔴 讀取端的 target 兩條路都通 ----------
  select m.id, m.line_user_id into v_member, v_line
    from members m where m.deleted_at is null and m.line_user_id is not null
   order by m.created_at limit 1;
  if v_line is null then
    v_msg := v_msg || E'\n' || '⚪ ⑤ 找不到綁了 LINE 的會員，測不了';
  else
    perform set_config('request.jwt.claims',
      json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated',
                        'app_metadata', json_build_object('line_user_id', v_line))::text,
      true);
    begin
      v_r := public.get_my_achievements_tx();

      select x into v_row from jsonb_array_elements(v_r->'achievements') x
       where x->>'code' = 'migi_02';
      v_msg := v_msg || E'\n' || case when (v_row->>'target')::int = 10
        then '✅ ⑤ 累積型（十次 MIGI）的 target 從 achievement_tiers 拿到了：'
             || (v_row->>'current_value') || ' / ' || (v_row->>'target')
        else '🔴 ⑤ 累積型的 target 是 ' || coalesce(v_row->>'target','null')
             || ' —— 進度條會畫不出來' end;

      -- 🔴 負對照：specific 那一枚**不可以**有 target（它沒有進度可言）
      select x into v_row from jsonb_array_elements(v_r->'achievements') x
       where x->>'code' = 'migi_01';
      v_msg := v_msg || E'\n' || case when v_row->>'target' is null
        then '✅ ⑤ 而 specific 那一枚（MIGI）沒有 target —— 不會畫出一條 0 / 0 的條'
        else '🔴 ⑤ specific 竟然有 target ' || (v_row->>'target') end;

      -- meta 那一條仍然走 trigger.count
      select x into v_row from jsonb_array_elements(v_r->'achievements') x
       where x->>'code' = 'onboarding_29';
      v_msg := v_msg || E'\n' || case when (v_row->>'target')::int = 15
        then '✅ ⑤ meta（新手畢業）仍然是 15 —— 兩條來源沒有互相蓋掉'
        else '🔴 ⑤ meta 的 target 變成 ' || coalesce(v_row->>'target','null') end;

      v_msg := v_msg || E'\n' || '⚪ ⑥ 清單現在 ' || (v_r->>'total') || ' 枚（原 18 ＋ 這批 2 = 20）';
    exception when others then
      v_msg := v_msg || E'\n' || '🔴 ⑤ 呼叫炸了：' || sqlstate || ' ' || sqlerrm;
    end;
    perform set_config('request.jwt.claims', '', true);
  end if;

  -- ---------- ⑦ 🔴 還沒有發射端，那是預期的 ----------
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and pg_get_functiondef(p.oid) ~ 'fire_event_tx\s*\([^;]{0,160}''migi_hu''';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '⚪ ⑦ migi_hu 還沒有發射端 —— **那是預期的**，它要等 M4 判定牌型 8 台。'
         || '在那之前這兩枚看得到、解不開'
    else '✅ ⑦ 已經有 ' || v_n || ' 支在發 migi_hu' end;

  perform set_config('migi.verify', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify', true), ''), '🔴 沒有驗證訊息') as "驗證";
