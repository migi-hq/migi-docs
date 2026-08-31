/* ============================================================
   `rank_seasons`：讓「賽季」有定義　2026-09-01 · MIGI

   ── 為什麼 ──────────────────────────────────────────
   🔴 **今天「賽季」只有結果沒有定義。**
     `season_champions` 記著誰拿冠軍，但**沒有任何地方說一季從哪天到哪天**，
     而 `reset_season_ratings_tx(p_org_id, p_season text, …)` 的季別
     是**呼叫端隨手打的字串** —— 打錯不會有人知道。

   於是三個地方各自用不同的近似值去猜它：
   | 誰在猜 | 猜成什麼 |
   |---|---|
   | 成績頁 Hero 的賽季膠囊 | **寫死**「2026 春季賽 · 倒數 23 天」 |
   | 段位走勢圖的範圍 | 「最近 20 場」 |
   | 大師熊的對手多樣性 | 「最近 50 場」（拍板的字面是「**本季**」） |

   📌 **同一個名字三種意思** —— 同 CLAUDE.md 待辦 35 記的那個病
     （前三次：`wallet_txns.type` 一欄兩義、`staff.role` 一欄兩維度、
     `players` 一個 key 兩種形狀）。這是第四次。

   ── 這份做什麼 ──────────────────────────────────────
   ① `rank_seasons` 表（起訖日）＋ **不可重疊**的排除約束
   ② `season_champions` 的 PK 補上 org，並外鍵指向 ①
   ③ `current_season_tx` / `rating_window_start_tx` 兩支內部函式
   ④ `member_rank_tx` 的多樣性視窗換成「上次歸零之後」
   ⑤ `get_my_rank_tx` 回傳 `season` 區塊（給 Hero 的倒數用）
   ⑥ `reset_season_ratings_tx` 拒絕不存在的季別

   ⚠ **不做結算排程。** 先有起訖日，倒數與「本季」立刻能算 ——
     自動關季是另一件事（而且沒有人在看告警，硬規則 5.5）。
   ============================================================ */

-- ① ───────────────────────────────────────────────────────
/* 🔴 **排除約束需要 btree_gist**（要把 `org_id WITH =` 和範圍放同一個索引）。
   gist 原生只認範圍型別，等值比較要靠這個 contrib。 */
create extension if not exists btree_gist;

create table if not exists public.rank_seasons (
  code       text        not null,
  org_id     uuid        not null references public.orgs(id),
  label      text        not null,          -- 客人看到的名字，例如「2026 秋季賽」
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,          -- 🔴 **不含**（半開區間 [starts, ends)）
  created_at timestamptz not null default now(),
  primary key (org_id, code),
  constraint rank_seasons_range_chk check (ends_at > starts_at),
  /* 🔴 **這條約束才是這張表的重點。**
     兩季重疊 = 「現在是第幾季」有兩個答案 —— 那正是這份 SQL 要消滅的東西。
     ⚠ 寫成規則靠人記是沒有用的（`uq_buddy_pair` 就是這樣長出第二個索引的）；
       **讓它插不進去**才是機制。
     ⚠ 上界不含，所以 07-01 結束、07-01 開始的兩季**不算重疊**（`&&` 對半開區間） */
  constraint rank_seasons_no_overlap
    exclude using gist (org_id with =, tstzrange(starts_at, ends_at) with &&)
);

/* RLS 比照 `rank_tiers`：**啟用、0 條 policy** ——
   只被 DEFINER 函式讀，沒有任何角色能直接查。 */
alter table public.rank_seasons enable row level security;

/* 種子：目前這一季 ＋ 下一季。
   🎯 **一次種兩季**是刻意的 —— 「忘記建下一季」在半年內不可能發生，
     而排除約束順便證明了它們不重疊。
   ⚠ **季別名稱與切點是可以改的資料，不是程式碼** ——
     要改成別的名字或別的切點就是一句 UPDATE／DELETE，不用動任何函式。
   ⚠ 6 個月一季是 2026-08-29 拍板的（決策紀錄第二十三節）；
     切在 1/1 與 7/1 是這份 SQL 選的，因為它不需要任何人記得。
   🔴 **上線那天可能要重切第一季** —— 現在這一季有一半在上線之前，
     而那段時間沒有任何真實牌局。那時 `orgs.live_from` 也要一起設。 */
