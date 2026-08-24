-- ════════════════════════════════════════════════════════════════════
-- topup_tx 自己算贈點，不再採信前端送的值（待辦 17 第二階段）
-- 2026-08-24
--
-- ═══ 問題 ═══
--
-- 🔴 `topup_tx` 的 `p_bonus_points` **完全來自呼叫端**，只驗「不可為負」。
--    也就是說：**送 0 或送 99999 都會照單全收並寫進 wallets.balance**。
--    這與待辦 2（checkout_tx 的價格完全來自前端）是同一個病 ——
--    POS 是店員在用風險可控，但會員端的儲值一旦接上金流，
--    那就是可竄改的贈點。
--
-- 🔴 而且規則現在有**三份**：
--    · migi-pos/src/OpenCheckoutPage.jsx:30   bonusOf() 函式
--    · migi-web/src/pages/wallet.jsx:297      AMTS 寫死的字串
--    · topup_plans 主檔（2026-08-23 建）      ← 唯一該算數的
--
-- ═══ 這一批做什麼 ═══
--
-- topup_tx 改成用 `calc_topup_bonus_tx(org, store, amount_twd)` 自己算。
-- 前端送什麼都不影響入帳。
--
-- ⚠ **簽名不動**（`p_bonus_points` 保留但忽略）。這是刻意的：
--   POS 已經部署在線上，而且 `pos_checkout_with_topup_tx` 是**位置引數**呼叫
--   `topup_tx(..., p_bonus_points, ...)` —— 現在拿掉那個參數，
--   已部署的 POS 會立刻 404。
--   走 expand → migrate → contract：
--     ① 這一批：後端自己算，參數留著但忽略（前端不受影響）
--     ② 下一批：兩端前端改讀主檔、不再送贈點
--     ③ 再下一批：才把參數拿掉
--   ⚠ 這跟 2026-08-19 的 kind → revenue_type 是同一套做法。
--
-- ⚠ 回傳多一個 `bonus_ignored`：呼叫端送的值與實算不同時把它標出來。
--   **靜靜忽略是最糟的**——前端會一直以為自己說了算，而畫面顯示 300、
--   實際入帳 50，只有客人會發現。
-- ════════════════════════════════════════════════════════════════════

begin;

