-- ════════════════════════════════════════════════════════════════════
-- 2026-10-20 他人個人卡：同團成員與牌咖看到的不一樣
-- ────────────────────────────────────────────────────────────────────
-- 使用者：「同團跟牌咖可以看到個人資料要有區別，牌咖可以全開」（同日拍板）
--
--                    公開那一半   打法作息標籤   你和他   成績（本季）  最近亮點  寶貝牌
--   本人、牌咖          ✅            ✅          ✅        ✅            ✅        ✅
--   同團（不是牌咖）    ✅            ✅          ✅        🔒            🔒        🔒
--   都不是              ✅            🔒          🔒        🔒            🔒        🔒
--
-- · 鎖在後端：同團時 stats、baby_tile、highlight 根本不在回傳裡，多回 'partial' = true 讓前端畫鎖住的區塊。
-- · 'locked' 不變（同團仍是 false）⇒ 同團成員的頭像不模糊。
-- · 同團成員也能按「＋ 加牌咖」：can_invite 回 true（同團就是認識的人，不必先同桌過）。
--   ⚠ 「同桌過才能加」本來就只是前端看 can_invite 的規則，送邀請那支函式從來不檢查 —— 這裡不改它。
--
-- 簽名不變 ⇒ CREATE OR REPLACE，授權不會掉。
-- ════════════════════════════════════════════════════════════════════

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
    'locked', v_rel not in ('self', 'buddy', 'team'),
    'partial', v_rel = 'team');

  if v_rel = 'none' then
    /* 🔴 只回「能不能邀」，不回同桌次數 —— 同桌次數本身是限牌咖的資料。
       規則照舊：同桌對局過才能加牌咖。 */
    v_out := v_out || jsonb_build_object('can_invite',
      exists (select 1 from session_players me
                join session_players op on op.session_id = me.session_id and op.member_id = p_target
                join table_sessions s   on s.id = me.session_id and s.deleted_at is null and (s.status = 'completed' or me.finish_rank is not null)
               where me.member_id = v_me and me.org_id = v_org));
    return v_out;
  end if;
  if v_rel = 'hidden' then
    return v_out || jsonb_build_object('can_invite', false);
  end if;

  -- ── 以下只有本人、牌咖、同團成員拿得到 ──
  v_pair := public._pair_history(v_org, v_me, p_target);

  if v_rel = 'team' then
    /* 🆕 2026-10-20：同團（還不是牌咖）只看到標籤與「你和他」。
       成績、寶貝牌、最近亮點刻意不放進回傳 —— 前端看 partial 畫鎖住的區塊。 */
    return v_out || jsonb_build_object(
      'can_invite', true,
      'style',      t.style,
      'sched',      t.sched,
      'together',   v_pair);
  end if;

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

-- ── 驗證（單一 SELECT；不 raise，硬規則 1.8）──────────────────────────
with f as (
  select p.oid, pg_get_functiondef(p.oid) as d
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.proname = 'get_member_card_tx'
)
select concat_ws(E'\n',
  case when (select count(*) from f) = 1 then '✅ ① 只有一個版本' else '🔴 ① 版本數 ' || (select count(*) from f) end,
  case when (select d from f) ~ '''partial'',\s*v_rel = ''team''' then '✅ ② 回傳多了 partial（同團才是 true）' else '🔴 ② 沒有 partial' end,
  case when (select d from f) ~ 'if v_rel = ''team'' then\s*/\*[^*]*\*/\s*return v_out' then '✅ ③ 同團在讀成績之前就回傳' else '🔴 ③ 同團那一段不在成績之前' end,
  case when exists (select 1 from f, aclexplode((select proacl from pg_proc where oid = f.oid)) a
                     where a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE')
       then '✅ ④ authenticated 仍叫得動' else '🔴 ④ authenticated 的授權掉了' end,
  case when not exists (select 1 from f, aclexplode((select proacl from pg_proc where oid = f.oid)) a
                         where a.grantee in (0, 'anon'::regrole::oid) and a.privilege_type = 'EXECUTE')
       then '✅ ⑤ anon／PUBLIC 都叫不動' else '🔴 ⑤ anon 或 PUBLIC 叫得動' end
) as "驗證";
