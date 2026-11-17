-- ════════════════════════════════════════════════════════════════════
-- 2026-11-18 同桌文字評價（使用者拍板）
--
-- 規則：
--   · 打完牌在「給同桌評價」按讚或倒讚之後，可以「匿名留一句話（選填）」，30 字以內
--   · 好評、負評都公開：任何人看個人卡都看得到（同桌怎麼說 ＋ 全部留言抽屜）
--   · 匿名：前端拿不到是誰寫的；總部後台看得到（出事查得到人）
--   · 不顯示日期與門市（使用者 11-18）；留言從第一則到現在全部看得到，不限 90 天
--   · 不用人審：送出時擋電話、聯絡方式、賭博用詞、髒話；被評的人可以檢舉，總部下架
--     被評的人**不能自己隱藏**（負評公開之後，能自己藏的話負評都會被藏掉）
--   · 寫字不多給小熊餅乾（每個讚 1 個照舊）
--
-- 好評還是負評**看他按的是讚還是倒讚**（後端查 member_likes／member_dislikes），不收前端的說法。
-- 讚或倒讚收回、或讚換成倒讚 ⇒ 那一則留言跟著刪掉（觸發器），不改 like_player_tx／dislike_player_tx。
--
-- ⚠ 線上跑的時候檢字函式還是舊版（會誤擋「值得信賴」「online」），這份檔案裡的是改過的；
--   線上由 2026-11-18_評價檢字修正.sql 補上。驗證 8/8 ✅（使用者 11-18 在 Dashboard 跑）。
--
-- 權限：2026-09-29 起預設全關 ⇒ 給前端的三支、後台的兩支都在最後明確 grant。
--   會員功能的身分一律 current_member_id()；後台走 can('review.write')。
-- ════════════════════════════════════════════════════════════════════

-- ① 表 ───────────────────────────────────────────────────────────────
create table if not exists public.member_reviews (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references public.orgs(id),
  session_id          uuid not null references public.table_sessions(id),
  rater_id            uuid not null references public.members(id),
  target_id           uuid not null references public.members(id),
  good                boolean not null,
  body                text not null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  reported_at         timestamptz,
  removed_at          timestamptz,
  removed_by_staff_id uuid references public.staff(id),
  constraint member_reviews_not_self check (rater_id <> target_id),
  constraint member_reviews_body_len check (char_length(body) between 1 and 30),
  constraint uq_member_reviews unique (session_id, rater_id, target_id)
);
comment on table public.member_reviews is
  '同桌文字評價（2026-11-18）：按讚或倒讚之後留的一句話。好評負評都公開、匿名；rater_id 只有總部後台看得到。good 由讚／倒讚決定，不收前端的說法';
comment on column public.member_reviews.reported_at is '被評的人按「檢舉」的時間；總部處理完（下架或不處理）會清掉或留著，見 admin_review_action_tx';
comment on column public.member_reviews.removed_at is '總部下架的時間；有值就不再出現在任何客人看得到的地方';

create index if not exists ix_member_reviews_target
  on public.member_reviews (target_id, created_at desc) where removed_at is null;
create index if not exists ix_member_reviews_reported
  on public.member_reviews (reported_at) where reported_at is not null and removed_at is null;

alter table public.member_reviews enable row level security;   -- 0 條 policy：只有 DEFINER 函式進得去
revoke all on public.member_reviews from anon, authenticated;

-- ② 讚／倒讚收回 ⇒ 那一則留言跟著刪 ─────────────────────────────────
create or replace function public._trg_vote_removed_drop_review()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'member_likes' then
    delete from member_reviews
     where session_id = old.session_id and rater_id = old.liker_id and target_id = old.target_id and good;
  else
    delete from member_reviews
     where session_id = old.session_id and rater_id = old.rater_id and target_id = old.target_id and not good;
  end if;
  return old;
end $$;
revoke execute on function public._trg_vote_removed_drop_review() from public, anon, authenticated;

drop trigger if exists trg_member_likes_drop_review on public.member_likes;
create trigger trg_member_likes_drop_review after delete on public.member_likes
  for each row when (old.session_id is not null) execute function public._trg_vote_removed_drop_review();
drop trigger if exists trg_member_dislikes_drop_review on public.member_dislikes;
create trigger trg_member_dislikes_drop_review after delete on public.member_dislikes
  for each row execute function public._trg_vote_removed_drop_review();