-- 參數型別完全不變 → 不需要 DROP
create or replace function public.topup_tx(
  p_member_id      uuid,
  p_store_id       uuid,
  p_points         bigint,
  p_amount_twd     bigint,
  p_pay_method     text,
  p_idempotency_key text,
  p_bonus_points   bigint default 0,   -- ⚠ 已停用，見下方
  p_external_ref   text  default null,
  p_staff_id       uuid  default null,
  p_note           text  default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_org        uuid;
  v_bal        bigint;
  v_existing   record;
  v_topup_id   uuid;
  v_topup_no   text;
  v_txn_id     uuid;
  v_bonus_txn  uuid;
  v_total      bigint;
  v_bonus      bigint;    -- ★ 由 topup_plans 算出來的，唯一算數的贈點
begin
  -- ---------- 參數驗證 ----------
  if p_points <= 0 then
    raise exception 'points 必須 > 0';
  end if;
  if p_amount_twd <= 0 then
    raise exception 'amount_twd 必須 > 0';
  end if;
  -- ⚠ 原本這裡有 `if p_bonus_points < 0 then raise` —— 已移除。
  --   那個參數現在完全不影響結果，對一個被忽略的值做驗證只會讓人以為它還有用。
  if p_pay_method not in ('cash','credit_card','line_pay','jko','other') then
    raise exception '不支援的付款方式: %', p_pay_method;
  end if;
  if p_idempotency_key is null then
    raise exception 'idempotency_key 必填';
  end if;

  select org_id into v_org from members where id = p_member_id and deleted_at is null;
  if v_org is null then
    raise exception 'member % 不存在', p_member_id;
  end if;

  -- ---------- ★ 贈點由主檔決定，不採信呼叫端 ----------
  -- 規則見 topup_plans：門檻 <= 金額的那些之中取最大的一筆（往下取級距）。
  -- ⚠ 用 p_amount_twd 不是 p_points：贈點是「付了多少錢」的回饋，
  --   而這兩個在現行流程裡雖然相等，語意上不是同一件事
  --   （日後若出現「1000 元買 1200 點」的方案，用錯就會算錯）。
  v_bonus := calc_topup_bonus_tx(v_org, p_store_id, p_amount_twd);

  -- ---------- 冪等：同一把鑰匙重打，直接回上次結果 ----------
  select id, topup_no, wallet_txn_id
    into v_existing
    from topup_orders
   where org_id = v_org and idempotency_key = p_idempotency_key;

  if found then
    select balance into v_bal from wallets where member_id = p_member_id;
    return jsonb_build_object(
      'idempotent',  true,
      'topup_id',    v_existing.id,
      'topup_no',    v_existing.topup_no,
      'txn_id',      v_existing.wallet_txn_id,
      'new_balance', v_bal
    );
  end if;

  -- ---------- 鎖錢包（並發安全）；沒有就建 ----------
  select balance into v_bal from wallets where member_id = p_member_id for update;
  if not found then
    insert into wallets(member_id, org_id, balance) values (p_member_id, v_org, 0);
    v_bal := 0;
    perform 1 from wallets where member_id = p_member_id for update;
  end if;

  -- ---------- ① 建儲值單（單號由 trigger 自動產生 TP-店碼-YYMMDD-流水） ----------
  insert into topup_orders(
    org_id, store_id, member_id,
    points, bonus_points, amount_twd,
    pay_method, status,
    external_ref, idempotency_key,
    staff_id, note, created_by
  ) values (
    v_org, p_store_id, p_member_id,
    p_points, v_bonus, p_amount_twd,          -- ★ v_bonus
    p_pay_method, 'paid',
    p_external_ref, p_idempotency_key,
    p_staff_id, p_note, p_staff_id
  )
  returning id, topup_no into v_topup_id, v_topup_no;

  -- ---------- ② 寫入點流水（本金） ----------
  insert into wallet_txns(
    org_id, store_id, member_id, type, amount, status,
    counter_account, idempotency_key, external_ref,
    ref_table, ref_id, staff_id, note
  ) values (
    v_org, p_store_id, p_member_id, 'topup', p_points, 'completed',
    'liability',                       -- 儲值＝預收款（負債），不是收入
    p_idempotency_key, p_external_ref,
    'topup_orders', v_topup_id, p_staff_id, p_note
  )
  returning id into v_txn_id;

  -- ---------- ③ 贈點另開一筆（與本金分離，帳務乾淨） ----------
  if v_bonus > 0 then                        -- ★ v_bonus
    insert into wallet_txns(
      org_id, store_id, member_id, type, amount, status,
      counter_account, idempotency_key,
      ref_table, ref_id, staff_id, note
    ) values (
      v_org, p_store_id, p_member_id, 'adjust', v_bonus, 'completed',
      'promo_expense',                 -- 贈點＝行銷費用，非預收款
      p_idempotency_key || ':bonus',   -- 冪等鍵加後綴，避免撞號
      'topup_orders', v_topup_id, p_staff_id, '儲值贈點'
    )
    returning id into v_bonus_txn;
  end if;

  -- ---------- ④ 更新餘額快取 + 回填單上的流水 id ----------
  v_total := p_points + v_bonus;             -- ★ v_bonus
  update wallets set balance = balance + v_total where member_id = p_member_id;
  update topup_orders set wallet_txn_id = v_txn_id where id = v_topup_id;

  return jsonb_build_object(
    'topup_id',      v_topup_id,
    'topup_no',      v_topup_no,
    'txn_id',        v_txn_id,
    'bonus_txn_id',  v_bonus_txn,
    'points',        p_points,
    'bonus_points',  v_bonus,
    -- ⚠ 呼叫端送的值與實算不同時標出來。靜靜忽略是最糟的：
    --   前端會一直以為自己說了算，而畫面顯示 300、實際入帳 50，
    --   只有客人會發現。
    'bonus_ignored', case when coalesce(p_bonus_points, 0) <> v_bonus
                          then coalesce(p_bonus_points, 0) else null end,
    'new_balance',   v_bal + v_total
  );
end $function$;

commit;


-- ════════════════════════════════════════════════════════════════════
-- 驗證（單一 SELECT）
-- ⚠ 不做真的儲值 —— 那會在正式資料裡留下訂單與流水。
--   改用「檢查函式體」＋「用不存在的會員觸發早期 raise」。
-- ════════════════════════════════════════════════════════════════════
with o as (select id from orgs limit 1)
select 項目, 結果
from (
  select 1 as ord, '① 版本數（應為 1）' as 項目,
    (select count(*)::text from pg_proc
      where pronamespace='public'::regnamespace and proname='topup_tx') as 結果

  union all select 2, '② 簽名（應仍含 p_bonus_points —— 這批刻意不動簽名）',
    coalesce((select pg_get_function_identity_arguments(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='topup_tx' limit 1),
             '❌ 不存在')

  union all select 3, '③ 🔴 函式體是否呼叫 calc_topup_bonus_tx（應為 是）',
    case when (select pg_get_functiondef(oid) from pg_proc
                where pronamespace='public'::regnamespace and proname='topup_tx' limit 1)
              like '%calc_topup_bonus_tx%' then '是' else '❌ 沒有 —— 沒改到' end

  -- 🔴 這一項最關鍵：三個寫入點都必須用 v_bonus，不能還有漏網的 p_bonus_points。
  --    只檢查「有沒有呼叫新函式」不夠 —— 改一半才是最危險的狀態
  --    （訂單記新值、流水記舊值、餘額記第三個值，而且不報錯）。
  union all select 4, '④ 🔴 函式體裡還有沒有殘留的 p_bonus_points 寫入',
    case when (select pg_get_functiondef(oid) from pg_proc
                where pronamespace='public'::regnamespace and proname='topup_tx' limit 1)
              ~ 'points, p_bonus_points, amount_twd|amount, p_bonus_points|p_points \+ p_bonus_points|if p_bonus_points > 0'
         then '❌ 還有寫入點用舊參數 —— 改到一半' else '沒有（只剩 bonus_ignored 的比對）' end

  union all select 5, '⑤ 回傳是否含 bonus_ignored（分歧要看得見）',
    case when (select pg_get_functiondef(oid) from pg_proc
                where pronamespace='public'::regnamespace and proname='topup_tx' limit 1)
              like '%bonus_ignored%' then '是' else '❌ 沒有' end

  -- ⚠ 這裡**不做** topup_tx 的煙霧測試。
  --   它的參數驗證全部是 `raise exception`（不是回 {ok:false}），
  --   而純 SQL 的 SELECT 接不住例外 —— 呼叫一次就會讓整個驗證查詢中斷，
  --   其餘每一項都看不到。
  --   ⚠ 這是 topup_tx 與其他函式不同的地方（多數業務錯誤回 ok:false），
  --     要測它得包在 DO 區塊裡，而那又不能跟這個單一 SELECT 併在一起。
  --   → 這一批靠 ③④⑤ 的結構檢查，實際行為在下次真的儲值時驗。

  union all select 11, '⑪ calc_topup_bonus_tx 仍然正確（抽三個金額覆核）',
    coalesce((select string_agg(v.amt || '→' || calc_topup_bonus_tx(o.id, null, v.amt), '　')
                from o cross join (values (999::bigint),(1500::bigint),(3000::bigint)) v(amt)),
             '—')
) x
order by ord;

-- ── 怎麼看 ────────────────────────────────────────────────
-- ③④ 一起看才有意義：③ 證明「有用新的」、④ 證明「沒有舊的漏網」。
--    只看 ③ 會漏掉「改到一半」——那是最危險的狀態：
--    訂單記新值、流水記舊值、餘額記第三個值，而且不報錯。
-- ⚠ 這一批沒有行為測試（原因見 ⑩ 的位置）。
--    真正的驗證是**下一次實際儲值**：
--    在 POS 用會員儲 1500 元，檢查 topup_orders.bonus_points = 50
--    （前端現在送的是 50，所以看不出差別）；
--    要真的證明後端說了算，最快的方法是暫時把前端送的值改成 999 再儲一次 ——
--    入帳應該仍是 50，且回傳的 bonus_ignored = 999。
