/* ============================================================
   報表檢視表 v_real_wallet_txns 補上 bonus_amount
   2026-10-27 · 錯誤儀表 ⑫ 抓到

   10-22 錢包流水加了 wallet_txns.bonus_amount（每筆其中幾點是贈點），
   而 v_real_wallet_txns 的欄位是寫死的清單 ⇒ 報表查不到這一欄、也不會報錯。
   日後開發票（只開本金部分）與對帳都要讀它。

   做法：create or replace view，**只在最後面加一欄**，其餘逐字照線上版本
   （pg_get_viewdef 撈出來的）。Postgres 允許在尾端加欄位、不允許改順序。
   ⚠ create or replace 會保留權限：前端角色原本就讀不到（⑯），這份不碰 grant。
   ============================================================ */

create or replace view public.v_real_wallet_txns as
 select x.id,
    x.org_id,
    x.store_id,
    x.served_store_id,
    x.member_id,
    x.type,
    x.amount,
    x.status,
    x.counter_account,
    x.reverses_txn_id,
    x.idempotency_key,
    x.external_ref,
    x.ref_table,
    x.ref_id,
    x.staff_id,
    x.note,
    x.created_at,
    x.created_by,
    x.bonus_amount
   from wallet_txns x
     join orgs o on o.id = x.org_id
  where x.created_at >= coalesce(o.live_from, 'infinity'::timestamp with time zone)
    and not (exists ( select 1 from stores s where s.id = x.store_id and s.is_test))
    and not (exists ( select 1 from members m where m.id = x.member_id and m.is_test));

/* ── 驗證（單一 SELECT，不 raise）──────────────────────── */
select
  case when exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'v_real_wallet_txns' and column_name = 'bonus_amount')
       then '✅ ① 檢視表有 bonus_amount' else '🔴 ① 檢視表沒有 bonus_amount' end
  || E'\n' ||
  case when (select count(*) from information_schema.columns
              where table_schema = 'public' and table_name = 'v_real_wallet_txns') = 19
       then '✅ ② 欄位 19 個（原本 18 ＋ 1）' else '🔴 ② 欄位數不是 19' end
  || E'\n' ||
  case when not has_table_privilege('anon', 'public.v_real_wallet_txns', 'SELECT')
        and not has_table_privilege('authenticated', 'public.v_real_wallet_txns', 'SELECT')
       then '✅ ③ 前端角色仍然讀不到' else '🔴 ③ 前端角色讀得到了' end
  || E'\n' ||
  coalesce((select '🔴 ④ 還有漏的：' || string_agg(t.column_name, '、')
              from information_schema.columns t
             where t.table_schema = 'public' and t.table_name = 'wallet_txns'
               and not exists (select 1 from information_schema.columns v
                                where v.table_schema = 'public' and v.table_name = 'v_real_wallet_txns'
                                  and v.column_name = t.column_name)
            having count(*) > 0),
           '✅ ④ wallet_txns 的欄位都在檢視表裡')
  as "驗證";
