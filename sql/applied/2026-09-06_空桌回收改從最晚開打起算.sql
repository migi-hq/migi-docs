/* ============================================================
   配桌佔的桌：回收時間從「最晚開打」起算，不是從「桌建立」起算
   2026-09-06 · MIGI 咪吉麻將

   ── 使用者指出的 ──────────────────────────────────────
   「他不是 11:30 開打嗎？都 12:00 了。」
   「應該要改成最晚開打時間起算 30 分，而不是桌建立起 30 分。」

   ── 現在的規則是兩個條件疊加，而那是意外不是設計 ────────
   ```sql
   -- cleanup_empty_sessions_tx（每 10 分鐘）
   and coalesce(started_at, created_at) < now() - 30 分     -- ① 桌建立起算
   and not exists (…seated 的房 and now() < play_at + 30 分) -- ② 2026-09-06 加的保護
   ```
   ⇒ 實際回收時間是 **兩者的較晚者**。

   🔴 今天就看到它的後果：
   ```
   房的最晚開打  11:30
   系統配到桌    11:45   ← 那張桌**一出生就已經遲到 15 分鐘**
   ① 桌建立 + 30 = 12:15
   ② play_at + 30 = 12:00（已過）
   實際回收      12:20
   ```
   一個 11:30 的局，桌被佔到 12:20 —— 而**多出來的 20 分鐘完全是
   「桌是什麼時候建的」造成的，跟客人幾點要來無關**。

   ── 修法：兩種桌用兩種時鐘 ────────────────────────────
   | 桌 | 從什麼時候起算 |
   |---|---|
   | **配桌帶來的**（有 `seated` 的房指著它） | **最晚開打時間** `play_at` |
   | 其他（店員開了沒結帳的 setup 桌） | 桌建立時間（不變） |

   🎯 判準是「**這張桌在等誰**」：
     · 配桌的桌在等一組**約好時間**的客人 → 那個時間才是基準
     · setup 的桌在等**店員自己**把流程走完 → 從他開桌那一刻算才對
   ⚠ 所以不是把 ① 換成 ②，是**依桌的來源選一個時鐘**。
     舊版兩個都套，等於「兩個都要滿足」，而那沒有任何人決定過。

   ⚠ 寬限仍然是 `p_idle_minutes`（預設 30），不另外開參數 ——
     多一個旋鈕就多一個沒有人知道該設多少的數字。
   ⚠ 觸發器那邊的寬限也是 30 分，兩邊必須一致
     （不一致會變成「排程收了桌、觸發器又放回去」的循環）。
   ============================================================ */

create or replace function public.cleanup_empty_sessions_tx(p_idle_minutes integer default 30)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_n int := 0; v_held int := 0; v_grace interval;
begin
  v_grace := make_interval(mins => p_idle_minutes);

  /* 這一輪「因為還沒到時候而放過」了幾張 —— 回傳裡看得到，
     不然這條保護是隱形的，沒有人知道它有沒有在作用。 */
  select count(*) into v_held
    from table_sessions ts
    left join lateral (
      select q.play_at from match_queues q
       where q.matched_session_id = ts.id and q.status = 'seated' limit 1) qq on true
   where ts.status = 'open'
     and not exists (select 1 from session_players sp
                      where sp.session_id = ts.id and sp.left_at is null)
     and qq.play_at is not null
     and now() < qq.play_at + v_grace;

  update table_sessions ts
     set status = 'voided', ended_at = now()
    from (
      select s.id,
             (select q.play_at from match_queues q
               where q.matched_session_id = s.id and q.status = 'seated' limit 1) as qplay,
             coalesce(s.started_at, s.created_at) as opened_at
        from table_sessions s
       where s.status = 'open'
    ) x
   where ts.id = x.id
     and ts.status = 'open'
     and not exists (
       select 1 from session_players sp
        where sp.session_id = ts.id and sp.left_at is null)
     /* ★ 2026-09-06：**依桌的來源選時鐘**（使用者指定）。
        🔴 舊版是「桌建立 + 30 分」**再加上**「play_at + 30 分」的保護，
          兩個條件疊加 ⇒ 實際回收是兩者的較晚者。
          而那讓一張「11:45 才配到、局是 11:30」的桌被佔到 12:20 ——
          多出來的 20 分鐘純粹來自「桌是什麼時候建的」，
          **跟客人幾點要來完全無關**。
        🎯 配桌的桌在等一組約好時間的客人 → 用 `play_at`；
          setup 的桌在等店員自己走完流程 → 用建立時間。 */
     and case
           when x.qplay is not null then now() >= x.qplay + v_grace
           else x.opened_at < now() - v_grace
         end;

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
  v_q uuid; v_sess uuid; v_st text; v_n int; v_r jsonb;
