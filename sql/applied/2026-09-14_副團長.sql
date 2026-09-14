/* ============================================================
   副團長：只能做一件事 —— 邀請人入團
   2026-09-14
   ------------------------------------------------------------
   使用者：「新增一個功能 升為副團長。副團長只有一個功能 邀請人入團」。

   ⚠ **只有一件事**是規格不是省略。所以副團長**不能**：
     審核申請／移除團員／改團名團徽／轉讓團長／解散團／看待審核清單。
     🔴 那些今天都是 `role = 'leader'` 的正向判斷（撈全庫 16 支逐行看過），
       所以**多一個角色值不會讓任何一支自動放行** —— 這一份要改的
       只有 `invite_to_team_tx` 那一支，其餘一個字都不動。
     📌 判準記著：權限寫成「是不是 leader」（正向）時，加角色是安全的；
       寫成「不是 leader 就…」（反向）時，加角色會靜靜擴權。
       這個系統目前**沒有任何一支是反向寫的**，是查過不是假設。

   ── 這份做什麼（四件）─────────────────────────────
   ① `team_members.role` 的 CHECK 多一個值 `co_leader`
   ② `set_team_co_leader_tx` 新增 —— 團長升降副團長
   ③ `invite_to_team_tx` 的守衛放寬成「團長或副團長」
   ④ `get_team_tx` 的名冊排序 —— 見下，這一格不改會出事

   🔴 ④ 不是順便做的：現在那一段是 `order by x->>'role'`（字串序），
     而 `'co_leader' < 'leader' < 'member'`
     ⇒ **副團長會排在團長上面**。字串序今天看起來對，純粹是因為
       `leader` 剛好排在 `member` 前面 —— 那是巧合不是設計
       （同「排序不要靠字母巧合」那一條，收據的檯費就是這樣掉到最後一行的）。

   ⚠ **不設副團長人數上限**：那是團長自己的事，而且副團長做得到的事
     （邀請）本來就是團長做得到的。要限制得先有人說得出「為什麼是 3 個」。
   ============================================================ */

/* ── ① 角色多一個值 ─────────────────────────────── */
alter table public.team_members drop constraint if exists team_members_role_check;
alter table public.team_members add constraint team_members_role_check
  check (role = any (array['leader'::text, 'co_leader'::text, 'member'::text]));

/* ⚠ `uq_team_one_leader` 只認 `role = 'leader'`，所以它照舊只鎖一個團長，
   副團長不受它影響 —— 不需要動那道索引。 */


