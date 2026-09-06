/* ============================================================
   成桌之後不能再報名別的房 ＋「這個房還活著嗎」收成一份定義
   2026-09-06 · MIGI 咪吉麻將

   ── 使用者發現的 ────────────────────────────────────────
   「為何我可以成桌後還能繼續加入配桌？」

   `_check_join_conflict` 只掃 `waiting` 與 `matched`：
   ```sql
   where qp.member_id = p_member and qp.left_at is null
     and q.status in ('waiting', 'matched')      -- ← 沒有 'seated'
   ```
   ⇒ 桌都帶好了、人正要去店裡，**還能再開一桌**。
   而那條規則本身寫著「同時只能參加一場」。

   🔴 **我稍早看到這件事時說「好消息：不會卡住他們」** ——
     那是把 bug 講成好處。它確實不會卡住人，但代價是規則失效。

   ── ⚠ 為什麼不能只是把 'seated' 加進去 ─────────────────
   `seated` 是**終點狀態**：牌局打完、收桌之後，房還是 `seated`
   （沒有任何函式會把它移出去）。
   ⇒ 無條件加進去的話，**打過一場的人從此永遠報不了名**，
     而那比現在這個洞嚴重得多。

   ✅ 界線與同日另外兩支一致：**那張桌還開著才算數**。
   ```
   桌 open        → 這個房還活著 → 擋
   桌 completed   → 打完了       → 放行
   桌 voided      → 桌沒了       → 放行（而且觸發器會把房放回 waiting）
   ```

   ── 🎯 順帶：同一個述詞已經出現在三個地方 ──────────────
   `get_my_active_queue_tx` / `pos_list_queues_tx` 都在做
   「seated 且桌還開著」這件事，加上這一支就是**第三份**。
   而「同一個概念多份定義」是這個專案一再記錄的病
   （`wallet_txns.type`／`staff.role`／`players`／`score_points`／
     `has_store_access()` 與 `can()`）。
   ⇒ 收成 `migi_seat_is_live(session_id)`，三支都改用它。
   ⚠ 只抽**共通的那一半**（seated 的界線），
     不要把三支各自不同的條件（`expires_at`／`open_at`／org 過濾）
     也硬塞進來 —— 那會變成一個誰都看不懂的萬用函式。
   ============================================================ */

-- ══════════════════════════════════════════════════════
-- ① 唯一的定義：這個配桌房佔的桌還活著嗎
-- ══════════════════════════════════════════════════════
create or replace function public.migi_seat_is_live(p_session uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1 from table_sessions ts
     where ts.id = p_session
       and ts.status = 'open'
       and ts.deleted_at is null)
$$;

/* ⚠ 內部輔助函式，只被 SECURITY DEFINER 從內部呼叫 ⇒ 不需要給前端角色。
   🔴 兩個方向都要收（硬規則 2.6／2.6b）：
     舊函式的 anon 來自 PUBLIC 繼承、**新建**函式的 anon 是 default
     privileges 明確授權。收錯方向的症狀跟沒收一模一樣。 */
revoke execute on function public.migi_seat_is_live(uuid) from public;
revoke execute on function public.migi_seat_is_live(uuid) from anon, authenticated;
grant  execute on function public.migi_seat_is_live(uuid) to service_role;


