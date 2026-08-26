/* ============================================================
   讓 members.last_visit_at 與 visit_count 活起來
   2026-08-26

   ✅ 已執行並驗證通過（2026-08-26）
      觸發器已掛且啟用／回填完成／**回填與即時重算一致**／
      煙霧測試 visit_count 2 → 3（新的一天有加到）／
      primary_staff_id 0/4 維持不動（等待辦 20）。

      📌 回填結果證實 null 與 0 分得開：
         測試02 → 1 天、測試測試… → 2 天、測試03/04 → 「沒來過」(null)。
         **「從來沒來過」是有意義的值，不是缺資料。**

   ── 現況（2026-08-26 查證）──────────────────────────
   | 欄位 | 有值 | 有函式寫 | 有觸發器寫 |
   |---|---|---|---|
   | last_visit_at    | 0 / 4 | ❌ | ❌ |
   | visit_count      | 0 / 4 | ❌ | ❌ |
   | primary_staff_id | 0 / 4 | ❌ | ❌ |

   三個都是「建了完全沒人寫」。**留著不動最糟** ——
   下一個人看到欄位會以為它有值，而它永遠是 null。

   ── 這一份只救兩個，第三個刻意不動 ──────────────────
   🔴 `primary_staff_id`（業務歸屬「我的客人」）**卡在店員登入**：
     沒有店員身分就沒有東西可寫。硬給一個值只會製造假資料。
     → 留著不動，但在 CLAUDE.md 註明「等待辦 20」，不要讓它看起來像被遺忘的。

   ── 這與待辦 1 的 B 案不衝突 ────────────────────────
   待辦 1 拍板「消費累積**從 orders 即時算，不存計數欄位**」，理由是
   存欄位會漂、退款作廢要記得回沖。那個理由對**累積消費**成立，
   但這兩個欄位是**不同的用途**：

     · 即時算適合「單一會員的頁面」—— 一次查一個人，成本很低
     · MA 要掃「全店 7 天沒來的人」—— 掃 orders 是全表聚合，
       而 last_visit_at 加索引是一次範圍掃描，差一個數量級

   ✅ 而且它們**可以隨時從 orders 重算驗證**（這份檔案的回填就是重算），
     不像累積消費那樣一漂就沒人知道哪邊才對。

   ── visit_count 的定義（要先講清楚，否則名字會說謊）────
   **「來過幾天」，同一天多筆訂單算一次。**
   用訂單數的話它其實是「訂單數」—— 一個客人一天加購三次不是來了三次。
   ⚠ 用 **Asia/Taipei 的日曆日**，與當日暢打同一個判準
     （CLAUDE.md 待辦 0.5：「當日」兩個字對客人與店員都不需要解釋）。

   ── 為什麼用觸發器不改 checkout_tx ──────────────────
   結帳有四條路（join / addon / quick / with_topup），改函式要改四個地方，
   而且其中兩支是金流函式。
   ✅ 觸發器掛在 `orders` 上，**一個地方涵蓋所有路徑**，
     而且完全不碰任何既有函式（不 DROP、不丟 GRANT、不用部署順序）。
   ============================================================ */


/* ──────────────────────────────────────────────────────────
   一、觸發器函式
   ────────────────────────────────────────────────────────── */

create or replace function public.trg_orders_touch_member_visit()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_last date;
  v_new  date;
begin
  -- 只有已付款、且掛在會員身上的訂單算一次來訪
  if NEW.member_id is null or NEW.status <> 'paid' then
    return null;   -- AFTER 觸發器的回傳值被忽略，寫 null 表示「不做事」
  end if;

  /* 用付款時間判定是哪一天。paid_at 為 null 時退回 created_at ——
     checkout_tx 會寫 paid_at，但別的路徑萬一沒寫，
     用建立時間也比整筆不算好。 */
  v_new := (coalesce(NEW.paid_at, NEW.created_at) at time zone 'Asia/Taipei')::date;

  select (last_visit_at at time zone 'Asia/Taipei')::date
    into v_last
    from members where id = NEW.member_id;

  /* ★ 同一天多筆只算一次來訪。
     ⚠ 一個客人一天加購三次不是來了三次 ——
       用訂單數當 visit_count，那個欄位名就會說謊。
     ⚠ 日期用 Asia/Taipei，與當日暢打同一個判準。 */
  update members
     set last_visit_at = greatest(coalesce(last_visit_at, coalesce(NEW.paid_at, NEW.created_at)),
                                  coalesce(NEW.paid_at, NEW.created_at)),
         visit_count   = coalesce(visit_count, 0)
                         + (case when v_last is null or v_last < v_new then 1 else 0 end)
   where id = NEW.member_id;

  return null;
end $function$;


/* ──────────────────────────────────────────────────────────
   二、掛上去
   ⚠ AFTER INSERT：BEFORE 的話 orders 那一列還沒真的存在，
     而且與既有的 trg_orders_is_test（BEFORE）搶同一個時機沒有好處。
   ⚠ 只在 status = 'paid' 時觸發 —— WHEN 子句比在函式裡判斷便宜，
     而且意圖寫在觸發器定義上，看 \d orders 就知道。
   ────────────────────────────────────────────────────────── */

drop trigger if exists trg_orders_touch_visit on orders;

create trigger trg_orders_touch_visit
  after insert on orders
  for each row
  when (NEW.status = 'paid' and NEW.member_id is not null)
  execute function trg_orders_touch_member_visit();


