/* ============================================================
   會員等級實裝：累積消費自動升等
   2026-08-30

   ── 現況（查證，不是推測）──────────────────────────
   ```
   member_tiers      ✅ 主檔完整，checkout_tx 與 pos_member_detail_tx 都在讀
   members.tier      🔴 **沒有任何函式會寫它** —— 現在的值全是手動設的
   累積消費          🔴 不存在
   ```
   → 也就是「會員等級」只有顯示與折扣，**沒有任何東西讓它前進**。

   ── 拍板的規則（2026-08-30）────────────────────────
   | | |
   |---|---|
   | 累積方式 | **終身累積，只升不降** |
   | 門檻 | 珍珠奶茶 0 ／ 焦糖布丁 **6,000** ／ 提拉米蘇 **20,000** ／ 主廚特調 邀請制 |
   | 算什麼 | `orders.payable`（**實付、折扣後**）且 `status='paid'` |

   🎯 門檻是從**真實價格**推的不是憑空：檯費 100–200 ＋ 餐飲 60–80
     ⇒ 一次來店約 200 元 ⇒ 6,000 ≈ **30 次**、20,000 ≈ **100 次**。
   ⚠ 折扣**只折檯費**（2026-08-17 拍板），所以每一階的金錢價值很小
     （5% × 150 = 7.5 元）。門檻設的是「多久算常客」不是「多久回本」。
   ⚠ **不算儲值**：儲值是預收款不是消費，而且它在 `topup_orders` 不在 `orders`。
     真正的消費在他花掉的那一刻才會出現在 `orders`，算儲值等於算兩次。

   ── 為什麼用觸發器不改 `checkout_tx` ──────────────
   結帳有**四條路**（join／addon／quick／with_topup），改函式要改四個地方
   而且其中兩支是金流函式。觸發器**一個地方涵蓋所有路徑**，
   而且完全不碰既有函式（不 DROP、不丟 GRANT、不用顧部署順序）。
   📌 同 2026-08-26 的 `last_visit_at` / `visit_count`（待辦 24），那次已經驗證過這個做法。
   ============================================================ */

-- ── ① 門檻改成拍板值 ──────────────────────────────
update member_tiers set threshold_amount = 0     where code = 'bubble_tea';
update member_tiers set threshold_amount = 6000  where code = 'caramel_pudding';
update member_tiers set threshold_amount = 20000 where code = 'tiramisu';
/* ⚠ 主廚特調維持 null＝邀請制。**null 不是「門檻是 0」** ——
   下面的查詢用 `threshold_amount is not null` 把它排除在自動升等之外，
   所以它只能由人手動給。 */
update member_tiers set threshold_amount = null  where code = 'chef_special';


-- ── ② 索引：觸發器每次結帳都會 sum by member_id ────
/* 🔴 `orders` **原本沒有任何 member_id 索引**（查證過）。
   現在 153 筆無所謂，但這個 sum 會在**每一次結帳**跑。
   ⚠ 不用 CONCURRENTLY —— Supabase SQL Editor 整份是一個交易，
     而 CONCURRENTLY 不能在交易裡跑（會直接報錯）。153 筆瞬間完成。 */
create index if not exists idx_orders_member_paid
  on orders (member_id, status) include (payable)
  where member_id is not null;


