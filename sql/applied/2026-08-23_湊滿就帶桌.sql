-- 【這是什麼】自動帶桌改回「湊滿就帶」，並把補帶排程的條件放寬。
-- 【何時讀】執行前。這支推翻的是同一天的 2026-08-23_自動帶桌延到接近開打.sql。
--
-- ═══ 為什麼推翻自己 ═══
--
-- 我把它改成「開打前 30 分才佔桌」，理由是「湊滿 ≠ 客人到場，提早佔桌會讓桌空置」。
-- 那個理由本身沒錯，但**設計有個洞：桌放回去給現場客人了，卻沒有任何預留機制。**
--
--   19:00  四人湊滿 → 系統發出「配桌成功！準時到店開打」
--   19:30  現場來了四個客人 → 店員把最後一張桌開給他們
--   21:00  那四個人到店 → 沒有桌
--
-- **我們主動承諾了然後兌現不了。** 空置只是機會成本，失約是違約 ——
-- 我拿一個少見的極端情況（湊滿到開打隔兩小時），去換掉一個天天會發生的承諾。
--
-- 而且實務上配桌房從湊滿到開打通常不久：客人挑今晚 21:00 的局，
-- 大概 19、20 點才湊滿。
--
-- ⚠ 桌被佔住之後，桌況上**不能只顯示「使用中」** ——
--   那張桌現在沒有人在打。判準是現成的：
--   **table_sessions 開了但 session_players 是 0 = 配好桌但還沒有人結帳入座**，
--   桌況要顯示成「預留中 · 21:00 開打 · 四個人是誰」。不用加欄位。
--   （那是 POS 前端的事，這支只管後端。）

-- ============================================================
-- 一、拿掉 30 分鐘限制
-- ============================================================
create or replace function _try_auto_seat_tx(p_org uuid, p_queue uuid, p_staff uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_store uuid; v_tbl uuid; v_fc jsonb;
begin
  select store_id into v_store
    from match_queues where id = p_queue and org_id = p_org;
  if v_store is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  /* ★ 湊滿就佔桌，不再等到接近開打。
     理由見檔頭：放回去給現場客人卻沒有預留機制，等於承諾兌現不了。
     ⚠ 代價是那張桌在開打前會空著 —— 所以桌況一定要能顯示「預留中」，
       否則店員會以為有人在打。 */

  select t.id into v_tbl
    from tables t
   where t.org_id = p_org and t.store_id = v_store
     and coalesce(t.is_active, true) = true
     and t.deleted_at is null
     and t.auto_assign = true
     and not exists (select 1 from table_sessions s
                      where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
   order by t.sort_order nulls last, t.label
   limit 1
   for update of t skip locked;

  if v_tbl is null then
    -- 帶不出桌時把預估一起回去，店員才有話可以跟客人講
    v_fc := pos_table_forecast_tx(p_org, v_store, null);
    return jsonb_build_object('ok', false, 'reason', 'no_free_table',
      'next_free_at', v_fc->'next_free_at',
      'next_free_table', v_fc->'next_free_table');
  end if;

  return pos_seat_queue_tx(p_org, p_queue, v_tbl, p_staff);
end $$;

-- ============================================================
-- 二、補帶排程：條件放寬成「所有已滿但還沒配到桌的」
-- ============================================================
-- 現在唯一會走到這裡的情況是「湊滿當下沒有空桌」。
-- 有桌釋出之後由這支補上，不用店員盯著。
create or replace function sweep_auto_seat_tx(p_org uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare r record; v_res jsonb; v_seated int := 0; v_stuck int := 0; v_labels text := '';
begin
  for r in
    select q.id
      from match_queues q
     where q.org_id = p_org
       and q.status = 'matched'
       and q.matched_session_id is null
     order by q.play_at            -- 先到的先配，跟現場排隊一樣
  loop
    v_res := _try_auto_seat_tx(p_org, r.id, null);
    if coalesce((v_res->>'ok')::boolean, false) then
      v_seated := v_seated + 1;
      v_labels := v_labels || coalesce((select t.label from table_sessions s
                                          join tables t on t.id = s.table_id
                                         where s.id = (v_res->>'session_id')::uuid), '?') || ' ';
    else
      v_stuck := v_stuck + 1;   -- 幾乎都是 no_free_table：現場滿了，下一輪再試
    end if;
  end loop;

  return jsonb_build_object('seated', v_seated, 'stuck', v_stuck, 'tables', btrim(v_labels));
end $$;

comment on function sweep_auto_seat_tx(uuid) is
  '把「已滿四人但還沒配到桌」的配桌房補帶到實體桌（湊滿當下沒空桌的情況）。'
  '⚠ 湊滿當下就會先試一次帶桌，這支只是收尾。';

-- ============================================================
-- 三、驗證（單一 SELECT）
-- ============================================================
select 項目, 結果
from (
  select 1 as ord, '① _try_auto_seat_tx 是否還有 30 分限制（應為 0）' as 項目,
    (select count(*)::text from pg_proc
      where pronamespace='public'::regnamespace and proname='_try_auto_seat_tx'
        and prosrc like '%too_early%') as 結果

  union all select 2, '② sweep_auto_seat_tx 是否還有時間條件（應為 0）',
    (select count(*)::text from pg_proc
      where pronamespace='public'::regnamespace and proname='sweep_auto_seat_tx'
        and prosrc like '%30 minutes%')

  union all select 3, '③ 排程還在嗎',
    coalesce((select jobname || ' [' || schedule || ']' from cron.job
               where jobname = 'auto-seat-matched'), '❌ 沒掛上')

  union all select 10, '④ 目前「已滿但沒配到桌」的房（應為 0）',
    (select count(*)::text from match_queues
      where status = 'matched' and matched_session_id is null)

  union all select 11, '⑤ 已配好桌但還沒有人結帳的（＝桌況要顯示「預留中」的）',
    coalesce((select string_agg(t.label || '　' ||
                (q.play_at at time zone 'Asia/Taipei')::text || ' 開打', chr(10) order by q.play_at)
                from match_queues q
                join table_sessions s on s.id = q.matched_session_id
                join tables t on t.id = s.table_id
               where q.status = 'seated' and s.status = 'open'
                 and not exists (select 1 from session_players p where p.session_id = s.id)),
             '（目前沒有）')

  union all select 20, '現在時間（台北）',
    (now() at time zone 'Asia/Taipei')::text
) x
order by ord;

-- ── 實測（另外跑，因為要改資料）─────────────────────────────
-- 上面第 ④ 項只是佔位。真正的實測請走 POS：
--   1. POS 開一個「明天 21:00」的即時桌
--   2. 在空位按「＋」加四個測試客人（或用 App 報名）
--   3. 第四個加完應該**立刻**回 status=seated 並顯示桌號
--   4. 去「即時桌況」看那張桌 —— 它會顯示成使用中，
--      但**還沒有人結帳**，所以桌況要能分辨「預留中」與「使用中」
--
-- ── 接下來要在 POS 做的 ─────────────────────────────────────
-- 🔴 桌況第三種狀態「預留中」：
--    判準 = table_sessions 開了但 session_players 是 0
--         （配好桌但還沒有人結帳入座）
--    顯示 = 「預留中 · 21:00 開打 · 測試01 小美 阿明 雅琪」
--    ⚠ 少了它，那張空著的桌在桌況上長得跟「有人在打」一模一樣，
--      店員會以為滿了而把現場客人推掉。
