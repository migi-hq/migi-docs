-- 【這是什麼】本桌動態只回最近 10 筆，不再把整個房的歷史全撈出來。
-- 【何時讀】執行前。
--
-- ═══ 問題 ═══
--
-- get_my_active_queue_tx 的 events 是無條件全撈：
--   每一筆 match_queue_players 的 joined_at 一筆、有 left_at 的再一筆，全部回傳。
-- 一個開著一天的房被反覆加入／離開之後，客人會看到十幾二十行 ——
-- 2026-08-23 實測 18 行，把下面的「牌局資訊」整個擠出畫面。
--
-- ⚠ 這不只是測試資料的問題。**一個沒有上限的清單遲早會長到蓋掉下面的東西**，
--   而它不會報錯，只是畫面愈來愈難用。
--
-- ═══ 為什麼是 10 筆而不是「最近 N 小時」═══
--
-- 動態要回答的是「這桌現在熱不熱、有沒有人在走」，那是**相對的**：
-- 冷門時段一小時只有一筆，熱門時段十分鐘就五筆。
-- 用時間切的話，冷門時段會變成空白（看起來像壞掉），熱門時段還是爆。
-- 筆數是穩定的 —— 不管什麼時段，都給你「最近發生的那幾件」。
--
-- ⚠ 排序維持舊 → 新（時間順序讀起來自然），只是現在最多 10 筆，
--   最新的那筆一定在可見範圍內。

create or replace function get_my_active_queue_tx(p_org_id uuid, p_member uuid)
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
     and q.org_id = p_org_id and q.status in ('waiting','matched')
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
      'players', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'member_id', m.id, 'nickname', m.display_name, 'rank', m.rank,
          'avatar_url', m.avatar_url, 'joined_at', qp2.joined_at,
          'avatar_source', m.avatar_source, 'avatar_photo_path', m.avatar_photo_path
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
            -- 加入事件
            select jsonb_build_object('type','join','nickname', m.display_name, 'at', qp3.joined_at) as e,
                   qp3.joined_at as at_ts
              from match_queue_players qp3 join members m on m.id = qp3.member_id
             where qp3.queue_id = q.id
            union all
            -- 離開事件（只取有 left_at 的）
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
    from match_queues q where q.id = v_qid
  );
end $function$;

-- ── 驗證（單一 SELECT）────────────────────────────────────────
select 項目, 結果
from (
  select 1 as ord, '① 函式有沒有加上限（應含 limit 10）' as 項目,
    (select case when prosrc like '%limit 10%' then '✅ 是' else '❌ 否' end
       from pg_proc where pronamespace='public'::regnamespace
        and proname='get_my_active_queue_tx' limit 1) as 結果

  union all select 2, '② 版本數（應為 1）',
    (select count(*)::text from pg_proc
      where pronamespace='public'::regnamespace and proname='get_my_active_queue_tx')

  -- 拿一個真的有在座紀錄的房來實測
  union all select 3, '③ 實測：某個在座會員的動態筆數（應 ≤ 10）',
    coalesce((select jsonb_array_length(
                get_my_active_queue_tx('11111111-1111-1111-1111-111111111111'::uuid, p.member_id)
                  -> 'events')::text
                from match_queue_players p
                join match_queues q on q.id = p.queue_id
               where p.left_at is null and q.status in ('waiting','matched')
               limit 1),
             '（目前沒有人在任何房裡 —— 先去 App 報名一場再跑）')

  union all select 4, '④ 那一房實際累積了幾筆事件（對照用）',
    coalesce((select ((select count(*) from match_queue_players x where x.queue_id = q.id)
                    + (select count(*) from match_queue_players x
                        where x.queue_id = q.id and x.left_at is not null))::text
                from match_queue_players p
                join match_queues q on q.id = p.queue_id
               where p.left_at is null and q.status in ('waiting','matched')
               limit 1),
             '-')
) x
order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
-- ③ 應該 ≤ 10。④ 是那一房實際累積的總數 ——
--    ④ 大於 10 而 ③ 等於 10，就代表限制真的生效了。
-- ⚠ ③ 顯示「目前沒有人在任何房裡」的話不是失敗，是現在真的沒人在排隊。
