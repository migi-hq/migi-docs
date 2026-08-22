-- 【這是什麼】給最近一場已收桌的場次隨機灌上名次與得分，讓 App 成績頁能測到「已結算」狀態。
-- 【何時用】走完「開桌 → 結帳 → 收桌」之後，想看成績頁的完整樣子時。
--
-- ⚠ 這是**測試工具**，不是功能。M4 結算上線後由系統寫這兩個欄位，這支就該刪掉。
--
-- ⚠ 刻意走真實欄位（session_players.finish_rank / score_points），
--   不是在前端塞假資料。這樣才驗得到整條路徑：
--     get_my_games_tx → status 從 pending 變 settled
--     → SeatRow 出現名次角標（第一名桃紅）與得分行
--     → MatchRow 從「等 · 已收桌」變成「勝/負 · 第 N 名」
--   前端塞假的只會驗到「假資料長怎樣」，那正是這批剛清掉的東西。
--
-- ⚠ 每次跑都會**重新隨機**，所以可以連跑幾次看不同名次的樣子。

do $do$
declare
  v_sid   uuid;
  v_n     int;
  v_who   text;
begin
  -- 最近一場已收桌、而且有人入座的場次
  select s.id into v_sid
    from table_sessions s
   where s.status = 'completed' and s.deleted_at is null
     and exists (select 1 from session_players p where p.session_id = s.id)
   order by s.ended_at desc nulls last
   limit 1;

  if v_sid is null then
    raise exception '找不到已收桌且有入座者的場次。'
                    '⚠ 只有「結帳」過的人才會進 session_players —— '
                    '如果你跳過結帳直接收桌，那場是沒有人的。';
  end if;

  select count(*) into v_n from session_players where session_id = v_sid;

  /* 名次隨機、得分依名次線性分佈且總和為 0。
     四人時是 +120 / +40 / −40 / −120 —— 麻將是零和，
     總和不為 0 的假資料之後做報表時會很難看出哪裡不對。 */
  with ranked as (
    select id, row_number() over (order by random()) as rk
      from session_players where session_id = v_sid
  )
  update session_players p
     set finish_rank  = r.rk,
         score_points = round(((v_n + 1) / 2.0 - r.rk) * 80)::int,
         settled_at   = now()
    from ranked r
   where p.id = r.id;

  select string_agg(m.display_name || ' 第' || p.finish_rank || '名 ' ||
                    case when p.score_points > 0 then '+' else '' end || p.score_points,
                    '、' order by p.finish_rank)
    into v_who
    from session_players p join members m on m.id = p.member_id
   where p.session_id = v_sid;

  raise notice '已灌入 % 人的戰績：%', v_n, v_who;
end $do$;

-- ── 驗證（單一 SELECT）────────────────────────────────────────
select 項目, 結果
from (
  select 1 as ord, '灌到哪一場' as 項目,
    coalesce((select s.id::text || '　收桌於 ' || (s.ended_at at time zone 'Asia/Taipei')::text
                from table_sessions s
               where s.status = 'completed' and s.deleted_at is null
                 and exists (select 1 from session_players p where p.session_id = s.id)
               order by s.ended_at desc nulls last limit 1), '（沒有）') as 結果

  union all select 2, '戰績明細',
    coalesce((select string_agg(
                '第' || p.finish_rank || '名　' || m.display_name || '　' ||
                case when p.score_points > 0 then '+' else '' end || p.score_points ||
                '　狀態=' || coalesce(p.status, 'null'),
                chr(10) order by p.finish_rank)
                from session_players p join members m on m.id = p.member_id
               where p.session_id = (select s.id from table_sessions s
                                      where s.status = 'completed' and s.deleted_at is null
                                        and exists (select 1 from session_players x where x.session_id = s.id)
                                      order by s.ended_at desc nulls last limit 1)), '（沒有）')

  union all select 3, '得分總和（應為 0）',
    coalesce((select sum(p.score_points)::text
                from session_players p
               where p.session_id = (select s.id from table_sessions s
                                      where s.status = 'completed' and s.deleted_at is null
                                        and exists (select 1 from session_players x where x.session_id = s.id)
                                      order by s.ended_at desc nulls last limit 1)), '（沒有）')

  -- 這才是真正要驗的：App 那支 RPC 現在回什麼
  union all select 10, '測試帳號的 get_my_games_tx 狀態',
    coalesce((select string_agg(m.display_name || ' → ' ||
                coalesce((get_my_games_tx('11111111-1111-1111-1111-111111111111'::uuid, m.id) -> 0 ->> 'status'), '無紀錄') ||
                '　名次=' || coalesce((get_my_games_tx('11111111-1111-1111-1111-111111111111'::uuid, m.id) -> 0 ->> 'my_rank'), '-') ||
                '　得分=' || coalesce((get_my_games_tx('11111111-1111-1111-1111-111111111111'::uuid, m.id) -> 0 ->> 'my_score'), '-'),
                chr(10) order by m.display_name)
                from members m
               where m.org_id = '11111111-1111-1111-1111-111111111111'
                 and m.is_test = true and m.deleted_at is null), '（沒有測試帳號）')
) x
order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
-- 第 3 項不是 0 → 得分算錯了，報表會歪。
-- 第 10 項的 status 應該從 pending 變成 **settled**，名次與得分都有值。
--   還是 pending 的話代表 my_rank 沒寫進去，去看第 2 項是不是真的更新了。
--
-- 打開 App 成績頁應該看到：
--   · 列表那一列從「等 · 已收桌」變成「勝／負 · 第 N 名 · 積分」，右邊出現 +120 / −40
--   · 點進去「本局戰績」四個座位有名次角標（第一名桃紅底白字）與得分行
--
-- ── 要清掉重來 ───────────────────────────────────────────────
-- update session_players set finish_rank = null, score_points = null, settled_at = null
--  where session_id = (select s.id from table_sessions s
--                       where s.status = 'completed' and s.deleted_at is null
--                       order by s.ended_at desc nulls last limit 1);
