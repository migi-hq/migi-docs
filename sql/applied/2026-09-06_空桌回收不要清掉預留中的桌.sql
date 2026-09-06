/* ============================================================
   🔴 空桌回收會把「配桌預留中」的桌清掉
   2026-09-06 · MIGI 咪吉麻將

   ── 怎麼發現的 ────────────────────────────────────────
   2026-09-06 自動配桌**第一次跑通**：四個測試帳號湊滿 → 佔到 A3。
   35 分鐘後那張桌不見了。查證：
   ```
   table_sessions   建立 00:25:37   作廢 01:00:00   status voided
   updated_by       (沒有記錄操作者)          ← 不是店員按的
   ```
   **整點、沒有操作者** ⇒ 排程。而 `cleanup_empty_sessions_tx(30)`
   每 10 分鐘跑一次，那張桌 00:25 建立、`session_players` 是 **0**
   （四個人都還沒結帳）⇒ 00:55 到期 ⇒ 01:00 那一輪把它作廢。

   ── 🔴 這是兩個機制互相打架，而且必然發生 ────────────
   ```
   自動配桌的設計   「湊滿就佔桌」——21:00 的局 19:00 湊滿就佔，空等 2 小時
   空桌回收的規則   「open 且 30 分鐘沒有 session_players」→ 作廢
   ```
   而配桌佔的桌**在客人到店結帳之前，`session_players` 永遠是 0**
   （系統裡不存在「已入座但未付款」）。
   ⇒ **每一張自動配到的桌都會在 30 分鐘後被清掉，一次都成功不了。**

   ⚠ `_try_auto_seat_tx` 的作者自己寫了「代價是那張桌在開打前會空著
     —— 所以桌況一定要能顯示『預留中』」，但沒有人把它跟這支排程連起來。
   📌 它到今天才可能被發現：在此之前自動配桌**一次都沒成功過**
     （`match_queues` 的 `seated` 是 0）。

   ── 修法：預留中的桌保留到「約定開打時間 ＋ 寬限」──────
   ```
   有一個 seated 的房指著它，而且 now() < play_at + 寬限   → 不回收
   過了那個時間還是沒有人結帳                              → 照常回收
   ```
   🎯 **界線是「約定的開打時間」不是「建立時間」** —— 那才是
     「這張桌被預留到什麼時候」的答案，而它本來就記在房裡。
   ⚠ **寬限沿用 `p_idle_minutes`**（預設 30），不另外開一個參數：
     多一個旋鈕就多一個沒有人知道該設多少的數字。
   ⚠ 過了寬限**一定要放** —— 沒有人來的桌永遠鎖著，比被清掉更糟
     （店員看得到一張永遠「預留中」的桌，而且不知道能不能用）。

   ── ⚠ 簽名不變 ────────────────────────────────────────
   `CREATE OR REPLACE`、參數一樣 ⇒ 不用 DROP、不丟 GRANT，
   pg_cron 的排程（`cleanup-empty-sessions`）也不用改。
   ============================================================ */

create or replace function public.cleanup_empty_sessions_tx(p_idle_minutes integer default 30)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_n int := 0; v_held int := 0;
begin
  /* 先數一下這一輪「因為預留而放過」了幾張 —— 回傳裡看得到，
     不然這條保護是隱形的，沒有人知道它有沒有在作用。 */
  select count(*) into v_held
    from table_sessions ts
   where ts.status = 'open'
     and coalesce(ts.started_at, ts.created_at) < now() - make_interval(mins => p_idle_minutes)
     and not exists (select 1 from session_players sp
                      where sp.session_id = ts.id and sp.left_at is null)
     and exists (select 1 from match_queues q
                  where q.matched_session_id = ts.id
                    and q.status = 'seated'
                    and now() < q.play_at + make_interval(mins => p_idle_minutes));

  update table_sessions ts
     set status = 'voided', ended_at = now()
   where ts.status = 'open'
     -- started_at 目前皆有值，但保險起見退回 created_at，
     -- 避免任一為 null 時條件恆為 null 而靜默失效
     and coalesce(ts.started_at, ts.created_at) < now() - make_interval(mins => p_idle_minutes)
     and not exists (
       select 1 from session_players sp
        where sp.session_id = ts.id and sp.left_at is null)
     /* ★ 2026-09-06：配桌預留中的桌不要清。
        🔴 配桌佔的桌**在客人到店結帳之前 `session_players` 永遠是 0**，
          所以上面那個 `not exists` 對它恆為真 ⇒ 每一張都會被清掉。
        ✅ 保留到「約定開打時間 ＋ 寬限」，過了才放 ——
          沒有人來的桌永遠鎖著比被清掉更糟。
        ⚠ 用 `now() < play_at + 寬限` 而不是 `play_at > now()`：
          客人遲到 10 分鐘不該讓桌立刻被收走。 */
     and not exists (
       select 1 from match_queues q
        where q.matched_session_id = ts.id
          and q.status = 'seated'
          and now() < q.play_at + make_interval(mins => p_idle_minutes));

  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'voided', v_n,
                            'held_for_queue', v_held,
                            'idle_minutes', p_idle_minutes);
