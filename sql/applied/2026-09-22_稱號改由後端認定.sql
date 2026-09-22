-- ════════════════════════════════════════════════════════════════════
-- 2026-09-22 稱號改由後端認定（待辦 40）
--
-- 在此之前：
--   · App 的稱號清單是寫死的六個（三屆雀神／自由店店霸…），五個是假的
--   · 「擁有哪些稱號」存在 member_app_state.titles，而那一欄由
--     save_app_state_tx 的 p_titles 寫入 —— anon 年代叫得動、前端說了算、
--     而且只增不減（寫一次就永遠解鎖）
--
-- 改成：**擁有的稱號是算出來的，不是存下來的**
--   ① 新手上路           人人都有
--   ② 成就的 grants_title 解鎖了那枚成就就有（永久，成就日後下架也不收回）
--   ③ 賽季冠軍           season_champions 每一列一個「<年> <季>季雀神熊」
--   ④ member_app_state.titles  留給日後**後端**發的來源（抽獎），前端不再寫得進去
--
-- 本檔做的事：
--   A. 兩枚已上線的成就填 grants_title（其餘 19 枚還沒匯入，匯入時一起填）
--   B. _member_titles(member)      唯一一份「這個人有哪些稱號」的定義
--   C. get_my_titles_tx()          App 的稱號抽屜讀這支（已擁有 ＋ 還沒解鎖的）
--   D. set_my_title_tx             改成問 B，不再問前端寫進去的清單
--   E. save_app_state_tx           簽名不變，但**不再寫稱號**（p_titles 忽略）
--   F. get_my_profile_tx           titles_unlocked 改讀 B
--
-- ⚠ E 不拿掉參數：前端（v0922 之前的版本）仍然會送 p_titles，
--   拿掉的話那些裝置的小熊存檔會整支 404。前端不送之後再 contract。
-- ⚠ 全部是 CREATE OR REPLACE 或新建 ⇒ 不會丟既有的 GRANT。
-- ════════════════════════════════════════════════════════════════════

-- ── A. 已上線的兩枚 ────────────────────────────────────────────────
update achievements set grants_title = '新手村制霸', updated_at = now()
 where code = 'onboarding_29' and deleted_at is null;
update achievements set grants_title = 'MIGI', updated_at = now()
 where code = 'migi_02' and deleted_at is null;

-- ── B. 唯一一份定義 ────────────────────────────────────────────────
create or replace function public._member_titles(p_member uuid)
returns table(title text, source text, got_at timestamptz)
language sql stable security definer set search_path to 'public'
as $$
  select distinct on (x.title) x.title, x.source, x.got_at
    from (
      select '新手上路'::text as title, '註冊就有'::text as source, m.created_at as got_at, 0 as pri
        from members m where m.id = p_member and m.deleted_at is null

      union all
      /* 🔴 刻意不過濾 a.deleted_at / a.is_active：稱號永久（成就與稱號設計 §6.1），
         成就日後下架，已經拿到的人不應該被收回。 */
      select a.grants_title, '成就「' || a.name || '」', ma.unlocked_at, 1
        from member_achievements ma
        join achievements a on a.id = ma.achievement_id
       where ma.member_id = p_member and ma.status = 'unlocked'
         and a.grants_title is not null and btrim(a.grants_title) <> ''

      union all
      /* 賽季名稱「2026 段位秋季賽」→「2026 秋季雀神熊」。
         ⚠ 從 rank_seasons.label 推，不另寫一份季別對照 ——
           兩份的話日後改賽季名稱，稱號會跟著漂。 */
      select case when s.label ~ '^\d{4} 段位.季賽$'
                  then regexp_replace(s.label, '^(\d{4}) 段位(.)季賽$', '\1 \2季雀神熊')
                  else coalesce(s.label, c.season) || ' 雀神熊' end,
             coalesce(s.label, c.season) || ' 冠軍', c.awarded_at, 2
        from season_champions c
        left join rank_seasons s on s.org_id = c.org_id and s.code = c.season
       where c.member_id = p_member

      union all
      select t, '特別獲得', null::timestamptz, 3
        from member_app_state st, jsonb_array_elements_text(st.titles) t
       where st.member_id = p_member
    ) x
   order by x.title, x.pri, x.got_at nulls last
$$;

