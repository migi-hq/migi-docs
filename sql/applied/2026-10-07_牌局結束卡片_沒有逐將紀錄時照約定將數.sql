/* ============================================================
   牌局結束卡片：沒有逐將紀錄時照約定將數（2026-10-07）

   起點：行為測試 sql/checks/2026-10-07_驗牌局結束推播.sql 的 ⓕ 印出
     「玩法：2 將（打完 0 將）」「段位分：未滿 2 將，不計段位分」
   原因：那場的名次是「隨機名次」（placeholder_ranks_tx）給的，**沒有任何 session_rounds**
     ⇒ 數出來打完 0 將。用計分板打的新牌局一定有逐將紀錄，不會這樣；
     但四位都是測試帳號的桌、以及推播測試工具借用的舊牌局都是這一種。

   ✅ 改法：名次已經有、卻一將逐將紀錄都沒有 ⇒ 成績是一次給的（隨機名次照約定將數跑），
     將數就照約定的（planned_rounds），段位分照實際寫進去的數字（score_points）顯示。
   ⚠ 其餘逐字照 2026-10-07_LINE推播_牌局結束.sql 那一版；CREATE OR REPLACE、簽名不變。
   ⚠ 驗證段只有一支 SELECT，不用 raise。
   ============================================================ */

create or replace function public._push_settle_fields(p_notif uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  n app_notifications%rowtype;
  v_sid uuid;
  sp record;
  s record;
  v_done int;
  v_others text;
  v_game text;
begin
  select * into n from app_notifications where id = p_notif;
  if n.id is null or n.type <> 'settle' then return null; end if;
  v_sid := coalesce((n.payload ->> 'session_id')::uuid, n.ref_id);

  select p.finish_rank, p.final_score, p.score_points into sp
    from session_players p
   where p.session_id = v_sid and p.member_id = n.member_id;
  if sp.finish_rank is null then return null; end if;   -- 沒有名次（一將都沒打完）⇒ 不送

  select ts.game_type, ts.flower, ts.planned_rounds,
         st.name as store, t.label as tbl,
         sl.label as stake, coalesce(sl.is_hygiene, false) as hyg,
         m.display_name as my_name, m.rank as my_rank
    into s
    from table_sessions ts
    left join stores       st on st.id = ts.store_id
    left join tables       t  on t.id  = ts.table_id
    left join stake_levels sl on sl.id = ts.stake_level_id
    left join members      m  on m.id  = n.member_id
   where ts.id = v_sid;

  select count(*) into v_done
    from session_rounds where session_id = v_sid and status = 'finished';
  /* 🆕 有名次卻沒有任何逐將紀錄 ⇒ 成績是一次給的（隨機名次），照約定將數算 */
  if v_done = 0 then
    v_done := coalesce(s.planned_rounds, 2);
  end if;

  -- 隱藏的會員名字已經是「隱藏的會員」（隱藏時就換掉了），這裡不用另外判斷
  select string_agg(m.display_name, '、' order by p.seat nulls last) into v_others
    from session_players p join members m on m.id = p.member_id
   where p.session_id = v_sid and p.member_id <> n.member_id;

  -- 玩法：打滿約定將數寫「3 將」；提早收桌寫「3 將（打完 2 將）」；計分桌補上級距，純娛樂不寫（桌上積分那一列已經寫了）
  v_game := concat_ws(' · ', s.game_type, s.flower,
              case when s.planned_rounds is null or v_done >= s.planned_rounds then v_done || ' 將'
                   else s.planned_rounds || ' 將（打完 ' || v_done || ' 將）' end,
              case when not s.hyg and s.stake is not null then '積分 ' || s.stake end);

  return jsonb_build_object(
    'test',    n.payload ->> 'test' = 'true',
    'style',   n.payload ->> 'style',
    'name',    s.my_name,
    'rank_no', sp.finish_rank,
    -- 桌上積分：純娛樂寫「純娛樂」（那一欄是 null 不是 0）
    'score',   case when s.hyg then '純娛樂'
                    when sp.final_score is not null then _push_signed(sp.final_score) end,
    -- 段位分：未滿 2 將不計（2026-10-01 拍板，只打 1 將「有名次沒段位分」）
    'rating',  case when v_done < 2 then '未滿 2 將，不計段位分'
                    when sp.score_points is not null then _push_signed(sp.score_points) end,
    'rating_short', case when v_done >= 2 and sp.score_points is not null then _push_signed(sp.score_points) end,
    'tier',    s.my_rank,
    'place',   coalesce(s.store, 'MIGI') || coalesce(' · ' || s.tbl || ' 桌', ''),
    'game',    nullif(v_game, ''),
    'others',  v_others,
    'url',     'https://liff.line.me/2011312117-Zuul0Ndo?tab=stats');   -- ?tab=stats：App 打開直接到成績頁（migi-web lib/deeplink.js）
end $$;
revoke execute on function public._push_settle_fields(uuid) from public, anon, authenticated;

/* ── 驗證（單一 SELECT）──────────────────────────────────────
   ① 版本數 1、新的那段在程式裡
   ② 借一則「有名次、那場沒有逐將紀錄」的結算通知（舊的隨機名次場次）：不再出現「打完 0 將」
   ③ 借一則「有名次、那場有逐將紀錄」的結算通知（計分板打的）：照實際將數（正對照）
   找不到樣本就印 ⚪，不假裝通過 */
with noround as (
  select n.id from app_notifications n
    join session_players sp on sp.session_id = n.ref_id and sp.member_id = n.member_id and sp.finish_rank is not null
   where n.type = 'settle'
     and not exists (select 1 from session_rounds r where r.session_id = n.ref_id and r.status = 'finished')
   order by n.created_at desc limit 1
), withround as (
  select n.id from app_notifications n
    join session_players sp on sp.session_id = n.ref_id and sp.member_id = n.member_id and sp.finish_rank is not null
   where n.type = 'settle'
     and exists (select 1 from session_rounds r where r.session_id = n.ref_id and r.status = 'finished')
   order by n.created_at desc limit 1
)
select concat_ws(E'\n',
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = '_push_settle_fields') = 1
        and (select pg_get_functiondef(p.oid) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = '_push_settle_fields')
            ~ 'v_done := coalesce\(s\.planned_rounds, 2\)'
       then '✅ ① 版本數 1，「沒有逐將紀錄照約定將數」那段在' else '🔴 ① 函式沒有換到' end,
  coalesce((select case when public._push_settle_fields(noround.id) ->> 'game' !~ '打完 0 將'
                        then '✅ ② 舊的隨機名次場次：' || (public._push_settle_fields(noround.id) ->> 'game')
                             || ' ／ 段位分 ' || coalesce(public._push_settle_fields(noround.id) ->> 'rating', '（沒有）')
                        else '🔴 ② 還是打完 0 將：' || (public._push_settle_fields(noround.id) ->> 'game') end from noround),
           '⚪ ② 線上沒有「沒有逐將紀錄」的結算通知可以試'),
  coalesce((select '✅ ③ 計分板打的場次照實際將數：' || (public._push_settle_fields(withround.id) ->> 'game')
                   || ' ／ 段位分 ' || coalesce(public._push_settle_fields(withround.id) ->> 'rating', '（沒有）') from withround),
           '⚪ ③ 線上沒有「有逐將紀錄」的結算通知可以試')
) as "驗證";
