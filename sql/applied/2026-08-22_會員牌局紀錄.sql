-- 【這是什麼】get_my_games_tx：會員 App 的牌局紀錄（我打過哪些局）。
-- 【何時讀】執行前。欄位盤點見 sql/checks/查牌局紀錄可用欄位.sql（2026-08-22 已跑）。
--
-- ═══ 為什麼要做 ═══
--
-- 成績頁 100% 吃 DEMO_MATCHES 假資料 —— migi-web/src/lib/social.js 裡
-- **一支讀取牌局紀錄的函式都沒有**，那一頁從來沒跟後端要過資料。
-- 而 POS 收桌（settle_session_tx）已經把 table_sessions 設成 completed、
-- 寫了 ended_at 與 session_players.left_at，資料早就在那裡沒人讀。
--
-- 這是 get_my_orders_tx（消費明細）的同一個形狀：同一批事實表的另一種切法。
--
-- ═══ 這一版做什麼、不做什麼 ═══
--
-- 做：我坐過哪些已收桌的局、在哪間店、什麼玩法／積分級距、打了多久、同桌是誰。
-- 不做：戰績。session_players.finish_rank / score_points 欄位存在但全部是 null
--       （盤點：0 筆有值），那是 M4 結算的範圍。
--       這裡照樣回傳這兩個欄位，M4 上線後前端不用改。
--
-- ⚠ 只回 status='completed' 的場次：
--   · 'open' 是進行中 —— 配桌頁已經在顯示，而且前端的 RecordDetailSheet
--     沒有「進行中」這個狀態，混進去會被當成 settled 渲染
--   · 'voided' 是開錯桌取消 —— 客人根本沒打，不該出現在紀錄裡
--     （void_session_tx 有在座玩家就拒絕，所以 voided 場次本來就沒有 session_players，
--      join 之後自然不會出現。這裡明寫是為了表達意圖）
--
-- ⚠ 存取控制：SECURITY DEFINER + 前端傳 p_member_id，與其餘會員端 RPC 一致。
--   知道任何會員 uuid 就能查他打過哪些局、在哪間店、跟誰打。
--   這是 CLAUDE.md 待辦 14（LIFF 換 JWT）的範圍，整批一起解，不在這裡開特例。

-- ============================================================
-- 一、前置檢查：確認每個要用的欄位都存在
-- ============================================================
-- CREATE FUNCTION 不檢查函式體裡的欄位是否存在（硬規則 7 的成因），
-- 所以先自己比對。stores 的欄位這次沒盤點過，尤其要驗。
do $do$
declare v_missing text;
begin
  select string_agg(need.t || '.' || need.c, '、' order by need.t, need.c)
    into v_missing
    from (values
      ('table_sessions', 'id'), ('table_sessions', 'org_id'), ('table_sessions', 'store_id'),
      ('table_sessions', 'mode'), ('table_sessions', 'stake_level_id'), ('table_sessions', 'status'),
      ('table_sessions', 'started_at'), ('table_sessions', 'activated_at'), ('table_sessions', 'ended_at'),
      ('table_sessions', 'game_type'), ('table_sessions', 'flower'), ('table_sessions', 'planned_rounds'),
      ('table_sessions', 'deleted_at'),
      ('session_players', 'session_id'), ('session_players', 'member_id'), ('session_players', 'org_id'),
      ('session_players', 'seat'), ('session_players', 'finish_rank'), ('session_players', 'score_points'),
      ('session_players', 'charged_points'), ('session_players', 'fee_waived_amount'),
      ('session_players', 'joined_at'),
      ('stake_levels', 'id'), ('stake_levels', 'org_id'), ('stake_levels', 'label'),
      ('members', 'id'), ('members', 'display_name'), ('members', 'rank'), ('members', 'title'),
      ('stores', 'id'), ('stores', 'org_id'), ('stores', 'name'), ('stores', 'address')
    ) as need(t, c)
   where not exists (
     select 1 from information_schema.columns
      where table_schema = 'public'
        and table_name = need.t
        and column_name = need.c);

  if v_missing is not null then
    raise exception '缺這些欄位，整支中止：%。請先確認實際名稱再改函式（硬規則 3）。', v_missing;
  end if;
end $do$;

