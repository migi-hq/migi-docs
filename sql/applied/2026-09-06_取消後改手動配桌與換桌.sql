/* ============================================================
   取消之後改成「手動配桌」＋ 新增「換桌」
   2026-09-06 · MIGI 咪吉麻將
   ⚠ 這一份**有真的寫入**（加欄位、回填現有的房），不是只有 DDL。

   ── 使用者拍板的規則 ──────────────────────────────────
   ```
   第一次成桌            → 系統自動帶桌（不管房是誰開的）
   帶到的桌被取消之後    → 該房在配桌列表改成**手動**（隨機或指定）
   ```
   ⇒ 自動配桌**只做一次**。取消之後系統不再自己配，由店員決定。

   ── 🎯 為什麼這比「立刻重配」好 ────────────────────────
   我原本要做「取消後立刻配一張新的桌」，但那有一個必然的毛病：
   `_try_auto_seat_tx` 挑的是「第一張沒有 open 場次的桌」，
   而**剛被取消的那張正好符合** ⇒ 店員取消 A3，系統立刻配回 A3，
   看起來像取消沒有作用。要避開就得多一個「排除這張桌」的參數，
   而那只是在繞過真正的問題：**系統不知道他為什麼取消。**

   🎯 使用者的版本把判斷交還給知道答案的人：
     · 「這桌開錯了」    → 店員按隨機／指定，換一張
     · 「這組不來了」    → 店員什麼都不用做，房自己過期
     · 「我要這張桌給別人」→ **那根本不該用取消，該用換桌**（見下）

   ── 這一份做四件事 ────────────────────────────────────
   ① `match_queues.auto_seat`（預設 true）—— 自動配桌只做一次
   ② 觸發器：帶到的桌被作廢 → `auto_seat = false`
   ③ `sweep_auto_seat_tx` 與 `_finalize_queue_full_tx` 跳過 `auto_seat = false`
   ④ **`pos_move_session_tx`：換桌** —— 系統裡完全沒有這個東西

   ── 🔴 為什麼要有「換桌」──────────────────────────────
   店員想把 A3 讓給現場客人時，現在唯一的辦法是**取消開桌**，
   而那會：
     · 把四個客人的房打回排隊（他們收到「桌取消了」的通知）
     · 已經收過檯費的話根本不能取消（`has_players` 擋著）
   而他真正要做的只是「同一組人，換一張桌」。
   ⇒ 換桌**保住場次、玩家、已收的檯費、配桌房的關聯**，只換 `table_id`。
   ============================================================ */

-- ══════════════════════════════════════════════════════
-- ① 自動配桌只做一次
-- ══════════════════════════════════════════════════════
alter table match_queues
  add column if not exists auto_seat boolean not null default true;

comment on column match_queues.auto_seat is
  '系統可不可以自動幫這個房配桌。第一次成桌是 true；帶到的桌被取消之後改成 false，'
  '之後由店員在配桌列表手動配（隨機或指定）。2026-09-06 使用者拍板。';


-- ══════════════════════════════════════════════════════
-- ② 桌被作廢 → 改成手動
-- ══════════════════════════════════════════════════════
create or replace function public.trg_session_voided_release_queue()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r record;
  v_n int;
  /* 寬限與 `cleanup_empty_sessions_tx` 的預設一致（30 分）。
     ⚠ 兩邊不一致會出現「排程收了桌、觸發器又放回去」的循環。 */
  c_grace constant interval := interval '30 minutes';
