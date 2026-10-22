/* ============================================================
   2026-10-22 牌風問卷結果：「◯◯型法家」改成「◯◯型玩家」
   ------------------------------------------------------------
   · 「法家」是寫錯字（使用者 10-22 確認），前端已改（migi-web profile.jsx）
   · 結果存在 members.style（jsonb，鍵 type），執行前實查：
       社交型法家 2、謀略型法家 2、速攻型法家 2，共 6 位；member_hidden 0 位
   · 後端沒有任何函式寫死這幾個名字（掃過 pg_get_functiondef），只改資料
   · member_hidden 也一起改（隱藏中的會員恢復時會把 style 搬回來）
   · 可重複執行：第二次跑時找不到舊名稱，0 列
   ============================================================ */

update public.members
   set style = jsonb_set(style, '{type}', to_jsonb(replace(style->>'type', '型法家', '型玩家')))
 where style->>'type' like '%型法家';

update public.member_hidden
   set style = jsonb_set(style, '{type}', to_jsonb(replace(style->>'type', '型法家', '型玩家')))
 where style->>'type' like '%型法家';

/* ── 驗證（單一 SELECT）── */
select
  case when (select count(*) from public.members where style->>'type' like '%法家%') = 0
        and (select count(*) from public.member_hidden where style->>'type' like '%法家%') = 0
       then '✅ 已經沒有「法家」'
       else '🔴 還有 ' || ((select count(*) from public.members where style->>'type' like '%法家%')
                         + (select count(*) from public.member_hidden where style->>'type' like '%法家%'))::text || ' 筆是舊名稱' end
  || E'\n' ||
  coalesce((select '型玩家：' || string_agg(t || ' ' || n, '、' order by t)
              from (select style->>'type' t, count(*) n from public.members
                     where style->>'type' like '%型玩家' group by 1) s),
           '🔴 一筆型玩家都沒有（期望 6 筆：社交 2、謀略 2、速攻 2）') as "驗證";
