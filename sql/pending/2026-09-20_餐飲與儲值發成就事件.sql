-- ============================================================
-- 餐飲與儲值發成就事件（2026-09-20）—— 成就系統第 ④ 步
--   `fnb_drink`（第一杯飲料）· `fnb_meal`（第一份餐點）· `topup`（第一次儲值）
--
-- 📄 契約 `docs/03-會員App與社交/成就事件對照表_階段1.md` §1
--
-- ============================================================
-- 🔴 做法是**觸發器**不是改函式，而那是查證出來的不是偏好
-- ============================================================
--
-- ### ① `orders` 的 AFTER INSERT 觸發器**看不到品項** ⇒ 那條路直接出局
-- ```
-- checkout_tx:223   insert into orders(… 'paid' …)    ← 觸發器在這裡就燒掉了
-- checkout_tx:239   insert into order_items(…)         ← 品項這時才進去
-- ```
-- 既有的 `trg_orders_touch_visit` / `trg_orders_upgrade_tier` 能用，
-- 是因為它們**只要 `member_id` 與金額**。
-- ⚠ 掛在 `orders` 上會拿到 **0 列品項，而且不報錯** —— 最糟的那一種。
--
-- ### ② `checkout_tx` 是 **302 行 ＋ SECURITY INVOKER**
-- 那是全系統的計價／券／等級引擎。**能不碰就不碰。**
-- 🎯 而觸發器一個地方涵蓋**四條結帳路徑**（join／addon／quick／with_topup）——
--   同待辦 24 `last_visit_at` 的理由，那次已經證明過這個做法。
--
-- ### ③ 儲值同理：掛 `topup_orders`，不改 140 行的 `topup_tx`
-- `topup_tx:86` 直接寫 `'paid'` ⇒ 觸發器的 `WHEN` 判斷得到。
--
-- ============================================================
-- 🔴 三件必須寫進去的
-- ============================================================
-- **① 觸發器要自己吞例外。**
--   這跟 `settle_session_tx` 那批**不一樣** —— 那裡是呼叫端包 `exception`，
--   而觸發器**沒有呼叫端能包它**。不吞的話，
--   **成就寫入失敗會回滾整筆結帳**，而那是收錢的那一刻。
--
-- **② 判準要撈主檔，不可以信 `order_items.revenue_type`。**
--   對照表寫的是 `subcategory = 'DRK'` 與 `in ('MEAL','FRY','SNK')`，
--   而 `order_items` **只存 `revenue_type`**（餐飲三類全是 `fnb`，分不出來）。
--   ⇒ join `products` 取 `subcategory`。
--
-- **③ 用 statement 級 ＋ transition table，不用 FOR EACH ROW。**
--   `checkout_tx:239` 是**一個多列 INSERT**（`select … from jsonb_array_elements`）
--   ⇒ row 級的話 5 個品項燒 5 次，每次都跟著跑一次 `ach_meta_tx` 對帳。
--   ⚠ 這會是這個 codebase **第一個 statement 級觸發器**（既有 5 個全是 row 級），
--     但 transition table 是 PG 10 就有的東西，**那是新寫法不是風險**。
--   ⚠ 仍然對 `order_id` 分組 —— 理論上一個 INSERT 可以跨多張單，
--     而「這個交易裡只有一張單」是假設不是保證。
--
-- ============================================================
-- ⚠ 已知並接受：**甜點（DES）一枚都對應不到**
-- 對照表寫的是「第一次點主食／炸物／零嘴」⇒ `MEAL/FRY/SNK`，
-- 而首店餐飲有 **DES 7 項**。客人買焦糖布丁不會拿到 A 區任何一枚。
-- 🎯 那是刻意的：**甜點在 M 餐飲區**（階段 3，「第一份甜點」那一枚），
--   不是漏掉。⇒ 驗證段第 ⑥ 格把這件事印出來，免得日後有人當成 bug。
-- ============================================================
-- ⚠ 這份要留下 DDL ⇒ 驗證段一個字都不准 raise（硬規則 1.8）。
--   行為測試另一份：`sql/checks/2026-09-20_驗餐飲與儲值發成就事件.sql`
-- ============================================================


