-- ============================================================
-- 一次性：補發 A2 的成桌通知（LINE 卡片 ＋ 手機計分配對碼）給陳艾倫
-- 2026-10-13 · MIGI 咪吉麻將
--
-- 使用者：「補發一個成桌通知與配對碼給陳艾倫」
--   陳艾倫一開始是用創辦人的帳號報名的，所以成桌那一刻沒有收到卡片。
--
-- 做法：跟真的成桌一樣插一則 table_ok 通知（payload 照抄真的那一種），其餘交給既有機制：
--   · trg_app_notifications_phone_code：他還沒有配對過的手機 ⇒ 發一組配對碼（24 小時、用一次）
--   · trg_app_notifications_push：排進 LINE 寄送，line-push 幾秒內送出卡片
--   卡片內容（門市、地址、A2 桌、玩法、積分、同桌）由 _push_flex 依配桌房組
--
-- 🔴 結果（2026-10-13 跑完）：通知與配對碼都建了，但 **LINE 沒有送出**（notification_deliveries.status = skipped、reason = stale）——
--   push_claim_tx 規定成桌卡片在約定開打時間過 30 分鐘以上就不送（A2 約 17:00，補發時已經 17:49）。
--   ⇒ 開打之後才補人，配對碼請改用管理後台「發配對碼」；這一份產生的碼沒人拿到，24 小時後自己過期。
--
-- ⚠ 請先跑 2026-10-13_A2座位2創辦人改陳艾倫.sql 再跑這一份：
--   卡片上的「同桌」是配桌房裡除了他以外的人 —— 沒先換的話會把創辦人列成同桌，而陳艾倫自己不在房裡。
--   所以條件是「陳艾倫已經在 A2 配桌房裡」，不符合就不發（驗證段會說）。
-- ============================================================

insert into public.app_notifications (org_id, member_id, type, payload, ref_id)
select mq.org_id, 'aadf83c6-bf8d-4d2d-bcfc-e833acbbeb75', 'table_ok',
       jsonb_build_object('text', '配桌成功！準時到店開打', 'queue_id', mq.id), mq.id
  from public.match_queues mq
 where mq.id = '3e8a791e-09d3-4d34-86cc-d545f8df121c'
   and exists (select 1 from public.match_queue_players q
                where q.queue_id = mq.id and q.member_id = 'aadf83c6-bf8d-4d2d-bcfc-e833acbbeb75' and q.left_at is null);


-- ============================================================
-- 驗證（單一 SELECT，不 raise）
--   ⚠ LINE 送出要等 5～10 秒；這裡看的是「通知建了、碼發了、排進寄送了」
--   送到沒有，跑完之後另外查 notification_deliveries 的 status（sent ＝ 送到）
-- ============================================================
with n as (
  select id, created_at from app_notifications
   where member_id = 'aadf83c6-bf8d-4d2d-bcfc-e833acbbeb75' and type = 'table_ok'
     and ref_id = '3e8a791e-09d3-4d34-86cc-d545f8df121c'
   order by created_at desc limit 1
)
select concat_ws(E'\n',
  case when exists (select 1 from n) then '① ✅ 成桌通知建好了'
       else '① 🔴 沒有建 —— 陳艾倫還不在 A2 配桌房（請先跑換人那一份）' end,
  coalesce((select '② ✅ 配對碼發了（' || to_char(pc.expires_at at time zone 'Asia/Taipei', 'MM/DD HH24:MI') || ' 前有效）'
              from table_phone_codes pc, n where pc.notification_id = n.id and pc.used_at is null),
           '② ⚪ 沒有配對碼（他已經有配對好的手機，或通知沒建）'),
  coalesce((select '③ ✅ 已排進 LINE 寄送（目前狀態：' || d.status || '）'
              from notification_deliveries d, n where d.notification_id = n.id),
           '③ 🔴 沒有排進寄送')
) as "驗證";
