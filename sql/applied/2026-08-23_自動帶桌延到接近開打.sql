-- 【這是什麼】自動帶桌從「湊滿就帶」改成「快開打才帶」，並加一支排程負責補帶。
-- 【何時讀】執行前。這支修的是 2026-08-23_自動配桌與現場登記.sql 引進的問題。
--
-- ═══ 🔴 問題 ═══
--
-- 上一支做成「湊滿四人 → 立刻佔一張桌」。
-- 但 **湊滿 ≠ 客人到場**：21:00 的局若 19:00 就湊滿，那張桌會空等兩小時不能賣。
-- 對店家那不是不方便，是**實際的營收損失，而且沒有人會發現** ——
-- 桌況上它顯示「使用中」，看起來一切正常。
--
-- 餐廳訂位不會因為訂位滿了就在五點把七點的桌子空出來。
-- 配桌房是**訂位**（承諾），table_sessions 才是**佔桌**。兩者不該同時發生。
--
-- ═══ 改成什麼 ═══
--
--   湊滿、開打在 30 分內  → 自動帶桌
--   湊滿、開打還很遠      → 停在 matched，回 too_early；排程每 5 分鐘掃，時間到才帶
--   湊滿、沒有空桌        → 停在 matched，回 no_free_table；排程下一輪再試
--
-- ⚠ 店員手動的 pos_seat_queue_tx **不受時間限制** ——
--   客人提早到、店員想先開，那是現場判斷，系統不該擋。
--   自動的那條路才需要保守。
--
-- ⚠ 30 分鐘是拍腦袋的數字，不是算出來的。太短客人到了桌還沒開，
--   太長就回到空等的問題。改它只要改下面那個 interval，
--   但**改之前先問「客人平均提早多久到」**，那個數字現在沒有人知道。

