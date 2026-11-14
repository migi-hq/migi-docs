/* ============================================================
   收掉優惠券的舊欄位 coupons.applies_to（待辦 0.8 的最後一步：expand → migrate → contract）
   2026-11-14 · MIGI 咪吉麻將
   使用者：「發現一支名為『applies_to 凍結』的觸發器，這個問題解決了嗎」

   ── 來龍去脈 ────────────────────────────────────────────
   2026-10-01 適用範圍改成規則表 coupon_scopes，計價核心 _cart_pricing 從那天起只看規則表。
   舊欄位 applies_to 當時沒刪，而是加了觸發器 trg_coupons_applies_to_frozen「凍結」它：
   寫入新值就報錯 —— 不然同一張券會有兩個答案（欄位說限檯費、規則表說限餐飲），而且不報錯。
   那支觸發器是**刻意的保護，不是問題**；它等的是「沒有人再讀舊欄位」那一天。

   ── 2026-11-14 查證：那一天到了 ─────────────────────────
   · 三個前端 repo（migi-web／migi-pos／migi-admin）的 src 裡 `applies_to` 出現 0 次
   · 後端讀它的只剩 pos_member_detail_tx（把它跟 scope_label 一起回傳給 POS，而 POS 不讀它）與那支觸發器
   · 沒有任何檢視表依賴這一欄

   ⇒ 這份做三件事：pos_member_detail_tx 不再回傳 applies_to（其餘照抄線上版，簽名不變 ⇒ 授權不會掉）、
     刪觸發器與它的函式、刪欄位（它的 CHECK 約束跟著欄位一起消失）。
   ============================================================ */

-- ① POS 會員查詢：拿掉 applies_to 那一個鍵（其餘逐字照抄 2026-11-14 撈的線上版）
create or replace function public.pos_member_detail_tx(p_org_id uuid, p_member_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare
  v_p jsonb;      -- ★ 2026-09-08：等級那一段整段搬到 member_tier_progress_tx
begin
  -- 【身分 2026-09-29】從 API 進來的只有店員能叫（排程沒有 API 身分，照常）
  perform public._api_staff_only();
  if not exists (select 1 from members
                  where id = p_member_id and org_id = p_org_id and deleted_at is null) then
    return null;
  end if;

  v_p := public.member_tier_progress_tx(p_member_id, p_org_id);

  return (
    select jsonb_build_object(
      'id', m.id, 'nickname', m.display_name, 'phone', m.phone,
      /* ⚠ 這些鍵的名字**一個都不可以改** —— `MemberPage.jsx` 依賴它們
         （進度條算式用 lifetime_spend / tier_threshold / next_tier_threshold）。 */
      'tier', v_p ->> 'tier',
      'tier_discount_pct', (v_p ->> 'tier_discount_pct')::int,
      'rank', m.rank, 'title', m.title,
      'avatar_url', m.avatar_url, 'avatar_bear', m.avatar_bear, 'avatar_source', m.avatar_source, 'avatar_photo_path', m.avatar_photo_path,
      'balance', coalesce(w.balance, 0),
      'birthday', m.birthday,
      'lifetime_spend', (v_p ->> 'lifetime_spend')::bigint,
      'tier_threshold', (v_p ->> 'tier_threshold')::bigint,
      'tier_by_override', (v_p ->> 'tier_by_override')::boolean,
      'tier_earned', v_p ->> 'tier_earned',
      'next_tier', v_p ->> 'next_tier',
      'next_tier_label', v_p ->> 'next_tier_label',
      'next_tier_threshold', (v_p ->> 'next_tier_threshold')::bigint,
      'next_tier_gap', (v_p ->> 'next_tier_gap')::bigint,

      /* ★ 常加購品項（2026-08-25）。
         🔴 **排除 venue_fee** —— 檯費是每個人每次都買的，
           不排除的話這一格永遠只會顯示「場地費」，等於沒有資訊。
           排掉之後它回答的是「這位客人愛吃什麼」，店員可以據此推薦。
         ⚠ 用 name 分組不用 product_id：order_items.name 是**下單當時的快照**，
           改名過的商品用 product_id 會併在一起、用 name 會分開。
           這裡要的是「店員唸得出來的東西」，快照才是對的。
         只取前 3 名：櫃檯要的是一句話，不是排行榜。 */
      'top_items', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'name', t.nm, 'qty', t.q, 'revenue_type', t.rt)
                 order by t.q desc), '[]'::jsonb)
        from (select oi.name as nm, sum(oi.qty)::int as q,
                     min(oi.revenue_type) as rt
                from order_items oi
                join orders o2 on o2.id = oi.order_id
               where o2.member_id = m.id
                 and o2.org_id = p_org_id
                 and o2.status = 'paid'
                 and oi.revenue_type <> 'venue_fee'
               group by oi.name
               order by 2 desc
               limit 3) t),

      /* ★ 平均 3 將打多久（2026-11-09）：打完的每一將平均分鐘 × 3；只算 10～120 分的將、不算好友練習賽與作廢的場次 */
      'pace', (select case when r.rounds = 0 then null else jsonb_build_object('rounds', r.rounds, 'per_round_min', r.avg_min, 'three_min', r.avg_min * 3) end
                from public._member_round_minutes(p_org_id, m.id) r),   -- 2026-11-10 改叫共用算法

      /* ★ 互動紀錄（2026-08-25）。
         回傳**全部類型**不只 note —— 藍圖要求店員看得到系統已發過什麼，
         只回 note 的話 MA 上線後會重複關懷同一個人。 */
      'interactions', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'id', i.id, 'channel', i.channel, 'kind', i.kind,
                 'note', i.note, 'created_at', i.created_at)
                 order by i.created_at desc), '[]'::jsonb)
        from (select * from member_interactions
               where member_id = m.id and org_id = p_org_id
               order by created_at desc limit 5) i),

      /* 適用範圍只看規則表（scope_label）；舊的單一欄位 2026-11-14 刪掉了 */
      'coupons', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', mc.id, 'name', c.name,
          'scope_label', public._coupon_scope_label(c.id),
          'discount_type', c.discount_type,
          'discount_value', c.discount_value,
          'min_spend', c.min_spend, 'max_discount', c.max_discount,
          'expires_at', mc.expires_at
        ) order by mc.expires_at nulls last), '[]'::jsonb)
        from member_coupons mc
        join coupons c on c.id = mc.coupon_id
        where mc.member_id = m.id
          and mc.used_at is null and coalesce(mc.status,'') <> 'used'
          and (mc.expires_at is null or mc.expires_at > now()))
    )
    from members m
    left join wallets w on w.member_id = m.id
    where m.id = p_member_id and m.org_id = p_org_id and m.deleted_at is null
  );
