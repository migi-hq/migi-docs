/* ============================================================
   成就清單多回傳 grants_closet（這枚成就送哪件小熊配件）
   2026-11-09 使用者：「成就詳情加一行」—— 詳情頁原本有「稱號獎勵」，配件照同一個做法加「配件獎勵」

   · get_my_achievements_tx 簽名不變（CREATE OR REPLACE，不掉 GRANT），只在 grants_title 下面多一欄
   · 剪影成就還沒解鎖時跟 grants_title 一樣遮掉（回 null）—— 講出獎勵等於講出條件的一部分
   · 函式本體以 2026-11-09 線上 pg_get_functiondef 為準，只加一段
   ============================================================ */

create or replace function public.get_my_achievements_tx()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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
      case when a.visibility = 'silhouette'
                and coalesce(ma.status, 'locked') <> 'unlocked'
           then null else a.grants_title end                      as grants_title,
      /* 2026-11-09：送哪件小熊配件（代碼，前端 lib/closet.jsx 換成名稱）。遮蔽規則同 grants_title */
      case when a.visibility = 'silhouette'
                and coalesce(ma.status, 'locked') <> 'unlocked'
           then null else a.grants_closet end                     as grants_closet,
      (a.visibility = 'silhouette'
        and coalesce(ma.status, 'locked') <> 'unlocked')          as masked,
      /* 徽章圖。遮蔽的成就照樣回傳 —— 前端本來就把未解鎖的圖畫成灰階剪影，
         行為與搬家前（圖寫死在前端）完全相同。 */
      a.badge_path                                                as badge_path,
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
end $function$;

-- ============================================================
-- 驗證（單一 SELECT；不用 raise —— 硬規則 1.8）
-- ============================================================
select
  (select case when count(*) = 1 then '✅ ① 只有一個版本' else '🔴 ① 版本數 ' || count(*) end
     from pg_proc where proname = 'get_my_achievements_tx' and pronamespace = 'public'::regnamespace) as "①",
  (select case when pg_get_functiondef('public.get_my_achievements_tx()'::regprocedure) ~ 'a\.grants_closet end\s+as grants_closet'
          then '✅ ② 回傳裡有 grants_closet' else '🔴 ② 回傳裡沒有 grants_closet' end) as "②",
  /* ③ 授權沒掉（CREATE OR REPLACE 不會掉，但驗一下）：登入的人叫得到、沒登入叫不到 */
  (select case when has_function_privilege('authenticated', 'public.get_my_achievements_tx()', 'EXECUTE')
               and not has_function_privilege('anon', 'public.get_my_achievements_tx()', 'EXECUTE')
          then '✅ ③ 授權：authenticated 有、anon 沒有'
          else '🔴 ③ 授權變了：authenticated ' || has_function_privilege('authenticated', 'public.get_my_achievements_tx()', 'EXECUTE')
               || '、anon ' || has_function_privilege('anon', 'public.get_my_achievements_tx()', 'EXECUTE') end) as "③";
