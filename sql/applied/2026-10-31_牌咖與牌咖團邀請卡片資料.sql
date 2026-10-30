/* ============================================================
   牌咖與牌咖團的 LINE 邀請改送卡片 —— 產生連結時多回卡片要畫的資料
   2026-10-31 使用者：「牌咖與牌咖團也改卡片」

   ── 改了什麼 ──────────────────────────────────────
   create_buddy_invite_link_tx()  多回三個（邀請人自己的）：
     rank         段位文字（members.rank，例：金牌熊 II）；沒有就是 null
     season_rank  本季全國排名（跟排行榜、成績頁「全國排名」同一支 season_rank_rows_display_tx）；不在榜上就是 null
     win_pct      本季平均勝率（跟成績頁同一個算法：本季有積分的場數 scored 滿 min_games 才算，wins ÷ scored 四捨五入）
                  🔴 邀請人把「誰能看我的成績」設成「只有自己」⇒ 一律 null（邀請卡是傳給還不是牌咖的人）
   create_team_invite_link_tx(p_team_id)  多回三個：
     leader_name  團長暱稱
     member_count 目前團員人數（還沒離團的）
     my_name      發邀請的人（可能是副團長）—— 卡片開頭「某某邀你加入牌咖團」

   · 卡片上哪一項是 null 就不畫那一列，三項都沒有就整塊不畫（前端 lib/linecard.js）
   · 簽名都沒變 ⇒ CREATE OR REPLACE，不用 DROP、授權不會掉
   · 原本的擋牆（未登入、20 條上限、團長或副團長才能發）一行沒動
   ============================================================ */

create or replace function public.create_buddy_invite_link_tx()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_me    uuid := public.current_member_id();
  v_org   uuid := public.current_org_id();
  v_open  int;
  v_token text;
  v_exp   timestamptz;
  v_name  text;
  v_rank  text;
  v_see   text;
  v_from  timestamptz;
  v_srank int;
  v_core  jsonb;
  v_scored int;
  v_wins  int;
  v_min   int;
  v_pct   int;
begin
  /* 牌咖頁「LINE 邀請朋友」（2026-10-14）：每按一次拿一條新的一次性連結 */
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  select count(*) into v_open from public.buddy_invite_links l
   where l.created_by = v_me and l.used_at is null and l.expires_at > now();
  if v_open >= 20 then
    return jsonb_build_object('ok', false, 'reason', 'too_many_links',
      'message', '你還有很多條沒用掉的邀請連結，等朋友點完再發新的');
  end if;

  v_token := replace(gen_random_uuid()::text, '-', '');   -- 32 個 16 進位字元，122 位元隨機
  insert into public.buddy_invite_links (org_id, token, created_by)
  values (v_org, v_token, v_me)
  returning expires_at into v_exp;
  select display_name, rank, see_score into v_name, v_rank, v_see from public.members where id = v_me;

  /* 2026-10-31：邀請卡片上的三項（邀請人自己的）。 */
  v_from := (public.current_season_tx(v_org) ->> 'starts_at')::timestamptz;
  if v_from is not null then
    select r.rank_no into v_srank
      from public.season_rank_rows_display_tx(v_org, v_from, null) r
     where r.member_id = v_me;
  end if;
  if coalesce(v_see, '') <> '只有自己' then
    v_core   := public._member_stats_core(v_org, v_me);
    v_scored := nullif(v_core -> 'season' ->> 'scored', '')::int;
    v_wins   := nullif(v_core -> 'season' ->> 'wins', '')::int;
    v_min    := coalesce(nullif(v_core ->> 'min_games', '')::int, 0);
    if v_scored is not null and v_scored > 0 and v_scored >= v_min then
      v_pct := round(coalesce(v_wins, 0) * 100.0 / v_scored)::int;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'token', v_token, 'expires_at', v_exp, 'my_name', v_name,
    'rank', v_rank, 'season_rank', v_srank, 'win_pct', v_pct);
end $function$;

