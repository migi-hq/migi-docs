/* ============================================================
   行為測試：成就第 2 批（交易內收一場真的牌局，**全部回滾**）
   2026-09-30 · 配 sql/pending/2026-09-30_成就第2批_牌局局勢段位.sql（先跑那份）

   樣本：高雄自由店 A1 那一場（1ea984c6…，3 將、67 局、測試帳號四位）
   在交易裡把第 3 將標成打完 → 呼叫真的收桌函式 → 看每個人解鎖了哪幾枚。
   期望值是 09-30 用唯讀查詢從那 67 局**另外算出來的**，不是照著實作抄的：

     座位  會員      每一將累積          名次       大牌  莊家胡  最大連莊  拉莊
      1   測試02   −30 → −120 → −120   3,2,3        1      1        1       3
      2   測試03   100 → −160 → −280   2,4,4        0      0        0       0
      3   測試04   130 →  420 →  340   1,1,1        0     18        5       4
      4   測試01  −200 → −140 →   60   4,3,2        2      6        4       6

   ⓐ 有記分的級距（交易內把這場換成非純娛樂）：每一類都要亮
      另外造兩個條件：測試02 段位分先設 800（結算後是鑽石熊）、測試01 當過賽季冠軍（假賽季 1990）
   ⓑ 維持純娛樂（負對照）：積分類、局勢轉折類一枚都不可以亮；胡牌／連莊類照常

   ⚠ 故意 raise 回滾（硬規則 1.8 的例外），訊息設在 exception handler 裡（硬規則 3.9）
   ============================================================ */

-- ⓐ 有記分
do $$
declare
  v_sid uuid := '1ea984c6-e15e-4888-a4d6-9f99f0860120';
  v_org uuid; v_stake uuid; v_r jsonb; v_msg text := ''; v_ok int := 0; v_all int := 0;
  m01 uuid; m02 uuid; m03 uuid; m04 uuid; v_who uuid; v_has boolean; v_n int;
  x record;
begin
  perform set_config('request.jwt.claims', '', true);
  select org_id into v_org from public.table_sessions where id = v_sid and status = 'open';
  if v_org is null then
    perform set_config('migi.a', '🔴 A1 那一場已經不是進行中（可能已經收桌），這份測不了', true);
    return;
  end if;
  select id into m01 from public.members where line_user_id = 'TEST-01';
  select id into m02 from public.members where line_user_id = 'TEST-02';
  select id into m03 from public.members where line_user_id = 'TEST-03';
  select id into m04 from public.members where line_user_id = 'TEST-04';

  select id into v_stake from public.stake_levels where org_id = v_org and is_hygiene = false limit 1;
  if v_stake is null then
    perform set_config('migi.a', '🔴 找不到非純娛樂的級距，這份測不了', true);
    return;
  end if;
  update public.table_sessions set stake_level_id = v_stake where id = v_sid;
  update public.members set rating = 800 where id = m02;
  insert into public.rank_seasons (code, org_id, label, starts_at, ends_at)
  values ('TEST-1990', v_org, '測試用賽季', '1990-01-01', '1990-06-01');
  insert into public.season_champions (season, org_id, member_id, rating, awarded_at)
  values ('TEST-1990', v_org, m01, 999, now());

  update public.session_rounds set status = 'finished', finished_at = now()
   where session_id = v_sid and round_no = 3;
  v_r := public.settle_session_tx(v_sid, null, false);
  v_all := v_all + 1;
  if coalesce((v_r ->> 'ok')::boolean, false) then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' 收桌 → ' || left(v_r::text, 120) || E'\n';

  -- 判定有沒有出錯（出錯會寫 ach_error）
  select count(*) into v_n from public.app_events
   where event = 'ach_error' and props ->> 'session_id' = v_sid::text;
  v_all := v_all + 1;
  if v_n = 0 then v_ok := v_ok + 1; v_msg := v_msg || '✅ 判定沒有出錯' || E'\n';
  else v_msg := v_msg || '🔴 判定出錯 ' || v_n || ' 次（看 app_events 的 ach_error）' || E'\n'; end if;

  for x in select * from (values
      ('測試04','game_07',true), ('測試04','game_10',true), ('測試04','game_19',true), ('測試04','game_21',true),
      ('測試04','game_22',true), ('測試04','game_24',true), ('測試04','swing_01',true), ('測試04','swing_02',true),
      ('測試04','swing_05',true), ('測試04','rank_14',true), ('測試04','rank_16',true),
      ('測試04','game_23',false), ('測試04','game_20',false), ('測試04','swing_03',false), ('測試04','swing_08',false), ('測試04','swing_04',false),
      ('測試01','game_17',true), ('測試01','game_19',true), ('測試01','game_21',true), ('測試01','game_24',true),
      ('測試01','swing_04',true), ('測試01','swing_06',true), ('測試01','swing_07',true), ('測試01','rank_14',true),
      ('測試01','rank_16',false), ('測試01','game_22',false), ('測試01','game_07',false),
      ('測試02','game_19',true), ('測試02','game_24',true), ('測試02','rank_03',true), ('測試02','rank_04',true),
      ('測試02','rank_05',true), ('測試02','rank_07',true), ('測試02','rank_08',true), ('測試02','rank_10',true), ('測試02','rank_16',true),
      ('測試02','rank_14',false), ('測試02','rank_09',false), ('測試02','game_21',false),
      ('測試03','rank_14',true), ('測試03','rank_16',true),
      ('測試03','game_07',false), ('測試03','game_19',false), ('測試03','game_21',false), ('測試03','game_24',false),
      ('測試03','swing_01',false), ('測試03','swing_04',false), ('測試03','game_10',false)
    ) as t(who, code, want)
  loop
    v_who := case x.who when '測試01' then m01 when '測試02' then m02 when '測試03' then m03 else m04 end;
    select exists (select 1 from public.member_achievements ma join public.achievements a on a.id = ma.achievement_id
                    where ma.member_id = v_who and a.code = x.code and ma.status = 'unlocked') into v_has;
    v_all := v_all + 1;
    if v_has = x.want then v_ok := v_ok + 1;
    else v_msg := v_msg || '🔴 ' || x.who || ' ' || x.code || ' 期望' || case when x.want then '解鎖' else '不解鎖' end
               || '，實際' || case when v_has then '解鎖' else '沒有' end || E'\n'; end if;
  end loop;

  -- 參考：每個人這一批解鎖了什麼（不判對錯，給人看）
  for x in select m.display_name as nm,
                  (select string_agg(a.code, ',' order by a.sort) from public.member_achievements ma
                     join public.achievements a on a.id = ma.achievement_id
                    where ma.member_id = m.id and ma.status = 'unlocked' and a.code ~ '^(game|swing|rank)_') as codes
             from public.members m where m.id in (m01, m02, m03, m04) order by m.display_name
  loop
    v_msg := v_msg || '　' || x.nm || '：' || coalesce(x.codes, '（無）') || E'\n';
  end loop;

  v_msg := 'ⓐ 有記分：通過 ' || v_ok || ' / ' || v_all || E'\n' || v_msg;
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then perform set_config('migi.a', v_msg, true);
  else perform set_config('migi.a', v_msg || '🔴 中途出錯：' || sqlstate || ' ' || sqlerrm, true); end if;
