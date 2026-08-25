/* ============================================================
   修：升等進度的「下一級」算錯
   2026-08-25 · pos_member_detail_tx（簽名不變）

   ── 怎麼發現的 ──────────────────────────────────────
   前一支的驗證段真的呼叫了一次，印出：

       等級 tiramisu　累積 700　應得等級 bubble_tea
       人工指定 false　下一級 焦糖布丁　還差 9300

   🔴 **提拉米蘇的「下一級」不可能是焦糖布丁** —— 那比他低一級。
   而且 tier_by_override 是 false，代表他的 tiramisu 是**直接寫在
   members.tier**，不是 tier_override —— 我加的那個旗標擋不住這種情況。

   ✅ 硬規則 7 救了這一次：如果驗證段只檢查「函式存不存在、鍵齊不齊」，
      這個錯會一路上線，然後在畫面上對店員說謊。
      **實際執行並看回傳**才看得出來。

   ── 病根 ────────────────────────────────────────────
   「下一級」只看 lifetime_spend，**沒看這個人現在是哪一級**。
   累積 700 → 門檻大於 700 的最低一級 = 焦糖布丁（10000）。
   但他已經是提拉米蘇了。

   ── 改法 ────────────────────────────────────────────
   下一級 = 門檻**嚴格大於 `greatest(目前這一級的門檻, 累積額)`** 的最低一級。
   · 提拉米蘇（門檻 50000）+ 累積 700 → 基準 50000 → 沒有更高的有門檻級距
     → next 為 null，前端不顯示進度。✅
   · 珍珠奶茶（0）+ 累積 700 → 基準 700 → 焦糖布丁，還差 9300。✅
   · 珍珠奶茶（0）+ 累積 60000 → 基準 60000 → 沒有下一級；
     而 tier_earned = tiramisu ≠ tier = bubble_tea，
     前端據此顯示「已達提拉米蘇資格」而不是進度條。✅

   ⚠ 主廚特調的門檻是 null（邀請制，不在階梯上）——
     coalesce 成一個極大值，讓它永遠沒有「下一級」。
     不能 coalesce 成 0，那會讓主廚特調的人看到「還差 10000 到焦糖布丁」。

   ── 順便補 tier_threshold ───────────────────────────
   前端要畫進度條需要「這一級從多少開始」。
   沒有它的話只能從 0 畫到 next_threshold，
   而那會讓焦糖布丁的人看起來永遠只走了一小段。
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
  v_curthr    bigint;   -- 目前這一級的門檻（主廚特調為 null）
  v_base      bigint;   -- 算下一級的基準
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
  select coalesce(t.discount_pct, 0), t.threshold_amount
    into v_pct, v_curthr
    from member_tiers t where t.code = v_tier and t.is_active;
  v_pct := coalesce(v_pct, 0);

  /* 累積消費：折後實付，只算已付款的訂單。
     ⚠ 即時算不存欄位（待辦 1 的 B 案）—— 存欄位會出現「欄位與訂單對不上」
       而且無從得知哪邊才對；退款、作廢、補開都要記得回沖。
     ⚠ 儲值天然被排除：它寫的是 topup_orders 不是 orders。 */
  select coalesce(sum(o.payable), 0) into v_spend
    from orders o
   where o.member_id = p_member_id
     and o.org_id = p_org_id
     and o.status = 'paid';

  /* 這個累積額「應該」是哪一級（只看有門檻的，主廚特調是邀請制不該被掃到） */
  select t.code into v_earned
    from member_tiers t
   where t.is_active and t.threshold_amount is not null
     and t.threshold_amount <= v_spend
   order by t.threshold_amount desc
   limit 1;

  /* 🔴 基準要取「目前級距門檻」與「累積額」的大者。
     只看累積額的話，等級被人工設高的人會看到一個比自己低的「下一級」。
     主廚特調門檻是 null → coalesce 成極大值 → 永遠沒有下一級（它不在階梯上）。 */
  v_base := greatest(coalesce(v_curthr, 9223372036854775807::bigint), v_spend);

  select t.code, t.label, t.threshold_amount into v_next
    from member_tiers t
   where t.is_active and t.threshold_amount is not null
     and t.threshold_amount > v_base
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
      'lifetime_spend', v_spend,
      -- 這一級從多少開始 —— 前端畫進度條要用（主廚特調為 null）
      'tier_threshold', v_curthr,
      -- 🔴 等級是人工指定（tier_override）時進度沒有意義
      'tier_by_override', (v_override is not null),
      -- 累積額「應該」是哪一級。與 tier 不同代表尚未升等（本函式不自動升）
      'tier_earned', v_earned,
      'next_tier', v_next.code,
      'next_tier_label', v_next.label,
      'next_tier_threshold', v_next.threshold_amount,
      -- 沒有下一級時為 null，不要回 0（0 看起來像「已達成」）
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
   ⚠ 這次**每一級各測一位**，不是只測一個人 ——
     上一版的錯正是「只有提拉米蘇那種情況會錯」，
     測一個人剛好測到會過的那個就看不出來。
   ============================================================ */

with per_tier as (
  /* 每個等級挑一位（有已付款訂單的優先），一次看四種情況 */
  select distinct on (coalesce(m.tier_override, m.tier))
         coalesce(m.tier_override, m.tier) as tier_code,
         m.id, m.org_id
    from members m
   where m.deleted_at is null
   order by coalesce(m.tier_override, m.tier),
            (select count(*) from orders o
              where o.member_id = m.id and o.status = 'paid') desc,
            m.created_at
),
r as (
  select p.tier_code, pos_member_detail_tx(p.org_id, p.id) as j from per_tier p
)
select 序, 項目, 結果 from (

  select 0 as 序, '① 版本與權限' as 項目,
         (case when count(*) = 1 then '✅ 1 個' else '🔴 ' || count(*)::text || ' 個' end)
         || '　' || (case when bool_and(p.prosecdef) then 'DEFINER' else '🔴 INVOKER' end)
         || '　anon：' || (case when bool_and(has_function_privilege('anon', p.oid, 'EXECUTE'))
                               then '✅' else '🔴 沒有' end) as 結果
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'pos_member_detail_tx'

  union all
  /* ② 逐級印出來讓人判讀，不回傳是非題。
        ⚠ 同硬規則 3.5 的精神：讓人看得到每一列，
          而不是給一個「✅ 沒問題」然後把錯誤藏在裡面。 */
  select 1, '② ' || r.tier_code,
         '累積 ' || coalesce(r.j ->> 'lifetime_spend', '?')
         || '　本級門檻 ' || coalesce(r.j ->> 'tier_threshold', '(null)')
         || '　→ 下一級 ' || coalesce(r.j ->> 'next_tier_label', '(無)')
         || '　還差 ' || coalesce(r.j ->> 'next_tier_gap', '(null)')
         || '　應得 ' || coalesce(r.j ->> 'tier_earned', '(null)')
    from r

  union all
  /* ③ 唯一該自動判斷的：有沒有人的「下一級」比自己現在這級還低。
        那正是上一版的錯，不能只靠人眼再看一次。 */
  select 2, '③ 下一級低於本級（上一版的錯）',
         coalesce((select string_agg(r.tier_code, '、')
                     from r
                    where (r.j ->> 'next_tier_threshold') is not null
                      and (r.j ->> 'tier_threshold') is not null
                      and (r.j ->> 'next_tier_threshold')::bigint
                          <= (r.j ->> 'tier_threshold')::bigint),
                  '✅ 沒有了')

) x order by 序, 項目;