begin
  for r in
    select q.id, q.org_id, q.play_at, q.expires_at, q.source, q.seats
      from match_queues q
     where q.matched_session_id = new.id
       and q.status = 'seated'
     for update
  loop
    if now() < r.play_at + c_grace then
      select count(*) into v_n
        from match_queue_players qp
       where qp.queue_id = r.id and qp.left_at is null;

      /* ★ 2026-09-06：一併把 `auto_seat` 關掉 —— **自動配桌只做一次**。
         🔴 不關的話，`sweep_auto_seat_tx` 五分鐘後又會配一張，
           而它挑的是「第一張空桌」＝**很可能就是剛被取消的那張**
           ⇒ 店員取消了，桌又自己回來，看起來像取消沒有作用。
         🎯 取消的理由只有店員知道，所以之後由他決定（隨機／指定）。 */
      if v_n >= coalesce(r.seats, 4) then
        update match_queues
           set status = 'matched', matched_session_id = null,
               auto_seat = false,
               expires_at = greatest(r.expires_at, r.play_at, now() + interval '15 minutes'),
               updated_at = now()
         where id = r.id;
      else
        update match_queues
           set status = 'waiting', matched_session_id = null, matched_at = null,
               auto_seat = false,
               expires_at = greatest(r.expires_at, r.play_at, now() + interval '15 minutes'),
               updated_at = now()
         where id = r.id;
      end if;

      insert into app_notifications(org_id, member_id, type, payload, ref_id)
      select r.org_id, qp.member_id, 'system',
             jsonb_build_object(
               'text', '原本安排的桌取消了，店員會幫你重新安排',
               'queue_id', r.id, 'play_at', r.play_at),
             r.id
        from match_queue_players qp
       where qp.queue_id = r.id and qp.left_at is null;

    else
      ---- 過了開打時間還沒有人來 → 流局（比照 sweep）-------
      update match_queues set status = 'expired', updated_at = now() where id = r.id;

      insert into app_notifications(org_id, member_id, type, payload, ref_id)
      select r.org_id, qp.member_id, 'table_expired',
             jsonb_build_object(
               'text', case when r.source = 'recurring'
                            then '固定局人數不足，本場流局'
                            else '人數不足，本場流局' end,
               'queue_id', r.id, 'play_at', r.play_at),
             r.id
        from match_queue_players qp
       where qp.queue_id = r.id and qp.left_at is null;

      update match_queue_players
         set left_at = now(), leave_reason = 'expired'
       where queue_id = r.id and left_at is null;
    end if;
  end loop;

  return new;
end $function$;


