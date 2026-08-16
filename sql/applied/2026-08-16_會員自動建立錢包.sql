-- ============================================================
-- 會員建立時自動開錢包（並回填既有缺漏）
-- ------------------------------------------------------------
-- 【問題】
--   checkout_tx 找不到 wallets 記錄會直接拋例外：
--       select balance into v_bal from wallets where member_id = ... for update;
--       if v_bal is null then raise exception 'member % 沒有錢包', ...
--   而 members 上沒有任何觸發器會建錢包，register_member_tx 也沒建。
--   結果：新會員在第一次儲值之前**完全無法結帳** ——
--   即使是純付現金、一點都不折，也會被擋下。
--   2026-08-16 測試04 就撞到（0 點、純現金 $150 的檯費，結不掉）。
--
--   對照組：topup_tx 找不到錢包時會自己 insert 一筆。
--   兩支碰錢的函式對同一件事有兩種處理方式，這種不一致遲早出事。
--
-- 【為什麼用觸發器，不改 checkout_tx】
--   checkout_tx 是所有收款的唯一入口，為了補一個 null 檢查去動它，
--   風險與收益不成比例。而且「會員一定有錢包」本來就該是資料層的保證，
--   不該由每個呼叫端各自處理 —— 用觸發器一次解決，任何建立管道都涵蓋。
--
-- 【欄位依據】
--   wallets(member_id uuid PRIMARY KEY references members(id),
--           org_id uuid not null, balance bigint not null default 0
--           check (balance >= 0), updated_at timestamptz)
--   member_id 是主鍵 → ON CONFLICT DO NOTHING 可安全用於重複執行。
--
-- 【冪等】
--   回填與觸發器建立都可重複執行。
-- ============================================================


-- ============================================================
-- ① 回填：現有會員缺錢包的一律補上（餘額 0）
--    只補沒有的，不動任何既有餘額。
-- ============================================================
insert into wallets (member_id, org_id, balance)
select m.id, m.org_id, 0
  from members m
 where not exists (select 1 from wallets w where w.member_id = m.id)
on conflict (member_id) do nothing;


-- ============================================================
-- ② 觸發器函式：新會員一建立就開錢包
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_wallet_for_member()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  insert into wallets (member_id, org_id, balance)
  values (new.id, new.org_id, 0)
  on conflict (member_id) do nothing;
  return new;
end $function$;

COMMENT ON FUNCTION public.create_wallet_for_member IS
  '會員建立時自動開一個餘額 0 的錢包。checkout_tx 找不到錢包會拋例外，'
  '而「會員一定有錢包」該是資料層的保證，不該由每個呼叫端各自處理。';

drop trigger if exists trg_members_wallet on members;
create trigger trg_members_wallet
  after insert on members
  for each row execute function create_wallet_for_member();


-- ============================================================
-- 驗證（單一 SELECT）
-- ------------------------------------------------------------
-- 期待：
--   缺錢包的會員   = 0
--   觸發器在       = 1
--   測試04有錢包   = true   （就是撞到這個問題的那個帳號）
--   錢包總數       ≥ 會員總數
--   餘額有異動的   = 回填不該改到任何既有餘額，
--                    這欄是「餘額 > 0 的錢包數」，供你和先前的認知比對
-- ============================================================
select
  (select count(*) from members m
    where not exists (select 1 from wallets w where w.member_id = m.id))  as 缺錢包的會員,

  (select count(*) from pg_trigger
    where tgname = 'trg_members_wallet' and not tgisinternal)             as 觸發器在,

  (select exists (
     select 1 from wallets w join members m on m.id = w.member_id
      where m.display_name = '測試04'))                                   as 測試04有錢包,

  (select count(*) from wallets)                                          as 錢包總數,
  (select count(*) from members)                                          as 會員總數,
  (select count(*) from wallets where balance > 0)                        as 餘額大於零的錢包;