-- ── ③ 重算一個人的等級 ────────────────────────────
create or replace function public.recalc_member_tier_tx(p_member_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_org uuid; v_cur text; v_spent bigint;
  v_new text; v_cur_sort int; v_new_sort int;
begin
  select org_id, tier into v_org, v_cur
    from members where id = p_member_id and deleted_at is null;
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  select coalesce(sum(payable), 0) into v_spent
    from orders where member_id = p_member_id and status = 'paid';

  /* 達標的**最高**一階。`threshold_amount is not null` 把邀請制排除掉。 */
  select code, sort into v_new, v_new_sort
    from member_tiers
   where is_active and threshold_amount is not null and threshold_amount <= v_spent
   order by sort desc limit 1;

  if v_new is null then
    return jsonb_build_object('ok', true, 'spent', v_spent, 'tier', v_cur, 'changed', false);
  end if;

  select sort into v_cur_sort from member_tiers where code = v_cur;

  /* 🔴 **只升不降**。這一行同時擋掉三件事：
     ① 訂單被作廢讓累積變少 → 不降
     ② 日後把門檻調高 → 已達成的人不會被拉下來
     ③ 被手動設成主廚特調的人 → 它的 sort 最大，自動升等碰不到他 */
  if v_cur is not null and v_cur_sort >= v_new_sort then
    return jsonb_build_object('ok', true, 'spent', v_spent, 'tier', v_cur, 'changed', false);
  end if;

  update members set tier = v_new, updated_at = now() where id = p_member_id;
  return jsonb_build_object('ok', true, 'spent', v_spent,
                            'tier', v_new, 'from', v_cur, 'changed', true);
end $$;

/* 🔴 硬規則 2.6b：在 public 新建的函式，Supabase 的 default privileges
   會**明確授權**給 anon —— 而這一支會寫 `members.tier`。
   ⚠ 兩個方向都要收（2.6 ＋ 2.6b）：PUBLIC 繼承與明確授權是兩條不同的路，
     只收一邊是**不會報錯的空操作**。 */
revoke execute on function public.recalc_member_tier_tx(uuid) from public;
revoke execute on function public.recalc_member_tier_tx(uuid) from anon, authenticated;
grant  execute on function public.recalc_member_tier_tx(uuid) to service_role;


-- ── ④ 觸發器 ──────────────────────────────────────
create or replace function public.trg_orders_upgrade_tier()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  perform recalc_member_tier_tx(new.member_id);
  return null;      -- AFTER 觸發器，回傳值會被忽略
end $$;

drop trigger if exists trg_orders_upgrade_tier on public.orders;
create trigger trg_orders_upgrade_tier
  after insert or update of status on public.orders
  for each row
  when (new.status = 'paid' and new.member_id is not null)
  execute function public.trg_orders_upgrade_tier();

/* ⚠ 為什麼是 `insert or update of status` 而不是只有 insert：
   既有的 `trg_orders_touch_visit` 只掛 INSERT，那是假設訂單一建立就是 paid。
   今天確實如此，但 `orders.status` 允許 open/preparing/served ——
   哪天有人先建單後收款，只掛 INSERT 就會**靜靜漏掉**。
   ⚠ 重複觸發是安全的：`recalc` 只有在真的要升等時才 UPDATE。
   ⚠ 不會遞迴：它改的是 `members` 不是 `orders`。 */


-- ── ⑤ 回填 ────────────────────────────────────────
/* ⚠ 只升不降，所以回填**不可能讓任何人掉等級**。
   📌 而且今天全庫累積最高 700 元 —— 回填**預期一個人都不會變**。
     那正是下面驗證段要小心的地方（見第 ③ 格）。 */
do $$
declare r record;
begin
  for r in select id from members where deleted_at is null loop
    perform recalc_member_tier_tx(r.id);
  end loop;
end $$;


-- ── ⑥ 🎯 交易內造一筆 6,000 的已付訂單，看觸發器會不會升等（最後回滾）──
/* ⚠ 欄位是**撈約束撈出來的**不是猜的（硬規則 3.8）：
     `orders_amount_balance` 要求
       payable = subtotal − coupon_discount − tier_discount
       cash_due = payable − points_used
     只送 payable 會被 CHECK 擋下，而錯誤訊息只會給你約束名字。
   ⚠ 挑一個**累積 0**的會員，這樣「升到焦糖布丁」不可能是原本就有的狀態。 */
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_member uuid; v_store uuid; v_before text; v_after text; v_name text; v_msg text;
begin
  select m.id, m.tier, m.display_name into v_member, v_before, v_name
    from members m
   where m.org_id = v_org and m.deleted_at is null
     and coalesce((select sum(o.payable) from orders o
                    where o.member_id = m.id and o.status = 'paid'), 0) = 0
   order by m.created_at limit 1;
  select id into v_store from stores where org_id = v_org order by created_at limit 1;

  if v_member is null or v_store is null then
    v_msg := '🔴 找不到累積 0 的會員或門市 —— 這一格沒驗到';
  else
    insert into orders (org_id, store_id, member_id, status,
                        subtotal, coupon_discount, tier_discount, payable, points_used, cash_due)
    values (v_org, v_store, v_member, 'paid', 6000, 0, 0, 6000, 0, 6000);

    select tier into v_after from members where id = v_member;
    v_msg := v_name || '：' || coalesce(v_before, '(無)') || ' → ' || coalesce(v_after, '(無)')
          || case when v_after = 'caramel_pudding' and v_before is distinct from v_after
                  then '　✅ 觸發器真的升等了'
                  when v_after = v_before then '　🔴 沒有升等（觸發器沒作用）'
                  else '　🔴 升到了意外的等級' end;
  end if;

  raise exception 'rollback_on_purpose';

exception when others then
  /* 🔴 硬規則 3.9：set_config 只有設在這裡才活得下來 ——
     設在 raise 之前會跟著交易一起被回滾，最後印出空白。
     ⚠ PL/pgSQL 的**變數**不是資料庫狀態，所以 v_msg 不會被回滾。 */
  if sqlerrm <> 'rollback_on_purpose' then
    perform set_config('migi.tier', '🔴 測試本身就失敗了：' || sqlerrm, true);
  else
    perform set_config('migi.tier', coalesce(v_msg, '(空)'), true);
  end if;
end $$;


/* ============================================================
   驗證（單一 SELECT）

   🔴 **回填「零人變動」同時是「正確」與「機制根本沒接上」的症狀** ——
     兩者長得一模一樣（硬規則 3.55）。今天沒有人超過 700 元，
     所以只驗回填等於什麼都沒驗。
   → 第 ③ 格**在交易內造一筆 6,000 的已付訂單**，看觸發器有沒有真的把他升等，
     然後整段回滾。那才是這份 SQL 真正要證明的事。
   ============================================================ */
select 序, 項目, 內容 from (

  select 1 as 序, '① 門檻' as 項目,
         (select string_agg(label||'='||coalesce(threshold_amount::text,'邀請制'), '　' order by sort)
            from member_tiers) as 內容

  union all
  select 2, '② 觸發器與授權',
         (select case when count(*) = 1 then '✅ 觸發器在' else '🔴 觸發器數量='||count(*) end
            from pg_trigger where tgrelid='public.orders'::regclass and tgname='trg_orders_upgrade_tier')
      || '　recalc 前端叫得動嗎：'
      || (select case when has_function_privilege('anon', p.oid, 'execute')
                      then '🔴 叫得動（沒收乾淨）' else '✅ 叫不動' end
            from pg_proc p where p.pronamespace='public'::regnamespace
                             and p.proname='recalc_member_tier_tx')
      || '　索引：'
      || (select case when count(*)=1 then '✅' else '🔴 缺' end
            from pg_indexes where schemaname='public' and indexname='idx_orders_member_paid')

  union all
  /* 🎯 這一格才是真正的驗證：造一筆 6,000 的已付訂單 → 應該升成焦糖布丁 */
  select 3, '③ 🎯 正對照：造一筆 6,000 的訂單，看它會不會升等（會回滾）',
         coalesce(current_setting('migi.tier', true), '🔴 沒跑到')

  union all
  select 4, '④ 🎯 正對照：那筆測試訂單真的回滾了（應為 0）',
         (select count(*)::text || ' 筆 payable=6000 的訂單　'
              || case when count(*) = 0 then '✅ 乾淨' else '🔴 有殘留，要手動作廢' end
            from orders where payable = 6000 and status = 'paid')

  union all
  select 5, '⑤ 回填後的現況（預期不變 —— 沒有人超過 700 元）',
         (select string_agg(coalesce(m.display_name,'?')||' '||coalesce(m.tier,'(無)')
                            ||'（累積 '||coalesce(s.amt,0)::text||'）', '　' order by coalesce(s.amt,0) desc)
            from members m
            left join (select member_id, sum(payable) amt from orders where status='paid' group by 1) s
                   on s.member_id = m.id
           where m.deleted_at is null)

) x order by 序;
