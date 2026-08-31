/* ============================================================
   打過一場才有段位（未定位）＋ 段位對照表的讀取
   2026-08-31 · MIGI 咪吉麻將

   ── 🔴 為什麼 ────────────────────────────────────────
   使用者：「應該要打一場，起始分才會 +1000 分。」

   現在**每個新會員一建立就是「銅牌熊 II」** —— 而他一場都沒打過。
   成績頁的 Hero 會理直氣壯地顯示一個他沒有贏來的段位，
   那跟寫死假資料是同一類的謊。

   🎯 **「還沒有段位」是一個真實的狀態，要有辦法表達它。**

   ── 用 `members.rank IS NULL` 表示未定位 ─────────────
   ⚠ **不要用 `rating_games = 0` 當判準** —— 那一欄每季會歸零
     （K 值算的是「這一季打過幾場」）。用它的話，
     打了兩年的老客人每個新賽季都會變回「未定位」，那是錯的。

   ✅ `rank` 只有 `apply_session_rounds_tx` 會寫，而它只在真的結算過才跑。
     ⇒ **`rank IS NULL` 就是「從來沒有打過任何一場計分的牌局」**，
       不需要新欄位，也不會被賽季影響。

   ⚠ `rating` 仍然是 **NOT NULL DEFAULT 1000** —— 它是**起始值**不是段位。
     Elo 從第一場就需要它（對手的期望值要算），拿掉會讓第一場算不出來。
     🎯 差別是：**分數一直都在，但在打過之前不對外顯示成段位。**

   ── 誰讀得懂 null ───────────────────────────────────
   ✅ POS 三處早就寫了 `m.rank && …`（MemberPage / QueuePage / SeatPage）
   ✅ `avatar.js:120` 是 `member.rank ? rankBearSrc(...) : DEFAULT_BEAR`
      —— 未定位自然掉回通用小熊，正好是對的
   🔴 但 `fmtRank(null)` 會回 **`'段位: null'`** —— 兩端各一份，同批修

   ── 順帶：段位對照表要能讀 ──────────────────────────
   使用者要一個抽屜顯示「段位與積分的關係」。
   `rank_tiers` / `rank_points` 兩張表都是 RLS 開著、0 條 policy
   （只被 DEFINER 讀），所以要一支 `list_rank_tiers_tx()` 交出去。
   ⚠ 小級的門檻是**算出來的**（區間平均切四段），不是存的 ——
     這支要把算好的結果一起給，不然前端會再算一次而且一定會漂。
   ============================================================ */

-- ── ① rank 可為 null，預設也是 null ───────────────────
alter table members alter column rank drop not null;
alter table members alter column rank drop default;

comment on column members.rank is
  '段位顯示名（快取）。🔴 NULL = 還沒打過任何一場計分的牌局（未定位）。'
  '只有 apply_session_rounds_tx 會寫它。⚠ 不要用 rating_games 判斷未定位 —— 那一欄每季歸零。';

/* 回填：**沒有任何一場結算過的人**一律設回 null。
   ⚠ 判準用 `session_players.finish_rank`，不是 `rating <> 1000` ——
     有人可能打過但淨得分剛好是 0。 */
update members m
   set rank = null
 where m.deleted_at is null
   and not exists (select 1 from session_players sp
                    where sp.member_id = m.id and sp.finish_rank is not null);


-- ── ② 賽季降階跳過未定位的人 ──────────────────────────
/* 🔴 沒打過的人**不該被降階** —— 他沒有東西可以降，
   而且降完會變成 910，看起來像「他打輸過」。
   ⚠ 也不要順手把他的 rank 算出來 —— 那會讓他在賽季結算那一刻
     莫名其妙「被定位」成銅牌熊。 */
create or replace function public.reset_season_ratings_tx(
  p_org_id uuid,
  p_season text,
  p_drop_tiers integer default 2
) returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_champ uuid; v_rating int; v_n int; v_drop int; v_floor int;
begin
  if exists (select 1 from season_champions where season = p_season) then
    return jsonb_build_object('ok', false, 'reason', 'season_already_closed');
  end if;

  /* 🔴 先記冠軍再降階。順序反了就永遠沒有這一季的雀神。 */
  select m.id, m.rating into v_champ, v_rating
    from members m
   where m.org_id = p_org_id and m.deleted_at is null and not m.is_test
     and m.rank is not null
     and m.rating >= (select min_rating from rank_tiers where code = 'master')
     and public.member_rank_tx(m.id) = (select label from rank_tiers where code = 'master')
   order by m.rating desc, m.rating_games desc
   limit 1;

  insert into season_champions (season, org_id, member_id, rating)
  values (p_season, p_org_id, v_champ, v_rating);

  /* 大階寬度從主檔算，不要寫死 180 —— 每階 45 一定會調。 */
  select coalesce(min(next_min - min_rating), 180) into v_drop
    from (select min_rating, lead(min_rating) over (order by min_rating) as next_min
            from rank_tiers where auto) x
   where next_min is not null;
  v_drop := v_drop * p_drop_tiers;

  select min(min_rating) into v_floor from rank_tiers where auto;

  update members
     set rating       = greatest(v_floor, rating - v_drop),
         rating_games = 0,
         rank         = public.rank_from_rating(greatest(v_floor, rating - v_drop))
   where org_id = p_org_id and deleted_at is null
     and rank is not null;          -- 🔴 未定位的人整列不動
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'season', p_season,
    'champion', v_champ, 'champion_rating', v_rating,
    'dropped', v_drop, 'floor', v_floor, 'affected_members', v_n);
