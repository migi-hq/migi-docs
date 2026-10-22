/* ============================================================
   錢包流水記「其中幾點是贈點」—— 本金與贈點分帳的第一步
   2026-10-22 · MIGI 咪吉麻將
   📄 規則：docs/07-營運商業/電子發票與儲值點數.md 第三、六節（2026-10-05 拍板）

   ── 為什麼 ──────────────────────────────────────────────
   贈點入帳本來就是獨立一筆（counter_account = 'promo_expense'），
   但**扣點那一側**一律只記一筆總數 ⇒ 「這次扣了幾點贈點」沒有地方記。
   退款要扣回已用的贈點、發票只開本金部分，兩件事都要這個數字。

   ── 做法：一個觸發器，不改任何寫入函式 ─────────────────────
   會寫 wallet_txns 的有 7 支（真正有人在叫的只有 topup_tx 與 checkout_tx）。
   改函式的話，漏一支兩格就對不起來而且不報錯；以後新寫的函式也要記得。
   ⇒ BEFORE INSERT 觸發器替每一筆填 bonus_amount，**規則只有一份**（_wallet_bonus_part）。
   ⚠ **一律由觸發器算，呼叫端送什麼都覆寫**。曾經想讓「明確給值」照收，
     但約束只看單筆，照收的值可以讓本金算成負數而不報錯；今天也沒有任何函式會送這個值。

   ── 規則 ────────────────────────────────────────────────
   進帳   counter_account = 'promo_expense' 的正數 ⇒ 整筆是贈點；其餘正數 ⇒ 本金
   扣點   先扣贈點，扣完才扣本金
   沖正   有 reverses_txn_id 的 ⇒ 照原單的贈點部分退回或扣回
   底線   不管上面怎麼算，**本金與贈點都不可以變成負數**：
          本金不夠扣的差額一定由贈點補；贈點不夠的就不扣贈點

   ── 刻意不做的 ──────────────────────────────────────────
   · 不存「贈點餘額」快取欄位：每次從流水加總（每人幾十筆）。
     wallets.balance 已經是一份快取，再多一份就是兩份會漂的東西。
   · 不做贈點效期：效期多長是營運決定，還沒定（文件第四節）。
   · 不改畫面：今天沒有任何畫面要顯示兩格；開發票與退款時才會讀。

   ── 回填 ────────────────────────────────────────────────
   既有 284 筆**全部是測試帳號**。照時間順序重播同一條規則回填。
   wallet_txns 有「不可 UPDATE」的觸發器（append-only 帳本）——
   這份在同一個交易裡暫停它、回填、再打開；失敗會整份回滾，連暫停一起退掉。
   同一時間點寫入的（同一筆結帳裡的儲值與扣點）先算進帳再算扣點。
   ============================================================ */

-- ① 欄位 ＋ 約束（既有列預設 0，一定符合約束）
alter table public.wallet_txns
  add column if not exists bonus_amount bigint not null default 0;

alter table public.wallet_txns drop constraint if exists chk_bonus_amount_within;
alter table public.wallet_txns add constraint chk_bonus_amount_within check (
  (amount >= 0 and bonus_amount between 0 and amount) or
  (amount <  0 and bonus_amount between amount and 0));

comment on column public.wallet_txns.bonus_amount is
  '這一筆裡屬於贈點的部分（正負號同 amount）；amount − bonus_amount ＝ 本金部分。由觸發器 trg_wallet_txn_fill_bonus 依「贈點先扣」填入，規則在 _wallet_bonus_part。2026-10-22';

-- ② 規則（純計算，觸發器與回填共用 —— 只有這一份）
create or replace function public._wallet_bonus_part(
  p_amount     bigint,   -- 這一筆的金額（正＝進帳、負＝扣）
  p_counter    text,     -- counter_account
  p_orig_bonus bigint,   -- 沖正時原單的 bonus_amount；不是沖正就是 null
  p_bonus_avail bigint,  -- 寫入前的贈點餘額
  p_total_avail bigint   -- 寫入前的總餘額
) returns bigint
language plpgsql immutable
set search_path = public
as $$
declare
  v_principal bigint := greatest(coalesce(p_total_avail, 0) - coalesce(p_bonus_avail, 0), 0);
  v_bonus     bigint := greatest(coalesce(p_bonus_avail, 0), 0);
  v_need      bigint;   -- 扣點時要扣的點數（正數）
  v_take      bigint;   -- 其中由贈點出的（正數）
