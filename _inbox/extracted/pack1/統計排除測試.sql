-- 【這是什麼】已執行：建立 v_real_members 視圖，並讓埋點日活視圖自動排除測試帳號。
-- 【何時讀】要寫任何營運統計 SQL 前必讀（一律 from v_real_members，不要 from members）。
-- ============================================================
-- MIGI 統計排除測試帳號（可直接執行，冪等）
-- 前提：已跑過「測試帳號隔離」建立 members.is_test
-- 作用：把會混入測試資料的視圖改成自動排除 is_test=true
-- ============================================================

-- 1. 修正埋點日活視圖：排除測試帳號
create or replace view v_app_daily_active as
select
  e.org_id,
  (e.created_at at time zone 'Asia/Taipei')::date as biz_date,
  count(distinct e.member_id)                      as active_members,
  count(*) filter (where e.event = 'app_open')     as app_opens
from app_events e
join members m on m.id = e.member_id
where e.member_id is not null
  and m.is_test = false                            -- ★排除測試
group by e.org_id, (e.created_at at time zone 'Asia/Taipei')::date;

-- 2. 作息/耐心視圖也排除（MA1 上線後生效；現在表可能還沒建，用 DO 包起來防報錯）
do $$
begin
  if exists (select 1 from information_schema.views where table_name='v_member_wait_stats') then
    -- 已存在才重建（MA1 配桌上線後）
    execute $v$
      create or replace view v_member_wait_stats as
      select qp.org_id, qp.member_id,
             count(*) as total_joins,
             count(*) filter (where q.status='matched') as matched_cnt,
             count(*) filter (where qp.leave_reason='quit') as quit_cnt
      from match_queue_players qp
      join match_queues q on q.id = qp.queue_id
      join members m on m.id = qp.member_id
      where m.is_test = false
      group by qp.org_id, qp.member_id
    $v$;
  end if;
end $$;

-- 3. 提供一個「真實會員」基底視圖，未來所有統計 join 它最省事
create or replace view v_real_members as
select * from members where is_test = false and deleted_at is null;

comment on view v_real_members is
  '真實會員（已排除測試帳號與軟刪）。做營運統計時 from v_real_members 取代 members。';

-- 驗證
select
  (select count(*) from members where is_test = true)  as 測試帳號數,
  (select count(*) from v_real_members)                as 真實會員數;
