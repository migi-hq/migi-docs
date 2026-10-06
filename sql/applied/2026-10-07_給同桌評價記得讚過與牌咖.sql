/* ============================================================
   「給同桌評價」抽屜記得：這一場讚過誰、誰已經是牌咖／已邀請
   2026-10-07 · MIGI 咪吉麻將

   起點：使用者說「按讚要實作」。查下去讚其實有寫進 member_likes（也有發小熊餅乾），
   但抽屜**從來沒讀回來** ⇒ 關掉再打開，讚全部變回沒按，看起來像沒作用；
   「＋ 加牌咖」也一樣，不知道對方早就是牌咖、或已經邀請過。

   ✏️ _game_row 的 players 每人多兩個欄位（簽名不變 ⇒ create or replace，授權不會掉）：
     liked_by_me   這一場我有沒有讚過他（member_likes：liker＝我、target＝他、session＝這一場）
     buddy_state   'buddy'（已是牌咖，兩個方向都算，同 get_member_card_tx 的判斷）
                   'invited'（我送過、對方還沒回）／null
   ⚠ 「我」＝ p_member_id，就是呼叫端傳進來的那位（get_game_tx 傳的是 current_member_id()）。
   其餘內容一字不動 —— 從線上版本撈出來改的。
   ============================================================ */

create or replace function public._game_row(p_org_id uuid, p_session_id uuid, p_member_id uuid)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select jsonb_build_object(
    'session_id', m.id,
    -- table_sessions.mode ∈ matched / private，就是配桌 vs 包桌
    'kind',   case when m.mode = 'private' then 'package' else 'match' end,
    -- 已收桌但還沒結算戰績 → pending；有名次 → settled
    'status', case when sp.finish_rank is not null then 'settled' else 'pending' end,
    /* 這一場是從哪一種配桌房來的（member／pos／recurring，2026-09-18 加）。
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
    -- 結束時間：收桌時間；還沒收桌就用打完、成績算好的那一刻（2026-10-02）
    'ended_at',   coalesce(m.ended_at, sp.settled_at),
    'duration_minutes',
      case when coalesce(m.ended_at, sp.settled_at) is not null
           then greatest(0, (extract(epoch from
                  (coalesce(m.ended_at, sp.settled_at) - coalesce(m.activated_at, m.started_at))) / 60)::int)
           else null end,
    'my_rank',           sp.finish_rank,      -- M4 之前是 null
    'my_score',          sp.score_points,     -- M4 之前是 null
    'my_charged_points', sp.charged_points,
    'my_fee_waived',     sp.fee_waived_amount,  -- 暢打／店員／店長特調免收的金額
    'my_seat',           sp.seat,
    /* 走勢圖的兩個座標。⚠ `settled_at` 不能用 `ended_at` 代替 ——
       收桌與結算是兩個動作，而走勢圖畫的是**分數變動的時間**。 */
    'my_rating_after',   sp.rating_after,
    'settled_at',        sp.settled_at,
    'players', coalesce((
      select jsonb_agg(jsonb_build_object(
               'member_id',    p.member_id,
               'nickname',     mem.display_name,
               /* 段位是「那一場的事實」：打完時的段位（2026-10-02）。被隱藏的人不顯示；還在打就是現在的；
                  收了桌卻沒有段位分（只打 1 將）就不顯示 —— 不知道當時是什麼，不猜 */
               'rank',         case when mem.hidden_at is not null then null
                                    when p.rating_after is not null then public.rank_from_rating(p.rating_after)
                                    when m.status = 'open' then mem.rank
                                    else null end,
               'avatar_url',        mem.avatar_url,
               'avatar_source',     mem.avatar_source,
               'avatar_photo_path', mem.avatar_photo_path,
               'avatar_bear',       mem.avatar_bear,
               'title',        mem.title,
               'seat',         p.seat,
               'finish_rank',  p.finish_rank,
               'score_points', p.score_points,
               /* 桌上積分。⚠ null 是有意義的：純娛樂的桌不計積分，
                  那與「打平（0）」不同。 */
               'final_score',  p.final_score,
               'is_me',        p.member_id = p_member_id,
               /* 🆕 2026-10-07：「給同桌評價」抽屜重開時要記得狀態 */
               'liked_by_me',  exists (select 1 from member_likes l
                                        where l.liker_id = p_member_id and l.target_id = p.member_id
                                          and l.session_id = m.id),
               'buddy_state',  case
                 when p.member_id = p_member_id then null
                 when exists (select 1 from mahjong_buddies b
                               where b.deleted_at is null
                                 and ((b.member_id = p_member_id and b.buddy_id = p.member_id)
                                   or (b.member_id = p.member_id and b.buddy_id = p_member_id))) then 'buddy'
                 when exists (select 1 from buddy_invites i
                               where i.inviter_id = p_member_id and i.invitee_id = p.member_id
                                 and i.status = 'pending') then 'invited'
                 else null end
             ) order by coalesce(p.finish_rank, 99), p.seat nulls last, p.joined_at)
        from session_players p
        join members mem on mem.id = p.member_id
       where p.session_id = m.id), '[]'::jsonb)
  )
  from table_sessions m
  join session_players sp
    on sp.session_id = m.id
   and sp.member_id  = p_member_id
   and sp.org_id     = p_org_id
  left join stores       st on st.id = m.store_id       and st.org_id = p_org_id
  left join stake_levels sl on sl.id = m.stake_level_id and sl.org_id = p_org_id
  /* ⚠ lateral ＋ limit 1：理論上一場只對到一個配桌房，
     但不假設它 —— 多對到一筆會讓整場資料變成兩列。 */
  left join lateral (
    select mq.source
      from match_queues mq
     where mq.matched_session_id = m.id
       and mq.org_id = p_org_id
     order by mq.created_at
     limit 1
  ) q on true
  where m.id = p_session_id
    and m.org_id = p_org_id
    and m.deleted_at is null