insert into public.rank_seasons (code, org_id, label, starts_at, ends_at)
select v.code, o.id, v.label, v.s, v.e
  from public.orgs o
 cross join (values
   ('2026H2', '2026 秋季賽', timestamptz '2026-07-01 00:00+08', timestamptz '2027-01-01 00:00+08'),
   ('2027H1', '2027 春季賽', timestamptz '2027-01-01 00:00+08', timestamptz '2027-07-01 00:00+08')
 ) as v(code, label, s, e)
 where o.deleted_at is null
on conflict (org_id, code) do nothing;


-- ② ───────────────────────────────────────────────────────
/* 🔴 `season_champions` 的 PK 是 **`(season)` 沒有 org** ——
   兩個 org 不可能在同一季各有一個冠軍，而那張表**明明有 org_id 欄位**。
   ⚠ 今天只有一個 org 所以踩不到，**那是運氣不是設計**（同硬規則 3 那句）。
   ✅ 那張表**現在是空的**，所以改 PK 是零成本；有資料之後就是一次 migration。 */
alter table public.season_champions drop constraint if exists season_champions_pkey;
alter table public.season_champions add primary key (org_id, season);

/* 外鍵：冠軍只能屬於一個**真的存在**的季別。
   🎯 這一條把「季別字串隨手打」這件事**從流程規範變成資料庫規則**。 */
alter table public.season_champions drop constraint if exists season_champions_season_fk;
alter table public.season_champions
  add constraint season_champions_season_fk
  foreign key (org_id, season) references public.rank_seasons(org_id, code);


-- ③ ───────────────────────────────────────────────────────
/* 現在是第幾季。沒有涵蓋現在的季別 → 回 null（**不要瞎猜一個**）。 */
create or replace function public.current_season_tx(p_org_id uuid)
returns jsonb language sql stable security definer set search_path to 'public'
as $$
  select jsonb_build_object(
           'code', s.code, 'label', s.label,
           'starts_at', s.starts_at, 'ends_at', s.ends_at,
           /* 倒數用**台北日曆日相減**，不要用秒數 ——
              客人問的是「還有幾天」不是「還有幾小時」，
              而秒數除以 86400 會讓「今天結束」顯示成 0 天。 */
           'days_left', greatest(0,
             (s.ends_at at time zone 'Asia/Taipei')::date
             - (now()    at time zone 'Asia/Taipei')::date))
    from rank_seasons s
   where s.org_id = p_org_id
     and now() >= s.starts_at and now() < s.ends_at
   limit 1
$$;

/* 「上次段位歸零之後」是什麼時候。
   🎯 **這才是多樣性視窗真正的語意** —— 拍板寫的是「本季」，
     而「本季」在正常情況下就等於「上次歸零之後」。
   ⚠ 這樣寫的好處是**它自己會退化**：
     · 有當季 → 當季開始
     · 沒有當季但有過去的季 → 最後一季結束（＝上次歸零那一刻）
     · 一季都沒有 → null（呼叫端退回舊行為）
   🔴 直接寫「本季，沒有就一律不給大師」會在有人忘記建下一季時
     **靜靜把所有大師降成鑽石**，而那沒有任何症狀。 */
create or replace function public.rating_window_start_tx(p_org_id uuid)
returns timestamptz language sql stable security definer set search_path to 'public'
as $$
  select coalesce(
    (select s.starts_at from rank_seasons s
      where s.org_id = p_org_id and now() >= s.starts_at and now() < s.ends_at limit 1),
    (select max(s.ends_at) from rank_seasons s
      where s.org_id = p_org_id and s.ends_at <= now()))
$$;

/* 🔴 兩支都是**內部用**，前端叫不到才對。
   收 anon 與 PUBLIC **兩個方向都要**（硬規則 2.6／2.6b）——
   舊函式的 anon 來自 PUBLIC 繼承，新建的來自 default privileges 明確授權，
   只收一邊會是**完全沒有效果而且不報錯**的空操作。
   ⚠ DEFINER 函式從內部呼叫它們不受影響（呼叫端權限根本不會被檢查）。 */
revoke execute on function public.current_season_tx(uuid)      from public;
revoke execute on function public.current_season_tx(uuid)      from anon, authenticated;
revoke execute on function public.rating_window_start_tx(uuid) from public;
revoke execute on function public.rating_window_start_tx(uuid) from anon, authenticated;
grant  execute on function public.current_season_tx(uuid)      to service_role;
grant  execute on function public.rating_window_start_tx(uuid) to service_role;


