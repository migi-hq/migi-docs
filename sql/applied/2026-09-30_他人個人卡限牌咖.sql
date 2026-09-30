/* ============================================================
   他人個人卡：公開與限牌咖分家（後端先擋，前端只畫遮罩）
   2026-09-30 · MIGI 咪吉麻將

   ── 使用者拍板 ─────────────────────────────────────────
   公開      頭像 · 名字 · 稱號 · 段位 · 獲讚 · 自我介紹
   限牌咖    打法與作息標籤 · 你和他（同桌次數、上次同桌、常一起打）
             · 成績 · 最近亮點 · 寶貝牌
   同團成員視同牌咖。只做在會員 App（POS 店員照舊看得到完整資料）。
   畫面：非牌咖那一段蓋霧面遮罩 ＋ 深墨膠囊「尚未加為牌咖」
   📄 預覽 docs/_資產/他人個人卡_牌咖限定_預覽.html

   🔴 **鎖做在後端**：不是牌咖時，限牌咖的欄位**根本不放進回傳**。
     只在前端畫遮罩的話，打開開發者工具就看得到。
   🔴 非牌咖只回一個是非值 `can_invite`（同桌過、可以邀），**不回同桌次數**。

   ── 這一份做五件事 ──────────────────────────────────────
   ① 成績算法抽成 `_member_stats_core(org, member)`（前端叫不到）
      `get_my_stats_tx` 改成「問身分 → 叫 core」，回傳**逐字不變**。
      🎯 理由：個人卡的成績要跟成績頁**同一份定義**。各算一份的症狀是
        「成績頁說我勝率 58%、牌咖看到 60%」，而且不報錯。
      ⚠ core 是從線上 `get_my_stats_tx` 的全文**機械轉出來**的（只拿掉身分那兩行），
        不是重抄 —— 重抄一份 200 行的函式一定會漏東西。
   ② 「同桌次數／上次同桌／常一起打」抽成 `_pair_history(org, a, b)`
      `list_buddies_tx` 改成叫它（原本寫在它自己的 lateral 裡）。回傳形狀不變。
   ③ 成績公開設定（members.see_score）拿掉「所有人」
      只剩「牌咖」（預設）與「只有自己」；選「只有自己」的人，**連牌咖也看不到成績**。
      現在選「所有人」的改成「牌咖」。舊版前端送「所有人」視同「牌咖」，不報錯。
      ⚠ 它只管「成績」那一塊；其他限牌咖的區塊一律給牌咖，不受這個設定影響。
   ④ 新建 `get_member_card_tx(p_target uuid)` —— 個人卡唯一的資料來源
   ⑤ `get_season_leaderboard_tx` 的排行榜與名人堂加回 `id`
      🔴 2026-09-04 刻意拿掉，理由是「拿榜上的 id 就能看別人的錢包」。
        那個洞 2026-09-20 已經堵死（所有會員功能只認 JWT，前端送誰的 id 都沒用），
        而沒有 id 的話從排行榜點進去的卡**判斷不了你們是不是牌咖**（使用者 2026-09-30 拍板加回）。

   ── 權限（硬規則 2.7：新東西預設全關）───────────────────
   _member_stats_core / _pair_history   不給前端（只有函式內部叫）
   get_member_card_tx                   authenticated（會員要登入才看得到別人）
   get_my_stats_tx / list_buddies_tx / set_my_see_score_tx / get_season_leaderboard_tx
                                        CREATE OR REPLACE，原本的授權保留

   ── 前端相依 ─────────────────────────────────────────
   可以先跑：舊版前端照舊能用（成績頁、牌咖清單、排行榜回傳都只多不少；
   成績設定送「所有人」也照收）。前端改完再推。
   ============================================================ */

-- ⓪ 前置檢查：線上的 get_my_stats_tx 必須還是「身分那兩行 ＋ 本體」的形狀，
--    不是的話 ① 的機械轉換會做錯 —— 整份停下來。
do $$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.get_my_stats_tx(uuid,uuid)'::regprocedure);
  if v_def !~ 'p_member_id := public\.current_member_id\(\);' then
    raise exception '⓪ get_my_stats_tx 的形狀跟預期不同（找不到身分那一行），整份停下來先人工看';
  end if;
  if (select count(*) from regexp_matches(v_def, 'current_member_id\(\)', 'g')) <> 1 then
    raise exception '⓪ get_my_stats_tx 裡提到身分函式的地方不是剛好一處，機械轉換不安全';
  end if;
