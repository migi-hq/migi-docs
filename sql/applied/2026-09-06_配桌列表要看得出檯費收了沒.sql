/* ============================================================
   配桌列表：看得出檯費收了沒，並保留「今天已完成」的房
   2026-09-06 · MIGI 咪吉麻將

   ── 使用者指出的 ──────────────────────────────────────
   「這邊要多個已完成篩選，然後上面在結帳後自動切換已完成、相關資訊更新。」

   而畫面上那張卡在四份檯費都收完之後，**還是寫著「檯費還沒收」**。

   ── 根因：這支函式完全不回傳付款狀態 ──────────────────
   `pos_list_queues_tx` 回的是房與成員，**沒有任何一個欄位跟結帳有關**。
   POS 那句「檯費還沒收」是 2026-09-06 我寫死在前端的 ——
   🔴 **它不是狀態，是一句無條件的字**。收完帳它也不會變。
   ⚠ 那比沒有寫更糟：店員會以為還沒收，於是去收第二次
     （`join_session_tx` 會擋，但他得到的是一個看不懂的錯誤）。

   ── 這一份補三個欄位 ──────────────────────────────────
   | 欄位 | 為了什麼 |
   |---|---|
   | `paid_count` | 這桌**已經結過帳**的人數（`session_players`） |
   | `session_status` | 桌還開著／已收桌／已作廢 |
   | `settled_at` | 收桌時間（已完成那一區要照時間排） |

   🎯 **「已完成」的判準是「檯費收齊」不是「收桌」** ——
     配桌這個房的工作是「湊人 → 配桌 → 收費」，
     收費完成它就沒事了；**牌局本身結束是桌的事，不是房的事**。
   ⚠ 所以 `paid_count >= seats` 就算已完成，不必等 `settle_session_tx`。

   ── 🔴 順帶：已完成的房不能一收桌就消失 ────────────────
   舊的 WHERE 只放行 `ts.status = 'open'` ⇒ **收桌那一刻整張卡不見**。
   店員交班時想回頭看「今天配了幾桌」就查不到。
   ✅ 加上「今天收掉的」也留著，**但只留今天**（不然清單會無限長）。
   ⚠ 用台北時區的日曆日，與當日暢打同一個判準。
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
    /* ★ 2026-09-06：讓卡片說得出「系統已自動帶到 A3」。
       `auto` = sweep_auto_seat_tx／_try_auto_seat_tx 帶的
       `manual` = 店員在 POS 按的（pos_seat_queue_tx）
       ⚠ 值不是 `auto` 的一律寫「已帶到 A3」，不要寫「系統自動」。 */
    'open_method', ts.open_method,
    /* ★ 2026-09-06：付款狀態。
       🔴 在此之前這支**完全不回傳任何跟結帳有關的東西**，
         所以 POS 那句「檯費還沒收」是寫死的字 —— 收完也不會變，
         而店員會因此去收第二次。 */
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
      /* `matched`＝四人到齊卻沒有空桌 —— 店員最該知道的狀況（他可以去清一張桌）。 */
      q.status = 'matched'
      or
      (q.status = 'seated' and ts.status = 'open' and ts.deleted_at is null)
      or
      /* ★ 2026-09-06：**今天已經收桌的也留著**。
         🔴 舊版只放行 `open` ⇒ 收桌那一刻整張卡消失，
           店員交班時想回頭看「今天配了幾桌」就查不到。
         ⚠ **只留今天**（台北日曆日，與當日暢打同一個判準）——
           不限的話這個清單會無限長，而它是一個「現在要處理什麼」的畫面。 */
      (q.status = 'seated' and ts.status = 'completed' and ts.deleted_at is null
       and (ts.ended_at at time zone 'Asia/Taipei')::date
           = (now() at time zone 'Asia/Taipei')::date)
    )
$function$;


-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
do $v$
declare
  v_out text := '';
  v_org uuid; v_store uuid; v_q uuid; v_sess uuid; v_row jsonb; v_n int;
