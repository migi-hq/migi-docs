-- 【這是什麼】把測試帳號從所有進行中的配桌房裡拉出來，讓配桌流程可以從頭再測一次。
-- 【何時用】測試帳號卡在「已成桌」或「等待中」，想重新走一次報名流程時。
--
-- ⚠ **不刪房、不刪範本。** 只做兩件事：
--   ① 把測試帳號在 waiting / matched 房裡的在座紀錄標成已離開
--   ② 因此不滿員的 matched 房改回 waiting（不然它會一直卡在已成桌）
--
-- 為什麼不直接把房 cancel 掉：
--   固定局的實例被關掉之後**排程不會補回來** ——
--   generate_recurring_instances_tx 的重複檢查是
--   `not exists (... where recurring_id = r.id and play_at = v_play_at)`，
--   不看 status。已經存在（哪怕是取消的）就不再生成，那一場就永遠沒了。
--   所以測試只清人，房留著。
--
-- 對象：members.is_test = true 的帳號。

do $do$
declare v_left int; v_reset int;
begin
  -- ① 拉出所有在座紀錄
  with gone as (
    update match_queue_players p
       set left_at = now()
      from members m, match_queues q
     where m.id = p.member_id
       and q.id = p.queue_id
       and m.is_test = true
       and p.left_at is null
       and q.status in ('waiting', 'matched')
    returning 1)
  select count(*) into v_left from gone;

  -- ② 人不夠了就把已成桌改回等待中
  with back as (
    update match_queues q
       set status = 'waiting', matched_at = null, updated_at = now()
     where q.status = 'matched'
       and (select count(*) from match_queue_players p
             where p.queue_id = q.id and p.left_at is null) < q.seats
    returning 1)
  select count(*) into v_reset from back;

  raise notice '清掉 % 筆在座紀錄，% 個已成桌的房改回等待中', v_left, v_reset;
end $do$;

-- ── 驗證（單一 SELECT）────────────────────────────────────────
select 項目, 結果
from (
  select 1 as ord, '測試帳號還掛在哪些房（應為空）' as 項目,
    coalesce((select string_agg(m.display_name || ' → [' || q.status || '] '
                                || (q.play_at at time zone 'Asia/Taipei')::text, chr(10))
                from match_queue_players p
                join members m on m.id = p.member_id
                join match_queues q on q.id = p.queue_id
               where m.is_test = true and p.left_at is null
                 and q.status in ('waiting', 'matched')),
             '✅ 全部清空了') as 結果

  union all select 2, '各狀態的房數',
    coalesce((select string_agg(status || ' = ' || n, '   ' order by status)
                from (select status, count(*) n from match_queues group by status) t), '（無）')

  union all select 3, '客人現在看得到的房（等待中且已開賣）',
    coalesce((select string_agg(
                coalesce(source, '?') || ' ' || (play_at at time zone 'Asia/Taipei')::text
                || ' 人數 ' || (select count(*) from match_queue_players p
                                 where p.queue_id = q.id and p.left_at is null) || '/' || seats,
                chr(10) order by play_at)
                from match_queues q
               where status = 'waiting' and play_at > now()
                 and (open_at is null or open_at <= now())),
             '（一間都沒有）')

  union all select 4, '固定局範本還在嗎',
    coalesce((select string_agg(frequency || ' ' || start_time::text || '（' ||
                                case when enabled then '啟用' else '停用' end || '）', '   ')
                from recurring_tables), '（沒有範本）')
) x
order by ord;

-- ── 用完之後 ─────────────────────────────────────────────────
-- 第 1 項應為「✅ 全部清空了」。回到 App 重新整理，配桌頁會變回「我要配桌」。
-- 第 3 項會告訴你現在有哪些房可以報名 —— 固定局那場會回到等待中，可以重新加入。
-- ⚠ 房沒有被刪，所以固定局的實例還在、範本也還在，下一輪 cron 不會重複生成。
