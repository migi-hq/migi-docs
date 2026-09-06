/* ============================================================
   配桌列表的「已完成」加分頁，拿掉 7 天窗口
   2026-09-07 · MIGI 咪吉麻將 · 🔴 改簽名 → 先 DROP

   ── 為什麼 ────────────────────────────────────────────
   同一天稍早把「只留今天」改成「留 7 天」，但那只是把邊界推遠，
   沒有解決根本問題：**這一頁每 8 秒輪詢、一次把整間店的房全撈**，
   所以窗口拉長 = 每 8 秒重新下載更多歷史。

   ✅ 正解是**分頁**：預設只給最近 20 筆已收桌的，要往回翻再要更多。
   ⇒ 窗口可以整個拿掉 —— 翻得到一個月前，而預設的載入量反而更小。

   ── 誰分頁、誰不分頁 ──────────────────────────────────
   🔴 **只有「已收桌」分頁。**
   `waiting` / `matched` / `seated + 場次還開著` 是**現在的事**，
   一律全部回傳、不受 `p_limit` 影響。
   ⚠ 那三種被分頁截掉的話，會出現「有一桌在等你結帳但它在第二頁」——
     而店員不會知道要去翻。**現在的事沒有第二頁。**

   ── 新參數 ────────────────────────────────────────────
   ```
   p_before timestamptz default null   只要比這個時間更早收桌的（往回翻）
   p_limit  int         default 20     已收桌的最多幾筆（夾在 1..100）
   ```
   ⚠ **前端目前只用 `p_limit`（成長式）**，`p_before` 傳 null。
     這一頁每 8 秒輪詢，用游標的話就得把翻過的舊頁留在前端再跟輪詢
     結果合併 —— **而合併正是重複與漏列會發生的地方**。
     成長式（20 → 40 → 60）只有一個真相來源，會自我修正。
   📌 `p_before` 留著給**日後 migi-admin 的檔案庫**用：那一頁不輪詢，
     游標分頁才是對的做法。⚠ 它今天沒有呼叫點，**要記得它在等一個用途** ——
     如果檔案庫最後不是這樣做，就該把它拿掉。
   📌 前端判斷「還有沒有更多」：拿到的已收桌筆數 == `p_limit` 就當作還有。
     不改回傳形狀 —— 形狀一改三個消費端要一起改。
   ⚠ 成長式的上限是 100 筆 ≒ 一天 20 桌約 5 天。再往前是 migi-admin 的事。

   ── ⚠ 排序也順便修對 ──────────────────────────────────
   已收桌的之間依 `ended_at desc`（新到舊）——
   舊版是依 `play_at`，那是**開打時間**，往回翻時順序會跳。

   ── 🔴 硬規則 2：DROP 會把 GRANT 一起丟掉 ──────────────
   目前的授權：`anon` / `authenticated` / `service_role` 明確有，PUBLIC 也有。
   POS 用的是 **anon**，少補一行這一頁就整個空白（而且不會報錯，
   只會是「查無資料」的樣子）。檔案結尾補回來，驗證段第 ⑤ 格盯著它。
   ============================================================ */

drop function if exists public.pos_list_queues_tx(uuid, uuid);

create or replace function public.pos_list_queues_tx(
  p_org    uuid,
  p_store  uuid,
  p_before timestamptz default null,
  p_limit  int         default 20
)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with live as (
    /* 現在的事：全部回傳，**不分頁**。
       ⚠ 被截掉的話會出現「有一桌在等你結帳但它在第二頁」，
         而店員不會知道要去翻。 */
    select q.id
      from match_queues q
      left join table_sessions ts on ts.id = q.matched_session_id
     where q.org_id = p_org and q.store_id = p_store
       and (
         (q.status = 'waiting'
           and (q.expires_at is null or q.expires_at > now())
           and (q.open_at is null or q.open_at <= now()))
         or q.status = 'matched'
         or (q.status = 'seated' and ts.status = 'open' and ts.deleted_at is null)
       )
  ),
  history as (
    /* 已收桌的：新到舊，分頁。
       🔴 **配桌是延續的** —— 前兩位可能是上一班找到的，靠下一班完成，
         所以這裡**不可以有任何日／班的邊界**（2026-09-07 拿掉了 7 天窗口）。
       ⚠ `p_limit` 夾在 1..100：0 或負數會讓這一段整個消失，
         而症狀是「已完成分頁空的」，看不出是參數問題。 */
    select q.id
      from match_queues q
      join table_sessions ts on ts.id = q.matched_session_id
     where q.org_id = p_org and q.store_id = p_store
       and q.status = 'seated'
       and ts.status = 'completed' and ts.deleted_at is null
       and (p_before is null or ts.ended_at < p_before)
     order by ts.ended_at desc
     limit least(greatest(coalesce(p_limit, 20), 1), 100)
  ),
  picked as (select id from live union select id from history)
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
    /* 🔴 數的是「這桌收了幾份檯費」，**不要加 `left_at is null`** ——
       收桌時在座玩家一律被寫 `left_at`，那個條件會讓收桌那一刻
       掉回 0，配桌列表就對一個早就收齊的房喊「前往結帳」。
       ⚠ 也不要改成數 `order_id is not null`：暢打的人 order_id 是 null
       （那是「不用付」不是「還沒付」）。 */
    'paid_count', (
      select count(*) from session_players sp
       where sp.session_id = q.matched_session_id),
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
    /* 排序：現在的事在前；已收桌的之間**依收桌時間新到舊**。
       ⚠ 舊版依 `play_at`（開打時間）—— 往回翻時順序會跳。 */
  ) order by (ts.status is distinct from 'completed') desc,
             (q.status = 'seated') desc,
             (q.status = 'matched') desc,
             ts.ended_at desc nulls last,
             q.play_at), '[]'::jsonb)
  from match_queues q
  join picked pk on pk.id = q.id
  left join stake_levels sl on sl.id = q.stake_level_id and sl.org_id = p_org
  left join members mo on mo.id = q.opened_by
  left join table_sessions ts on ts.id = q.matched_session_id
  left join tables tb on tb.id = ts.table_id
