-- 2026-11-20 陳81 那一場（11-20 16:24 打完的 3 將配桌）的評價改回「還沒評」
-- 起因：他打開 App 3 秒內評價彈窗被按掉（應該是誤觸，一個讚都沒按）⇒ 通知被標成已評完、已讀。
-- 改回之後他下次打開 App 會再自動跳一次評價彈窗（3 天內的才跳，這則是今天建的）。
-- 同日前端已補：彈窗跳出後 1.5 秒內「完成評價」按不下去（migi-web c9ceaf5）。

update app_notifications
   set done_at = null, read_at = null
 where member_id = '52cde184-bac4-484d-bae3-0d59a8cf10fb'          -- 陳81
   and ref_id    = '0102ad73-b0c5-4593-a9ea-d2193b73f1b3'          -- 那一場
   and type      = 'settle';

-- 驗證：應該是 1 列、已評完與已讀都是空的
select count(*) as 筆數,
       count(*) filter (where done_at is null and read_at is null) as 已改回還沒評,
       case when count(*) = 1 and count(*) filter (where done_at is null and read_at is null) = 1
            then '✅ 改回還沒評了' else '🔴 沒改到，請貼結果給 Claude' end as 驗證
  from app_notifications
 where member_id = '52cde184-bac4-484d-bae3-0d59a8cf10fb'
   and ref_id    = '0102ad73-b0c5-4593-a9ea-d2193b73f1b3'
   and type      = 'settle';
