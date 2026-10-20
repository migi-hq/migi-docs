-- ════════════════════════════════════════════════════════════════════
-- 副團長也能看、也能審核入團申請（2026-10-20 使用者：「副團長也要」）
--
-- 原本（2026-09-14 定）副團長只多「邀請人入團」一件事，待審核與審核只有團長。改成：
--   · list_team_requests_tx   待審核名單：團長、副團長都看得到
--   · respond_team_request_tx 核准／回絕申請（kind = 'apply'）：團長、副團長都可以
--   · get_team_tx             團詳情的 pending_count：副團長也算；名冊每位團員都回 member_id（團員列表點了看個人檔案）
--   · apply_team_tx           有人申請時：團長 ＋ 每一位副團長都收到通知（原本只有團長）
-- 誰先審就算誰的（decided_by 記那個人）；其他人那則通知的狀態讀同一筆申請，會一起變成已接受／已拒絕。
-- 其餘權限不動：移除團員、改團名團徽、轉讓團長仍然只有團長。
--
-- 四支簽名都不變 ⇒ CREATE OR REPLACE，授權不會掉；其餘邏輯逐字照抄線上版。
-- ════════════════════════════════════════════════════════════════════

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
  /* 🆕 2026-10-20：副團長也看得到（原本只有團長） */
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = v_me
                    and tm.left_at is null and tm.role in ('leader', 'co_leader')) then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長、副團長看得到');
  end if;

  perform public._team_expire_requests(p_team_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'request_id', r.id,
           /* 🔴 這裡回 member_id 是刻意的 —— 審核的人要按核准，
              而核准吃的是 request_id。但名冊那邊的原則同樣適用：
              這一頁只有團長、副團長叫得動。 */
           'member_id',  r.member_id,
           'nickname',   m.display_name,
           'rank',       m.rank,
           'title',      m.title,
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


create or replace function public.respond_team_request_tx(p_request_id uuid, p_accept boolean)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_me   uuid := public.current_member_id();
  v_org  uuid := public.current_org_id();
  v_r    record;
  v_t    record;
  v_cnt  int;
  v_lead uuid;
  v_name text;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  perform public._team_expire_requests(null);

  select r.* into v_r from public.team_requests r where r.id = p_request_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這筆邀請');
  end if;
  if v_r.status <> 'pending' then
    /* ⚠ 話術要說出**它現在是什麼**，不要只說「已處理」——
       客人看到「已過期」與「已被拒絕」要做的事不一樣。 */
    return jsonb_build_object('ok', false, 'reason', 'already_decided', 'status', v_r.status,
                              'message', case v_r.status
                                when 'expired'   then '這筆邀請已經過期了'
                                when 'accepted'  then '這筆已經答應過了'
                                when 'rejected'  then '這筆已經回絕過了'
                                else '這筆已經處理過了' end);
  end if;

  select t.id, t.name, t.member_limit into v_t
    from public.teams t where t.id = v_r.team_id and t.deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'team_gone', 'message', '這個團已經解散了');
  end if;

  if v_r.kind = 'apply' then
    /* 🆕 2026-10-20：副團長也可以審核（原本只有團長） */
    if not exists (select 1 from public.team_members tm
                    where tm.team_id = v_r.team_id and tm.member_id = v_me
                      and tm.left_at is null and tm.role in ('leader', 'co_leader')) then
      return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長、副團長可以審核');
    end if;
  else
    if v_r.member_id <> v_me then
      return jsonb_build_object('ok', false, 'reason', 'not_yours', 'message', '這不是給你的邀請');
    end if;
  end if;

  if not p_accept then
    update public.team_requests set status = 'rejected', decided_by = v_me, decided_at = now()
     where id = p_request_id;
    /* 🔴 刻意不發通知，理由見檔頭。 */
    return jsonb_build_object('ok', true, 'accepted', false, 'message', '已回絕');
  end if;

  if exists (select 1 from public.team_members tm
              where tm.team_id = v_r.team_id and tm.member_id = v_r.member_id and tm.left_at is null) then
    update public.team_requests set status = 'accepted', decided_by = v_me, decided_at = now()
     where id = p_request_id;
    return jsonb_build_object('ok', true, 'accepted', true, 'message', '他已經在團裡了');
  end if;

  select count(*) into v_cnt from public.team_members tm
   where tm.team_id = v_r.team_id and tm.left_at is null;
  if v_cnt >= v_t.member_limit then
    return jsonb_build_object('ok', false, 'reason', 'team_full', 'message', '這個團滿了');
  end if;

  select count(*) into v_cnt from public.team_members tm
    join public.teams t2 on t2.id = tm.team_id and t2.deleted_at is null
   where tm.member_id = v_r.member_id and tm.left_at is null;
  if v_cnt >= 10 then
    return jsonb_build_object('ok', false, 'reason', 'too_many_teams',
                              'message', '他已經加入 10 個牌咖團了');
  end if;

  update public.team_requests set status = 'accepted', decided_by = v_me, decided_at = now()
   where id = p_request_id;
  insert into public.team_members (org_id, team_id, member_id)
  values (v_org, v_r.team_id, v_r.member_id);

  /* 通知方向與 `kind` 相反：團長核准 → 通知申請人；本人答應邀請 → 通知團長。 */
  if v_r.kind = 'apply' then
    perform public._team_notify(v_org, v_r.member_id, 'team_ok', v_t.name,
             '你的申請通過了，歡迎加入 ' || v_t.name, v_t.id, v_t.name, null);
  else
    select tm.member_id into v_lead from public.team_members tm
     where tm.team_id = v_t.id and tm.role = 'leader' and tm.left_at is null;
    select display_name into v_name from public.members where id = v_r.member_id;
    if v_lead is not null then
      perform public._team_notify(v_org, v_lead, 'team_ok', v_name,
               v_name || ' 加入了 ' || v_t.name, v_t.id, v_t.name, null);
    end if;
  end if;

  return jsonb_build_object('ok', true, 'accepted', true, 'message', '已加入 ' || v_t.name);
