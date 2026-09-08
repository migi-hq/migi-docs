/* ============================================================
   升等進度抽成一支共用函式，會員 App 也看得到（待辦 1 · 2026-09-08）

   ── 🔴 現況是反的 ────────────────────────────────────
   ```
   店員 POS   ✅ 進度條、「距 提拉米蘇 還差 $X」、累積消費   （2026-08-25 就有了）
   客人 App   🔴 什麼都沒有
   ```
   **對 loyalty 來說這剛好反了** —— 該被進度條推動的是客人。
   星巴克整個產品就是那個星星進度條；一個看不見進度的等級制度，
   對客人來說基本上不存在。

   而那個數字**後端早就在算了**（`pos_member_detail_tx` 與
   `recalc_member_tier_tx` 各算一次），只是從來沒有回給客人。

   ── 🔴 為什麼是「抽出來」不是「抄過去」──────────────
   抄一份到 `get_wallet_tx` 的話，「還差多少」就有兩份定義。
   症狀是**客人看到「還差 $2,000」而店員看到「還差 $1,800」**
   —— 而它不會報錯，只會在櫃檯變成一次爭執。
   📌 同 `season_rank_rows_tx` 那次（成績頁的即時排名與賽季結算的
     名次快照都叫同一支）—— 兩份分岔的症狀是「他看到自己第 3 名，
     歷史卻記成第 5 名」。

   ⇒ ① 新增 `member_tier_progress_tx()`（唯一定義）
     ② `pos_member_detail_tx` 改呼叫它 —— **回傳的鍵一個都不變**
        （POS 前端 `MemberPage.jsx` 依賴那些名字）
     ③ `get_wallet_tx` 加上同一批鍵

   ── ⚠ 邏輯照搬，一行都不改（含那個 2026-08-25 的修正）────
   ```sql
   v_base := greatest(coalesce(本級門檻, 最大值), 累積額)
   ```
   註解寫著：「否則等級被人工設高的人會看到一個比自己低的下一級」。
   🔴 那是**已經踩過並修好的坑**，抽出來的時候最容易弄丟。

   ── 📌 順帶記一個今天查到的細節 ────────────────────────
   `v_earned` 用 `order by threshold_amount desc`，
   而 `recalc_member_tier_tx` 用 `order by sort desc` ——
   **兩個不同的排序鍵**。今天早上加的那道
   「門檻必須隨 sort 遞增」（`admin_update_member_tier_tx`）
   剛好讓它們永遠等價。那道擋牆因此有了第二個理由。
   ============================================================ */

-- ══════════════════════════════════════════════════════
-- ① 唯一定義
-- ══════════════════════════════════════════════════════
create or replace function public.member_tier_progress_tx(
  p_member_id uuid,
  p_org_id    uuid default null      -- null = 從會員身上查
) returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $fn$
declare
  v_org      uuid;
  v_tier     text;
  v_pct      int;
  v_override text;
  v_spend    bigint;
  v_earned   text;
  v_curthr   bigint;
  v_base     bigint;
  v_next     record;
