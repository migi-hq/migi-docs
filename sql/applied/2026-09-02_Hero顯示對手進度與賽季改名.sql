/* ============================================================
   Hero 顯示「不同對手 N / 50」＋ 賽季改名　2026-09-02 · MIGI

   ── ① 成績頁 Hero 要顯示對手進度（只在鑽石熊 I）──────
   大師熊的條件是**分數 ＋ 本季 50 位不同對手**。
   在爬到鑽石熊 I 之前，那個條件完全不影響他 ——
   **提早顯示只是一個看不懂的數字**。
   ⇒ 只有 `rating >= 鑽石熊 I 的門檻`（820）時才回傳。

   🔴 **順手解掉一個結構問題**：那段「本季不同對手數」的查詢
     目前**只寫在 `member_rank_tx` 裡**，而 Hero 也要用它。
     複製一份 ⇒ 兩份「本季」的定義（而它 9/1 才剛從
     「最近 50 場」改成「本季」一次）。
   → 抽成 `member_opponents_tx(member)`，兩邊都呼叫它。

   ── ② 賽季改名 ────────────────────────────────────
   `2026 秋季賽` → **`2026 段位秋季賽`**（使用者 2026-09-02 指定）。
   ⚠ 它是**資料不是程式碼**（`rank_seasons.label`），所以只是一句 UPDATE，
     而且 Hero 的膠囊與《段位怎麼算》的賽季區**會一起變**。
   ============================================================ */

-- ① 抽出「本季不同對手數」──────────────────────────
create or replace function public.member_opponents_tx(p_member_id uuid)
returns int language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_org uuid; v_win timestamptz; v_opp int;
begin
  select org_id into v_org from members where id = p_member_id and deleted_at is null;
  if v_org is null then return null; end if;

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
    /* 🔴 一季都還沒建 → 退回舊行為（最近 50 場），**不要一律回 0**。
       「忘記建下一季」不該讓所有大師靜靜掉成鑽石。
       ⚠ 這個 `limit 50` 是**視窗大小**，跟門檻 `min_opponents`
         **是兩件事**，數字剛好一樣是巧合。不要合併。 */
    with last50 as (
      select session_id from session_players
       where member_id = p_member_id and finish_rank is not null
       order by joined_at desc limit 50
    )
    select count(distinct sp.member_id) into v_opp
      from session_players sp join last50 l on l.session_id = sp.session_id
     where sp.member_id <> p_member_id;
  end if;

  return coalesce(v_opp, 0);
end $function$;

/* 🔴 內部用：收 anon 與 PUBLIC **兩個方向**（硬規則 2.6／2.6b）。
   ⚠ DEFINER 函式從內部呼叫不受影響。 */
revoke execute on function public.member_opponents_tx(uuid) from public;
revoke execute on function public.member_opponents_tx(uuid) from anon, authenticated;
grant  execute on function public.member_opponents_tx(uuid) to service_role;


-- ② member_rank_tx 改用它（同一份定義）──────────────
create or replace function public.member_rank_tx(p_member_id uuid)
returns text language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_rating int; v_master int; v_need int;
begin
  select rating into v_rating from members
   where id = p_member_id and deleted_at is null;
  if v_rating is null then return null; end if;

  select min_rating, coalesce(min_opponents, 0) into v_master, v_need
    from rank_tiers where code = 'master';

  if v_rating < v_master then
    return public.rank_from_rating(v_rating);
  end if;

  /* 🔴 **視窗邏輯已抽到 `member_opponents_tx`** —— 這裡只問結果。
     在此之前這段查詢在這支裡各寫一份，而 Hero 也要同一個數字。 */
  return case when public.member_opponents_tx(p_member_id) >= v_need
              then (select label from rank_tiers where code = 'master')
              else public.rank_from_rating(v_rating) end;   -- 卡在鑽石 I
end $function$;


