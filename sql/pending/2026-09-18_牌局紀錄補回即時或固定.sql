/* ═══════════════════════════════════════════════════════════════════
   牌局詳情的「類型」要講得出即時／固定
   2026-09-18 · 使用者指定
   ═══════════════════════════════════════════════════════════════════

   使用者：「牌桌詳情 類型要加即時或固定」。

   前端**早就會組那句話**了（`kindText(kind, source)` → 「配桌 · 即時牌局」，
   配桌頁與成桌彈窗都在用），缺的只是 `get_my_games_tx` 沒有回 `source`
   ⇒ 牌局詳情永遠只印「配桌」。

   📌 關聯本來就存在：`match_queues.matched_session_id` = 那一場的 id。
     那支函式的註解自己寫著「配桌與開桌的關聯在 matched_session_id，這裡用不到」
     —— 現在用得到了。

   ⚠ `source` 的實際值是 **member / pos / recurring**（實查 114 筆）：
     · recurring → 固定牌局
     · 其餘      → 即時牌局
     前端 `kindText` 就是這樣分的（`source === 'recurring' ? 固定 : 即時`），
     **這裡原樣回傳，不要在 SQL 裡翻成中文** —— 顯示規則不住在資料庫裡。

   ⚠ 包桌（`mode = 'private'`）沒有即時／固定之分，前端拿到也不會用。
   ⚠ 對不到配桌房就是 null ⇒ 前端只印「配桌」，不猜（猜錯會讓固定牌局
     顯示成即時牌局，而那不會報錯、只會讓人白等一週）。

   ✅ 只多回一個鍵，簽名不變 ⇒ CREATE OR REPLACE、不丟 GRANT。
   ⚠ 這份要留下 DDL ⇒ 驗證段不 raise（硬規則 1.8）。
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.get_my_games_tx(p_org_id uuid, p_member_id uuid, p_limit integer default 20)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v_me uuid;
begin
  v_me := public.current_member_id();
  p_member_id := coalesce(v_me, p_member_id);

  return (
    with mine as (
      -- 從「我坐過的位子」反查場次 —— 不需要知道那桌是怎麼開的。
      select s.id, s.mode, s.store_id, s.stake_level_id,
             s.game_type, s.flower, s.planned_rounds,
             s.started_at, s.activated_at, s.ended_at,
             sp.finish_rank      as my_rank,
             sp.score_points     as my_score,
             sp.charged_points   as my_charged,
             sp.fee_waived_amount as my_waived,
             sp.seat             as my_seat,
             -- ★ 2026-08-31：走勢圖用。M4 之前是 null。
             sp.rating_after     as my_rating_after,
             sp.settled_at       as my_settled_at
        from session_players sp
        join table_sessions s on s.id = sp.session_id
       where sp.member_id = p_member_id
         and sp.org_id    = p_org_id
         and s.org_id     = p_org_id
         and s.deleted_at is null
         and s.status     = 'completed'
       order by s.ended_at desc nulls last
       limit greatest(coalesce(p_limit, 20), 1)
    )
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'session_id', m.id,
        -- table_sessions.mode ∈ matched / private，就是配桌 vs 包桌
        'kind',   case when m.mode = 'private' then 'package' else 'match' end,
        -- 已收桌但還沒結算戰績 → pending；有名次 → settled
        'status', case when m.my_rank is not null then 'settled' else 'pending' end,
        /* 🆕 2026-09-18：這一場是從哪一種配桌房來的（member／pos／recurring）。
           前端 `kindText` 用它分「即時牌局／固定牌局」。對不到房就是 null。 */
        'source',     q.source,
        'store',      st.name,
        'addr',       st.address,
        'game_type',  m.game_type,
        'flower',     m.flower,
        'rounds',     m.planned_rounds,     -- 整數，「幾將」由前端組字
        'stake',      sl.label,             -- 積分級距顯示名，例如 50/20、純娛樂麻將
        -- 開打時間用 activated_at（帶桌／真正開打），沒有才退回 started_at（開桌）
        'started_at', coalesce(m.activated_at, m.started_at),
        'ended_at',   m.ended_at,
        'duration_minutes',
          case when m.ended_at is not null
               then greatest(0, (extract(epoch from
                      (m.ended_at - coalesce(m.activated_at, m.started_at))) / 60)::int)
               else null end,
        'my_rank',          m.my_rank,      -- M4 之前是 null
        'my_score',         m.my_score,     -- M4 之前是 null
        'my_charged_points', m.my_charged,
        'my_fee_waived',     m.my_waived,   -- 暢打／店員／店長特調免收的金額
        'my_seat',           m.my_seat,
        /* ★ 2026-08-31 新增：走勢圖的兩個座標。 */
        'my_rating_after',   m.my_rating_after,
        'settled_at',        m.my_settled_at,
        'players', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'member_id',    p.member_id,
                   'nickname',     mem.display_name,
                   'rank',         mem.rank,
                   'avatar_url',        mem.avatar_url,
                   'avatar_source',     mem.avatar_source,
                   'avatar_photo_path', mem.avatar_photo_path,
                   'avatar_bear',       mem.avatar_bear,
                   'title',        mem.title,
                   'seat',         p.seat,
                   'finish_rank',  p.finish_rank,
                   'score_points', p.score_points,
                   /* 桌上積分（2026-09-06）。⚠ null 是有意義的：
                      純娛樂的桌不計積分，那與「打平（0）」不同。 */
                   'final_score',  p.final_score,
                   'is_me',        p.member_id = p_member_id
                 ) order by coalesce(p.finish_rank, 99), p.seat nulls last, p.joined_at)
            from session_players p
            join members mem on mem.id = p.member_id
           where p.session_id = m.id), '[]'::jsonb)
      ) order by m.ended_at desc nulls last
    ), '[]'::jsonb)
    from mine m
    left join stores       st on st.id = m.store_id       and st.org_id = p_org_id
    left join stake_levels sl on sl.id = m.stake_level_id and sl.org_id = p_org_id
    /* ⚠ 用 lateral ＋ limit 1：理論上一場只會對到一個房，
       但這裡不假設它 —— 多對到一筆的話 join 會讓整場資料變成兩列。 */
    left join lateral (
      select mq.source
        from match_queues mq
       where mq.matched_session_id = m.id
         and mq.org_id = p_org_id
       order by mq.created_at
       limit 1
    ) q on true
  );
