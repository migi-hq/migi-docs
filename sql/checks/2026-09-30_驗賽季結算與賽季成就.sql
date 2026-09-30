/* ============================================================
   行為測試：賽季自動結算 ＋ 賽季成就（交易內，**全部回滾**）
   2026-09-30 · 配 sql/pending/2026-09-30_賽季自動結算與賽季成就.sql（先跑那份）

   ⓐ 結算：把本季（2026H2）在交易內改成「09-01 開始、一分鐘前結束」，五位有打牌的會員暫時當真人，
      測試04 的段位分調成 900（大師），跑一次 sweep_season_close_tx()
      期望（期望值 2026-09-30 用唯讀查詢先算過）：
        測試04   雀神、前十、前百、全勤、賽季進步（起點快照 100）、二度稱王（另外造一筆舊冠軍）
                 整季不降階 ✗（本季降階過 1 次）
        測試02   前十、前百、全勤；賽季進步 ✗（起點快照 = 結束分數）；整季不降階 ✗（降階 2 次）
        測試03   前十、前百、全勤；整季不降階 ✗（只有 3 場）
        咖勁凱   交易內把本季段位分改成一路往上 ⇒ 整季不降階 ✓；賽季進步 ✗（沒有起點）
      另外：下一季（2027H1）起點快照有寫、跟降完階的分數一樣；再跑一次不會重複結算
   ⓑ 賽季首戰：把本季開始改到 09-06 00:00，
      測試04（之前打過）本季第一場 ⇒ ✓；測試03（第一場就在本季）⇒ ✗

   ⚠ 故意 raise 回滾（硬規則 1.8 的例外），訊息設在 exception handler 裡（硬規則 3.9）
   ============================================================ */

do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  x uuid := '526aa8b9-cc93-4327-b878-6d21d399af8e';   -- 測試04
  y uuid := '218378e1-fb6c-43fb-b642-99fdbf5c52b1';   -- 測試02
  z uuid := 'd0db928e-5a75-4535-90d4-93ede67790a8';   -- 測試03
  p uuid := '69016205-afde-4036-95a6-5893c9d0e5fe';   -- 咖勁凱
  v_msg text := ''; v_ok int := 0; v_all int := 0; r jsonb; v_n int; v_m int; v_rt int; v_snap int;

