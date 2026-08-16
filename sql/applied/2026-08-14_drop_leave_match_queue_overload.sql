-- ============================================================
-- 移除 leave_match_queue_tx 的孤兒舊版（3 參數）
-- 產生日期：2026-08-14
--
-- 背景：
--   資料庫裡同時存在兩個版本，違反 CLAUDE.md 硬規則 2：
--     leave_match_queue_tx(uuid, uuid, uuid)              ← 舊版，本檔要刪
--     leave_match_queue_tx(uuid, uuid, uuid, text)        ← 新版，實際使用中
--
-- 安全性確認（2026-08-14 檢查過）：
--   migi-web/src/lib/social.js:120 的 leaveMatchQueue() 一律傳四個具名參數
--   （p_reason 為 null 時仍會送出），PostgREST 依參數名解析，只會打到新版。
--   migi-pos、migi-admin 皆無呼叫點。故舊版為孤兒，刪除不影響任何功能。
--
-- 風險：低。若日後有程式只傳三個參數，會改為找不到函式而明確報錯，
--       比現在「靜默寫不進 leave_reason」好抓。
-- ============================================================

DROP FUNCTION IF EXISTS public.leave_match_queue_tx(uuid, uuid, uuid);

-- ---------- 驗證：跑完應只剩一列（4 參數版） ----------
select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as 剩餘版本
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'leave_match_queue_tx';
