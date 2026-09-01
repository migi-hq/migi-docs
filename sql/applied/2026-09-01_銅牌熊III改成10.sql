/* ============================================================
   銅牌熊 III 從 5 分改成 10 分　2026-09-01 · MIGI

   使用者當天稍後更正。連帶「III 之後每小階 45」的規則要保持一致
   ⇒ 銅牌熊變 0/10/55/100，大階寬 145 ⇒ **後面每一個大階邊界都 +5**。

   ```
   銅牌熊    0 ·  10 ·  55 · 100      ← 間距 10 / 45 / 45
   銀牌熊  145 · 190 · 235 · 280
   金牌熊  325 · 370 · 415 · 460
   白金熊  505 · 550 · 595 · 640
   鑽石熊  685 · 730 · 775 · 820
   大師熊  865 以上
   ```

   ── 🔴 10 分正好是保證的下限，零餘裕 ──────────────
   ```
   定位賽第 4 名 +5　×　最少 2 將（未滿 2 將不計）　=　剛好 10 分
   ```
   ⇒ **「任何人打完第一場都會升到 III」還是成立，但剛好踩線。**
   🔴 **這個數字改成 11 就會失效**，而且**不會有任何錯誤** ——
     只是新客人第一場打完什麼都沒發生。
   → 所以下面的驗證段真的跑一次定位賽，不是只比對數字。

   ── ✅ 為什麼只要改兩張主檔 ────────────────────────
   `rank_detail_tx` / `list_rank_tiers_tx` / `reset_season_ratings_tx`
   **全部都是從主檔算的**，一支函式都不用動 ——
   那正是 2026-09-01 把小階門檻從「程式裡的除法」改成「資料」的收益，
   今天就兌現了。
   ⚠ 前端也一樣：大師熊那格已經改讀 `x.min_rating`，
     不會再出現「表都變了只有那一格沒變」。
     **唯一要改的是教學頁那個舉例的數字**（那是文案不是資料）。
   ============================================================ */

update public.rank_tiers set min_rating = v.m
  from (values ('bronze',0),('silver',145),('gold',325),
               ('platinum',505),('diamond',685),('master',865)) as v(c,m)
 where rank_tiers.code = v.c;

/* 銅牌熊：0 / 10 / 55 / 100（間距 10 / 45 / 45）
   ⚠ 其餘五階的位移是 0/45/90/135，**不動** —— 它們的絕對值
     跟著大階下限一起平移了 5 分，那是「存位移不存絕對值」的好處。 */
update public.rank_sub_levels set offset_pts = v.o
  from (values ('IV',0),('III',10),('II',55),('I',100)) as v(s,o)
 where rank_sub_levels.tier_code = 'bronze' and rank_sub_levels.sub = v.s;


-- ── 驗證 ───────────────────────────────────────────────
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_out text := ''; v_st uuid; v_tbl uuid; v_store uuid;
  a uuid; b uuid; c uuid; e uuid;
