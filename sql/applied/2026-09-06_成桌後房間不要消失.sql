/* ============================================================
   🔴 成桌之後房間從畫面上消失
   2026-09-06 · MIGI 咪吉麻將

   ── 症狀 ──────────────────────────────────────────────
   四個人湊滿 → 自動配到桌 → **配桌頁整個退回「我要配桌」**，
   而客人應該停在「你已經成桌囉！」那一頁（有導航與叫車過去）。

   ── 根因（查證，不是推測）────────────────────────────
   ```sql
   -- get_my_active_queue_tx 第一段
   and q.status in ('waiting','matched')      -- ← 沒有 'seated'
   ```
   ⇒ 房間變 `seated` 之後這支回 `null`
   ⇒ 前端 `if (!q) setPhase('idle')` ⇒ 房間消失。

   🔴 **而它比看起來嚴重**：`match_queues.status` 的 CHECK 允許
   `waiting / matched / seated / cancelled / expired`，
   但**沒有任何函式會把 `seated` 移出去** —— 它是終點狀態。
   ⇒ 客人不是「晚幾秒才看到」，是**永遠看不到成桌畫面**。

   ⚠ 這次是 `waiting → seated` **一步到位**（`matched_at` 與建桌
     都是 00:25:37）—— 中間那 5 秒的輪詢根本沒看到 `matched`。
     🎯 所以「先變 matched 再變 seated」這個假設本身就不成立，
       不能靠「至少會閃一下 matched」把畫面撐住。

   ── 🔴 不能只是把 'seated' 加進去 ──────────────────────
   它是終點狀態 ⇒ 加進去之後那個房間會**永遠留在畫面上**，
   客人明天打開 App 還看到「你已經成桌囉！」。

   ✅ 界線用「**那張桌還開著嗎**」（`match_queues.matched_session_id`
   → `table_sessions.status = 'open'`）：
   ```
   收桌（completed）／取消開桌（voided）→ 房間自然消失
   ```
   🎯 那個界線是**現成的事實**，不是新發明的規則 ——
     不需要新欄位、不需要新的排程去改狀態。

   ── ⚠ 簽名不變 ────────────────────────────────────────
   `CREATE OR REPLACE` ⇒ 不用 DROP、不丟 GRANT、沒有部署順序問題。
   ⚠ 前端也要改一行（`seated` → phase `'matched'`），
     但**兩邊互相不依賴**：後端先上只是讓資料回得來，
     前端先上也不會壞（那時 RPC 還是回 null）。
   ============================================================ */

create or replace function public.get_my_active_queue_tx(p_org_id uuid, p_member uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_qid uuid;
begin
  select q.id into v_qid
    from match_queue_players qp
    join match_queues q on q.id = qp.queue_id
   where qp.member_id = p_member and qp.left_at is null
     and q.org_id = p_org_id
     /* ★ 2026-09-06：加上 `seated`，但**要有界線**。
        🔴 `seated` 是終點狀態（沒有任何函式會把它移出去），
          無條件加進來的話，客人明天打開還看到「你已經成桌囉！」。
        ✅ 界線＝那張桌還開著。收桌（completed）或取消開桌（voided）
          之後它自然消失 —— 用的是現成的事實，不是新規則。
        ⚠ `matched_session_id` 可能是 null（POS 手動把房標成 seated
          的路徑），那時**不回** —— 寧可少顯示，也不要顯示一個
          指不到任何桌的「你已經成桌囉」。 */
     and (
       q.status in ('waiting','matched')
       or (q.status = 'seated' and exists (
             select 1 from table_sessions ts
              where ts.id = q.matched_session_id
                and ts.status = 'open'
                and ts.deleted_at is null))
     )
   order by qp.joined_at desc
   limit 1;
  if v_qid is null then return null; end if;
  return (
    select jsonb_build_object(
      'id', q.id, 'status', q.status, 'source', q.source, 'tags', q.tags,
      'store_id', q.store_id, 'stake_level_id', q.stake_level_id,
      'game_type', q.game_type, 'flower', q.flower, 'rounds', q.rounds, 'seats', q.seats,
      'play_at', q.play_at, 'opened_by', q.opened_by,
      'is_host', (q.opened_by = p_member),
      'players', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'member_id', m.id, 'nickname', m.display_name, 'rank', m.rank,
          'avatar_url', m.avatar_url, 'joined_at', qp2.joined_at,
          'avatar_source', m.avatar_source, 'avatar_photo_path', m.avatar_photo_path,
          'avatar_bear', m.avatar_bear
        ) order by qp2.joined_at), '[]'::jsonb)
        from match_queue_players qp2
        join members m on m.id = qp2.member_id
        where qp2.queue_id = q.id and qp2.left_at is null
      ),
      'player_count', (
        select count(*) from match_queue_players
         where queue_id = q.id and left_at is null
      ),
      /* ★ 本桌動態：每人一筆加入 + 有離開者加一筆離開。
         **只取最近 10 筆**，再依時間由舊到新排回來。
         舊版無條件全撈，開一天的房會累積十幾二十行把牌局資訊擠出畫面。 */
      'events', (
        select coalesce(jsonb_agg(ev.e order by ev.at_ts), '[]'::jsonb)
        from (
          select all_ev.e, all_ev.at_ts
          from (
            -- 加入事件
            select jsonb_build_object('type','join','nickname', m.display_name, 'at', qp3.joined_at) as e,
                   qp3.joined_at as at_ts
              from match_queue_players qp3 join members m on m.id = qp3.member_id
             where qp3.queue_id = q.id
            union all
            -- 離開事件（只取有 left_at 的）
            select jsonb_build_object('type','leave','nickname', m.display_name, 'at', qp3.left_at) as e,
                   qp3.left_at as at_ts
              from match_queue_players qp3 join members m on m.id = qp3.member_id
             where qp3.queue_id = q.id and qp3.left_at is not null
          ) all_ev
          order by all_ev.at_ts desc
          limit 10
        ) ev
      )
    )
    from match_queues q where q.id = v_qid
  );
