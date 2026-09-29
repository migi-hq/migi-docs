/* ============================================================
   牌咖團邀請連結：團長按一次 → 傳到 LINE → 朋友點了直接入團
   2026-09-29 · 使用者問「團長要如何最快把一位客人加成會員並加進牌咖團」

   ── 規則（2026-09-16 使用者定的，這裡照做）──────────────────
   · **一次性、直接入團**：點了就進，不經團長審核（連結是團長親手發的）
   · 兩半綁在一起：直接入團 ⇒ 連結本身就是憑證；只能用一次 ⇒ 被轉貼也最多進一個人
   ⇒ 網址放的是**一次性 tokeㄇn，不是 team_id**（團 id 在熱門榜上人人看得到）

   ── 形狀 ──────────────────────────────────────────────
   team_invite_links   一條連結一列；誰發的、什麼時候過期、被誰用掉
   create_team_invite_link_tx(p_team_id)   團長／副團長按一次發一條新的（寫入，不是查詢）
   redeem_team_invite_tx(p_token)          憑連結入團（身分一律登入的本人）

   ── 刻意的決定 ─────────────────────────────────────────
   · 有效 7 天：連結傳出去通常當天就點；放太久的連結被轉貼的機會變大
   · 一個團同時最多 20 條沒用掉的：防止被刷；不是業務限制，正常團長碰不到
   · **沒用成功就不算用掉**：已經在團裡、團滿了、已經加入 10 個團 ⇒ 連結保留，
     不然朋友點了一次沒進去，團長得重發
   · 自己點自己發的連結 ⇒ 已經在團裡，不消耗
   · 團的 join_policy 是 closed 也照樣進：連結是團長主動發的，等同邀請
   · 入團規則與既有兩支一致：10 個團上限、團員上限、已在團裡不重複
   · 有一筆「團長邀請我」的待處理邀請 ⇒ 一起標成已答應（不留一筆懸著的）
   · 入團通知照舊發給團長（同 apply_team_tx 的 open 那條路）
   · 成就：team_members 的觸發器會自己發，這裡不另外發

   ── 授權（硬規則 2.7：預設全關，這是第一份照新規矩寫的）──
   兩支都明確 grant 給 authenticated；表 0 policy（只有函式進得去）。
   ⚠ 這份要留下東西 ⇒ 驗證段不 raise（硬規則 1.8）。
     行為測試：sql/checks/2026-09-29_驗牌咖團邀請連結.sql
   ============================================================ */

create table if not exists public.team_invite_links (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.orgs(id),
  team_id     uuid not null references public.teams(id),
  token       text not null unique,
  created_by  uuid not null references public.members(id),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default (now() + interval '7 days'),
  used_by     uuid references public.members(id),
  used_at     timestamptz,
  constraint team_invite_links_used_pair check ((used_by is null) = (used_at is null))
);
create index if not exists idx_team_invite_links_team on public.team_invite_links (team_id) where used_at is null;
alter table public.team_invite_links enable row level security;   -- 0 policy：只有函式進得去
comment on table public.team_invite_links is
  '牌咖團的一次性入團連結（2026-09-29）。token 放在 LIFF 網址 ?t= 裡；用掉一次就失效、7 天過期。前端讀不到這張表，只能透過兩支函式。';