-- ============================================================
-- ① 餐飲：order_items 的 statement 級觸發器
-- ============================================================
create or replace function public.trg_order_items_achievements()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare r record;
begin
  /* 🔴 整段吞例外：觸發器沒有呼叫端能替它包 ——
     不吞的話，成就寫入失敗會**回滾整筆結帳**。 */
  begin
    for r in
      select o.id as order_id, o.member_id,
             bool_or(pr.subcategory = 'DRK')                      as has_drink,
             bool_or(pr.subcategory in ('MEAL','FRY','SNK'))      as has_meal
        from new_items ni
        join orders   o  on o.id  = ni.order_id
        join products pr on pr.id = ni.product_id
       where o.status = 'paid'          -- ⚠ 未付款的單不算（作廢、草稿）
         and o.member_id is not null    -- ⚠ 匿名結帳沒有人可以發
       group by o.id, o.member_id
    loop
      -- ⚠ 冪等鍵帶 order_id：同一張單重送不會把累積型多加一次
      --   （A 區這兩枚是 specific，本來就冪等，但 M 區會有累積型）
      if r.has_drink then
        perform public.fire_event_tx(r.member_id, 'fnb_drink', 1, null,
                                     'oi:' || r.order_id::text);
      end if;
      if r.has_meal then
        perform public.fire_event_tx(r.member_id, 'fnb_meal', 1, null,
                                     'oi:' || r.order_id::text);
      end if;
    end loop;
  exception when others then null;
  end;
  return null;   -- AFTER 觸發器的回傳值會被忽略
end $$;

drop trigger if exists trg_order_items_ach on public.order_items;
create trigger trg_order_items_ach
  after insert on public.order_items
  referencing new table as new_items
  for each statement
  execute function public.trg_order_items_achievements();


-- ============================================================
-- ② 儲值：topup_orders 的 row 級觸發器
--    ⚠ 這裡用 row 級是對的：一次儲值就是一列，沒有「多列」的問題。
-- ============================================================
create or replace function public.trg_topup_achievements()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  begin
    perform public.fire_event_tx(new.member_id, 'topup', 1, null,
                                 'topup:' || new.id::text);
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists trg_topup_ach on public.topup_orders;
create trigger trg_topup_ach
  after insert on public.topup_orders
  for each row
  when (new.status = 'paid' and new.member_id is not null)
  execute function public.trg_topup_achievements();


-- 🔴 兩個方向都收（硬規則 2.6b）。
-- ⚠ 觸發器函式本來就沒辦法當 RPC 叫（PostgREST 不會暴露回傳 trigger 的函式，
--   直接叫也會拋「trigger functions can only be called as triggers」）——
--   收它是**態度一致**，不是因為今天有洞。
revoke execute on function public.trg_order_items_achievements from public;
revoke execute on function public.trg_order_items_achievements from anon, authenticated;
revoke execute on function public.trg_topup_achievements       from public;
revoke execute on function public.trg_topup_achievements       from anon, authenticated;


-- ============================================================
-- 驗證
-- ============================================================
do $$
declare
  v_msg text := '';
  v_n   int;
  v_txt text;
