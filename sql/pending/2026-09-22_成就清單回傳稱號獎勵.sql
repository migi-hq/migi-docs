-- ════════════════════════════════════════════════════════════════════
-- 2026-09-22 成就清單回傳「稱號獎勵」（使用者要求：META 成就詳情要顯示可以獲得稱號）
--
-- get_my_achievements_tx 每一列多一個 grants_title。
-- ⚠ silhouette 且還沒解鎖的一律回 null —— 跟名稱、說明、條件同一套遮蔽，
--   稱號寫出來等於把隱藏成就是什麼講出來。
-- ⚠ 簽名不變 ⇒ 只換函式本體，不丟 GRANT。
-- ⚠ expand-safe：舊版前端不讀這個鍵，先跑後推都可以。
-- ════════════════════════════════════════════════════════════════════

do $$
declare v_old text; v_new text;
begin
  v_old := pg_get_functiondef('public.get_my_achievements_tx()'::regprocedure);
  v_new := regexp_replace(v_old,
    '(a\.is_signature\s+as signature,)',
    E'\\1\n      case when a.visibility = ''silhouette''\n                and coalesce(ma.status, ''locked'') <> ''unlocked''\n           then null else a.grants_title end                      as grants_title,');
  -- 換不到就整份不要提交
  if v_new = v_old then raise exception '找不到 is_signature 那一行，整份回滾'; end if;
  execute v_new;
end $$;

-- ════════════════════════════════════════════════════════════════════
-- 驗證（單一 SELECT，不 raise —— 硬規則 1.8）
-- ════════════════════════════════════════════════════════════════════
select * from (
  select 1 as n, '① 函式只有一個版本' as 項目,
         case when (select count(*) from pg_proc where proname = 'get_my_achievements_tx') = 1 then '✅' else '🔴' end as 結果
  union all
  select 2, '② 本體有回 grants_title',
         case when pg_get_functiondef('public.get_my_achievements_tx()'::regprocedure) ~ 'as grants_title,' then '✅' else '🔴' end
  union all
  select 3, '③ 稱號也套用隱藏遮蔽（跟名稱同一套）',
         case when pg_get_functiondef('public.get_my_achievements_tx()'::regprocedure)
                   ~ 'silhouette''\s+and coalesce\(ma\.status, ''locked''\) <> ''unlocked''\s+then null else a\.grants_title'
              then '✅' else '🔴' end
  union all
  select 4, '④ authenticated 還叫得動',
         case when has_function_privilege('authenticated', 'public.get_my_achievements_tx()', 'execute') then '✅' else '🔴' end
  union all
  select 5, '⑤ 正對照：線上有幾枚會發稱號（應為 2）',
         case when (select count(*) from achievements where deleted_at is null and is_active and grants_title is not null) = 2
              then '✅' else '🔴' end
) v order by n;
