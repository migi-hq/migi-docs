-- 2026-10-18 A1 測試開桌：取消開桌，配桌紀錄整筆刪除（使用者：「這只是測試，實際上並沒有付」）
--
-- 對象（跑之前用唯讀查過）
--   場次     b60497e9-fd75-4ca0-9cfe-a81e8f59051a   MIGI 高雄自由店 A1，open、還沒開打、0 將 0 局
--   配桌房   ce98c4f7-b64b-480e-b3fb-bc63afc3e8b0   seated，四人：黃凱、王小政、黑仔、妮妮
--   訂單     7d8d3593-8082-4912-aaeb-038601174621   MG-S01-261018-0001，配桌檯費 3 將 ×4 ＝ $600 現金（黃凱代付）
--
-- 做什麼
--   ① 配桌房與四人的報名：真的刪掉（四人的 App 對局紀錄裡不會再出現）
--   ② 那一房的四則「成桌」通知一起刪（鈴鐺裡不會留一則點進去找不到的通知）
--      ⚠ LINE 卡片當時已經送出，收不回來
--   ③ 四人的入座紀錄刪掉（場次有在座玩家就不算「取消開桌」）
--   ④ 訂單改成作廢（不刪：付款紀錄是 append-only，作廢的訂單不進任何營收與累積消費）
--   ⑤ 場次改成 voided（留一筆作廢的當稽核），A1 立刻空出來
--   ⑥ 黃凱的「來過幾天／最後來店」是這張訂單寫的 ⇒ 用他其餘已付訂單重算（2 → 1 天，最後 10-13）
--
-- 🔴 開頭有一道擋牆：場次已經開打、有局、或狀態變了就整份不做（那時就不是「測試開桌」了，要重新看）

do $$
declare
  c_sid constant uuid := 'b60497e9-fd75-4ca0-9cfe-a81e8f59051a';
  c_qid constant uuid := 'ce98c4f7-b64b-480e-b3fb-bc63afc3e8b0';
  c_oid constant uuid := '7d8d3593-8082-4912-aaeb-038601174621';
  c_payer constant uuid := '314a31c0-65db-4cdb-9cc5-bf080900d2a2';
  v_ok boolean;
begin
  select (s.status = 'open' and s.activated_at is null
          and not exists (select 1 from session_rounds r where r.session_id = s.id)
          and not exists (select 1 from hands h where h.session_id = s.id))
    into v_ok
    from table_sessions s where s.id = c_sid for update;
  -- 故意不提交的那一種：狀態不對就整份回滾（硬規則 1.8 的例外）
  if not coalesce(v_ok, false) then
    raise exception 'A1 這一場的狀態已經變了（開打、有局或不是 open），整份不做，請重新查';
  end if;

  -- ② 成桌通知（先放開可能指著它們的配對碼，再刪；寄送紀錄會連帶刪掉）
  update table_phone_codes set notification_id = null
   where notification_id in (select id from app_notifications where ref_id = c_qid);
  delete from app_notifications where ref_id = c_qid;

  -- ① 配桌房與報名
  delete from match_queue_players where queue_id = c_qid;
  delete from match_queues where id = c_qid;

  -- ③ 入座紀錄
  delete from session_players where session_id = c_sid;

  -- ④ 訂單作廢
  update orders set status = 'void' where id = c_oid and status = 'paid';

  -- ⑤ 場次作廢（配桌房已經刪了，作廢觸發器找不到要放回的房）
  update table_sessions set status = 'voided', ended_at = now() where id = c_sid;

  -- ⑥ 黃凱的來店紀錄重算（跟觸發器同一個定義：台北日曆日、只算已付訂單）
  update members m
     set visit_count = coalesce((select count(distinct (o.created_at at time zone 'Asia/Taipei')::date)
                                   from orders o where o.member_id = m.id and o.status = 'paid'), 0),
         last_visit_at = (select max(o.created_at) from orders o where o.member_id = m.id and o.status = 'paid')
   where m.id = c_payer;
end $$;

-- 驗證（單一 SELECT）
select
  case when (select status from table_sessions where id = 'b60497e9-fd75-4ca0-9cfe-a81e8f59051a') = 'voided'
       then '✅' else '🔴' end || ' ① 場次：' || coalesce((select status from table_sessions where id = 'b60497e9-fd75-4ca0-9cfe-a81e8f59051a'), '找不到') as "①",
  case when not exists (select 1 from match_queues where id = 'ce98c4f7-b64b-480e-b3fb-bc63afc3e8b0')
        and not exists (select 1 from match_queue_players where queue_id = 'ce98c4f7-b64b-480e-b3fb-bc63afc3e8b0')
       then '✅ ② 配桌房與報名已刪除' else '🔴 ② 配桌紀錄還在' end as "②",
  case when not exists (select 1 from app_notifications where ref_id = 'ce98c4f7-b64b-480e-b3fb-bc63afc3e8b0')
       then '✅ ③ 成桌通知已刪除' else '🔴 ③ 通知還在' end as "③",
  case when not exists (select 1 from session_players where session_id = 'b60497e9-fd75-4ca0-9cfe-a81e8f59051a')
       then '✅ ④ 入座紀錄已刪除' else '🔴 ④ 入座紀錄還在' end as "④",
  case when (select status from orders where id = '7d8d3593-8082-4912-aaeb-038601174621') = 'void'
       then '✅ ⑤ 訂單已作廢' else '🔴 ⑤ 訂單：' || coalesce((select status from orders where id = '7d8d3593-8082-4912-aaeb-038601174621'), '找不到') end as "⑤",
  (select case when visit_count = 1 then '✅' else '🔴' end || ' ⑥ 黃凱 來過 ' || visit_count || ' 天，最後 '
          || to_char(last_visit_at at time zone 'Asia/Taipei', 'MM/DD HH24:MI')
     from members where id = '314a31c0-65db-4cdb-9cc5-bf080900d2a2') as "⑥",
  case when not exists (select 1 from table_sessions s join tables t on t.id = s.table_id
                         where t.id = (select table_id from table_sessions where id = 'b60497e9-fd75-4ca0-9cfe-a81e8f59051a')
                           and s.status = 'open' and s.deleted_at is null)
       then '✅ ⑦ A1 已空出來' else '🔴 ⑦ A1 還有開著的場次' end as "⑦";
