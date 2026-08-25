/* ============================================================
   會員查詢下一批的後端
   2026-08-25 · pos_member_detail_tx 加兩塊 + 新增一支寫入

   ── 這批只有兩件事需要後端 ──────────────────────────
   查證後發現五項裡有三項**後端早就有了**，是純前端：
       list_buddies_tx(p_org_id, p_member)          牌咖
       list_blocks_tx(p_org_id, p_member)           互黑（不需要 session）
       get_my_availability_tx(p_org_id, p_member_id) 常來時段
   剩下兩項才要動後端：**常加購品項** 與 **店員備註**。

   ── 店員備註寫進 member_interactions，不新增欄位 ──────
   `整合系統開發藍圖.md:365`：
     「不管 MA 自動發或店員手動發，**全寫進同一張互動紀錄**」——
     避免重複打擾（MA 發前先查最近有無被聯絡）、店員看得到系統已發過什麼。

   查證後那張表的設計完全對得上，一個欄位都不用加：
       channel CHECK 'system' | 'staff'
       kind    CHECK 'care' | 'birthday' | 'winback' | 'welcome' | 'note'
       staff_id / created_by / note / created_at
   → 店員備註 = channel='staff' + kind='note'。

   🔴 我原本要在 members 加一個 note 欄位 —— 那會是第六個「建了兩套」，
     而且 MA 上線時「發前先查最近有沒有被聯絡」會查不到店員寫的東西。

   ── ⚠ 回傳的是**全部互動**不只備註 ──────────────────
   照藍圖：店員要看得到「系統已經發過什麼」。
   只回 kind='note' 的話，MA 上線後店員會重複關懷同一個人。

   ── ⚠ 刻意沒有刪除 ──────────────────────────────────
   互動紀錄是**日誌不是欄位**。寫錯就再寫一則更正，
   而不是把歷史抹掉 —— 所有 CRM 的互動紀錄都是 append-only。
   （這也讓「誰在什麼時候說了什麼」永遠可追。）

   ── ⚠ 店員登入還沒做 ────────────────────────────────
   staff_id 與 created_by 會是 null。
   🔴 **不要把 App.jsx 那個寫死的 `const STAFF = "小美"` 塞進來** ——
     假的作者比沒有作者更糟，它看起來是真的，出事時會指向錯的人。
     null 是誠實的，而 created_at 仍然讓「什麼時候寫的」看得出來。
   ============================================================ */

/* ──────────────────────────────────────────────────────────
   一、pos_member_detail_tx：加 top_items（常加購）與 interactions
   簽名不變 → CREATE OR REPLACE，不必 DROP，也就不會丟 GRANT。
   ────────────────────────────────────────────────────────── */

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
  v_curthr    bigint;
  v_base      bigint;
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

  select coalesce(t.discount_pct, 0), t.threshold_amount
    into v_pct, v_curthr
    from member_tiers t where t.code = v_tier and t.is_active;
  v_pct := coalesce(v_pct, 0);

  select coalesce(sum(o.payable), 0) into v_spend
    from orders o
   where o.member_id = p_member_id and o.org_id = p_org_id and o.status = 'paid';

  select t.code into v_earned
    from member_tiers t
   where t.is_active and t.threshold_amount is not null
     and t.threshold_amount <= v_spend
   order by t.threshold_amount desc
   limit 1;

  -- 基準取「本級門檻」與「累積額」的大者，否則等級被人工設高的人
  -- 會看到一個比自己低的「下一級」（2026-08-25 修過一次）
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
      'birthday', m.birthday,
      'lifetime_spend', v_spend,
      'tier_threshold', v_curthr,
      'tier_by_override', (v_override is not null),
      'tier_earned', v_earned,
      'next_tier', v_next.code,
      'next_tier_label', v_next.label,
      'next_tier_threshold', v_next.threshold_amount,
      'next_tier_gap', case when v_next.threshold_amount is null then null
                            else v_next.threshold_amount - v_spend end,

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


/* ──────────────────────────────────────────────────────────
   二、pos_add_member_note_tx：店員寫一則備註
   ────────────────────────────────────────────────────────── */

drop function if exists public.pos_add_member_note_tx(uuid, uuid, text, uuid);

