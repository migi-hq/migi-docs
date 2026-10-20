-- ════════════════════════════════════════════════════════════════
-- 2026-10-21 報表用的 v_real_members 補上 legend_title（名人玩家頭銜）
-- ────────────────────────────────────────────────────────────────
-- 錯誤儀表 ⑫ 抓到的：10-17 加 members.legend_title 時沒有一起補進檢視表。
-- 檢視表的欄位是建立當下展開的清單，底層表加欄位不會跟進 ⇒ 報表查不到、也不報錯。
-- 做法：CREATE OR REPLACE VIEW，新欄位加在最後（只能往後加），其餘逐字照線上定義。
-- ⚠ CREATE OR REPLACE 不會動權限：維持只有 postgres、service_role（前端讀不到，同錯誤儀表 ⑯）。
-- ════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW public.v_real_members AS
 SELECT m.id,
    m.org_id,
    m.line_user_id,
    m.display_name,
    m.phone,
    m.home_store_id,
    m.tier,
    m.gender,
    m.birthday,
    m.occupation,
    m.district,
    m.acquisition_source,
    m.avatar_url,
    m.last_visit_at,
    m.visit_count,
    m.lifecycle,
    m.primary_staff_id,
    m.deleted_at,
    m.created_at,
    m.updated_at,
    m.created_by,
    m.updated_by,
    m.tier_override,
    m.last_app_active_at,
    m.rank,
    m.title,
    m.likes_count,
    m.is_test,
    m.about,
    m.sched,
    m.style,
    m.see_score,
    m.baby_tile,
    m.avatar_source,
    m.avatar_photo_path,
    m.avatar_photo_at,
    m.avatar_blocked,
    m.avatar_removed_count,
    m.inv_type,
    m.inv_carrier,
    m.inv_donate_code,
    m.inv_tax_id,
    m.inv_title,
    m.avatar_bear,
    m.phone_verified_at,
    m.rating,
    m.rating_games,
    m.hidden_at,
    m.best_rank_tier,
    m.legend_title
   FROM members m
     JOIN orgs o ON o.id = m.org_id
  WHERE m.is_test = false AND m.deleted_at IS NULL AND m.created_at >= COALESCE(o.live_from, 'infinity'::timestamp with time zone);

-- ── 驗證（單一 SELECT，不 raise）──────────────────────────────────
select
  case when exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'v_real_members' and column_name = 'legend_title')
       then '✅ ① v_real_members 有 legend_title 了' else '🔴 ① 沒加到' end
  || E'\n' ||
  coalesce((select '🔴 ② 還有漏的：' || string_agg(t.column_name, '、')
              from information_schema.columns t
             where t.table_schema = 'public' and t.table_name = 'members'
               and not exists (select 1 from information_schema.columns v
                                where v.table_schema = 'public' and v.table_name = 'v_real_members'
                                  and v.column_name = t.column_name)
            having count(*) > 0),
           '✅ ② members 的每一欄檢視表都有')
  || E'\n' ||
  case when not has_table_privilege('anon', 'public.v_real_members', 'SELECT')
        and not has_table_privilege('authenticated', 'public.v_real_members', 'SELECT')
       then '✅ ③ 前端照舊讀不到（權限沒被打開）' else '🔴 ③ 前端讀得到了 —— 要收回' end
  as "驗證";
