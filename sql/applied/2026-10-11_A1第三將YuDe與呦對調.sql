-- ============================================================
-- A1 這一場（bbc2e63c…）第三將選錯位置：YuDe 與 呦 對調（2026-10-11 使用者）
--
-- 現在第三將的繞桌順序 seat_ring = {4,2,3,1}：W 莊家 → YuDe 下家 → 呦 對家 → C 上家
-- 改成               seat_ring = {4,3,2,1}：W 莊家 → 呦 下家 → YuDe 對家 → C 上家
--
-- 🔴 只改這一將的繞桌順序，不改 session_players.seat —— 座位號代表那個人，
--   前兩將 43 局的胡牌、放槍、莊家都記在座位號上，改座位號會把那些局算到別人頭上。
-- 三道保險（任何一個不成立就一列都不改，驗證段會講出來）：
--   ① 第三將還在打（status = playing）
--   ② 順序還是現在這樣（{4,2,3,1}）—— 平板上已經有人改過的話不會被蓋掉
--   ③ 第三將還沒有任何一局（含待確認、取消的）—— 打過的局用的是舊順序
-- 觸發器只在改 status 時作用，這份只改 seat_ring，不會觸發結算。
-- ============================================================

update public.session_rounds r
   set seat_ring = '{4,3,2,1}'::smallint[]
 where r.session_id = 'bbc2e63c-77a4-4c5f-8bb3-3150aa5968ca'
   and r.round_no = 3
   and r.status = 'playing'
   and r.seat_ring = '{4,2,3,1}'::smallint[]
   and not exists (select 1 from public.hands h where h.round_id = r.id);

-- ── 驗證（單一 SELECT）──
select case
         when r.seat_ring = '{4,3,2,1}'::smallint[]
           then '✅ 第三將順序已改成：W 莊家 → 呦 下家 → YuDe 對家 → C 上家（前兩將未動，座位號未動）'
         when r.seat_ring = '{4,2,3,1}'::smallint[] and exists (select 1 from public.hands h where h.round_id = r.id)
           then '🔴 沒改：第三將已經開始打了（有 ' || (select count(*) from public.hands h where h.round_id = r.id) || ' 筆局）—— 請先跟我說，要另外處理'
         when r.seat_ring = '{4,2,3,1}'::smallint[]
           then '🔴 沒改：第三將狀態是 ' || r.status
         else '🔴 沒改：順序已經被改成 ' || r.seat_ring::text || '（可能平板上有人改過）'
       end as "驗證"
  from public.session_rounds r
 where r.session_id = 'bbc2e63c-77a4-4c5f-8bb3-3150aa5968ca' and r.round_no = 3;
