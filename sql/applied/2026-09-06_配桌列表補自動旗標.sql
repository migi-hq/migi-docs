/* ============================================================
   `pos_list_queues_tx` 補回傳 `auto_seat`
   2026-09-06 · MIGI 咪吉麻將

   ── 為什麼 ────────────────────────────────────────────
   同日新增的規則：**自動配桌只做一次**，帶到的桌被取消之後
   `match_queues.auto_seat` 變成 false，由店員手動配（隨機／指定）。
   而 POS 要畫那個「手動配桌」的介面，就得知道這個房是不是手動的 ——
   ⇒ 少了這個欄位，`matched` 且沒有桌的房，前端**分不出**
     「排程等一下會配」與「在等我動手」。

   ── ⚠ 我差點以為它已經有了 ────────────────────────────
   查的時候用 `pg_get_functiondef(...) ~ 'auto_seat'` → 回 `true`，
   但實際的回傳鍵裡**沒有**它。
   🔴 那個 `true` 撞到的是我自己寫在註解裡的 `sweep_auto_seat_tx`
     —— **硬規則 3.5：禁字不能是自己註解裡會出現的詞。**
   🎯 決定性的檢查是**列出實際回傳的鍵**（`jsonb_object_keys`），
     不是掃函式全文。
   ============================================================ */

create or replace function public.pos_list_queues_tx(p_org uuid, p_store uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', q.id,
    'status', q.status,
    'source', q.source,
    'stake_level_id', q.stake_level_id,
    'stake', sl.label,
    'game_type', q.game_type, 'flower', q.flower, 'rounds', q.rounds,
    'seats', q.seats,
    'play_at', q.play_at,
    'open_at', q.open_at,
    'recurring_freq', q.recurring_freq,
    'opener', mo.display_name,
    'session_id', q.matched_session_id, 'tags', q.tags,
    'table_label', tb.label,
    'seated_at', case when q.status = 'seated' then q.updated_at else null end,
    /* `auto` = 系統帶的／`manual` = 店員在 POS 按的。
       ⚠ 值不是 `auto` 的一律寫「已帶到 A3」不寫「系統自動」。 */
    'open_method', ts.open_method,
    /* ★ 2026-09-06：這個房還能不能被系統自動配。
       false ＝ 帶到的桌被取消過，之後由店員手動配（隨機／指定）。
       🔴 少了它，`matched` 且沒有桌的房前端**分不出**
         「排程等一下會配」與「在等我動手」。 */
    'auto_seat', q.auto_seat,
    'paid_count', (
      select count(*) from session_players sp
       where sp.session_id = q.matched_session_id and sp.left_at is null),
    'session_status', ts.status,
    'settled_at', ts.ended_at,
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'member_id', m.id, 'nickname', m.display_name,
        'rank', m.rank, 'title', m.title,
        'tier', coalesce(m.tier_override, m.tier),
        'joined_at', p.joined_at,
        'walk_in', p.join_source = 'pos_walkin'
      ) order by p.joined_at)
      from match_queue_players p
      join members m on m.id = p.member_id
      where p.queue_id = q.id and p.left_at is null), '[]'::jsonb)
  ) order by (q.status = 'seated') desc, (q.status = 'matched') desc, q.play_at), '[]'::jsonb)
  from match_queues q
  left join stake_levels sl on sl.id = q.stake_level_id and sl.org_id = p_org
  left join members mo on mo.id = q.opened_by
  left join table_sessions ts on ts.id = q.matched_session_id
  left join tables tb on tb.id = ts.table_id
  where q.org_id = p_org and q.store_id = p_store
    and (
      (q.status = 'waiting'
        and (q.expires_at is null or q.expires_at > now())
        and (q.open_at is null or q.open_at <= now()))
      or
      q.status = 'matched'
      or
      (q.status = 'seated' and ts.status = 'open' and ts.deleted_at is null)
      or
      /* 今天已經收桌的也留著（只留今天，台北日曆日）——
         店員交班時要看得到「今天配了幾桌」。 */
      (q.status = 'seated' and ts.status = 'completed' and ts.deleted_at is null
       and (ts.ended_at at time zone 'Asia/Taipei')::date
           = (now() at time zone 'Asia/Taipei')::date)
    )
$function$;


-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
do $v$
declare v_out text := ''; v_org uuid; v_store uuid; v_keys text; v_n int;
begin
  select s.org_id, s.id into v_org, v_store from stores s
   where exists (select 1 from match_queues q where q.store_id = s.id) limit 1;
  if v_org is null then
    perform set_config('migi.v', E'\n🔴 取樣失敗' || E'\t' || '找不到有配桌房的門市', true);
    return;
  end if;

  /* 🎯 **列出實際回傳的鍵**，不要掃函式全文 ——
     掃全文那次撞到自己註解裡的 `sweep_auto_seat_tx`（硬規則 3.5）。 */
  select string_agg(k, ', ' order by k) into v_keys
    from jsonb_object_keys(jsonb_path_query_first(
           public.pos_list_queues_tx(v_org, v_store), '$[0]')) k;

  v_out := v_out || E'\n① 回傳鍵裡有 auto_seat' || E'\t' ||
    case when v_keys like '%auto_seat%' then '✅ 有' else '🔴 沒有：' || coalesce(v_keys,'(空清單)') end;

  ---- ② 🎯 值對得上資料庫（不是回一個常數）---------------
  select count(*) into v_n
    from jsonb_array_elements(public.pos_list_queues_tx(v_org, v_store)) e
    join match_queues q on q.id = (e ->> 'id')::uuid
   where (e ->> 'auto_seat')::boolean is distinct from q.auto_seat;
  v_out := v_out || E'\n② 🎯 值對得上 match_queues' || E'\t' ||
    case when v_n = 0 then '✅ 全部一致' else '🔴 有 ' || v_n || ' 筆不一致' end;

  ---- ③ 🎯 正對照：其他鍵沒有掉 --------------------------
  /* 重貼整支函式最容易漏掉一個鍵，而那**不會報錯**，
     只會讓前端某一格突然空白。 */
  v_out := v_out || E'\n③ 🎯 正對照：鍵的總數' || E'\t' ||
    (select count(*)::text from jsonb_object_keys(jsonb_path_query_first(
       public.pos_list_queues_tx(v_org, v_store), '$[0]')))
    || ' 個（上一版 22 個 ＋ auto_seat = 23）';

  ---- ④ 🎯 正對照：清單筆數沒變 --------------------------
  select jsonb_array_length(public.pos_list_queues_tx(v_org, v_store)) into v_n;
  v_out := v_out || E'\n④ 🎯 正對照：清單筆數' || E'\t' ||
    case when v_n > 0 then '✅ ' || v_n || ' 筆（WHERE 沒被改壞）' else '🔴 0 筆' end;

  perform set_config('migi.v', v_out, true);
end $v$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(coalesce(current_setting('migi.v', true), ''), E'\n')) as x
 where coalesce(x, '') <> '';