end $function$;


-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
do $v$
declare
  v_out text := '';
  v_q   uuid; v_sess uuid; v_org uuid; v_mem uuid; v_other uuid;
  v_r   jsonb; v_n int;
begin
  ---- 取樣：現在那個 seated 的房 -------------------------
  select q.id, q.matched_session_id, q.org_id
    into v_q, v_sess, v_org
    from match_queues q
   where q.status = 'seated'
     and exists (select 1 from table_sessions ts
                  where ts.id = q.matched_session_id and ts.status = 'open')
   order by q.created_at desc limit 1;

  select qp.member_id into v_mem
    from match_queue_players qp where qp.queue_id = v_q and qp.left_at is null limit 1;

  /* 🔴 取樣失敗要出聲，不要安靜跳過 —— 下面每一格都會變成假的通過。 */
  if v_q is null or v_mem is null then
    perform set_config('migi.v', E'\n🔴 取樣失敗' || E'\t' ||
      '找不到「seated 且桌還開著」的房 —— 下面每一格都不算數', true);
    return;
  end if;

  ---- ① seated ＋ 桌還開著 → 要回得到房 ------------------
  v_r := public.get_my_active_queue_tx(v_org, v_mem);
  v_out := v_out || E'\n① seated 且桌還開著 → 回得到房' || E'\t' ||
    case when v_r is not null and (v_r ->> 'status') = 'seated'
         then '✅ 回了，status=seated，' || (v_r ->> 'player_count') || ' 人'
         else '🔴 回 null —— 房間還是會消失' end;

  ---- ② 🎯 正對照：桌收掉之後 → 要變回 null --------------
  /* 🔴 這一格才是「不會永遠留在畫面上」的證據。
     只驗 ① 的話，一支**無條件回傳**的實作也會綠。 */
  update table_sessions set status = 'completed' where id = v_sess;
  v_r := public.get_my_active_queue_tx(v_org, v_mem);
  v_out := v_out || E'\n② 🎯 正對照：收桌後 → 房間消失' || E'\t' ||
    case when v_r is null then '✅ 回 null' else '🔴 還回著房，會永遠留在畫面上' end;

  ---- ③ 🎯 正對照：作廢的桌也要消失 ----------------------
  update table_sessions set status = 'voided' where id = v_sess;
  v_r := public.get_my_active_queue_tx(v_org, v_mem);
  v_out := v_out || E'\n③ 🎯 正對照：取消開桌後 → 房間消失' || E'\t' ||
    case when v_r is null then '✅ 回 null' else '🔴 還回著房' end;

  update table_sessions set status = 'open' where id = v_sess;   -- 還原（反正整段會回滾）

  ---- ④ 🎯 正對照：waiting 沒有被誤傷 --------------------
  update match_queues set status = 'waiting' where id = v_q;
  v_r := public.get_my_active_queue_tx(v_org, v_mem);
  v_out := v_out || E'\n④ 🎯 正對照：waiting 仍然回得到' || E'\t' ||
    case when v_r is not null and (v_r ->> 'status') = 'waiting'
         then '✅ 沒有誤傷' else '🔴 waiting 也回不來了' end;

  ---- ⑤ 🎯 正對照：不在這個房裡的人回 null ---------------
  update match_queues set status = 'seated' where id = v_q;
  select m.id into v_other from members m
   where m.deleted_at is null
     and not exists (select 1 from match_queue_players qp
                      where qp.queue_id = v_q and qp.member_id = m.id and qp.left_at is null)
   limit 1;
  if v_other is null then
    v_out := v_out || E'\n⑤ 🎯 正對照：別人看不到這個房' || E'\t' || '🔴 取樣失敗：找不到不在房裡的會員';
  else
    v_out := v_out || E'\n⑤ 🎯 正對照：別人看不到這個房' || E'\t' ||
      case when public.get_my_active_queue_tx(v_org, v_other) is null
           then '✅ 回 null' else '🔴 看得到別人的房' end;
  end if;

  ---- ⑥ 掃全庫：還有誰寫死 in ('waiting','matched') ------
  /* 禁字用**函式名不用欄位名**（硬規則 3.5）——
     這裡掃的是一段完整的 SQL 片段，不會撞到說明文字。 */
  select count(*) into v_n
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prokind = 'f'
     and pg_get_functiondef(p.oid) ~ 'status\s+in\s*\(\s*''waiting''\s*,\s*''matched''\s*\)';
  v_out := v_out || E'\n⑥ 還有幾支寫死 waiting+matched' || E'\t' ||
    case when v_n = 0 then '✅ 0 支'
         else '🟡 ' || v_n || ' 支 —— 逐一看是不是同一個問題' end;

  raise exception 'migi_rollback';

exception when others then
  /* 🔴 訊息設在這裡，不是設在上面再 raise（硬規則 3.9：
     `is_local = true` 的設定會跟著 savepoint 一起回滾掉）。 */
  perform set_config('migi.v',
    v_out || case when sqlerrm <> 'migi_rollback'
                  then E'\n🔴 驗證中斷' || E'\t' || sqlerrm else '' end, true);
end $v$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(coalesce(current_setting('migi.v', true), ''), E'\n')) as x
 where coalesce(x, '') <> '';