begin
  -- 前提（每一段自己建）
  -- ⚠ 結束時間寫死 10-01 00:00，不可以寫「一分鐘前」：10-01 以後跑，測試賽季會多出一個十月，
  --   全勤就一定拿不到（2026-10-01 00:05 第一次跑就踩到，函式是對的、樣本錯）
  update public.rank_seasons set starts_at = '2026-09-01 00:00+08', ends_at = '2026-10-01 00:00+08'
   where org_id = v_org and code = '2026H2';
  update public.members set is_test = false where id in (x, y, z, p, 'd73fdac2-d6b9-4b8a-bcff-b19c2786056f');
  update public.members set rating = 900 where id = x;
  update public.rank_tiers set min_opponents = 0 where code = 'master';
  -- 二度稱王要一筆舊冠軍（放在今年一月，不跟任何賽季重疊）
  insert into public.rank_seasons (org_id, code, label, starts_at, ends_at)
  values (v_org, 'ZZT0', '測試舊賽季', '2026-01-01 00:00+08', '2026-02-01 00:00+08');
  insert into public.season_champions (season, org_id, member_id, rating) values ('ZZT0', v_org, x, 900);
  -- 起點快照：測試04 從 100 開始（會進步）、測試02 起點＝現在的分數（不會進步）
  insert into public.season_start_ratings (org_id, season, member_id, rating)
  values (v_org, '2026H2', x, 100),
         (v_org, '2026H2', y, (select rating from public.members where id = y));
  -- 咖勁凱本季每一場結算後的段位分改成一路往上
  update public.session_players sp set rating_after = 150 + 20 * q.n
    from (select session_id, row_number() over (order by settled_at, session_id) as n
            from public.session_players
           where member_id = p and settled_at >= '2026-09-01 00:00+08' and rating_after is not null) q
   where sp.member_id = p and sp.session_id = q.session_id;

  r := public.sweep_season_close_tx();

  -- ① 結算了、雀神是測試04、五個人有名次
  select count(*) into v_n from public.season_standings where org_id = v_org and season = '2026H2';
  v_all := v_all + 1;
  if (select member_id from public.season_champions where org_id = v_org and season = '2026H2') = x and v_n = 5
    then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ① 結算：雀神 ' || coalesce((select m.display_name from public.season_champions c join public.members m on m.id = c.member_id
                                              where c.org_id = v_org and c.season = '2026H2'), '（無）')
        || '、名次 ' || v_n || ' 人（期望 測試04、5 人）' || E'\n';

  -- ② 下一季起點快照 ＝ 降完階的分數
  select count(*) into v_n from public.season_start_ratings where org_id = v_org and season = '2027H1';
  select count(*) into v_m from public.members where org_id = v_org and deleted_at is null and rank is not null;
  select rating into v_rt from public.members where id = x;
  select rating into v_snap from public.season_start_ratings where org_id = v_org and season = '2027H1' and member_id = x;
  v_all := v_all + 1;
  if v_n = v_m and v_snap = v_rt and v_rt < 900 then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ② 2027H1 起點快照 ' || v_n || ' 筆（期望 ' || v_m || '）；測試04 降完階 ' || coalesce(v_rt::text, '∅')
        || '、快照 ' || coalesce(v_snap::text, '∅') || E'\n';

  -- ③～⑥ 每個人的賽季成就
  declare
    v_who uuid; v_name text; v_want text[]; v_not text[]; v_got text; v_bad text;
  begin
    for v_who, v_name, v_want, v_not in
      select * from (values
        (x, '測試04', array['season_06','season_05','season_04','season_02','season_03','season_08'], array['rank_12']),
        (y, '測試02', array['season_05','season_04','season_02'], array['season_03','rank_12','season_06']),
        (z, '測試03', array['season_05','season_04','season_02'], array['rank_12','season_03']),
        (p, '咖勁凱', array['rank_12','season_05','season_04','season_02'], array['season_03','season_06'])
      ) t(a, b, c, d)
    loop
      select string_agg(a.code, '、' order by a.code) into v_got
        from public.member_achievements ma join public.achievements a on a.id = ma.achievement_id
       where ma.member_id = v_who and ma.status = 'unlocked' and a.code = any(v_want);
      select string_agg(a.code, '、' order by a.code) into v_bad
        from public.member_achievements ma join public.achievements a on a.id = ma.achievement_id
       where ma.member_id = v_who and ma.status = 'unlocked' and a.code = any(v_not);
      v_all := v_all + 1;
      if (select count(*) from public.member_achievements ma join public.achievements a on a.id = ma.achievement_id
           where ma.member_id = v_who and ma.status = 'unlocked' and a.code = any(v_want)) = array_length(v_want, 1)
         and v_bad is null
        then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
      v_msg := v_msg || ' ' || v_name || '：拿到 ' || coalesce(v_got, '無') || '（期望 ' || array_to_string(v_want, '、')
            || '）；不該拿到卻拿到 ' || coalesce(v_bad, '無') || E'\n';
    end loop;
  end;

  -- ⑦ 再跑一次：沒有東西要結算、名次沒有多出來
  r := public.sweep_season_close_tx();
  select count(*) into v_n from public.season_standings where org_id = v_org and season = '2026H2';
  v_all := v_all + 1;
  if jsonb_array_length(r -> 'closed') = 0 and v_n = 5 then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ⑦ 再跑一次：結算了 ' || jsonb_array_length(r -> 'closed') || ' 季、名次 ' || v_n || ' 人（期望 0、5）' || E'\n';

  v_msg := 'ⓐ 結算：通過 ' || v_ok || ' / ' || v_all || E'\n' || v_msg;
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then perform set_config('migi.a', v_msg, true);
  else perform set_config('migi.a', v_msg || '🔴 中途出錯：' || sqlstate || ' ' || sqlerrm, true); end if;
end $$;