create or replace function public.pos_add_member_note_tx(
  p_org_id    uuid,
  p_member_id uuid,
  p_note      text,
  p_staff_id  uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_id uuid;
begin
  if p_note is null or btrim(p_note) = '' then
    raise exception '備註內容不可為空';
  end if;
  -- 長度上限：備註是「一句提醒」不是日記。太長的東西沒有人會讀，
  -- 而且會把畫面撐開，把真正該看的資訊擠下去。
  if char_length(btrim(p_note)) > 200 then
    raise exception '備註最多 200 字（目前 %）', char_length(btrim(p_note));
  end if;

  if not exists (select 1 from members
                  where id = p_member_id and org_id = p_org_id and deleted_at is null) then
    raise exception '找不到這位會員';
  end if;

  insert into member_interactions(org_id, member_id, staff_id, channel, kind, note, created_by)
  values (p_org_id, p_member_id, p_staff_id, 'staff', 'note', btrim(p_note), p_staff_id)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end $function$;

-- 硬規則 2：DROP 重建會丟 GRANT。這支有 DROP，所以一定要補回來。
grant execute on function public.pos_add_member_note_tx(uuid, uuid, text, uuid)
  to anon, authenticated;


/* ============================================================
   驗證段（單一 SELECT）
   ⚠ 硬規則 7：真的呼叫一次，看回傳。
     ⚠ 但**寫入的那支不能真的跑** —— 它會留下一筆假備註。
       所以只測它的擋牆（空字串），那條路在碰資料表之前就拋錯。
   ============================================================ */

do $$
begin
  begin
    perform pos_add_member_note_tx(gen_random_uuid(), gen_random_uuid(), '   ');
    perform set_config('migi.smoke', '🔴 空白備註竟然通過了', true);
  exception when others then
    perform set_config('migi.smoke', '✅ 正確拋錯：' || sqlerrm, true);
  end;
end $$;

with probe as (
  select m.id, m.org_id
    from members m
   where m.deleted_at is null
   order by (select count(*) from orders o
              where o.member_id = m.id and o.status = 'paid') desc,
            m.created_at
   limit 1
),
r as (select pos_member_detail_tx(p.org_id, p.id) as j from probe p)
select 序, 項目, 結果 from (

  select 0 as 序, '① 兩支函式的狀態' as 項目,
         string_agg(p.proname || '：' ||
                    (case when p.prosecdef then 'DEFINER' else '🔴 INVOKER' end) ||
                    '／anon ' ||
                    (case when has_function_privilege('anon', p.oid, 'EXECUTE')
                          then '✅' else '🔴 沒有' end), '　│　' order by p.proname) as 結果
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname in ('pos_member_detail_tx', 'pos_add_member_note_tx')

  union all
  select 1, '② 常加購品項（實際呼叫）',
         coalesce((select coalesce(
                     (select string_agg((e ->> 'name') || ' ×' || (e ->> 'qty'), '、')
                        from jsonb_array_elements(j -> 'top_items') e),
                     '（這位客人還沒有檯費以外的消費）')
                   from r), '🔴 回傳 null')

  union all
  select 2, '③ 互動紀錄（實際呼叫）',
         coalesce((select coalesce(
                     (select string_agg((e ->> 'channel') || '/' || (e ->> 'kind'), '、')
                        from jsonb_array_elements(j -> 'interactions') e),
                     '（還沒有任何互動紀錄 —— 預期，這張表是空的）')
                   from r), '🔴 回傳 null')

  union all
  /* ④ 常加購**一定不能**含檯費。這是這一格唯一會出錯的地方，
        而且錯了畫面看起來很正常（就是多一列「場地費」）。 */
  select 3, '④ 常加購有沒有混進檯費',
         coalesce((select case when count(*) > 0
                    then '🔴 混進來了：' || string_agg(e ->> 'name', '、')
                    else '✅ 沒有' end
                     from r, jsonb_array_elements(j -> 'top_items') e
                    where (e ->> 'revenue_type') = 'venue_fee'), '✅ 沒有')

  union all
  select 4, '⑤ 舊欄位沒被弄丟',
         coalesce((select case when (j ? 'lifetime_spend') and (j ? 'next_tier_gap')
                                and (j ? 'coupons') and (j ? 'balance') and (j ? 'birthday')
                    then '✅ 累積／進度／券／餘額／生日都還在'
                    else '🔴 有欄位不見了' end from r), '🔴 回傳 null')

  union all
  select 5, '⑥ 寫入擋牆煙霧測試',
         coalesce(current_setting('migi.smoke', true), '🔴 DO 區塊沒執行')

) x order by 序, 項目;
