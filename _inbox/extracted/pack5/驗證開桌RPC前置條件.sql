-- 【診斷工具】檢查開桌 RPC 依賴的欄位/函式/約束是否齊全。改動桌台相關結構後可重跑驗證。
-- ============================================================
-- 執行 M2 開桌 RPC 前的前置驗證
-- 確認 v3 SQL 用到的欄位／函式／約束是否都存在
-- Supabase SQL Editor 整段貼上，只會回一個結果表
-- ★「缺」的項目代表那段程式會壞，要先處理
-- ============================================================
SELECT '① orders 欄位' AS 檢查項,
       coalesce((SELECT string_agg(column_name, ', ' ORDER BY column_name)
                 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='orders'
                   AND column_name IN ('session_id','table_id','channel','entity_id')), '❌全缺') AS 結果,
       '需要 session_id, table_id, channel, entity_id' AS 應有
UNION ALL
SELECT '② stores.entity_id',
       coalesce((SELECT column_name FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='stores' AND column_name='entity_id'), '❌缺'),
       'join_session_tx 要用'
UNION ALL
SELECT '③ members 欄位',
       coalesce((SELECT string_agg(column_name, ', ' ORDER BY column_name)
                 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='members'
                   AND column_name IN ('display_name','rank','avatar_source','avatar_photo_path')), '❌全缺'),
       '需要 display_name, rank, avatar_source, avatar_photo_path'
UNION ALL
SELECT '④ tables 欄位',
       coalesce((SELECT string_agg(column_name, ', ' ORDER BY column_name)
                 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='tables'
                   AND column_name IN ('label','area','is_active','org_id','store_id')), '❌全缺'),
       '需要 label, area, is_active, org_id, store_id'
UNION ALL
SELECT '⑤ table_sessions 欄位',
       coalesce((SELECT string_agg(column_name, ', ' ORDER BY column_name)
                 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='table_sessions'
                   AND column_name IN ('promoted_by_staff_id','open_method','planned_minutes','mode','status')), '❌全缺'),
       '需要 promoted_by_staff_id, open_method, planned_minutes, mode, status'
UNION ALL
SELECT '⑥ stake_levels 表',
       coalesce((SELECT 'label 欄位存在' FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='stake_levels' AND column_name='label'), '❌表或欄位缺'),
       'get_session_tx 要用'
UNION ALL
SELECT '⑦ _blocked_between 函式',
       coalesce((SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                 WHERE n.nspname='public' AND proname='_blocked_between'), '❌缺'),
       'check_session_blocks_tx 要用'
UNION ALL
SELECT '⑧ join_type 約束「實際名稱」',
       coalesce((SELECT conname FROM pg_constraint
                 WHERE conrelid='public.session_players'::regclass AND contype='c'
                   AND pg_get_constraintdef(oid) ILIKE '%join_type%'), '❌查無'),
       '★若不是 session_players_join_type_check，v3 的 DROP 會失效'
UNION ALL
SELECT '⑨ 同桌重複 open 場次',
       coalesce((SELECT count(*)::text || ' 桌有多筆 open（建唯一索引會失敗）'
                 FROM (SELECT table_id FROM table_sessions
                        WHERE status='open' AND deleted_at IS NULL
                        GROUP BY table_id HAVING count(*)>1) x), '0（安全）'),
       '★>0 要先清理才能建 uq_sessions_open_table'
UNION ALL
SELECT '⑩ 舊收費函式 PUBLIC 權限',
       coalesce((SELECT string_agg(proname || '=' || coalesce(array_to_string(proacl,','),'預設(PUBLIC可執行)'), ' | ')
                 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                 WHERE n.nspname='public' AND proname IN ('charge_matched_tx','charge_private_tx')), '查無'),
       '★顯示「預設」代表 PUBLIC 仍可執行，只 REVOKE anon/authenticated 無效';
