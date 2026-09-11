/* ============================================================
   牌咖團 RPC 第二批：加入流程 ＋ 治理 ＋ 總部下架團徽
   2026-09-11 · 接在 `2026-09-11_牌咖團函式_讀與建團.sql`（已跑，9/9）之後

   ⚠ 這份要留下函式，所以**驗證段不准 `raise`**（硬規則 1.8）。
     行為測試在 `sql/checks/2026-09-11_驗牌咖團加入與治理.sql`。
   ⚠ 唯一的例外是 ⑫ 那個改寫 `list_notifications_tx` 的 guard ——
     那是**故意要讓整份失敗**的守衛，不是拿來印訊息的（CLAUDE.md 明列這種允許）。

   ── 申請與邀請是同一張表的兩個方向 ────────────────
   ```
   kind = 'apply'   客人按「申請加入」 → 團長決定
   kind = 'invite'  團長按「邀牌咖加入」 → 那個人決定
   ```
   🔴 而「同時有一筆申請與一筆邀請」是荒謬狀態，靠
     `uq_team_request_pending (team_id, member_id) where status='pending'` 擋掉。
   🎯 **兩邊撞在一起時不要報錯，要直接成交** —— 那正是雙方都同意的意思。
     團長邀他的同時他剛好申請了，跳一個「已經有一筆在談」只會讓人困惑。

   ── 過期不靠排程（硬規則 5.5）──────────────────────
   14 天到期，而**清理綁在一定會發生的動作上**：列出、申請、回應時順手收掉。
   🔴 開 pg_cron 要有人看告警，而那個人不存在。

   ── 🔴 通知刻意不帶 `from_id` ─────────────────────
   牌咖邀請帶 `from_id` 是因為回覆那支吃 `inviter_id`。
   團的回覆吃的是 `p_request_id`（＝`ref_id`），**不需要任何會員 uuid**。
   ⇒ 同 2026-09-04 排行榜的原則：不需要身分就不要交出身分。

   ── 🔴 拒絕不發通知 ───────────────────────────────
   「你被拒絕了」變成一則留在通知列表 30 天的東西，對客人是持續的難堪，
   而它不帶任何他能採取的行動。申請被拒之後那筆會從待審核消失，
   他重新申請時自然會知道。**這是取捨不是遺漏。**
   ============================================================ */


/* ─────────────────────────────────────────────────────────
   ① 兩支內部工具
   ───────────────────────────────────────────────────────── */
/* 過期清理。`p_team_id` 給 null 就掃全部（列我自己的邀請時用）。
   ⚠ `decided_at` 一定要一起寫 —— `team_requests_decided_shape_check`
     規定「不是 pending 就必須有決定時間」，少寫會整段拋錯。 */
create or replace function public._team_expire_requests(p_team_id uuid default null)
returns int
language plpgsql
as $$
declare v_n int;
begin
  update public.team_requests
     set status = 'expired', decided_at = now()
   where status = 'pending' and expires_at <= now()
     and (p_team_id is null or team_id = p_team_id);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

/* 通知的唯一寫入點。
   🔴 payload 的形狀必須與 `buddy_req` 一致（`from_name` / `text`），
     否則前端 `fetchNotifs()` 的 `n.payload.from_name` 會讀到 undefined，
     而那**不會報錯**，只會讓通知列少一個名字。 */
create or replace function public._team_notify(p_org       uuid,
                                               p_to        uuid,
                                               p_type      text,
                                               p_from_name text,
                                               p_text      text,
                                               p_team_id   uuid,
                                               p_team_name text,
                                               p_ref       uuid)
returns void
language sql
as $$
  insert into public.app_notifications (org_id, member_id, type, payload, ref_id)
  values (p_org, p_to, p_type,
          jsonb_build_object('from_name', p_from_name, 'text', p_text,
                             'team_id', p_team_id, 'team_name', p_team_name),
          p_ref);
$$;

revoke execute on function public._team_expire_requests(uuid) from public;
revoke execute on function public._team_expire_requests(uuid) from anon, authenticated;
revoke execute on function public._team_notify(uuid, uuid, text, text, text, uuid, text, uuid) from public;
revoke execute on function public._team_notify(uuid, uuid, text, text, text, uuid, text, uuid) from anon, authenticated;


/* ─────────────────────────────────────────────────────────
   ② apply_team_tx —— 申請加入
   ───────────────────────────────────────────────────────── */