begin
  -- ① 兩支觸發器函式：DEFINER ＋ owner = postgres
  --    🔴 owner 非查不可 —— 它們要呼叫 service_role only 的 fire_event_tx，
  --      靠的是「進到 DEFINER 裡身分變成 owner」（內部呼叫一樣檢查 EXECUTE）
  select string_agg(p.proname || '=' ||
           case when p.prosecdef and p.proowner::regrole::text = 'postgres'
                then '✅ DEFINER/postgres' else '🔴 ' || p.proowner::regrole::text end,
           '　' order by p.proname)
    into v_txt
    from pg_proc p
   where p.pronamespace='public'::regnamespace
     and p.proname in ('trg_order_items_achievements','trg_topup_achievements');
  v_msg := '　　① 觸發器函式：' || coalesce(v_txt, '⚪ 取不到');

  -- ② 🔴 餐飲那個必須是 statement 級 ＋ 有 transition table
  --    掉回 row 級的話「new_items」不存在，整段會被 exception 吞掉 ⇒ **永遠靜默不發**
  select pg_get_triggerdef(t.oid) into v_txt
    from pg_trigger t join pg_class c on c.oid=t.tgrelid
   where c.relname='order_items' and t.tgname='trg_order_items_ach';
  v_msg := v_msg || E'\n' || case
    when v_txt ~* 'FOR EACH STATEMENT' and v_txt ~* 'NEW TABLE'
    then '✅ ② order_items 的觸發器是 statement 級 ＋ transition table'
    else '🔴 ② 形狀不對：' || coalesce(v_txt, '⚪ 找不到那個觸發器') end;
  v_msg := v_msg || E'\n' || '　　' || coalesce(v_txt, '');

  -- ③ 儲值那個的 WHEN 要同時擋「未付款」與「沒有會員」
  select pg_get_triggerdef(t.oid) into v_txt
    from pg_trigger t join pg_class c on c.oid=t.tgrelid
   where c.relname='topup_orders' and t.tgname='trg_topup_ach';
  v_msg := v_msg || E'\n' || case
    when v_txt ~* 'paid' and v_txt ~* 'member_id IS NOT NULL'
    then '✅ ③ topup_orders 的觸發器有擋未付款與匿名'
    else '🔴 ③ WHEN 條件不對：' || coalesce(v_txt, '⚪ 找不到那個觸發器') end;

  -- ④ 🔴 負對照：既有的觸發器一個都不可以不見
  --    只驗「新的加上去了」的話，把舊的刪掉也會全綠（硬規則 3.55）
  --    期望值用算式寫出來：orders 5 原有 ＋ order_items 0→1 ＋ topup_orders 1→2
  select count(*) into v_n
    from pg_trigger t join pg_class c on c.oid=t.tgrelid
   where c.relname in ('orders','order_items','topup_orders') and not t.tgisinternal;
  v_msg := v_msg || E'\n' || case when v_n = 8
    then '✅ ④ 三張表共 8 個觸發器（orders 5 ＋ order_items 1 ＋ topup_orders 2）'
    else '🔴 ④ 共 ' || v_n || ' 個，應為 8（5 ＋ 1 ＋ 2）' end;
  v_msg := v_msg || E'\n' || coalesce(
    (select '　　' || string_agg(c.relname || '.' || t.tgname, '　' order by c.relname, t.tgname)
       from pg_trigger t join pg_class c on c.oid=t.tgrelid
      where c.relname in ('orders','order_items','topup_orders') and not t.tgisinternal),
    '⚪ 取不到');   -- 字串 || NULL 會吃掉前面所有格（硬規則 3.555）

  -- ⑤ 三個事件名在主檔裡找得到，而且是 active（否則發了也不會解鎖任何東西）
  select string_agg(e || '=' || coalesce((
           select a.code || case when a.is_active then '/active' else '/🔴inactive' end
             from achievements a
            where a.deleted_at is null and a.trigger->>'event' = e limit 1), '🔴 找不到'),
         '　' order by ord)
    into v_txt
    from unnest(array['fnb_drink','fnb_meal','topup']) with ordinality t(e, ord);
  v_msg := v_msg || E'\n' || '　　⑤ 事件對得上成就：' || coalesce(v_txt, '⚪ 取不到');

  -- ⑥ ⚠ 把「甜點對應不到」印出來，免得日後被當成 bug
  select count(*) into v_n from products
   where deleted_at is null and subcategory = 'DES';
  v_msg := v_msg || E'\n' || '　　⑥ ⚠ 甜點（DES）' || v_n
    || ' 項**刻意**不對應 A 區任何一枚 —— 它在 M 餐飲區（階段 3）';

  -- ⑦ 授權：兩支都不給前端（態度一致，不是今天有洞）
  select string_agg(p.proname || '=' ||
           case when has_function_privilege('anon', p.oid, 'execute')
                then '🔴anon 叫得動' else '✅ 收掉了' end, '　' order by p.proname)
    into v_txt
    from pg_proc p
   where p.pronamespace='public'::regnamespace
     and p.proname in ('trg_order_items_achievements','trg_topup_achievements');
  v_msg := v_msg || E'\n' || '　　⑦ 授權：' || coalesce(v_txt, '⚪ 取不到');

  perform set_config('migi.verify', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify', true), ''), '🔴 沒有驗證訊息') as "驗證";
