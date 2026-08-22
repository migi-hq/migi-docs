-- 【這是什麼】唯讀盤點：App 顯示「我要配桌」（閒置）卻被擋「你已報名固定牌局」，
--   以及「歷史配桌紀錄」是空的。
-- 【何時讀】2026-08-22 實機出現這兩個現象時。
--
-- ═══ 現象 ═══
--   · 配桌頁顯示閒置狀態（我要配桌 / 開始配桌），代表 get_my_active_queue_tx 回 null
--   · 但按下去被 _check_join_conflict 擋：「你已報名固定牌局，同時只能參加一場」
--   → **前端說你沒有房、後端說你有。** 客人會看到一個他在畫面上完全找不到的東西擋住他。
--
-- 推測：get_my_active_queue_tx 只回 status='waiting'，
--       而那場已經 matched（2026-08-25 週二 20:00 那筆）。
--       _check_join_conflict 則把 matched 也算進去。
--
--   · 「歷史配桌紀錄」空的 —— get_my_games_tx 實測回 1 筆給測試01，畫面卻是空的。
--     最可能是登入的不是測試01（四個人都坐過那場，理論上都看得到）。

select 項目, 結果
from (
  -- ── 一、兩支函式各自認哪些狀態 ─────────────────────────────
  select 1 as ord, 'get_my_active_queue_tx 全文' as 項目,
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='get_my_active_queue_tx' limit 1),
             '（不存在）') as 結果

  union all select 2, '_check_join_conflict 全文',
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='_check_join_conflict' limit 1),
             '（不存在）')

  -- ── 二、誰在哪一場房裡 ─────────────────────────────────────
  union all select 10, '每個測試帳號目前掛在哪些房（不分狀態）',
    coalesce((select string_agg(line, chr(10) order by line)
                from (select m.display_name || ' → [' || q.status || '/' || q.source || '] '
                             || (q.play_at at time zone 'Asia/Taipei')::text
                             || case when p.left_at is null then '' else '（已離開）' end as line
                        from match_queue_players p
                        join match_queues q on q.id = p.queue_id
                        join members m on m.id = p.member_id
                       where q.status <> 'expired') t),
             '（沒有人掛在任何非過期的房裡）')

  union all select 11, '各狀態的房數',
    coalesce((select string_agg(status || ' = ' || n, '   ' order by status)
                from (select status, count(*) n from match_queues group by status) t), '（無）')

  -- ── 三、歷史紀錄：四個測試帳號各自看得到幾筆 ───────────────
  union all select 20, '各測試帳號 get_my_games_tx 回傳筆數',
    coalesce((select string_agg(m.display_name || ' → ' ||
                jsonb_array_length(get_my_games_tx('11111111-1111-1111-1111-111111111111'::uuid, m.id)),
                '   ' order by m.display_name)
                from members m
               where m.org_id = '11111111-1111-1111-1111-111111111111'
                 and m.deleted_at is null), '（沒有會員）')

  union all select 21, '會員 id 對照（跟 localStorage 的 migi_member.id 比對）',
    coalesce((select string_agg(display_name || ' = ' || id::text, chr(10) order by display_name)
                from members
               where org_id = '11111111-1111-1111-1111-111111111111' and deleted_at is null), '（無）')

  -- ── 四、那場已收桌的場次到底是誰坐的 ───────────────────────
  union all select 30, '已收桌場次的入座者',
    coalesce((select string_agg(m.display_name, '、' order by m.display_name)
                from session_players sp
                join members m on m.id = sp.member_id
                join table_sessions s on s.id = sp.session_id
               where s.status = 'completed' and s.deleted_at is null), '（沒有已收桌的場次）')

  union all select 40, '現在時間（台北）',
    (now() at time zone 'Asia/Taipei')::text
) x
order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
-- 第 1 項：看 where 有沒有 status='waiting'。若有 → 確認推測，matched 的房查不到。
--   ⚠ 這不是「補一個狀態就好」的修法，要先決定：成桌之後配桌頁該顯示什麼？
--     現在的 ActiveZone 有 waiting / matched 兩態，matched 那態本來就存在，
--     只是拿不到資料。所以修的是查詢範圍，不是畫面。
-- 第 2 項：看它算哪些狀態。若把 matched 也算進去而 get_my_active 不回 matched，
--   兩支對「你有沒有在排隊」的定義就不一致 —— 那是這個 bug 的根。
-- 第 10 項：直接看得出你登入的帳號掛在哪一場。
-- 第 20 項：若四個帳號都回 1，代表 RPC 正常，畫面空是因為登入的是別的帳號；
--   若全部回 0，才是 RPC 有問題。
-- 第 21 項：拿去跟瀏覽器 localStorage 的 migi_member.id 比對，確認現在登入的是誰。