create or replace function public.apply_team_tx(p_team_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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

  if v_leader is not null then
    perform public._team_notify(v_org, v_leader, 'team_req', v_name,
             v_name || ' 想加入 ' || v_t.name, p_team_id, v_t.name, v_req);
  end if;

  return jsonb_build_object('ok', true, 'joined', false, 'request_id', v_req,
                            'message', '已送出申請，等團長審核');
end $$;


/* ─────────────────────────────────────────────────────────
   ③ invite_to_team_tx —— 團長邀牌咖加入
   ───────────────────────────────────────────────────────── */
create or replace function public.invite_to_team_tx(p_team_id uuid, p_member_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
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
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = v_me
                    and tm.left_at is null and tm.role = 'leader') then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以邀請');
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

  /* 🎯 他已經申請過了 ⇒ 團長按邀請就是核准。 */
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


/* ─────────────────────────────────────────────────────────
   ④ respond_team_request_tx —— 回應（兩個方向共用一支）
   ───────────────────────────────────────────────────────── */
/* 🔴 誰能回應，由 `kind` 決定，不由呼叫端說了算：
   ```
   apply   → 只有那個團的團長
   invite  → 只有被邀的那個人
   ```
   兩個方向各寫一支的話，「誰有權決定」就會有兩份定義。 */
create or replace function public.respond_team_request_tx(p_request_id uuid, p_accept boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
    if not exists (select 1 from public.team_members tm
                    where tm.team_id = v_r.team_id and tm.member_id = v_me
                      and tm.left_at is null and tm.role = 'leader') then
      return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以審核');
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
end $$;


/* ─────────────────────────────────────────────────────────
   ⑤ cancel_team_request_tx —— 收回自己發出的那一筆
   ───────────────────────────────────────────────────────── */
create or replace function public.cancel_team_request_tx(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := public.current_member_id();
  v_r  record;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  select r.* into v_r from public.team_requests r where r.id = p_request_id;
  if not found or v_r.status <> 'pending' then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這筆或已經處理過了');
  end if;
  /* ⚠ 只有**發起的人**能收回。邀請由團長收回、申請由本人收回，
     而 `created_by` 正是為了答得出這件事才存在的。 */
  if v_r.created_by <> v_me then
    return jsonb_build_object('ok', false, 'reason', 'not_yours', 'message', '這不是你發出的');
  end if;

  update public.team_requests set status = 'cancelled', decided_by = v_me, decided_at = now()
   where id = p_request_id;
  return jsonb_build_object('ok', true, 'message', '已收回');
end $$;


/* ─────────────────────────────────────────────────────────
   ⑥ list_team_requests_tx —— 團長的待審核清單
   ───────────────────────────────────────────────────────── */
create or replace function public.list_team_requests_tx(p_team_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
           'kind',       r.kind,
           'created_at', r.created_at,
           'expires_at', r.expires_at) order by r.created_at), '[]'::jsonb)
    into v_rows
    from public.team_requests r
    join public.members m on m.id = r.member_id
   where r.team_id = p_team_id and r.status = 'pending' and r.kind = 'apply';

  return jsonb_build_object('ok', true, 'requests', v_rows);
end $$;


/* ─────────────────────────────────────────────────────────
   ⑦ leave_team_tx —— 退團
   ───────────────────────────────────────────────────────── */
/* 🔴 團長不能直接退：要嘛先轉讓，要嘛解散。
   讓他直接走的話那個團會變成**沒有團長的團** ——
   沒有人能審核申請、沒有人能改團名，而畫面上完全看不出來。
   ⚠ 例外：他是最後一個人 ⇒ 退團等於解散，直接幫他做完。 */
create or replace function public.leave_team_tx(p_team_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me   uuid := public.current_member_id();
  v_role text;
  v_cnt  int;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  select tm.role into v_role from public.team_members tm
   where tm.team_id = p_team_id and tm.member_id = v_me and tm.left_at is null;
  if v_role is null then
    return jsonb_build_object('ok', false, 'reason', 'not_member', 'message', '你不在這個團裡');
  end if;

  select count(*) into v_cnt from public.team_members tm
   where tm.team_id = p_team_id and tm.left_at is null;

  if v_role = 'leader' and v_cnt > 1 then
    return jsonb_build_object('ok', false, 'reason', 'leader_must_transfer',
                              'message', '你是團長，請先把團長轉給別人，或解散這個團');
  end if;

  if v_role = 'leader' then
    return public.disband_team_tx(p_team_id);
  end if;

  update public.team_members set left_at = now(), left_reason = 'quit'
   where team_id = p_team_id and member_id = v_me and left_at is null;

  return jsonb_build_object('ok', true, 'message', '已退出這個牌咖團');
end $$;


/* ─────────────────────────────────────────────────────────
   ⑧ kick_team_member_tx —— 團長移除團員
   ───────────────────────────────────────────────────────── */
create or replace function public.kick_team_member_tx(p_team_id uuid, p_member_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_me uuid := public.current_member_id();
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_member_id = v_me then
    return jsonb_build_object('ok', false, 'reason', 'self',
                              'message', '要離開請用退團，不是移除自己');
  end if;
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = v_me
                    and tm.left_at is null and tm.role = 'leader') then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以移除團員');
  end if;

  /* 🔴 寫 `kicked` 不重用 `quit` —— `quit` 的意思是「他自己走的」，
     店員移除卻寫 quit 會讓那個欄位說一件沒發生的事（同 2026-09-10
     配桌那批的決定）。而且它不會報錯，只會讓日後的流失分析算錯。 */
  update public.team_members set left_at = now(), left_reason = 'kicked'
   where team_id = p_team_id and member_id = p_member_id and left_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_member', 'message', '他不在這個團裡');
  end if;

  return jsonb_build_object('ok', true, 'message', '已移除');
end $$;


/* ─────────────────────────────────────────────────────────
   ⑨ transfer_team_leader_tx —— 轉讓團長
   ───────────────────────────────────────────────────────── */
/* 🔴 順序只有一種寫法：**先把自己降級，再把對方升級**。
   `uq_team_one_leader` 是部分唯一索引而且不可延遲 ——
   一句 UPDATE 同時改兩列時，Postgres 不保證哪一列先寫，
   先寫到升級那一列就會撞索引。**而撞不撞得到要看資料列的順序**，
   也就是它會在某些資料上通過、某些資料上失敗。 */
create or replace function public.transfer_team_leader_tx(p_team_id uuid, p_to_member_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me   uuid := public.current_member_id();
  v_org  uuid := public.current_org_id();
  v_name text;
  v_team text;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_to_member_id is null or p_to_member_id = v_me then
    return jsonb_build_object('ok', false, 'reason', 'bad_target', 'message', '對象不正確');
  end if;
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = v_me
                    and tm.left_at is null and tm.role = 'leader') then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以轉讓');
  end if;
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = p_to_member_id
                    and tm.left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'not_member', 'message', '他不在這個團裡');
  end if;

  update public.team_members set role = 'member'
   where team_id = p_team_id and member_id = v_me and left_at is null;
  update public.team_members set role = 'leader'
   where team_id = p_team_id and member_id = p_to_member_id and left_at is null;

  select t.name into v_team from public.teams t where t.id = p_team_id;
  select display_name into v_name from public.members where id = v_me;
  perform public._team_notify(v_org, p_to_member_id, 'team_ok', v_name,
           v_name || ' 把 ' || v_team || ' 的團長交給你了', p_team_id, v_team, null);

  return jsonb_build_object('ok', true, 'message', '已轉讓團長');
end $$;


/* ─────────────────────────────────────────────────────────
   ⑩ claim_team_leader_tx —— 團長失聯，年資最久的團員接任
   ───────────────────────────────────────────────────────── */
/* 🎯 這一支是手遊公會的標準答案，而它解掉的是「只有一級團長」留下的
   單點失效：團長不再出現 ⇒ 沒有人能審核申請、沒有人能改團名，
   **而畫面上完全看不出來**。
   🔴 業界的解法是**自動化**，不是加一個副團長階級（硬規則 5.7 那一族）。

   ⚠ 判準用**兩個既有欄位**，不新建任何東西：
   ```
   members.last_app_active_at   開 App
   members.last_visit_at        來店消費（trg_orders_touch_visit 在維護）
   ```
   兩個都超過 60 天沒動作才算失聯。取兩者較晚的那一個 ——
   只看 App 的話，常來店但不開 App 的老闆型團長會被誤判。

   🔴 **不是誰先按誰接任** —— 那會變成「團長一失聯就被新人搶走」。
     只有「除了團長以外、在團最久的那一位」按得動，答案是唯一的。 */
create or replace function public.claim_team_leader_tx(p_team_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me     uuid := public.current_member_id();
  v_org    uuid := public.current_org_id();
  v_lead   uuid;
  v_seen   timestamptz;
  v_first  uuid;
  v_days   int := 60;   -- 失聯門檻
  v_team   text;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = v_me and tm.left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'not_member', 'message', '你不在這個團裡');
  end if;

  select tm.member_id into v_lead from public.team_members tm
   where tm.team_id = p_team_id and tm.role = 'leader' and tm.left_at is null;

  if v_lead = v_me then
    return jsonb_build_object('ok', false, 'reason', 'already_leader', 'message', '你已經是團長了');
  end if;

  /* 年資最久的非團長成員（同時間時取 id 較小的，讓答案是唯一的）。 */
  select tm.member_id into v_first from public.team_members tm
   where tm.team_id = p_team_id and tm.left_at is null
     and (v_lead is null or tm.member_id <> v_lead)
   order by tm.joined_at, tm.member_id
   limit 1;

  if v_first is distinct from v_me then
    return jsonb_build_object('ok', false, 'reason', 'not_eligible',
                              'message', '要由團裡待最久的人接任');
  end if;

  if v_lead is not null then
    select greatest(coalesce(m.last_app_active_at, 'epoch'::timestamptz),
                    coalesce(m.last_visit_at,      'epoch'::timestamptz))
      into v_seen
      from public.members m where m.id = v_lead;

    if v_seen > now() - make_interval(days => v_days) then
      return jsonb_build_object('ok', false, 'reason', 'leader_active',
                                'message', '團長還在活動中，不能接任',
                                'last_seen', v_seen);
    end if;

    update public.team_members set role = 'member'
     where team_id = p_team_id and member_id = v_lead and left_at is null;
  end if;

  update public.team_members set role = 'leader'
   where team_id = p_team_id and member_id = v_me and left_at is null;

  select t.name into v_team from public.teams t where t.id = p_team_id;
  return jsonb_build_object('ok', true, 'message', '你現在是 ' || v_team || ' 的團長了');
end $$;


/* ─────────────────────────────────────────────────────────
   ⑪ admin_remove_team_crest_tx —— 總部下架團徽
   ───────────────────────────────────────────────────────── */
/* 使用者 2026-09-11 決定團徽**不審核**。這一支不是審核，是出事時的下架。
   🔴 權限碼用 `member.write`，與 `admin_remove_avatar_tx` **同一個**
     —— 開一個新的 `team.write` 會變成第二份「誰能做這件事」的定義，
     而今天所有碼的答案都一樣（總部才有）。
   ⚠ `p_block = true` 之後那個團**不能再上傳照片**，emoji 仍然可以換
     （比照 `members.avatar_blocked`）。 */
create or replace function public.admin_remove_team_crest_tx(p_team_id uuid,
                                                             p_reason  text default null,
                                                             p_block   boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_old text;
begin
  if not public.can('member.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限');
  end if;

  select t.crest_path into v_old from public.teams t
   where t.id = p_team_id and t.deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;

  update public.teams
     set crest_path = null,
         crest_blocked = coalesce(p_block, false) or crest_blocked,
         updated_at = now()
   where id = p_team_id;

  /* ⚠ 只回「本來有沒有照片」，不回路徑 —— 路徑是 Storage 的公開網址，
     回傳等於把剛下架的那張圖再交出去一次。 */
  return jsonb_build_object('ok', true, 'had_photo', v_old is not null,
                            'blocked', coalesce(p_block, false), 'reason_note', p_reason);
end $$;


/* ─────────────────────────────────────────────────────────
   ⑫ list_notifications_tx 也要認得團的邀請
   ───────────────────────────────────────────────────────── */
/* 🔴 不改的話，團的邀請在通知列**永遠是待處理的樣子** ——
   答應過了還是顯示兩顆按鈕，再按一次得到「已經答應過了」。
   ⚠ 簽名不動 ⇒ `CREATE OR REPLACE` ⇒ 不用 DROP、不掉 GRANT、前端不用改。
   📌 這支仍然吃 `p_org_id` 與 `p_member`（前端送的），那是待辦 14 的
     53 支之一。**這一批不動它** —— 改簽名是另一件事，混進來會讓
     「通知壞了」與「牌咖團壞了」分不開。 */
create or replace function public.list_notifications_tx(p_org_id uuid, p_member uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', n.id, 'type', n.type, 'payload', n.payload, 'ref_id', n.ref_id,
      'unread', (n.read_at is null), 'created_at', n.created_at,
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
        end
    ) order by n.created_at desc)
    from app_notifications n
    where n.member_id = p_member and n.org_id = p_org_id
      and n.created_at > now() - interval '30 days'
  ), '[]'::jsonb);
