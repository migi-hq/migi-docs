-- 【待執行】暢打免收的金額記在入座紀錄，不記進訂單
-- ============================================================
-- 問題
--   當日暢打生效時，join_session_tx 的 v_qty = 0，那一桌**不建立場地費品項**。
--   帳是對的 —— 暢打的 300 元在購買當天就從預收款轉成收入了，
--   之後每開一桌是在消耗那筆已認列的收入，不是「又賣 150 又送 150」。
--
--   但因此少了一個該知道的數字：**暢打總共抵掉多少場地費**。
--   那決定暢打定價對不對（賣 300 卻平均被用掉 600，就是定錯價）。
--
-- 為什麼不改成「先加後減」
--   券與會員折扣是**銷貨折讓**（店家少收錢），毛額與折讓都要記，
--   兩者相減才是淨額 —— 這是要算折扣率必須的。
--   暢打不是。沒有人放棄收入，客人已經付過了。
--   若記成 150 收入 + 150 折讓：
--       淨額 300（對）但毛額 450（虛增 150）
--   於是所有以毛額為分母的指標全歪 —— 客單價憑空多 150、
--   場地費營收含一筆沒人付過的 150、折扣率變成 33% 而店家一毛沒少收。
--
--   健身房不會在會員每次進場時記一筆「單次入場費 200 + 折讓 200」。
--   他們記會員費，進場次數是另一個維度。
--
-- 解法：使用量指標記在使用量的表
--   session_players 描述的是「這個人用了這張桌」，不是「這筆交易收了多少錢」。
--   免收的金額放這裡，報表算得出來，帳本不受污染。
--   而且未來其他免費理由（招待、糾紛補償、員工用桌）都有地方放，
--   一律不進收入。
--
-- reason 不設 CHECK
--   免費理由會一直增加，每加一種就要跑 migration 的欄位撐不久
--   （同 coupons.applies_to 的教訓）。
--
--   現值只有 'daypass'。已知未來會有（2026-08-18 盤點，都還沒做）：
--       'staff'  店員身分免檯費 —— 內部使用，不是客人優惠，不該進營收
--       'comp'   店長特調（人工授權）—— 這種是**真的少收錢**，
--                做的時候必須同時加「誰批准的」，否則就是無稽核的免費按鈕
--   三者互相獨立：店員與店長特調不經過當日暢打。
--
--   ⚠ 'daypass' 一個值底下有兩種會計性質：
--       買的   → 履約（收入在購買當天已認列，消耗它不是折讓）
--       活動送 → 促銷費用（從來沒有人付錢）
--   但**不需要為此加欄位** —— has_daypass_tx 認的是那張暢打訂單，
--   活動贈送就是開一張 payable = 0 的暢打訂單，用金額就分得開。
--
--   成本歸屬主檔（reason → 會計性質／誰吸收）可以晚點再建：
--   reason code 存下來就 join 得回去。現在補不回的只有金額與 reason 本身。
-- ============================================================

alter table public.session_players
  add column if not exists fee_waived_amount bigint not null default 0,
  add column if not exists fee_waived_reason text;

comment on column public.session_players.fee_waived_amount is
  '這一桌因權益而免收的場地費（元）。使用量指標，不是折讓 —— 不進 orders、不影響營收毛額。';
comment on column public.session_players.fee_waived_reason is
  '免收原因。目前只有 daypass（當日暢打）。未來可能有招待、糾紛補償、員工用桌等，刻意不設 CHECK。';

create index if not exists idx_session_players_waived
  on public.session_players(fee_waived_reason)
  where fee_waived_reason is not null;

