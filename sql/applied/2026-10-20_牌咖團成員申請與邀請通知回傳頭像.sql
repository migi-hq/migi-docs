-- ════════════════════════════════════════════════════════════════════
-- 牌咖團成員、入團申請、牌咖／入團邀請通知：回傳真實頭像（2026-10-20 使用者）
--
-- 會員 App 這三處一直畫預設小熊，因為後端根本沒回頭像欄位：
--   · get_team_tx            團員名冊（members[]）
--   · list_team_requests_tx  團長看到的待審核（requests[]）
--   · list_notifications_tx  通知（多一個 actor：牌咖邀請 ＝ 邀請人；入團申請 ＝ 申請的人；入團邀請 ＝ 邀請的人）
-- 欄位名跟其他函式一致（list_recent_players_tx 那一套）：avatar_url／avatar_bear／avatar_source／avatar_photo_path。
-- 隱藏帳號的人 avatar_source 本來就是 'hidden'，前端照樣畫問號，不用另外處理。
--
-- 三支簽名都不變 ⇒ CREATE OR REPLACE，授權不會掉；其餘邏輯逐字照抄線上版（只加欄位）。
-- ════════════════════════════════════════════════════════════════════

create or replace function public.get_team_tx(p_team_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_me      uuid := public.current_member_id();
  v_card    jsonb;
  v_role    text;
  v_from    timestamptz;
  v_members jsonb;
  v_pending int := 0;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  v_card := public._team_card(p_team_id);
  if v_card is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;

  select tm.role into v_role
    from public.team_members tm
   where tm.team_id = p_team_id and tm.member_id = v_me and tm.left_at is null;

  if v_role is null then
    return jsonb_build_object('ok', true, 'team', v_card, 'my_role', null,
                              'members', '[]'::jsonb, 'can_claim_leader', false);
  end if;

  v_from := (date_trunc('month', (now() at time zone 'Asia/Taipei')) at time zone 'Asia/Taipei');

  /* 🔴 排序用**明寫的名次**不用字串序。
     `'co_leader' < 'leader' < 'member'` ⇒ 字串序會把副團長排到團長上面，
     而在這之前它「看起來是對的」只是因為 leader 剛好排在 member 前面。 */
  select coalesce(jsonb_agg(x order by (x->>'role_sort')::int, x->>'joined_at'), '[]'::jsonb)
    into v_members
    from (
      select jsonb_build_object(
               /* 🔴 只有團長拿得到 member_id —— 不需要身分就不要交出身分
                  （2026-09-04 排行榜定的原則）。只有他要按移除與轉讓。 */
               'member_id', case when v_role = 'leader' then tm.member_id else null end,
               'is_me',     tm.member_id = v_me,
               'nickname',  m.display_name,
               'rank',      m.rank,
               'title',     m.title,
               /* 🆕 2026-10-20：真實頭像（原本前端一律畫預設小熊） */
               'avatar_url', m.avatar_url, 'avatar_bear', m.avatar_bear,
               'avatar_source', m.avatar_source, 'avatar_photo_path', m.avatar_photo_path,
               'role',      tm.role,
               'role_sort', case tm.role when 'leader' then 0 when 'co_leader' then 1 else 2 end,
               'joined_at', tm.joined_at,
               /* 🔴 名冊**不給「上次來店」** —— 手遊公會名冊都有那一欄，
                  但 2026-08-26 為常來時段畫的線擋著：對別人的單向側寫
                  不給客人看。本月貢獻是**共同事實**，所以可以。 */
               'month_contrib', (
                 select count(*) from public._team_session_ids(p_team_id) ts
                  where ts.played_at >= v_from
                    and exists (select 1 from public.session_players sp
                                 where sp.session_id = ts.session_id
                                   and sp.member_id = tm.member_id))) as x
        from public.team_members tm
        join public.members m on m.id = tm.member_id
       where tm.team_id = p_team_id and tm.left_at is null
    ) s;

  if v_role = 'leader' then
    select count(*) into v_pending
      from public.team_requests r
     where r.team_id = p_team_id and r.status = 'pending'
       and r.kind = 'apply' and r.expires_at > now();
  end if;

  return jsonb_build_object('ok', true, 'team', v_card, 'my_role', v_role,
                            'members', v_members, 'pending_count', v_pending,
                            /* ✅ 只回「我現在能不能接任」。三種不能的原因
                               都回 false，看不出是哪一種 —— 最小揭露。 */
                            'can_claim_leader',
                            public._team_claim_check(p_team_id, v_me) is null);
end $function$;


create or replace function public.list_team_requests_tx(p_team_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_me   uuid := public.current_member_id();
  v_rows jsonb;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = v_me
                    and tm.left_at is null and tm.role = 'leader') then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長看得到');
  end if;

  perform public._team_expire_requests(p_team_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'request_id', r.id,
           /* 🔴 這裡回 member_id 是刻意的 —— 團長要按核准，
              而核准吃的是 request_id。但名冊那邊的原則同樣適用：
              這一頁只有團長叫得動。 */
           'member_id',  r.member_id,
           'nickname',   m.display_name,
           'rank',       m.rank,
           'title',      m.title,
           /* 🆕 2026-10-20：真實頭像 */
           'avatar_url', m.avatar_url, 'avatar_bear', m.avatar_bear,
           'avatar_source', m.avatar_source, 'avatar_photo_path', m.avatar_photo_path,
           'kind',       r.kind,
           'created_at', r.created_at,
           'expires_at', r.expires_at) order by r.created_at), '[]'::jsonb)
    into v_rows
    from public.team_requests r
    join public.members m on m.id = r.member_id
   where r.team_id = p_team_id and r.status = 'pending' and r.kind = 'apply';

  return jsonb_build_object('ok', true, 'requests', v_rows);