end $function$;


/* ═══ 驗證段（不 raise）═══ */
do $$
declare
  v_msg text := '';
  v_def text;
  v_n   int;
  v_ok  boolean;
begin
  select count(*) into v_n from pg_proc
   where pronamespace = 'public'::regnamespace and proname = 'get_my_games_tx';
  v_def := pg_get_functiondef('public.get_my_games_tx(uuid,uuid,integer)'::regprocedure);
  v_msg := case when v_n = 1 and v_def ilike '%security definer%'
    then '✅ ① 版本數 1 · DEFINER' else '🔴 ① 版本數 ' || v_n || ' 或不是 DEFINER' end;

  /* ② 新鍵在，而且是從 match_queues 來的 */
  v_msg := v_msg || E'\n' || case
    when v_def ilike '%''source''%' and v_def ilike '%matched_session_id%'
    then '✅ ② 多回 source，來源是 match_queues.matched_session_id'
    else '🔴 ② source 沒加到，或沒有接上配桌房' end;

  /* ③ 舊的鍵一個都沒少 —— 少一個，成績頁與走勢圖會靜靜缺一格 */
  v_msg := v_msg || E'\n' || case
    when v_def ilike '%''session_id''%' and v_def ilike '%''my_rating_after''%'
     and v_def ilike '%''final_score''%' and v_def ilike '%''duration_minutes''%'
     and v_def ilike '%''settled_at''%'  and v_def ilike '%''players''%'
    then '✅ ③ 原本的鍵都還在'
    else '🔴 ③ 原本的鍵少了' end;

  /* ④ 授權沒掉（前端是 anon 叫它的） */
  select has_function_privilege('anon', 'public.get_my_games_tx(uuid,uuid,integer)', 'execute') into v_ok;
  v_msg := v_msg || E'\n' || case when v_ok
    then '✅ ④ anon 仍然叫得動' else '🔴 ④ 授權掉了' end;

  /* ⑤ 正對照：真的抓一場已收桌的場次出來，看 source 對不對。
     ⚠ 只讀不寫。找不到樣本要**出聲**，不要安靜跳過（硬規則 3.57）。 */
  declare
    v_sid uuid; v_src text; v_expect text;
  begin
    select mq.matched_session_id, mq.source
      into v_sid, v_expect
      from match_queues mq
      join table_sessions s on s.id = mq.matched_session_id
     where mq.matched_session_id is not null
       and s.status = 'completed'
     order by s.ended_at desc nulls last
     limit 1;

    if v_sid is null then
      v_msg := v_msg || E'\n⚪ ⑤ 沒有「已收桌而且對得到配桌房」的場次可以取樣 —— 這一格測不了';
    else
      select q.source into v_src
        from table_sessions m
        left join lateral (
          select mq.source from match_queues mq
           where mq.matched_session_id = m.id order by mq.created_at limit 1
        ) q on true
       where m.id = v_sid;
      v_msg := v_msg || E'\n' || case when v_src is not distinct from v_expect
        then '✅ ⑤ 取樣的場次對回房間：source = ' || coalesce(v_src, 'null')
             || '（' || case when v_src = 'recurring' then '固定牌局' else '即時牌局' end || '）'
        else '🔴 ⑤ 對回來的 source 是 ' || coalesce(v_src, 'null')
             || '，但那個房寫的是 ' || coalesce(v_expect, 'null') end;
    end if;
  end;

  /* ⑥ 負對照：包桌（private）不該因為這次改動多出一個房 */
  select count(*) into v_n
    from table_sessions s
    join match_queues mq on mq.matched_session_id = s.id
   where s.mode = 'private';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ⑥ 沒有包桌場次對到配桌房（包桌本來就不經過配桌）'
    else '⚠ ⑥ 有 ' || v_n || ' 場包桌對到了配桌房 —— 前端不會用它，但值得看一眼為什麼' end;

  perform set_config('migi.verify_games_source', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify_games_source', true), ''), '🔴 沒有驗證訊息') as "驗證";
