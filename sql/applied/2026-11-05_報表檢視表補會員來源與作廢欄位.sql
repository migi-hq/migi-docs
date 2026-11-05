-- ═══════════════════════════════════════════════════════════════════
-- 2026-11-05 報表檢視表補會員來源與作廢欄位（錯誤儀表 ⑫）
-- ───────────────────────────────────────────────────────────────────
-- v_real_* 的欄位清單是建立那天就寫死的；底層表後來加的欄位不會自己跟上。
-- 漏掉的兩批：
--   v_real_members          會員來源 6 欄（11-02 會員來源記錄）
--   v_real_orders           作廢紀錄 3 欄（11-03 作廢稽核）
--   v_real_table_sessions   同上
--   v_real_topup_orders     同上
--
-- 做法：create or replace view，原本的欄位與篩選條件一字不改（從線上 pg_get_viewdef 抄），
--       新欄位只接在最後面（Postgres 只允許在尾端加欄位）。
-- ⚠ create or replace 會保留原本的權限 ⇒ 仍然只有 postgres／service_role 讀得到（錯誤儀表 ⑯）；
--   下面仍再收一次 anon／authenticated，保險。
-- 畫面零變化：管理後台報表走 _ops_report_core 直接讀原表；上線日沒設，這四支目前都是空的。
-- ═══════════════════════════════════════════════════════════════════

create or replace view public.v_real_members as
 SELECT m.id, m.org_id, m.line_user_id, m.display_name, m.phone, m.home_store_id, m.tier, m.gender,
    m.birthday, m.occupation, m.district, m.acquisition_source, m.avatar_url, m.last_visit_at,
    m.visit_count, m.lifecycle, m.primary_staff_id, m.deleted_at, m.created_at, m.updated_at,
    m.created_by, m.updated_by, m.tier_override, m.last_app_active_at, m.rank, m.title,
    m.likes_count, m.is_test, m.about, m.sched, m.style, m.see_score, m.baby_tile,
    m.avatar_source, m.avatar_photo_path, m.avatar_photo_at, m.avatar_blocked,
    m.avatar_removed_count, m.inv_type, m.inv_carrier, m.inv_donate_code, m.inv_tax_id,
    m.inv_title, m.avatar_bear, m.phone_verified_at, m.rating, m.rating_games, m.hidden_at,
    m.best_rank_tier, m.legend_title,
    -- 🆕 11-02 會員來源
    m.acquisition_channel, m.acquisition_campaign, m.referred_by_staff_id,
    m.referred_by_member_id, m.acquisition_at, m.acquisition_backfilled
   FROM members m
     JOIN orgs o ON o.id = m.org_id
  WHERE m.is_test = false AND m.deleted_at IS NULL
    AND m.created_at >= COALESCE(o.live_from, 'infinity'::timestamp with time zone);

create or replace view public.v_real_orders as
 SELECT x.id, x.org_id, x.store_id, x.member_id, x.table_id, x.session_id, x.status, x.channel,
    x.total_points, x.deleted_at, x.created_at, x.updated_at, x.created_by, x.updated_by,
    x.order_no, x.subtotal, x.coupon_discount, x.tier_discount, x.payable, x.points_used,
    x.cash_due, x.tier_at_order, x.idempotency_key, x.wallet_txn_id, x.paid_at, x.entity_id,
    x.is_test, x.tier_discount_pct, x.txn_no, x.advisor_discount, x.advisor_team_id,
    -- 🆕 11-03 作廢稽核
    x.voided_at, x.voided_by_staff_id, x.void_source
   FROM orders x
     JOIN orgs o ON o.id = x.org_id
  WHERE NOT COALESCE(x.is_test, false) AND x.deleted_at IS NULL
    AND x.created_at >= COALESCE(o.live_from, 'infinity'::timestamp with time zone)
    AND NOT (EXISTS ( SELECT 1 FROM stores s WHERE s.id = x.store_id AND s.is_test))
    AND NOT (EXISTS ( SELECT 1 FROM members m WHERE m.id = x.member_id AND m.is_test));

