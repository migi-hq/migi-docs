-- ============================================================
-- 撈 join_session_tx 的線上實際定義（唯讀，不改任何東西）
-- ------------------------------------------------------------
-- 為什麼要改它：
--   首次結帳走 join_session_tx，而它**沒有 items 參數** ——
--   只收自己算出來的檯費。所以開桌時加的餐飲、商品、儲值
--   全部不會進 orders，而前端送過去的 payments 卻含了那些金額，
--   checkout_tx 第 6 步「收款驗證」必然失敗。
--   （加購那條路走 pos_addon_checkout_tx，有送 items，所以沒事。）
--
-- 依 CLAUDE.md 硬規則 3：改既有函式一律先 pg_get_functiondef 撈線上版，
-- sql/applied/ 只是「當時交付的版本」，不是線上鏡像。
--
-- 依硬規則 2：加參數會改變簽名，改版時必須先 DROP FUNCTION IF EXISTS，
-- 否則會建出多載版本。所以本查詢也一併列出**目前有幾個版本**，
-- 確認現在是不是只有一個。
--
-- 依踩過的坑第 19 條：SQL Editor 一次跑多個 SELECT 只顯示最後一個，
-- 所以本檔只有一個 SELECT。
-- ============================================================

select
  p.oid::regprocedure                                            as 簽名,
  case p.prosecdef when true then 'DEFINER' else 'INVOKER' end   as 安全模式,

  -- 確認沒有多載（改簽名前要知道現在幾個版本）
  (select count(*)
     from pg_proc p2 join pg_namespace n2 on n2.oid = p2.pronamespace
    where n2.nspname = 'public' and p2.proname = 'join_session_tx')  as join版本數,

  -- 儲值要獨立成一步，順便撈 topup 相關函式的簽名，省一趟往返
  (select string_agg(p3.oid::regprocedure::text, E'\n' order by p3.proname)
     from pg_proc p3 join pg_namespace n3 on n3.oid = p3.pronamespace
    where n3.nspname = 'public'
      and p3.proname in ('topup_tx', 'wallet_topup_tx', 'topup_void_tx'))  as 儲值函式簽名,

  pg_get_functiondef(p.oid)                                      as 完整定義

from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'join_session_tx';