-- ⓒ 全勤的負對照：賽季橫跨 8、9 兩個月，而大家只在 9 月打過 ⇒ 沒有人可以拿到全勤
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_msg text := ''; v_n int; v_std int; r jsonb;
begin
  update public.rank_seasons set starts_at = '2026-08-01 00:00+08', ends_at = '2026-10-01 00:00+08'
   where org_id = v_org and code = '2026H2';
  update public.members set is_test = false
   where id in ('526aa8b9-cc93-4327-b878-6d21d399af8e','218378e1-fb6c-43fb-b642-99fdbf5c52b1','d0db928e-5a75-4535-90d4-93ede67790a8',
                '69016205-afde-4036-95a6-5893c9d0e5fe','d73fdac2-d6b9-4b8a-bcff-b19c2786056f');
  r := public.sweep_season_close_tx();
  select count(*) into v_std from public.season_standings where org_id = v_org and season = '2026H2';
  select count(*) into v_n from public.member_achievements ma join public.achievements a on a.id = ma.achievement_id
   where a.code = 'season_02' and ma.status = 'unlocked';
  v_msg := case when v_std = 5 and v_n = 0 then '✅' else '🔴' end
        || ' 8～9 月的賽季：結算了 ' || v_std || ' 人（期望 5，否則這一格測不到東西）、拿到全勤 ' || v_n || ' 人（期望 0）';
  v_msg := 'ⓒ 全勤負對照：通過 ' || case when v_std = 5 and v_n = 0 then 1 else 0 end || ' / 1' || E'\n' || v_msg || E'\n';
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then perform set_config('migi.c', v_msg, true);
  else perform set_config('migi.c', v_msg || '🔴 中途出錯：' || sqlstate || ' ' || sqlerrm, true); end if;
end $$;

-- ⓑ 賽季首戰
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  x uuid := '526aa8b9-cc93-4327-b878-6d21d399af8e';   -- 測試04（09-03 就打過）
  z uuid := 'd0db928e-5a75-4535-90d4-93ede67790a8';   -- 測試03（第一場在 09-06）
  v_msg text := ''; v_ok int := 0; v_all int := 0; v_sx uuid; v_sz uuid; v_hx boolean; v_hz boolean;
begin
  update public.rank_seasons set starts_at = '2026-09-06 00:00+08' where org_id = v_org and code = '2026H2';
  select ts.id into v_sx from public.session_players sp join public.table_sessions ts on ts.id = sp.session_id
   where sp.member_id = x and ts.status = 'completed' and ts.deleted_at is null and ts.ended_at >= '2026-09-06 00:00+08'
   order by ts.ended_at limit 1;
  select ts.id into v_sz from public.session_players sp join public.table_sessions ts on ts.id = sp.session_id
   where sp.member_id = z and ts.status = 'completed' and ts.deleted_at is null
   order by ts.ended_at limit 1;
  if v_sx is null or v_sz is null then
    raise exception '🔴 找不到樣本場次（測試04 本季第一場 %、測試03 第一場 %）', v_sx, v_sz;
  end if;
  perform public._ach_session_events(v_sx);
  if v_sz <> v_sx then perform public._ach_session_events(v_sz); end if;
  select exists (select 1 from public.member_achievements ma join public.achievements a on a.id = ma.achievement_id
                  where ma.member_id = x and a.code = 'season_01' and ma.status = 'unlocked') into v_hx;
  select exists (select 1 from public.member_achievements ma join public.achievements a on a.id = ma.achievement_id
                  where ma.member_id = z and a.code = 'season_01' and ma.status = 'unlocked') into v_hz;
  v_all := v_all + 1;
  if v_hx and not v_hz then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' 測試04（之前打過）' || case when v_hx then '拿到' else '沒拿到' end
        || '、測試03（第一場就在本季）' || case when v_hz then '拿到' else '沒拿到' end || '（期望 拿到、沒拿到）' || E'\n';

  v_msg := 'ⓑ 賽季首戰：通過 ' || v_ok || ' / ' || v_all || E'\n' || v_msg;
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then perform set_config('migi.b', v_msg, true);
  else perform set_config('migi.b', v_msg || '🔴 中途出錯：' || sqlstate || ' ' || sqlerrm, true); end if;
end $$;

select coalesce(nullif(current_setting('migi.a', true), ''), '🔴 ⓐ 沒有訊息') || E'\n'
    || coalesce(nullif(current_setting('migi.c', true), ''), '🔴 ⓒ 沒有訊息') || E'\n'
    || coalesce(nullif(current_setting('migi.b', true), ''), '🔴 ⓑ 沒有訊息') as "行為測試";
