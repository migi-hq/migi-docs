-- 【已執行】current_org_id() 加 SECURITY DEFINER，修復 RLS 無限遞迴（stack depth limit exceeded）。寫任何 RLS helper 函式前的範本。
-- ============================================================
-- 修復 current_org_id() 遞迴（stack depth limit exceeded）
-- 病因：函式沒有 SECURITY DEFINER，查 staff/members 時受 RLS 限制
--       → 觸發那些表的 policy → policy 又呼叫 current_org_id() → 無限遞迴
-- 解法：加 SECURITY DEFINER，讓函式查表時繞過 RLS（Supabase 官方推薦寫法）
-- Supabase SQL Editor 執行
-- ============================================================

CREATE OR REPLACE FUNCTION public.current_org_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER                          -- ★關鍵：繞過 RLS，斷開遞迴
SET search_path = public                  -- 安全：固定 search_path，防注入
AS $function$
  select coalesce(
    (select org_id from staff   where auth_uid = auth.uid() and deleted_at is null limit 1),
    (select org_id from members where line_user_id = auth.jwt()->>'sub' and deleted_at is null limit 1)
  );
$function$;

-- 確認：is_security_definer 應該變 true
SELECT proname, prosecdef AS is_security_definer
FROM pg_proc WHERE proname = 'current_org_id' AND prokind = 'f';
