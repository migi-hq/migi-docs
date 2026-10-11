-- ============================================================
-- 智慧計分板牌型改名（2026-10-11 使用者：「獨聽改 邊張單吊中洞」）
--   duting  獨聽 → 邊張單吊中洞
--
-- 跟同日「中發白／東南西北」那份同一個做法：改主檔名稱，按鈕、確認卡、紀錄頁一起變；
--   代碼（code）不動 —— 歷史的 hands.patterns 存的是代碼。
-- 查過：全庫函式沒有寫死「獨聽」（0 支）；四個前端只有計分板預覽頁的主檔副本（同批改）。
-- ⚠ 成就 tile_04 的名稱也叫「獨聽」—— 那是成就主檔（achievements），這一份不動，另外問使用者。
-- 前端同批：按鈕上原本的小字「單吊 · 中洞 · 邊張」拿掉（跟新名字重複）。
-- ============================================================

update public.scoring_patterns set label = '邊張單吊中洞', updated_at = now() where code = 'duting';

-- ── 驗證（單一 SELECT）──
select
  (select case when label = '邊張單吊中洞' then '✅ duting ＝ 邊張單吊中洞' else '🔴 duting 是「' || label || '」' end
     from public.scoring_patterns where code = 'duting')                                as "①",
  (select case when count(*) = 0 then '✅ 主檔裡已經沒有「獨聽」' else '🔴 還有 ' || count(*) || ' 筆' end
     from public.scoring_patterns where label = '獨聽')                                 as "②";
