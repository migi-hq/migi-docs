-- ============================================================
-- 賽季自動建下一季，讓賽季之間不會出現空檔
-- （2026-10-10 使用者拍板：之後每一季自動叫「YYYY 段位春季賽／秋季賽」）
--
-- 起點：把「每一局統計」收成一支時發現，成績頁與賽季排行榜的「本季起點」是兩支函式算的
--   rating_window_start_tx  進行中的賽季起點；沒有的話 ＝ 上一季的結束時間（成績頁、對手統計用）
--   current_season_tx       只認進行中的賽季；沒有就是 null（排行榜、段位頁用 ⇒ 回空）
-- 賽季頭尾相接時兩支永遠一樣，只有「兩季之間的空檔」會分岔。
--
-- 🔴 而全庫沒有任何函式會建下一季、後台也沒有賽季頁 ⇒ 2027-06-30 春季賽結束時，
--   沒人記得手動建 2027 下半季的話空檔就出現，而且不報錯：
--   · 排行榜與段位頁說「沒有賽季」，成績頁照樣算本季數字
--   · sweep_season_close_tx 收掉一季時，**下一季不存在就不寫 season_start_ratings**
--     ⇒ 下一季的起點段位分整份漏掉，事後補不回來（結算只跑一次）
--
-- 做法：
--   _ensure_next_seasons(org, 建到哪一天為止 default 現在＋60 天)
--     從最後一季的結束時間接著建，一直建到涵蓋那一天；頭尾相接，不會有空檔。
--     規則（照既有兩季推）：台北時間 1/1–6/30 ＝ YYYYH1「YYYY 段位春季賽」，
--                           7/1–12/31 ＝ YYYYH2「YYYY 段位秋季賽」。
--     一季都沒有的機構不替它發明第一季。代碼撞到就拋錯（不安靜跳過）。
--   sweep_season_close_tx（pg_cron season-close 每 10 分鐘）：**結算之前**先對每個有賽季的機構叫一次。
--     建季失敗不擋結算，寫 app_events season_create_error（錯誤儀表 ⑲ 會列出來）。
--
-- 今天跑完不會建出任何東西：最後一季 2027-06-30 結束，晚於 現在＋60 天。
--   2027H2 會在 2027-05-01 前後自動出現。行為另外在交易內測過（sql/checks/2026-10-10_驗賽季自動建下一季.sql）。
-- 兩支起點函式不合併：沒有空檔之後它們的答案永遠一樣，硬合併要動四支函式，換到的只是好看。
--
-- 驗證段不 raise（硬規則 1.8）—— 這份要留下東西。
-- ============================================================


-- ── ① 建下一季 ──
create or replace function public._ensure_next_seasons(
  p_org_id uuid,
  p_until  timestamptz default now() + interval '60 days')
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_last rank_seasons%rowtype;
  v_d    date;
  v_y    int;
  v_h    text;
  v_end  date;
  v_new  jsonb := '[]'::jsonb;
  i      int := 0;
begin
  loop
    select * into v_last from rank_seasons
     where org_id = p_org_id
     order by ends_at desc limit 1;
    exit when not found;                 -- 一季都沒有：不替它發明第一季
    exit when v_last.ends_at > p_until;  -- 已經排到那一天之後了
    i := i + 1;
    exit when i > 8;                     -- 保險：一次最多補 8 季（4 年），不會無限迴圈

    /* 新一季從上一季結束那一刻開始（頭尾相接）；屬於哪半年看台北時間的日期 */
    v_d := (v_last.ends_at at time zone 'Asia/Taipei')::date;
    v_y := extract(year from v_d)::int;
    if extract(month from v_d) < 7 then
      v_h := 'H1'; v_end := make_date(v_y, 7, 1);
    else
      v_h := 'H2'; v_end := make_date(v_y + 1, 1, 1);
    end if;

    insert into rank_seasons (org_id, code, label, starts_at, ends_at)
    values (p_org_id,
            v_y || v_h,
            v_y || case v_h when 'H1' then ' 段位春季賽' else ' 段位秋季賽' end,
            v_last.ends_at,
            v_end::timestamp at time zone 'Asia/Taipei');

    v_new := v_new || to_jsonb(v_y || v_h);
  end loop;

  return jsonb_build_object('ok', true, 'created', v_new);
