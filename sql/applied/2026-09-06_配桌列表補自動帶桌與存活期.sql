/* ============================================================
   配桌列表：說得出「是系統自動帶的」，而且卡片不要提早消失
   2026-09-06 · MIGI 咪吉麻將

   起點是一個文案需求：配桌卡要講出「系統已自動帶到 A3」。
   撈線上版之後發現**兩個更嚴重的問題擋在前面**。

   ── ① 分不出「系統自動帶」還是「店員手動帶」──────────
   帶桌有兩條路：`sweep_auto_seat_tx`（自動）與 `pos_seat_queue_tx`
   （店員手動）。而 `pos_list_queues_tx` 兩者回傳完全一樣。
   🔴 **沒有這個欄位，唯一誠實的寫法是「已帶到 A3」** ——
     對著一張店員自己手動帶的桌說「系統已自動帶桌」，比不說更糟。
   ✅ `open_method` 就在 `table_sessions` 上，而這支**本來就已經
     left join 了 `ts`** —— 加一行 `'open_method', ts.open_method` 就好。

   ── 🔴 ② seated 的卡片 10 分鐘後就消失 ────────────────
   ```sql
   (q.status = 'seated' and q.updated_at > now() - interval '10 minutes')
   ```
   註解寫的目的是「讓 POS 有機會跳『已帶到 T1』的彈窗」——
   但那個條件同時決定**卡片在不在清單裡**。
   ⇒ 店員十分鐘內沒去收檯費，那張卡（連同「前往 A3 結帳」）
     **整個從畫面上消失**，而那四個人的檯費一毛都還沒收。
   ⚠ 它不會報錯，也沒有任何提示 —— 只是不見了。

   ✅ 界線改成「**那張桌還開著**」（與同日修的 `get_my_active_queue_tx`
     同一個判準）：收桌（completed）或取消開桌（voided）之後才消失。
   🎯 用的是現成的事實，不需要新欄位、也不需要排程去改狀態。

   ── 🔴 ③ `matched` 的房根本不會出現 ──────────────────
   `QueueCard` 有一個完整的 `stuck` 狀態：紅框、紅底、
   「已滿 · 沒有空桌」＋「四人已到齊，等有桌釋出系統會自動帶」。
   **而 WHERE 只放行 `waiting` 與 `seated`** ⇒ 那段程式碼永遠不會執行。
   ⚠ 這正是「建了沒人讀」的形狀，而且是最糟的一種：
     **四人已到齊卻沒有桌**是店員最該知道的狀況（他可以去清一張桌），
     而系統選擇不告訴他。

   ── ⚠ 簽名不變 ────────────────────────────────────────
   `CREATE OR REPLACE` ⇒ 不用 DROP、不丟 GRANT、沒有部署順序問題。
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
       ⚠ 值不是 `auto` 的一律寫「已帶到 A3」，不要寫「系統自動」——
         那會對著店員自己做的事說是系統做的。 */
    'open_method', ts.open_method,
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
      /* ★ 2026-09-06：`matched`＝四人到齊卻沒有空桌。
         `QueueCard` 早就有 `stuck` 狀態（紅框 ＋「已滿 · 沒有空桌」），
         但舊的 WHERE 不放行它 ⇒ 那段程式碼**永遠不會執行**。
         🔴 而那是店員最該知道的狀況：他可以去清一張桌。 */
      q.status = 'matched'
      or
      /* ★ 2026-09-06：舊版是 `q.updated_at > now() - interval '10 minutes'`。
         🔴 十分鐘後卡片連同「前往結帳」整個消失，而檯費一毛都還沒收。
         ✅ 改成「那張桌還開著」—— 收桌或取消開桌之後才消失。
         ⚠ `matched_session_id` 是 null 就不放行（沒有桌可以去結帳）。 */
      (q.status = 'seated' and ts.status = 'open' and ts.deleted_at is null)
    )
$function$;


-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
do $v$
declare
  v_out text := '';
  v_org uuid; v_store uuid; v_q uuid; v_sess uuid;
  v_row jsonb; v_n int;
  /* ⚠ 2026-09-06：第一次跑時把布林值塞進 `v_n int` ——
     `invalid input syntax for type integer: "t"`，整段在第 ② 格中斷。
     ①（真正的修正）其實已經通過了。**又一次是驗證段錯不是函式錯。** */
  v_b boolean;
