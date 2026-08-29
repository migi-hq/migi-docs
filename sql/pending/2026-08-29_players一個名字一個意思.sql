/* ============================================================
   `players` 一個名字一個意思（待辦 35 收尾）
   2026-08-29

   ── 病 ──────────────────────────────────────────────
   同一個 key `players` 在不同 RPC 有**兩種形狀**：

   | 函式 | players 是 | 誰讀 |
   |---|---|---|
   | `get_my_active_queue_tx` | **陣列** | 座位列 |
   | `get_my_games_tx` | **陣列** | 成績頁 |
   | `list_match_queues_tx` | **數字** | 🔴 已無人讀 |
   | `list_tables_tx` | **數字** | POS 桌況卡片 |
   | `pos_add_queue_member_tx` | **數字** | POS 加入提示 |

   🔴 已經真的炸過：`app_error` 裡
     `(t.players || []).map is not a function` ×5（2026-08-22）。
   ⚠ **`|| []` 只擋 null／undefined，擋不住「是數字」這種真值** ——
     它給了一種「我防過了」的錯覺，那比完全沒防更危險。

   ── 這一份做兩件事 ──────────────────────────────────
   ① **contract**：`list_match_queues_tx` **拿掉 `players`**
      （前端已於 2026-08-29 改讀 `player_count` 並部署過，
        且已 grep 三端確認**沒有任何地方再讀它**）
   ② **expand**：`list_tables_tx` **補上 `player_count`**，`players` 先留著
      —— 🔴 我原本只看到一個源頭，查證時才發現桌況也是數字版的 `players`。

   ⚠ 為什麼 ② 不一起拿掉：POS 的 `App.jsx:298,306` 還在讀 `t.players`。
     拿掉的話**人數會變空白而且不報錯**。
     → 前端改讀 `player_count` 並部署過之後，才做第二次 contract。
   📌 這就是 expand → migrate → contract 的意義：
     **中間一定要有一段兩者並存的時間**，否則舊版裝置會立刻壞掉。

   ⚠ `pos_add_queue_member_tx` 的 `players` 不動 ——
     它回的是「加入之後現在幾人」，是一次性的操作結果不是清單欄位，
     而且它從來沒有陣列版本。改名只是製造第三次遷移。

   ── 簽名都沒變 ⇒ `CREATE OR REPLACE` ────────────────
   不用 DROP、不會掉 GRANT（硬規則 2）。
   ⚠ 兩支都是從 `pg_get_functiondef` 撈線上版改的（硬規則 3）。
   ============================================================ */

-- ── ① contract：list_match_queues_tx 拿掉 players ──
create or replace function public.list_match_queues_tx(p_org_id uuid, p_member uuid, p_store uuid)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', q.id, 'store_id', q.store_id, 'stake_level_id', q.stake_level_id,
      'game_type', q.game_type, 'flower', q.flower, 'rounds', q.rounds, 'seats', q.seats,
      'play_at', q.play_at, 'prefs', q.prefs, 'source', q.source, 'tags', q.tags,
      'recurring_id', q.recurring_id, 'recurring_freq', q.recurring_freq,
      'opener', mo.display_name,
      /* ★ 2026-08-29 contract：`players`（數字）已拿掉，只剩 `player_count`。
         同一個 key 兩種形狀是待辦 35 的病，而它已經真的炸過一次。 */
      'player_count', (select count(*) from match_queue_players qp
                        where qp.queue_id = q.id and qp.left_at is null)
    ) order by (q.source='pos') desc, (q.source='recurring') desc, q.play_at asc)
    from match_queues q
    left join members mo on mo.id = q.opened_by
    where q.org_id=p_org_id and q.store_id=p_store and q.status='waiting'
      and (q.expires_at is null or q.expires_at > now())
      and (q.open_at is null or q.open_at <= now())
      and not exists (
        select 1 from match_queue_players qp
        where qp.queue_id=q.id and qp.left_at is null
          and _blocked_between(p_org_id, p_member, qp.member_id))
  ), '[]'::jsonb);
