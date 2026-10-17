-- ============================================================
-- 2026-10-17 傳奇玩家標記 ＋ 牌局詳情回傳
-- MIGI 咪吉麻將
--
-- 起因：使用者「遊戲BOY 是台灣麻將的傳奇人物，在牌局紀錄跟他交手過，要怎麼呈現比較突出」
--   → 選「交手紀念」，先做牌局詳情（個人檔案先不用）。
--
-- ① members.legend_title  總部指定的傳奇頭銜；null ＝ 不是傳奇
--    · 只有總部能設（members 沒有任何給前端的寫入 policy，也沒有 RPC 會寫它）
--    · 一欄同時回答「是不是傳奇」與「頭銜寫什麼」—— 不另外加布林
--    · 目前用 SQL 設；要的人變多再做後台開關
-- ② _game_row 的 players 每人多一個 'legend'（簽名不變，CREATE OR REPLACE ⇒ 授權不會掉）
--    · 被隱藏的會員一律回 null（同 rank 的處理）
-- ③ 遊戲BOY 設成「台灣麻將傳奇」（頭銜文字使用者可改；牌局詳情目前不印頭銜）
--
-- ⚠ 其餘 _game_row 的內容與 2026-10-17 線上版逐字相同（pg_get_functiondef 撈出來的），只多 'legend' 那一行
-- ============================================================

alter table public.members add column if not exists legend_title text;
comment on column public.members.legend_title is
  '總部指定的傳奇玩家頭銜（例：台灣麻將傳奇）；null ＝ 不是傳奇。只由總部設定，前端不可寫。牌局詳情用它畫交手紀念（2026-10-17）';

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
               /* 🆕 2026-10-17：總部指定的傳奇頭銜（牌局詳情畫「傳奇對局」）。被隱藏的人不顯示 */
               'legend',       case when mem.hidden_at is null then mem.legend_title end,
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

-- ③ 遊戲BOY
update public.members
   set legend_title = '台灣麻將傳奇'
 where id = 'dfe22038-ffe1-4561-be05-d9cfa2247d67'
   and legend_title is distinct from '台灣麻將傳奇';

-- ============================================================
-- 驗證（單一 SELECT；不 raise，跑完我會另外查一次線上）
-- 樣本：10-16 遊戲BOY 打的那一場，從同桌「芙芙」的角度看
-- ============================================================
with r as (
  select public._game_row('11111111-1111-1111-1111-111111111111',
                          'a4d8c500-df79-46b1-852f-446ac167b80d',
                          '0949d8d3-295d-42b8-95cb-fd1ebf0d543b') as j
), ps as (
  select x from r, jsonb_array_elements(r.j -> 'players') x
)
select concat_ws(E'\n',
  case when exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'members' and column_name = 'legend_title')
       then '✅ ① members.legend_title 已建立' else '🔴 ① 欄位沒建起來' end,
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = '_game_row') = 1
        and (select pg_get_functiondef(oid) from pg_proc where pronamespace = 'public'::regnamespace and proname = '_game_row') ~ '''legend'','
       then '✅ ② _game_row 只有一個版本，且回傳 legend' else '🔴 ② _game_row 沒換到或有多個版本' end,
  coalesce((select case when legend_title = '台灣麻將傳奇' then '✅ ③ 遊戲BOY 頭銜：' || legend_title
                        else '🔴 ③ 遊戲BOY 頭銜是 ' || coalesce(legend_title, 'null') end
              from public.members where id = 'dfe22038-ffe1-4561-be05-d9cfa2247d67'), '🔴 ③ 找不到遊戲BOY'),
  coalesce((select case when x ->> 'legend' = '台灣麻將傳奇' then '✅ ④ 正對照：牌局詳情裡遊戲BOY 帶 legend'
                        else '🔴 ④ 遊戲BOY 的 legend 是 ' || coalesce(x ->> 'legend', 'null') end
              from ps where x ->> 'member_id' = 'dfe22038-ffe1-4561-be05-d9cfa2247d67'), '⚪ ④ 這一場找不到遊戲BOY'),
  coalesce((select case when count(*) = 3 and count(x ->> 'legend') = 0 then '✅ ⑤ 負對照：同桌其他 3 人 legend 都是 null'
                        else '🔴 ⑤ 其他人：' || count(*) || ' 人，其中 ' || count(x ->> 'legend') || ' 人有 legend' end
              from ps where x ->> 'member_id' <> 'dfe22038-ffe1-4561-be05-d9cfa2247d67'), '⚪ ⑤ 測不了')
) as "驗證";
