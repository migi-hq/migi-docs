/* ============================================================
   配桌房要自己講得出門市、開打狀態
   2026-09-06 · MIGI 咪吉麻將

   ── 起點 ──────────────────────────────────────────────
   使用者：「歷史配桌紀錄下面沒有出現『即將開始』跟『等待結算』」。
   查下去發現底下壓著一個**更嚴重**的問題。

   ── 🔴 成桌畫面會顯示寫死的假資料 ─────────────────────
   `match.jsx` 的 `active` 是 **App.jsx 的本地 state**，
   只有「這次開著 App 自己開房／報名」時才會被設定。
   ```js
   if (q) setActive((a) => a ? { ...a, players: … } : a)   // ← null 就永遠是 null
   ```
   ⇒ **重新整理之後 `active` 永遠是 null**，而成桌畫面的 fallback 是：
   ```
   ['開打時間', active?.time || '今天 19:30'          ]
   ['門市',     active?.store || 'MIGI 高雄自由店'     ]
   ['地址',     active?.addr  || '高雄市左營區自由三路 410 號']
   ['玩法',     … || '台麻 · 無花' · '3 將'            ]
   ['積分',     … || '50/20'                          ]
   ```
   ⇒ 客人重整之後看到的是**一個假的開打時間與假的地址**，
     而「導航過去」那顆按鈕用的就是那個假地址。
   🔴 **它不會報錯，看起來也完全正常** —— 那正是最糟的一種。

   🎯 這是 CLAUDE.md 記過的那個病第四次：
     **「畫面的值來自本機，而後端也有一份」**
     （`App.jsx:95` 的身分、手機號碼那一列、暱稱，現在是配桌房）。
     根治的方式一樣：**讓後端成為唯一的來源**，本機只當快取。

   ── 這一份補四個欄位（簽名不變）──────────────────────
   | 欄位 | 為了什麼 |
   |---|---|
   | `store_name` / `store_address` | 取代那兩個寫死的門市與地址 |
   | `stake_label` | 取代寫死的 `50/20` |
   | `activated_at` | **分得出「即將開始」與「等待結算」** |
   | `table_label` | 成桌之後告訴客人是幾號桌 |

   ⚠ `activated_at` 來自 `table_sessions`（`matched_session_id` join）——
     `match_queues` 上沒有「開打了沒」這件事，它只到 `seated` 為止。
   ⚠ `CREATE OR REPLACE`、簽名不變 ⇒ 不用 DROP、不丟 GRANT。
     **前端沒改也不會壞**（多回幾個鍵，舊版單純不讀）。
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
     /* ★ 2026-09-06：`seated` 要有界線（那是終點狀態，無條件放行的話
        客人明天打開還看到「你已經成桌囉！」）。界線＝那張桌還開著。 */
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
      /* ★ 2026-09-06：門市／注額／桌號／開打時間全部由後端給。
         🔴 在此之前前端在 `active` 是 null 時會印**寫死的假值**
           （'MIGI 高雄自由店'、'高雄市左營區自由三路 410 號'、'50/20'），
           而重整之後 `active` 一定是 null。
         ⚠ 門市要用**這個房的門市**，不是客人當下在瀏覽的那一間 ——
           兩者可以不同（他可以一邊等桌一邊逛別家）。 */
      'store_name',    st.name,
      'store_address', st.address,
      'stake_label',   sl.label,
      'table_label',   tb.label,
      /* 🔴 `activated_at` 是「真的開打了」，與 `seated`（帶到桌）是兩件事。
         POS 的「帶桌」與「開打」本來就是兩個動作，
         而客人端要靠它分「即將開始」與「等待結算」。
         ⚠ 它在 `table_sessions` 上，`match_queues` 沒有這個概念。 */
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
      /* ★ 本桌動態：每人一筆加入 + 有離開者加一筆離開。
         **只取最近 10 筆**，再依時間由舊到新排回來。
         舊版無條件全撈，開一天的房會累積十幾二十行把牌局資訊擠出畫面。 */
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
-- 驗證
-- ══════════════════════════════════════════════════════
do $v$
declare
  v_out text := '';
  v_q uuid; v_sess uuid; v_org uuid; v_mem uuid; v_r jsonb; v_n int;
