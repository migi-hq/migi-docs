-- ════════════════════════════════════════════════════════════════════
-- 2026-10-09 創辦人段位重來（退出排行榜，下次打完重新定位）
-- ════════════════════════════════════════════════════════════════════
-- 使用者：「把創辦人的積分淨空」→ 選「段位重來＋退出排行榜」
--
-- 會員：手機 0910768736（本狩 岡五郎），在 SQL 裡用手機查，不寫死 id
--
-- 清掉的
--   members         rating 0、rating_games 0（下次重打定位賽）、rank 未定級、best_rank_tier 清空
--   session_players 他那 12 場的 finish_rank／score_points／rating_after／final_score
--                   ⇒ 排行榜只排「有名次」的人，所以他先從榜上消失，打完下一場才回來
--                   ⇒ 成績頁的名次分布、勝率、段位走勢都從零開始
-- 留著的
--   牌局紀錄本身（session_players 列、計分板每一局 hands）、成就 7 枚、頭像、稱號
--   同桌其他人（測試帳號）的名次與積分一律不動
--
-- 觸發器查過（2026-10-09）：
--   · rank 改成 null → trg_members_rank_events 不發任何成就（只在升階時發）
--   · trg_members_best_rank 遇到 null 段位直接放行 ⇒ 這裡明寫 best_rank_tier = null 才清得掉
--     （它決定段位熊頭像解鎖；銅牌熊永遠解鎖，他現在用的就是銅牌熊，不受影響）
--   · 結算通知只在名次「從無到有」時發 ⇒ 清名次不會再發通知
-- ════════════════════════════════════════════════════════════════════

do $$
declare v_id uuid; v_n int;
begin
  select id into v_id from members where phone = '0910768736' and deleted_at is null;
  if v_id is null then
    perform set_config('migi.reset', '🔴 找不到手機 0910768736 的會員，什麼都沒改', true);
    return;
  end if;

  update session_players
     set finish_rank = null, score_points = null, rating_after = null, final_score = null
   where member_id = v_id
     and (finish_rank is not null or score_points is not null or rating_after is not null or final_score is not null);
  get diagnostics v_n = row_count;

  update members
     set rating = 0, rating_games = 0, rank = null, best_rank_tier = null
   where id = v_id;

  perform set_config('migi.reset', '清掉 ' || v_n || ' 場的名次與積分', true);
end $$;

-- ── 驗證（單一 SELECT，不 raise）──────────────────────────────────────
with f as (select id from members where phone = '0910768736' and deleted_at is null),
     o as (select id from orgs order by created_at limit 1)
select concat_ws(E'\n',
  coalesce(nullif(current_setting('migi.reset', true), ''), '⚪ 沒有執行訊息'),
  -- ① 會員本身歸零
  (select case when m.rating = 0 and m.rating_games = 0 and m.rank is null and m.best_rank_tier is null
               then '✅ ① 段位分 0、未定級、定位賽重來'
               else '🔴 ① 還沒歸零：' || m.rating || '／' || coalesce(m.rank, '未定級') || '／' || m.rating_games || ' 場' end
     from members m join f on f.id = m.id),
  -- ② 他的名次與積分全清，但牌局紀錄還在
  (select case when count(*) filter (where sp.finish_rank is not null or sp.final_score is not null or sp.rating_after is not null) = 0
                and count(*) > 0
               then '✅ ② 名次與積分全清，牌局紀錄還在（' || count(*) || ' 列）'
               else '🔴 ② 還有 ' || count(*) filter (where sp.finish_rank is not null) || ' 場有名次' end
     from session_players sp join f on f.id = sp.member_id),
  -- ③ 不在排行榜上（顯示用的那一支）
  (select case when count(*) = 0 then '✅ ③ 已退出排行榜' else '🔴 ③ 還在排行榜上' end
     from o cross join lateral public.season_rank_rows_display_tx(o.id, null, null) r
     join f on f.id = r.member_id),
  -- ④ 正對照：同桌其他人的名次沒被動到
  (select case when count(*) > 0 then '✅ ④ 其他人的名次還在（' || count(*) || ' 筆）'
               else '🔴 ④ 其他人的名次也不見了（清過頭）' end
     from session_players sp
    where sp.finish_rank is not null and sp.member_id not in (select id from f)),
  -- ⑤ 成就保留
  (select '✅ ⑤ 成就保留 ' || count(*) || ' 枚' from member_achievements a join f on f.id = a.member_id)
) as "驗證";