end $$;


-- ── ③ 我的段位：講得出「還沒定位」──────────────────────
create or replace function public.get_my_rank_tx(p_org_id uuid, p_member_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_rating int; v_games int; v_cached text; v_d jsonb;
begin
  select rating, rating_games, rank into v_rating, v_games, v_cached
    from members
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
  if v_rating is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  /* 🔴 未定位：**不要回 rank_detail_tx 的結果**。
     那會回「銅牌熊 II」，而前端只要不小心讀了 `tier` 就又把假段位畫出來。
     → 整組段位欄位都不給，只回 `ranked: false`。
     ⚠ `rating` 也不回 —— 那是內部數字，而且對還沒打過的人沒有意義。 */
  if v_cached is null then
    return jsonb_build_object('ok', true, 'ranked', false, 'games', 0);
  end if;

  v_d := public.rank_detail_tx(v_rating);
  return v_d || jsonb_build_object('ok', true, 'ranked', true,
    'rank', public.member_rank_tx(p_member_id), 'games', v_games);
end $$;


-- ── ④ 段位對照表（抽屜用）──────────────────────────────
/* 使用者要一個抽屜顯示「段位與積分的關係」。
   ⚠ **小級的門檻是算出來的**（把 `[min_rating, 下一階)` 平均切四段），
     所以這支要把算好的結果交出去 —— 讓前端再算一次就是第二個真相來源。
   ⚠ 順位點也一起給：客人問的「段位與積分的關係」其實是兩件事 ——
     ① 幾分是什麼段位　② 打一場拿幾分。少一半答不完整。 */
create or replace function public.list_rank_tiers_tx()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  /* ⚠ `next_min` 要看**全部**的階（不加 `where auto`）——
     鑽石熊的「下一階下限」是大師熊的 1810，那才是它 180 分寬的來源。
     只看 auto 的話鑽石會沒有 next_min，小級要靠 fallback 猜。 */
  with a as (
    select code, label, min_rating, sub_count, auto, band, sort,
           lead(min_rating) over (order by min_rating) as next_min
      from rank_tiers
  )
  select jsonb_build_object(
    'tiers', (
      select jsonb_agg(jsonb_build_object(
        'code', a.code, 'label', a.label, 'band', a.band,
        'min_rating', a.min_rating, 'auto', a.auto,
        /* 小級由低到高：IV / III / II / I */
        'subs', case when a.sub_count <= 1 then '[]'::jsonb else (
          select jsonb_agg(jsonb_build_object(
            'sub', (array['IV','III','II','I'])[g],
            'min', a.min_rating + ((g - 1) *
              ((coalesce(a.next_min, a.min_rating + 180) - a.min_rating) / a.sub_count))
          ) order by g)
          from generate_series(1, a.sub_count) g) end
      ) order by a.sort)
      from a),
    'points', (
      select jsonb_agg(jsonb_build_object('band', band, 'place', place, 'points', points)
               order by case band when 'low' then 1 when 'mid' then 2 else 3 end, place)
        from rank_points)
  );
$$;

grant execute on function public.list_rank_tiers_tx() to anon, authenticated, service_role;


-- ── ⑤ 驗證 ────────────────────────────────────────────
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_out text := ''; v_st uuid; v_tbl uuid; v_store uuid;
  a uuid; b uuid; c uuid; d uuid; r jsonb; j jsonb;
begin
  begin
    ---- 未定位 ------------------------------------------------
    insert into members (org_id, display_name) values (v_org,'測新人') returning id into a;
    v_out := v_out || E'\n' || '① 新會員的 rank 是 null（未定位）' || E'\t' ||
      (select case when rank is null then '✅ null' else '🔴 ' || rank end
         from members where id=a);

    r := public.get_my_rank_tx(v_org, a);
    v_out := v_out || E'\n' || '② get_my_rank_tx 回 ranked=false' || E'\t' ||
      case when (r->>'ranked')::boolean = false then '✅ ranked=false'
           else '🔴 ' || coalesce(r->>'rank','?') end;
    /* 🔴 **未定位時整組段位欄位都不該在** ——
       只要 `tier` 還在，前端不小心讀了就又把假段位畫出來。 */
    v_out := v_out || E'\n' || '③ 未定位時不吐 tier / rating' || E'\t' ||
      case when not (r ? 'tier') and not (r ? 'rating') then '✅ 兩個都沒有'
           else '🔴 還在：' || coalesce(r->>'tier','') || ' / ' || coalesce(r->>'rating','') end;

    /* ⚠ 但 `rating` 欄位本身仍然是 1000（Elo 從第一場就要用它）。 */
    v_out := v_out || E'\n' || '④ 正對照：rating 欄位仍然是 1000' || E'\t' ||
      (select case when rating=1000 then '✅ 1000（起始值一直都在）'
                   else '🔴 ' || rating end from members where id=a);

    ---- 打一場之後就定位了 ------------------------------------
    select id into v_store from stores where org_id=v_org limit 1;
    select id into v_tbl   from tables where org_id=v_org limit 1;
    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
    values (v_org, v_store, v_tbl, 'private', 'completed', now()) returning id into v_st;
    insert into members (org_id, display_name) values (v_org,'測乙') returning id into b;
    insert into members (org_id, display_name) values (v_org,'測丙') returning id into c;
    insert into members (org_id, display_name) values (v_org,'測丁') returning id into d;
    insert into session_players (org_id, session_id, member_id)
      select v_org, v_st, x from unnest(array[a,b,c,d]) x;
    r := public.apply_session_rounds_tx(v_st, (
      select jsonb_agg(jsonb_build_array(
        jsonb_build_object('member_id',a,'finish_rank',1),
        jsonb_build_object('member_id',b,'finish_rank',2),
        jsonb_build_object('member_id',c,'finish_rank',3),
        jsonb_build_object('member_id',d,'finish_rank',4)))
      from generate_series(1,2)));
    v_out := v_out || E'\n' || '⑤ 打完兩將 → 定位（1060 銅牌熊 I）' || E'\t' ||
      (select case when rank='銅牌熊 I' and rating=1060
                   then '✅ 銅牌熊 I · 1060'
                   else '🔴 ' || coalesce(rank,'null') || ' · ' || rating end
         from members where id=a);

    ---- 賽季降階不動未定位的人 --------------------------------
    insert into members (org_id, display_name) values (v_org,'測沒打過') returning id into b;
    r := public.reset_season_ratings_tx(v_org, '_TEST_SEASON2');
    v_out := v_out || E'\n' || '⑥ 賽季降階跳過未定位的人' || E'\t' ||
      (select case when rank is null and rating=1000
                   then '✅ 沒被動到（仍然 null · 1000）'
                   else '🔴 ' || coalesce(rank,'null') || ' · ' || rating end
         from members where id=b);
    /* 🔴 正對照：有定位的人**一定要被降**，不然上面那格用「整支不執行」也會過。 */
    v_out := v_out || E'\n' || '⑦ 正對照：有定位的人 1060 → 夾在 910' || E'\t' ||
      (select case when rating=910 and rank='銅牌熊 IV'
                   then '✅ 910 · 銅牌熊 IV'
                   else '🔴 ' || coalesce(rank,'null') || ' · ' || rating end
         from members where id=a);

    ---- 對照表 ------------------------------------------------
    j := public.list_rank_tiers_tx();
    v_out := v_out || E'\n' || '⑧ 對照表有六階 ＋ 12 條順位點' || E'\t' ||
      case when jsonb_array_length(j->'tiers')=6 and jsonb_array_length(j->'points')=12
           then '✅ 6 / 12'
           else '🔴 ' || jsonb_array_length(j->'tiers') || ' / ' || jsonb_array_length(j->'points') end;
    /* 銅牌的小級由低到高：IV 910 / III 955 / II 1000 / I 1045 */
    v_out := v_out || E'\n' || '⑨ 銅牌的小級：IV 910 … I 1045' || E'\t' ||
      (select case when (s->0->>'sub')='IV' and (s->0->>'min')::int=910
                    and (s->3->>'sub')='I'  and (s->3->>'min')::int=1045
                   then '✅ IV 910 → I 1045'
                   else '🔴 ' || (s->0->>'sub') || ' ' || (s->0->>'min')
                        || ' … ' || (s->3->>'sub') || ' ' || (s->3->>'min') end
         from (select (j->'tiers'->0->'subs') as s) x);
    /* ⚠ 大師熊不分小級 → subs 是空陣列，而且 auto=false 也要在清單裡
       （客人要看得到那個目標）。 */
    v_out := v_out || E'\n' || '⑩ 大師熊在清單裡、無小級、auto=false' || E'\t' ||
      (select case when (t->>'label')='大師熊' and jsonb_array_length(t->'subs')=0
                    and (t->>'auto')::boolean = false
                   then '✅ 在清單裡且標明要認證'
                   else '🔴 ' || coalesce(t->>'label','?') end
         from (select j->'tiers'->5 as t) x);

    v_out := v_out || E'\n' || '⑪ 授權：anon 讀得到對照表' || E'\t' ||
      (select case when count(*)=1 then '✅ 有' else '🔴 沒有' end
         from pg_proc p
        where p.pronamespace='public'::regnamespace and p.proname='list_rank_tiers_tx'
          and exists (select 1 from aclexplode(p.proacl) x
                       where x.grantee='anon'::regrole::oid and x.privilege_type='EXECUTE'));

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.rank4', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.rank4', true), E'\n')) as x
 where coalesce(x,'') <> '';