begin
  select coalesce(p_org_id, m.org_id), m.tier_override, coalesce(m.tier_override, m.tier)
    into v_org, v_override, v_tier
    from members m
   where m.id = p_member_id and m.deleted_at is null
     and (p_org_id is null or m.org_id = p_org_id);

  if v_org is null then return null; end if;   -- 呼叫端自己決定怎麼處理

  select coalesce(t.discount_pct, 0), t.threshold_amount
    into v_pct, v_curthr
    from member_tiers t where t.code = v_tier and t.is_active;
  v_pct := coalesce(v_pct, 0);

  select coalesce(sum(o.payable), 0) into v_spend
    from orders o
   where o.member_id = p_member_id and o.org_id = v_org and o.status = 'paid';

  /* 「憑消費賺到的」等級 —— 與 `tier_override` 分開，
     這樣畫面可以說「你被指定為主廚特調」而不是假裝他消費達標。 */
  select t.code into v_earned
    from member_tiers t
   where t.is_active and t.threshold_amount is not null
     and t.threshold_amount <= v_spend
   order by t.threshold_amount desc
   limit 1;

  /* 🔴 **這一行是 2026-08-25 修過的坑，抽出來時最容易弄丟**：
     基準取「本級門檻」與「累積額」的大者，否則等級被人工設高的人
     會看到一個比自己低的「下一級」。
     ⚠ `v_curthr is null` ＝ 邀請制（主廚特調）⇒ 基準是最大值 ⇒ 沒有下一級。 */
  v_base := greatest(coalesce(v_curthr, 9223372036854775807::bigint), v_spend);

  select t.code, t.label, t.threshold_amount into v_next
    from member_tiers t
   where t.is_active and t.threshold_amount is not null
     and t.threshold_amount > v_base
   order by t.threshold_amount asc
   limit 1;

  return jsonb_build_object(
    'tier',                v_tier,
    'tier_discount_pct',   v_pct,
    'tier_threshold',      v_curthr,
    'tier_by_override',    (v_override is not null),
    'tier_earned',         v_earned,
    'lifetime_spend',      v_spend,
    'next_tier',           v_next.code,
    'next_tier_label',     v_next.label,
    'next_tier_threshold', v_next.threshold_amount,
    'next_tier_gap',       case when v_next.threshold_amount is null then null
                                else v_next.threshold_amount - v_spend end
  );
end $fn$;

-- ══════════════════════════════════════════════════════
-- ② POS：改呼叫共用函式，**回傳的鍵一個都不變**
-- ══════════════════════════════════════════════════════
create or replace function public.pos_member_detail_tx(p_org_id uuid, p_member_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_p jsonb;      -- ★ 2026-09-08：等級那一段整段搬到 member_tier_progress_tx
begin
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
          'applies_to', c.applies_to,
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

-- ══════════════════════════════════════════════════════
-- ③ 會員 App：錢包多回升等進度
-- ══════════════════════════════════════════════════════
create or replace function public.get_wallet_tx(p_member_id uuid, p_txn_limit integer default 20)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_balance bigint;
  v_name    text;
  v_p       jsonb;      -- ★ 2026-09-08：等級與升等進度都從共用函式來
  v_txns    jsonb;
  v_coupons jsonb;
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
  if p_member_id is null then
    raise exception 'member_id required';
  end if;

  select display_name into v_name
    from members where id = p_member_id and deleted_at is null;
  if v_name is null then
    raise exception 'member not found';
  end if;

  /* ★ 2026-09-08：原本這裡自己取 `coalesce(tier_override, tier)`。
     改成呼叫共用函式，順便把**升等進度**一起帶回來 ——
     🔴 而重點不是「多幾個欄位」，是**客人與店員從此看到同一個數字**。
       各算一次的症狀是「客人看到還差 $2,000、店員看到還差 $1,800」，
       而它不會報錯，只會在櫃檯變成一次爭執。 */
  v_p := public.member_tier_progress_tx(p_member_id);

  select coalesce(balance, 0) into v_balance from wallets where member_id = p_member_id;
  v_balance := coalesce(v_balance, 0);

  -- 近期消費/儲值紀錄
  select coalesce(jsonb_agg(t order by t.created_at desc), '[]'::jsonb) into v_txns
  from (
    select
      wt.id,
      wt.amount,
      wt.type::text as type,
      case wt.type
        when 'topup'     then '儲值'
        when 'table_fee' then '檯費'
        when 'fnb'       then '餐飲'
        when 'merch'     then '商品'
        when 'refund'    then '退款'
        when 'adjust'    then '贈點/調整'
        when 'event_fee' then '活動費'
        when 'reversal'  then '沖正'
        else wt.type::text
      end as label,
      wt.note,
      wt.created_at
    from wallet_txns wt
    where wt.member_id = p_member_id
      and wt.status = 'completed'
    order by wt.created_at desc
    limit greatest(1, least(p_txn_limit, 100))
  ) t;

  -- 持有中的優惠券（active）— 把 granted_at 一起選進子查詢再排序
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', c.id,
             'name', c.name,
             'kind', c.kind,
             'discount_type', c.discount_type,
             'discount_value', c.discount_value,
             'expires_at', c.expires_at
           ) order by c.granted_at desc
         ), '[]'::jsonb) into v_coupons
  from (
    select
      mc.id,
      co.name,
      co.kind::text as kind,
      co.discount_type::text as discount_type,
      co.discount_value,
      mc.expires_at,
      mc.granted_at
    from member_coupons mc
    join coupons co on co.id = mc.coupon_id
    where mc.member_id = p_member_id
      and mc.status = 'active'
  ) c;

  return jsonb_build_object(
    'member_id',    p_member_id,
    'display_name', v_name,
    'tier',         v_p ->> 'tier',   -- 中文名由前端查 list_member_tiers_tx 主檔
    'balance',      v_balance,
    'txns',         v_txns,
    'coupons',      v_coupons,
    /* ★ 升等進度（2026-09-08）。與 POS 完全同一份定義。
       ⚠ `next_tier` 是 null 有兩種意思，前端要分開講：
         · 已經是最高的自動階   → 「已達最高等級」
         · 目前是邀請制（主廚特調）→ 沒有「下一階」這件事 */
    'tier_discount_pct',   (v_p ->> 'tier_discount_pct')::int,
    'tier_threshold',      (v_p ->> 'tier_threshold')::bigint,
    'tier_by_override',    (v_p ->> 'tier_by_override')::boolean,
    'lifetime_spend',      (v_p ->> 'lifetime_spend')::bigint,
    'next_tier',           v_p ->> 'next_tier',
    'next_tier_label',     v_p ->> 'next_tier_label',
    'next_tier_threshold', (v_p ->> 'next_tier_threshold')::bigint,
    'next_tier_gap',       (v_p ->> 'next_tier_gap')::bigint
  );
