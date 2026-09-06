/* ============================================================
   🔴 可以開一個「開打時間在過去」的房，而且它的存活期與開打時間無關
   2026-09-06 · MIGI 咪吉麻將
   ⚠ 這一份**有真的寫入**（清掉已經過了開打時間的房），不是只有 DDL。

   ── 怎麼發現的 ────────────────────────────────────────
   準備跑完整配桌流程時，發現測試04 卡在一個房裡：
   ```
   7f6b99ac   建立 10:04:17   開打 03:30（七小時前）   過期 12:04
   ```
   **10:04 建立的房，開打時間填 03:30。**

   ── 兩個獨立的問題 ────────────────────────────────────
   ① `create_match_queue_tx` **對 `p_play_at` 完全沒有驗證**
      —— 函式體只有 `_check_join_conflict` 然後直接 insert。
      ⇒ 開一個開打時間在過去的房是合法的。

   ② `expires_at` 吃欄位預設 `now() + 2h`，**完全不看 `play_at`**：
      | | `expires_at` |
      |---|---|
      | 固定牌局（`generate_recurring_instances_tx`） | `= play_at` ✅ |
      | 會員開的房 | `= 建立 + 2 小時` 🔴 |
      ⇒ 「明天 20:00 的房」兩小時後就過期（客人以為還在等，其實流局了）；
        「七小時前 03:30 的房」反而活到 12:04（卡住那個人不能報別的名）。
      🎯 **同一件事兩套規則，而對的那一套已經寫在固定牌局那條路上了。**

   ── 修法 ──────────────────────────────────────────────
   · `p_play_at` 在過去 → 直接擋，訊息講得出時間
   · `expires_at` 明寫成 `p_play_at`（與固定牌局一致）
     🎯 語意：`play_at` 是「**最晚**開打」，過了那個時間這個房就沒有意義。
   · **一次性**：把已經過了開打時間、還在 `waiting` 的房收掉 ——
     做法是把它們的 `expires_at` 拉到 `play_at`，然後**呼叫既有的
     `sweep_expired_queues_tx()`**。
     ⚠ **不要自己再寫一份流局邏輯** —— 那支已經處理了標流局、
       發通知、標記離開三件事。複製一份就是第二個定義。

   ⚠ 簽名不變 ⇒ `CREATE OR REPLACE`、不用 DROP、不丟 GRANT。
   ============================================================ */

create or replace function public.create_match_queue_tx(
  p_org_id uuid, p_opener uuid, p_store uuid, p_stake uuid,
  p_play_at timestamp with time zone,
  p_game_type text default '台麻', p_rounds text default '2 將',
  p_seats integer default 4, p_prefs jsonb default '{}'::jsonb,
  p_flower text default '無花')
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_qid uuid;
begin
  /* ★ 2026-09-06：開打時間不可以在過去。
     🔴 在此之前**完全沒有驗證** —— 2026-09-06 10:04 真的建出一個
       開打時間 03:30 的房，而它還把那個人卡住不能報別的名。
     ⚠ 訊息要**講得出那個時間**：只寫「時間不正確」的話，
       客人不知道是自己選錯還是系統壞了。
     ⚠ 留 5 分鐘寬限 —— 客人選「現在」到按下送出之間會過幾秒，
       而卡在整分鐘邊界被拒絕是很莫名其妙的體驗。 */
  if p_play_at is null then
    raise exception '請選擇最晚開打時間';
  end if;
  if p_play_at < now() - interval '5 minutes' then
    raise exception '最晚開打時間（%）已經過了，請重新選擇',
      to_char(p_play_at at time zone 'Asia/Taipei', 'MM/DD HH24:MI');
  end if;

  perform _check_join_conflict(p_org_id, p_opener, p_play_at, 'member');

  insert into match_queues(
    org_id, store_id, stake_level_id, game_type, flower, rounds,
    seats, prefs, opened_by, play_at,
    /* ★ 2026-09-06：明寫 `expires_at = play_at`，與固定牌局那條路一致。
       🔴 舊版吃欄位預設 `now() + 2h`，**與開打時間無關** ⇒
         「明天 20:00 的房」兩小時後就流局（客人以為還在等），
         「已經過了的房」反而活到建立後兩小時（把人卡住）。
       🎯 `play_at` 的語意是「**最晚**開打」—— 過了它，這個房就沒有意義。 */
    expires_at)
  values (
    p_org_id, p_store, p_stake, p_game_type, p_flower, p_rounds,
    p_seats, p_prefs, p_opener, p_play_at,
    p_play_at)
  returning id into v_qid;

  insert into match_queue_players(org_id, queue_id, member_id, join_source)
  values (p_org_id, v_qid, p_opener, 'open');

  return v_qid;
end $function$;


