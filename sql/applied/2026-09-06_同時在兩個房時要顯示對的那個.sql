/* ============================================================
   🔴 一個人在兩個房時，App 顯示了錯的那一個
   2026-09-06 · MIGI 咪吉麻將
   ⚠ 這一份**有真的寫入**（清理殘留資料），不是只有 DDL。

   ── 使用者看到的 ────────────────────────────────────────
   「我還在第二桌」—— 畫面顯示「正在等待配桌… 目前 2/4」，
   但實際上他**已經被自動配到桌了**：

   ```
   6f7c8b11  01:26 建立  seated   桌 open    4/4  02:30 開打   ← 真正的桌
   9d0101de  01:32 建立  waiting  沒有桌     2/4              ← 畫面顯示這個
   019d1afc  00:01 建立  seated   桌 voided  4/4              ← 孤兒（A3）
   ```

   ── 根因 ──────────────────────────────────────────────
   ```sql
   -- get_my_active_queue_tx
   order by qp.joined_at desc limit 1      -- ← 誰晚加入就顯示誰
   ```
   在「同時只能一個房」成立的世界裡這樣寫沒問題。
   但 `_check_join_conflict` 漏了 `seated`（同日已修），
   於是真的長出了「一個人兩個房」的資料 ——
   而那時這個排序**必定挑到後加入的那個**，也就是**沒有桌的那個**。

   🎯 **修守衛不會修好已經產生的資料。**
   已經同時在兩個房裡的人，需要 ① 排序改成優先顯示活著的房
   ② 清掉殘留。兩件都要做，缺一個都還是壞的。

   ── 這一份做三件事 ────────────────────────────────────
   ① `get_my_active_queue_tx` 排序改成「**活著的房優先**」
      —— 這是防禦性的：即使日後又出現重複，畫面至少會顯示對的那個。
   ② **一次性**：釋放孤兒房（`seated` 但桌已不在）——
      套用與 `trg_session_voided_release_queue` 完全相同的規則。
      🔴 那個觸發器只對「今後」的作廢生效，追不回 01:00 那次。
   ③ **一次性**：同時在多個活著的房裡的人，只留最該留的那個，
      其餘標 `leave_reason = 'switched'`
      （CHECK 允許 `quit / cancelled / expired / switched`，
        而 `switched` 正是為這種情況存在的值 —— 不用改約束）。

   ⚠ ②③ 是**真的寫入**，不回滾。驗證段只讀不寫。
   ============================================================ */