end;
$function$;

/* ── 授權 ────────────────────────────────────────────────
   ⚠ `member_tier_progress_tx` 是**內部用的**（只被上面兩支呼叫）
     ⇒ anon 與 PUBLIC 都收掉（硬規則 2.6b 兩個方向）。
   ⚠ 上面兩支是 `CREATE OR REPLACE`、簽名沒變 ⇒ **GRANT 沒有掉**，不用補。 */
revoke execute on function public.member_tier_progress_tx(uuid, uuid) from public;
revoke execute on function public.member_tier_progress_tx(uuid, uuid) from anon, authenticated;
grant  execute on function public.member_tier_progress_tx(uuid, uuid) to service_role;


/* ============================================================
   驗證（單一 SELECT）
   🎯 這一份的核心風險是**重構把行為改掉了**，所以驗的重點是
     「POS 那支的每一個鍵都還在、而且值一樣」。
   ⚠ 硬規則 3.55：正負對照都要有。
   ============================================================ */
do $$
declare
  v_mid uuid; v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_pos jsonb; v_wal jsonb; v_prog jsonb; v_msg text := ''; v_miss text;
begin
  /* 取樣當場查：挑**有訂單**的會員（沒有訂單的話累積是 0，驗不到東西）。 */
  select o.member_id into v_mid
    from orders o where o.status = 'paid' and o.member_id is not null
   group by o.member_id order by sum(o.payable) desc limit 1;
  if v_mid is null then
    perform set_config('migi.p', '🔴 找不到有付款訂單的會員 —— 下面全部沒跑', true); return;
  end if;

  v_pos  := public.pos_member_detail_tx(v_org, v_mid);
  v_wal  := public.get_wallet_tx(v_mid, 5);
  v_prog := public.member_tier_progress_tx(v_mid);

  -- ① POS 的鍵一個都不可以少（前端 MemberPage.jsx 依賴它們）
  select string_agg(k, ', ') into v_miss
    from unnest(array['id','nickname','phone','tier','tier_discount_pct','rank','title',
                      'avatar_url','avatar_bear','avatar_source','avatar_photo_path',
                      'balance','birthday','lifetime_spend','tier_threshold',
                      'tier_by_override','tier_earned','next_tier','next_tier_label',
                      'next_tier_threshold','next_tier_gap','top_items','interactions','coupons']) k
   where not jsonb_exists(v_pos, k);
  v_msg := case when v_miss is null then '✅ ① POS 的 24 個鍵一個都沒少'
                else '🔴 ① POS 少了：' || v_miss end;

  -- ② 🔴 兩邊的「還差多少」必須一模一樣（這一份存在的主因）
  v_msg := v_msg || E'\n' || case
    when v_pos ->> 'lifetime_spend' is not distinct from v_wal ->> 'lifetime_spend'
     and v_pos ->> 'next_tier_gap'  is not distinct from v_wal ->> 'next_tier_gap'
     and v_pos ->> 'next_tier'      is not distinct from v_wal ->> 'next_tier'
    then '✅ ② 客人與店員看到同一個數字（累積 ' || coalesce(v_pos ->> 'lifetime_spend','?')
         || '、還差 ' || coalesce(v_pos ->> 'next_tier_gap','（已最高）') || '）'
    else '🔴 ② 兩邊不一致：POS ' || coalesce(v_pos ->> 'next_tier_gap','null')
         || ' vs App ' || coalesce(v_wal ->> 'next_tier_gap','null') end;

  -- ③ 正對照：值不是空的（少了這格，兩邊都回 null 也會讓 ② 變綠）
  v_msg := v_msg || E'\n' || case
    when (v_wal ->> 'lifetime_spend')::bigint > 0
    then '✅ ③ 累積消費有值（' || (v_wal ->> 'lifetime_spend') || '）'
    else '🔴 ③ 累積是 0 —— ② 的一致可能只是「兩邊都空」' end;

  -- ④ 錢包原本的鍵沒有掉
  select string_agg(k, ', ') into v_miss
    from unnest(array['member_id','display_name','tier','balance','txns','coupons']) k
   where not jsonb_exists(v_wal, k);
  v_msg := v_msg || E'\n' || case when v_miss is null
    then '✅ ④ 錢包原本的 6 個鍵都在' else '🔴 ④ 錢包少了：' || v_miss end;

  -- ⑤ 🔴 那個 2026-08-25 的坑：被人工設高的人不可以看到比自己低的「下一級」
  --    用主廚特調（邀請制、門檻 null）當樣本 —— 它的 next 必須是 null
  v_msg := v_msg || E'\n' || (
    select case when (public.member_tier_progress_tx(m.id) ->> 'next_tier') is null
      then '✅ ⑤ 邀請制／最高階沒有「下一級」'
      else '🔴 ⑤ 竟然有下一級：' || (public.member_tier_progress_tx(m.id) ->> 'next_tier') end
    from members m
    where coalesce(m.tier_override, m.tier) = (
            select code from member_tiers where threshold_amount is null and is_active limit 1)
      and m.deleted_at is null limit 1);

  -- ⑥ 負對照：不存在的會員回 null（不是回一包空殼）
  v_msg := v_msg || E'\n' || case
    when public.member_tier_progress_tx(gen_random_uuid()) is null
    then '✅ ⑥ 查不到的人回 null' else '🔴 ⑥ 回了東西' end;

  perform set_config('migi.p', v_msg, true);