/* ──────────────────────────────────────────────────────────
   三、回填既有資料
   ⚠ 回填用的是**與觸發器同一套定義**（Asia/Taipei 的日曆日去重）——
     兩邊定義不同的話，新舊資料會用不同的規則，而那沒有人會發現。
   ⚠ 只回填有訂單的會員。沒有訂單的維持 null / 0 ——
     null 代表「從來沒來過」，是有意義的值，不要寫成 now()。
   ────────────────────────────────────────────────────────── */

with v as (
  select o.member_id,
         max(coalesce(o.paid_at, o.created_at)) as last_at,
         count(distinct (coalesce(o.paid_at, o.created_at)
                         at time zone 'Asia/Taipei')::date) as days
    from orders o
   where o.status = 'paid' and o.member_id is not null
   group by o.member_id
)
update members m
   set last_visit_at = v.last_at,
       visit_count   = v.days
  from v
 where v.member_id = m.id;


/* ============================================================
   驗證段（單一 SELECT）

   ⚠ 硬規則 7：不能只看「觸發器建起來了」。
     這裡**真的插一筆訂單**驗觸發器，然後 raise 回滾。
   ⚠ 硬規則 3.9：訊息設在 exception 處理器裡，
     設在成功路徑上再 raise 會被 savepoint 回滾掉。
   ============================================================ */

do $$
declare
  v_m     uuid;
  v_store uuid;
  v_org   uuid;
  v_before int;
  v_after  int;
  v_msg   text;
begin
  select m.id, m.org_id, m.visit_count into v_m, v_org, v_before
    from members m where m.deleted_at is null
    order by m.created_at limit 1;
  select s.id into v_store from stores s where s.org_id = v_org limit 1;

  if v_m is null or v_store is null then
    perform set_config('migi.v', '⚠ 跳過：找不到會員或門市', true);
    return;
  end if;

  begin
    /* 用**明天**的日期插一筆，確保它是「新的一天」→ visit_count 應該 +1。
       ⚠ 用今天的話，如果回填後的 last_visit_at 就是今天，
         結果會是 +0，那樣分不出「觸發器沒跑」與「同日不重複」。 */
    insert into orders(org_id, store_id, member_id, status,
                       subtotal, coupon_discount, tier_discount,
                       payable, points_used, cash_due,
                       idempotency_key, paid_at)
    values (v_org, v_store, v_m, 'paid',
            0, 0, 0, 0, 0, 0,
            'smoke-visit-' || gen_random_uuid()::text, now() + interval '1 day');

    select visit_count into v_after from members where id = v_m;
    v_msg := case when v_after = v_before + 1
                  then '✅ 觸發器有跑：visit_count ' || v_before::text || ' → ' || v_after::text
                  else '🔴 沒加到：' || v_before::text || ' → ' || coalesce(v_after::text,'null') end;
    raise exception 'rollback_on_purpose';
  exception when others then
    if sqlerrm = 'rollback_on_purpose' then
      perform set_config('migi.v', v_msg, true);
    else
      perform set_config('migi.v', '🔴 插入失敗：' || sqlerrm, true);
    end if;
  end;
end $$;

select 序, 項目, 結果 from (

  select 0 as 序, '① 觸發器掛上了嗎' as 項目,
         coalesce((select tg.tgname || '　' ||
                          (case when tg.tgenabled = 'O' then '啟用' else '🔴 停用' end)
                     from pg_trigger tg
                     join pg_class t on t.oid = tg.tgrelid
                    where t.relnamespace = 'public'::regnamespace
                      and t.relname = 'orders' and tg.tgname = 'trg_orders_touch_visit'
                    limit 1), '🔴 沒掛上') as 結果

  union all
  select 1, '② 回填結果',
         m.display_name || '：最後來訪 ' ||
         coalesce(to_char(m.last_visit_at at time zone 'Asia/Taipei', 'MM/DD HH24:MI'), '（沒來過）') ||
         '　來過 ' || coalesce(m.visit_count::text, '0') || ' 天'
    from members m where m.deleted_at is null

  union all
  /* ③ 回填對不對 —— 拿同一套定義重算一次比對。
        ⚠ 這是唯一能證明「回填沒算錯」的方法：
          光看數字合不合理沒有用，要跟來源對。 */
  select 2, '③ 回填與即時重算是否一致',
         coalesce((select case when count(*) = 0 then '✅ 全部一致'
                               else '🔴 ' || count(*)::text || ' 人對不上' end
                     from members m
                     left join (
                       select o.member_id,
                              count(distinct (coalesce(o.paid_at, o.created_at)
                                              at time zone 'Asia/Taipei')::date) as days
                         from orders o
                        where o.status = 'paid' and o.member_id is not null
                        group by o.member_id) c on c.member_id = m.id
                    where m.deleted_at is null
                      and coalesce(m.visit_count, 0) <> coalesce(c.days, 0)), '✅ 全部一致')

  union all
  select 3, '④ 觸發器煙霧測試',
         coalesce(current_setting('migi.v', true), '🔴 DO 區塊沒執行')

  union all
  /* ⑤ primary_staff_id 刻意沒動 —— 這一項是提醒，不是檢查。 */
  select 4, '⑤ primary_staff_id（刻意不動）',
         (select count(*) filter (where primary_staff_id is not null)::text
              || ' / ' || count(*)::text || ' 有值　—— 等店員登入（待辦 20）'
            from members where deleted_at is null)

) x order by 序, 項目;