begin
  /* 取樣：今天真的收過檯費的那個房（硬規則 3.57：條件要涵蓋
     後面每一格會用到的前提，不要挑「最新的那一筆」）。 */
  select q.id, q.matched_session_id, q.org_id, q.store_id
    into v_q, v_sess, v_org, v_store
    from match_queues q
    join table_sessions ts on ts.id = q.matched_session_id
   where q.status = 'seated'
     and exists (select 1 from session_players sp
                  where sp.session_id = ts.id and sp.left_at is null)
   order by q.updated_at desc limit 1;

  if v_q is null then
    perform set_config('migi.v', E'\n🔴 取樣失敗' || E'\t' ||
      '找不到「已成桌且有人結過帳」的房 —— 下面每一格都不算數', true);
    return;
  end if;

  select jsonb_path_query_first(public.pos_list_queues_tx(v_org, v_store),
           ('$[*] ? (@.id == "' || v_q || '")')::jsonpath) into v_row;

  ---- ① 回得出「收了幾個人」--------------------------------
  v_out := v_out || E'\n① 檯費收了幾個人' || E'\t' ||
    case when v_row is null then '🔴 這張卡不在清單裡'
         when (v_row ->> 'paid_count') is null then '🔴 沒有這個鍵'
         else '✅ ' || (v_row ->> 'paid_count') || ' / ' || (v_row ->> 'seats')
              || '　桌=' || coalesce(v_row ->> 'table_label','?')
              || '　場次=' || coalesce(v_row ->> 'session_status','?') end;

  ---- ② 🎯 對得上資料庫（不是回一個好看的數字）-------------
  select count(*) into v_n from session_players sp
   where sp.session_id = v_sess and sp.left_at is null;
  v_out := v_out || E'\n② 🎯 對得上 session_players' || E'\t' ||
    case when (v_row ->> 'paid_count')::int = v_n then '✅ 都是 ' || v_n
         else '🔴 函式說 ' || (v_row ->> 'paid_count') || '，實際 ' || v_n end;

  ---- ③ 🔴 收桌之後那張卡還在（同一天）--------------------
  update table_sessions set status='completed', ended_at=now() where id = v_sess;
  select jsonb_path_query_first(public.pos_list_queues_tx(v_org, v_store),
           ('$[*] ? (@.id == "' || v_q || '")')::jsonpath) into v_row;
  v_out := v_out || E'\n③ 🔴 收桌後卡片還在（今天）' || E'\t' ||
    case when v_row is not null then '✅ 還在，session_status=' || coalesce(v_row->>'session_status','?')
         else '🔴 不見了 —— 交班時查不到今天配了幾桌' end;

  ---- ④ 🎯 正對照：昨天收掉的就不要留 --------------------
  /* 只驗 ③ 的話，一支**無條件全留**的實作也會綠，
     而那個清單會越長越長，直到沒有人看得完。 */
  update table_sessions set ended_at = now() - interval '2 days' where id = v_sess;
  select jsonb_path_query_first(public.pos_list_queues_tx(v_org, v_store),
           ('$[*] ? (@.id == "' || v_q || '")')::jsonpath) into v_row;
  v_out := v_out || E'\n④ 🎯 正對照：前天收掉的不留' || E'\t' ||
    case when v_row is null then '✅ 不在清單裡' else '🔴 還在' end;

  ---- ⑤ 🎯 正對照：作廢的桌不要因為這條而復活 -------------
  update table_sessions set status='voided', ended_at=now() where id = v_sess;
  select jsonb_path_query_first(public.pos_list_queues_tx(v_org, v_store),
           ('$[*] ? (@.id == "' || v_q || '")')::jsonpath) into v_row;
  v_out := v_out || E'\n⑤ 🎯 正對照：作廢的桌不出現' || E'\t' ||
    case when v_row is null then '✅ 不在清單裡' else '🔴 還在（新條件放太寬）' end;

  ---- ⑥ 🎯 正對照：等待中的房沒被誤傷 --------------------
  select count(*) into v_n
    from jsonb_array_elements(public.pos_list_queues_tx(v_org, v_store)) e
   where (e ->> 'status') = 'waiting';
  v_out := v_out || E'\n⑥ 🎯 正對照：等待中的房還在' || E'\t' ||
    case when v_n > 0 then '✅ ' || v_n || ' 筆' else '🟡 0 筆（現在剛好沒有等待中的房）' end;

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