-- ============================================================
-- 二、RPC
-- ============================================================
-- 新函式，線上不存在（盤點確認），不需要 DROP。
create or replace function get_my_games_tx(
  p_org_id    uuid,
  p_member_id uuid,
  p_limit     int default 20
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with mine as (
    -- 從「我坐過的位子」反查場次 —— 不需要知道那桌是怎麼開的。
    -- （配桌與開桌的關聯在 match_queues.matched_session_id，這裡用不到）
    select s.id, s.mode, s.store_id, s.stake_level_id,
           s.game_type, s.flower, s.planned_rounds,
           s.started_at, s.activated_at, s.ended_at,
           sp.finish_rank      as my_rank,
           sp.score_points     as my_score,
           sp.charged_points   as my_charged,
           sp.fee_waived_amount as my_waived,
           sp.seat             as my_seat
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
      -- （M4 之前全部都是 pending，那是預期的）
      'status', case when m.my_rank is not null then 'settled' else 'pending' end,
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
      'players', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'member_id',    p.member_id,
                 'nickname',     mem.display_name,
                 'rank',         mem.rank,
                 'title',        mem.title,
                 'seat',         p.seat,
                 'finish_rank',  p.finish_rank,
                 'score_points', p.score_points,
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
$$;

comment on function get_my_games_tx(uuid, uuid, int) is
  '會員 App 牌局紀錄：我坐過的已收桌場次。戰績欄位（finish_rank/score_points）在 M4 之前恆為 null。';

grant execute on function get_my_games_tx(uuid, uuid, int) to anon, authenticated;

-- ============================================================
-- 三、驗證（單一 SELECT）—— 硬規則 7：必須實際執行並看到回傳
-- ============================================================
-- 用盤點查到的實際資料：測試01（d73fdac2…）坐過那場已收桌的 bb767957…
select 項目, 結果
from (
  select 1 as ord, '函式版本數（應為 1）' as 項目,
    (select count(*)::text from pg_proc
      where pronamespace = 'public'::regnamespace and proname = 'get_my_games_tx') as 結果

  union all select 2, '是否 SECURITY DEFINER',
    (select case when prosecdef then '✅ 是' else '❌ 否 —— anon 會被 RLS 濾成空的' end
       from pg_proc where pronamespace = 'public'::regnamespace
        and proname = 'get_my_games_tx' limit 1)

  union all select 3, '實際執行：測試01 有幾筆紀錄',
    (select jsonb_array_length(get_my_games_tx(
       '11111111-1111-1111-1111-111111111111',
       'd73fdac2-d6b9-4b8a-bcff-b19c2786056f'))::text)

  union all select 4, '第一筆：門市 / 類型 / 狀態',
    (select coalesce(
       (g->0->>'store') || ' / ' || (g->0->>'kind') || ' / ' || (g->0->>'status'),
       '（沒有紀錄）')
       from (select get_my_games_tx(
               '11111111-1111-1111-1111-111111111111',
               'd73fdac2-d6b9-4b8a-bcff-b19c2786056f') as g) t)

  union all select 5, '第一筆：玩法 / 級距 / 幾將 / 打多久（分）',
    (select coalesce(
         coalesce(g->0->>'game_type', '?') || ' ' || coalesce(g->0->>'flower', '?')
      || ' / ' || coalesce(g->0->>'stake', '(無級距)')
      || ' / ' || coalesce(g->0->>'rounds', '?')
      || ' / ' || coalesce(g->0->>'duration_minutes', '?'), '（沒有紀錄）')
       from (select get_my_games_tx(
               '11111111-1111-1111-1111-111111111111',
               'd73fdac2-d6b9-4b8a-bcff-b19c2786056f') as g) t)

  union all select 6, '第一筆：同桌幾個人 / 都是誰',
    (select coalesce(
         jsonb_array_length(g->0->'players')::text || ' 人：'
      || (select string_agg((p->>'nickname') || case when (p->>'is_me')::bool then '(我)' else '' end, '、')
            from jsonb_array_elements(g->0->'players') p), '（沒有紀錄）')
       from (select get_my_games_tx(
               '11111111-1111-1111-1111-111111111111',
               'd73fdac2-d6b9-4b8a-bcff-b19c2786056f') as g) t)

  union all select 7, '戰績欄位（M4 之前應為 null）',
    (select coalesce('my_rank=' || coalesce(g->0->>'my_rank', 'null')
                  || ' / my_score=' || coalesce(g->0->>'my_score', 'null'), '（沒有紀錄）')
       from (select get_my_games_tx(
               '11111111-1111-1111-1111-111111111111',
               'd73fdac2-d6b9-4b8a-bcff-b19c2786056f') as g) t)

  union all select 8, '沒坐過任何桌的會員應回空陣列（不是 null）',
    (get_my_games_tx('11111111-1111-1111-1111-111111111111',
                     '00000000-0000-0000-0000-000000000000'))::text
) x
order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
-- 項目 3 應為 1（盤點時：一場已收桌、四個入座者，測試01 是其中之一）。
--   若為 0 → 那場的 org_id 或 member_id 對不上，撈出來看。
-- 項目 4 store 若是空的 → stores 的 name 欄位名稱不同（前置檢查應該已經擋下）。
-- 項目 5 stake 若是「(無級距)」→ 那場開桌時沒帶 stake_level_id，是資料問題不是函式問題。
-- 項目 6 應為 4 人，且其中一個帶「(我)」。
-- 項目 7 應為兩個 null —— 這是對的，M4 結算還沒做。
-- 項目 8 應為 []，不是 null。前端拿到 null 會在 .map 上炸掉。