-- ══════════════════════════════════════════════════════
-- ③ 排程只碰 auto_seat 還是 true 的房
-- ══════════════════════════════════════════════════════
create or replace function public.sweep_auto_seat_tx(p_org uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r record; v_res jsonb; v_seated int := 0; v_stuck int := 0;
        v_manual int := 0; v_labels text := '';
begin
  /* ★ 2026-09-06：跳過 `auto_seat = false` 的房（取消過一次就改手動）。
     ⚠ 一起數出來回傳 —— 不然「有幾個房在等店員手動配」是隱形的，
       而那正是店員需要知道的事。 */
  select count(*) into v_manual
    from match_queues q
   where q.org_id = p_org and q.status = 'matched'
     and q.matched_session_id is null and not q.auto_seat;

  for r in
    select q.id from match_queues q
     where q.org_id = p_org
       and q.status = 'matched'
       and q.matched_session_id is null
       and q.auto_seat                       -- ★ 2026-09-06
     order by q.play_at                      -- 先到的先配，跟現場排隊一樣
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

  return jsonb_build_object('seated', v_seated, 'stuck', v_stuck,
                            'manual', v_manual, 'tables', btrim(v_labels));
end $function$;


-- ══════════════════════════════════════════════════════
-- ④ 換桌
-- ══════════════════════════════════════════════════════
/* 🔴 系統裡**完全沒有**這個東西（查過 move / change_table / transfer / swap）。
   店員想把 A3 讓給現場客人時，現在唯一的辦法是取消開桌 ——
   而那會把四個客人打回排隊，且**已經收過檯費就根本不能取消**
   （`void_session_tx` 的 `has_players` 擋著）。
   ⇒ 換桌只換 `table_id`：場次、玩家、已收的檯費、配桌房的關聯全部保住。 */
create or replace function public.pos_move_session_tx(
  p_session_id uuid, p_table_id uuid, p_staff_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_s record; v_t record; v_busy uuid;
begin
  /* 🔴 操作者身分從 JWT 取，不採信呼叫端送的值（2026-09-04 那一批的規矩）。
     ⚠ 查不到就是 null，不可以報錯。 */
  p_staff_id := (select staff_id from public.current_staff());

  select ts.*, t.label as old_label into v_s
    from table_sessions ts
    left join tables t on t.id = ts.table_id
   where ts.id = p_session_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_s.status <> 'open' then
    return jsonb_build_object('ok', false, 'reason', 'not_open', 'status', v_s.status);
  end if;

  select * into v_t from tables where id = p_table_id and deleted_at is null;
  if not found then return jsonb_build_object('ok', false, 'reason', 'table_not_found'); end if;
  if v_t.id = v_s.table_id then
    return jsonb_build_object('ok', false, 'reason', 'same_table', 'table_label', v_t.label);
  end if;
  if not coalesce(v_t.is_active, true) then
    return jsonb_build_object('ok', false, 'reason', 'table_unavailable', 'table_label', v_t.label);
  end if;
  /* ⚠ 跨門市不可以 —— 客人已經在這間店裡了。 */
  if v_t.store_id <> v_s.store_id then
    return jsonb_build_object('ok', false, 'reason', 'other_store');
  end if;

  /* 先查再改，不要靠 `uq_sessions_open_table` 拋 23505 ——
     那個錯誤訊息店員看不懂，而這裡答得出是誰佔著。 */
  select s.id into v_busy from table_sessions s
   where s.table_id = p_table_id and s.status = 'open' and s.deleted_at is null;
  if v_busy is not null then
    return jsonb_build_object('ok', false, 'reason', 'table_busy',
                              'table_label', v_t.label, 'session_id', v_busy);
  end if;

  update table_sessions
     set table_id = p_table_id, updated_at = now(),
         updated_by = coalesce(p_staff_id, updated_by)
   where id = p_session_id and status = 'open';
  if not found then
    -- 併發保護：同時兩人按，只有一個會成功
    return jsonb_build_object('ok', false, 'reason', 'race_lost');
  end if;

  return jsonb_build_object('ok', true, 'session_id', p_session_id,
                            'from', v_s.old_label, 'to', v_t.label);
end $function$;

/* ⚠ POS 用 anon key，所以這支要給 anon（同其他 `pos_*`）。
   🔴 那是**現況的必然**不是決定 —— 店員登入之前沒有身分可以檢查
     （CLAUDE.md 待辦 20 的 A 類）。收緊是待辦 14／21 的範圍。 */
grant execute on function public.pos_move_session_tx(uuid, uuid, uuid) to anon, authenticated, service_role;


-- ══════════════════════════════════════════════════════
-- 一次性：已經被取消過的房改成手動
-- ══════════════════════════════════════════════════════
do $fix$
declare v_n int;
begin
  /* 判準：這個房歷來開過的桌**全部都不是 open** ＝ 它被取消過。
     ⚠ 從來沒配過桌的房不要動（`auto_seat` 維持 true）—— 它還沒用掉那一次。 */
  update match_queues q
     set auto_seat = false, updated_at = now()
   where q.status in ('waiting','matched')
     and exists (select 1 from table_sessions s
                  where s.idempotency_key like 'queue-' || q.id::text || '%')
     and not exists (select 1 from table_sessions s
                      where s.idempotency_key like 'queue-' || q.id::text || '%'
                        and s.status = 'open');
  get diagnostics v_n = row_count;
  perform set_config('migi.fix', v_n::text || ' 個被取消過的房改成手動', true);
end $fix$;


-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
do $v$
declare
  v_out text := '';
  v_org uuid; v_store uuid; v_q uuid; v_tbl uuid; v_tbl2 uuid;
  v_r jsonb; v_sid uuid; v_n int; v_auto boolean;
begin
  v_out := v_out || E'\n⓪ 一次性回填' || E'\t' || coalesce(current_setting('migi.fix', true), '(沒有紀錄)');

  select q.id, q.org_id, q.store_id into v_q, v_org, v_store
    from match_queues q
   where exists (select 1 from match_queue_players p
                  where p.queue_id = q.id and p.left_at is null)
   order by q.updated_at desc limit 1;
  select t.id into v_tbl from tables t
   where t.store_id = v_store and t.is_active and t.deleted_at is null
     and not exists (select 1 from table_sessions s
                      where s.table_id=t.id and s.status='open' and s.deleted_at is null)
   order by t.sort_order nulls last limit 1;
  select t.id into v_tbl2 from tables t
   where t.store_id = v_store and t.is_active and t.deleted_at is null and t.id <> v_tbl
     and not exists (select 1 from table_sessions s
                      where s.table_id=t.id and s.status='open' and s.deleted_at is null)
   order by t.sort_order nulls last limit 1;

  if v_q is null or v_tbl is null or v_tbl2 is null then
    perform set_config('migi.v', v_out || E'\n🔴 取樣失敗' || E'\t' ||
      '房或空桌不足 —— 下面每一格都不算數', true);
    return;
  end if;

  -- 借成「四人到齊、還沒有桌、可以自動配」
  update match_queues set status='matched', matched_session_id=null,
         auto_seat = true, play_at = now() + interval '60 minutes', rounds='2 將'
   where id = v_q;

  ---- ① 第一次自動配桌 → 成功 ----------------------------
  v_r := public.sweep_auto_seat_tx(v_org);
  select matched_session_id into v_sid from match_queues where id = v_q;
  v_out := v_out || E'\n① 第一次自動配桌' || E'\t' ||
    case when v_sid is not null
         then '✅ 配到 ' || coalesce((select t.label from table_sessions s
                                      join tables t on t.id=s.table_id where s.id=v_sid), '?')
         else '🔴 沒配到：' || v_r::text end;

  ---- ② 取消 → 改成手動 ---------------------------------
  update table_sessions set status='voided', ended_at=now() where id = v_sid;
  select auto_seat into v_auto from match_queues where id = v_q;
  v_out := v_out || E'\n② 取消之後改成手動' || E'\t' ||
    case when v_auto is false then '✅ auto_seat = false' else '🔴 還是 ' || v_auto::text end;

  ---- ③ 🔴 排程不再自己配（這就是使用者要的規則）---------
  update match_queues set status='matched', matched_session_id=null where id = v_q;
  v_r := public.sweep_auto_seat_tx(v_org);
  select matched_session_id into v_sid from match_queues where id = v_q;
  v_out := v_out || E'\n③ 🔴 排程不再自己配' || E'\t' ||
    case when v_sid is null
         then '✅ 沒動它（等店員手動）　manual=' || coalesce(v_r->>'manual','?')
         else '🔴 又自己配了一張' end;

  ---- ④ 🎯 正對照：店員手動指定仍然配得到 -----------------
  /* 只驗 ③ 的話，一支**永遠不配**的實作也會綠 —— 那時沒有人配得到桌。 */
  v_r := public.pos_seat_queue_tx(v_org, v_q, v_tbl);
  select matched_session_id into v_sid from match_queues where id = v_q;
  v_out := v_out || E'\n④ 🎯 正對照：手動指定配得到' || E'\t' ||
    case when v_sid is not null then '✅ 配到 ' || (select label from tables where id=v_tbl)
         else '🔴 ' || coalesce(v_r->>'reason', v_r::text) end;

  ---- ⑤ 換桌 -------------------------------------------
  v_r := public.pos_move_session_tx(v_sid, v_tbl2);
  v_out := v_out || E'\n⑤ 換桌' || E'\t' ||
    case when coalesce((v_r->>'ok')::boolean,false)
         then '✅ ' || coalesce(v_r->>'from','?') || ' → ' || coalesce(v_r->>'to','?')
         else '🔴 ' || coalesce(v_r->>'reason', v_r::text) end;

  ---- ⑥ 🎯 正對照：換到自己現在這張要被擋 ----------------
  /* 只驗 ⑤ 的話，一支**無條件改 table_id** 的實作也會綠。 */
  v_r := public.pos_move_session_tx(v_sid, v_tbl2);
  v_out := v_out || E'\n⑥ 🎯 正對照：換到同一張要擋' || E'\t' ||
    case when (v_r->>'reason') = 'same_table' then '✅ same_table'
         else '🔴 ' || v_r::text end;

  ---- ⑦ 🎯 正對照：換桌不會弄斷房與場次的關聯 ------------
  select count(*) into v_n from match_queues
   where id = v_q and matched_session_id = v_sid;
  v_out := v_out || E'\n⑦ 🎯 正對照：房還指著同一個場次' || E'\t' ||
    case when v_n = 1 then '✅ 沒斷（換的是桌不是場次）' else '🔴 斷了' end;

  ---- ⑧ 🎯 正對照：換到有人的桌要被擋 --------------------
  /* 借一張「有 open 場次」的桌來試。找不到就出聲，不要安靜跳過。 */
  select s.table_id into v_tbl from table_sessions s
   where s.status='open' and s.deleted_at is null and s.id <> v_sid
     and s.store_id = v_store limit 1;
  if v_tbl is null then
    v_out := v_out || E'\n⑧ 🎯 正對照：換到有人的桌要擋' || E'\t' || '🟡 取樣失敗：現在沒有別的開著的桌';
  else
    v_r := public.pos_move_session_tx(v_sid, v_tbl);
    v_out := v_out || E'\n⑧ 🎯 正對照：換到有人的桌要擋' || E'\t' ||
      case when (v_r->>'reason') = 'table_busy' then '✅ table_busy（訊息說得出是哪一桌）'
           else '🔴 ' || v_r::text end;
  end if;

  raise exception 'migi_rollback';

exception when others then
  /* 🔴 訊息設在這裡，不是設在 raise 之前 —— `set_config(..., true)`
     會跟著 savepoint 一起回滾，那樣會印出**上一次執行**的舊結果。
     （硬規則 3.9） */
  perform set_config('migi.v',
    v_out || case when sqlerrm <> 'migi_rollback'
                  then E'\n🔴 驗證中斷' || E'\t' || sqlerrm else '' end, true);
end $v$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(coalesce(current_setting('migi.v', true), ''), E'\n')) as x
 where coalesce(x, '') <> '';