end $function$;

-- ② 凍結觸發器與它的函式（它守的那一欄要刪了）
drop trigger if exists trg_coupons_applies_to_frozen on public.coupons;
drop function if exists public.trg_coupons_applies_to_frozen();

-- ③ 舊欄位（coupons_applies_to_check 跟著一起消失）
alter table public.coupons drop column if exists applies_to;

-- ── 驗證（單一 SELECT；不用 raise）──
select x.項目, x.結果 from (
  select 1 as n, '① 舊欄位刪掉了' as 項目,
         case when not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'coupons' and column_name = 'applies_to')
              then '✅' else '🔴 還在' end as 結果
  union all
  select 2, '② 凍結觸發器與函式都沒了',
         case when not exists (select 1 from pg_trigger where tgname = 'trg_coupons_applies_to_frozen')
               and not exists (select 1 from pg_proc where proname = 'trg_coupons_applies_to_frozen')
              then '✅' else '🔴 還在' end
  union all
  select 3, '③ 全庫沒有函式再寫到這個欄位（逐行掃，註解不算）',
         coalesce((select '🔴 ' || string_agg(p.proname, '、') from pg_proc p
                    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
                      and exists (select 1 from regexp_split_to_table(pg_get_functiondef(p.oid), E'\n') l
                                   where l ~ 'applies_to' and l !~ '^\s*(--|/\*|\*)')), '✅ 0 支')
  union all
  select 4, '④ POS 會員查詢還是店員叫得動（授權沒掉）',
         case when has_function_privilege('authenticated', 'public.pos_member_detail_tx(uuid,uuid)'::regprocedure, 'EXECUTE')
              then '✅' else '🔴 POS 會員查詢會壞' end
  union all
  select 5, '⑤ 既有 5 張券都還在、規則表沒動',
         (select case when count(*) = 5 then '✅ 券 5 張、規則 ' || (select count(*) from coupon_scopes) || ' 條' else '⚠ 券 ' || count(*) || ' 張' end from coupons)
) x order by x.n;
