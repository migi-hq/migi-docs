/* ============================================================
   行為測試：錢包流水記贈點部分（trg_wallet_txn_fill_bonus ＋ _wallet_bonus_part）
   2026-10-22 · 先跑 sql/pending/2026-10-22_錢包流水記贈點部分.sql 再跑這份
   ⚠ 整份在一個交易裡造樣本，最後 raise 'migi_rollback' 全部退掉 —— 一列都不留（硬規則 1）。
     結果從 exception 處理器存進設定，最後那支 SELECT 讀出來（硬規則 3.9）。
   ============================================================ */
do $$
declare
  v_mem   uuid;
  v_org   uuid;
  v_store uuid;
  v_msg   text := '';
  v_tot   bigint;
  v_b     bigint;
  v_id_principal uuid;
  v_id_promo     uuid;
  v_id_spend     uuid;
  v_id_promo2    uuid;
  r       jsonb;
  v_ok    boolean;
begin
  -- 樣本：一位有錢包的測試帳號（找不到要出聲，不可以安靜跳過 —— 硬規則 3.57）
  select w.member_id, w.org_id into v_mem, v_org
    from wallets w join members m on m.id = w.member_id
   where m.is_test and m.deleted_at is null
   order by m.created_at limit 1;
  if v_mem is null then
    perform set_config('migi.t', '🔴 找不到有錢包的測試帳號，整份測不了', true);
    raise exception 'migi_rollback';
  end if;
  select id into v_store from stores where org_id = v_org order by code limit 1;

  -- ⓪ 歸零：扣掉他現有的全部餘額（贈點先扣）⇒ 兩格都從 0 開始
  select coalesce(sum(amount), 0) into v_tot from wallet_txns where member_id = v_mem and status = 'completed';
  if v_tot > 0 then
    insert into wallet_txns(org_id, member_id, type, amount, note)
    values (v_org, v_mem, 'adjust', -v_tot, '測試歸零');
  end if;
  r := wallet_pools(v_mem);
  v_msg := v_msg || case when (r->>'balance')::bigint = 0 and (r->>'bonus')::bigint = 0 then '✅' else '🔴' end
        || ' ⓪ 歸零後 ' || r::text || E'\n';

  -- ⓐ 儲值 1000 ＋ 贈點 150
  insert into wallet_txns(org_id, member_id, type, amount, counter_account, note)
  values (v_org, v_mem, 'topup', 1000, 'liability', '測試本金') returning id, bonus_amount into v_id_principal, v_b;
  insert into wallet_txns(org_id, member_id, type, amount, counter_account, note)
  values (v_org, v_mem, 'adjust', 150, 'promo_expense', '測試贈點') returning id into v_id_promo;
  r := wallet_pools(v_mem);
  v_msg := v_msg || case when v_b = 0 and (r->>'bonus')::bigint = 150 and (r->>'principal')::bigint = 1000 then '✅' else '🔴' end
        || ' ⓐ 本金那筆贈點部分 ' || v_b || '，兩格 ' || r::text || E'（要 150／1000）\n';

  -- ⓑ 扣 100：全部從贈點
  insert into wallet_txns(org_id, member_id, type, amount, counter_account, note)
  values (v_org, v_mem, 'spend', -100, 'liability', '測試扣點') returning bonus_amount into v_b;
  v_msg := v_msg || case when v_b = -100 then '✅' else '🔴' end || ' ⓑ 扣 100 的贈點部分 ' || v_b || E'（要 -100）\n';

  -- ⓒ 扣 300：贈點只剩 50，其餘 250 扣本金
  insert into wallet_txns(org_id, member_id, type, amount, counter_account, note)
  values (v_org, v_mem, 'spend', -300, 'liability', '測試扣點') returning id, bonus_amount into v_id_spend, v_b;
  r := wallet_pools(v_mem);
  v_msg := v_msg || case when v_b = -50 and (r->>'bonus')::bigint = 0 and (r->>'principal')::bigint = 750 then '✅' else '🔴' end
        || ' ⓒ 扣 300 的贈點部分 ' || v_b || '，兩格 ' || r::text || E'（要 -50，0／750）\n';

  -- ⓓ 沖正 ⓒ：原單扣了 50 贈點 ⇒ 還 50 贈點、250 本金
  insert into wallet_txns(org_id, member_id, type, amount, counter_account, reverses_txn_id, note)
  values (v_org, v_mem, 'reversal', 300, 'reversal', v_id_spend, '測試沖正') returning bonus_amount into v_b;
  r := wallet_pools(v_mem);
  v_msg := v_msg || case when v_b = 50 and (r->>'bonus')::bigint = 50 and (r->>'principal')::bigint = 1000 then '✅' else '🔴' end
        || ' ⓓ 沖正扣點還回 ' || v_b || ' 贈點，兩格 ' || r::text || E'（要 50，50／1000）\n';

  -- ⓔ 再送 200 贈點，然後作廢它（沖正一筆贈點進帳 ⇒ 扣回 200 贈點）
  insert into wallet_txns(org_id, member_id, type, amount, counter_account, note)
  values (v_org, v_mem, 'adjust', 200, 'promo_expense', '測試贈點2') returning id into v_id_promo2;
  insert into wallet_txns(org_id, member_id, type, amount, counter_account, reverses_txn_id, note)
  values (v_org, v_mem, 'reversal', -200, 'promo_expense', v_id_promo2, '測試作廢贈點') returning bonus_amount into v_b;
  r := wallet_pools(v_mem);
  v_msg := v_msg || case when v_b = -200 and (r->>'bonus')::bigint = 50 then '✅' else '🔴' end
        || ' ⓔ 作廢贈點扣回 ' || v_b || '，兩格 ' || r::text || E'（要 -200，贈點 50）\n';

  -- ⓕ 沖正本金那筆（原單贈點 0）⇒ 本金 1000 全扣、贈點不動
  insert into wallet_txns(org_id, member_id, type, amount, counter_account, reverses_txn_id, note)
  values (v_org, v_mem, 'reversal', -1000, 'liability', v_id_principal, '測試作廢本金') returning bonus_amount into v_b;
  r := wallet_pools(v_mem);
  v_msg := v_msg || case when v_b = 0 and (r->>'bonus')::bigint = 50 and (r->>'principal')::bigint = 0 then '✅' else '🔴' end
        || ' ⓕ 作廢本金的贈點部分 ' || v_b || '，兩格 ' || r::text || E'（要 0，50／0）\n';

  -- ⓖ 底線：本金不夠扣的差額一定由贈點補（現在 贈點 50／本金 0）
  insert into wallet_txns(org_id, member_id, type, amount, counter_account, note)
  values (v_org, v_mem, 'topup', 40, 'liability', '測試本金40') returning id into v_id_principal;
  -- 先部分作廢 30（原單贈點 0、本金夠）⇒ 只扣本金
  insert into wallet_txns(org_id, member_id, type, amount, counter_account, reverses_txn_id, note)
  values (v_org, v_mem, 'reversal', -30, 'liability', v_id_principal, '測試作廢本金30') returning bonus_amount into v_b;
  r := wallet_pools(v_mem);
  v_msg := v_msg || case when v_b = 0 and (r->>'bonus')::bigint = 50 and (r->>'principal')::bigint = 10 then '✅' else '🔴' end
        || ' ⓖ-1 作廢 30 本金，贈點部分 ' || v_b || '，兩格 ' || r::text || E'（要 0，50／10）\n';
  -- 再作廢 40：本金只剩 10 ⇒ 其餘 30 一定由贈點補，本金不可以變負
  insert into wallet_txns(org_id, member_id, type, amount, counter_account, reverses_txn_id, note)
  values (v_org, v_mem, 'reversal', -40, 'liability', v_id_principal, '測試作廢本金40') returning bonus_amount into v_b;
  r := wallet_pools(v_mem);
  v_msg := v_msg || case when v_b = -30 and (r->>'bonus')::bigint = 20 and (r->>'principal')::bigint = 0 then '✅' else '🔴' end
        || ' ⓖ-2 本金不夠時贈點補 ' || v_b || '，兩格 ' || r::text || E'（要 -30，20／0）\n';

  -- ⓗ 呼叫端送的值一律覆寫：送 -9（大於整筆 -5、也不合規則）⇒ 照規則算成 -5（贈點還有 20）
  insert into wallet_txns(org_id, member_id, type, amount, counter_account, bonus_amount, note)
  values (v_org, v_mem, 'spend', -5, 'liability', -9, '測試送亂值') returning bonus_amount into v_b;
  v_msg := v_msg || case when v_b = -5 then '✅' else '🔴' end || ' ⓗ 送 -9 被覆寫成 ' || v_b || E'（要 -5）\n';

  -- ⓘ 約束本身：直接比對定義，證明它在擋「贈點部分超過整筆」與「正負號相反」
  select (pg_get_constraintdef(oid) ~ 'bonus_amount >= 0' or pg_get_constraintdef(oid) ~ 'BETWEEN 0 AND amount')
    into v_ok from pg_constraint
   where conrelid = 'public.wallet_txns'::regclass and conname = 'chk_bonus_amount_within';
  v_msg := v_msg || case when coalesce(v_ok, false) then '✅' else '🔴' end
        || ' ⓘ 約束 chk_bonus_amount_within ' || coalesce((select pg_get_constraintdef(oid) from pg_constraint
             where conrelid = 'public.wallet_txns'::regclass and conname = 'chk_bonus_amount_within'), '（不存在）') || E'\n';

  -- ⓙ 真的叫 topup_tx：贈點那筆整筆算贈點、本金那筆 0（贈點由 topup_plans 決定）
  r := topup_tx(v_mem, v_store, 1000, 1000, 'cash', 'migi-test-bonus-' || gen_random_uuid()::text);
  select bonus_amount into v_b from wallet_txns where id = (r->>'txn_id')::uuid;
  v_msg := v_msg || case when v_b = 0 then '✅' else '🔴' end || ' ⓙ-1 topup_tx 本金那筆贈點部分 ' || v_b || E'（要 0）\n';
  if (r->>'bonus_txn_id') is null then
    v_msg := v_msg || '⚪ ⓙ-2 這間店儲值 1000 沒有贈點（bonus_points = ' || coalesce(r->>'bonus_points', '?') || '），測不到贈點那筆';
  else
    select bonus_amount into v_b from wallet_txns where id = (r->>'bonus_txn_id')::uuid;
    v_msg := v_msg || case when v_b = (r->>'bonus_points')::bigint then '✅' else '🔴' end
          || ' ⓙ-2 topup_tx 贈點那筆 ' || v_b || '（要等於 bonus_points ' || (r->>'bonus_points') || '）';
  end if;

  perform set_config('migi.t', v_msg, true);
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm <> 'migi_rollback' then
    v_msg := v_msg || E'\n🔴 中途出錯：' || sqlerrm;
  end if;
  perform set_config('migi.t', v_msg, false);
end $$;

select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有測試訊息') as "行為測試";