create or replace view public.v_real_table_sessions as
 SELECT x.id, x.org_id, x.store_id, x.table_id, x.mode, x.stake_level_id, x.status,
    x.planned_minutes, x.started_at, x.ended_at, x.fee_points, x.promoted_by_staff_id,
    x.open_method, x.deleted_at, x.created_at, x.updated_at, x.created_by, x.updated_by,
    x.planned_rounds, x.opened_by_staff_id, x.activated_at, x.idempotency_key, x.is_test,
    x.game_type, x.flower, x.score_channel, x.closed_by_staff_id,
    -- 🆕 11-03 作廢稽核
    x.voided_at, x.voided_by_staff_id, x.void_source
   FROM table_sessions x
     JOIN orgs o ON o.id = x.org_id
  WHERE NOT COALESCE(x.is_test, false) AND x.deleted_at IS NULL
    AND x.created_at >= COALESCE(o.live_from, 'infinity'::timestamp with time zone)
    AND NOT (EXISTS ( SELECT 1 FROM stores s WHERE s.id = x.store_id AND s.is_test));

create or replace view public.v_real_topup_orders as
 SELECT x.id, x.org_id, x.store_id, x.member_id, x.topup_no, x.points, x.bonus_points,
    x.amount_twd, x.pay_method, x.status, x.external_ref, x.idempotency_key, x.invoice_no,
    x.invoice_at, x.wallet_txn_id, x.staff_id, x.note, x.created_at, x.created_by, x.entity_id,
    x.held_by_entity, x.session_id, x.cash_received, x.change_given, x.txn_no,
    -- 🆕 11-03 作廢稽核
    x.voided_at, x.voided_by_staff_id, x.void_source
   FROM topup_orders x
     JOIN orgs o ON o.id = x.org_id
  WHERE x.created_at >= COALESCE(o.live_from, 'infinity'::timestamp with time zone)
    AND NOT (EXISTS ( SELECT 1 FROM stores s WHERE s.id = x.store_id AND s.is_test))
    AND NOT (EXISTS ( SELECT 1 FROM members m WHERE m.id = x.member_id AND m.is_test));

-- 前端一律不給（檢視表繞過 RLS，anon 金鑰是公開的）
revoke all on public.v_real_members, public.v_real_orders,
              public.v_real_table_sessions, public.v_real_topup_orders
  from public, anon, authenticated;

-- ═══ 驗證（單一 SELECT，不 raise）═══
with v(v, t) as (values ('v_real_members','members'), ('v_real_orders','orders'),
                        ('v_real_table_sessions','table_sessions'), ('v_real_topup_orders','topup_orders')),
miss as (
  select v.v, count(*) n from v
  join information_schema.columns c on c.table_schema='public' and c.table_name=v.t
  where not exists (select 1 from information_schema.columns x
                     where x.table_schema='public' and x.table_name=v.v and x.column_name=c.column_name)
  group by v.v),
chk as (
  select v.v,
    coalesce((select n from miss where miss.v=v.v), 0) as 還缺幾欄,
    has_table_privilege('anon',          ('public.'||v.v)::regclass, 'select') as anon讀得到,
    has_table_privilege('authenticated', ('public.'||v.v)::regclass, 'select') as 登入者讀得到,
    pg_get_viewdef(('public.'||v.v)::regclass) like '%live_from%' as 上線日篩選還在
  from v)
select string_agg(
  case when 還缺幾欄 = 0 and not anon讀得到 and not 登入者讀得到 and 上線日篩選還在
       then '✅ ' || v
       else '🔴 ' || v || '（缺 ' || 還缺幾欄 || ' 欄'
            || case when anon讀得到 or 登入者讀得到 then '・前端讀得到' else '' end
            || case when not 上線日篩選還在 then '・上線日篩選不見了' else '' end || '）'
  end, E'\n' order by v) as "驗證"
from chk;