begin
  /* 🔴 **不要求線上剛好有一個「seated 且桌還開著」的房。**
     2026-09-06 第一次跑就是這樣失敗的：那張 A3 在 01:00 被取消開桌
     （`table_sessions.status = 'voided'`）⇒ 新的界線正確地把它排除掉
     ⇒ 取樣找不到東西 ⇒ 七格全部沒跑。
     🎯 **驗證不該依賴線上當下的狀態** —— 整段本來就會回滾，
       那就在交易裡把樣本「借」成需要的樣子。 */
  select q.id, q.matched_session_id, q.org_id into v_q, v_sess, v_org
    from match_queues q
   where q.status = 'seated' and q.matched_session_id is not null
   order by q.updated_at desc limit 1;
  select qp.member_id into v_mem
    from match_queue_players qp where qp.queue_id = v_q and qp.left_at is null limit 1;

  if v_q is null or v_mem is null then
    perform set_config('migi.v', E'\n🔴 取樣失敗' || E'\t' ||
      '一個 seated 且有 session 的房都沒有 —— 下面每一格都不算數', true);
    return;
  end if;

  -- 借用：把那張桌暫時當成還開著（整段最後會回滾）
  update table_sessions set status = 'open', activated_at = null where id = v_sess;

  v_r := public.get_my_active_queue_tx(v_org, v_mem);

  ---- ① 四個新欄位都有值（不是「鍵在但都是 null」）--------
  /* 🔴 只驗「鍵存在」會過 —— `jsonb_build_object` 一定會建出那個鍵。
     要驗的是**值撈得到**。 */
  v_out := v_out || E'\n① 門市名稱' || E'\t' ||
    coalesce(nullif(v_r ->> 'store_name',''), '🔴 null —— 前端還是會印寫死的假門市');
  v_out := v_out || E'\n② 門市地址' || E'\t' ||
    coalesce(nullif(v_r ->> 'store_address',''), '🔴 null —— 導航會導到寫死的假地址');
  v_out := v_out || E'\n③ 注額 · 桌號' || E'\t' ||
    coalesce(v_r ->> 'stake_label','(null)') || '　·　' || coalesce(v_r ->> 'table_label','(還沒帶桌)');

  ---- ④ activated_at：現在應該是 null（帶了桌還沒開打）---
  v_out := v_out || E'\n④ activated_at（即將開始／等待結算）' || E'\t' ||
    case when (v_r ->> 'activated_at') is null
         then '✅ null ＝ 預留中 → 前端顯示「即將開始」'
         else '🟡 有值（' || (v_r ->> 'activated_at') || '）→ 顯示「等待結算」' end;

  ---- ⑤ 🎯 正對照：真的開打之後要變成有值 ----------------
  /* 只驗 ④ 的話，一支**永遠回 null** 的實作也會綠 ——
     而症狀是「等待結算」這個狀態永遠不會出現（硬規則 3.55）。 */
  update table_sessions set activated_at = now() where id = v_sess;
  v_r := public.get_my_active_queue_tx(v_org, v_mem);
  v_out := v_out || E'\n⑤ 🎯 正對照：開打後 activated_at 有值' || E'\t' ||
    case when (v_r ->> 'activated_at') is not null then '✅ 有值了' else '🔴 還是 null' end;

  ---- ⑥ 🎯 正對照：門市是「這個房的」不是隨便一間 --------
  select count(*) into v_n from stores s
   where s.name = (v_r ->> 'store_name')
     and s.id = (select store_id from match_queues where id = v_q);
  v_out := v_out || E'\n⑥ 🎯 正對照：門市對得上這個房' || E'\t' ||
    case when v_n = 1 then '✅ 對得上' else '🔴 撈到別間店的' end;

  ---- ⑦ 🎯 正對照：waiting 的房沒有被誤傷 ----------------
  update match_queues set status = 'waiting' where id = v_q;
  v_r := public.get_my_active_queue_tx(v_org, v_mem);
  v_out := v_out || E'\n⑦ 🎯 正對照：waiting 仍然回得到' || E'\t' ||
    case when v_r is not null and (v_r ->> 'status') = 'waiting'
         then '✅ 沒有誤傷，門市=' || coalesce(v_r ->> 'store_name','(null)')
         else '🔴 回不來了' end;

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