-- ══════════════════════════════════════════════════════
-- 一次性：收掉已經過了開打時間、卻還在 waiting 的房
-- ══════════════════════════════════════════════════════
do $fix$
declare v_n int; v_swept int;
begin
  /* 🎯 **不自己寫流局邏輯** —— 只把 `expires_at` 拉到 `play_at`，
     然後呼叫既有的 `sweep_expired_queues_tx()`。
     那支已經處理了標流局、發通知、標記離開三件事；
     複製一份就是第二個定義（這個專案一再記錄的病）。
     ⚠ 只動 `source = 'member'` 的：固定牌局的 `expires_at` 本來就對，
       而且它們由排程再生，不該被這裡碰。 */
  update match_queues
     set expires_at = play_at, updated_at = now()
   where status = 'waiting'
     and source = 'member'
     and play_at < now()
     and expires_at > play_at;
  get diagnostics v_n = row_count;

  select public.sweep_expired_queues_tx() into v_swept;

  perform set_config('migi.fix',
    v_n::text || ' 個過時的房被拉回正確的過期時間，sweep 清掉 ' || v_swept::text || ' 個', true);
end $fix$;


-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
do $v$
declare
  v_out text := '';
  v_org uuid; v_mem uuid; v_store uuid; v_stake uuid; v_qid uuid; v_n int;
  v_exp timestamptz; v_play timestamptz;
begin
  v_out := v_out || E'\n⓪ 一次性清理' || E'\t' || coalesce(current_setting('migi.fix', true), '(沒有紀錄)');

  select s.org_id, s.id into v_org, v_store from stores s
   where s.is_active and s.deleted_at is null limit 1;
  select id into v_stake from stake_levels order by created_at limit 1;
  /* 取一個**沒有活著的房**的會員，否則會撞到 `_check_join_conflict`
     而我們就分不出擋住它的是時間還是衝突（同 2026-09-06 那次教訓）。 */
  select m.id into v_mem from members m
   where m.deleted_at is null
     and not exists (
       select 1 from match_queue_players p join match_queues q on q.id = p.queue_id
        where p.member_id = m.id and p.left_at is null
          and (q.status in ('waiting','matched')
               or (q.status = 'seated' and exists (
                     select 1 from table_sessions ts
                      where ts.id = q.matched_session_id
                        and ts.status='open' and ts.deleted_at is null))))
   limit 1;

  if v_mem is null or v_store is null or v_stake is null then
    perform set_config('migi.v', v_out || E'\n🔴 取樣失敗' || E'\t' ||
      '會員／門市／級距有一個找不到 —— 下面每一格都不算數', true);
    return;
  end if;

  ---- ① 開打時間在過去 → 擋 ------------------------------
  begin
    v_qid := public.create_match_queue_tx(v_org, v_mem, v_store, v_stake, now() - interval '3 hours');
    v_out := v_out || E'\n① 過去的開打時間被擋' || E'\t' || '🔴 竟然建出來了';
  exception when others then
    v_out := v_out || E'\n① 過去的開打時間被擋' || E'\t' ||
      case when sqlerrm like '%已經過了%' then '✅ ' || sqlerrm
           else '🟡 被別的理由擋下：' || sqlerrm end;
  end;

  ---- ② 🎯 正對照：未來的時間要放行 ----------------------
  /* 只驗 ① 的話，一支**什麼都擋**的實作也會綠 ——
     而症狀是沒有人開得了房。 */
  v_play := now() + interval '4 hours';
  begin
    v_qid := public.create_match_queue_tx(v_org, v_mem, v_store, v_stake, v_play);
    v_out := v_out || E'\n② 🎯 正對照：未來的時間放行' || E'\t' ||
      case when v_qid is not null then '✅ 建出來了' else '🔴 沒有 id' end;
  exception when others then
    v_out := v_out || E'\n② 🎯 正對照：未來的時間放行' || E'\t' || '🔴 被誤擋：' || sqlerrm;
  end;

  ---- ③ expires_at 跟著 play_at ------------------------
  if v_qid is not null then
    select expires_at, play_at into v_exp, v_play from match_queues where id = v_qid;
    v_out := v_out || E'\n③ expires_at = play_at' || E'\t' ||
      case when v_exp = v_play then '✅ 一致（舊版是建立 + 2 小時）'
           else '🔴 差 ' || round(extract(epoch from (v_exp - v_play))/60) || ' 分鐘' end;
  end if;

  ---- ④ 🎯 正對照：現在沒有「開打時間已過」的 waiting 房 --
  select count(*) into v_n from match_queues
   where status = 'waiting' and play_at < now();
  v_out := v_out || E'\n④ 🎯 正對照：沒有過時還在等的房' || E'\t' ||
    case when v_n = 0 then '✅ 0 個' else '🔴 還有 ' || v_n || ' 個' end;

  ---- ⑤ 🎯 正對照：固定牌局那條路沒被改壞 ----------------
  select count(*) into v_n from match_queues
   where status = 'waiting' and source = 'recurring';
  v_out := v_out || E'\n⑤ 🎯 正對照：固定牌局還在' || E'\t' ||
    case when v_n > 0 then '✅ ' || v_n || ' 個（沒有被誤清）' else '🔴 0 個 —— 清過頭了' end;

  raise exception 'migi_rollback';

exception when others then
  /* 🔴 訊息設在這裡（硬規則 3.9）。
     ⚠ ①②③ 有真的 insert，靠這個 raise 回滾；
       但上面那個一次性清理是**另一個 DO 區塊**，不受影響。 */
  perform set_config('migi.v',
    v_out || case when sqlerrm <> 'migi_rollback'
                  then E'\n🔴 驗證中斷' || E'\t' || sqlerrm else '' end, true);
end $v$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(coalesce(current_setting('migi.v', true), ''), E'\n')) as x
 where coalesce(x, '') <> '';