end $$;

/* 🔴 守衛：改到一半就整份失敗。
   這個 `raise` 是**故意不要提交**的那一種，不是拿來印訊息的 —— 兩者
   的差別是硬規則 1.8 的重點。少了它，線上會出現一支「buddy 認得、
   team 不認得」的通知函式，而且不會報錯。 */
do $$
begin
  if position('team_requests' in pg_get_functiondef('public.list_notifications_tx(uuid,uuid)'::regprocedure)) = 0
  then
    raise exception '🔴 list_notifications_tx 沒有改成功，整份回滾';
  end if;
end $$;


/* ─────────────────────────────────────────────────────────
   ⑬ 授權
   ───────────────────────────────────────────────────────── */
do $$
declare v_sig text;
begin
  foreach v_sig in array array[
    'public.apply_team_tx(uuid)',
    'public.invite_to_team_tx(uuid, uuid)',
    'public.respond_team_request_tx(uuid, boolean)',
    'public.cancel_team_request_tx(uuid)',
    'public.list_team_requests_tx(uuid)',
    'public.leave_team_tx(uuid)',
    'public.kick_team_member_tx(uuid, uuid)',
    'public.transfer_team_leader_tx(uuid, uuid)',
    'public.claim_team_leader_tx(uuid)',
    'public.admin_remove_team_crest_tx(uuid, text, boolean)'
  ] loop
    execute format('revoke execute on function %s from public', v_sig);
    execute format('revoke execute on function %s from anon', v_sig);
    execute format('grant  execute on function %s to authenticated', v_sig);
  end loop;
