/* ============================================================
   推播測試：發一則「【推播測試】你的牌局湊滿了」給老闆自己的 LINE
   常駐工具，可重複跑。⚠ 它**真的會寫入**正式資料庫：
     · app_notifications 一列（老闆 App 的通知清單會多一則，內文開頭寫「推播測試」）
     · notification_deliveries 一列（寄件匣，會被 Edge Function line-push 送出去）
   只發給 staff.role = 'owner' 那一位，不會發給任何客人。

   怎麼看結果（跑完等 5～10 秒）：
     select status, reason, http_status, last_error, sent_at
       from notification_deliveries order by created_at desc limit 3;
   sent ＝ 手機應該收到了；skipped / not_friend ＝ 那個 LINE 還沒加官方帳號 @254blful 好友；
   pending 一直不動 ＝ Edge Function 沒部署、或 LINE_MESSAGING_TOKEN 沒設（看 Edge Function 的 Logs）。
   ============================================================ */
with me as (
  select s.org_id, s.member_id
    from staff s
   where s.role = 'owner' and s.member_id is not null and s.deleted_at is null
   order by s.created_at limit 1
), q as (
  -- 借最近一個配桌房組訊息內容（測試訊息不檢查房的狀態與時間）
  select mq.id from match_queues mq, me where mq.org_id = me.org_id order by mq.created_at desc limit 1
)
insert into app_notifications (org_id, member_id, type, payload, ref_id)
select me.org_id, me.member_id, 'table_ok',
       -- style：'card' 跟正式推播一樣（使用者選定）；想比較文字版就改 'both'（兩個框也只算 1 則）
       jsonb_build_object('text', '【推播測試】這一則是測試 LINE 推播用的，可以忽略', 'queue_id', q.id, 'test', true, 'style', 'card'),
       q.id
  from me, q
returning id as "通知 id", created_at as "建立時間";
