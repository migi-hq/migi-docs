/* ============================================================
   給同桌評價：讚的右邊加「倒讚」
   2026-10-28 · 使用者：「把加牌咖都刪除，改成按讚右邊放倒讚」

   ── 使用者拍板的兩條規則 ─────────────────────────────
   誰看得到   只有總部後台。被倒讚的人、其他客人都看不到（沒有次數、沒有通知）
   拿來做什麼 先只記錄，日後再決定（配桌避開、提醒店員都還沒做）

   ── 規則 ────────────────────────────────────────────
   · 一場牌局對同一個人最多一個倒讚；只能倒讚同一場坐過的人；不能倒讚自己
   · 讚與倒讚二選一：按倒讚會撤掉同一場對他的讚（讚數一起扣回），按讚會撤掉倒讚
   · 倒讚不發小熊餅乾、不觸發成就、不改任何畫面上的數字

   ── 做了什麼 ────────────────────────────────────────
   ① 新表 member_dislikes：開 RLS、0 條 policy、前端角色一律收回 ⇒ 只有 DEFINER 函式與後台讀得到
   ② 新函式 dislike_player_tx(對象, 開或關, 場次)：身分只認登入的本人（current_member_id）
   ③ like_player_tx：按讚時順手撤掉同一場的倒讚（撈線上全文 replace，沒換到就整份回滾）
   ④ _game_row：每位玩家多回 disliked_by_me（給「給同桌評價」打開時預先點亮；只回「我有沒有倒讚他」）
   ============================================================ */