end $$;


/* ============================================================
   驗證（唯讀，不准 raise —— 這份要留下十支函式）
   ⚠ 行為測試在 `sql/checks/2026-09-11_驗牌咖團加入與治理.sql`。
   ============================================================ */
do $$
declare
  v_msg  text := '';
  v_n    int;
  v_line text;
  v_r    jsonb;
begin
  /* ① 十支對外 ＋ 兩支內部都在，而且各只有一個版本 */
  select count(*) into v_n from pg_proc
   where pronamespace = 'public'::regnamespace
     and proname in ('apply_team_tx','invite_to_team_tx','respond_team_request_tx',
                     'cancel_team_request_tx','list_team_requests_tx','leave_team_tx',
                     'kick_team_member_tx','transfer_team_leader_tx','claim_team_leader_tx',
                     'admin_remove_team_crest_tx','_team_expire_requests','_team_notify');
  v_msg := v_msg || case when v_n = 12
    then '① ✅ 十二支都在（十支對外 ＋ 兩支內部），各只有一個版本'
    else '① 🔴 共 ' || v_n || ' 支，預期 12 —— 大於 12 表示建出了多載版本' end;

  /* ② 十支對外：anon 與 PUBLIC 都要是 0 */
  select count(*) into v_n
    from pg_proc p left join lateral aclexplode(p.proacl) a on true
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('apply_team_tx','invite_to_team_tx','respond_team_request_tx',
                       'cancel_team_request_tx','list_team_requests_tx','leave_team_tx',
                       'kick_team_member_tx','transfer_team_leader_tx','claim_team_leader_tx',
                       'admin_remove_team_crest_tx')
     and (a.grantee = 'anon'::regrole::oid or a.grantee = 0)
     and a.privilege_type = 'EXECUTE';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '② ✅ 十支都收掉了 anon 與 PUBLIC'
    else '② 🔴 還有 ' || v_n || ' 筆 anon／PUBLIC 的執行權' end;

  select count(*) into v_n
    from pg_proc p join lateral aclexplode(p.proacl) a on true
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('apply_team_tx','invite_to_team_tx','respond_team_request_tx',
                       'cancel_team_request_tx','list_team_requests_tx','leave_team_tx',
                       'kick_team_member_tx','transfer_team_leader_tx','claim_team_leader_tx',
                       'admin_remove_team_crest_tx')
     and a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE';
  v_msg := v_msg || E'\n' || case when v_n = 10
    then '③ ✅ 十支都授權給 authenticated（正對照 —— 沒有連前端一起關掉）'
    else '③ 🔴 只有 ' || v_n || '/10 授權給 authenticated' end;

  /* ④ 兩支內部不可以給前端 */
  select count(*) into v_n
    from pg_proc p left join lateral aclexplode(p.proacl) a on true
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('_team_expire_requests','_team_notify')
     and (a.grantee = 'anon'::regrole::oid or a.grantee = 0
          or a.grantee = 'authenticated'::regrole::oid)
     and a.privilege_type = 'EXECUTE';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '④ ✅ 兩支內部函式前端都叫不到'
    else '④ 🔴 內部函式被授權出去了（' || v_n || ' 筆）' end;

  /* ⑤ 通知函式認得 team_req 了，而且 buddy_req 沒被改壞 */
  v_n := 0;
  if position('team_requests' in
       pg_get_functiondef('public.list_notifications_tx(uuid,uuid)'::regprocedure)) > 0
     and position('buddy_invites' in
       pg_get_functiondef('public.list_notifications_tx(uuid,uuid)'::regprocedure)) > 0
  then v_n := 1; end if;
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '⑤ ✅ 通知函式同時認得 team_req 與 buddy_req（沒有改掉舊的那一半）'
    else '⑤ 🔴 通知函式只認得其中一種 —— 改到一半了' end;

  /* ⑥ 通知型別白名單裡真的有那兩個值。
     🔴 少了這一格，第一次有人申請加入時 insert 會被 CHECK 擋掉，
       **而通知是靜默的，那一筆會直接消失**。 */
  select count(*) into v_n
    from pg_constraint c
    cross join lateral regexp_matches(pg_get_constraintdef(c.oid), '''(team_[a-z]+)''', 'g') m
   where c.conname = 'app_notifications_type_check';
  v_msg := v_msg || E'\n' || case when v_n = 2
    then '⑥ ✅ 通知白名單有 team_req 與 team_ok'
    else '⑥ 🔴 白名單裡只有 ' || v_n || ' 個 team_ 型別，預期 2' end;

  /* ⑦ 借真身分實際跑一支唯讀的（硬規則 7）。
     ⚠ 這位會員不是任何團的團長 ⇒ 正確答案是 not_leader，
       那證明「權限判斷真的有跑到」，不是函式體沒走。 */
  select m.line_user_id into v_line from public.members m
   where m.line_user_id is not null and m.deleted_at is null
   order by m.created_at limit 1;

  if v_line is null then
    v_msg := v_msg || E'\n⑦ 🔴 找不到綁了 LINE 的會員 —— 這一格測不了，而測不了不等於通過';
  else
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_line, 'role', 'authenticated')::text, true);
    v_r := public.list_team_requests_tx('00000000-0000-0000-0000-000000000000'::uuid);
    v_msg := v_msg || E'\n' || case when coalesce(v_r->>'reason','') = 'not_leader'
      then '⑦ ✅ list_team_requests_tx 跑得動，非團長被擋下（權限判斷有走到）'
      else '⑦ 🔴 預期 not_leader，實際回 ' || coalesce(v_r::text,'null') end;
    perform set_config('request.jwt.claims', '', true);
  end if;

  /* ⑧ 總部那支：沒有權限時要回 forbidden。
     ⚠ SQL Editor 沒有 staff 身分 ⇒ `can()` 回 false ⇒ 這一格本來就該擋。 */
  v_r := public.admin_remove_team_crest_tx('00000000-0000-0000-0000-000000000000'::uuid);
  v_msg := v_msg || E'\n' || case when coalesce(v_r->>'reason','') = 'forbidden'
    then '⑧ ✅ 總部下架團徽那支有權限判斷（沒有身分時回 forbidden）'
    else '⑧ 🔴 沒有身分卻回 ' || coalesce(v_r::text,'null') end;

  /* ⑨ 這份沒有寫進任何東西 */
  select count(*) into v_n from public.team_requests;
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '⑨ ✅ 驗證段沒有留下任何申請或邀請'
    else '⑨ ⚠ 現在有 ' || v_n || ' 筆 team_requests —— 若不是真的客人送的，回頭看驗證段' end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
