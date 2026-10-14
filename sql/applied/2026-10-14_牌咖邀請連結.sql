-- ============================================================
-- 2026-10-14 牌咖邀請連結：朋友點了 LINE 傳來的連結，登入（或註冊完）就自動跟邀請人成為牌咖
-- ------------------------------------------------------------
-- 使用者：「牌咖頁：邀請朋友拿 50 點跟推薦碼機制都先隱藏，下面用 LINE 邀請朋友只需單純分享 LINE 連結」
--         「但牌咖的邀請朋友不能跟牌咖團共用：牌咖團的會自動入團，牌咖的邀請只需要自動加牌咖」
--
-- 照牌咖團邀請連結（team_invite_links／create_team_invite_link_tx／redeem_team_invite_tx，2026-09-29）同一套規則：
--   · 網址裡放一次性 token，不放會員 id（會員 id 不能當憑證）
--   · 一條連結只能用一次、7 天過期；每按一次「LINE 邀請朋友」就要一條新的（同一個人最多 20 條沒用掉的）
--   · 點了自己發的、或本來就是牌咖 ⇒ 回成功但**不消耗**連結
--   · 兩人之間有任何一方封鎖對方 ⇒ 不加（訊息不說是誰封鎖誰）
--   · 加牌咖的寫法照 respond_buddy_invite_tx：兩筆互指、origin = 'pre_existing'（本來就認識的朋友）、重複就跳過；
--     兩人之間還懸著的牌咖邀請一起標成已接受；通知邀請人一則 buddy_ok
-- 身分一律 current_member_id()（硬規則 2.7：新函式預設全關，這裡明寫 grant 給 authenticated）
-- 新表開 RLS、0 條 policy（只有 DEFINER 函式進得去）
-- ============================================================

create table if not exists public.buddy_invite_links (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.orgs(id),
  token       text not null unique,
  created_by  uuid not null references public.members(id),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default (now() + interval '7 days'),
  used_by     uuid references public.members(id),
  used_at     timestamptz
);
create index if not exists idx_buddy_invite_links_creator on public.buddy_invite_links (created_by) where used_at is null;
alter table public.buddy_invite_links enable row level security;
comment on table public.buddy_invite_links is
  '牌咖邀請連結（2026-10-14）：一次性 token，朋友點了自動成為邀請人的牌咖。只有 create_buddy_invite_link_tx／redeem_buddy_invite_tx 會碰（RLS 開、0 policy）';

CREATE OR REPLACE FUNCTION public.create_buddy_invite_link_tx()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me    uuid := public.current_member_id();
  v_org   uuid := public.current_org_id();
  v_open  int;
  v_token text;
  v_exp   timestamptz;
  v_name  text;
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
  select display_name into v_name from public.members where id = v_me;

  return jsonb_build_object('ok', true, 'token', v_token, 'expires_at', v_exp, 'my_name', v_name);
end $function$;