begin
  if p_amount = 0 then return 0; end if;

  -- 進帳
  if p_amount > 0 then
    if p_orig_bonus is not null then
      -- 沖正一筆扣點：原單扣了幾點贈點就還幾點（最多還到這一筆的金額）
      return least(greatest(-p_orig_bonus, 0), p_amount);
    end if;
    return case when p_counter = 'promo_expense' then p_amount else 0 end;
  end if;

  -- 扣點
  v_need := -p_amount;
  if p_orig_bonus is not null then
    v_take := greatest(p_orig_bonus, 0);   -- 沖正一筆進帳：原單有幾點贈點就扣回幾點；本金那筆是 0
  else
    v_take := v_need;                       -- 一般扣點：贈點先扣
  end if;
  v_take := greatest(v_take, v_need - v_principal);   -- 本金不夠的一定由贈點補
  v_take := least(v_take, v_bonus, v_need);           -- 贈點不夠就扣到 0
  return -greatest(v_take, 0);
end $$;

revoke execute on function public._wallet_bonus_part(bigint, text, bigint, bigint, bigint) from public;
revoke execute on function public._wallet_bonus_part(bigint, text, bigint, bigint, bigint) from anon, authenticated;

-- ③ 觸發器
create or replace function public._wallet_txn_fill_bonus()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bonus bigint;
  v_total bigint;
  v_orig  bigint;
begin
  -- 跟寫入函式同一把鎖（它們本來就先鎖錢包），兩筆同時寫時不會算到同一個餘額
  perform 1 from wallets where member_id = new.member_id for update;

  select coalesce(sum(bonus_amount), 0), coalesce(sum(amount), 0)
    into v_bonus, v_total
    from wallet_txns
   where member_id = new.member_id and org_id = new.org_id and status = 'completed';

  if new.reverses_txn_id is not null then
    select bonus_amount into v_orig from wallet_txns where id = new.reverses_txn_id;
    v_orig := coalesce(v_orig, 0);
  end if;

  new.bonus_amount := public._wallet_bonus_part(new.amount, new.counter_account, v_orig, v_bonus, v_total);
  return new;
end $$;

revoke execute on function public._wallet_txn_fill_bonus() from public;
revoke execute on function public._wallet_txn_fill_bonus() from anon, authenticated;

drop trigger if exists trg_wallet_txn_fill_bonus on public.wallet_txns;
create trigger trg_wallet_txn_fill_bonus
  before insert on public.wallet_txns
  for each row execute function public._wallet_txn_fill_bonus();

-- ④ 回填既有流水（全部是測試帳號）
alter table public.wallet_txns disable trigger trg_txn_no_update;

do $$
declare
  r       record;
  v_mem   uuid := null;
  v_org   uuid := null;
  v_bonus bigint := 0;
  v_total bigint := 0;
  v_b     bigint;
  v_orig  bigint;
begin
  for r in
    select t.id, t.member_id, t.org_id, t.amount, t.counter_account, t.reverses_txn_id
      from public.wallet_txns t
     where t.status = 'completed'
     order by t.member_id, t.org_id, t.created_at, (t.amount < 0), t.id   -- 同一時間點先算進帳
  loop
    if v_mem is distinct from r.member_id or v_org is distinct from r.org_id then
      v_mem := r.member_id; v_org := r.org_id; v_bonus := 0; v_total := 0;
    end if;

    v_orig := null;
    if r.reverses_txn_id is not null then
      select coalesce(bonus_amount, 0) into v_orig from public.wallet_txns where id = r.reverses_txn_id;
      v_orig := coalesce(v_orig, 0);
    end if;

    v_b := public._wallet_bonus_part(r.amount, r.counter_account, v_orig, v_bonus, v_total);
    if v_b <> 0 then
      update public.wallet_txns set bonus_amount = v_b where id = r.id;
    end if;
    v_bonus := v_bonus + v_b;
    v_total := v_total + r.amount;
  end loop;
end $$;

alter table public.wallet_txns enable trigger trg_txn_no_update;

-- ⑤ 讀取：某位會員的兩格（給日後的開票、退款、錯誤儀表；前端叫不到）
create or replace function public.wallet_pools(p_member_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'balance',   coalesce(sum(amount), 0),
    'bonus',     coalesce(sum(bonus_amount), 0),
    'principal', coalesce(sum(amount), 0) - coalesce(sum(bonus_amount), 0))
    from wallet_txns
   where member_id = p_member_id and status = 'completed';
