/* ============================================================
   查：pos_checkout_with_topup_tx 用什麼認回剛建的儲值單
   2026-08-25 · 唯讀

   上一支查詢撈到了
       update topup_orders
          set cash_received = p_topup_cash_received,
              change_given  = p_topup_change_given
   但**沒撈到 where** —— 我的正則只比對含關鍵字的行，
   而 where 那行不含任何一個關鍵字。

   ⚠ 這正是「只看片段就下判斷」的老毛病（2026-08-20 在 join_session_tx
     上連續判斷錯兩次，都是因為只看片段）。
     這次改成**撈上下文**：以 update 那行為錨點，前後各抓幾行。

   ✅ 順帶已確認：topup_orders **沒有**類似 order_payments 的
      cash_fields_only_for_cash 自洽約束（只有 amount_twd > 0、
      points > 0、bonus_points >= 0、pay_method 白名單、status 白名單）。
      → 補實收找零不必滿足「change = received − amount」。
   ============================================================ */

with src as (
  select t.n, t.ln
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    cross join lateral unnest(string_to_array(pg_get_functiondef(p.oid), E'\n'))
                with ordinality as t(ln, n)
   where ns.nspname = 'public'
     and p.proname = 'pos_checkout_with_topup_tx'
),
anchor as (
  select min(n) as n from src where ln ~* 'update\s+topup_orders'
)
select s.n as 行號, s.ln as 原始碼
  from src s, anchor a
 where a.n is not null
   and s.n between a.n - 6 and a.n + 10
 order by s.n;
