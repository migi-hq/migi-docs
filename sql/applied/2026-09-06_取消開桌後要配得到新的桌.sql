/* ============================================================
   🔴 一個房被取消開桌之後，就再也配不到新的桌
   2026-09-06 · MIGI 咪吉麻將
   ⚠ 這一份**有真的寫入**（修好現在卡住的房），不是只有 DDL。

   ── 怎麼發現的 ────────────────────────────────────────
   使用者：「即時桌況選取消開桌，配桌列表開桌還在，是 BUG 嗎？」
   → 那個不是。但查時間軸時看到：
   ```
   10:32:03  桌建立（auto）
   10:34:33  桌作廢   ← 取消開桌，觸發器把房放回 waiting ✅
   10:40:00  房又變成 seated，**指著同一張已作廢的桌**
             （而那張桌從 10:34 之後再也沒被動過）
   ```

   ── 根因 ──────────────────────────────────────────────
   ```sql
   -- pos_seat_queue_tx
   open_session_tx(..., 'queue-' || p_queue::text, ...)   -- 冪等鍵 = 房 id

   -- open_session_tx
   select id into v_id from table_sessions
    where idempotency_key = p_idempotency_key;            -- ← 完全不看狀態
   if v_id is not null then return ... duplicate
   ```
   ⇒ 重新配桌時撞到 10:34 那張**已作廢**的，回 `duplicate / ok=true`
   ⇒ `pos_seat_queue_tx` 就把房標成 `seated`，指回那張死掉的桌。

   🔴 **後果：一個房只要被取消開桌一次，就永遠配不到新的桌**，
     而畫面上寫著「已成桌」。實查：用 `queue-` 開頭的桌**共 4 張，
     全部已作廢** ⇒ 那四個房都卡死了。

   ── 🔴 為什麼不能改 `open_session_tx` ────────────────
   ```
   uq_sessions_idem  UNIQUE (idempotency_key) WHERE idempotency_key IS NOT NULL
   ```
   那把鑰匙**一輩子只能用一次**。所以就算在 `open_session_tx` 加
   `and status <> 'voided'` 跳過它，接下來的 INSERT 會直接撞唯一索引（23505）。
   ⇒ **唯一正確的位置是產生鑰匙的地方。**

   ── 修法：鑰匙加一個「第幾次嘗試」──────────────────────
   ```
   'queue-' || 房id || '-' || (這個房已經死掉幾張桌)
   ```
   · 第一次配　　　　　→ 死掉 0 張 → `-0` → 建新桌
   · **連按兩下**　　　→ 那張還開著，死掉仍是 0 → `-0` → 回 duplicate ✅
   · 取消開桌後再配　　→ 死掉 1 張 → `-1` → **建新桌** ✅
   · 作廢後又連按兩下　→ 死掉仍是 1 → `-1` → 回 duplicate ✅

   🎯 冪等要防的是「同一個意圖被送兩次」。桌被作廢之後再配桌
     **是一個新的意圖**，不是重送 —— 舊鑰匙本來就不該擋它。
   ⚠ `like 'queue-' || 房id || '%'` 也涵蓋舊格式（沒有後綴的那四張）。
   ============================================================ */