-- ① 表
create table if not exists public.member_dislikes (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.orgs(id) on delete restrict,
  rater_id   uuid not null references public.members(id) on delete restrict,
  target_id  uuid not null references public.members(id) on delete restrict,
  session_id uuid not null references public.table_sessions(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint member_dislikes_not_self check (rater_id <> target_id)
);
create unique index if not exists uq_dislike_per_session on public.member_dislikes (rater_id, target_id, session_id);
create index if not exists idx_dislikes_target on public.member_dislikes (target_id);
alter table public.member_dislikes enable row level security;
revoke all on table public.member_dislikes from public, anon, authenticated;
comment on table public.member_dislikes is
  '給同桌評價的倒讚（2026-10-28）。只有總部後台看得到，被倒讚的人與其他客人都看不到；先只記錄。一場對同一人最多一個，與讚二選一。';

-- ② 按倒讚
create or replace function public.dislike_player_tx(p_target uuid, p_on boolean, p_session uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_me    uuid;
  v_org   uuid;
  v_both  int;
  v_like  uuid;
begin
  -- 身分只認登入的本人，不收「你是誰」的參數
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  if p_target is null or p_session is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_args', 'message', '缺少牌局或對象');
  end if;
  if p_target = v_me then
    return jsonb_build_object('ok', false, 'reason', 'self', 'message', '不能倒讚自己');
  end if;
  -- 兩個人都要坐過那一場（同按讚發餅乾那道門）：否則隨便送一個場次就能倒讚任何人
  select count(*) into v_both from session_players sp
   where sp.session_id = p_session and sp.member_id in (v_me, p_target);
  if v_both < 2 then
    return jsonb_build_object('ok', false, 'reason', 'not_tablemates', 'message', '只能評價同一場牌局的人');
  end if;
  select org_id into v_org from table_sessions where id = p_session;

  if p_on then
    insert into member_dislikes (org_id, rater_id, target_id, session_id)
    values (v_org, v_me, p_target, p_session)
    on conflict (rater_id, target_id, session_id) do nothing;
    -- 二選一：同一場對他的讚撤掉，讚數一起扣回（同 like_player_tx 取消讚的寫法）
    delete from member_likes
     where liker_id = v_me and target_id = p_target and session_id = p_session
    returning id into v_like;
    if v_like is not null then
      update members set likes_count = greatest(0, likes_count - 1) where id = p_target;
    end if;
  else
    delete from member_dislikes where rater_id = v_me and target_id = p_target and session_id = p_session;
  end if;
  return jsonb_build_object('ok', true);
end $function$;

revoke all on function public.dislike_player_tx(uuid, boolean, uuid) from public, anon;
grant execute on function public.dislike_player_tx(uuid, boolean, uuid) to authenticated;

-- ③④ 改兩支既有函式：撈線上全文 → replace → 每一處都確認真的換到（沒換到就 raise，整份回滾、線上不動）
do $$
declare
  v_old text;
  v_new text;
begin
  -- ③ 按讚時撤掉同一場的倒讚
  v_old := pg_get_functiondef('public.like_player_tx(uuid,uuid,uuid,boolean,uuid)'::regprocedure);
  v_new := replace(v_old,
    'if p_on then',
    'if p_on then' || chr(10) ||
    '    -- 讚與倒讚二選一（2026-10-28）：同一場對同一人的倒讚撤掉' || chr(10) ||
    '    if p_session is not null then' || chr(10) ||
    '      delete from member_dislikes where rater_id = p_liker and target_id = p_target and session_id = p_session;' || chr(10) ||
    '    end if;');
  if v_new = v_old then raise exception '③ like_player_tx 的插入點對不上，沒有換到'; end if;
  execute v_new;

  -- ④ 牌局詳情每位玩家多回「我有沒有倒讚他」
  v_old := pg_get_functiondef('public._game_row(uuid,uuid,uuid)'::regprocedure);
  v_new := replace(v_old,
    '''liked_by_me'',  exists (select 1 from member_likes l',
    '''disliked_by_me'', exists (select 1 from member_dislikes dl' || chr(10) ||
    '                                        where dl.rater_id = p_member_id and dl.target_id = p.member_id' || chr(10) ||
    '                                          and dl.session_id = m.id),' || chr(10) ||
    '               ''liked_by_me'',  exists (select 1 from member_likes l');
  if v_new = v_old then raise exception '④ _game_row 的插入點對不上，沒有換到'; end if;
  execute v_new;
end $$;

/* ── 驗證（單一 SELECT，不 raise）──────────────────────── */
select
  case when exists (select 1 from pg_class where oid = 'public.member_dislikes'::regclass and relrowsecurity)
        and not exists (select 1 from pg_policy where polrelid = 'public.member_dislikes'::regclass)
       then '✅ ① member_dislikes 開了 RLS、0 條 policy' else '🔴 ① 表或 RLS 不對' end
  || E'\n' ||
  case when not has_table_privilege('anon', 'public.member_dislikes', 'SELECT')
        and not has_table_privilege('authenticated', 'public.member_dislikes', 'SELECT')
       then '✅ ② 前端角色讀不到倒讚表' else '🔴 ② 前端角色讀得到倒讚表' end
  || E'\n' ||
  case when (select count(*) from pg_proc where proname = 'dislike_player_tx' and pronamespace = 'public'::regnamespace) = 1
        and (select prosecdef from pg_proc where oid = 'public.dislike_player_tx(uuid,boolean,uuid)'::regprocedure)
        and has_function_privilege('authenticated', 'public.dislike_player_tx(uuid,boolean,uuid)', 'EXECUTE')
        and not exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, '{}')) a
                         where p.oid = 'public.dislike_player_tx(uuid,boolean,uuid)'::regprocedure
                           and a.privilege_type = 'EXECUTE' and a.grantee in (0, 'anon'::regrole::oid))
       then '✅ ③ dislike_player_tx：一個版本、DEFINER、登入的人叫得動、anon 與 PUBLIC 都沒有'
       else '🔴 ③ dislike_player_tx 的版本或授權不對' end
  || E'\n' ||
  case when pg_get_functiondef('public.like_player_tx(uuid,uuid,uuid,boolean,uuid)'::regprocedure) ~ 'delete from member_dislikes where rater_id = p_liker'
        and (select count(*) from pg_proc where proname = 'like_player_tx' and pronamespace = 'public'::regnamespace) = 1
       then '✅ ④ 按讚會撤掉倒讚（like_player_tx 仍是一個版本）' else '🔴 ④ like_player_tx 沒改到' end
  || E'\n' ||
  case when pg_get_functiondef('public._game_row(uuid,uuid,uuid)'::regprocedure) ~ '''disliked_by_me'', exists'
        and (select count(*) from pg_proc where proname = '_game_row' and pronamespace = 'public'::regnamespace) = 1
       then '✅ ⑤ 牌局詳情回傳 disliked_by_me' else '🔴 ⑤ _game_row 沒改到' end
  as "驗證";
