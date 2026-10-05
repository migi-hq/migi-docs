/* ============================================================
   行為測試：LINE 推播寄件匣（跑在 2026-10-05_LINE推播_配桌湊滿.sql 之後）
   🔴 整段在交易裡造樣本，最後 raise 'migi_rollback' 回滾 —— 一列都不會留下，
     pg_net 排進去的 HTTP 請求也跟著回滾（不會真的打 Edge Function、不會真的推播）。
   樣本自己造（硬規則 3.57）：借最近一個配桌房，在交易裡把它改成「明天晚上、已湊滿」。
   ============================================================ */
do $$
declare
  v_msg text := '';
  v_key text; v_q uuid; v_real uuid; v_fake uuid; v_org uuid;
  v_n1 uuid; v_n2 uuid; v_n3 uuid; v_d1 uuid; v_d2 uuid; v_d3 uuid;
  v_req0 bigint; v_req1 bigint;
  v_claim jsonb; v_rep jsonb; v_row record;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'push_worker_key';
  select id, org_id into v_q, v_org from match_queues order by created_at desc limit 1;
  select id into v_real from members where line_user_id ~ '^U[0-9a-f]{32}$' and deleted_at is null and hidden_at is null order by created_at limit 1;
  select id into v_fake from members where line_user_id !~ '^U[0-9a-f]{32}$' and deleted_at is null order by created_at limit 1;
  if v_key is null or v_q is null or v_real is null or v_fake is null then
    v_msg := '🔴 樣本不齊：鑰匙 ' || (v_key is not null) || '／房 ' || (v_q is not null) ||
             '／真 LINE 會員 ' || (v_real is not null) || '／假 id 會員 ' || (v_fake is not null);
    raise exception 'migi_rollback';
  end if;

  update match_queues set status = 'matched', play_at = now() + interval '1 day', updated_at = now() where id = v_q;
  select count(*) into v_req0 from net.http_request_queue;

  -- ⓐ 一個 insert 兩個人 → 寄件匣兩列 pending
  insert into app_notifications (org_id, member_id, type, payload, ref_id)
  values (v_org, v_real, 'table_ok', jsonb_build_object('text', '測試', 'queue_id', v_q), v_q),
         (v_org, v_fake, 'table_ok', jsonb_build_object('text', '測試', 'queue_id', v_q), v_q);
  select n.id, d.id into v_n1, v_d1 from app_notifications n join notification_deliveries d on d.notification_id = n.id
   where n.member_id = v_real and n.ref_id = v_q order by n.created_at desc limit 1;
  select n.id, d.id into v_n2, v_d2 from app_notifications n join notification_deliveries d on d.notification_id = n.id
   where n.member_id = v_fake and n.ref_id = v_q order by n.created_at desc limit 1;
  v_msg := v_msg || case when v_d1 is not null and v_d2 is not null
                         then '✅ ⓐ 一次寫兩則通知 → 寄件匣兩列' else '🔴 ⓐ 寄件匣沒有排進去' end;

  -- ⓑ 只打一次 HTTP（觸發器是每個陳述式一次）
  select count(*) into v_req1 from net.http_request_queue;
  v_msg := v_msg || E'\n' || case when v_req1 - v_req0 = 1 then '✅ ⓑ 兩個人只排了 1 個 HTTP 請求'
                                  else '🔴 ⓑ 排了 ' || (v_req1 - v_req0) || ' 個 HTTP 請求（應該是 1）' end;

  -- ⓒ 鑰匙對：真 id 的交出去、帶訊息；假 id 的當場 skipped
  v_claim := push_claim_tx(v_key, 50);
  v_msg := v_msg || E'\n' || coalesce((
    select case when (e ->> 'text') like '%你的牌局湊滿了%' and (e ->> 'text') like '%明天%'
                then '✅ ⓒ 取件拿到真 LINE 會員那一筆，訊息：' || replace(e ->> 'text', E'\n', ' ／ ')
                else '🔴 ⓒ 訊息不對：' || (e ->> 'text') end
      from jsonb_array_elements(v_claim) e where (e ->> 'id')::uuid = v_d1), '🔴 ⓒ 取件沒有拿到真 LINE 會員那一筆');
  select status, reason into v_row from notification_deliveries where id = v_d2;
  v_msg := v_msg || E'\n' || case when v_row.status = 'skipped' and v_row.reason = 'bad_line_id'
                                  then '✅ ⓓ 測試帳號的假 id → skipped / bad_line_id（不會打給 LINE）'
                                  else '🔴 ⓓ 假 id 那一筆是 ' || coalesce(v_row.status, 'null') || ' / ' || coalesce(v_row.reason, 'null') end;

  -- ⓔ 回報 retry → 回到 pending，1 分鐘後才再取
  v_rep := push_report_tx(v_key, v_d1, 'retry', 503, 'line_busy', null, '測試');
  select status, attempts, next_try_at into v_row from notification_deliveries where id = v_d1;
  v_msg := v_msg || E'\n' || case when v_row.status = 'pending' and v_row.attempts = 1
                                       and v_row.next_try_at between now() + interval '50 seconds' and now() + interval '70 seconds'
                                  then '✅ ⓔ retry → pending，第 1 次重試排在 1 分鐘後'
                                  else '🔴 ⓔ retry 之後是 ' || v_row.status || '，attempts ' || v_row.attempts end;

  -- ⓕ 還沒到時間 → 取不到（負對照）
  v_claim := push_claim_tx(v_key, 50);
  v_msg := v_msg || E'\n' || case when not exists (select 1 from jsonb_array_elements(v_claim) e where (e ->> 'id')::uuid = v_d1)
                                  then '✅ ⓕ 還沒到重試時間 → 不會被取走' else '🔴 ⓕ 還沒到時間就被取走了' end;

  -- ⓖ 到時間 → 取到、回報 sent → 已送
  update notification_deliveries set next_try_at = now() where id = v_d1;
  v_claim := push_claim_tx(v_key, 50);
  v_rep := push_report_tx(v_key, v_d1, 'sent', 200, null, 'req-測試', null);
  select status, attempts, sent_at, line_request_id into v_row from notification_deliveries where id = v_d1;
  v_msg := v_msg || E'\n' || case when v_row.status = 'sent' and v_row.attempts = 2 and v_row.sent_at is not null and v_row.line_request_id = 'req-測試'
                                  then '✅ ⓖ 第二次送成功 → sent，記下 request id、attempts 2'
                                  else '🔴 ⓖ 送成功之後是 ' || v_row.status || '，attempts ' || v_row.attempts end;

  -- ⓗ 已經 sent 的再回報一次 → 被擋（不會被改回別的狀態）
  v_rep := push_report_tx(v_key, v_d1, 'failed', 400, 'http_400', null, '測試');
  v_msg := v_msg || E'\n' || case when v_rep ->> 'reason' = 'not_sending'
                                       and (select status from notification_deliveries where id = v_d1) = 'sent'
                                  then '✅ ⓗ 已送出的再回報 → 被擋，狀態維持 sent'
                                  else '🔴 ⓗ 已送出的被改掉了：' || v_rep::text end;

  -- ⓘ 房取消了才輪到送 → skipped / stale（不會送一則錯的「湊滿了」）
  update match_queues set status = 'cancelled' where id = v_q;
  insert into app_notifications (org_id, member_id, type, payload, ref_id)
  values (v_org, v_real, 'table_ok', jsonb_build_object('text', '測試', 'queue_id', v_q), v_q)
  returning id into v_n3;
  select id into v_d3 from notification_deliveries where notification_id = v_n3;
  v_claim := push_claim_tx(v_key, 50);
  select status, reason into v_row from notification_deliveries where id = v_d3;
  v_msg := v_msg || E'\n' || case when v_row.status = 'skipped' and v_row.reason = 'stale'
                                  then '✅ ⓘ 房已取消 → skipped / stale'
                                  else '🔴 ⓘ 房已取消卻是 ' || coalesce(v_row.status, 'null') || ' / ' || coalesce(v_row.reason, 'null') end;

  -- ⓙ 白名單外的通知類型不排進寄件匣（負對照）
  insert into app_notifications (org_id, member_id, type, payload) values (v_org, v_real, 'system', '{"text":"測試"}');
  v_msg := v_msg || E'\n' || case when not exists (
                                    select 1 from notification_deliveries d join app_notifications n on n.id = d.notification_id
                                     where n.member_id = v_real and n.type = 'system' and n.created_at = now())
                                  then '✅ ⓙ system 類通知不會推播（白名單只有 table_ok）'
                                  else '🔴 ⓙ system 類通知也被排進寄件匣了' end;

  raise exception 'migi_rollback';
exception when others then
  perform set_config('migi.t', v_msg || case when sqlerrm <> 'migi_rollback' then E'\n🔴 中途錯誤：' || sqlerrm else '' end, true);
end $$;
select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有訊息') as "行為測試（已回滾）";