-- ③ 這句話能不能送（null ＝ 可以；否則回給客人看的原因） ─────────────────
--   ⚠ 只擋「一定不該出現」的：電話、聯絡方式、賭博用詞、髒話。其餘靠檢舉。
create or replace function public._review_text_problem(p_body text)
returns text language plpgsql immutable as $$
declare
  t text := lower(regexp_replace(coalesce(p_body, ''), '\s+', '', 'g'));
begin
  -- 連續 7 個以上數字（中間可以有 - 或空白）＝ 電話號碼
  if coalesce(p_body, '') ~ '[0-9０-９][0-9０-９ \-]{5,}[0-9０-９]' then
    return '不能留電話號碼或 LINE ID，請改一下再送出';
  end if;
  -- ⚠ 不寫單獨的「賴」（會擋到「值得信賴」），也不寫單獨的 line（會擋到 online）
  if t ~ '((^|[^a-z])line|ｌｉｎｅ|加賴|我的賴|賴[:：]|賴id|微信|wechat|instagram|telegram|@[a-z0-9._]{3,})' then
    return '不能留電話號碼或 LINE ID，請改一下再送出';
  end if;
  if t ~ '(賭|輸錢|贏錢|下注|現金|轉帳|匯款|抽頭)' then
    return '這句話有不能使用的字（牌桌上不談錢），請改一下再送出';
  end if;
  if t ~ '(幹你|幹妳|幹林|幹拎|幹恁|操你|靠北|靠杯|靠腰|他媽|你媽|三小|王八|白痴|白癡|智障|去死|廢物|腦殘|垃圾|雞掰|機掰|婊)' then
    return '這句話有不適合的字，請改一下再送出';
  end if;
  return null;
end $$;
revoke execute on function public._review_text_problem(text) from public, anon, authenticated;

-- ④ 送出（或清空）一則留言 ─────────────────────────────────────────
create or replace function public.set_review_tx(p_target uuid, p_session uuid, p_body text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_me   uuid;
  v_org  uuid;
  v_good boolean;
  v_body text := btrim(regexp_replace(coalesce(p_body, ''), '\s+', ' ', 'g'));
  v_both int;
  v_why  text;
begin
  -- 身分只認登入的本人，不收「你是誰」的參數
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  if p_target is null or p_session is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_args', 'message', '缺少牌局或對象');
  end if;
  if p_target = v_me then
    return jsonb_build_object('ok', false, 'reason', 'self', 'message', '不能評價自己');
  end if;
  select org_id into v_org from table_sessions where id = p_session and mode <> 'friendly';
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '找不到這一場牌局');
  end if;
  -- 兩個人都要坐過那一場（同讚、倒讚那道門）
  select count(*) into v_both from session_players sp
   where sp.session_id = p_session and sp.member_id in (v_me, p_target);
  if v_both < 2 then
    return jsonb_build_object('ok', false, 'reason', 'not_tablemates', 'message', '只能評價同一場牌局的人');
  end if;

  -- 清空 ＝ 不留言（刪掉這一場給他的那一則）
  if v_body = '' then
    delete from member_reviews where session_id = p_session and rater_id = v_me and target_id = p_target;
    return jsonb_build_object('ok', true, 'cleared', true);
  end if;

  -- 好評還是負評：看他按的是讚還是倒讚
  if exists (select 1 from member_likes where liker_id = v_me and target_id = p_target and session_id = p_session) then
    v_good := true;
  elsif exists (select 1 from member_dislikes where rater_id = v_me and target_id = p_target and session_id = p_session) then
    v_good := false;
  else
    return jsonb_build_object('ok', false, 'reason', 'no_vote', 'message', '先按讚或倒讚，才能留一句話');
  end if;

  if char_length(v_body) > 30 then
    return jsonb_build_object('ok', false, 'reason', 'too_long', 'message', '最多 30 個字');
  end if;
  v_why := public._review_text_problem(v_body);
  if v_why is not null then
    return jsonb_build_object('ok', false, 'reason', 'blocked_word', 'message', v_why);
  end if;

  -- 已經被總部下架的那一則不會因為重新送出就回來（where removed_at is null）
  insert into member_reviews (org_id, session_id, rater_id, target_id, good, body)
  values (v_org, p_session, v_me, p_target, v_good, v_body)
  on conflict (session_id, rater_id, target_id) do update
    set good = excluded.good, body = excluded.body, updated_at = now(), reported_at = null
    where member_reviews.removed_at is null;
  return jsonb_build_object('ok', true, 'good', v_good);
end $$;