-- ④ ───────────────────────────────────────────────────────
/* 大師熊的對手多樣性：視窗從「最近 50 場」換成「上次歸零之後」。
   ✅ 簽名不變 → `CREATE OR REPLACE`。org 從 `members` 查，不用多一個參數。 */
create or replace function public.member_rank_tx(p_member_id uuid)
returns text language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_rating int; v_master int; v_opp int; v_org uuid; v_win timestamptz;
begin
  select rating, org_id into v_rating, v_org
    from members where id = p_member_id and deleted_at is null;
  if v_rating is null then return null; end if;

  select min_rating into v_master from rank_tiers where code = 'master';
  if v_rating < v_master then
    return public.rank_from_rating(v_rating);
  end if;

  v_win := public.rating_window_start_tx(v_org);

  if v_win is not null then
    /* 本季（＝上次歸零之後）。**不設場次上限** ——
       視窗已經由時間界定，再加 limit 就是兩個規則管同一件事。 */
    with mine as (
      select session_id from session_players
       where member_id = p_member_id and finish_rank is not null
         and settled_at is not null and settled_at >= v_win
    )
    select count(distinct sp.member_id) into v_opp
      from session_players sp join mine l on l.session_id = sp.session_id
     where sp.member_id <> p_member_id;
  else
    /* 🔴 一季都還沒建 → 退回舊行為（最近 50 場），**不要一律不給**。
       「忘記建下一季」不該讓所有大師靜靜掉成鑽石。 */
    with last50 as (
      select session_id from session_players
       where member_id = p_member_id and finish_rank is not null
       order by joined_at desc limit 50
    )
    select count(distinct sp.member_id) into v_opp
      from session_players sp join last50 l on l.session_id = sp.session_id
     where sp.member_id <> p_member_id;
  end if;

  return case when coalesce(v_opp,0) >= 20
              then (select label from rank_tiers where code = 'master')
              else public.rank_from_rating(v_rating) end;   -- 卡在鑽石 I
end $function$;


-- ⑤ ───────────────────────────────────────────────────────
/* Hero 的賽季膠囊要真的倒數。⚠ **未定位的人也要拿到 season** ——
   他看到的是同一顆膠囊，而「這一季還有幾天」跟他有沒有段位無關。 */