end $function$;


create or replace function public.list_notifications_tx(p_org_id uuid, p_member uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
begin
  -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
  p_member := public.current_member_id();
  if p_member is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', n.id, 'type', n.type, 'payload', n.payload, 'ref_id', n.ref_id,
      'unread', (n.read_at is null), 'done', (n.done_at is not null), 'created_at', n.created_at,
      /* 這則邀請回覆了沒。null = 不適用（純告知類）或查不到對應邀請。
         前端把 null 與 'pending' 都當成待處理。 */
      'invite_status', case
        when n.type = 'buddy_req' then (
          select bi.status
            from buddy_invites bi
           where bi.inviter_id = n.ref_id
             and bi.invitee_id = n.member_id
           order by bi.created_at desc
           limit 1)
        /* 🆕 團的申請與邀請。`ref_id` 直接就是 team_requests.id。
           ⚠ 過期的要說「過期」不要說「待處理」—— 清理是在別的動作
             順手做的（沒有排程），所以這裡一定會看到還沒被收掉的 pending。 */
        when n.type = 'team_req' then (
          select case when r.status = 'pending' and r.expires_at <= now()
                      then 'expired' else r.status end
            from team_requests r
           where r.id = n.ref_id)
        end,
      /* 🆕 2026-10-20：這則通知「是誰」的頭像（前端畫真的頭像，不再一律預設小熊）
           牌咖邀請 ref_id ＝ 邀請人；入團申請（給團長）＝ 申請的人；入團邀請（給被邀的人）＝ 邀請的人。
           其他類型沒有「誰」，回 null */
      'actor', (
        select jsonb_build_object('avatar_url', a.avatar_url, 'avatar_bear', a.avatar_bear,
                                  'avatar_source', a.avatar_source, 'avatar_photo_path', a.avatar_photo_path,
                                  'rank', a.rank)
          from members a
         where a.id = case
                 when n.type = 'buddy_req' then n.ref_id
                 when n.type = 'team_req' then (
                   select case when r.kind = 'invite' then r.created_by else r.member_id end
                     from team_requests r where r.id = n.ref_id)
               end)
    ) order by n.created_at desc)
    from app_notifications n
    where n.member_id = p_member and n.org_id = p_org_id
      and n.created_at > now() - interval '30 days'
  ), '[]'::jsonb);
end $function$;

-- 驗證（單一 SELECT）：三支各 1 個版本、都有頭像欄位、授權跟改之前一樣
select
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
              and proname in ('get_team_tx', 'list_team_requests_tx', 'list_notifications_tx')) = 3
       then '✅ 三支各 1 個版本' else '🔴 版本數不對' end as "①",
  case when pg_get_functiondef('public.get_team_tx(uuid)'::regprocedure) ~ '''avatar_photo_path'''
        and pg_get_functiondef('public.list_team_requests_tx(uuid)'::regprocedure) ~ '''avatar_photo_path'''
       then '✅ 團員名冊與待審核都回頭像' else '🔴 名冊或待審核沒有頭像' end as "②",
  case when pg_get_functiondef('public.list_notifications_tx(uuid,uuid)'::regprocedure) ~ '''actor'''
       then '✅ 通知多了 actor（邀請人／申請人的頭像）' else '🔴 通知沒有 actor' end as "③",
  case when not has_function_privilege('anon', 'public.get_team_tx(uuid)', 'execute')
        and has_function_privilege('authenticated', 'public.get_team_tx(uuid)', 'execute')
        and not has_function_privilege('anon', 'public.list_team_requests_tx(uuid)', 'execute')
        and has_function_privilege('authenticated', 'public.list_team_requests_tx(uuid)', 'execute')
        and has_function_privilege('authenticated', 'public.list_notifications_tx(uuid,uuid)', 'execute')
       then '✅ 授權跟改之前一樣（名冊、待審核只給登入的人）' else '🔴 授權變了' end as "④";
