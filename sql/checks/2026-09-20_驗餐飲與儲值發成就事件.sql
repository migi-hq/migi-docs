-- ============================================================
-- 驗「餐飲與儲值真的會發成就事件」—— 造訂單測行為，最後整個回滾
-- 2026-09-20　前置：`sql/applied/2026-09-20_餐飲與儲值發成就事件.sql` 已執行
--
-- 🔴 與那一份分家的理由（硬規則 1.8）：
--   那一份要**留下**觸發器 ⇒ 一個字都不准 raise
--   這一份要**造訂單** ⇒ 只能 raise 回滾（沒有 staging，硬規則 5.7）
--
-- ⚠ 這份會真的寫 `orders` / `order_items` / `topup_orders` /
--   `member_achievements`，**全部靠最外層那個 raise 回滾**。可以重複跑。
-- ============================================================

do $$
declare
  v_msg    text := '';
  v_org    uuid;
  v_store  uuid;
  v_member uuid;
  v_drink  uuid;
  v_meal   uuid;
  v_des    uuid;
  v_oid    uuid;
  v_n      int;
begin
  begin
    -- ---------- 造樣本 ----------
    select m.id, m.org_id into v_member, v_org
      from members m where m.is_test and m.deleted_at is null
     order by m.created_at limit 1;
    select id into v_store from stores where deleted_at is null limit 1;

    select id into v_drink from products
     where deleted_at is null and subcategory = 'DRK' limit 1;
    select id into v_meal  from products
     where deleted_at is null and subcategory in ('MEAL','FRY','SNK') limit 1;
    select id into v_des   from products
     where deleted_at is null and subcategory = 'DES' limit 1;

    -- 🔴 找不到樣本要出聲，不要 if…then 安靜跳過（硬規則 3.57）
    if v_member is null or v_store is null then
      v_msg := '⚪ 找不到測試會員或門市，整份測不了'; raise exception 'migi_rollback';
    end if;
    if v_drink is null or v_meal is null or v_des is null then
      v_msg := '⚪ 商品不齊（DRK/MEAL-FRY-SNK/DES 各要一項），整份測不了';
      raise exception 'migi_rollback';
    end if;

    -- ---------- ① 🔴 負對照先跑：只買甜點，不可以解鎖任何一枚 ----------
    -- 🎯 先跑它是刻意的 —— 後面的正對照會把成就解鎖掉，
    --    那之後就再也分不出「沒被誤發」與「早就解鎖了」。
    insert into orders(org_id, store_id, member_id, status, subtotal, payable,
                       idempotency_key, paid_at)
    values (v_org, v_store, v_member, 'paid', 60, 60, 'chk-des-'||gen_random_uuid(), now())
    returning id into v_oid;
    insert into order_items(org_id, order_id, product_id, name, revenue_type, qty,
                            unit_price, line_total)
    values (v_org, v_oid, v_des, '測試甜點', 'fnb', 1, 60, 60);

    select count(*) into v_n
      from member_achievements ma join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_member and ma.status = 'unlocked'
       and a.code in ('onboarding_06','onboarding_07');
    v_msg := case when v_n = 0
      then '✅ ① 只買甜點（DES）沒有解鎖飲料或餐點 —— 判準沒有寫成「只要是 fnb」'
      else '🔴 ① 甜點解鎖了 ' || v_n || ' 枚 —— 判準寫錯了（可能是看 revenue_type）' end;

    -- ---------- ② 🔴 負對照：未付款的單不可以觸發 ----------
    insert into orders(org_id, store_id, member_id, status, subtotal, payable,
                       idempotency_key)
    values (v_org, v_store, v_member, 'open', 70, 70, 'chk-open-'||gen_random_uuid())
    returning id into v_oid;
    insert into order_items(org_id, order_id, product_id, name, revenue_type, qty,
                            unit_price, line_total)
    values (v_org, v_oid, v_drink, '測試飲料', 'fnb', 1, 70, 70);

    select count(*) into v_n
      from member_achievements ma join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_member and ma.status = 'unlocked' and a.code = 'onboarding_06';
    v_msg := v_msg || E'\n' || case when v_n = 0
      then '✅ ② status = open 的單沒有觸發（只有 paid 才算）'
      else '🔴 ② 未付款的單也發了 —— 作廢與草稿都會送成就' end;

    -- ---------- ③ 🔴 負對照：匿名（member_id is null）不可以炸 ----------
    insert into orders(org_id, store_id, member_id, status, subtotal, payable,
                       idempotency_key, paid_at)
    values (v_org, v_store, null, 'paid', 70, 70, 'chk-anon-'||gen_random_uuid(), now())
    returning id into v_oid;
    insert into order_items(org_id, order_id, product_id, name, revenue_type, qty,
                            unit_price, line_total)
    values (v_org, v_oid, v_drink, '測試飲料', 'fnb', 1, 70, 70);
    v_msg := v_msg || E'\n' || '✅ ③ 匿名訂單沒有讓觸發器爆掉（能跑到這一行就是通過）';

    -- ---------- ④ 正對照：飲料 ----------
    insert into orders(org_id, store_id, member_id, status, subtotal, payable,
                       idempotency_key, paid_at)
    values (v_org, v_store, v_member, 'paid', 70, 70, 'chk-drk-'||gen_random_uuid(), now())
    returning id into v_oid;
    insert into order_items(org_id, order_id, product_id, name, revenue_type, qty,
                            unit_price, line_total)
    values (v_org, v_oid, v_drink, '測試飲料', 'fnb', 1, 70, 70);

    select count(*) into v_n
      from member_achievements ma join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_member and ma.status = 'unlocked' and a.code = 'onboarding_06';
    v_msg := v_msg || E'\n' || case when v_n = 1
      then '✅ ④ 買飲料解鎖了「第一杯飲料」'
      else '🔴 ④ 買了飲料卻沒解鎖 —— 觸發器沒生效或 new_items 拿不到' end;

    -- ---------- ⑤ 正對照：餐點，而且是**多列一次插入** ----------
    -- 🎯 這一格順便驗 statement 級：一個 INSERT 帶兩列，只該燒一次
    insert into orders(org_id, store_id, member_id, status, subtotal, payable,
                       idempotency_key, paid_at)
    values (v_org, v_store, v_member, 'paid', 200, 200, 'chk-meal-'||gen_random_uuid(), now())
    returning id into v_oid;
    insert into order_items(org_id, order_id, product_id, name, revenue_type, qty,
                            unit_price, line_total)
    select v_org, v_oid, p.pid, p.nm, 'fnb', 1, 100, 100
      from (values (v_meal, '測試餐點'), (v_des, '測試甜點')) p(pid, nm);

    select count(*) into v_n
      from member_achievements ma join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_member and ma.status = 'unlocked' and a.code = 'onboarding_07';
    v_msg := v_msg || E'\n' || case when v_n = 1
      then '✅ ⑤ 一個 INSERT 兩列（餐點＋甜點）解鎖了「第一份餐點」'
      else '🔴 ⑤ 多列插入沒有解鎖 —— transition table 可能沒吃到' end;

    -- ---------- ⑥ 儲值 ----------
    insert into topup_orders(org_id, store_id, member_id, points, amount_twd,
                             pay_method, status, idempotency_key)
    values (v_org, v_store, v_member, 500, 500, 'cash', 'paid',
            'chk-tp-'||gen_random_uuid());

    select count(*) into v_n
      from member_achievements ma join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_member and ma.status = 'unlocked' and a.code = 'onboarding_28';
    v_msg := v_msg || E'\n' || case when v_n = 1
      then '✅ ⑥ 儲值解鎖了「第一次儲值」'
      else '🔴 ⑥ 儲值沒解鎖：' || v_n end;

    -- ---------- ⑦ 🔴 負對照：C 區 31 枚（is_active=false）不可以被碰到 ----------
    select count(*) into v_n
      from member_achievements ma join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_member and a.code like 'tile\_%' and ma.status <> 'locked';
    v_msg := v_msg || E'\n' || case when v_n = 0
      then '✅ ⑦ C 區 31 枚一枚都沒被碰到'
      else '🔴 ⑦ 有 ' || v_n || ' 枚牌型成就動了' end;

    -- ---------- ⑧ 冪等：同一張單再插一次不會變 ----------
    insert into order_items(org_id, order_id, product_id, name, revenue_type, qty,
                            unit_price, line_total)
    values (v_org, v_oid, v_drink, '測試飲料', 'fnb', 1, 70, 70);
    select count(*) into v_n
      from member_achievements ma join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_member and ma.status = 'unlocked'
       and a.code in ('onboarding_06','onboarding_07','onboarding_28');
    v_msg := v_msg || E'\n' || case when v_n = 3
      then '✅ ⑧ 重複插入之後仍然是 3 枚（specific 天生冪等）'
      else '🔴 ⑧ 變成 ' || v_n || ' 枚，應為 3' end;

    raise exception 'migi_rollback';

  exception when others then
    -- 🔴 訊息一定要在 handler 裡設（硬規則 3.9）
    if sqlerrm = 'migi_rollback' then
      perform set_config('migi.verify', v_msg || E'\n\n🧹 樣本已全部回滾。', true);
    else
      perform set_config('migi.verify',
        v_msg || E'\n\n🔴 意外中斷：' || sqlstate || ' ' || sqlerrm, true);
    end if;
  end;
end $$;

select coalesce(nullif(current_setting('migi.verify', true), ''), '🔴 沒有驗證訊息') as "行為測試";