create or replace function public.create_team_invite_link_tx(p_team_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_me    uuid := public.current_member_id();
  v_org   uuid := public.current_org_id();
  v_team  record;
  v_open  int;
  v_token text;
  v_exp   timestamptz;
  v_leader text;
  v_count int;
  v_name  text;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  select t.id, t.name into v_team from public.teams t
   where t.id = p_team_id and t.org_id = v_org and t.deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;
  -- 與 invite_to_team_tx 同一個判準：團長或副團長
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = v_me and tm.left_at is null
                    and tm.role in ('leader', 'co_leader')) then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長或副團長可以邀請');
  end if;
  select count(*) into v_open from public.team_invite_links l
   where l.team_id = p_team_id and l.used_at is null and l.expires_at > now();
  if v_open >= 20 then
    return jsonb_build_object('ok', false, 'reason', 'too_many_links',
      'message', '這個團還有很多條沒用掉的邀請連結，等朋友點完再發新的');
  end if;

  v_token := replace(gen_random_uuid()::text, '-', '');   -- 32 個 16 進位字元，122 位元隨機
  insert into public.team_invite_links (org_id, team_id, token, created_by)
  values (v_org, p_team_id, v_token, v_me)
  returning expires_at into v_exp;

  /* 2026-10-31：邀請卡片上的團長與團員人數 */
  select m.display_name into v_leader
    from public.team_members tm join public.members m on m.id = tm.member_id
   where tm.team_id = p_team_id and tm.left_at is null and tm.role = 'leader'
   limit 1;
  select count(*) into v_count from public.team_members tm
   where tm.team_id = p_team_id and tm.left_at is null;
  -- 發邀請的人（可能是副團長，不一定是團長）—— 卡片開頭「某某邀你加入牌咖團」
  select display_name into v_name from public.members where id = v_me;

  return jsonb_build_object('ok', true, 'token', v_token, 'expires_at', v_exp, 'team_name', v_team.name,
    'leader_name', v_leader, 'member_count', v_count, 'my_name', v_name);
end $function$;

/* ── 驗證（只讀，不 raise）──────────────────────────
   ① 兩支都只有一個版本、仍是 SECURITY DEFINER
   ② 新欄位真的寫進去了（看回傳的那一行，不是看註解）
   ③ authenticated 還叫得動（CREATE OR REPLACE 不會掉授權，這一格確認）
   ④ 原本的擋牆還在：20 條上限、團長或副團長 */
select string_agg(x, E'\n' order by n) as "驗證" from (
  select 1 n, case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
                          and proname in ('create_buddy_invite_link_tx','create_team_invite_link_tx')) = 2
                    and (select bool_and(prosecdef) from pg_proc where pronamespace = 'public'::regnamespace
                          and proname in ('create_buddy_invite_link_tx','create_team_invite_link_tx'))
              then '✅ ① 兩支各一個版本、都是 SECURITY DEFINER' else '🔴 ① 版本數或 DEFINER 不對' end x
  union all
  select 2, case when pg_get_functiondef('public.create_buddy_invite_link_tx()'::regprocedure) ~ '''season_rank'', v_srank, ''win_pct'', v_pct'
                  and pg_get_functiondef('public.create_team_invite_link_tx(uuid)'::regprocedure) ~ '''leader_name'', v_leader, ''member_count'', v_count, ''my_name'', v_name'
              then '✅ ② 兩支的回傳都多了卡片要的欄位' else '🔴 ② 新欄位沒進回傳' end
  union all
  select 3, case when has_function_privilege('authenticated', 'public.create_buddy_invite_link_tx()', 'execute')
                  and has_function_privilege('authenticated', 'public.create_team_invite_link_tx(uuid)', 'execute')
              then '✅ ③ 登入的會員叫得動' else '🔴 ③ authenticated 叫不動了' end
  union all
  select 4, case when pg_get_functiondef('public.create_buddy_invite_link_tx()'::regprocedure) ~ 'v_open >= 20'
                  and pg_get_functiondef('public.create_team_invite_link_tx(uuid)'::regprocedure) ~ 'leader'', ''co_leader'''
              then '✅ ④ 原本的擋牆還在（20 條上限、團長或副團長）' else '🔴 ④ 擋牆不見了' end
) t;