/* ── ② 團長升／降副團長 ──────────────────────────── */
create or replace function public.set_team_co_leader_tx(
  p_team_id uuid, p_member_id uuid, p_on boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_me   uuid := public.current_member_id();
  v_org  uuid := public.current_org_id();
  v_role text;
  v_tname text;
  v_name text;
  v_n    int;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_member_id is null or p_member_id = v_me then
    return jsonb_build_object('ok', false, 'reason', 'bad_target', 'message', '對象不正確');
  end if;

  /* 🔴 只有團長。副團長**不能**再任命副團長 ——
     那會讓「誰能給權限」有第二個答案，而收回權限的人只有一個。 */
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = v_me
                    and tm.left_at is null and tm.role = 'leader') then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以設定副團長');
  end if;

  select t.name into v_tname from public.teams t
   where t.id = p_team_id and t.deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;

  select tm.role into v_role from public.team_members tm
   where tm.team_id = p_team_id and tm.member_id = p_member_id and tm.left_at is null;
  if v_role is null then
    return jsonb_build_object('ok', false, 'reason', 'not_member', 'message', '他不在這個團裡');
  end if;
  /* 防守性的一格：呼叫者是團長而對象不是自己 ⇒ 走不到這裡
     （`uq_team_one_leader` 保證一團一個團長）。留著是因為那道索引
     哪天被改掉時，這裡要**大聲拒絕**而不是把團長降成副團長。 */
  if v_role = 'leader' then
    return jsonb_build_object('ok', false, 'reason', 'is_leader', 'message', '他是團長');
  end if;

  /* 冪等：已經是了就直接回成功，不要報錯。
     ⚠ 團長連按兩下、或兩台裝置各按一次都會走到這裡。 */
  if (p_on and v_role = 'co_leader') or (not p_on and v_role = 'member') then
    return jsonb_build_object('ok', true, 'changed', false, 'role', v_role,
                              'message', case when p_on then '他已經是副團長了' else '他本來就不是副團長' end);
  end if;

  update public.team_members
     set role = case when p_on then 'co_leader' else 'member' end
   where team_id = p_team_id and member_id = p_member_id and left_at is null;
  get diagnostics v_n = row_count;
  /* 🔴 `update … where` 之後一定要看有沒有真的改到 ——
     `register_member_tx` 就是漏了這一步而謊報成功過一次。 */
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'not_member', 'message', '他不在這個團裡');
  end if;

  /* 通知本人。升上去要講**他現在能做什麼**，不然他不會知道多了什麼。
     ⚠ 用既有的 `team_ok`（純告知、沒有按鈕），不要為此發明新的通知類型。 */
  select display_name into v_name from public.members where id = v_me;
  perform public._team_notify(v_org, p_member_id, 'team_ok', v_tname,
           case when p_on
                then '你成為 ' || v_tname || ' 的副團長了，可以邀請牌咖加入'
                else '你不再是 ' || v_tname || ' 的副團長了' end,
           p_team_id, v_tname, null);

  return jsonb_build_object('ok', true, 'changed', true,
                            'role', case when p_on then 'co_leader' else 'member' end,
                            'message', case when p_on then '已升為副團長' else '已取消副團長' end);
end $$;

/* 🔴 授權逐字比照其他團 RPC（實查 `proacl`：只有 authenticated 與
   service_role，anon 與 PUBLIC 都沒有）。
   ⚠ 新建的函式會從 default privileges **明確拿到 anon**，
     所以兩個方向都要收（硬規則 2.6b）。 */
revoke execute on function public.set_team_co_leader_tx(uuid, uuid, boolean) from public;
revoke execute on function public.set_team_co_leader_tx(uuid, uuid, boolean) from anon;
grant  execute on function public.set_team_co_leader_tx(uuid, uuid, boolean) to authenticated, service_role;


/* ── ③ 邀請：團長或副團長 ────────────────────────── */
/* ⚠ 簽名沒變 ⇒ `CREATE OR REPLACE`，不用 DROP、不會掉 GRANT。
   整支重貼是刻意的（硬規則：同一支要改三處以上就撈全文重建）——
   這裡只改了那道守衛與它的訊息，其餘與線上版逐字相同。 */