$function$;

/* 🔴 DROP 把授權丟掉了，補回來（硬規則 2）。POS 用的是 anon。 */
grant execute on function public.pos_list_queues_tx(uuid, uuid, timestamptz, int)
  to anon, authenticated, service_role;

/* ── 驗證 ────────────────────────────────────────────────
   ⚠ 期望值一律當場算（硬規則 3.56），不寫死筆數。 */
with 全部 as (
  select e.v from jsonb_array_elements(
    pos_list_queues_tx((select id from orgs limit 1),
                       '22222222-2222-2222-2222-222222222222'::uuid)) e(v)
),
第一頁 as (
  select e.v from jsonb_array_elements(
    pos_list_queues_tx((select id from orgs limit 1),
                       '22222222-2222-2222-2222-222222222222'::uuid, null, 1)) e(v)
)
select
  /* ① 現在的事全都在（不受 p_limit 影響）。
     🎯 第一頁只要 1 筆已收桌，但進行中的必須一筆不少。 */
  (select case when count(*) = (select count(*) from 全部
                                 where (v ->> 'session_status') is distinct from 'completed')
               then '✅ ① 進行中的房不受分頁影響（' || count(*)::text || ' 房）'
               else '🔴 ① 進行中的被截掉了' end
     from 第一頁 where (v ->> 'session_status') is distinct from 'completed') as ①現在的事不分頁,

  /* ② p_limit 真的有作用 */
  (select case when count(*) = 1 then '✅ ② p_limit=1 時已收桌的只回 1 筆'
               else '🔴 ② 回了 ' || count(*)::text || ' 筆，limit 沒作用' end
     from 第一頁 where (v ->> 'session_status') = 'completed') as ②limit有效,

  /* ③ 🎯 p_before 往回翻：第二頁不可以包含第一頁那一筆。
     ⚠ 少了這一格，一支「忽略 p_before」的實作也會讓①②變綠。 */
  (select case when count(*) = 0 then '✅ ③ 往回翻不會重複第一頁那一筆'
               else '🔴 ③ 第二頁又出現了第一頁的資料' end
     from jsonb_array_elements(
            pos_list_queues_tx((select id from orgs limit 1),
              '22222222-2222-2222-2222-222222222222'::uuid,
              (select (v ->> 'settled_at')::timestamptz from 第一頁
                where (v ->> 'session_status') = 'completed' limit 1), 20)) e(v)
    where (e.v ->> 'session_status') = 'completed'
      and (e.v ->> 'id') = (select v ->> 'id' from 第一頁
                             where (v ->> 'session_status') = 'completed' limit 1)) as ③往回翻不重複,

  /* ④ 🎯 7 天窗口拿掉了：比 7 天更舊的也翻得到。
     ⚠ 今天可能沒有那麼舊的資料 ⇒ 用「函式裡還有沒有那段」來驗，
       而禁字用 `interval '7 days'`（會產生行為的東西，不是註解裡的字）。 */
  case when (select count(*) from pg_proc p
              where p.pronamespace = 'public'::regnamespace
                and p.proname = 'pos_list_queues_tx'
                and pg_get_functiondef(p.oid) ~ 'interval ''7 days''') = 0
       then '✅ ④ 7 天窗口已移除（改用分頁）'
       else '🔴 ④ 窗口還在，會跟分頁打架' end as ④窗口已移除,

  /* ⑤ 🔴 DROP 之後授權有沒有補回來。
     ⚠ 用 `aclexplode` 而不是 `has_function_privilege` ——
       後者分不出「明確授權」與「從 PUBLIC 繼承」（硬規則 2.6）。 */
  (select case when count(*) = 3
               then '✅ ⑤ anon／authenticated／service_role 都有明確授權'
               else '🔴 ⑤ 只有 ' || count(*)::text || ' 個 —— POS 用 anon，少了整頁空白' end
     from pg_proc p, aclexplode(p.proacl) a
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'pos_list_queues_tx'
      and a.privilege_type = 'EXECUTE'
      and a.grantee in ('anon'::regrole::oid, 'authenticated'::regrole::oid,
                        'service_role'::regrole::oid)) as ⑤授權補回來了,

  /* ⑥ 只有一個版本（沒有建出多載）。硬規則 2 的另一半。 */
  (select case when count(*) = 1 then '✅ ⑥ 只有一個版本'
               else '🔴 ⑥ 有 ' || count(*)::text || ' 個多載 —— 舊的沒 DROP 掉' end
     from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'pos_list_queues_tx') as ⑥沒有多載;