begin
  begin
    v_out := v_out || E'\n' || '① 六個大階下限' || E'\t' ||
      (select case when string_agg(min_rating::text, '/' order by sort) = '0/145/325/505/685/865'
                   then '✅ 0/145/325/505/685/865'
                   else '🔴 ' || string_agg(min_rating::text, '/' order by sort) end
         from rank_tiers);

    v_out := v_out || E'\n' || '② 銅牌熊 = 0/10/55/100' || E'\t' ||
      (select case when string_agg((t.min_rating + s.offset_pts)::text, '/' order by s.sort) = '0/10/55/100'
                   then '✅ 間距 10/45/45'
                   else '🔴 ' || string_agg((t.min_rating + s.offset_pts)::text, '/' order by s.sort) end
         from rank_sub_levels s join rank_tiers t on t.code = s.tier_code
        where s.tier_code = 'bronze');

    /* 🔴 **正對照**：其餘五階必須整組平移 5 分且維持 45 間距。
       只驗銅牌的話，一個「只改銅牌、大階下限忘了改」的錯誤照樣會綠。 */
    v_out := v_out || E'\n' || '③ 正對照：銀牌熊 = 145/190/235/280' || E'\t' ||
      (select case when string_agg((t.min_rating + s.offset_pts)::text, '/' order by s.sort) = '145/190/235/280'
                   then '✅ 每階 45'
                   else '🔴 ' || string_agg((t.min_rating + s.offset_pts)::text, '/' order by s.sort) end
         from rank_sub_levels s join rank_tiers t on t.code = s.tier_code
        where s.tier_code = 'silver');
    v_out := v_out || E'\n' || '④ 正對照：鑽石熊 = 685/730/775/820' || E'\t' ||
      (select case when string_agg((t.min_rating + s.offset_pts)::text, '/' order by s.sort) = '685/730/775/820'
                   then '✅ 每階 45'
                   else '🔴 ' || string_agg((t.min_rating + s.offset_pts)::text, '/' order by s.sort) end
         from rank_sub_levels s join rank_tiers t on t.code = s.tier_code
        where s.tier_code = 'diamond');

    ---- 分界 --------------------------------------------
    v_out := v_out || E'\n' || '⑤ 分界：9→IV　10→III　54→III　55→II' || E'\t' ||
      case when public.rank_from_rating(9)  = '銅牌熊 IV'
            and public.rank_from_rating(10) = '銅牌熊 III'
            and public.rank_from_rating(54) = '銅牌熊 III'
            and public.rank_from_rating(55) = '銅牌熊 II'
           then '✅ 四個邊界都對'
           else '🔴 ' || public.rank_from_rating(9) || '／' || public.rank_from_rating(10)
                || '／' || public.rank_from_rating(54) || '／' || public.rank_from_rating(55) end;
    v_out := v_out || E'\n' || '⑥ 正對照：144→銅I　145→銀IV　864→鑽I' || E'\t' ||
      case when public.rank_from_rating(144) = '銅牌熊 I'
            and public.rank_from_rating(145) = '銀牌熊 IV'
            and public.rank_from_rating(864) = '鑽石熊 I'
           then '✅ 三個都對'
           else '🔴 ' || public.rank_from_rating(144) || '／' || public.rank_from_rating(145)
                || '／' || public.rank_from_rating(864) end;

    ---- 🎯 真的跑一次定位賽（這一格才是重點）------------
    /* 🔴 **不要只比對數字。** 10 分是保證的下限、零餘裕 ——
       要證明它成立，只有真的讓四個人打一場最少的 2 將。 */
    select id into v_store from stores where org_id = v_org limit 1;
    select id into v_tbl   from tables where org_id = v_org limit 1;
    insert into members (org_id, display_name) values (v_org,'測甲') returning id into a;
    insert into members (org_id, display_name) values (v_org,'測乙') returning id into b;
    insert into members (org_id, display_name) values (v_org,'測丙') returning id into c;
    insert into members (org_id, display_name) values (v_org,'測丁') returning id into e;
    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
      values (v_org, v_store, v_tbl, 'private', 'completed', now()) returning id into v_st;
    insert into session_players (org_id, session_id, member_id)
      select v_org, v_st, x from unnest(array[a,b,c,e]) x;
    perform public.apply_session_rounds_tx(v_st, (
      select jsonb_agg(jsonb_build_array(
        jsonb_build_object('member_id',a,'finish_rank',1),
        jsonb_build_object('member_id',b,'finish_rank',2),
        jsonb_build_object('member_id',c,'finish_rank',3),
        jsonb_build_object('member_id',e,'finish_rank',4)))
      from generate_series(1,2)));

    v_out := v_out || E'\n' || '⑦ 定位賽（2 將，最少）四個人' || E'\t' ||
      (select string_agg(m.display_name || ' ' || m.rating || '分 ' || m.rank, '　' order by m.display_name)
         from members m where m.id in (a,b,c,e));
    v_out := v_out || E'\n' || '⑧ 🎯 兩將都墊底 = 剛好 10 分 = 銅牌熊 III' || E'\t' ||
      (select case when m.rating = 10 and m.rank = '銅牌熊 III'
                   then '✅ 踩線成功（門檻再高 1 分就失效）'
                   else '🔴 ' || m.rating || ' 分 ' || coalesce(m.rank,'null') end
         from members m where m.id = e);

    /* 🔴 **正對照：進度條要是 0%。** 他剛踏上 III，還沒往前走 ——
       如果這裡不是 0，代表門檻與計分對不齊。 */
    v_out := v_out || E'\n' || '⑨ 正對照：10 分在 III 的進度 = 0%，距 II 還有 45' || E'\t' ||
      (select case when (d->>'progress')::int = 0 and (d->>'to_next')::int = 45
                   then '✅ 0% ／ 還有 45'
                   else '🔴 progress=' || (d->>'progress') || ' to_next=' || (d->>'to_next') end
         from (select public.rank_detail_tx(10) as d) x);

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.b3', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.b3', true), E'\n')) as x
 where coalesce(x,'') <> '';