create or replace function public.get_my_rank_tx(p_org_id uuid, p_member_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_rating int; v_games int; v_cached text; v_d jsonb; v_season jsonb;
begin
  select rating, rating_games, rank into v_rating, v_games, v_cached
    from members
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
  if v_rating is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  /* 🔴 沒有涵蓋現在的季別時回 **null**，前端就不畫那顆膠囊。
     ⚠ 不要退回「上一季」—— 那會顯示一個已經結束的賽季名稱，
       而客人沒有辦法知道它已經結束了。 */
  v_season := public.current_season_tx(p_org_id);

  /* 🔴 未定位：**不要回 rank_detail_tx 的結果**。
     那會回「銅牌熊 II」，而前端只要不小心讀了 `tier` 就又把假段位畫出來。
     → 整組段位欄位都不給，只回 `ranked: false`。
     ⚠ `rating` 也不回 —— 那是內部數字，而且對還沒打過的人沒有意義。 */
  if v_cached is null then
    return jsonb_build_object('ok', true, 'ranked', false, 'games', 0,
                              'season', v_season);
  end if;

  v_d := public.rank_detail_tx(v_rating);
  return v_d || jsonb_build_object('ok', true, 'ranked', true,
    'rank', public.member_rank_tx(p_member_id), 'games', v_games,
    'season', v_season);
end $function$;


-- ⑥ ───────────────────────────────────────────────────────
/* 關季時拒絕不存在的季別。
   🔴 在此之前 `p_season` 是**隨手打的字串** —— 打成 '2026h2' 也會成功，
     然後那一季就永遠對不上任何東西。外鍵其實已經會擋（②），
     但外鍵拋的是 23503 看不懂的訊息，這裡先給一句人話。 */
create or replace function public.reset_season_ratings_tx(
  p_org_id uuid, p_season text, p_drop_tiers integer default 2
) returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_champ uuid; v_rating int; v_n int; v_drop int; v_floor int;
begin
  if not exists (select 1 from rank_seasons
                  where org_id = p_org_id and code = p_season) then
    return jsonb_build_object('ok', false, 'reason', 'season_not_found');
  end if;

  if exists (select 1 from season_champions
              where org_id = p_org_id and season = p_season) then
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
end $function$;


-- ── 驗證 ───────────────────────────────────────────────
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_out text := ''; v_s jsonb; v_win timestamptz; v_master int;
  v_st uuid; v_tbl uuid; v_store uuid; me uuid; opp uuid; i int;
  v_rank text; v_r jsonb; v_err text;
begin
  begin
    ---- ① 表與約束 --------------------------------------
    v_out := v_out || E'\n' || '① 種子：兩季且不重疊' || E'\t' ||
      (select case when count(*) = 2 then '✅ ' || string_agg(code || ' ' || label, '、' order by code)
                   else '🔴 ' || count(*) || ' 季' end
         from rank_seasons where org_id = v_org);

    /* 🔴 **正對照缺一不可**：只驗「重疊會被擋」的話，
       一個「什麼都插不進去」的壞約束也會過。 */
    begin
      insert into rank_seasons (code, org_id, label, starts_at, ends_at)
      values ('X重疊', v_org, '測試', '2026-12-01+08', '2027-02-01+08');
      v_out := v_out || E'\n' || '② 重疊的季別要被擋' || E'\t' || '🔴 竟然插進去了';
    exception when exclusion_violation then
      v_out := v_out || E'\n' || '② 重疊的季別要被擋' || E'\t' || '✅ 擋下（exclusion_violation）';
    end;
    begin
      insert into rank_seasons (code, org_id, label, starts_at, ends_at)
      values ('X不重疊', v_org, '測試', '2027-07-01+08', '2028-01-01+08');
      v_out := v_out || E'\n' || '③ 正對照：不重疊的要插得進去' || E'\t' || '✅ 插入成功';
      delete from rank_seasons where code = 'X不重疊' and org_id = v_org;
    exception when others then
      v_out := v_out || E'\n' || '③ 正對照：不重疊的要插得進去' || E'\t' || '🔴 也被擋了：' || sqlerrm;
    end;

    v_out := v_out || E'\n' || '④ season_champions PK 補上 org' || E'\t' ||
      (select case when pg_get_constraintdef(oid) = 'PRIMARY KEY (org_id, season)'
                   then '✅ (org_id, season)' else '🔴 ' || pg_get_constraintdef(oid) end
         from pg_constraint where conrelid = 'season_champions'::regclass and contype = 'p');

    ---- ③ 兩支查詢 --------------------------------------
    v_s := public.current_season_tx(v_org);
    v_out := v_out || E'\n' || '⑤ 現在是哪一季（今天 2026-09-01 → 2026H2）' || E'\t' ||
      case when v_s->>'code' = '2026H2' then '✅ ' || (v_s->>'label') ||
                '　倒數 ' || (v_s->>'days_left') || ' 天'
           else '🔴 ' || coalesce(v_s::text, 'null') end;

    v_win := public.rating_window_start_tx(v_org);
    v_out := v_out || E'\n' || '⑥ 多樣性視窗 = 本季開始' || E'\t' ||
      case when v_win = timestamptz '2026-07-01 00:00+08' then '✅ 2026-07-01'
           else '🔴 ' || coalesce(v_win::text, 'null') end;

    ---- ④ member_rank_tx 的視窗真的換了 ------------------
    select min_rating into v_master from rank_tiers where code = 'master';
    select id into v_store from stores where org_id = v_org limit 1;
    select id into v_tbl   from tables where org_id = v_org limit 1;
    /* ⚠ `rank` 用 `rank_from_rating()` 算出來，不要寫死「鑽石熊 I」——
       每階 45 一定會調，寫死的測試會在調整那天莫名其妙變紅。 */
    insert into members (org_id, display_name, rating, rank)
      values (v_org, '測大師', v_master + 50, public.rank_from_rating(v_master + 50))
      returning id into me;

    /* 造 20 個不同對手，但整批結算時間**在本季開始之前**（去年） */
    for i in 1..20 loop
      insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
        values (v_org, v_store, v_tbl, 'private', 'completed', now()) returning id into v_st;
      insert into members (org_id, display_name) values (v_org, '測對手' || i) returning id into opp;
      insert into session_players (org_id, session_id, member_id, finish_rank, settled_at)
        values (v_org, v_st, me,  1, timestamptz '2026-01-15 12:00+08'),
               (v_org, v_st, opp, 2, timestamptz '2026-01-15 12:00+08');
    end loop;

    v_rank := public.member_rank_tx(me);
    v_out := v_out || E'\n' || '⑦ 20 個對手但都在上一季 → 不給大師' || E'\t' ||
      case when v_rank = public.rank_from_rating(v_master + 50)
           then '✅ ' || v_rank || '（舊寫法會給大師）'
           else '🔴 ' || coalesce(v_rank, 'null') end;

    /* 🔴 **正對照**：把同一批搬進本季，就必須變成大師。
       少了這一格的話，一個「永遠不給大師」的壞函式也會讓 ⑦ 變綠。 */
    update session_players set settled_at = timestamptz '2026-08-01 12:00+08'
     where member_id = me;
    v_rank := public.member_rank_tx(me);
    v_out := v_out || E'\n' || '⑧ 正對照：同一批搬進本季 → 給大師' || E'\t' ||
      case when v_rank = (select label from rank_tiers where code = 'master')
           then '✅ ' || v_rank
           else '🔴 ' || coalesce(v_rank, 'null') end;

    /* 🎯 **儀器測試：過濾的是「我」那一列還是「對手」那一列？**
       把對手全部搬到上一季、我留在本季 —— 這是現實不會出現的狀態，
       但它是唯一能分辨這兩種寫法的方式，而寫錯的話 ⑦⑧ 都還是綠的。
       ⚠ 正確答案是**仍然大師**：條件是「我本季打過的場次裡遇過幾個人」，
         不是「對手的那一列是什麼時候結算的」。 */
    update session_players set settled_at = timestamptz '2026-01-15 12:00+08'
     where member_id <> me and session_id in (select session_id from session_players where member_id = me);
    v_rank := public.member_rank_tx(me);
    v_out := v_out || E'\n' || '⑨ 視窗看的是「我」那一列，不是對手的' || E'\t' ||
      case when v_rank = (select label from rank_tiers where code = 'master')
           then '✅ 對手搬走也不影響 —— 過濾的是我'
           else '🔴 ' || coalesce(v_rank,'null') || ' —— 過濾錯人了' end;

    ---- ⑤ get_my_rank_tx 的 season 區塊 ------------------
    v_r := public.get_my_rank_tx(v_org, me);
    v_out := v_out || E'\n' || '⑩ 有段位的人拿得到 season' || E'\t' ||
      case when v_r->'season'->>'code' = '2026H2' and (v_r->>'ranked')::boolean
           then '✅ ranked ＋ ' || (v_r->'season'->>'label')
           else '🔴 ' || coalesce(v_r::text, 'null') end;

    insert into members (org_id, display_name) values (v_org, '測未定位') returning id into opp;
    v_r := public.get_my_rank_tx(v_org, opp);
    v_out := v_out || E'\n' || '⑪ 未定位的人也拿得到 season' || E'\t' ||
      case when v_r->'season'->>'code' = '2026H2' and not (v_r->>'ranked')::boolean
                and not (v_r ? 'tier')
           then '✅ season 有、ranked=false、沒有 tier'
           else '🔴 ' || coalesce(v_r::text, 'null') end;

    ---- ⑥ 關季擋不存在的季別 ----------------------------
    v_r := public.reset_season_ratings_tx(v_org, '打錯的季別');
    v_out := v_out || E'\n' || '⑫ 關季拒絕不存在的季別' || E'\t' ||
      case when v_r->>'reason' = 'season_not_found' then '✅ season_not_found'
           else '🔴 ' || coalesce(v_r::text, 'null') end;

    ---- 授權 --------------------------------------------
    v_out := v_out || E'\n' || '⑬ 兩支內部函式：anon 與 PUBLIC 都收乾淨' || E'\t' ||
      (select case when count(*) = 0 then '✅ 兩個方向都沒有'
                   else '🔴 還有 ' || count(*) || ' 筆：' || string_agg(proname || '/' || g, '、') end
         from (select p.proname,
                      case when a.grantee = 0 then 'PUBLIC' else 'anon' end as g
                 from pg_proc p, aclexplode(p.proacl) a
                where p.pronamespace = 'public'::regnamespace
                  and p.proname in ('current_season_tx','rating_window_start_tx')
                  and a.privilege_type = 'EXECUTE'
                  and (a.grantee = 0 or a.grantee = 'anon'::regrole::oid)) z);
    v_out := v_out || E'\n' || '⑭ 正對照：get_my_rank_tx 的 anon 還在' || E'\t' ||
      (select case when exists (select 1 from aclexplode(p.proacl) a
                                 where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
                   then '✅ 還在' else '🔴 掉了' end
         from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'get_my_rank_tx');

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.season', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.season', true), E'\n')) as x
 where coalesce(x,'') <> '';
