/* ============================================================
   pos_member_detail_tx 加：累積消費 + 升等進度 + 生日
   2026-08-25

   ── 為什麼是這一項優先 ──────────────────────────────
   member_tiers.threshold_amount 2026-08-17 就建好了，**至今沒有任何人讀**
   （CLAUDE.md 待辦 0 的「建了主檔沒人讀」）。
   缺了這一格，等級制度對客人與店員都不存在 ——
   客人問「我怎麼升級」，店員答不出來，那個制度就只是四個名字。

   ── 為什麼不開新 RPC ────────────────────────────────
   這支已經回傳 tier / balance / coupons，多三個數字是同一次查詢。
   多開一支等於讓前端多打一次網路。
   ✅ **簽名不變**，所以用 CREATE OR REPLACE，不必 DROP ——
      也就不會踩到「DROP 丟掉 GRANT」（硬規則 2）。

   ── 累積消費的定義 ──────────────────────────────────
   `sum(orders.payable) where status = 'paid'`
   · **payable 是折後實付**，不是折前小計 —— 待辦 3 已拍板。
     用小計的話，發券等於送升等進度。
   · 只算 'paid'。查證：目前 paid 4 筆 / void 149 筆，沒有其他狀態。
   · **儲值不算**：它寫的是 topup_orders 不是 orders，天然被排除。
     儲值是預收款不是消費，客人儲 10000 不該直接升等。

   ── 🔴 tier_override 的人不能顯示進度 ────────────────
   截圖那位「提拉米蘇」累積不可能到 50,000 —— 他是 tier_override。
   對他顯示「還差 $41,580」是**誤導**：他的等級不是累積來的，
   而那個數字會讓店員以為他快掉級。
   → 回傳 tier_by_override，前端據此**整段不顯示進度**。

   ── ⚠ 這支**不會自動升等** ──────────────────────────
   members.tier 仍然是儲存值，這裡只是把「累積到多少」算給人看。
   自動升等要先回答一串問題（何時觸發？會不會降級？降級要不要通知？
   退款作廢要不要回沖？），那是另一批。
   → 所以會出現「累積已達門檻但 tier 還沒動」的情況，
     這支照實回報 tier_earned，讓前端看得出來，而不是假裝一致。
   ============================================================ */

