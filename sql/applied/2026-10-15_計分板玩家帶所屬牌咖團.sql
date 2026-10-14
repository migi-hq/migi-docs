-- ============================================================
-- 2026-10-15 智慧計分板：每位玩家多帶「所屬牌咖團」（團名 ＋ 團徽）
-- 使用者：「平板畫面在每個人物卡最右邊新增所屬牌咖團，有團徽跟團名」；一人好幾團時「最早加入的那一團」
--
-- ① 新增 _tbl_member_team(會員)：回最早加入、還在團裡、團沒刪掉的那一團
--    { name, crest_source, crest_path, crest_blocked, crest_emoji }；沒有團回 null
--    · 隱藏帳號的人不回團（他在平板上是問號，掛著團名等於把人認出來）
--    · 不回團的 id —— 平板只要畫，不需要認團
--    · 只給後端內部叫（計分板狀態是 DEFINER，owner 叫得到），前端叫不到
-- ② _tbl_state_for_device 的 players 每一列多一個 'team' 鍵（其餘一字不改）
--    POS 觀看畫面（pos_tbl_watch_tx）也走這支，所以一起有
--
-- 跑法：Supabase SQL Editor 整份執行，看最後那一格
-- ============================================================

create or replace function public._tbl_member_team(p_member uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
           'name', t.name, 'crest_source', t.crest_source, 'crest_path', t.crest_path,
           'crest_blocked', t.crest_blocked, 'crest_emoji', t.crest_emoji)
    from public.team_members tm
    join public.teams t   on t.id = tm.team_id and t.deleted_at is null
    join public.members m on m.id = tm.member_id
   where tm.member_id = p_member
     and tm.left_at is null
     and m.hidden_at is null
     and t.org_id = m.org_id
   order by tm.joined_at, tm.id
   limit 1
$$;

revoke execute on function public._tbl_member_team(uuid) from public;
revoke execute on function public._tbl_member_team(uuid) from anon, authenticated;
grant  execute on function public._tbl_member_team(uuid) to service_role;

-- ② 只在 players 那一段的最後一個鍵後面接上 team；其餘照線上原文重建
do $$
declare
  v_def text;
  v_new text;
  v_old_anchor text := $a$'device_label', (select td.label from table_devices td where td.id = sp.device_id))$a$;
  v_new_anchor text := $a$'device_label', (select td.label from table_devices td where td.id = sp.device_id),
           'team', public._tbl_member_team(sp.member_id))   -- 所屬牌咖團（2026-10-15）$a$;
begin
  v_def := pg_get_functiondef('public._tbl_state_for_device(table_devices)'::regprocedure);
  if position('_tbl_member_team' in v_def) > 0 then
    perform set_config('migi.team', '⚪ 計分板狀態早就帶團了（這份跑過一次），沒有再改', true);
    return;
  end if;
  v_new := replace(v_def, v_old_anchor, v_new_anchor);
  if v_new = v_def then
    perform set_config('migi.team', '🔴 計分板狀態裡找不到要接的位置，沒有改（線上版本跟預期不同）', true);
    return;
  end if;
  execute v_new;
  perform set_config('migi.team', '✅ 計分板狀態已加上 team', true);
end $$;

-- ============================================================
-- 驗證（單一 SELECT；不 raise，提交後另外查線上）
-- ============================================================
with
f as (select p.oid, p.proacl from pg_proc p
       where p.pronamespace = 'public'::regnamespace and p.proname = '_tbl_member_team'),
s as (select p.oid from pg_proc p
       where p.pronamespace = 'public'::regnamespace and p.proname = '_tbl_state_for_device'),
-- 正對照：有團的人一定拿得到團名
with_team as (select tm.member_id from team_members tm
                join teams t on t.id = tm.team_id and t.deleted_at is null
                join members m on m.id = tm.member_id and m.hidden_at is null
               where tm.left_at is null order by tm.joined_at limit 1),
-- 負對照：沒有任何團的人回 null
no_team as (select m.id from members m
             where m.deleted_at is null
               and not exists (select 1 from team_members tm where tm.member_id = m.id and tm.left_at is null)
             limit 1)
select concat_ws(E'\n',
  current_setting('migi.team', true),
  case when (select count(*) from f) = 1 then '✅' else '🔴' end || ' ① _tbl_member_team 存在（' || (select count(*) from f) || ' 支）',
  case when not exists (select 1 from f, aclexplode(f.proacl) a
                         where a.privilege_type = 'EXECUTE'
                           and a.grantee in (0, 'anon'::regrole::oid, 'authenticated'::regrole::oid))
            and (select proacl from f) is not null
       then '✅' else '🔴' end || ' ② 前端叫不到（PUBLIC／anon／authenticated 都沒有）',
  case when (select count(*) from s) = 1
            and position('_tbl_member_team' in pg_get_functiondef((select oid from s))) > 0
       then '✅' else '🔴' end || ' ③ 計分板狀態只有一個版本，而且帶了 team',
  coalesce((select case when public._tbl_member_team(member_id) ->> 'name' is not null
                        then '✅ ④ 有團的人拿得到團名：' || (public._tbl_member_team(member_id) ->> 'name')
                        else '🔴 ④ 有團的人卻拿不到團' end from with_team), '⚪ ④ 沒有任何人在團裡，測不了'),
  coalesce((select case when public._tbl_member_team(id) is null then '✅ ⑤ 沒有團的人回 null'
                        else '🔴 ⑤ 沒有團的人卻拿到團' end from no_team), '⚪ ⑤ 找不到沒有團的人，測不了')
) as "計分板玩家帶所屬牌咖團 · 驗證";