end $function$;

revoke execute on function public._ensure_next_seasons(uuid, timestamptz) from public;
revoke execute on function public._ensure_next_seasons(uuid, timestamptz) from anon, authenticated;
grant  execute on function public._ensure_next_seasons(uuid, timestamptz) to service_role;


-- ── ② 賽季結算排程：結算之前先把下一季建好（其餘與線上版逐字相同）──
create or replace function public.sweep_season_close_tx()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_s record; v_res jsonb; v_out jsonb := '[]'::jsonb; v_next text; v_ach jsonb;
  v_org uuid; v_made jsonb := '[]'::jsonb; v_r jsonb;
begin
  /* ★ 2026-10-10：先把下一季建好，再結算。
     順序有意義 —— 結算時下一季不存在的話，下一季的起點段位分（season_start_ratings）不會寫，而且補不回來。
     建季失敗不擋結算，但要讓人看得到。 */
  for v_org in select distinct rs.org_id from rank_seasons rs loop
    begin
      v_r := public._ensure_next_seasons(v_org);
      if jsonb_array_length(v_r -> 'created') > 0 then
        v_made := v_made || jsonb_build_array(jsonb_build_object('org', v_org, 'created', v_r -> 'created'));
      end if;
    exception when others then
      v_made := v_made || jsonb_build_array(jsonb_build_object('org', v_org, 'error', left(sqlerrm, 300)));
      begin
        perform public.log_app_event_tx(v_org, null, 'season_create_error',
          jsonb_build_object('code', sqlstate, 'message', left(sqlerrm, 300)), now(), null);
      exception when others then null;
      end;
    end;
  end loop;

  for v_s in
    select rs.org_id, rs.code, rs.ends_at
      from rank_seasons rs
     where rs.ends_at <= now()
       and not exists (select 1 from season_champions c where c.org_id = rs.org_id and c.season = rs.code)
     order by rs.ends_at
  loop
    begin
      v_res := public.reset_season_ratings_tx(v_s.org_id, v_s.code);
      if not coalesce((v_res ->> 'ok')::boolean, false) then
        raise exception 'reset_season_ratings_tx 回 %', v_res;
      end if;

      -- 下一季的起點 ＝ 剛降完階的段位分
      select rs2.code into v_next from rank_seasons rs2
       where rs2.org_id = v_s.org_id and rs2.starts_at >= v_s.ends_at
       order by rs2.starts_at limit 1;
      if v_next is not null then
        insert into season_start_ratings (org_id, season, member_id, rating)
        select m.org_id, v_next, m.id, m.rating
          from members m
         where m.org_id = v_s.org_id and m.deleted_at is null and m.rank is not null
        on conflict do nothing;
      end if;

      -- 成就失敗不影響結算（結算已經做完、不可重來）
      begin
        v_ach := public._ach_season_close_events(v_s.org_id, v_s.code);
      exception when others then
        v_ach := jsonb_build_object('ok', false, 'code', sqlstate, 'message', left(sqlerrm, 300));
        begin
          perform public.log_app_event_tx(v_s.org_id, null, 'ach_error',
            jsonb_build_object('where', '_ach_season_close_events', 'season', v_s.code,
                               'code', sqlstate, 'message', left(sqlerrm, 300)), now(), null);
        exception when others then null;
        end;
      end;

      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'season', v_s.code, 'result', v_res, 'next_season', v_next, 'achievements', v_ach));
    exception when others then
      -- 這一季整個退回（沒有記冠軍 ⇒ 下一輪會再試），而且要讓人看得到
      v_out := v_out || jsonb_build_array(jsonb_build_object('season', v_s.code, 'error', left(sqlerrm, 300)));
      begin
        perform public.log_app_event_tx(v_s.org_id, null, 'season_close_error',
          jsonb_build_object('season', v_s.code, 'code', sqlstate, 'message', left(sqlerrm, 300)), now(), null);
      exception when others then null;
      end;
    end;
  end loop;
  return jsonb_build_object('ok', true, 'created_seasons', v_made, 'closed', v_out);