begin
  select s.org_id, s.id into v_org, v_store
    from stores s
   where exists (select 1 from match_queues q
                  where q.store_id = s.id and q.status = 'seated')
   limit 1;

  select q.id, q.matched_session_id into v_q, v_sess
    from match_queues q
   where q.store_id = v_store and q.status = 'seated'
   order by q.updated_at desc limit 1;

  /* 🔴 取樣失敗要出聲（2026-09-04 就發生過「那格沒出現而我以為全過」）。 */
  if v_q is null or v_sess is null then
    perform set_config('migi.v', E'\n🔴 取樣失敗' || E'\t' ||
      '找不到 seated 且有 session 的房 —— 下面每一格都不算數', true);
    return;
  end if;

  ---- ① open_method 有回傳 -------------------------------
  select jsonb_path_query_first(public.pos_list_queues_tx(v_org, v_store),
           ('$[*] ? (@.id == "' || v_q || '")')::jsonpath) into v_row;
  v_out := v_out || E'\n① 回傳 open_method' || E'\t' ||
    case when v_row is null then '🔴 這張卡根本不在清單裡'
         when v_row ? 'open_method' then '✅ ' || coalesce(v_row ->> 'open_method','(null)')
           || '　桌=' || coalesce(v_row ->> 'table_label','?')
         else '🔴 沒有這個鍵' end;

  ---- ② 🔴 超過 10 分鐘還在（舊版會在這裡消失）-----------
  select (now() - q.updated_at) > interval '10 minutes' into v_b
    from match_queues q where q.id = v_q;
  v_out := v_out || E'\n② 已經超過 10 分鐘了嗎' || E'\t' ||
    case when v_b then '✅ 是（所以 ① 看得到卡片就證明存活期修好了）'
         else '🟡 還沒超過 —— ① 通過不代表存活期修好了，過十分鐘再跑一次' end;

  ---- ③ 🎯 正對照：收桌之後要消失 ------------------------
  /* 只驗「看得到」的話，一支**無條件全放行**的實作也會綠。 */
  update table_sessions set status = 'completed' where id = v_sess;
  select jsonb_path_query_first(public.pos_list_queues_tx(v_org, v_store),
           ('$[*] ? (@.id == "' || v_q || '")')::jsonpath) into v_row;
  v_out := v_out || E'\n③ 🎯 正對照：收桌後卡片消失' || E'\t' ||
    case when v_row is null then '✅ 不見了' else '🔴 還在，會永遠留著' end;

  update table_sessions set status = 'voided' where id = v_sess;
  select jsonb_path_query_first(public.pos_list_queues_tx(v_org, v_store),
           ('$[*] ? (@.id == "' || v_q || '")')::jsonpath) into v_row;
  v_out := v_out || E'\n④ 🎯 正對照：取消開桌後也消失' || E'\t' ||
    case when v_row is null then '✅ 不見了' else '🔴 還在' end;

  update table_sessions set status = 'open' where id = v_sess;

  ---- ⑤ matched 的房看得到了（stuck 狀態終於有資料）-------
  update match_queues set status = 'matched' where id = v_q;
  select jsonb_path_query_first(public.pos_list_queues_tx(v_org, v_store),
           ('$[*] ? (@.id == "' || v_q || '")')::jsonpath) into v_row;
  v_out := v_out || E'\n⑤ matched（四人到齊沒空桌）看得到' || E'\t' ||
    case when v_row is not null and (v_row ->> 'status') = 'matched'
         then '✅ 出現了 —— stuck 那段程式碼終於會執行'
         else '🔴 還是看不到' end;
  update match_queues set status = 'seated' where id = v_q;

  ---- ⑥ 🎯 正對照：expired／cancelled 不可以冒出來 --------
  select count(*) into v_n
    from jsonb_array_elements(public.pos_list_queues_tx(v_org, v_store)) e
   where (e ->> 'status') in ('expired','cancelled');
  v_out := v_out || E'\n⑥ 🎯 正對照：過期／取消的沒有跑進來' || E'\t' ||
    case when v_n = 0 then '✅ 0 筆' else '🔴 混進 ' || v_n || ' 筆' end;

  ---- ⑦ 🎯 正對照：waiting 沒有被誤傷 --------------------
  select count(*) into v_n
    from jsonb_array_elements(public.pos_list_queues_tx(v_org, v_store)) e
   where (e ->> 'status') = 'waiting';
  v_out := v_out || E'\n⑦ 🎯 正對照：waiting 仍然看得到' || E'\t' ||
    case when v_n > 0 then '✅ ' || v_n || ' 筆' else '🔴 0 筆 —— 被誤擋了' end;

  raise exception 'migi_rollback';

exception when others then
  /* 🔴 訊息設在這裡，不是設在上面再 raise（硬規則 3.9）。 */
  perform set_config('migi.v',
    v_out || case when sqlerrm <> 'migi_rollback'
                  then E'\n🔴 驗證中斷' || E'\t' || sqlerrm else '' end, true);
end $v$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(coalesce(current_setting('migi.v', true), ''), E'\n')) as x
 where coalesce(x, '') <> '';