end $$;

-- ⓑ 純娛樂（負對照）
do $$
declare
  v_sid uuid := '1ea984c6-e15e-4888-a4d6-9f99f0860120';
  v_r jsonb; v_msg text := ''; v_ok int := 0; v_all int := 0;
  m01 uuid; m04 uuid; v_who uuid; v_has boolean;
  x record;
begin
  perform set_config('request.jwt.claims', '', true);
  if not exists (select 1 from public.table_sessions where id = v_sid and status = 'open') then
    perform set_config('migi.b', '🔴 A1 那一場已經不是進行中，這份測不了', true);
    return;
  end if;
  select id into m01 from public.members where line_user_id = 'TEST-01';
  select id into m04 from public.members where line_user_id = 'TEST-04';

  update public.session_rounds set status = 'finished', finished_at = now()
   where session_id = v_sid and round_no = 3;
  v_r := public.settle_session_tx(v_sid, null, false);

  for x in select * from (values
      -- 純娛樂：積分類、局勢轉折類不可以亮
      ('測試04','game_10',false), ('測試04','swing_01',false), ('測試04','swing_02',false), ('測試04','swing_05',false),
      ('測試01','swing_04',false), ('測試01','swing_06',false), ('測試01','swing_07',false),
      -- 胡牌／連莊／名次照常（證明判定有跑，不是整支沒動）
      ('測試04','game_07',true), ('測試04','game_19',true), ('測試04','game_21',true), ('測試04','game_22',true),
      ('測試04','game_24',true), ('測試01','game_17',true)
    ) as t(who, code, want)
  loop
    v_who := case x.who when '測試01' then m01 else m04 end;
    select exists (select 1 from public.member_achievements ma join public.achievements a on a.id = ma.achievement_id
                    where ma.member_id = v_who and a.code = x.code and ma.status = 'unlocked') into v_has;
    v_all := v_all + 1;
    if v_has = x.want then v_ok := v_ok + 1;
    else v_msg := v_msg || '🔴 ' || x.who || ' ' || x.code || ' 期望' || case when x.want then '解鎖' else '不解鎖' end
               || '，實際' || case when v_has then '解鎖' else '沒有' end || E'\n'; end if;
  end loop;

  v_msg := 'ⓑ 純娛樂：通過 ' || v_ok || ' / ' || v_all || '（收桌 ' || coalesce(v_r ->> 'ok', '?') || '）' || E'\n' || v_msg;
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then perform set_config('migi.b', v_msg, true);
  else perform set_config('migi.b', v_msg || '🔴 中途出錯：' || sqlstate || ' ' || sqlerrm, true); end if;
end $$;

select coalesce(nullif(current_setting('migi.a', true), ''), '🔴 ⓐ 沒有訊息')
       || E'\n' ||
       coalesce(nullif(current_setting('migi.b', true), ''), '🔴 ⓑ 沒有訊息') as "行為測試";