end $$;

-- ═══ ① 成績算法抽成 core ══════════════════════════════════
do $$
declare v_def text; v_core text;
begin
  v_def := pg_get_functiondef('public.get_my_stats_tx(uuid,uuid)'::regprocedure);
  v_core := replace(v_def, 'FUNCTION public.get_my_stats_tx(', 'FUNCTION public._member_stats_core(');
  v_core := regexp_replace(v_core,
    'p_member_id := public\.current_member_id\(\);\s*if p_member_id is null then raise exception ''[^'']*'' using errcode = ''28000''; end if;',
    '/* 身分由呼叫端決定：get_my_stats_tx 傳登入的本人，get_member_card_tx 傳要看的那個人。 */');
  if v_core = v_def or position('current_member_id' in v_core) > 0 or position('_member_stats_core(' in v_core) = 0 then
    raise exception '① 轉換沒有成功（身分那兩行沒拿掉，或函式名沒換到）';
  end if;
  execute v_core;
end $$;

revoke execute on function public._member_stats_core(uuid, uuid) from public;
revoke execute on function public._member_stats_core(uuid, uuid) from anon, authenticated;

comment on function public._member_stats_core(uuid, uuid) is
  '成績的唯一算法（2026-09-30 從 get_my_stats_tx 抽出）。不問身分 ⇒ 前端叫不到；'
  '成績頁（get_my_stats_tx）與他人個人卡（get_member_card_tx）都叫這一支。改算法改這裡。';

create or replace function public.get_my_stats_tx(p_org_id uuid, p_member_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
begin
  /* 🔴 身分一律從 JWT 取，不採信呼叫端（待辦 14）。前端照樣送 p_member_id，這裡忽略。
     算法在 _member_stats_core（2026-09-30 抽出，他人個人卡也叫同一支）。 */
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  return public._member_stats_core(p_org_id, p_member_id);
end $function$;

-- ═══ ② 兩人的同桌紀錄 ════════════════════════════════════
create or replace function public._pair_history(p_org_id uuid, p_a uuid, p_b uuid)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  /* 你們兩個都坐過、而且已收桌的場次（2026-09-30 從 list_buddies_tx 抽出，規則逐字不變）。
     ⚠ 用開打時間（activated_at）不是收桌時間 —— 凌晨兩點收桌的晚場，問的是「幾點開始打」。
     回傳 { n 同桌場數, last_at 上次同桌, pattern 常一起打 }，pattern 是結構不是句子。 */
  with shared as (
    select coalesce(s.activated_at, s.started_at, s.ended_at) as at
      from session_players me
      join session_players op on op.session_id = me.session_id and op.member_id = p_b
      join table_sessions s   on s.id = me.session_id and s.deleted_at is null and s.status = 'completed'
     where me.member_id = p_a and me.org_id = p_org_id
  ), tagged as (
    select extract(dow from (at at time zone 'Asia/Taipei'))::int as wd,
           public.migi_slot_of(at) as slot
      from shared where at is not null
  ), tot as (select count(*) as n from tagged),
  best_ws as (
    select wd, slot, count(*) as n from tagged
     group by wd, slot order by count(*) desc, slot, wd limit 1
  ),
  best_s as (
    select slot, count(*) as n from tagged
     group by slot order by count(*) desc, slot limit 1
  )
  select jsonb_build_object(
    'n',       (select count(*) from shared),
    'last_at', (select max(at) from shared),
    'pattern', case
      /* 「常」的兩個門檻，缺一不可：① 總同桌 ≥ 3 場 ② 眾數要過半（n × 2 > 總數）。
         「最多的那一個」不等於「常」。 */
      when (select n from tot) < 3 then null
      when (select n from best_ws) * 2 > (select n from tot) then
        jsonb_build_object('weekday', (select wd from best_ws), 'slot', (select slot from best_ws), 'n', (select n from best_ws))
      when (select n from best_s) * 2 > (select n from tot) then
        /* 退化：星期分散但時段集中 → 只講時段 */
        jsonb_build_object('weekday', null, 'slot', (select slot from best_s), 'n', (select n from best_s))
      else null
    end)
$function$;

revoke execute on function public._pair_history(uuid, uuid, uuid) from public;
revoke execute on function public._pair_history(uuid, uuid, uuid) from anon, authenticated;

create or replace function public.list_buddies_tx(p_org_id uuid, p_member uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  -- 【身分 2026-09-29】店員可以代客人操作；其他人只認登入的本人
  if not exists (select 1 from public.current_staff()) then
    p_member := public.current_member_id();
    if p_member is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', b.buddy_id, 'nickname', m.display_name,
      'rank', m.rank, 'title', m.title, 'likes_count', m.likes_count,
      'avatar_url', m.avatar_url, 'co_play_count', b.co_play_count,
      'avatar_source', m.avatar_source, 'avatar_photo_path', m.avatar_photo_path,
      'avatar_bear', m.avatar_bear,
      'linked_at', b.linked_at,
      'last_played_at', (h.v ->> 'last_at')::timestamptz,
      /* 常一起打：回結構不回句子。2026-09-30 起算法在 _pair_history（個人卡共用）。 */
      'play_pattern', h.v -> 'pattern'
    ) order by b.linked_at desc)
    from mahjong_buddies b
    /* 隱藏中的牌咖不列。關係列不刪，恢復之後自動回來。 */
    join members m on m.id = b.buddy_id and m.deleted_at is null and m.hidden_at is null
    cross join lateral (select public._pair_history(p_org_id, p_member, b.buddy_id) as v) h
    where b.member_id = p_member and b.org_id = p_org_id and b.deleted_at is null
  ), '[]'::jsonb);