$$;

revoke execute on function public.wallet_pools(uuid) from public;
revoke execute on function public.wallet_pools(uuid) from anon, authenticated;
grant  execute on function public.wallet_pools(uuid) to service_role;

-- ============================================================
-- 驗證（單一 SELECT；不用 raise —— 硬規則 1.8）
-- ============================================================
do $$
declare
  v_msg text := '';
  v_n   bigint;
  v_m   bigint;
begin
  -- ① 欄位與約束
  select count(*) into v_n from information_schema.columns
   where table_schema = 'public' and table_name = 'wallet_txns' and column_name = 'bonus_amount';
  select count(*) into v_m from pg_constraint
   where conrelid = 'public.wallet_txns'::regclass and conname = 'chk_bonus_amount_within';
  v_msg := v_msg || case when v_n = 1 and v_m = 1 then '✅' else '🔴' end
        || ' ① 欄位 ' || v_n || '、約束 ' || v_m || E'（都要是 1）\n';

  -- ② 新觸發器存在且啟用
  select count(*) into v_n from pg_trigger
   where tgrelid = 'public.wallet_txns'::regclass and tgname = 'trg_wallet_txn_fill_bonus' and tgenabled = 'O';
  v_msg := v_msg || case when v_n = 1 then '✅' else '🔴' end || ' ② 填贈點的觸發器' || E'\n';

  -- ③ 帳本不可修改的觸發器有打開回來（回填時暫停過）
  select count(*) into v_n from pg_trigger
   where tgrelid = 'public.wallet_txns'::regclass and tgname = 'trg_txn_no_update' and tgenabled = 'O';
  v_msg := v_msg || case when v_n = 1 then '✅' else '🔴' end || ' ③ 帳本不可修改的觸發器已打開' || E'\n';

  -- ④ 每個錢包：贈點 0 ≤ 贈點 ≤ 總餘額，而且總餘額跟 wallets.balance 一樣
  select count(*) into v_n from (
    select w.member_id, w.balance, coalesce(sum(t.amount), 0) tot, coalesce(sum(t.bonus_amount), 0) bon
      from public.wallets w left join public.wallet_txns t on t.member_id = w.member_id and t.status = 'completed'
     group by w.member_id, w.balance) s
   where s.bon < 0 or s.bon > s.tot or s.tot <> s.balance;
  v_msg := v_msg || case when v_n = 0 then '✅' else '🔴' end
        || ' ④ 兩格對不上的錢包 ' || v_n || E' 個（要 0）\n';

  -- ⑤ 儲值贈點那幾筆（promo_expense 正數）全部整筆算贈點
  select count(*) filter (where bonus_amount = amount), count(*) into v_n, v_m
    from public.wallet_txns where counter_account = 'promo_expense' and amount > 0;
  v_msg := v_msg || case when v_n = v_m and v_m > 0 then '✅' else '🔴' end
        || ' ⑤ 儲值贈點 ' || v_n || ' / ' || v_m || E' 筆整筆算贈點\n';

  -- ⑥ 正對照：回填真的有把扣點分出贈點（測試帳號儲值過有贈點的方案又消費過，應該 > 0）
  select count(*) into v_n from public.wallet_txns where amount < 0 and bonus_amount < 0;
  v_msg := v_msg || case when v_n > 0 then '✅' else '🔴' end
        || ' ⑥ 有贈點部分的扣點 ' || v_n || E' 筆（要 > 0，否則回填沒作用）\n';

  -- ⑦ 三支新函式前端都叫不到（明確授權與 PUBLIC 都沒有）
  select count(*) into v_n
    from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('_wallet_bonus_part', '_wallet_txn_fill_bonus', 'wallet_pools')
     and a.privilege_type = 'EXECUTE'
     and a.grantee in (0, 'anon'::regrole::oid, 'authenticated'::regrole::oid);
  v_msg := v_msg || case when v_n = 0 then '✅' else '🔴' end
        || ' ⑦ 前端（PUBLIC／anon／authenticated）叫得到的 ' || v_n || ' 個（要 0）';

  perform set_config('migi.v', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 驗證段沒有跑到') as "驗證";