create or replace function public.invite_to_team_tx(p_team_id uuid, p_member_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_me   uuid := public.current_member_id();
  v_org  uuid := public.current_org_id();
  v_t    record;
  v_cnt  int;
  v_req  uuid;
  v_name text;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_member_id is null or p_member_id = v_me then
    return jsonb_build_object('ok', false, 'reason', 'bad_target', 'message', '對象不正確');
  end if;
  /* 🆕 副團長也可以邀。**只有這一支放寬** —— 副團長不能審核、不能移除、
     不能改團，那些仍然是 `role = 'leader'`。 */
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = v_me
                    and tm.left_at is null and tm.role in ('leader', 'co_leader')) then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長或副團長可以邀請');
  end if;

  select t.id, t.name, t.member_limit into v_t
    from public.teams t where t.id = p_team_id and t.deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;

  if not exists (select 1 from public.members m
                  where m.id = p_member_id and m.org_id = v_org and m.deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found', 'message', '找不到這個人');
  end if;
  if exists (select 1 from public.team_members tm
              where tm.team_id = p_team_id and tm.member_id = p_member_id and tm.left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'already_member', 'message', '他已經在團裡了');
  end if;

  select count(*) into v_cnt from public.team_members tm
   where tm.team_id = p_team_id and tm.left_at is null;
  if v_cnt >= v_t.member_limit then
    return jsonb_build_object('ok', false, 'reason', 'team_full', 'message', '這個團滿了');
  end if;

  perform public._team_expire_requests(p_team_id);

  /* 🎯 他已經申請過了 ⇒ 按邀請就是核准。
     ⚠ 這條路**副團長也走得到**，而那等於讓他核准了一筆申請 ——
       規格說副團長不能審核，但這裡是他主動去邀一個剛好也在申請的人，
       結果與「邀請成功」完全相同（那個人本來就想進來）。
       🔴 真正不給他的是**待審核清單**（`list_team_requests_tx` 仍是團長限定）
         ⇒ 他不會看到有誰在申請，也不能回絕任何人。 */
  select r.id into v_req from public.team_requests r
   where r.team_id = p_team_id and r.member_id = p_member_id
     and r.status = 'pending' and r.kind = 'apply';
  if v_req is not null then
    update public.team_requests set status = 'accepted', decided_by = v_me, decided_at = now()
     where id = v_req;
    insert into public.team_members (org_id, team_id, member_id)
    values (v_org, p_team_id, p_member_id);
    perform public._team_notify(v_org, p_member_id, 'team_ok', v_t.name,
             '你的申請通過了，歡迎加入 ' || v_t.name, p_team_id, v_t.name, null);
    return jsonb_build_object('ok', true, 'joined', true, 'via', 'apply',
                              'message', '他本來就在申請，已經直接加入了');
  end if;

  if exists (select 1 from public.team_requests r
              where r.team_id = p_team_id and r.member_id = p_member_id and r.status = 'pending') then
    return jsonb_build_object('ok', false, 'reason', 'already_pending', 'message', '已經邀請過了');
  end if;

  insert into public.team_requests (org_id, team_id, member_id, kind, created_by)
  values (v_org, p_team_id, p_member_id, 'invite', v_me)
  returning id into v_req;

  select display_name into v_name from public.members where id = v_me;
  perform public._team_notify(v_org, p_member_id, 'team_req', v_name,
           v_name || ' 邀請你加入 ' || v_t.name, p_team_id, v_t.name, v_req);

  return jsonb_build_object('ok', true, 'joined', false, 'request_id', v_req,
                            'message', '邀請已送出');
end $$;


/* ── ④ 名冊排序：團長 → 副團長 → 團員 → 入團先後 ──── */
/* ⚠ 同樣是整支重貼、簽名不變。與線上版的差別只有那一行 `order by`。
   ⚠ `member_id` 仍然**只給團長** —— 副團長不需要它
     （邀請是從自己的牌咖名單挑人，不是從團員名冊）。
     不需要身分就不要交出身分（2026-09-04 排行榜定的原則）。 */
create or replace function public.get_team_tx(p_team_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $$
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
end $$;


/* ============================================================
   驗證。🔴 一個 raise 都沒有 —— 這份要留下 DDL（硬規則 1.8）。
   ⚠ 行為（副團長真的邀得動、真的審不了）在
     `sql/checks/2026-09-14_驗副團長.sql`，那一份會 raise 回滾。
   ============================================================ */
do $$
declare v_msg text := '';
begin
  v_msg := '① role 的允許值：'
    || coalesce((select pg_get_constraintdef(c.oid) from pg_constraint c
                  where c.conrelid = 'public.team_members'::regclass
                    and c.conname = 'team_members_role_check'), '🔴 約束不見了');

  v_msg := v_msg || E'\n② 三支函式的版本數（各應為 1）：set_team_co_leader_tx '
    || coalesce((select count(*)::text from pg_proc p where p.pronamespace='public'::regnamespace
                  and p.proname='set_team_co_leader_tx'), '🔴')
    || '　invite_to_team_tx '
    || coalesce((select count(*)::text from pg_proc p where p.pronamespace='public'::regnamespace
                  and p.proname='invite_to_team_tx'), '🔴')
    || '　get_team_tx '
    || coalesce((select count(*)::text from pg_proc p where p.pronamespace='public'::regnamespace
                  and p.proname='get_team_tx'), '🔴');

  /* ③ 授權要與其他團 RPC 一模一樣：authenticated 有、anon 與 PUBLIC 都沒有。
     🔴 兩個方向都印（硬規則 2.6b）—— 只印 has_function_privilege
       的話，收錯方向時看到的症狀跟沒收一模一樣。 */
  v_msg := v_msg || E'\n③ set_team_co_leader_tx 授權：authenticated '
    || coalesce((select (exists (select 1 from aclexplode(p.proacl) a
                 where a.grantee='authenticated'::regrole::oid and a.privilege_type='EXECUTE'))::text
         from pg_proc p where p.pronamespace='public'::regnamespace
           and p.proname='set_team_co_leader_tx'), '🔴')
    || '（應 true）　anon '
    || coalesce((select (exists (select 1 from aclexplode(p.proacl) a
                 where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE'))::text
         from pg_proc p where p.pronamespace='public'::regnamespace
           and p.proname='set_team_co_leader_tx'), '🔴')
    || '（應 false）　PUBLIC '
    || coalesce((select (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                 where a.grantee = 0 and a.privilege_type='EXECUTE'))::text
         from pg_proc p where p.pronamespace='public'::regnamespace
           and p.proname='set_team_co_leader_tx'), '🔴')
    || '（應 false）';

  /* ④ 邀請那一支真的放寬了嗎。 */
  v_msg := v_msg || E'\n④ invite_to_team_tx 認得副團長：'
    || coalesce((select (pg_get_functiondef(p.oid) like '%co_leader%')::text
         from pg_proc p where p.pronamespace='public'::regnamespace
           and p.proname='invite_to_team_tx'), '🔴');

  /* ⑤ 🔴 負對照：**其餘五支一個字都不該動**。
     少了這一格，一份「順手把每一支都放寬」的改動也會讓上面全綠。 */
  v_msg := v_msg || E'\n⑤ 仍然只認團長的函式（應為 5 支全部列出）：'
    || coalesce((select string_agg(p.proname, '　' order by p.proname)
         from pg_proc p
        where p.pronamespace='public'::regnamespace and p.prokind='f'
          and p.proname in ('list_team_requests_tx','respond_team_request_tx',
                            'kick_team_member_tx','update_team_tx','disband_team_tx')
          and pg_get_functiondef(p.oid) not like '%co_leader%'), '🔴 有人被放寬了');

  /* ⑥ 名冊排序不再靠字母巧合。 */
  v_msg := v_msg || E'\n⑥ get_team_tx 用明寫的名次排序：'
    || coalesce((select (pg_get_functiondef(p.oid) like '%role_sort%')::text
         from pg_proc p where p.pronamespace='public'::regnamespace
           and p.proname='get_team_tx'), '🔴');

  /* ⑦ 現況：今天有幾個副團長（跑之前必為 0，跑完也是 0 —— 這一份不動資料）。 */
  v_msg := v_msg || E'\n⑦ 現有副團長人數（這份不造資料，應為 0）：'
    || coalesce((select count(*)::text from public.team_members
                  where role = 'co_leader' and left_at is null), '🔴')
    || '　團長 '
    || coalesce((select count(*)::text from public.team_members
                  where role = 'leader' and left_at is null), '🔴')
    || ' 位　團員 '
    || coalesce((select count(*)::text from public.team_members
                  where role = 'member' and left_at is null), '🔴') || ' 位';

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