CREATE OR REPLACE FUNCTION public.redeem_buddy_invite_tx(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me    uuid := public.current_member_id();
  v_org   uuid := public.current_org_id();
  v_l     record;
  v_from  record;
  v_name  text;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  select l.* into v_l from public.buddy_invite_links l
   where l.token = p_token and l.org_id = v_org
   for update;                                   -- 兩個人同時點同一條：第二個等第一個做完
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'invalid', 'message', '這條邀請連結不存在，請朋友重新傳一次');
  end if;

  select m.id, m.display_name, m.hidden_at, m.deleted_at into v_from from public.members m where m.id = v_l.created_by;
  if v_from.id is null or v_from.deleted_at is not null or v_from.hidden_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'inviter_gone', 'message', '發這條邀請的會員已經不在了');
  end if;

  -- 點了自己發的：成功，但不消耗連結
  if v_l.created_by = v_me then
    return jsonb_build_object('ok', true, 'added', false, 'self', true, 'message', '這是你自己的邀請連結，傳給朋友吧');
  end if;
  -- 本來就是牌咖：成功，但不消耗連結
  if exists (select 1 from public.mahjong_buddies b
              where b.member_id = v_me and b.buddy_id = v_l.created_by and b.deleted_at is null) then
    return jsonb_build_object('ok', true, 'added', false, 'already', true,
      'buddy_name', v_from.display_name, 'message', '你和 ' || v_from.display_name || ' 已經是牌咖了');
  end if;

  if v_l.used_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'used', 'message', '這條邀請連結已經有人用過了，請朋友再傳一次');
  end if;
  if v_l.expires_at <= now() then
    return jsonb_build_object('ok', false, 'reason', 'expired', 'message', '這條邀請連結已經過期了，請朋友再傳一次');
  end if;
  -- 任何一方封鎖了對方：不加，也不說是誰封鎖誰
  if exists (select 1 from public.member_blocks k
              where (k.blocker_id = v_me and k.blocked_id = v_l.created_by)
                 or (k.blocker_id = v_l.created_by and k.blocked_id = v_me)) then
    return jsonb_build_object('ok', false, 'reason', 'blocked', 'message', '沒辦法透過這條連結加牌咖');
  end if;

  -- 加牌咖：照 respond_buddy_invite_tx 的寫法 —— 兩筆互指、本來就認識（pre_existing）、重複就跳過
  insert into public.mahjong_buddies (org_id, member_id, buddy_id, origin)
  values (v_org, v_l.created_by, v_me, 'pre_existing'),
         (v_org, v_me, v_l.created_by, 'pre_existing')
  on conflict do nothing;
  update public.buddy_invite_links set used_by = v_me, used_at = now() where id = v_l.id;

  -- 兩人之間懸著的牌咖邀請一起了結，通知裡不要留一則「等回覆」
  update public.buddy_invites set status = 'accepted', responded_at = now()
   where status = 'pending'
     and ((inviter_id = v_me and invitee_id = v_l.created_by) or (inviter_id = v_l.created_by and invitee_id = v_me));
  update public.app_notifications set read_at = now()
   where type = 'buddy_req' and read_at is null
     and ((member_id = v_me and ref_id = v_l.created_by) or (member_id = v_l.created_by and ref_id = v_me));

  -- 通知邀請人（同接受牌咖邀請那一則的形狀）
  select display_name into v_name from public.members where id = v_me;
  insert into public.app_notifications (org_id, member_id, type, payload, ref_id)
  values (v_org, v_l.created_by, 'buddy_ok',
          jsonb_build_object('from_name', v_name, 'from_id', v_me,
                             'text', v_name || ' 用你的邀請連結成為牌咖了'),
          v_me);

  return jsonb_build_object('ok', true, 'added', true, 'buddy_id', v_l.created_by, 'buddy_name', v_from.display_name,
                            'message', '你和 ' || v_from.display_name || ' 成為牌咖了');
end $function$;

revoke execute on function public.create_buddy_invite_link_tx() from public, anon;
revoke execute on function public.redeem_buddy_invite_tx(text) from public, anon;
grant  execute on function public.create_buddy_invite_link_tx() to authenticated;
grant  execute on function public.redeem_buddy_invite_tx(text) to authenticated;

-- ============================================================
-- 驗證（單一 SELECT；不 raise，硬規則 1.8）—— 結構；行為另外跑 sql/checks/2026-10-14_驗牌咖邀請連結.sql
-- ============================================================
select
  case when to_regclass('public.buddy_invite_links') is not null
        and (select relrowsecurity from pg_class where oid = 'public.buddy_invite_links'::regclass)
        and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'buddy_invite_links')
       then '✅' else '🔴' end || ' ① 新表在、RLS 開、0 條 policy' as "①",
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
              and proname in ('create_buddy_invite_link_tx', 'redeem_buddy_invite_tx')) = 2
       then '✅' else '🔴' end || ' ② 兩支函式各一個版本' as "②",
  case when has_function_privilege('authenticated', 'public.create_buddy_invite_link_tx()', 'execute')
        and has_function_privilege('authenticated', 'public.redeem_buddy_invite_tx(text)', 'execute')
        and not has_function_privilege('anon', 'public.create_buddy_invite_link_tx()', 'execute')
        and not has_function_privilege('anon', 'public.redeem_buddy_invite_tx(text)', 'execute')
       then '✅' else '🔴' end || ' ③ 只給登入的人叫' as "③",
  case when not has_table_privilege('anon', 'public.buddy_invite_links', 'select')
       then '✅' else '🔴' end || ' ④ 前端直接讀不到連結表' as "④";
