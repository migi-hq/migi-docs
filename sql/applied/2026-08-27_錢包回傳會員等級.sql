/* ============================================================
   get_wallet_tx 多回一個 tier —— 讓會員 App 別再寫死「焦糖布丁」
   2026-08-27

   ── 問題（待辦 31）──────────────────────────────────
   `migi-web/src/pages/wallet.jsx` 錢包 hero 的
   「會員等級: 焦糖布丁」是**寫死的字串**，
   而同一個回傳裡的 `balance` 是真的。
   → **任何不是焦糖布丁的會員看到的都是錯的。**
   ⚠ 而且測試02 剛好就是焦糖布丁 —— 這就是為什麼一直沒人發現。

   🔴 這是待辦 0（「建了主檔沒人讀」）的 App 版：
     POS 已經接上 `list_member_tiers_tx`，會員 App 還沒。

   ── 為什麼是 CREATE OR REPLACE 而不用 DROP ──────────
   ✅ **簽名完全不變**，只是在 `jsonb_build_object` 多一個 key。
     所以不需要 `DROP FUNCTION`，也**不會丟掉 GRANT**（硬規則 2）。
   ⚠ 前端讀不到那個 key 時會退回 fallback，所以
     **先跑這支、後推前端** 是安全的順序；反過來也只是暫時顯示不出等級。

   ── 有效等級的算法（2026-08-27 查證，不是推測）────────
   `checkout_tx` 與 `pos_member_detail_tx` **兩支都是**：
       select coalesce(tier_override, tier) ...
   🔴 `members` 有兩個等級欄位，允許值一模一樣
     （bubble_tea / caramel_pudding / tiramisu / chef_special）。
     只讀 `tier` 會讓「被店長手動覆寫過的會員」看到錯的等級 ——
     那正是這支 SQL 要修的同一種 bug。
   → **判準是「已經在收錢的那支怎麼算」**：`checkout_tx` 用哪一欄
     決定折扣，哪一欄就是有效等級。

   ── 只加 tier，不加 label 也不加折扣率 ──────────────
   · **label 一律從 `list_member_tiers_tx` 主檔拿**（POS 就是這樣）。
     這裡回中文名的話，總部改名要改兩個地方，而「一致」得靠人維護。
   · 折扣率同理，而且 App 現在沒有任何地方要顯示它。
   ⚠ 多回一個沒人讀的欄位，是白白擴大暴露面
     ——同 2026-08-26 `get_my_profile_tx` 只補 birthday 的理由。
   ============================================================ */

create or replace function public.get_wallet_tx(p_member_id uuid, p_txn_limit integer default 20)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_balance bigint;
  v_name    text;
  v_tier    text;          -- ★ 新增：有效等級（coalesce(tier_override, tier)）
  v_txns    jsonb;
  v_coupons jsonb;
begin
  if p_member_id is null then
    raise exception 'member_id required';
  end if;

  /* ★ 改動只有這一段：原本只取 display_name，順便把等級一起取出來。
     不另外查一次 members —— 同一列的資料沒有理由查兩趟。 */
  select display_name, coalesce(tier_override, tier)
    into v_name, v_tier
    from members
   where id = p_member_id and deleted_at is null;

  if v_name is null then
    raise exception 'member not found';
  end if;
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
    'tier',         v_tier,      -- ★ 新增。中文名由前端查 list_member_tiers_tx 主檔
    'balance',      v_balance,
    'txns',         v_txns,
    'coupons',      v_coupons
  );
end;
$function$;

/* ============================================================
   驗證（單一 SELECT）

   ⚠ 硬規則 7：「SQL 跑完沒報錯」不等於「函式能用」——
     `CREATE FUNCTION` 不檢查函式體裡的欄位存不存在。
     所以底下 ③ ④ 是**真的呼叫它**。

   ⚠ ③ 逐一測**四個會員**而不是挑一個 ——
     2026-08-25 升等進度那次就是只驗一個人而漏掉別的等級。
     這裡尤其重要：測試02 剛好是焦糖布丁，只驗他的話
     **跟寫死的字串長得一模一樣，什麼都驗不到**。

   ── 該看到什麼 ──────────────────────────────────────
   ① 1（沒有建出多載版本）
   ② 六個 key 都在，且含 tier（舊的一個都不能少）
   ③ 四列，每一列的「回傳」與「應為」相同
   ④ ✅ 全部一致
   ============================================================ */
select 序, 項目, 內容 from (

  select 1 as 序, '① get_wallet_tx 版本數' as 項目,
         count(*)::text as 內容
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prokind = 'f' and p.proname = 'get_wallet_tx'

  union all
  /* ② 回傳的 key 清單 —— 確認舊的都還在，不是「加了新的、弄丟舊的」。 */
  select 2, '② 回傳的 key',
         (select string_agg(k, '　' order by k)
            from members m,
                 lateral jsonb_object_keys(public.get_wallet_tx(m.id)) k
           where m.deleted_at is null
           limit 6)

  union all
  /* ③ 真的呼叫，逐人比對「函式回的」與「照 checkout_tx 算法應該是的」。 */
  select 3, '③ 逐人實測',
         coalesce(string_agg(
           m.display_name || '：回傳=' ||
           coalesce(public.get_wallet_tx(m.id) ->> 'tier', '🔴 null') ||
           '　應為=' || coalesce(coalesce(m.tier_override, m.tier), '（null）'),
           E'\n' order by m.display_name), '（沒有會員）')
    from members m
   where m.deleted_at is null

  union all
  /* ④ 一句話的結論。⚠ 不是「有沒有 tier 這個字」——
        那種掃字串的驗證會被註解觸發（硬規則 3.5）。
        這裡比的是**實際回傳值**與**應有值**。 */
  select 4, '④ 結論',
         case when exists (
                select 1 from members m
                 where m.deleted_at is null
                   and coalesce(public.get_wallet_tx(m.id) ->> 'tier', '') is distinct from
                       coalesce(coalesce(m.tier_override, m.tier), '')
              )
              then '🔴 有人對不上，不要推前端'
              else '✅ 全部一致，可以推前端了' end

) x order by 序, 項目;
