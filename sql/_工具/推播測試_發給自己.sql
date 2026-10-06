/* ============================================================
   推播測試：發 LINE 卡片給老闆自己（配桌湊滿／牌局結束）
   常駐工具，可重複跑。⚠ 它**真的會寫入**正式資料庫：
     · app_notifications（老闆 App 的通知清單會多出來，配桌那張的內文開頭寫「推播測試」）
     · notification_deliveries（寄件匣，會被 Edge Function line-push 送出去）
   只發給 staff.role = 'owner' 那一位，不會發給任何客人。

   ── 要測哪一張：改下面 opt 那一行 ──────────────────────
   '配桌'  你的牌局湊滿了（借最近一個配桌房的內容）
   '結束'  牌局結束（借老闆打過、有名次、還沒有結算通知的最近一場）
   '兩張'  兩張都發（一張算一則，吃兩則免費額度）

   ⚠ 「結束」那張會建一則**真的**「牌局結算完成」通知，出現在老闆 App 的配桌頁，點得進那場的結算；
     而同一場同一人只能有一則（唯一索引 uq_app_notifications_settle_once），所以每跑一次用掉一場。
     2026-10-07 時老闆有 12 場可以用；用完了就只會發配桌那張（查詢回 0 列的那一張就是沒發）。

   怎麼看結果（跑完等 5～10 秒）：
     select n.type, d.status, d.reason, d.http_status, d.last_error, d.sent_at
       from notification_deliveries d join app_notifications n on n.id = d.notification_id
      order by d.created_at desc limit 3;
   sent ＝ 手機應該收到了；skipped / not_friend ＝ 那個 LINE 還沒加官方帳號 @254blful 好友；
   pending 一直不動 ＝ Edge Function 沒部署、或 LINE_MESSAGING_TOKEN 沒設（看 Edge Function 的 Logs）。
   ============================================================ */
with opt as (
  select '兩張'::text as k          -- 🔴 要測哪一張：'配桌'／'結束'／'兩張'
), me as (
  select s.org_id, s.member_id
    from staff s
   where s.role = 'owner' and s.member_id is not null and s.deleted_at is null
   order by s.created_at limit 1
), q as (
  -- 借最近一個配桌房組訊息內容（測試訊息不檢查房的狀態與時間）
  select mq.id from match_queues mq, me where mq.org_id = me.org_id order by mq.created_at desc limit 1
), g as (
  -- 老闆打過、有名次、還沒有結算通知的最近一場
  select ts.id, ts.org_id, ts.activated_at, ts.started_at, st.name as store, sl.label as stake
    from me
    join session_players sp on sp.member_id = me.member_id and sp.finish_rank is not null
    join table_sessions ts on ts.id = sp.session_id
    left join stores st on st.id = ts.store_id
    left join stake_levels sl on sl.id = ts.stake_level_id
   where not exists (select 1 from app_notifications n
                      where n.type = 'settle' and n.member_id = me.member_id and n.ref_id = ts.id)
   order by ts.started_at desc nulls last limit 1
)
insert into app_notifications (org_id, member_id, type, payload, ref_id)
-- style：'card' 跟正式推播一樣（使用者選定）；想比較文字版就改 'both'（兩個框也只算 1 則）
select me.org_id, me.member_id, 'table_ok',
       jsonb_build_object('text', '【推播測試】這一則是測試 LINE 推播用的，可以忽略', 'queue_id', q.id, 'test', true, 'style', 'card'),
       q.id
  from me, q, opt where opt.k in ('配桌', '兩張')
union all
-- payload 跟正式的結算通知逐欄相同，只多 test 與 style（卡片標題列會多一行「推播測試」）
select me.org_id, me.member_id, 'settle',
       jsonb_build_object('text', '牌局結算完成', 'session_id', g.id, 'store', g.store, 'stake', g.stake,
                          'at', coalesce(g.activated_at, g.started_at), 'test', true, 'style', 'card'),
       g.id
  from me, g, opt where opt.k in ('結束', '兩張')
returning type as "哪一張", id as "通知 id", created_at as "建立時間";