create or replace function public.pos_seat_queue_tx(
  p_org_id uuid, p_queue uuid, p_table_id uuid, p_staff_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare q record; v_rounds int; v_open jsonb; v_sid uuid; v_dead int;
begin
  /* 🔴 操作者身分從 JWT 取，**不採信呼叫端送的 p_staff_id**（2026-09-04）。
     ⚠ 查不到就是 null（會員 App 那條路沒有 staff 身分），**不可以報錯**。 */
  p_staff_id := (select staff_id from public.current_staff());

  select * into q from match_queues where id = p_queue and org_id = p_org_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  /* 冪等：已經帶過就直接回同一張桌，不再開第二桌。
     ⚠ **要確認那張桌還開著** —— 2026-09-06 之前只看 `matched_session_id is not null`，
       所以一個指著已作廢場次的房會一直回 `already=true`，
       而店員得到的是「已經帶過了」，桌卻不存在。 */
  if q.status = 'seated' and q.matched_session_id is not null
     and exists (select 1 from table_sessions s
                  where s.id = q.matched_session_id
                    and s.status = 'open' and s.deleted_at is null) then
    return jsonb_build_object('ok', true, 'already', true, 'session_id', q.matched_session_id);
  end if;

  if q.status not in ('waiting', 'matched') then
    return jsonb_build_object('ok', false, 'reason', 'bad_status', 'status', q.status);
  end if;
  if p_table_id is null then
    return jsonb_build_object('ok', false, 'reason', 'table_required');
  end if;

  -- 將數：兩種寫法都吃（'2 將' 與 '二將'），但一將擋下並說清楚
  v_rounds := case when q.rounds ilike '%三%' or q.rounds like '%3%' then 3
                   when q.rounds ilike '%二%' or q.rounds like '%2%' then 2
                   else null end;
  if v_rounds is null then
    return jsonb_build_object('ok', false, 'reason', 'rounds_not_supported', 'rounds', q.rounds);
  end if;

  /* ★ 2026-09-06：冪等鍵加上「這個房已經死掉幾張桌」。
     🔴 舊版是 `'queue-' || p_queue` —— 而 `uq_sessions_idem` 是 UNIQUE，
       所以那把鑰匙一輩子只能用一次。取消開桌之後再配桌會撞到那張
       **已作廢**的（`open_session_tx` 的冪等檢查完全不看狀態），
       回 `duplicate / ok=true` ⇒ 房被標成 seated 指回死掉的桌
       ⇒ **那個房永遠配不到新的桌，而畫面上寫著「已成桌」**。
     🎯 冪等要防的是「同一個意圖被送兩次」。桌被作廢之後再配桌
       **是一個新的意圖**，不是重送。
     ⚠ 只數「不是 open」的：那張還開著時連按兩下，數字不變 ⇒ 仍然冪等。
     ⚠ `like 'queue-…%'` 也涵蓋 2026-09-06 之前的舊格式（沒有後綴）。 */
  select count(*) into v_dead
    from table_sessions s
   where s.idempotency_key like 'queue-' || p_queue::text || '%'
     and s.status <> 'open';

  v_open := open_session_tx(
    p_table_id, 'matched', q.stake_level_id, v_rounds, null, p_staff_id, 'auto',
    'queue-' || p_queue::text || '-' || v_dead::text,
    q.game_type, q.flower);
  if not coalesce((v_open->>'ok')::boolean, false) then
    return v_open;   -- table_busy / table_unavailable 等原樣傳回，訊息已經是中文
  end if;

  v_sid := (v_open->>'session_id')::uuid;
  update match_queues
     set status = 'seated', matched_session_id = v_sid,
         matched_at = coalesce(matched_at, now()), updated_at = now()
   where id = p_queue;

  return jsonb_build_object(
    'ok', true, 'session_id', v_sid, 'rounds', v_rounds,
    'members', pos_queue_members_tx(p_org_id, p_queue));
end $function$;


-- ══════════════════════════════════════════════════════
-- 一次性：把指著死桌的房救回來
-- ══════════════════════════════════════════════════════
do $fix$
declare v_n int;
begin
  /* 🔴 修函式不會修好**已經卡住**的房（今天第三次學到同一件事）。
     條件：`seated` 但它指的場次已經不是 open。
     依人數決定回哪裡 —— 與 `trg_session_voided_release_queue` 同一套規則。 */
  update match_queues q
     set status = case
           when (select count(*) from match_queue_players p
                  where p.queue_id = q.id and p.left_at is null) >= coalesce(q.seats, 4)
             then 'matched' else 'waiting' end,
         matched_session_id = null,
         updated_at = now()
   where q.status = 'seated'
     and q.play_at > now() - interval '30 minutes'
     and not exists (select 1 from table_sessions s
                      where s.id = q.matched_session_id
                        and s.status = 'open' and s.deleted_at is null);
  get diagnostics v_n = row_count;
  perform set_config('migi.fix', v_n::text || ' 個指著死桌的房已放回排隊', true);
end $fix$;


-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
do $v$
declare
  v_out text := '';
  v_org uuid; v_store uuid; v_q uuid; v_tbl uuid; v_tbl2 uuid;
  v_r jsonb; v_s1 uuid; v_s2 uuid; v_n int; v_base int;
begin
  v_out := v_out || E'\n⓪ 一次性救回' || E'\t' || coalesce(current_setting('migi.fix', true), '(沒有紀錄)');

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
      '房=' || coalesce(v_q::text,'無') || '　空桌=' || coalesce(v_tbl::text,'無') ||
      '/' || coalesce(v_tbl2::text,'無') || ' —— 下面每一格都不算數', true);
    return;
  end if;

  /* 🔴 **先記下基準** —— 這個房在測試之前可能已經開過桌
     （2026-09-06 實測就是：它有一張 10:32 的已作廢場次）。
     不記基準的話 ⑤ 會把舊的算進去，然後**紅在一個對的函式上**。 */
  select count(*) into v_base from table_sessions
   where idempotency_key like 'queue-' || v_q::text || '%';

  -- 借成「四人到齊、還沒有桌」
  update match_queues set status='matched', matched_session_id=null,
         play_at = now() + interval '60 minutes', rounds = '2 將'
   where id = v_q;

  ---- ① 第一次配桌 → 建出桌 ------------------------------
  v_r := public.pos_seat_queue_tx(v_org, v_q, v_tbl);
  v_s1 := (v_r->>'session_id')::uuid;
  v_out := v_out || E'\n① 第一次配桌' || E'\t' ||
    case when coalesce((v_r->>'ok')::boolean,false) and v_s1 is not null
         then '✅ 建出桌 ' || (select label from tables where id = v_tbl)
         else '🔴 ' || coalesce(v_r->>'reason', v_r::text) end;

  ---- ② 🎯 冪等：立刻再叫一次 → 同一張，不開第二桌 --------
  v_r := public.pos_seat_queue_tx(v_org, v_q, v_tbl2);
  v_out := v_out || E'\n② 🎯 連按兩下仍然冪等' || E'\t' ||
    case when coalesce((v_r->>'already')::boolean,false)
              and (v_r->>'session_id')::uuid = v_s1
         then '✅ 回同一張，沒有開第二桌'
         else '🔴 開了別的：' || coalesce(v_r->>'session_id','(無)') end;

  ---- ③ 🔴 取消開桌之後要配得到**新的**桌 ----------------
  update table_sessions set status='voided', ended_at=now() where id = v_s1;
  -- 觸發器會把房放回 matched（4/4）或 waiting；再配一次
  update match_queues set status='matched', matched_session_id=null where id = v_q;

  v_r := public.pos_seat_queue_tx(v_org, v_q, v_tbl2);
  v_s2 := (v_r->>'session_id')::uuid;
  v_out := v_out || E'\n③ 🔴 作廢後配得到新的桌' || E'\t' ||
    case when v_s2 is not null and v_s2 <> v_s1
         then '✅ 新的場次（舊版會拿回死掉那張）'
         when v_s2 = v_s1 then '🔴 又拿回同一張已作廢的桌'
         else '🔴 ' || coalesce(v_r->>'reason', v_r::text) end;

  ---- ④ 🎯 正對照：作廢後連按兩下仍然只有一張 ------------
  v_r := public.pos_seat_queue_tx(v_org, v_q, v_tbl);
  v_out := v_out || E'\n④ 🎯 作廢後連按兩下仍然冪等' || E'\t' ||
    case when (v_r->>'session_id')::uuid = v_s2 then '✅ 回同一張'
         else '🔴 又開了一張：' || coalesce(v_r->>'session_id','(無)') end;

  ---- ⑤ 🎯 正對照：這個房總共只開出兩張桌 ----------------
  /* 只驗 ③ 的話，一支**每次都開新桌**的實作也會綠 ——
     而那的症狀是店員連按兩下就佔掉兩張桌。 */
  /* 🔴 **2026-09-06 實跑時這一格紅了，而錯的是期望值不是函式**（硬規則 3.56）。
     我寫「總共應該是 2 張」，實際 3 張 —— 因為取樣到的那個房
     **測試之前本來就有一張 10:32 的已作廢場次**，我算的時候忘了它。
     🎯 要算的是「**這次測試新增了幾張**」，所以必須先記基準。
     ⚠ 這一格的用途沒變：防「每次呼叫都開新桌」（症狀是店員連按兩下
       就佔掉兩張桌）—— 而 ②④ 也各自從另一個角度證明了同一件事。 */
  select count(*) into v_n from table_sessions
   where idempotency_key like 'queue-' || v_q::text || '%';
  v_out := v_out || E'\n⑤ 🎯 這次測試新增了幾張桌' || E'\t' ||
    case when v_n - v_base = 2
         then '✅ 2 張（① 一張 ＋ ③ 作廢後一張；測試前本來就有 ' || v_base || ' 張）'
         else '🔴 新增 ' || (v_n - v_base) || ' 張（測試前 ' || v_base || '，現在 ' || v_n || '）' end;

  ---- ⑥ 現在還有幾個房指著死桌 ---------------------------
  select count(*) into v_n from match_queues q
   where q.status = 'seated'
     and not exists (select 1 from table_sessions s
                      where s.id = q.matched_session_id and s.status='open');
  v_out := v_out || E'\n⑥ 還有幾個房指著死桌' || E'\t' ||
    case when v_n = 0 then '✅ 0 個' else '🟡 ' || v_n || ' 個（開打時間已過太久的不救，見一次性條件）' end;

  raise exception 'migi_rollback';

exception when others then
  /* 🔴 訊息設在這裡（硬規則 3.9）。
     ⚠ ①〜⑤ 有真的開桌，靠這個 raise 回滾；
       上面那個一次性救回是**另一個 DO 區塊**，不受影響。 */
  perform set_config('migi.v',
    v_out || case when sqlerrm <> 'migi_rollback'
                  then E'\n🔴 驗證中斷' || E'\t' || sqlerrm else '' end, true);
end $v$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(coalesce(current_setting('migi.v', true), ''), E'\n')) as x
 where coalesce(x, '') <> '';