-- ⑤ 列出某人收到的留言（個人卡與抽屜共用） ──────────────────────────
--   🔴 不回傳是誰寫的、不回傳門市；created_at 只當翻頁用，前端不畫
create or replace function public.list_member_reviews_tx(
  p_target uuid, p_filter text default 'all', p_before timestamptz default null, p_limit int default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_me    uuid;
  v_lim   int := least(greatest(coalesce(p_limit, 30), 1), 100);
  v_good  int;
  v_bad   int;
  v_items jsonb;
  v_more  boolean;
  v_last  timestamptz;
begin
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  if p_target is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_args', 'message', '缺少對象');
  end if;
  -- 隱藏的會員、或兩人之間有封鎖 ⇒ 什麼都沒有（同個人卡）
  if exists (select 1 from members where id = p_target and hidden_at is not null)
     or exists (select 1 from member_blocks
                 where (blocker_id = v_me and blocked_id = p_target) or (blocker_id = p_target and blocked_id = v_me)) then
    return jsonb_build_object('ok', true, 'good', 0, 'bad', 0, 'mine', false, 'items', '[]'::jsonb, 'has_more', false);
  end if;

  select count(*) filter (where good), count(*) filter (where not good)
    into v_good, v_bad
    from member_reviews where target_id = p_target and removed_at is null;

  with page as (
    select r.id, r.good, r.body, r.created_at, r.reported_at
      from member_reviews r
     where r.target_id = p_target and r.removed_at is null
       and (p_filter is null or p_filter = 'all' or (p_filter = 'good' and r.good) or (p_filter = 'bad' and not r.good))
       and (p_before is null or r.created_at < p_before)
     order by r.created_at desc, r.id desc
     limit v_lim + 1
  ), numbered as (select page.*, row_number() over (order by created_at desc, id desc) as rn from page)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'good', good, 'body', body,
           -- 只有被評的本人才知道自己檢舉過哪一則
           'reported', case when v_me = p_target then reported_at is not null else false end)
         order by rn) filter (where rn <= v_lim), '[]'::jsonb),
         count(*) > v_lim,
         max(created_at) filter (where rn = v_lim)
    into v_items, v_more, v_last
    from numbered;

  return jsonb_build_object('ok', true, 'good', v_good, 'bad', v_bad, 'mine', v_me = p_target,
                            'items', v_items, 'has_more', v_more,
                            'next_before', case when v_more then v_last end);
end $$;