end $$;

select
  '① 三支：' || (select count(*)::text from pg_proc
     where pronamespace='public'::regnamespace
       and proname in ('member_tier_progress_tx','pos_member_detail_tx','get_wallet_tx'))
    || ' / 3'                                                                  as "①建立",
  (select 'progress〔anon=' ||
     case when exists (select 1 from aclexplode(p.proacl) a
            where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE')
          then '🔴有' else '✅無' end ||
     ' PUBLIC=' ||
     case when p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
            where a.grantee=0 and a.privilege_type='EXECUTE')
          then '🔴有' else '✅無' end || '〕'
     from pg_proc p where p.pronamespace='public'::regnamespace
       and p.proname='member_tier_progress_tx')                                as "②內部函式沒外露",
  /* ⚠ 正對照：這兩支是 CREATE OR REPLACE、簽名沒變 ⇒ GRANT 不該掉。
     真的掉了的話 POS 與 App 會 permission denied（不是擋住，是壞掉）。 */
  (select string_agg(p.proname || '=' ||
     case when exists (select 1 from aclexplode(p.proacl) a
            where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE')
          then '✅anon' else '🔴anon掉了' end, ' ')
     from pg_proc p where p.pronamespace='public'::regnamespace
       and p.proname in ('pos_member_detail_tx','get_wallet_tx'))              as "③既有授權還在",
  coalesce(nullif(current_setting('migi.p', true), ''), '🔴 沒有測試訊息')      as "④～⑨行為";
