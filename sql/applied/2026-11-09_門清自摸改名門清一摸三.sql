/* ============================================================
   「門清自摸」改名「門清一摸三」（2026-11-09 使用者：記分板、引擎、相關成就都改）

   · 只改給人看的名字；代碼 menqing_tsumo 不動（舊局 hands.patterns、成就事件 pattern_menqing_tsumo 都靠它）
   · 牌型主檔 scoring_patterns.label ⇒ 計分板選牌型、確認卡、紀錄頁一起變（都讀這一欄）
   · 成就 tile_02 的名稱一起改；說明「自己做完，自己摸到」不動
   · 台數 3 台不變
   ============================================================ */

update public.scoring_patterns set label = '門清一摸三', updated_at = now() where code = 'menqing_tsumo';
update public.achievements set name = '門清一摸三' where code = 'tile_02' and name = '門清自摸';

/* ── 驗證（單一 SELECT；不用 raise）──────────────────────────── */
select
  case when (select label from scoring_patterns where code = 'menqing_tsumo') = '門清一摸三' then '✅' else '🔴' end || ' ① 牌型主檔改名' || E'\n' ||
  case when (select tai from scoring_patterns where code = 'menqing_tsumo') = 3 then '✅' else '🔴' end || ' ② 還是 3 台' || E'\n' ||
  case when (select name from achievements where code = 'tile_02') = '門清一摸三' then '✅' else '🔴' end || ' ③ 成就 tile_02 改名' || E'\n' ||
  case when not exists (select 1 from scoring_patterns where label like '%門清自摸%')
        and not exists (select 1 from achievements where name like '%門清自摸%') then '✅' else '🔴' end || ' ④ 主檔與成就裡沒有舊名字了' || E'\n' ||
  case when (select label from scoring_patterns where code = 'menqing') = '門清' then '✅' else '🔴' end || ' ⑤ 正對照：「門清」沒被誤改' as "驗證";