-- ══════════════════════════════════════════════════════
-- ② 報名衝突檢查：把 seated 納入
-- ══════════════════════════════════════════════════════
create or replace function public._check_join_conflict(
  p_org_id uuid, p_member uuid, p_play_at timestamp with time zone, p_source text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r record;
  v_target_is_fix boolean := (p_source = 'recurring');
  v_row_is_fix boolean;
begin
  /* 掃身上所有「還沒結束」的場。
     ★ 2026-09-06：加入 `seated`（已經帶到桌、正要去店裡）——
       在此之前成桌之後還能再開一桌，而這支的規則本身寫著
       「同時只能參加一場」。
     🔴 但**必須綁「那張桌還開著」** —— `seated` 是終點狀態，
       打完收桌之後房仍然是 seated，無條件擋的話
       **打過一場的人從此永遠報不了名**。 */
  for r in
    select q.play_at, q.source
      from match_queue_players qp
      join match_queues q on q.id = qp.queue_id
     where qp.member_id = p_member
       and qp.left_at is null
       and q.org_id = p_org_id
       and (
         q.status in ('waiting', 'matched')
         or (q.status = 'seated' and public.migi_seat_is_live(q.matched_session_id))
       )
  loop
    v_row_is_fix := (r.source = 'recurring');
    -- ① 即時局最多一場：目標是即時局、身上已有即時局
    if not v_target_is_fix and not v_row_is_fix then
      raise exception '你已報名即時牌局，同時只能參加一場';
    end if;
    -- ② 固定局最多一場：目標是固定局、身上已有固定局
    if v_target_is_fix and v_row_is_fix then
      raise exception '你已報名固定牌局，同時只能參加一場';
    end if;
    -- ③ 任一場 play_at 跟目標場差 < 6 小時 → 擋（跨類型也要守）
    if abs(extract(epoch from (r.play_at - p_play_at))) < 6 * 3600 then
      raise exception '你已有一場 % 的牌局，時間太近無法同時報名（需間隔 6 小時以上）',
        to_char(r.play_at, 'MM/DD HH24:MI');
    end if;
  end loop;
end $function$;

/* 🔴 順帶補一個原本就漏的條件：`q.org_id = p_org_id`。
   舊版**完全沒有比對 org** —— 目前只有一個 org 所以踩不到，
   但那是運氣不是設計（同 2026-08-27 `join_session_tx` 補 org 比對）。 */


-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
do $v$
declare
  v_out text := '';
  v_q uuid; v_sess uuid; v_org uuid; v_mem uuid;
  v_play timestamptz; v_n int; v_err text;
begin
  select q.id, q.matched_session_id, q.org_id, q.play_at
    into v_q, v_sess, v_org, v_play
    from match_queues q
   where q.matched_session_id is not null
     and exists (select 1 from match_queue_players p
                  where p.queue_id = q.id and p.left_at is null)
   order by q.updated_at desc limit 1;
  select qp.member_id into v_mem
    from match_queue_players qp where qp.queue_id = v_q and qp.left_at is null limit 1;

  if v_q is null or v_mem is null then
    perform set_config('migi.v', E'\n🔴 取樣失敗' || E'\t' ||
      '找不到「有 session 且還有人在座」的房 —— 下面每一格都不算數', true);
    return;
  end if;

  -- 借用樣本：房 seated、桌 open（＝正在「成桌中」）
  update match_queues set status = 'seated', matched_session_id = v_sess where id = v_q;
  update table_sessions set status = 'open', ended_at = null where id = v_sess;

  ---- ① 成桌中 → 不能再報名（這就是那個洞）---------------
  /* ⚠ 時間刻意錯開 12 小時，**繞過第 ③ 條「6 小時內」的擋牆** ——
     不錯開的話這一格會被那條擋下，而我們就分不出擋住它的是
     「成桌中」還是「時間太近」。 */
  begin
    perform public._check_join_conflict(v_org, v_mem, v_play + interval '12 hours', 'member');
    v_out := v_out || E'\n① 成桌中不能再報名' || E'\t' || '🔴 竟然放行了';
  exception when others then
    v_err := sqlerrm;
    v_out := v_out || E'\n① 成桌中不能再報名' || E'\t' ||
      case when v_err like '%只能參加一場%' then '✅ 擋住了：' || v_err
           else '🟡 被別的理由擋下：' || v_err end;
  end;

  ---- ② 🎯 正對照：桌收掉之後要放行 ----------------------
  /* 🔴 這一格最重要：只驗 ① 的話，一支**無條件擋 seated** 的實作也會綠，
     而症狀是**打過一場的人從此永遠報不了名**（seated 是終點狀態）。 */
  update table_sessions set status = 'completed', ended_at = now() where id = v_sess;
  begin
    perform public._check_join_conflict(v_org, v_mem, v_play + interval '12 hours', 'member');
    v_out := v_out || E'\n② 🎯 正對照：收桌後可以再報名' || E'\t' || '✅ 放行';
  exception when others then
    v_out := v_out || E'\n② 🎯 正對照：收桌後可以再報名' || E'\t' ||
      '🔴 還是被擋：' || sqlerrm || '（打過一場的人會永遠報不了名）';
  end;

  ---- ③ 桌作廢 → 房回 waiting → 仍然擋（兩份 SQL 的交互作用）----
  /* 🔴 **第一版這一格的期望值是錯的**（2026-09-06，硬規則 3.56）。
     我寫「桌作廢後可以再報名」，實際是**擋住** —— 而擋住才是對的：
     `update ... set status='voided'` 會觸發同日裝的
     `trg_session_voided_release_queue`，它把房**放回 `waiting`**
     （人還在等下一張桌）⇒ 那個人確實還在一個等待中的房裡。
     ⚠ 我寫那一格時忘了兩份 SQL 會互相作用。
     🎯 真正要防的「永遠被卡住」由 ② 守著（收桌後放行）。 */
  update match_queues set status = 'seated', matched_session_id = v_sess where id = v_q;
  update table_sessions set status = 'open', ended_at = null where id = v_sess;
  update table_sessions set status = 'voided', ended_at = now() where id = v_sess;

  select status into v_err from match_queues where id = v_q;
  v_out := v_out || E'\n③ 桌作廢後房被放回' || E'\t' ||
    case when v_err in ('waiting','expired') then '✅ ' || v_err || '（觸發器接手了，不再是孤兒）'
         else '🔴 還是 ' || v_err end;

  begin
    perform public._check_join_conflict(v_org, v_mem, v_play + interval '12 hours', 'member');
    v_out := v_out || E'\n③b 放回 waiting 之後仍然擋' || E'\t' ||
      case when v_err = 'waiting' then '🔴 放行了 —— 他明明還在一個等待中的房裡'
           else '✅ 放行（房已流局，本來就該放）' end;
  exception when others then
    v_out := v_out || E'\n③b 放回 waiting 之後仍然擋' || E'\t' ||
      case when v_err = 'waiting' then '✅ 擋住了（正確：人還在等下一張桌）'
           else '🔴 房已流局卻還被擋：' || sqlerrm end;
  end;

  ---- ④ 🎯 正對照：waiting 的既有規則沒被改壞 ------------
  update table_sessions set status = 'open' where id = v_sess;
  update match_queues set status = 'waiting' where id = v_q;
  begin
    perform public._check_join_conflict(v_org, v_mem, v_play + interval '12 hours', 'member');
    v_out := v_out || E'\n④ 🎯 正對照：waiting 仍然擋得住' || E'\t' || '🔴 放行了 —— 舊規則被改壞';
  exception when others then
    v_out := v_out || E'\n④ 🎯 正對照：waiting 仍然擋得住' || E'\t' ||
      case when sqlerrm like '%只能參加一場%' then '✅ 擋住了' else '🟡 ' || sqlerrm end;
  end;

  ---- ⑤ 🎯 正對照：不在任何房裡的人可以報名 --------------
  update match_queues set status = 'seated' where id = v_q;
  /* ⚠ 條件要跟**函式的判準一致**：問的是「有沒有**還活著**的房」，
     不是「有沒有任何房」。第一版寫成後者，於是每個會員都被排除掉
     （他們身上都有過期／取消的舊房）⇒ 取樣失敗，那一格等於沒驗。 */
  select m.id into v_mem from members m
   where m.deleted_at is null
     and not exists (
       select 1 from match_queue_players p
         join match_queues q on q.id = p.queue_id
        where p.member_id = m.id and p.left_at is null
          and (q.status in ('waiting','matched')
               or (q.status = 'seated' and public.migi_seat_is_live(q.matched_session_id))))
   limit 1;
  if v_mem is null then
    v_out := v_out || E'\n⑤ 🎯 正對照：沒房的人可以報名' || E'\t' || '🟡 取樣失敗：每個會員都在某個房裡';
  else
    begin
      perform public._check_join_conflict(v_org, v_mem, now() + interval '3 hours', 'member');
      v_out := v_out || E'\n⑤ 🎯 正對照：沒房的人可以報名' || E'\t' || '✅ 放行';
    exception when others then
      v_out := v_out || E'\n⑤ 🎯 正對照：沒房的人可以報名' || E'\t' || '🔴 被誤擋：' || sqlerrm;
    end;
  end if;

  ---- ⑥ ⏳ 「seated 且桌還開著」目前有幾份寫法 -----------
  /* ⚠ **這一格是提示不是通過條件。**
     這一份只讓 `_check_join_conflict` 改用 `migi_seat_is_live`，
     另外兩支**沒有動**：
     · `get_my_active_queue_tx` —— 一樣是 EXISTS 形，可以換
     · `pos_list_queues_tx`     —— 它本來就 join 了 `ts`，
        寫成 `ts.status = 'open'`，形狀不同
     🔴 所以現在是**兩份寫法**，而「同一個概念多份定義」正是這個專案
       一再記錄的病。沒有一起改是**風險取捨**：那兩支剛驗過、正在線上跑，
       為了統一寫法重貼一百行函式體，出錯的機會比收益大。
     → 下次真的要動那兩支時一起換掉。**寫在這裡就是不讓它被忘記。** */
  select count(*) into v_n
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname <> 'migi_seat_is_live'
     and pg_get_functiondef(p.oid) ~ '''seated''';
  v_out := v_out || E'\n⑥ ⏳ 提到 seated 的函式數' || E'\t' ||
    v_n || ' 支（本份只統一了 _check_join_conflict，另外兩支見註解）';

  raise exception 'migi_rollback';

exception when others then
  /* 🔴 訊息設在這裡（硬規則 3.9）。 */
  perform set_config('migi.v',
    v_out || case when sqlerrm <> 'migi_rollback'
                  then E'\n🔴 驗證中斷' || E'\t' || sqlerrm else '' end, true);
end $v$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(coalesce(current_setting('migi.v', true), ''), E'\n')) as x
 where coalesce(x, '') <> '';
