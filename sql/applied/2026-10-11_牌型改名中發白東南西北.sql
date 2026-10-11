-- ============================================================
-- 智慧計分板牌型改名（2026-10-11 使用者：「三元牌改中發白、風牌改東南西北，小字不用」）
--   triplet_dragon  三元牌 → 中發白
--   triplet_wind    風牌   → 東南西北
--
-- 改主檔名稱（不是只改按鈕）：名字只有一份，選牌型的按鈕、確認卡、紀錄頁一起變，
--   不會出現按鈕寫「中發白」而確認卡寫「三元牌」。
-- 查過：沒有任何函式把這兩個名字寫死（掃全庫函式本體 0 支；同一個查詢找「台」有 35 支，查詢本身是活的），
--   會員 App／POS／後台的程式碼也沒有。代碼（code）不動 —— 歷史的 hands.patterns 存的是代碼。
-- 前端同批：計分板按鈕上那兩格的小字（原本就寫「中發白」「東南西北」）拿掉，否則大字小字重複。
-- ============================================================

update public.scoring_patterns set label = '中發白',   updated_at = now() where code = 'triplet_dragon';
update public.scoring_patterns set label = '東南西北', updated_at = now() where code = 'triplet_wind';

-- ── 驗證（單一 SELECT）──
select
  (select case when label = '中發白' then '✅ triplet_dragon ＝ 中發白' else '🔴 triplet_dragon 是「' || label || '」' end
     from public.scoring_patterns where code = 'triplet_dragon')                                      as "①",
  (select case when label = '東南西北' then '✅ triplet_wind ＝ 東南西北' else '🔴 triplet_wind 是「' || label || '」' end
     from public.scoring_patterns where code = 'triplet_wind')                                        as "②",
  (select case when count(*) = 0 then '✅ 主檔裡已經沒有「三元牌」「風牌」這兩個名字'
               else '🔴 還有 ' || count(*) || ' 筆' end
     from public.scoring_patterns where label in ('三元牌', '風牌'))                                  as "③";