create or replace function public.pos_member_detail_tx(p_org_id uuid, p_member_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_tier      text;
  v_pct       int;
  v_override  text;
  v_spend     bigint;
  v_earned    text;
  v_next      record;
begin
  select tier_override, coalesce(tier_override, tier)
    into v_override, v_tier
    from members
   where id = p_member_id and org_id = p_org_id and deleted_at is null;

  if v_tier is null and not exists (
       select 1 from members where id = p_member_id and org_id = p_org_id) then
    return null;
  end if;

  -- ★ 折抵幅度查 member_tiers，與 checkout_tx 同一個來源。
  --   原本這裡有一份跟 checkout_tx 一模一樣的 case，靠人維護「一致」——
  --   改一邊忘另一邊，畫面顯示與實收金額就會不同，而且不會報錯。
  select coalesce(t.discount_pct, 0) into v_pct
    from member_tiers t where t.code = v_tier and t.is_active;
  v_pct := coalesce(v_pct, 0);

  /* 累積消費：折後實付，只算已付款的訂單。
     ⚠ 這是即時算的，不存欄位（待辦 1 的 B 案）——
       存欄位會出現「欄位與訂單對不上」而且無從得知哪邊才對；
       退款、作廢、補開都要記得回沖，漏一次就永久偏差。 */
  select coalesce(sum(o.payable), 0) into v_spend
    from orders o
   where o.member_id = p_member_id
     and o.org_id = p_org_id
     and o.status = 'paid';

  /* 這個累積額「應該」是哪一級 —— 取門檻不超過累積額的最高一級。
     ⚠ 只看有門檻的（threshold_amount not null）：
       主廚特調是邀請制，不該被累積額掃到。 */
  select t.code into v_earned
    from member_tiers t
   where t.is_active and t.threshold_amount is not null
     and t.threshold_amount <= v_spend
   order by t.threshold_amount desc
   limit 1;

  /* 下一級：門檻**嚴格大於**累積額的最低一級。
     沒有下一級（已達最高的累積級距）時 v_next 為 null，前端不顯示進度。 */
  select t.code, t.label, t.threshold_amount into v_next
    from member_tiers t
   where t.is_active and t.threshold_amount is not null
     and t.threshold_amount > v_spend
   order by t.threshold_amount asc
   limit 1;

  return (
    select jsonb_build_object(
      'id', m.id, 'nickname', m.display_name, 'phone', m.phone,
      'tier', v_tier, 'tier_discount_pct', v_pct, 'rank', m.rank, 'title', m.title,
      'avatar_source', m.avatar_source, 'avatar_photo_path', m.avatar_photo_path,
      'balance', coalesce(w.balance, 0),
      -- 生日：members.birthday 早就存在（date）。生日招待是已承諾的權益，
      -- 而店員在這之前沒有任何管道知道今天是誰生日。
      'birthday', m.birthday,
      -- 累積消費與升等進度
      'lifetime_spend', v_spend,
      -- 🔴 等級是人工指定的話，進度整段沒有意義，前端據此不顯示
      'tier_by_override', (v_override is not null),
      -- 累積額「應該」是哪一級。與 tier 不同時代表尚未升等（本函式不自動升）
      'tier_earned', v_earned,
      'next_tier', v_next.code,
      'next_tier_label', v_next.label,
      'next_tier_threshold', v_next.threshold_amount,
      -- 還差多少。沒有下一級時為 null，不要回 0（0 看起來像「已達成」）
      'next_tier_gap', case when v_next.threshold_amount is null then null
                            else v_next.threshold_amount - v_spend end,
      'coupons', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', mc.id, 'name', c.name,
          'applies_to', c.applies_to,        -- table_fee / fnb / null(全品項)
          'discount_type', c.discount_type,  -- free / percent / fixed
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


/* ============================================================
   驗證段（單一 SELECT）
   ⚠ 硬規則 7：函式寫完必須**實際執行並看到回傳**才算完成。
     所以這裡真的呼叫一次，拿真實會員的資料印出來 ——
     「CREATE FUNCTION 沒報錯」不等於「函式能用」。
   ============================================================ */

with probe as (
  /* 挑一位真的有已付款訂單的會員來測，沒有的話退而求其次挑任何一位。
     用測試資料也沒關係 —— 這裡驗的是函式算不算得出來，不是金額對不對。 */
  select m.id, m.org_id
    from members m
   where m.deleted_at is null
   order by (select count(*) from orders o
              where o.member_id = m.id and o.status = 'paid') desc,
            m.created_at
   limit 1
),
r as (
  select pos_member_detail_tx(p.org_id, p.id) as j from probe p
)
select 序, 項目, 結果 from (

  select 0 as 序, '① 版本數' as 項目,
         (case when count(*) = 1 then '✅ 1 個（簽名沒變，無多載）'
               else '🔴 ' || count(*)::text || ' 個' end) as 結果
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'pos_member_detail_tx'

  union all
  select 0, '② 權限與易變性',
         (case when bool_and(p.prosecdef) then '✅ DEFINER' else '🔴 INVOKER' end)
         || '　' ||
         (case when bool_and(p.provolatile = 's') then 'STABLE' else '🔴 不是 STABLE' end)
         || '　anon 可執行：' ||
         (case when bool_and(has_function_privilege('anon', p.oid, 'EXECUTE'))
               then '✅' else '🔴 沒有（硬規則 2.5）' end)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'pos_member_detail_tx'

  union all
  select 1, '③ 實際呼叫 · 這個人是誰',
         coalesce((select (j ->> 'nickname') || '　等級 ' || coalesce(j ->> 'tier', '—')
                          || '　餘額 ' || coalesce(j ->> 'balance', '—') from r), '🔴 回傳 null')

  union all
  select 2, '④ 實際呼叫 · 新欄位',
         coalesce((select '累積 ' || coalesce(j ->> 'lifetime_spend', 'null')
                     || '　應得等級 ' || coalesce(j ->> 'tier_earned', 'null')
                     || '　人工指定 ' || coalesce(j ->> 'tier_by_override', 'null')
                     || '　下一級 ' || coalesce(j ->> 'next_tier_label', '(無)')
                     || '　還差 ' || coalesce(j ->> 'next_tier_gap', 'null')
                     || '　生日 ' || coalesce(j ->> 'birthday', '(未填)')
                   from r), '🔴 回傳 null')

  union all
  /* ⑤ 五個新鍵一個都不能少 —— 少一個前端就會拿到 undefined 而不報錯 */
  select 3, '⑤ 新鍵齊不齊',
         coalesce((select string_agg(k, '、')
                     from (values ('lifetime_spend'),('tier_by_override'),
                                  ('tier_earned'),('next_tier_gap'),('birthday')) v(k)
                    where not (select j from r) ? k), '✅ 五個都在')

) x order by 序, 項目;
