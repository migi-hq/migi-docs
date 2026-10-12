-- ============================================================================
-- 2026-10-13 天胡不疊（使用者拍板，docs/02-POS與開桌/桌邊記分板設計.md 8.5 節）
-- 規則：天胡不疊門清、門清自摸、自摸、邊張單吊中洞、平胡；莊家、連莊、花牌照算。
--   天胡 ＋ 莊家（不含連莊、花）：原本 24 ＋ 3（門清自摸）＋ 1 ＝ 28 台 → 改完 24 ＋ 1 ＝ 25 台
--
-- 🔴 不可以只改資料：tbl_submit_hand_tx 先自動補「自摸」1 台、再檢查互斥 ——
--   只把自摸加進天胡的互斥的話，每次報天胡都會被補上自摸、再被互斥檢查整筆退回。
--   ⇒ 自動補自摸的條件從「寫死沒選門清自摸」改成「選了的牌型都沒有跟自摸互斥（雙向看 conflicts）」，
--     門清自摸本來就把自摸寫在自己的互斥裡，改完它也走同一條路。
-- 前端同一批改：migi-table/src/lib/rules.js 的 blocksZimo()／patternTai()、lib/engine.js（教學模式）。
-- ⚠ 驗證段不用 raise 印訊息（硬規則 1.8）；行為測試在 sql/checks/2026-10-13_驗天胡不疊.sql。
-- ============================================================================

-- ① 主檔：天胡跟這五個互斥（保留原本已有的，去重）
update public.scoring_patterns
   set conflicts = array(select distinct x from unnest(coalesce(conflicts, '{}') || array['menqing','menqing_tsumo','zimo','duting','pinghu']) x order by x)
 where code = 'tianhu';

-- ② 後端：自動補自摸的條件
do $$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('public.tbl_submit_hand_tx(text,text,smallint,jsonb,integer)'::regprocedure);

  v_new := replace(v_def,
    $s$if p_result = 'tsumo' and not ('zimo' = any(v_codes)) and not ('menqing_tsumo' = any(v_codes)) then$s$,
    $s$if p_result = 'tsumo' and not ('zimo' = any(v_codes)) and not exists (
         select 1 from scoring_patterns a
          where (a.code = any(v_codes) and 'zimo' = any(a.conflicts))
             or (a.code = 'zimo' and a.conflicts && v_codes)) then$s$);
  if v_new = v_def then raise exception 'tbl_submit_hand_tx：找不到自動補自摸那一行'; end if;

  -- 兩處註解跟著改（用文字描述舊寫法，不寫出它 —— 硬規則 3.5）
  v_def := v_new;
  v_new := replace(v_def,
    $s$-- 自摸：沒選門清自摸就自動帶自摸 1 台$s$,
    $s$-- 自摸：選了的牌型都沒有跟自摸互斥（雙向看 conflicts）才自動帶自摸 1 台 —— 門清自摸、天胡都靠這一條（2026-10-13 天胡不疊）$s$);
  if v_new = v_def then raise exception 'tbl_submit_hand_tx：找不到自動補自摸的註解'; end if;
  v_def := v_new;
  v_new := replace(v_def,
    $s$tsumo  我自摸（要選牌型；沒選門清自摸就自動帶自摸 1 台。$s$,
    $s$tsumo  我自摸（要選牌型；選的牌型跟自摸互斥的話不帶，例如門清自摸、天胡，其餘自動帶自摸 1 台。$s$);
  if v_new = v_def then raise exception 'tbl_submit_hand_tx：找不到檔頭說明'; end if;

  execute v_new;   -- CREATE OR REPLACE：簽名沒變，授權不會掉
end $$;

-- ============================================================================
-- 驗證（單一 SELECT）
-- ============================================================================
select concat_ws(E'\n',
  case when (select conflicts @> array['menqing','menqing_tsumo','zimo','duting','pinghu'] from scoring_patterns where code = 'tianhu')
       then '✅ ① 天胡跟 門清／門清自摸／自摸／邊張單吊中洞／平胡 互斥（' ||
            (select array_to_string(conflicts, '、') from scoring_patterns where code = 'tianhu') || '）'
       else '🔴 ① 天胡的互斥沒補到' end,
  case when (select result_only = 'tsumo' and dealer_only from scoring_patterns where code = 'tianhu')
       then '✅ ① 天胡照舊只有莊家自摸才有（沒被動到）' else '🔴 ① 天胡的自摸／莊家限制被動到了' end,
  case when pg_get_functiondef('public.tbl_submit_hand_tx(text,text,smallint,jsonb,integer)'::regprocedure) ~ '''zimo'' = any\(a\.conflicts\)'
            and pg_get_functiondef('public.tbl_submit_hand_tx(text,text,smallint,jsonb,integer)'::regprocedure) !~ 'not \(''menqing_tsumo'' = any\(v_codes\)\)'
       then '✅ ② 自動補自摸改成看互斥（寫死的門清自摸那一句不在了）' else '🔴 ② 後端沒改到' end,
  case when (select count(*) from pg_proc where proname = 'tbl_submit_hand_tx' and pronamespace = 'public'::regnamespace) = 1
       then '✅ ② tbl_submit_hand_tx 只有一個版本' else '🔴 ② 多出一個版本' end,
  case when has_function_privilege('anon', 'public.tbl_submit_hand_tx(text,text,smallint,jsonb,integer)', 'execute')
       then '✅ ② 平板照樣叫得到（授權沒掉）' else '🔴 ② 平板叫不到了' end
) as "驗證";