create or replace function public.create_team_invite_link_tx(p_team_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare
  v_me    uuid := public.current_member_id();
  v_org   uuid := public.current_org_id();
  v_team  record;
  v_open  int;
  v_token text;
  v_exp   timestamptz;
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

  return jsonb_build_object('ok', true, 'token', v_token, 'expires_at', v_exp, 'team_name', v_team.name);
end $$;

create or replace function public.redeem_team_invite_tx(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare
  v_me     uuid := public.current_member_id();
  v_org    uuid := public.current_org_id();
  v_l      record;
  v_t      record;
  v_cnt    int;
  v_leader uuid;
  v_name   text;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  select l.* into v_l from public.team_invite_links l
   where l.token = p_token and l.org_id = v_org
   for update;                                   -- 兩個人同時點同一條：第二個等第一個做完
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'invalid', 'message', '這條邀請連結不存在，請團長重新傳一次');
  end if;

  select t.id, t.name, t.member_limit into v_t from public.teams t
   where t.id = v_l.team_id and t.deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'team_gone', 'message', '這個牌咖團已經解散了');
  end if;

  -- 已經在團裡：成功，但**不消耗**連結（包含點了自己發的）
  if exists (select 1 from public.team_members tm
              where tm.team_id = v_t.id and tm.member_id = v_me and tm.left_at is null) then
    return jsonb_build_object('ok', true, 'joined', false, 'already_member', true,
      'team_id', v_t.id, 'team_name', v_t.name, 'message', '你已經在 ' || v_t.name || ' 裡了');
  end if;

  if v_l.used_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'used', 'message', '這條邀請連結已經有人用過了，請團長再傳一次');
  end if;
  if v_l.expires_at <= now() then
    return jsonb_build_object('ok', false, 'reason', 'expired', 'message', '這條邀請連結已經過期了，請團長再傳一次');
  end if;

  select count(*) into v_cnt from public.team_members tm where tm.team_id = v_t.id and tm.left_at is null;
  if v_cnt >= v_t.member_limit then
    return jsonb_build_object('ok', false, 'reason', 'team_full', 'message', v_t.name || ' 滿了');
  end if;
  select count(*) into v_cnt from public.team_members tm
    join public.teams t2 on t2.id = tm.team_id and t2.deleted_at is null
   where tm.member_id = v_me and tm.left_at is null;
  if v_cnt >= 10 then
    return jsonb_build_object('ok', false, 'reason', 'too_many_teams', 'message', '你已經加入 10 個牌咖團了');
  end if;

  insert into public.team_members (org_id, team_id, member_id) values (v_org, v_t.id, v_me);
  update public.team_invite_links set used_by = v_me, used_at = now() where id = v_l.id;
  -- 懸著的邀請／申請一起了結，不要留一筆「等回覆」在通知裡
  update public.team_requests set status = 'accepted', decided_by = v_me, decided_at = now()
   where team_id = v_t.id and member_id = v_me and status = 'pending';

  select tm.member_id into v_leader from public.team_members tm
   where tm.team_id = v_t.id and tm.role = 'leader' and tm.left_at is null;
  select display_name into v_name from public.members where id = v_me;
  if v_leader is not null and v_leader <> v_me then
    perform public._team_notify(v_org, v_leader, 'team_ok', v_name,
             v_name || ' 用邀請連結加入了 ' || v_t.name, v_t.id, v_t.name, null);
  end if;

  return jsonb_build_object('ok', true, 'joined', true, 'team_id', v_t.id, 'team_name', v_t.name,
                            'message', '已加入 ' || v_t.name);
end $$;

-- 授權：預設已經是全關（硬規則 2.7），這裡明確開給登入的人
revoke all on function public.create_team_invite_link_tx(uuid) from public, anon;
revoke all on function public.redeem_team_invite_tx(text)      from public, anon;
grant execute on function public.create_team_invite_link_tx(uuid) to authenticated, service_role;
grant execute on function public.redeem_team_invite_tx(text)      to authenticated, service_role;
revoke all on table public.team_invite_links from public, anon, authenticated;

/* ── 驗證段（單一 SELECT，不 raise）────────────────────────── */
do $$
declare v_msg text := ''; v_n int;
begin
  select count(*) into v_n from information_schema.tables where table_schema = 'public' and table_name = 'team_invite_links';
  v_msg := v_msg || case when v_n = 1 then '✅ ① team_invite_links 建好了' else '🔴 ① 表不在' end;

  select count(*) into v_n from pg_class c where c.oid = 'public.team_invite_links'::regclass and c.relrowsecurity
     and not exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = 'team_invite_links')
     and not has_table_privilege('anon', c.oid, 'SELECT') and not has_table_privilege('authenticated', c.oid, 'SELECT');
  v_msg := v_msg || E'\n' || case when v_n = 1 then '✅ ② 表開了 RLS、0 policy、前端讀不到（只有函式進得去）'
                                   else '🔴 ② 表的權限不對' end;

  select count(*) into v_n from pg_proc p where p.pronamespace = 'public'::regnamespace
     and p.proname in ('create_team_invite_link_tx', 'redeem_team_invite_tx')
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     and not has_function_privilege('anon', p.oid, 'EXECUTE')
     and pg_get_functiondef(p.oid) like '%current_member_id()%';
  v_msg := v_msg || E'\n' || case when v_n = 2 then '✅ ③ 兩支函式：登入的人叫得動、anon 叫不到、身分取自登入'
                                   else '🔴 ③ 函式 ' || v_n || '/2' end;

  /* ④ 正對照：預設全關真的有作用 —— 這兩支是新建的，沒有那兩行 grant 的話 authenticated 會叫不到。
        上面 ③ 已經驗到叫得動 ⇒ 代表 grant 寫對了；這裡再確認沒有意外多開給 PUBLIC */
  select count(*) into v_n from pg_proc p, aclexplode(p.proacl) a
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('create_team_invite_link_tx', 'redeem_team_invite_tx') and a.grantee = 0;
  v_msg := v_msg || E'\n' || case when v_n = 0 then '✅ ④ 沒有開給 PUBLIC'
                                   else '🔴 ④ 有開給 PUBLIC' end;

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