-- ⑥ 被評的人檢舉一則 ───────────────────────────────────────────────
create or replace function public.report_review_tx(p_review uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_me uuid;
  v_n  int;
begin
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  update member_reviews set reported_at = coalesce(reported_at, now())
   where id = p_review and target_id = v_me and removed_at is null;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這則留言');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ⑦ 總部後台：列出留言（看得到是誰寫的） ─────────────────────────────
create or replace function public.admin_list_reviews_tx(p_only_reported boolean default true, p_limit int default 200)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can('review.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限');
  end if;
  return jsonb_build_object('ok', true, 'items', coalesce((
    select jsonb_agg(x order by x.sort_reported desc, x.created_at desc)
      from (
        select r.id, r.good, r.body, r.created_at, r.reported_at, r.removed_at,
               r.reported_at is not null and r.removed_at is null as sort_reported,
               ra.id as rater_id, ra.display_name as rater_name,
               ta.id as target_id, ta.display_name as target_name,
               s.name as store_name, r.session_id
          from member_reviews r
          join members ra on ra.id = r.rater_id
          join members ta on ta.id = r.target_id
          join table_sessions ts on ts.id = r.session_id
          left join stores s on s.id = ts.store_id
         where r.org_id = public.current_org_id()
           and (not coalesce(p_only_reported, true) or (r.reported_at is not null and r.removed_at is null))
         order by r.created_at desc
         limit least(greatest(coalesce(p_limit, 200), 1), 500)
      ) x), '[]'::jsonb));
end $$;

-- ⑧ 總部後台：下架／恢復／不處理（清掉檢舉） ─────────────────────────
create or replace function public.admin_review_action_tx(p_review uuid, p_action text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid;
  v_n     int;
begin
  if not public.can('review.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限');
  end if;
  v_staff := (select staff_id from public.current_staff());   -- 誰按的：從登入身分取，不收前端
  if p_action = 'remove' then
    update member_reviews set removed_at = now(), removed_by_staff_id = v_staff
     where id = p_review and org_id = public.current_org_id() and removed_at is null;
  elsif p_action = 'restore' then
    update member_reviews set removed_at = null, removed_by_staff_id = null, reported_at = null
     where id = p_review and org_id = public.current_org_id() and removed_at is not null;
  elsif p_action = 'dismiss' then
    update member_reviews set reported_at = null
     where id = p_review and org_id = public.current_org_id() and reported_at is not null;
  else
    return jsonb_build_object('ok', false, 'reason', 'bad_action', 'message', '不認得的動作');
  end if;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '這則留言的狀態已經變了，請重新整理');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ⑨ 權限（預設全關，這裡明確開） ───────────────────────────────────
revoke execute on function public.set_review_tx(uuid, uuid, text) from public, anon;
revoke execute on function public.list_member_reviews_tx(uuid, text, timestamptz, int) from public, anon;
revoke execute on function public.report_review_tx(uuid) from public, anon;
revoke execute on function public.admin_list_reviews_tx(boolean, int) from public, anon;
revoke execute on function public.admin_review_action_tx(uuid, text) from public, anon;
grant execute on function public.set_review_tx(uuid, uuid, text) to authenticated;
grant execute on function public.list_member_reviews_tx(uuid, text, timestamptz, int) to authenticated;
grant execute on function public.report_review_tx(uuid) to authenticated;
grant execute on function public.admin_list_reviews_tx(boolean, int) to authenticated;
grant execute on function public.admin_review_action_tx(uuid, text) to authenticated;

-- ⑩ 驗證（單一 SELECT；不用 raise，硬規則 1.8） ───────────────────────
select * from (values
  ('① 表在、RLS 開、0 條 policy',
   case when to_regclass('public.member_reviews') is not null
         and (select relrowsecurity from pg_class where oid = 'public.member_reviews'::regclass)
         and (select count(*) from pg_policies where schemaname = 'public' and tablename = 'member_reviews') = 0
        then '✅' else '🔴' end),
  ('② 前端與 anon 碰不到表',
   case when not has_table_privilege('anon', 'public.member_reviews', 'select')
         and not has_table_privilege('authenticated', 'public.member_reviews', 'select')
        then '✅' else '🔴' end),
  ('③ 三支會員函式 authenticated 叫得動、anon 叫不動',
   case when has_function_privilege('authenticated', 'public.set_review_tx(uuid,uuid,text)', 'execute')
         and has_function_privilege('authenticated', 'public.list_member_reviews_tx(uuid,text,timestamptz,int)', 'execute')
         and has_function_privilege('authenticated', 'public.report_review_tx(uuid)', 'execute')
         and not has_function_privilege('anon', 'public.set_review_tx(uuid,uuid,text)', 'execute')
         and not has_function_privilege('anon', 'public.list_member_reviews_tx(uuid,text,timestamptz,int)', 'execute')
        then '✅' else '🔴' end),
  ('④ 後台兩支 authenticated 叫得動（裡面再問 can）',
   case when has_function_privilege('authenticated', 'public.admin_list_reviews_tx(boolean,int)', 'execute')
         and has_function_privilege('authenticated', 'public.admin_review_action_tx(uuid,text)', 'execute')
        then '✅' else '🔴' end),
  ('⑤ 檢字函式前端叫不動',
   case when not has_function_privilege('authenticated', 'public._review_text_problem(text)', 'execute')
         and not has_function_privilege('anon', 'public._review_text_problem(text)', 'execute')
        then '✅' else '🔴' end),
  ('⑥ 兩個觸發器都掛上了',
   case when (select count(*) from pg_trigger
               where tgname in ('trg_member_likes_drop_review', 'trg_member_dislikes_drop_review') and not tgisinternal) = 2
        then '✅' else '🔴' end),
  ('⑦ 擋得住（電話／LINE／賭博／髒話）',
   case when public._review_text_problem('加我 0912-345-678') is not null
         and public._review_text_problem('我的賴 abc123') is not null
         and public._review_text_problem('加我 line：abc123') is not null
         and public._review_text_problem('輸錢也笑笑的') is not null
         and public._review_text_problem('靠北很慢') is not null
        then '✅' else '🔴' end),
  ('⑧ 正對照：正常的話不會被誤擋',
   case when public._review_text_problem('下次再約！自摸那把超帥') is null
         and public._review_text_problem('牌品有待加強') is null
         and public._review_text_problem('10 點準時到') is null
         and public._review_text_problem('教我算台，感謝！') is null
         and public._review_text_problem('人很值得信賴') is null
         and public._review_text_problem('線上 online 也約') is null
        then '✅' else '🔴' end)
) v(項目, 結果);
