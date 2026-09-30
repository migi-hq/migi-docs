/* ============================================================
   v_real_members 補上 best_rank_tier（曾經到過的最高段位）
   2026-10-01 · MIGI 咪吉麻將

   錯誤儀表 ⑫ 抓到的：2026-09-30 在 members 加了 best_rank_tier（段位熊頭像永久解鎖），
   而報表檢視表的欄位是寫死的清單 ⇒ 不會自己跟上，查報表的人只會以為「沒有這筆資料」。
   · create or replace view 只能在最後面加欄位，原本的順序一個都不動
   · 權限不會掉（replace 保留授權；這支 09-29 起只有 postgres／service_role 讀得到）
   ============================================================ */

create or replace view public.v_real_members as
 SELECT m.id, m.org_id, m.line_user_id, m.display_name, m.phone, m.home_store_id, m.tier, m.gender,
        m.birthday, m.occupation, m.district, m.acquisition_source, m.avatar_url, m.last_visit_at,
        m.visit_count, m.lifecycle, m.primary_staff_id, m.deleted_at, m.created_at, m.updated_at,
        m.created_by, m.updated_by, m.tier_override, m.last_app_active_at, m.rank, m.title,
        m.likes_count, m.is_test, m.about, m.sched, m.style, m.see_score, m.baby_tile,
        m.avatar_source, m.avatar_photo_path, m.avatar_photo_at, m.avatar_blocked,
        m.avatar_removed_count, m.inv_type, m.inv_carrier, m.inv_donate_code, m.inv_tax_id,
        m.inv_title, m.avatar_bear, m.phone_verified_at, m.rating, m.rating_games, m.hidden_at,
        m.best_rank_tier
   FROM members m
     JOIN orgs o ON o.id = m.org_id
  WHERE m.is_test = false AND m.deleted_at IS NULL
    AND m.created_at >= COALESCE(o.live_from, 'infinity'::timestamp with time zone);

/* ============================================================
   驗證（不 raise —— 這份要留下東西）
   ============================================================ */
do $$
declare v_msg text := ''; v_txt text;
begin
  -- ① members 的欄位，檢視表一個都沒漏（同錯誤儀表 ⑫ 的判準）
  select string_agg(c.column_name, '、' order by c.ordinal_position) into v_txt
    from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'members'
     and not exists (select 1 from information_schema.columns v
                      where v.table_schema = 'public' and v.table_name = 'v_real_members' and v.column_name = c.column_name);
  v_msg := v_msg || case when v_txt is null then '✅' else '🔴' end || ' ① v_real_members 漏掉的欄位：' || coalesce(v_txt, '無') || E'\n';

  -- ② 前端還是讀不到
  v_msg := v_msg || case when not has_table_privilege('anon', 'public.v_real_members', 'SELECT')
                          and not has_table_privilege('authenticated', 'public.v_real_members', 'SELECT')
                         then '✅' else '🔴' end || ' ② 前端（anon／authenticated）讀不到這支檢視表' || E'\n';

  -- ③ 上線前仍然是空的（live_from 還沒設 ⇒ 設計上的空）
  v_msg := v_msg || '　③ 目前列數：' || (select count(*) from public.v_real_members) || '（上線前應該是 0）';

  perform set_config('migi.v', v_msg, true);
end $$;
select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有驗證訊息') as "驗證";