end $function$;


-- ── 驗證（單一 SELECT，不 raise，不建任何賽季）──
-- ① 建季函式在，而且只有 service_role（anon／authenticated／PUBLIC 都沒有）
-- ② 結算排程有叫它，而且叫的位置在結算之前
-- ③ 排程 season-close 還在而且啟用中
-- ④ 線上的賽季現在頭尾相接、有進行中的那一季（印出每一季讓人看）
-- ⑤ 2026-10-10 查過：在此之前全庫沒有任何函式會寫 rank_seasons；現在應該正好一支（就是建季那支）
with fn as (
  select p.proname, pg_get_functiondef(p.oid) as def
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
), ens as (
  select p.oid, p.proacl from pg_proc p
   where p.oid = 'public._ensure_next_seasons(uuid, timestamptz)'::regprocedure
), sw as (
  select def from fn where proname = 'sweep_season_close_tx'
), ss as (
  select rs.code, rs.label, rs.starts_at, rs.ends_at,
         lag(rs.ends_at) over (partition by rs.org_id order by rs.starts_at) as prev_end
    from rank_seasons rs
)
select
  (select case when (select proacl is not null from ens)
                and not exists (select 1 from ens, aclexplode(ens.proacl) a
                                 where a.privilege_type = 'EXECUTE'
                                   and a.grantee in (0, 'anon'::regrole::oid, 'authenticated'::regrole::oid))
                and exists (select 1 from ens, aclexplode(ens.proacl) a
                             where a.privilege_type = 'EXECUTE' and a.grantee = 'service_role'::regrole::oid)
               then '✅ 建季函式只有 service_role'
               else '🔴 建季函式授權不對：' || coalesce((select proacl::text from ens), 'null（＝PUBLIC 有）') end)  as "①",
  (select case when strpos(def, '_ensure_next_seasons(') = 0 then '🔴 結算排程沒有叫建季函式'
               when strpos(def, '_ensure_next_seasons(') < strpos(def, 'reset_season_ratings_tx(')
               then '✅ 結算排程先建季、再結算'
               else '🔴 建季排在結算之後（下一季的起點段位分會漏寫）' end
     from sw)                                                                                         as "②",
  (select case when exists (select 1 from cron.job where jobname = 'season-close' and active)
               then '✅ 排程 season-close 啟用中' else '🔴 排程 season-close 不見了或被停用' end)        as "③",
  (select string_agg(code || ' ' || label || ' '
                     || to_char(starts_at at time zone 'Asia/Taipei', 'YYYY-MM-DD') || '～'
                     || to_char((ends_at at time zone 'Asia/Taipei') - interval '1 second', 'YYYY-MM-DD')
                     || case when prev_end is not null and prev_end <> starts_at then ' 🔴 跟上一季中間有空檔' else '' end,
                     '・' order by starts_at)
          || case when exists (select 1 from rank_seasons where now() >= starts_at and now() < ends_at)
                  then ' ✅ 有進行中的賽季' else ' 🔴 現在沒有進行中的賽季' end
     from ss)                                                                                         as "④",
  (select coalesce(string_agg(proname, '、' order by proname), '（一支都沒有）')
          || case when count(*) = 1 and bool_and(proname = '_ensure_next_seasons') then ' ✅'
                  else ' 🔴 期望只有 _ensure_next_seasons' end
     from fn
    where def ~* 'insert\s+into\s+(public\.)?rank_seasons')                                           as "⑤";