-- join_session_tx：入座時把免收金額記下來
--   兩處：付款人自己那筆、被代付者那幾筆。
--   金額一律用 v_unit（不看暢打的標準單價）—— 那才是「免掉了多少」。
do $$
declare v_old text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_old
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'join_session_tx' and p.prokind = 'f';
  if v_old is null then raise exception 'join_session_tx 不存在'; end if;

  -- ① 付款人：自己這份被暢打免掉時記下來
  v_new := replace(v_old,
$src$  insert into session_players(
    org_id, session_id, member_id, join_type, status,
    charged_points, order_id, joined_at, created_by)
  values (
    v_s.org_id, p_session_id, p_member_id, p_join_type, 'playing',
    coalesce((v_res ->> 'payable')::bigint, 0), v_order, now(), p_staff_id)
  returning id into v_sp;$src$,
$dst$  insert into session_players(
    org_id, session_id, member_id, join_type, status,
    charged_points, order_id, joined_at, created_by,
    fee_waived_amount, fee_waived_reason)
  values (
    v_s.org_id, p_session_id, p_member_id, p_join_type, 'playing',
    coalesce((v_res ->> 'payable')::bigint, 0), v_order, now(), p_staff_id,
    -- 免收金額是使用量指標，不是折讓：不進 orders、不影響營收毛額
    case when (v_self_pass or v_buy_daypass) then v_unit else 0 end,
    case when (v_self_pass or v_buy_daypass) then 'daypass' end)
  returning id into v_sp;$dst$);

  -- ② 被代付者：各自判斷有沒有暢打
  v_new := replace(v_new,
$src$      insert into session_players(
        org_id, session_id, member_id, join_type, status,
        charged_points, order_id, paid_by, joined_at, created_by)
      values (
        v_s.org_id, p_session_id, v_target, p_join_type, 'playing',
        0, null, p_member_id, now(), p_staff_id);$src$,
$dst$      insert into session_players(
        org_id, session_id, member_id, join_type, status,
        charged_points, order_id, paid_by, joined_at, created_by,
        fee_waived_amount, fee_waived_reason)
      values (
        v_s.org_id, p_session_id, v_target, p_join_type, 'playing',
        0, null, p_member_id, now(), p_staff_id,
        -- 暢打是個人權利：被代付者有沒有暢打與付款人無關
        case when has_daypass_tx(v_s.org_id, v_target, v_s.store_id)
             then v_unit else 0 end,
        case when has_daypass_tx(v_s.org_id, v_target, v_s.store_id)
             then 'daypass' end);$dst$);

  if v_new = v_old then
    raise exception '找不到目標字串，線上版可能已改過 —— 先撈 pg_get_functiondef 確認';
  end if;

  execute v_new;
end $$;

-- ============================================================
-- 驗證（單一 SELECT）
--   兩個欄位存在 2、函式已寫入 true。
--   後三欄是目前的統計（現在應該都是 0，之後用暢打開桌就會長出來）。
-- ============================================================
select
  (select count(*) from information_schema.columns
    where table_schema = 'public' and table_name = 'session_players'
      and column_name in ('fee_waived_amount', 'fee_waived_reason'))       as 欄位數,
  (select pg_get_functiondef(p.oid) like '%fee_waived_reason%'
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'join_session_tx'
      and p.prokind = 'f' limit 1)                                         as 函式已寫入,
  (select count(*) from public.session_players
    where fee_waived_reason = 'daypass')                                   as 暢打免收筆數,
  (select coalesce(sum(fee_waived_amount), 0) from public.session_players
    where fee_waived_reason = 'daypass')                                   as 暢打抵掉金額,
  -- ⚠ 2026-08-19 更正：原本這裡寫 sum(o.payable)，那是**整張訂單**的金額，
  --   暢打跟同一次結帳的水餃、飲料會被一起算進來（實測回 580，而暢打單價 300）。
  --   要的是那一筆品項，所以取 order_items.line_total。
  (select coalesce(sum(oi.line_total), 0)
     from public.order_items oi
     join public.orders o on o.id = oi.order_id
     join public.products pr on pr.id = oi.product_id
    where pr.sku = 'SVC-TBL-DAY' and o.status = 'paid')                    as 暢打售出金額;