-- ══════════════════════════════════════════════════════
-- ① 排序：活著的房優先
-- ══════════════════════════════════════════════════════
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
     and (
       q.status in ('waiting','matched')
       or (q.status = 'seated' and exists (
             select 1 from table_sessions ts
              where ts.id = q.matched_session_id
                and ts.status = 'open'
                and ts.deleted_at is null))
     )
   /* ★ 2026-09-06：**活著的房優先**，不要只看誰晚加入。
      🔴 舊版是 `order by qp.joined_at desc` —— 一個人同時在兩個房時
        必定挑到後加入的那個，而那通常是**還沒有桌**的那個
        ⇒ 客人已經被配到桌了，畫面卻寫「還差 2 位」。
      ⚠ 這是**防禦性**的：`_check_join_conflict` 修好之後理論上不會再有
        重複，但「理論上不會發生」不是把排序寫錯的理由。
      📌 順序＝離開打最近的那一步：已帶到桌 › 已成桌 › 還在等。 */
   order by case q.status when 'seated' then 0 when 'matched' then 1 else 2 end,
            qp.joined_at desc
   limit 1;
  if v_qid is null then return null; end if;
  return (
    select jsonb_build_object(
      'id', q.id, 'status', q.status, 'source', q.source, 'tags', q.tags,
      'store_id', q.store_id, 'stake_level_id', q.stake_level_id,
      'game_type', q.game_type, 'flower', q.flower, 'rounds', q.rounds, 'seats', q.seats,
      'play_at', q.play_at, 'opened_by', q.opened_by,
      'is_host', (q.opened_by = p_member),
      'store_name',    st.name,
      'store_address', st.address,
      'stake_label',   sl.label,
      'table_label',   tb.label,
      'activated_at',  ts.activated_at,
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
      'events', (
        select coalesce(jsonb_agg(ev.e order by ev.at_ts), '[]'::jsonb)
        from (
          select all_ev.e, all_ev.at_ts
          from (
            select jsonb_build_object('type','join','nickname', m.display_name, 'at', qp3.joined_at) as e,
                   qp3.joined_at as at_ts
              from match_queue_players qp3 join members m on m.id = qp3.member_id
             where qp3.queue_id = q.id
            union all
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
    from match_queues q
    left join stores       st on st.id = q.store_id
    left join stake_levels sl on sl.id = q.stake_level_id
    left join table_sessions ts on ts.id = q.matched_session_id
    left join tables       tb on tb.id = ts.table_id
   where q.id = v_qid
  );
end $function$;


-- ══════════════════════════════════════════════════════
-- ② 一次性：釋放孤兒房（seated 但桌已不在）
-- ══════════════════════════════════════════════════════
do $fix1$
declare r record; v_n int := 0; v_out text := '';
begin
  for r in
    select q.id, q.org_id, q.play_at, q.source
      from match_queues q
     where q.status = 'seated'
       and not exists (select 1 from table_sessions ts
                        where ts.id = q.matched_session_id
                          and ts.status = 'open' and ts.deleted_at is null)
     for update
  loop
    /* 與 `trg_session_voided_release_queue` **完全相同的規則** ——
       兩邊不一致的話，同一個情況會依「是誰處理的」得到不同結果。 */
    if now() < r.play_at + interval '30 minutes' then
      update match_queues
         set status = 'waiting', matched_session_id = null, matched_at = null,
             expires_at = greatest(expires_at, play_at, now() + interval '15 minutes'),
             updated_at = now()
       where id = r.id;
      v_out := v_out || r.id::text || '→waiting ';
    else
      update match_queues set status = 'expired', updated_at = now() where id = r.id;
      update match_queue_players set left_at = now(), leave_reason = 'expired'
       where queue_id = r.id and left_at is null;
      v_out := v_out || r.id::text || '→expired ';
    end if;
    v_n := v_n + 1;
  end loop;
  perform set_config('migi.f1', v_n::text || ' 個孤兒房已釋放　' || v_out, true);
end $fix1$;


-- ══════════════════════════════════════════════════════
-- ③ 一次性：一個人同時在多個活著的房 → 只留一個
-- ══════════════════════════════════════════════════════
do $fix2$
declare v_n int := 0;
begin
  /* 留哪一個：**離開打最近的那一步** —— 已帶到桌 › 已成桌 › 還在等；
     同級則留**先加入**的（那是他原本的承諾，後加入的才是誤觸）。
     ⚠ `leave_reason = 'switched'` 是 CHECK 本來就允許的值，
       不用為了這次清理去改約束。 */
  with live as (
    select qp.id as qp_id, qp.member_id,
           row_number() over (
             partition by qp.member_id
             order by case q.status when 'seated' then 0 when 'matched' then 1 else 2 end,
                      qp.joined_at asc
           ) as rn
      from match_queue_players qp
      join match_queues q on q.id = qp.queue_id
     where qp.left_at is null
       and (q.status in ('waiting','matched')
            or (q.status = 'seated' and exists (
                  select 1 from table_sessions ts
                   where ts.id = q.matched_session_id
                     and ts.status = 'open' and ts.deleted_at is null)))
  )
  update match_queue_players p
     set left_at = now(), leave_reason = 'switched'
    from live
   where live.qp_id = p.id and live.rn > 1;
  get diagnostics v_n = row_count;
  perform set_config('migi.f2', v_n::text || ' 筆重複的房籍已清掉', true);
end $fix2$;


-- ══════════════════════════════════════════════════════
-- 驗證（只讀，不回滾 —— ②③ 是真的要留下來的）
-- ══════════════════════════════════════════════════════
do $v$
declare v_out text := ''; v_n int; v_mem uuid; v_r jsonb;
begin
  v_out := v_out || E'\n① 孤兒房' || E'\t' || coalesce(current_setting('migi.f1', true), '(沒有紀錄)');
  v_out := v_out || E'\n② 重複房籍' || E'\t' || coalesce(current_setting('migi.f2', true), '(沒有紀錄)');

  ---- ③ 現在沒有人同時在兩個活著的房裡 --------------------
  select count(*) into v_n from (
    select qp.member_id
      from match_queue_players qp
      join match_queues q on q.id = qp.queue_id
     where qp.left_at is null
       and (q.status in ('waiting','matched')
            or (q.status = 'seated' and exists (
                  select 1 from table_sessions ts
                   where ts.id = q.matched_session_id
                     and ts.status = 'open' and ts.deleted_at is null)))
     group by qp.member_id having count(*) > 1) x;
  v_out := v_out || E'\n③ 還有人同時在兩個活房嗎' || E'\t' ||
    case when v_n = 0 then '✅ 0 人' else '🔴 ' || v_n || ' 人' end;

  ---- ④ 🎯 咖勁凱看到的是那個「有桌」的房 ----------------
  select id into v_mem from members where display_name = '咖勁凱' and deleted_at is null limit 1;
  if v_mem is null then
    v_out := v_out || E'\n④ 🎯 咖勁凱看到哪個房' || E'\t' || '🟡 取樣失敗：找不到這個會員';
  else
    v_r := public.get_my_active_queue_tx(
      (select org_id from members where id = v_mem), v_mem);
    v_out := v_out || E'\n④ 🎯 咖勁凱看到哪個房' || E'\t' ||
      case when v_r is null then '🟡 沒有房了'
           when (v_r ->> 'status') = 'seated'
             then '✅ seated · 桌 ' || coalesce(v_r ->> 'table_label','?')
               || ' · ' || (v_r ->> 'player_count') || ' 人'
           else '🔴 ' || (v_r ->> 'status') || '（還是顯示沒有桌的那個）' end;
  end if;

  ---- ⑤ 🎯 正對照：只在一個房的人不受影響 ----------------
  /* 只驗 ③ 的話，一支**把所有人都清光**的清理也會綠。 */
  select count(*) into v_n
    from match_queue_players qp
    join match_queues q on q.id = qp.queue_id
   where qp.left_at is null and q.status in ('waiting','matched','seated');
  v_out := v_out || E'\n⑤ 🎯 正對照：還在房裡的人數' || E'\t' ||
    case when v_n > 0 then '✅ ' || v_n || ' 筆（沒有被清光）' else '🔴 0 —— 清過頭了' end;

  perform set_config('migi.v', v_out, true);
end $v$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(coalesce(current_setting('migi.v', true), ''), E'\n')) as x
 where coalesce(x, '') <> '';