end $function$;


create or replace function public.apply_team_tx(p_team_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_me     uuid := public.current_member_id();
  v_org    uuid := public.current_org_id();
  v_t      record;
  v_cnt    int;
  v_mine   text;
  v_req    uuid;
  v_leader uuid;
  v_name   text;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  select t.id, t.name, t.join_policy, t.member_limit into v_t
    from public.teams t where t.id = p_team_id and t.deleted_at is null and t.org_id = v_org;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;

  if exists (select 1 from public.team_members tm
              where tm.team_id = p_team_id and tm.member_id = v_me and tm.left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'already_member', 'message', '你已經在這個團裡了');
  end if;

  select count(*) into v_cnt from public.team_members tm
    join public.teams t2 on t2.id = tm.team_id and t2.deleted_at is null
   where tm.member_id = v_me and tm.left_at is null;
  if v_cnt >= 10 then
    return jsonb_build_object('ok', false, 'reason', 'too_many_teams',
                              'message', '你已經加入 10 個牌咖團了');
  end if;

  select count(*) into v_cnt from public.team_members tm
   where tm.team_id = p_team_id and tm.left_at is null;
  if v_cnt >= v_t.member_limit then
    return jsonb_build_object('ok', false, 'reason', 'team_full', 'message', '這個團滿了');
  end if;

  perform public._team_expire_requests(p_team_id);
  select display_name into v_name from public.members where id = v_me;

  /* 🎯 團長已經邀過我 ⇒ 我按申請就是答應。不要跳「已經有一筆在談」。 */
  select r.id into v_req from public.team_requests r
   where r.team_id = p_team_id and r.member_id = v_me
     and r.status = 'pending' and r.kind = 'invite';
  if v_req is not null then
    update public.team_requests set status = 'accepted', decided_by = v_me, decided_at = now()
     where id = v_req;
    insert into public.team_members (org_id, team_id, member_id) values (v_org, p_team_id, v_me);
    return jsonb_build_object('ok', true, 'joined', true, 'via', 'invite',
                              'message', '已加入 ' || v_t.name);
  end if;

  if exists (select 1 from public.team_requests r
              where r.team_id = p_team_id and r.member_id = v_me and r.status = 'pending') then
    return jsonb_build_object('ok', false, 'reason', 'already_pending',
                              'message', '你的申請正在等團長審核');
  end if;

  if v_t.join_policy = 'closed' then
    /* ⚠ 這個團本來就不該出現在找團頁（`search_teams_tx` 已經濾掉），
       所以走到這裡通常是舊畫面。話術要講得出下一步。 */
    return jsonb_build_object('ok', false, 'reason', 'closed',
                              'message', '這個團不開放申請，要請團長邀請你');
  end if;

  select tm.member_id into v_leader from public.team_members tm
   where tm.team_id = p_team_id and tm.role = 'leader' and tm.left_at is null;

  if v_t.join_policy = 'open' then
    insert into public.team_members (org_id, team_id, member_id) values (v_org, p_team_id, v_me);
    if v_leader is not null then
      perform public._team_notify(v_org, v_leader, 'team_ok', v_name,
               v_name || ' 加入了 ' || v_t.name, p_team_id, v_t.name, null);
    end if;
    return jsonb_build_object('ok', true, 'joined', true, 'via', 'open',
                              'message', '已加入 ' || v_t.name);
  end if;

  insert into public.team_requests (org_id, team_id, member_id, kind, created_by)
  values (v_org, p_team_id, v_me, 'apply', v_me)
  returning id into v_req;

  /* 🆕 2026-10-20：團長 ＋ 每一位副團長都收到（副團長也能審核了）。每人一則，ref_id 都指向同一筆申請 */
  perform public._team_notify(v_org, tm.member_id, 'team_req', v_name,
           v_name || ' 想加入 ' || v_t.name, p_team_id, v_t.name, v_req)
     from public.team_members tm
    where tm.team_id = p_team_id and tm.left_at is null and tm.role in ('leader', 'co_leader');

  return jsonb_build_object('ok', true, 'joined', false, 'request_id', v_req,
                            'message', '已送出申請，等團長審核');
end $function$;


/* get_team_tx：pending_count 副團長也數；member_id 每位團員都回（團員列表點了看個人檔案）；其餘同 2026-10-20 補頭像那一版 */
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
               /* 🆕 2026-10-20 使用者：團員列表點了要看個人檔案 ⇒ 每位團員都拿得到 member_id。
                  原本只給團長（2026-09-04「不需要身分就不要交出身分」）；2026-09-20 起會員功能一律只認登入身分，
                  拿到別人的 id 冒用不了，排行榜 09-30 起也回 id。移除／轉讓仍由後端只認團長 */
               'member_id', tm.member_id,
               'is_me',     tm.member_id = v_me,
               'nickname',  m.display_name,
               'rank',      m.rank,
               'title',     m.title,
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

  /* 🆕 2026-10-20：副團長也能審核 ⇒ 也數待審核 */
  if v_role in ('leader', 'co_leader') then
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

-- 驗證（單一 SELECT）：四支各 1 個版本、副團長都放行了、授權跟改之前一樣
select
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
              and proname in ('list_team_requests_tx', 'respond_team_request_tx', 'apply_team_tx', 'get_team_tx')) = 4
       then '✅ 四支各 1 個版本' else '🔴 版本數不對' end as "①",
  case when pg_get_functiondef('public.list_team_requests_tx(uuid)'::regprocedure) ~ 'role in \(''leader'', ''co_leader''\)'
        and pg_get_functiondef('public.respond_team_request_tx(uuid,boolean)'::regprocedure) ~ 'role in \(''leader'', ''co_leader''\)'
       then '✅ 待審核與審核都放行副團長' else '🔴 待審核或審核還只認團長' end as "②",
  case when pg_get_functiondef('public.apply_team_tx(uuid)'::regprocedure) ~ 'role in \(''leader'', ''co_leader''\)'
        and pg_get_functiondef('public.get_team_tx(uuid)'::regprocedure) ~ 'v_role in \(''leader'', ''co_leader''\)'
       then '✅ 申請通知與待審核數字都含副團長' else '🔴 通知或數字還只有團長' end as "③",
  case when pg_get_functiondef('public.get_team_tx(uuid)'::regprocedure) ~ '''member_id'', tm\.member_id,'
       then '✅ 名冊每位團員都回 member_id' else '🔴 名冊的 member_id 還只給團長' end as "⑤",
  case when has_function_privilege('authenticated', 'public.list_team_requests_tx(uuid)', 'execute')
        and has_function_privilege('authenticated', 'public.respond_team_request_tx(uuid,boolean)', 'execute')
        and has_function_privilege('authenticated', 'public.apply_team_tx(uuid)', 'execute')
        and not has_function_privilege('anon', 'public.list_team_requests_tx(uuid)', 'execute')
       then '✅ 授權跟改之前一樣' else '🔴 授權變了' end as "④";