end $function$;


-- ── ② expand：list_tables_tx 補上 player_count ──
--    ⚠ `players` 先留著，POS 還在讀（見檔頭）。
create or replace function public.list_tables_tx(p_org_id uuid, p_store_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', t.id, 'label', t.label, 'area', t.area, 'seats', t.seats,
      'is_active', t.is_active, 'note', t.note,

      -- ⚠ status 維持三值（off / use / idle），不新增 'hold'。
      --    舊版 POS 遇到沒見過的值會掉進「停用」分支畫成灰卡，比現況更糟。
      'status', case
                  when not t.is_active then 'off'
                  when ts.id is not null then 'use'
                  else 'idle' end,

      'session_id', ts.id,
      'started_at', ts.started_at,
      'planned_minutes', ts.planned_minutes,
      'stake_level_id', ts.stake_level_id,
      'mode', ts.mode,

      -- 在座人數：session_players 是**結帳成功後**才建立的，
      -- 所以「還沒有人結帳」與「還沒有人到」在這個系統裡是同一件事。
      /* ★ 2026-08-29 expand：補上 `player_count`。
         `players` 在別的 RPC 是**陣列**，同一個名字兩種形狀已經炸過一次
         （待辦 35）。⚠ 這裡先兩者並存 —— POS 的 App.jsx 還在讀 `players`，
         直接拿掉會讓人數變空白**而且不報錯**。 */
      'players', coalesce(pl.n, 0),
      'player_count', coalesce(pl.n, 0),

      -- ── 預留中 ───────────────────────────────────────────
      -- 桌開著但一個人都還沒入座。畫面上必須跟「真的有人在打」分開，
      -- 否則店員會把現場客人推掉（見檔頭）。
      'is_hold', (ts.id is not null and coalesce(pl.n, 0) = 0),

      -- queue = 配桌湊滿自動佔的（客人還沒到，要等）
      -- setup = 店員按了開桌設定還沒結帳（他一分鐘前的動作，點進去繼續）
      'hold_kind', case
                     when ts.id is null or coalesce(pl.n, 0) > 0 then null
                     when mq.id is not null then 'queue'
                     else 'setup' end,

      'queue_id',       mq.id,
      'queue_play_at',  mq.play_at,
      -- 誰要來。⚠ 只算沒離開的（left_at is null）——
      -- 報名後又退出的人不該出現在「等一下會來這桌」的名單裡。
      'queue_members',  coalesce(mq.names, '[]'::jsonb),

      -- ── 現場專用 ─────────────────────────────────────────
      -- false = 這張桌不給系統自動配。是**店員的意思**，沒人改就不會變，
      -- 所以它是欄位不是算出來的（桌況本身仍然是每次從 table_sessions 算）。
      'auto_assign', t.auto_assign

    ) order by t.sort_order, t.label)
    from tables t

    left join lateral (
      select ts.* from table_sessions ts
       where ts.table_id = t.id and ts.status = 'open' and ts.deleted_at is null
       order by ts.started_at desc limit 1
    ) ts on true

    -- 在座人數獨立拉出來：is_hold 與 players 都要用，算兩次會有機會寫歪一次
    left join lateral (
      select count(*)::int as n
        from session_players sp
       where sp.session_id = ts.id
         and sp.left_at is null
    ) pl on true

    -- 這張桌是被哪一房配走的。matched_session_id 是 2026-08-23 那批補上的橋。
    left join lateral (
      select q.id, q.play_at,
             (select coalesce(jsonb_agg(m.display_name order by p.joined_at), '[]'::jsonb)
                from match_queue_players p
                join members m on m.id = p.member_id
               where p.queue_id = q.id and p.left_at is null) as names
        from match_queues q
       where q.matched_session_id = ts.id
       order by q.play_at desc
       limit 1
    ) mq on true

    where t.org_id = p_org_id and t.store_id = p_store_id and t.deleted_at is null
  ), '[]'::jsonb);
