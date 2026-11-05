-- ═══════════════════════════════════════════════════════════════════
-- 2026-11-05 刪除 A3 誤按提早結算的那一場（使用者：當作從來沒有這一局，不用退錢，也不算場次）
-- ───────────────────────────────────────────────────────────────────
-- 配桌房   c3c8cf83-69bb-4ae0-934a-818c3c05fbbd  yuhsin 開的　純娛樂・台麻・無花・1 將・17:30 前開打
-- 場次     1c3540be-819f-4072-81c3-0ced5175567f  16:14 自動帶到 A3、16:16 收桌，一局都沒打、沒有人有名次
-- 四位     yuhsin／Y／露比／George —— 之後在 A2 重開一桌（有花），那一桌不動
--
-- 這一場留下的、這份全部拿掉：
--   入座紀錄 4 筆（不算場次、不算同桌）／配桌房與名單 4 人
--   通知：成桌 4 則（LINE 卡片已經送出，收不回來）＋ 牌局結算 4 則，連同推播紀錄
--   按讚 2 個（露比讚 Y、yuhsin）＋ 露比因此拿到的 2 個小熊餅乾；Y、yuhsin 讚數各扣 1
-- 檯費 4 張（各現金 100）：收款紀錄依規定不能刪 ⇒ 訂單改成作廢、拿掉跟這一場的連結
--   ⇒ 營收不算這 400；作廢紀錄自動記成「系統」（觸發器 _audit_void）
-- 段位分、成就、碎片：這一場一個都沒產生，不用處理（查過）
-- ⚠ 刪掉的是事實紀錄，無法復原。
-- ═══════════════════════════════════════════════════════════════════

-- 0. 前提：跟查的時候一樣才動手（不一樣就整份不提交）
do $$
begin
  if not exists (select 1 from table_sessions
                  where id = '1c3540be-819f-4072-81c3-0ced5175567f' and status = 'completed')
     or exists (select 1 from session_players
                 where session_id = '1c3540be-819f-4072-81c3-0ced5175567f' and finish_rank is not null)
     or exists (select 1 from hands where session_id = '1c3540be-819f-4072-81c3-0ced5175567f')
     or (select count(*) from orders
          where session_id = '1c3540be-819f-4072-81c3-0ced5175567f' and status = 'paid') <> 4
  then
    raise exception '這一場的狀態跟查的時候不一樣，整份沒有執行，請叫 Claude 重查';
  end if;
end $$;

-- 1. 通知（成桌、結算）連同推播紀錄
delete from notification_deliveries
 where notification_id in (select id from app_notifications
                            where ref_id in ('c3c8cf83-69bb-4ae0-934a-818c3c05fbbd',
                                             '1c3540be-819f-4072-81c3-0ced5175567f'));
delete from app_notifications
 where ref_id in ('c3c8cf83-69bb-4ae0-934a-818c3c05fbbd', '1c3540be-819f-4072-81c3-0ced5175567f');

-- 2. 按讚與按讚得到的餅乾；被讚的人讚數扣回
update members m set likes_count = greatest(m.likes_count - x.n, 0)
  from (select target_id, count(*) n from member_likes
         where session_id = '1c3540be-819f-4072-81c3-0ced5175567f' group by target_id) x
 where m.id = x.target_id;
delete from member_likes where session_id = '1c3540be-819f-4072-81c3-0ced5175567f';
delete from snack_grants where ref_id::text = '1c3540be-819f-4072-81c3-0ced5175567f';

-- 3. 配桌房與名單
delete from match_queue_players where queue_id = 'c3c8cf83-69bb-4ae0-934a-818c3c05fbbd';
delete from match_queues        where id       = 'c3c8cf83-69bb-4ae0-934a-818c3c05fbbd';

-- 4. 入座紀錄
delete from session_players where session_id = '1c3540be-819f-4072-81c3-0ced5175567f';

-- 5. 檯費單作廢並拿掉場次連結（收款紀錄不能刪）
update orders set status = 'void', session_id = null
 where session_id = '1c3540be-819f-4072-81c3-0ced5175567f';

-- 6. 場次本身
delete from table_sessions where id = '1c3540be-819f-4072-81c3-0ced5175567f';

-- ═══ 驗證（單一 SELECT，不 raise）═══
with c as (
  select
    (select count(*) from table_sessions where id = '1c3540be-819f-4072-81c3-0ced5175567f') 場次,
    (select count(*) from session_players where session_id = '1c3540be-819f-4072-81c3-0ced5175567f') 入座,
    (select count(*) from match_queues where id = 'c3c8cf83-69bb-4ae0-934a-818c3c05fbbd') 配桌房,
    (select count(*) from match_queue_players where queue_id = 'c3c8cf83-69bb-4ae0-934a-818c3c05fbbd') 名單,
    (select count(*) from app_notifications where ref_id in ('c3c8cf83-69bb-4ae0-934a-818c3c05fbbd','1c3540be-819f-4072-81c3-0ced5175567f')) 通知,
    (select count(*) from member_likes where session_id = '1c3540be-819f-4072-81c3-0ced5175567f') 按讚,
    (select count(*) from snack_grants where ref_id::text = '1c3540be-819f-4072-81c3-0ced5175567f') 餅乾,
    (select count(*) from orders where id in ('97cced54-61f2-43af-b02a-62ec9ecf7df4','65540a2c-d10d-4086-a3cb-5ebbf12cf4b6',
                                              '766f83fd-1813-4206-99da-48fd772afeea','cbfd1360-bb0a-4f91-b473-9358f3dfd04a')
                                 and status = 'void' and session_id is null) 作廢單,
    (select likes_count from members where id = 'e5b94358-3d1c-4f21-8f32-3689a924a402') y讚,       -- 6 − 1
    (select likes_count from members where id = 'fc235c4a-04db-4a12-b906-2c6983d868b3') yuhsin讚,  -- 4 − 1
    (select count(*) from session_players where session_id = '585b3d89-cf4f-4b15-985a-dfa9bb3d2b0b') a2入座  -- 正對照：A2 那桌不能被碰到
)
select case when 場次 + 入座 + 配桌房 + 名單 + 通知 + 按讚 + 餅乾 = 0
             and 作廢單 = 4 and y讚 = 5 and yuhsin讚 = 3 and a2入座 = 4
       then '✅ A3 那一場已刪除：場次、入座、配桌房、通知、按讚、餅乾都清掉，4 張檯費單已作廢；A2 那桌 4 人沒動'
       else '🔴 場次' || 場次 || ' 入座' || 入座 || ' 配桌房' || 配桌房 || ' 名單' || 名單 || ' 通知' || 通知
            || ' 按讚' || 按讚 || ' 餅乾' || 餅乾 || ' 作廢單' || 作廢單 || '/4 Y讚' || y讚 || '/5 yuhsin讚' || yuhsin讚
            || '/3 A2入座' || a2入座 || '/4'
       end as "驗證"
from c;