revoke execute on function public._member_titles(uuid) from public;
revoke execute on function public._member_titles(uuid) from anon, authenticated;
grant  execute on function public._member_titles(uuid) to service_role;

-- ── C. App 的稱號抽屜 ──────────────────────────────────────────────
create or replace function public.get_my_titles_tx()
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_me uuid; v_org uuid; v_owned jsonb; v_locked jsonb; v_wear text;
begin
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  select org_id, title into v_org, v_wear from members where id = v_me and deleted_at is null;

  select coalesce(jsonb_agg(jsonb_build_object('title', t.title, 'source', t.source, 'got_at', t.got_at)
                            order by (t.title = '新手上路') desc, t.got_at nulls last), '[]'::jsonb)
    into v_owned from public._member_titles(v_me) t;

  /* 還沒拿到的：只列**看得到**的成就。
     ⚠ silhouette 的成就不列 —— 列出稱號等於把隱藏條件講出來。 */
  select coalesce(jsonb_agg(jsonb_build_object('title', a.grants_title, 'achievement', a.name,
                                               'condition', a.condition_text)
                            order by a.sort, a.code), '[]'::jsonb)
    into v_locked
    from achievements a
   where a.org_id = v_org and a.deleted_at is null and a.is_active
     and a.grants_title is not null and btrim(a.grants_title) <> ''
     and a.visibility = 'visible'
     and not exists (select 1 from public._member_titles(v_me) t where t.title = a.grants_title);

  return jsonb_build_object('equipped', coalesce(v_wear, '新手上路'), 'owned', v_owned, 'locked', v_locked);
end $$;

revoke execute on function public.get_my_titles_tx() from public;
revoke execute on function public.get_my_titles_tx() from anon;
grant  execute on function public.get_my_titles_tx() to authenticated, service_role;

-- ── D. 配戴：問 B ──────────────────────────────────────────────────
create or replace function public.set_my_title_tx(p_org_id uuid, p_member_id uuid, p_title text)
returns void
language plpgsql security definer set search_path to 'public'
as $$
begin
  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。 */
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  /* 2026-09-22：擁有與否改問 _member_titles（事實算出來的），
     不再問前端寫進去的那份清單。「新手上路」也在那支裡面，不必另外放行。 */
  if not exists (select 1 from public._member_titles(p_member_id) t where t.title = p_title) then
    raise exception '稱號未解鎖';
  end if;
  update members set title = p_title
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
end $$;

-- ── E. 小熊存檔：不再寫稱號 ────────────────────────────────────────
create or replace function public.save_app_state_tx(p_org_id uuid, p_member_id uuid, p_bear jsonb, p_titles jsonb default null::jsonb)
returns void
language plpgsql security definer set search_path to 'public'
as $$
begin
  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。 */
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  if pg_column_size(p_bear) > 8192 then raise exception 'bear state 過大'; end if;

  /* 🔴 2026-09-19：`snacks` 一律忽略 —— 點心是獎勵，來源只有發放／消耗那兩支。
     🔴 2026-09-22：**稱號參數一律忽略**（待辦 40）。
       稱號是成就不是偏好，由 _member_titles 從事實算出來；
       這支只存小熊（他自己的選擇）。參數留在簽名裡只是為了舊版前端不 404。 */
  insert into member_app_state(member_id, org_id, bear, titles, updated_at)
  values (p_member_id, p_org_id, coalesce(p_bear, '{}'::jsonb) - 'snacks', '[]'::jsonb, now())
  on conflict (member_id) do update set
    bear = (coalesce(excluded.bear, '{}'::jsonb) - 'snacks')
           || jsonb_build_object('snacks', coalesce(member_app_state.bear -> 'snacks', '{}'::jsonb)),
    updated_at = now();
end $$;

-- ── F. 個人檔案的 titles_unlocked 改讀 B ───────────────────────────
do $$
declare v_old text; v_new text;
begin
  v_old := pg_get_functiondef('public.get_my_profile_tx(uuid,uuid)'::regprocedure);
  v_new := replace(v_old,
    $x$'titles_unlocked', coalesce(s.titles, '[]'::jsonb)$x$,
    $x$'titles_unlocked', (select coalesce(jsonb_agg(t.title order by t.got_at nulls last), '[]'::jsonb) from public._member_titles(m.id) t)$x$);
  -- 換不到就整份不要提交（寧可失敗也不要一半）
  if v_new = v_old then raise exception 'get_my_profile_tx 找不到 titles_unlocked 那一段，整份回滾'; end if;
  execute v_new;