-- ③ get_my_rank_tx 多回對手進度（只在鑽石熊 I 以上）──
create or replace function public.get_my_rank_tx(p_org_id uuid, p_member_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_rating int; v_games int; v_cached text; v_d jsonb; v_season jsonb;
  v_gate int; v_need int; v_extra jsonb := '{}'::jsonb;
begin
  select rating, rating_games, rank into v_rating, v_games, v_cached
    from members
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
  if v_rating is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  v_season := public.current_season_tx(p_org_id);

  if v_cached is null then
    return jsonb_build_object('ok', true, 'ranked', false, 'games', 0,
                              'season', v_season);
  end if;

  /* ★ 2026-09-02：對手進度，**只在鑽石熊 I 以上**才回。
     🎯 在爬到那裡之前，大師熊的條件完全不影響他 ——
       提早顯示只是一個看不懂的數字。
     ⚠ 門檻是**算出來的**（最高 auto 階 ＋ 它最後一個小級的位移），
       不要寫死 820 —— 那個數字 9/1 才因為銅牌熊調整而從 815 變過一次。 */
  select t.min_rating + s.off into v_gate
    from rank_tiers t
    join lateral (select max(offset_pts) as off from rank_sub_levels
                   where tier_code = t.code) s on true
   where t.auto
   order by t.min_rating desc limit 1;

  select coalesce(min_opponents, 0) into v_need from rank_tiers where code = 'master';

  if v_rating >= v_gate then
    v_extra := jsonb_build_object(
      'opponents',      public.member_opponents_tx(p_member_id),
      'opponents_need', v_need);
  end if;

  v_d := public.rank_detail_tx(v_rating);
  return v_d || v_extra || jsonb_build_object('ok', true, 'ranked', true,
    'rank', public.member_rank_tx(p_member_id), 'games', v_games,
    'season', v_season);
end $function$;


-- ④ 賽季改名（資料，不是程式碼）──────────────────────
update public.rank_seasons set label = '2026 段位秋季賽' where code = '2026H2';
update public.rank_seasons set label = '2027 段位春季賽' where code = '2027H1';


-- ── 驗證 ───────────────────────────────────────────────
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_out text := ''; v_store uuid; v_tbl uuid;
  me uuid; opp uuid; s uuid; i int; r jsonb; v_gate int;
begin
  begin
    v_out := v_out || E'\n' || '① 賽季改名' || E'\t' ||
      (select case when string_agg(label, '、' order by code) = '2026 段位秋季賽、2027 段位春季賽'
                   then '✅ ' || string_agg(label, '、' order by code)
                   else '🔴 ' || string_agg(label, '、' order by code) end
         from rank_seasons where org_id = v_org);

    select t.min_rating + s.off into v_gate
      from rank_tiers t
      join lateral (select max(offset_pts) as off from rank_sub_levels where tier_code=t.code) s on true
     where t.auto order by t.min_rating desc limit 1;
    v_out := v_out || E'\n' || '② 顯示門檻＝鑽石熊 I（算出來的，不寫死）' || E'\t' ||
      case when v_gate = 820 and public.rank_from_rating(v_gate) = '鑽石熊 I'
           then '✅ 820 ＝ 鑽石熊 I'
           else '🔴 ' || v_gate || ' ＝ ' || public.rank_from_rating(v_gate) end;

    ---- 造一個鑽石熊 I 的人 ------------------------------
    select id into v_store from stores where org_id = v_org limit 1;
    select id into v_tbl   from tables where org_id = v_org limit 1;
    insert into members (org_id, display_name, rating, rank)
      values (v_org, '測鑽石', v_gate, public.rank_from_rating(v_gate)) returning id into me;
    for i in 1..12 loop
      insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
        values (v_org, v_store, v_tbl, 'private','completed', now()) returning id into s;
      insert into members (org_id, display_name) values (v_org,'測對手'||i) returning id into opp;
      insert into session_players (org_id, session_id, member_id, finish_rank, settled_at)
        values (v_org,s,me,1,now()), (v_org,s,opp,2,now());
    end loop;

    r := public.get_my_rank_tx(v_org, me);
    v_out := v_out || E'\n' || '③ 🎯 鑽石熊 I → 回傳 12 / 50' || E'\t' ||
      case when (r->>'opponents')::int = 12 and (r->>'opponents_need')::int = 50
           then '✅ opponents 12 ／ need 50'
           else '🔴 ' || coalesce(r->>'opponents','(沒有)') || ' ／ ' || coalesce(r->>'opponents_need','(沒有)') end;

    /* 🔴 **正對照**：低一分（鑽石熊 II）就**不該回**這兩個鍵。
       少了這一格，一個「永遠回傳」的實作會讓 ③ 變綠，
       而畫面會對一個銅牌熊顯示「不同對手 0 / 50」—— 看不懂的數字。 */
    update members set rating = v_gate - 1, rank = public.rank_from_rating(v_gate - 1) where id = me;
    r := public.get_my_rank_tx(v_org, me);
    v_out := v_out || E'\n' || '④ 🎯 正對照：差一分（' || (r->>'rank') || '）→ 完全不回' || E'\t' ||
      case when not (r ? 'opponents') and not (r ? 'opponents_need')
           then '✅ 兩個鍵都沒有'
           else '🔴 ' || (r->>'opponents') || ' —— 提早顯示會是看不懂的數字' end;

    ---- 正對照：抽出來之後 member_rank_tx 行為不變 --------
    update members set rating = 900, rank = public.rank_from_rating(900) where id = me;
    v_out := v_out || E'\n' || '⑤ 正對照：900 分但只有 12 個對手 → 還是鑽石熊 I' || E'\t' ||
      case when public.member_rank_tx(me) = '鑽石熊 I' then '✅ 鑽石熊 I'
           else '🔴 ' || coalesce(public.member_rank_tx(me),'null') end;
    for i in 13..50 loop
      insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
        values (v_org, v_store, v_tbl, 'private','completed', now()) returning id into s;
      insert into members (org_id, display_name) values (v_org,'測對手'||i) returning id into opp;
      insert into session_players (org_id, session_id, member_id, finish_rank, settled_at)
        values (v_org,s,me,1,now()), (v_org,s,opp,2,now());
    end loop;
    v_out := v_out || E'\n' || '⑥ 正對照：湊滿 50 → 大師熊' || E'\t' ||
      case when public.member_rank_tx(me) = '大師熊' then '✅ 大師熊'
           else '🔴 ' || coalesce(public.member_rank_tx(me),'null') end;
    v_out := v_out || E'\n' || '⑦ 正對照：member_opponents_tx 與 Hero 是同一個數字' || E'\t' ||
      (select case when public.member_opponents_tx(me) = (public.get_my_rank_tx(v_org, me)->>'opponents')::int
                   then '✅ 都是 ' || public.member_opponents_tx(me)
                   else '🔴 兩邊不一樣 —— 大概又各寫了一份' end);

    v_out := v_out || E'\n' || '⑧ 正對照：member_opponents_tx 收乾淨、其餘授權沒動' || E'\t' ||
      (select case when (select count(*) from pg_proc p, aclexplode(p.proacl) a
                          where p.pronamespace='public'::regnamespace and p.proname='member_opponents_tx'
                            and a.privilege_type='EXECUTE'
                            and (a.grantee=0 or a.grantee='anon'::regrole::oid)) = 0
                    and (select count(*) from pg_proc p
                          where p.pronamespace='public'::regnamespace
                            and p.proname in ('member_rank_tx','get_my_rank_tx')
                            and exists (select 1 from aclexplode(p.proacl) a
                                         where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE')) = 2
                   then '✅ 新的沒有 anon／兩支舊的都還有'
                   else '🔴 授權有東西被動到' end);

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.opp', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.opp', true), E'\n')) as x
 where coalesce(x,'') <> '';