$function$;

-- ── 驗證（單一 SELECT）：拿線上真的讚與邀請當樣本，正反兩面都看 ─────────────
--   樣本一律當場撈（硬規則 3.57），找不到就說「測不了」，不安靜跳過
with lk as (     -- 最近一筆讚
  select l.org_id, l.liker_id, l.target_id, l.session_id from member_likes l
   where l.session_id is not null
     and exists (select 1 from session_players s where s.session_id = l.session_id and s.member_id = l.liker_id)
   order by l.created_at desc limit 1
), g as (
  select lk.*, public._game_row(lk.org_id, lk.session_id, lk.liker_id) as row from lk
), pl as (
  select g.target_id, g.liker_id, x from g, jsonb_array_elements(g.row -> 'players') x
), inv as (       -- 最近一筆還沒回的邀請，而且兩人同桌過（才找得到一場可以看）
  select i.org_id, i.inviter_id, i.invitee_id, s1.session_id from buddy_invites i
    join session_players s1 on s1.member_id = i.inviter_id
    join session_players s2 on s2.session_id = s1.session_id and s2.member_id = i.invitee_id
   where i.status = 'pending'
   order by i.created_at desc limit 1
), bud as (       -- 一對同桌過的牌咖
  select s1.org_id, b.member_id, b.buddy_id, s1.session_id from mahjong_buddies b
    join session_players s1 on s1.member_id = b.member_id
    join session_players s2 on s2.session_id = s1.session_id and s2.member_id = b.buddy_id
   where b.deleted_at is null limit 1
)
select concat_ws(E'\n',
  coalesce((select case when (x ->> 'liked_by_me')::boolean then '✅ ① 讚過的那位：liked_by_me = true（' || (x ->> 'nickname') || '）'
                        else '🔴 ① 讚過的那位卻是 ' || coalesce(x ->> 'liked_by_me', 'null') end
              from pl where (x ->> 'member_id')::uuid = pl.target_id), '⚪ ① 找不到讚的樣本，這一格測不了'),
  coalesce((select case when bool_and(not (x ->> 'liked_by_me')::boolean) then '✅ ② 自己那一列 liked_by_me = false（負對照）'
                        else '🔴 ② 自己那一列也變成讚過了' end
              from pl where (x ->> 'member_id')::uuid = pl.liker_id), '⚪ ② 測不了'),
  coalesce((select case when x ->> 'buddy_state' = 'invited' then '✅ ③ 邀請過還沒回的那位：buddy_state = invited'
                        else '🔴 ③ 邀請過的那位是 ' || coalesce(x ->> 'buddy_state', 'null') end
              from inv, jsonb_array_elements(public._game_row(inv.org_id, inv.session_id, inv.inviter_id) -> 'players') x
             where (x ->> 'member_id')::uuid = inv.invitee_id
               and not exists (select 1 from mahjong_buddies b where b.deleted_at is null
                                and ((b.member_id = inv.inviter_id and b.buddy_id = inv.invitee_id)
                                  or (b.member_id = inv.invitee_id and b.buddy_id = inv.inviter_id)))), '⚪ ③ 沒有「同桌過又還沒回」的邀請，這一格測不了'),
  coalesce((select case when x ->> 'buddy_state' = 'buddy' then '✅ ④ 牌咖那位：buddy_state = buddy'
                        else '🔴 ④ 牌咖那位是 ' || coalesce(x ->> 'buddy_state', 'null') end
              from bud, jsonb_array_elements(public._game_row(bud.org_id, bud.session_id, bud.member_id) -> 'players') x
             where (x ->> 'member_id')::uuid = bud.buddy_id), '⚪ ④ 沒有同桌過的牌咖，這一格測不了'),
  coalesce((select case when x ->> 'buddy_state' is null then '✅ ⑤ 自己那一列 buddy_state 是 null'
                        else '🔴 ⑤ 自己那一列 buddy_state = ' || (x ->> 'buddy_state') end
              from pl where (x ->> 'member_id')::uuid = pl.liker_id), '⚪ ⑤ 測不了'),
  -- 頂層 21 個鍵：session_id kind status source store addr game_type flower rounds stake started_at ended_at
  --   duration_minutes my_rank my_score my_charged_points my_fee_waived my_seat my_rating_after settled_at players（這次沒加頂層的）
  coalesce((select case when (select count(*) from jsonb_object_keys(row)) = 21
                         and jsonb_array_length(row -> 'players') > 0
                        then '✅ ⑥ 其他欄位沒動：頂層 21 個鍵、players 有 ' || jsonb_array_length(row -> 'players') || ' 位'
                        else '🔴 ⑥ 頂層鍵數變成 ' || (select count(*) from jsonb_object_keys(row)) end
              from g), '⚪ ⑥ 測不了')
) as "驗證";