end $$;

-- ════════════════════════════════════════════════════════════════════
-- 驗證（單一 SELECT，不 raise —— 硬規則 1.8）
-- ⚠ 驗的是交易內的狀態；跑完之後 Claude 會另外查一次線上。
-- ════════════════════════════════════════════════════════════════════
select * from (
  select 1 as n, '① 兩枚成就有稱號' as 項目,
         case when (select count(*) from achievements where deleted_at is null
                     and ((code='onboarding_29' and grants_title='新手村制霸') or (code='migi_02' and grants_title='MIGI'))) = 2
              then '✅' else '🔴' end as 結果,
         (select string_agg(code||'→'||coalesce(grants_title,'∅'), '、') from achievements
           where code in ('onboarding_29','migi_02') and deleted_at is null) as 細節
  union all
  select 2, '② 賽季稱號推得出來（正對照）',
         case when (select count(*) from rank_seasons where label ~ '^\d{4} 段位.季賽$')
                 = (select count(*) from rank_seasons) then '✅' else '🔴' end,
         (select string_agg(label||'→'||regexp_replace(label, '^(\d{4}) 段位(.)季賽$', '\1 \2季雀神熊'), '、' order by code) from rank_seasons)
  union all
  select 3, '③ 每個會員都至少有「新手上路」',
         case when not exists (select 1 from members m where m.deleted_at is null
                                and not exists (select 1 from public._member_titles(m.id) t where t.title='新手上路'))
              then '✅' else '🔴' end,
         (select count(*)::text || ' 人' from members where deleted_at is null)
  union all
  select 4, '④ 現在戴著的稱號都還擁有（改完不會有人戴著沒有的東西）',
         case when not exists (select 1 from members m where m.deleted_at is null and m.title is not null
                                and not exists (select 1 from public._member_titles(m.id) t where t.title=m.title))
              then '✅' else '🔴' end,
         (select string_agg(distinct coalesce(title,'∅'), '、') from members where deleted_at is null)
  union all
  select 5, '⑤ 個人檔案改讀 _member_titles',
         case when pg_get_functiondef('public.get_my_profile_tx(uuid,uuid)'::regprocedure) like '%_member_titles(m.id)%'
              then '✅' else '🔴' end, null
  union all
  select 6, '⑥ 配戴改問 _member_titles',
         case when pg_get_functiondef('public.set_my_title_tx(uuid,uuid,text)'::regprocedure) like '%_member_titles(p_member_id)%'
              then '✅' else '🔴' end, null
  union all
  select 7, '⑦ 小熊存檔不再合併稱號',
         case when pg_get_functiondef('public.save_app_state_tx(uuid,uuid,jsonb,jsonb)'::regprocedure) !~ 'titles\s*='
              then '✅' else '🔴' end, null
  union all
  select 8, '⑧ _member_titles 前端叫不動（明確 ＋ PUBLIC 兩個方向）',
         case when not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                                where p.oid='public._member_titles(uuid)'::regprocedure
                                  and a.privilege_type='EXECUTE'
                                  and a.grantee in (0, 'anon'::regrole::oid, 'authenticated'::regrole::oid))
              then '✅' else '🔴' end, null
  union all
  select 9, '⑨ get_my_titles_tx：authenticated 有、anon 與 PUBLIC 沒有',
         case when exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                            where p.oid='public.get_my_titles_tx()'::regprocedure and a.privilege_type='EXECUTE'
                              and a.grantee='authenticated'::regrole::oid)
               and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                            where p.oid='public.get_my_titles_tx()'::regprocedure and a.privilege_type='EXECUTE'
                              and a.grantee in (0, 'anon'::regrole::oid))
              then '✅' else '🔴' end, null
  union all
  select 10, '⑩ 既有三支的 authenticated 沒被弄丟',
         case when (select count(*) from pg_proc p where p.oid in (
                      'public.get_my_profile_tx(uuid,uuid)'::regprocedure,
                      'public.set_my_title_tx(uuid,uuid,text)'::regprocedure,
                      'public.save_app_state_tx(uuid,uuid,jsonb,jsonb)'::regprocedure)
                    and has_function_privilege('authenticated', p.oid, 'execute')) = 3
              then '✅' else '🔴' end, null
) v order by n;
