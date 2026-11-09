/* ============================================================
   POS 會員查詢加一個指數：這位會員平均打 3 將要多久（2026-11-09 使用者）

   算法：這位會員打完的每一將（session_rounds.started_at → finished_at）平均分鐘 × 3
     · 用「每一將平均 × 3」而不是「只算約 3 將的場次」：1 將、2 將的場次也能算進來，樣本多
       （查過：約 3 將打滿的 72 場，實際從第 1 將開始到第 3 將結束中位數 206 分，純打牌 197 分，
         將與將之間合計只有 7.5 分 ⇒ 兩種算法差不多）
     · 只算 10～120 分鐘的將：超過 2 小時的是忘了結束（線上最長一將 6796 分），不到 10 分的不合理
     · 不算好友練習賽（在家用手機打，不是店裡的節奏）、不算作廢的場次
     · 會員換人上桌時座位那一列換成接手的人 ⇒ 那一場前面幾將會算到接手的人頭上（少見，接受）
   回傳 pace：{ rounds 幾將, per_round_min 每將平均分鐘, three_min 3 將合計分鐘 }；一將都沒有就是 null
   ⚠ 畫面上至少 3 將才顯示（POS 決定），這裡照實回

   改法：CREATE OR REPLACE（簽名不變 ⇒ 授權不會掉），函式本體照線上版（pg_get_functiondef 撈的），只多 pace 一個鍵
   ============================================================ */

CREATE OR REPLACE FUNCTION public.pos_member_detail_tx(p_org_id uuid, p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      'pace', (
        select case when count(*) = 0 then null else jsonb_build_object(
                 'rounds', count(*),
                 'per_round_min', round(avg(x.mins))::int,
                 'three_min', round(avg(x.mins) * 3)::int) end
        from (select extract(epoch from sr.finished_at - sr.started_at) / 60 as mins
                from session_players sp
                join table_sessions ts on ts.id = sp.session_id
                join session_rounds sr on sr.session_id = sp.session_id
               where sp.member_id = m.id
                 and ts.org_id = p_org_id
                 and ts.mode <> 'friendly'
                 and ts.status <> 'voided'
                 and ts.deleted_at is null
                 and sr.status = 'finished'
                 and sr.started_at is not null and sr.finished_at is not null) x
        where x.mins between 10 and 120),

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

      'coupons', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', mc.id, 'name', c.name,
          'applies_to', c.applies_to, 'scope_label', public._coupon_scope_label(c.id),
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

/* ── 驗證（單一 SELECT；不用 raise）──────────────────────────── */
with top as (   -- 正對照：打最多將的那位，應該有 pace
  select sp.member_id, ts.org_id, count(*) n
    from session_players sp
    join table_sessions ts on ts.id = sp.session_id
    join session_rounds sr on sr.session_id = sp.session_id and sr.status = 'finished'
   where ts.mode <> 'friendly'
   group by 1, 2 order by 3 desc limit 1),
none as (       -- 負對照：一將都沒打過的會員，pace 應該是 null
  select m.id member_id, m.org_id from members m
   where m.deleted_at is null
     and not exists (select 1 from session_players sp where sp.member_id = m.id)
   limit 1),
r as (select public.pos_member_detail_tx(t.org_id, t.member_id) d from top t),
z as (select public.pos_member_detail_tx(n.org_id, n.member_id) d from none n)
select
  case when (select count(*) from pg_proc where proname = 'pos_member_detail_tx') = 1 then '✅' else '🔴' end || ' ① 只有一個版本' || E'\n' ||
  case when has_function_privilege('authenticated', 'public.pos_member_detail_tx(uuid,uuid)', 'execute') then '✅' else '🔴' end || ' ② 店員（authenticated）還叫得動' || E'\n' ||
  coalesce((select case when (d -> 'pace' ->> 'three_min')::int between 60 and 360 then '✅' else '🔴' end
                   || ' ③ 打最多將的那位：' || (d -> 'pace' ->> 'rounds') || ' 將，每將 ' || (d -> 'pace' ->> 'per_round_min')
                   || ' 分，3 將 ' || (d -> 'pace' ->> 'three_min') || ' 分' from r), '🔴 ③ 打最多將的那位沒有 pace') || E'\n' ||
  coalesce((select case when d ? 'pace' and d -> 'pace' = 'null'::jsonb then '✅ ④ 沒打過的會員 pace 是 null' else '🔴 ④ 沒打過的會員 pace 不是 null' end from z), '⚪ ④ 找不到沒打過的會員，這一格測不了') || E'\n' ||
  coalesce((select case when d ? 'top_items' and d ? 'coupons' and d ? 'interactions' and d ? 'lifetime_spend' then '✅' else '🔴' end
                   || ' ⑤ 原本的鍵都還在' from r), '🔴 ⑤ 沒有樣本') as "驗證";