begin
  /* 🔴 取樣必須挑一張**沒有玩家**的場次。
     2026-09-06 第一次跑就是敗在這裡：我挑了「最近成桌的那張」，
     而使用者剛好在那之前把四份檯費收了 ⇒ `session_players` 有 4 列
     ⇒ 那張桌**本來就不該被回收** ⇒ ①③ 紅了，但函式是對的。
     ⚠ 同硬規則 3.55：那兩格分不出「函式壞了」與「樣本不合格」，
       而那正是驗證最該避免的形狀。
     🎯 改成挑一張沒有玩家的（多半是先前已作廢的），在交易裡借成 open。 */
  /* ⚠ **還要求「那張桌現在是空的」** —— 2026-09-06 第二次取樣失敗就是
       敗在這裡：挑到 A3 的舊場次，而 A3 現在有一張開著的（剛結完帳那張）
       ⇒ 把舊的設回 `open` 直接撞 `uq_sessions_open_table`。
     🎯 這一整份的驗證失敗**三次都是取樣**，一次都不是函式 ——
       因為它一直在跟線上的真實資料搶東西。 */
  select ts.id into v_sess
    from table_sessions ts
   where not exists (select 1 from session_players sp where sp.session_id = ts.id)
     and not exists (select 1 from table_sessions o
                      where o.table_id = ts.table_id and o.id <> ts.id
                        and o.status = 'open' and o.deleted_at is null)
   order by ts.created_at desc limit 1;
  select q.id into v_q
    from match_queues q
   order by q.updated_at desc limit 1;

  if v_q is null or v_sess is null then
    perform set_config('migi.v', E'\n🔴 取樣失敗' || E'\t' ||
      '找不到「沒有玩家的場次」或房 —— 下面每一格都不算數', true);
    return;
  end if;

  -- 借成「配桌帶來的桌」
  update match_queues set status='seated', matched_session_id=v_sess where id = v_q;

  ---- ① 🔴 新規則的核心：桌剛建立，但開打時間早就過了 → 收 ----
  /* 舊版會因為「桌建立不到 30 分鐘」而放過它，
     再多給 30 分鐘 —— 而那 30 分鐘跟客人幾點要來完全無關。 */
  update table_sessions
     set status='open', ended_at=null,
         created_at = now() - interval '1 minute',
         started_at = now() - interval '1 minute'
   where id = v_sess;
  update match_queues set play_at = now() - interval '90 minutes' where id = v_q;

  perform public.cleanup_empty_sessions_tx(30);
  select status into v_st from table_sessions where id = v_sess;
  v_out := v_out || E'\n① 🔴 桌剛建立但開打時間過很久 → 回收' || E'\t' ||
    case when v_st = 'voided' then '✅ 收了（舊版會再多給 30 分鐘）'
         else '🔴 還是 ' || v_st end;

  ---- ② 🎯 正對照：開打時間還沒到 → 不收（即使桌很舊）------
  /* 只驗 ① 的話，一支**無條件全收**的實作也會綠，
     而那會把「19:00 湊滿、21:00 開打」那種桌立刻收走。 */
  /* 🔴 **要重新把房接回去。** ① 把桌收掉的那一刻，
     `trg_session_voided_release_queue` 跟著把房解開了
     （`matched_session_id` 清空、status 不再是 `seated`）——
     不重接的話這張桌在 ② 已經不是「配桌的桌」，會走 setup 的時鐘。
     ⚠ 2026-09-06 這一份的驗證失敗**四次，四次都是取樣或前置狀態**，
       一次都不是函式。**兩個機制串起來之後，前一格會改變下一格的前提。** */
  update table_sessions
     set status='open', ended_at=null,
         created_at = now() - interval '5 hours',
         started_at = now() - interval '5 hours'
   where id = v_sess;
  update match_queues
     set status='seated', matched_session_id = v_sess,
         play_at = now() + interval '3 hours'
   where id = v_q;

  v_r := public.cleanup_empty_sessions_tx(30);
  select status into v_st from table_sessions where id = v_sess;
  v_out := v_out || E'\n② 🎯 正對照：開打時間還沒到 → 不收' || E'\t' ||
    case when v_st = 'open'
         then '✅ 留著（held_for_queue=' || coalesce(v_r->>'held_for_queue','?') || '）'
         else '🔴 被收成 ' || v_st || ' —— 提前佔桌的設計就毀了' end;

  ---- ③ 🎯 正對照：非配桌的空桌照舊用「建立時間」----------
  update match_queues set matched_session_id = null, status='matched' where id = v_q;
  update table_sessions
     set status='open', ended_at=null,
         created_at = now() - interval '5 hours',
         started_at = now() - interval '5 hours'
   where id = v_sess;

  perform public.cleanup_empty_sessions_tx(30);
  select status into v_st from table_sessions where id = v_sess;
  v_out := v_out || E'\n③ 🎯 正對照：沒有配桌房的空桌照舊回收' || E'\t' ||
    case when v_st = 'voided' then '✅ 收了（setup 桌用建立時間）'
         else '🔴 還是 ' || v_st || ' —— 店員開了沒結帳的桌會永遠佔著' end;

  ---- ④ 🎯 正對照：剛開的 setup 桌不要收 ------------------
  update table_sessions
     set status='open', ended_at=null,
         created_at = now() - interval '2 minutes',
         started_at = now() - interval '2 minutes'
   where id = v_sess;

  perform public.cleanup_empty_sessions_tx(30);
  select status into v_st from table_sessions where id = v_sess;
  v_out := v_out || E'\n④ 🎯 正對照：剛開的 setup 桌不收' || E'\t' ||
    case when v_st = 'open' then '✅ 留著（店員還在結帳中）'
         else '🔴 被收走 —— 店員結到一半桌就沒了' end;

  ---- ⑤ 🎯 正對照：有人的桌永遠不收 ----------------------
  select count(*) into v_n from table_sessions ts
   where ts.status = 'voided' and ts.ended_at > now() - interval '5 seconds'
     and exists (select 1 from session_players sp
                  where sp.session_id = ts.id and sp.left_at is null);
  v_out := v_out || E'\n⑤ 🎯 正對照：有人的桌沒被誤收' || E'\t' ||
    case when v_n = 0 then '✅ 0 張' else '🔴 收掉了 ' || v_n || ' 張有人的桌' end;

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