end $function$;

-- ═══ ③ 成績公開設定：拿掉「所有人」 ══════════════════════════
update members set see_score = '牌咖', updated_at = now()
 where see_score = '所有人';

alter table members drop constraint if exists members_see_score_check;
do $$
declare r record;
begin
  -- 約束名稱不一定叫 members_see_score_check（硬規則 3.8：名稱不等於內容）⇒ 依內容找出來刪
  for r in select c.conname from pg_constraint c
            where c.conrelid = 'public.members'::regclass and c.contype = 'c'
              and pg_get_constraintdef(c.oid) like '%see_score%'
  loop
    execute format('alter table public.members drop constraint %I', r.conname);
  end loop;
end $$;
alter table members add constraint members_see_score_check
  check (see_score in ('牌咖', '只有自己'));

create or replace function public.set_my_see_score_tx(p_org_id uuid, p_member_id uuid, p_see_score text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  /* 身分一律從 JWT 取，不採信呼叫端（待辦 14）。 */
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  /* 2026-09-30 起只有兩個選項。舊版前端還可能送「所有人」⇒ 視同「牌咖」，不讓它報錯
     （成績本來就只給牌咖看，「所有人」已經沒有意義）。 */
  if p_see_score = '所有人' then p_see_score := '牌咖'; end if;
  if p_see_score not in ('牌咖','只有自己') then raise exception '成績公開範圍格式錯誤'; end if;
  update members set see_score = p_see_score, updated_at = now()
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
end $function$;

comment on column members.see_score is
  '誰能看我的成績：牌咖（預設）／只有自己。2026-09-30 拿掉「所有人」—— 成績一律只給牌咖。'
  '只管個人卡的「成績」區塊；其他限牌咖的區塊不受這個設定影響。';

-- ═══ ④ 他人個人卡 ═════════════════════════════════════════
create or replace function public.get_member_card_tx(p_target uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_me    uuid := public.current_member_id();
  v_org   uuid;
  t       members%rowtype;
  v_rel   text;
  v_pair  jsonb;
  v_stats jsonb;
  v_core  jsonb;
  v_out   jsonb;
begin
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  select org_id into v_org from members where id = v_me;

  select * into t from members where id = p_target and org_id = v_org and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這位會員');
  end if;
  -- 任一方封鎖了另一方 ⇒ 看不到（不說是誰封鎖誰）
  if v_me <> p_target and public._blocked_between(v_org, v_me, p_target) then
    return jsonb_build_object('ok', false, 'reason', 'blocked', 'message', '看不到這位會員的資料');
  end if;

  v_rel := case
    when v_me = p_target then 'self'
    when t.hidden_at is not null then 'hidden'
    when exists (select 1 from mahjong_buddies b
                  where b.org_id = v_org and b.deleted_at is null
                    and ((b.member_id = v_me and b.buddy_id = p_target)
                      or (b.member_id = p_target and b.buddy_id = v_me))) then 'buddy'
    when exists (select 1 from team_members a
                   join team_members b on b.team_id = a.team_id
                   join teams tm on tm.id = a.team_id and tm.deleted_at is null
                  where a.member_id = v_me and b.member_id = p_target
                    and a.left_at is null and b.left_at is null) then 'team'
    else 'none' end;

  /* 公開的部分：所有人都看得到。
     ⚠ 隱藏中的會員，這些欄位本來就已經被換成問號（member_hidden 保險箱），這裡不必再判斷。 */
  v_out := jsonb_build_object(
    'ok', true, 'id', t.id, 'rel', v_rel,
    'name', t.display_name, 'title', t.title, 'rank', t.rank, 'likes', t.likes_count,
    'about', t.about,
    'avatar_source', t.avatar_source, 'avatar_bear', t.avatar_bear,
    'avatar_url', t.avatar_url, 'avatar_photo_path', t.avatar_photo_path,
    'locked', v_rel not in ('self', 'buddy', 'team'));

  if v_rel = 'none' then
    /* 🔴 只回「能不能邀」，不回同桌次數 —— 同桌次數本身是限牌咖的資料。
       規則照舊：同桌對局過才能加牌咖。 */
    v_out := v_out || jsonb_build_object('can_invite',
      exists (select 1 from session_players me
                join session_players op on op.session_id = me.session_id and op.member_id = p_target
                join table_sessions s   on s.id = me.session_id and s.deleted_at is null and s.status = 'completed'
               where me.member_id = v_me and me.org_id = v_org));
    return v_out;
  end if;
  if v_rel = 'hidden' then
    return v_out || jsonb_build_object('can_invite', false);
  end if;

  -- ── 以下只有本人、牌咖、同團成員拿得到 ──
  v_pair := public._pair_history(v_org, v_me, p_target);

  if t.see_score = '只有自己' and v_rel <> 'self' then
    v_stats := jsonb_build_object('private', true);
  else
    v_core := public._member_stats_core(v_org, p_target);
    /* 只拿個人卡要畫的幾格（本季）。min_games 一起給：未達門檻時前端顯示「—」，
       同成績頁的規則（「100% · 2 場」是誤導）。 */
    v_stats := jsonb_build_object(
      'private',    false,
      'min_games',  v_core -> 'min_games',
      'games',      v_core -> 'season' -> 'games',
      'avg_rank',   v_core -> 'season' -> 'avg_rank',
      'scored',     v_core -> 'season' -> 'scored',
      'wins',       v_core -> 'season' -> 'wins',
      'best_score', v_core -> 'season' -> 'best_score');
  end if;

  return v_out || jsonb_build_object(
    'can_invite', false,
    'style',      t.style,
    'sched',      t.sched,
    'baby_tile',  t.baby_tile,
    'together',   v_pair,
    'stats',      v_stats,
    /* 最近亮點（最大台的一手）要等電子計分的每一局資料（hands），接上之前一律 null。 */
    'highlight',  null);
end $function$;

revoke execute on function public.get_member_card_tx(uuid) from public;
revoke execute on function public.get_member_card_tx(uuid) from anon;
grant  execute on function public.get_member_card_tx(uuid) to authenticated;

comment on function public.get_member_card_tx(uuid) is
  '會員 App 他人個人卡的唯一資料來源（2026-09-30）。公開：頭像／名字／稱號／段位／獲讚／自我介紹；'
  '限牌咖（含同團）：標籤、寶貝牌、同桌紀錄、成績（對方設「只有自己」時連牌咖也不給）。'
  '非牌咖只回 can_invite，不回同桌次數。';

-- ═══ ⑤ 排行榜與名人堂加回 id ══════════════════════════════
create or replace function public.get_season_leaderboard_tx(p_org_id uuid, p_limit integer default 10)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_season jsonb;
  v_rows   jsonb;
  v_champ  jsonb;
  v_n      int;
begin
  /* 上限保護：前端送 100000 的話這支會把整個榜撈出來。least 而不是 raise。 */
  v_n := greatest(1, least(coalesce(p_limit, 10), 100));

  v_season := public.current_season_tx(p_org_id);

  /* 沒有進行中的賽季時不要回 ok:false —— 那是正常狀態（兩季之間的空檔）。 */
  if v_season is null then
    return jsonb_build_object('ok', true, 'season', null,
                              'rows', '[]'::jsonb, 'champions', '[]'::jsonb);
  end if;

  /* 本季排行。名次借 season_rank_rows_display_tx（與成績頁的「全國排名」同一份定義）。
     🔴 2026-09-30 加回 id：點進去的個人卡要靠它判斷「你們是不是牌咖」。
       2026-09-04 拿掉它的理由（拿 id 就能看別人錢包）09-20 已經不成立 ——
       所有會員功能只認 JWT，前端送誰的 id 都沒用。 */
  select coalesce(jsonb_agg(x order by x.rank_no), '[]'::jsonb) into v_rows
    from (
      select r.rank_no, r.rating, r.games,
             r.member_id           as id,
             m.display_name        as name,
             public.rank_from_rating(r.rating) as rank_label
        from public.season_rank_rows_display_tx(
               p_org_id, (v_season ->> 'starts_at')::timestamptz, null) r
        join members m on m.id = r.member_id
       order by r.rank_no
       limit v_n
    ) x;

  /* 名人堂：歷代雀神熊。再擋一次測試帳號與隱藏中的會員（冠軍紀錄保留，恢復之後回來）。 */
  select coalesce(jsonb_agg(x order by x.awarded_at desc), '[]'::jsonb) into v_champ
    from (
      select c.season, c.rating, c.awarded_at,
             c.member_id           as id,
             s.label               as season_label,
             m.display_name        as name,
             public.rank_from_rating(c.rating) as rank_label
        from season_champions c
        join members m on m.id = c.member_id
                      and m.deleted_at is null
                      and m.hidden_at is null
                      and m.is_test = false
        left join rank_seasons s on s.org_id = c.org_id and s.code = c.season
       where c.org_id = p_org_id
       order by c.awarded_at desc
       limit 20
    ) x;

  return jsonb_build_object(
    'ok', true, 'season', v_season, 'rows', v_rows, 'champions', v_champ);
end;
$function$;

-- ═══ 驗證（不可以 raise —— 那會把上面全部回滾，硬規則 1.8）══════════
do $$
declare
  v_msg text := '';
  ok  text := '✅ '; bad text := '🔴 ';
  f   text;
  v_anon_exp boolean; v_auth_exp boolean; v_pub boolean;
begin
  -- ① core 存在、前端叫不到；成績頁改成叫 core
  select exists (select 1 from aclexplode(coalesce(p.proacl,'{}')) a where a.grantee in ('anon'::regrole::oid,'authenticated'::regrole::oid) and a.privilege_type='EXECUTE'),
         (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type='EXECUTE'))
    into v_auth_exp, v_pub
    from pg_proc p where p.oid = 'public._member_stats_core(uuid,uuid)'::regprocedure;
  v_msg := v_msg || case when not v_auth_exp and not v_pub then ok else bad end
        || '① _member_stats_core 前端叫不到（明確授權 ' || v_auth_exp || '、PUBLIC ' || v_pub || '）' || E'\n';
  f := pg_get_functiondef('public.get_my_stats_tx(uuid,uuid)'::regprocedure);
  v_msg := v_msg || case when f ~ 'return public\._member_stats_core\(' and f ~ 'current_member_id\(\)' then ok else bad end
        || '① get_my_stats_tx 先問身分再叫 core' || E'\n';
  f := pg_get_functiondef('public._member_stats_core(uuid,uuid)'::regprocedure);
  v_msg := v_msg || case when position('current_member_id' in f) = 0 and f ~ 'season_rank_rows_display_tx' then ok else bad end
        || '① core 沒有身分判斷、而且帶著原本的算法（有全國排名那一段）' || E'\n';

  -- ② 同桌紀錄抽出來，牌咖清單改叫它
  f := pg_get_functiondef('public.list_buddies_tx(uuid,uuid)'::regprocedure);
  v_msg := v_msg || case when f ~ 'public\._pair_history\(' and f !~ 'best_ws' then ok else bad end
        || '② list_buddies_tx 改叫 _pair_history（自己那份算法已拿掉）' || E'\n';
  select exists (select 1 from aclexplode(coalesce(p.proacl,'{}')) a where a.grantee in ('anon'::regrole::oid,'authenticated'::regrole::oid) and a.privilege_type='EXECUTE'),
         (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type='EXECUTE'))
    into v_auth_exp, v_pub
    from pg_proc p where p.oid = 'public._pair_history(uuid,uuid,uuid)'::regprocedure;
  v_msg := v_msg || case when not v_auth_exp and not v_pub then ok else bad end
        || '② _pair_history 前端叫不到' || E'\n';

  -- ③ 成績設定
  v_msg := v_msg || case when not exists (select 1 from members where see_score = '所有人') then ok else bad end
        || '③ 沒有人還是「所有人」（牌咖 ' || (select count(*) from members where see_score='牌咖')
        || '、只有自己 ' || (select count(*) from members where see_score='只有自己') || '）' || E'\n';
  v_msg := v_msg || case when exists (select 1 from pg_constraint c where c.conrelid='public.members'::regclass
                                        and pg_get_constraintdef(c.oid) like '%see_score%' and pg_get_constraintdef(c.oid) not like '%所有人%')
                          and (select count(*) from pg_constraint c where c.conrelid='public.members'::regclass
                                  and pg_get_constraintdef(c.oid) like '%see_score%') = 1
                     then ok else bad end
        || '③ see_score 只剩一條約束，而且不收「所有人」' || E'\n';

  -- ④ 個人卡：只給登入的人
  select exists (select 1 from aclexplode(coalesce(p.proacl,'{}')) a where a.grantee = 'anon'::regrole::oid and a.privilege_type='EXECUTE'),
         exists (select 1 from aclexplode(coalesce(p.proacl,'{}')) a where a.grantee = 'authenticated'::regrole::oid and a.privilege_type='EXECUTE'),
         (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type='EXECUTE'))
    into v_anon_exp, v_auth_exp, v_pub
    from pg_proc p where p.oid = 'public.get_member_card_tx(uuid)'::regprocedure;
  v_msg := v_msg || case when v_auth_exp and not v_anon_exp and not v_pub then ok else bad end
        || '④ get_member_card_tx 只給 authenticated（anon ' || v_anon_exp || '、PUBLIC ' || v_pub || '）' || E'\n';

  -- ⑤ 排行榜帶 id（問「回傳物件裡有沒有 id 這個鍵」，不掃註解）
  f := pg_get_functiondef('public.get_season_leaderboard_tx(uuid,integer)'::regprocedure);
  v_msg := v_msg || case when (select count(*) from regexp_matches(f, 'member_id\s+as id', 'g')) = 2 then ok else bad end
        || '⑤ 排行榜與名人堂都帶 id' || E'\n';

  -- 多載檢查：這幾支都只能有一個版本
  v_msg := v_msg || case when (select count(*) from pg_proc where pronamespace='public'::regnamespace
                                  and proname in ('get_my_stats_tx','_member_stats_core','_pair_history','list_buddies_tx',
                                                  'set_my_see_score_tx','get_member_card_tx','get_season_leaderboard_tx')) = 7
                     then ok else bad end
        || '七支函式各只有一個版本（沒有長出多載）';

  perform set_config('migi.v', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有驗證訊息') as "驗證";