end $function$;


/* ============================================================
   驗證（單一 SELECT）

   ① `list_match_queues_tx` 的 `players` 不見了、`player_count` 還在
   ② 🎯 **正對照**：`list_tables_tx` 的**兩個都在**
      —— 只驗「拿掉了」是不夠的：把函式寫壞也會讓 key 消失，
        而那個症狀跟「正確拿掉」長得一模一樣（硬規則 3.55）。
   ③ 🎯 正對照：`list_tables_tx` 的其他欄位一個都沒少
      —— 我是整支重寫的，漏一行不會報錯，只會讓 POS 的某個標記消失
   ④ 兩支的模式與授權沒被動到
   ============================================================ */
select 序, 項目, 內容 from (

  select 1 as 序, '① list_match_queues_tx（players 應該不見了）' as 項目,
         (select case when j is null then '⚠ 這間門市沒有 waiting 的房 —— 這一格沒驗到'
                      else '欄位：' || (select string_agg(k, '、' order by k) from jsonb_object_keys(j) k)
                        || case when not (j ? 'players') and (j ? 'player_count')
                                then E'\n  ✅ players 已拿掉、player_count 還在'
                                else E'\n  🔴 不如預期' end end
            from (select list_match_queues_tx(
                    '11111111-1111-1111-1111-111111111111', null,
                    (select store_id from match_queues where status='waiting'
                      order by created_at desc limit 1)) -> 0 as j) t) as 內容

  union all
  select 2, '② 🎯 正對照：list_tables_tx 兩個 key 都要在',
         (select case when j is null then '🔴 一張桌都沒有'
                      when (j ? 'players') and (j ? 'player_count')
                      then '✅ players=' || (j->>'players') || '　player_count=' || (j->>'player_count')
                        || '（並存＝expand 正確，POS 改完再 contract）'
                      else '🔴 缺一個' end
            from (select list_tables_tx('11111111-1111-1111-1111-111111111111',
                    (select id from stores order by created_at limit 1)) -> 0 as j) t)

  union all
  select 3, '③ 🎯 正對照：list_tables_tx 的其他欄位一個都沒少',
         (select case when j is null then '🔴 一張桌都沒有'
                      else (select count(*) from jsonb_object_keys(j))::text || ' 個欄位'
                        || case when (select count(*) from unnest(array[
                                  'id','label','area','seats','is_active','note','status',
                                  'session_id','started_at','planned_minutes','stake_level_id','mode',
                                  'players','player_count','is_hold','hold_kind',
                                  'queue_id','queue_play_at','queue_members','auto_assign']) k
                                 where not j ? k) = 0
                                then '　✅ 20 個全在（含 is_hold／hold_kind／auto_assign）'
                                else '　🔴 少了：' || (select string_agg(k,'、') from unnest(array[
                                  'id','label','area','seats','is_active','note','status',
                                  'session_id','started_at','planned_minutes','stake_level_id','mode',
                                  'players','player_count','is_hold','hold_kind',
                                  'queue_id','queue_play_at','queue_members','auto_assign']) k
                                 where not j ? k) end end
            from (select list_tables_tx('11111111-1111-1111-1111-111111111111',
                    (select id from stores order by created_at limit 1)) -> 0 as j) t)

  union all
  select 4, '④ 🎯 正對照：模式與授權都沒被動到',
         (select string_agg(p.proname
                 || '　' || case when p.prosecdef then 'DEFINER' else '🔴 INVOKER' end
                 || '　anon=' || case when has_function_privilege('anon', p.oid, 'execute') then '✅' else '🔴 無' end,
                 E'\n' order by p.proname)
            from pg_proc p
           where p.pronamespace='public'::regnamespace and p.prokind='f'
             and p.proname in ('list_match_queues_tx','list_tables_tx'))

) x order by 序;
