/* ============================================================
   創辦人的會員帳號改成「不是測試」（2026-10-31 使用者拍板）
   ------------------------------------------------------------
   原本的規則是「等設 orgs.live_from（正式上線）那天再一起改」，
   使用者決定現在就改，而且**他自己的消費要算進營收報表**。

   帳號：本狩 岡五郎（手機 0910768736，2026-08-29 用 LINE 註冊的那一個）
   ⚠ 用 id ＋ 手機兩個條件一起認，任何一個對不上就一列都不改。
   ⚠ 測試01～04 不動，仍然是測試帳號。

   改了之後會連動的（2026-10-31 掃過全庫讀 members.is_test 的函式）：
   · 名人堂（get_season_leaderboard_tx）不再排除他
   · 收桌沒打完一將時不再塞隨機名次（placeholder_ranks_tx）
   · 賽季結算會照常重置他的段位分（reset_season_ratings_tx 原本跳過測試帳號）
   · 之後的埋點不再標成測試（log_app_event_tx 寫入當下從會員推）
   · 開發用的「清測試資料」「設測試餘額」碰不到他了（dev_reset_test_data_tx／dev_set_test_balance_tx）
   · POS 會員列表的「測試」標籤消失
   · 營收報表：orgs.live_from 還沒設，v_real_* 目前全部是空的；
     上線那天起他的消費會跟真客人一起算進去
   ============================================================ */

update public.members
   set is_test = false
 where id = '69016205-afde-4036-95a6-5893c9d0e5fe'
   and phone = '0910768736'
   and is_test = true;

/* ── 驗證（單一 SELECT）── */
select
  coalesce((select case when not m.is_test then '✅ ' else '🔴 ' end || m.display_name || '　is_test = ' || m.is_test::text
              from public.members m where m.id = '69016205-afde-4036-95a6-5893c9d0e5fe'), '🔴 找不到這個帳號') as "① 創辦人",
  (select case when count(*) = 4 then '✅ ' else '⚠ ' end || '仍是測試的帳號 ' || count(*) || ' 個：' ||
          coalesce(string_agg(display_name, '、' order by created_at), '')
     from public.members where is_test and deleted_at is null)                                      as "② 其餘測試帳號（期望 4 個）";