-- ============================================================
-- 一、自動帶桌加時間條件
-- ============================================================
create or replace function _try_auto_seat_tx(p_org uuid, p_queue uuid, p_staff uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_store uuid; v_play timestamptz; v_tbl uuid;
begin
  select store_id, play_at into v_store, v_play
    from match_queues where id = p_queue and org_id = p_org;
  if v_store is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  /* ★ 只在接近開打時才佔桌。
     湊滿的那一刻可能離開打還有好幾小時，先佔住等於讓那張桌空著不能賣。 */
  if v_play > now() + interval '30 minutes' then
    return jsonb_build_object('ok', false, 'reason', 'too_early', 'play_at', v_play);
  end if;

  /* 指派規則：只看 auto_assign = true 且目前沒有 open 場次的桌。
     for update skip locked：兩桌同時湊滿時不會挑到同一張。 */
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
    -- 沒有可配的桌不是錯誤：房留在 matched，排程下一輪再試
    return jsonb_build_object('ok', false, 'reason', 'no_free_table');
  end if;

  return pos_seat_queue_tx(p_org, p_queue, v_tbl, p_staff);
end $$;

-- ============================================================
-- 二、排程：把「已滿且快開打」的房帶到桌
-- ============================================================
-- 沒有這支的話，湊滿當下太早而沒帶到的房**永遠不會被帶** ——
-- 客人收到「配桌成功」的通知，到店卻發現沒有桌。
drop function if exists sweep_auto_seat_tx(uuid);

create function sweep_auto_seat_tx(p_org uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare r record; v_res jsonb; v_seated int := 0; v_stuck int := 0; v_labels text := '';
begin
  for r in
    select q.id, q.play_at
      from match_queues q
     where q.org_id = p_org
       and q.status = 'matched'
       and q.matched_session_id is null
       and q.play_at <= now() + interval '30 minutes'
     order by q.play_at            -- 先到的先配，跟現場排隊一樣
  loop
    v_res := _try_auto_seat_tx(p_org, r.id, null);
    if coalesce((v_res->>'ok')::boolean, false) then
      v_seated := v_seated + 1;
      v_labels := v_labels || coalesce((select t.label from table_sessions s
                                          join tables t on t.id = s.table_id
                                         where s.id = (v_res->>'session_id')::uuid), '?') || ' ';
    else
      -- 幾乎都是 no_free_table：現場滿了，下一輪再試
      v_stuck := v_stuck + 1;
    end if;
  end loop;

  return jsonb_build_object('seated', v_seated, 'stuck', v_stuck, 'tables', btrim(v_labels));
end $$;

comment on function sweep_auto_seat_tx(uuid) is
  '把「已滿四人且開打在 30 分內」的配桌房帶到實體桌。'
  '⚠ 湊滿當下不帶桌是刻意的 —— 提早佔桌等於讓那張桌空著不能賣。';

grant execute on function sweep_auto_seat_tx(uuid) to anon, authenticated;

-- ============================================================
-- 三、掛排程（每 5 分鐘）
-- ============================================================
-- 5 分鐘是相對 30 分鐘門檻的精度：最壞情況客人的桌會晚 5 分鐘開，可接受。
do $do$
begin
  if exists (select 1 from cron.job where jobname = 'auto-seat-matched') then
    perform cron.unschedule('auto-seat-matched');
  end if;
  perform cron.schedule('auto-seat-matched', '*/5 * * * *',
    $j$select sweep_auto_seat_tx('11111111-1111-1111-1111-111111111111'::uuid)$j$);
  raise notice '已掛上 auto-seat-matched（每 5 分鐘）';
end $do$;

-- ============================================================
-- 四、驗證（硬規則 7：實際執行並看到回傳）
-- ============================================================
create temp table if not exists _v(ord int primary key, 項目 text, 結果 text) on commit drop;

do $do$
declare
  v_org   uuid := '11111111-1111-1111-1111-111111111111';
  v_store uuid := '22222222-2222-2222-2222-222222222222';
  v_stake uuid; v_ids uuid[]; v_i int;
  v_far uuid; v_near uuid; v_r jsonb; v_sweep jsonb;
begin
  delete from _v;

  -- 測試帳號先清空，否則 6 小時規則會擋
  update match_queue_players p set left_at = now()
    from members m, match_queues q
   where m.id = p.member_id and q.id = p.queue_id
     and m.is_test = true and p.left_at is null
     and q.status in ('waiting', 'matched');
  update match_queues q set status = 'waiting', matched_at = null
   where q.status = 'matched'
     and (select count(*) from match_queue_players p
           where p.queue_id = q.id and p.left_at is null) < q.seats;

  select id into v_stake from stake_levels where org_id = v_org limit 1;
  select array_agg(id) into v_ids
    from (select id from members where org_id = v_org and is_test and deleted_at is null
           order by display_name limit 4) t;
  if v_ids is null then
    insert into _v values (99, '⛔ 沒有測試帳號', '');
    return;
  end if;

  -- ── A：開打還很遠（+20 小時）→ 湊滿也不該佔桌 ──
  v_far := (pos_create_queue_tx(v_org, v_store, v_stake,
              now() + interval '20 hours', '台麻', '無花', '2 將', 4)->>'queue_id')::uuid;
  for v_i in 1..4 loop
    v_r := pos_add_queue_member_tx(v_org, v_far, v_ids[v_i], null);
  end loop;
  insert into _v values (1, '① 遠期房湊滿的回傳（應 status=matched、seat_reason=too_early）', v_r::text);
  insert into _v values (2, '② 遠期房有沒有佔到桌（應為「沒有」）',
    (select case when matched_session_id is null then '✅ 沒有佔桌　狀態=' || status
                 else '❌ 佔了桌！' end from match_queues where id = v_far));

  -- 把人拉出來，換測近期房
  update match_queue_players set left_at = now() where queue_id = v_far and left_at is null;
  update match_queues set status = 'cancelled' where id = v_far;

  -- ── B：開打就在眼前（+10 分鐘）→ 湊滿應立刻帶桌 ──
  v_near := (pos_create_queue_tx(v_org, v_store, v_stake,
               now() + interval '10 minutes', '台麻', '無花', '2 將', 4)->>'queue_id')::uuid;
  for v_i in 1..4 loop
    v_r := pos_add_queue_member_tx(v_org, v_near, v_ids[v_i], null);
  end loop;
  insert into _v values (10, '③ 近期房湊滿的回傳（應 status=seated、有 table_label）', v_r::text);
  insert into _v values (11, '④ 近期房的最終狀態',
    (select status || '　桌=' || coalesce((select t.label from table_sessions s
                                            join tables t on t.id = s.table_id
                                           where s.id = q.matched_session_id), '(沒帶到桌)')
       from match_queues q where q.id = v_near));

  -- ── C：排程掃描（此刻應該沒有東西可掃，因為近期房已經帶走了）──
  v_sweep := sweep_auto_seat_tx(v_org);
  insert into _v values (20, '⑤ sweep_auto_seat_tx 回傳', v_sweep::text);

  insert into _v values (21, '⑥ 排程有沒有掛上',
    coalesce((select jobname || ' [' || schedule || ']' from cron.job
               where jobname = 'auto-seat-matched'), '❌ 沒掛上'));

  -- 清理
  declare v_sid uuid;
  begin
    select matched_session_id into v_sid from match_queues where id = v_near;
    delete from match_queue_players where queue_id in (v_far, v_near);
    update match_queues set status = 'cancelled', matched_session_id = null
     where id in (v_far, v_near);
    if v_sid is not null then delete from table_sessions where id = v_sid; end if;
    insert into _v values (30, '⑦ 已清理', '✅');
  exception when others then
    insert into _v values (30, '⑦ 清理失敗', '⚠ ' || sqlerrm);
  end;
end $do$;

select 項目, 結果 from _v order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
-- ① 應含 "status": "matched" 與 "seat_reason": "too_early"
-- ② 必須是「✅ 沒有佔桌」—— 這是這支的重點，遠期的局不該提早佔桌
-- ③ 應含 "status": "seated" 與 table_label
-- ⑤ seated 應為 0（近期那房在湊滿當下就帶走了，沒有留給排程）
-- ⑥ 應為 auto-seat-matched [*/5 * * * *]
--
-- ── 還沒做的（POS 前端）─────────────────────────────────────
-- 配桌卡要分三種狀態，現在只有「等待中」：
--   等待中           人還沒滿
--   已滿 · 等開打     四人到齊，時間還沒到（seat_reason = too_early）
--   🔴 已滿 · 沒有空桌  四人到齊、時間也到了，但現場滿了（no_free_table）
--                     → 這種要排在列表最上面，那是店員現在就得處理的事
-- ⚠ 少了第三種，店員永遠不知道有一桌客人正在等而系統配不出桌。
