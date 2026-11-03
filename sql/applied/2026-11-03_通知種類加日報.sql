/* ============================================================
   通知種類加上 daily_report（2026-11-03 修）

   起因：使用者在後台按「傳昨天的日報到我的 LINE」→「資料有誤，請檢查後重新操作」。
   app_notifications 有一條 CHECK 限制 type 只能是固定那幾種，而第二批新加的 daily_report 不在裡面
   ⇒ 測試按鈕寫不進去，**明天 06:30 的排程也會一樣失敗**（排程失敗沒有人會看到）。

   🔴 第二批的驗證段只驗了「日報內容組得出來」，沒有真的寫一筆通知進去 ⇒ 漏掉。
     這一份的驗證段真的在子交易裡寫一筆再回滾（不會推播出去）。
   ============================================================ */

alter table public.app_notifications drop constraint if exists app_notifications_type_check;
alter table public.app_notifications add constraint app_notifications_type_check check (type = any (array[
  'settle', 'buddy_req', 'buddy_ok', 'table_req', 'table_ok', 'system', 'table_expired',
  'team_req', 'team_ok', 'team_out', 'friendly_ok', 'friendly_invite', 'friendly_out',
  'daily_report'   -- 🆕 2026-11-03 LINE 日報（只走 LINE，不進會員 App 的通知清單）
]));

-- ── 驗證（不 raise 到外層，硬規則 1.8）──────────────────────────
do $$
declare v text := ''; v_member uuid; v_org uuid; v_payload jsonb; v_n int;
begin
  -- ① 規則裡有 daily_report，原本的 13 種都還在
  select count(*) into v_n from unnest(array['settle','buddy_req','buddy_ok','table_req','table_ok','system','table_expired',
                                               'team_req','team_ok','team_out','friendly_ok','friendly_invite','friendly_out','daily_report']) t
   where pg_get_constraintdef((select oid from pg_constraint where conname = 'app_notifications_type_check')) like '%''' || t || '''%';
  v := v || case when v_n = 14 then '✅' else '🔴' end || ' ① 通知種類 ' || v_n || '/14（原本 13 種 ＋ daily_report）' || E'\n';

  -- ② 真的寫一筆日報進去，跟排程走同一條路；寫完回滾（推播排程與 pg_net 的請求也一起回滾，不會送出去）
  select s.member_id, s.org_id into v_member, v_org from staff s
   where s.role = 'owner' and s.deleted_at is null and s.member_id is not null limit 1;
  begin
    v_payload := public._daily_report_payload(v_org, public._biz_date(now()) - 1, true);
    insert into app_notifications (org_id, member_id, type, payload, read_at, done_at)
    values (v_org, v_member, 'daily_report', v_payload, now(), now());
    select count(*) into v_n from notification_deliveries d join app_notifications n on n.id = d.notification_id
     where n.member_id = v_member and n.type = 'daily_report' and d.status = 'pending';
    raise exception 'migi_probe:%', v_n;
  exception when others then
    if sqlerrm like 'migi_probe:%' then
      v := v || case when split_part(sqlerrm, ':', 2)::int >= 1 then '✅' else '🔴' end
              || ' ② 真的寫得進去，而且排進了 LINE 推播（' || split_part(sqlerrm, ':', 2) || ' 筆待送，已回滾）' || E'\n';
    else
      v := v || '🔴 ② 寫不進去：' || sqlerrm || E'\n';
    end if;
  end;

  -- ③ 回滾之後什麼都沒留下
  select count(*) into v_n from app_notifications where type = 'daily_report';
  v := v || case when v_n = 0 then '✅' else '⚠' end || ' ③ 線上的日報通知 ' || v_n || ' 筆（期望 0：剛剛那筆已回滾）';

  perform set_config('migi.daily', v, true);
end $$;

select coalesce(nullif(current_setting('migi.daily', true), ''), '🔴 沒有訊息') as "驗證";