end $function$;


-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
do $v$
declare
  v_out text := '';
  v_q uuid; v_sess uuid; v_st text;
  /* ⚠ 數字用數字的變數。2026-09-06 上一份就是把布林塞進 int，
     整段在第二格中斷，而那時函式其實已經是對的。 */
  v_n int;
begin
  select q.id, q.matched_session_id into v_q, v_sess
    from match_queues q
   where q.status = 'seated' and q.matched_session_id is not null
   order by q.updated_at desc limit 1;

  if v_q is null then
    perform set_config('migi.v', E'\n🔴 取樣失敗' || E'\t' ||
      '找不到 seated 且有 session 的房 —— 下面每一格都不算數', true);
    return;
  end if;

  /* 把樣本借成「30 分鐘前建立、還沒有人結帳、開打時間在一小時後」
     —— 那正是 2026-09-06 被清掉的那張桌的樣子。整段最後回滾。 */
  update table_sessions
     set status = 'open', created_at = now() - interval '90 minutes',
         started_at = now() - interval '90 minutes', ended_at = null
   where id = v_sess;
  update match_queues set play_at = now() + interval '60 minutes' where id = v_q;

  ---- ① 🔴 預留中的桌不會被清掉（這就是那個 bug）----------
  perform public.cleanup_empty_sessions_tx(30);
  select status into v_st from table_sessions where id = v_sess;
  v_out := v_out || E'\n① 🔴 預留中的桌沒被清掉' || E'\t' ||
    case when v_st = 'open' then '✅ 還在（修好了）'
         else '🔴 被清成 ' || v_st || ' —— 自動配桌還是不能用' end;

  ---- ② 🎯 正對照：過了開打時間＋寬限就要放 ---------------
  /* 只驗 ① 的話，一支**完全不回收**的實作也會綠，
     而症狀是店員看到一張永遠「預留中」、不知道能不能用的桌。 */
  update match_queues set play_at = now() - interval '120 minutes' where id = v_q;
  perform public.cleanup_empty_sessions_tx(30);
  select status into v_st from table_sessions where id = v_sess;
  v_out := v_out || E'\n② 🎯 正對照：開打時間過很久了就放掉' || E'\t' ||
    case when v_st = 'voided' then '✅ 收回來了'
         else '🔴 還是 ' || v_st || ' —— 桌會永遠鎖著' end;

  ---- ③ 🎯 正對照：一般的空桌照常回收（沒有誤放）---------
  update table_sessions
     set status = 'open', created_at = now() - interval '90 minutes',
         started_at = now() - interval '90 minutes', ended_at = null
   where id = v_sess;
  update match_queues set status = 'cancelled' where id = v_q;   -- 拔掉那道保護
  perform public.cleanup_empty_sessions_tx(30);
  select status into v_st from table_sessions where id = v_sess;
  v_out := v_out || E'\n③ 🎯 正對照：沒有配桌的空桌照樣回收' || E'\t' ||
    case when v_st = 'voided' then '✅ 照樣收（保護沒有擴大到別人身上）'
         else '🔴 沒收 —— 這條保護放太寬' end;

  ---- ④ 🎯 正對照：有人的桌永遠不回收 --------------------
  select count(*) into v_n from table_sessions ts
   where ts.status = 'voided' and ts.ended_at > now() - interval '5 seconds'
     and exists (select 1 from session_players sp
                  where sp.session_id = ts.id and sp.left_at is null);
  v_out := v_out || E'\n④ 🎯 正對照：有人的桌沒被誤收' || E'\t' ||
    case when v_n = 0 then '✅ 0 張' else '🔴 收掉了 ' || v_n || ' 張有人的桌' end;

  ---- ⑤ 回傳多了 held_for_queue，讓保護看得見 -------------
  update table_sessions
     set status = 'open', created_at = now() - interval '90 minutes',
         started_at = now() - interval '90 minutes', ended_at = null
   where id = v_sess;
  update match_queues set status = 'seated', play_at = now() + interval '60 minutes' where id = v_q;
  v_out := v_out || E'\n⑤ 回傳看得到保護了幾張' || E'\t' ||
    (public.cleanup_empty_sessions_tx(30))::text;

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
