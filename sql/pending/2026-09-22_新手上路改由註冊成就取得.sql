-- ════════════════════════════════════════════════════════════════════
-- 2026-09-22 「新手上路」改由成就「新手報到」取得（使用者拍板）
--          ＋ 賽季稱號的來源文字改成「2026 秋季賽冠軍」
--
-- 在此之前：_member_titles 對每個會員**無條件**給新手上路（寫死的一行）。
-- 改成：它是 onboarding_01「新手報到」（完成會員註冊）的 grants_title，
--       跟其他稱號走同一條路 —— 稱號只從成就與賽季來，沒有例外。
--
-- 🔴 **一定要先補解鎖紀錄**：新手報到的解鎖觸發器
--   （trg_members_achievements → member_registered）是後來才加的，
--   線上 5 個會員**全部在那之前註冊，0 人解鎖過**，而 5 人全部正戴著新手上路。
--   不補的話，改完那一刻 5 人都變成「戴著自己沒有的稱號」。
--   補的是事實（他們確實註冊過），解鎖時間用各自的註冊時間，不是 now()。
--
-- ✅ 新會員不受影響：members.title 預設 '新手上路'，
--   而同一個 INSERT 的觸發器會解鎖新手報到 ⇒ 一註冊就同時擁有。
-- ════════════════════════════════════════════════════════════════════

-- ── A. 新手報到發「新手上路」 ─────────────────────────────────────
update achievements set grants_title = '新手上路', updated_at = now()
 where code = 'onboarding_01' and deleted_at is null;

-- ── B. 補解鎖：觸發器上線前就註冊的會員 ───────────────────────────
insert into member_achievements (org_id, member_id, achievement_id, status, current_tier, unlocked_at, last_idem)
select m.org_id, m.id, a.id, 'unlocked', 1, m.created_at, 'backfill:2026-09-22:registered'
  from members m
  join achievements a on a.org_id = m.org_id and a.code = 'onboarding_01' and a.deleted_at is null
 where m.deleted_at is null
on conflict (member_id, achievement_id) do update
   set status = 'unlocked', current_tier = 1,
       unlocked_at = coalesce(member_achievements.unlocked_at, excluded.unlocked_at),
       last_idem = coalesce(member_achievements.last_idem, excluded.last_idem),
       updated_at = now()
 where member_achievements.status <> 'unlocked';

-- ── C. _member_titles：拿掉「人人都有」那一行 ──────────────────────
create or replace function public._member_titles(p_member uuid)
returns table(title text, source text, got_at timestamptz)
language sql stable security definer set search_path to 'public'
as $$
  select distinct on (x.title) x.title, x.source, x.got_at
    from (
      /* 🔴 2026-09-22：新手上路不再無條件給 —— 它是成就「新手報到」的稱號，
         跟其他稱號走同一條路（下面這一段）。
         🔴 刻意不過濾 a.deleted_at / a.is_active：稱號永久（成就與稱號設計 §6.1），
         成就日後下架，已經拿到的人不應該被收回。 */
      select a.grants_title as title, '成就「' || a.name || '」' as source, ma.unlocked_at as got_at, 1 as pri
        from member_achievements ma
        join achievements a on a.id = ma.achievement_id
       where ma.member_id = p_member and ma.status = 'unlocked'
         and a.grants_title is not null and btrim(a.grants_title) <> ''

      union all
      /* 賽季名稱「2026 段位秋季賽」→ 稱號「2026 秋季雀神熊」、來源「2026 秋季賽冠軍」。
         ⚠ 從 rank_seasons.label 推，不另寫一份季別對照 ——
           兩份的話日後改賽季名稱，稱號會跟著漂。 */
      select case when s.label ~ '^\d{4} 段位.季賽$'
                  then regexp_replace(s.label, '^(\d{4}) 段位(.)季賽$', '\1 \2季雀神熊')
                  else coalesce(s.label, c.season) || ' 雀神熊' end,
             case when s.label ~ '^\d{4} 段位.季賽$'
                  then regexp_replace(s.label, '^(\d{4}) 段位(.)季賽$', '\1 \2季賽冠軍')
                  else coalesce(s.label, c.season) || ' 冠軍' end,
             c.awarded_at, 2
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

-- ════════════════════════════════════════════════════════════════════
-- 驗證（單一 SELECT，不 raise —— 硬規則 1.8）
-- ════════════════════════════════════════════════════════════════════
select * from (
  select 1 as n, '① 新手報到發新手上路' as 項目,
         case when (select grants_title from achievements where code = 'onboarding_01' and deleted_at is null) = '新手上路'
              then '✅' else '🔴' end as 結果, null::text as 細節
  union all
  select 2, '② 每個會員都解鎖了新手報到',
         case when not exists (select 1 from members m where m.deleted_at is null
                                and not exists (select 1 from member_achievements ma join achievements a on a.id = ma.achievement_id
                                                 where ma.member_id = m.id and a.code = 'onboarding_01' and ma.status = 'unlocked'))
              then '✅' else '🔴' end,
         (select count(*)::text || ' 人' from members where deleted_at is null)
  union all
  select 3, '③ 補的解鎖時間是註冊時間，不是今天',
         case when not exists (select 1 from member_achievements ma join achievements a on a.id = ma.achievement_id
                                join members m on m.id = ma.member_id
                                where a.code = 'onboarding_01' and ma.last_idem = 'backfill:2026-09-22:registered'
                                  and ma.unlocked_at <> m.created_at)
              then '✅' else '🔴' end, null
  union all
  select 4, '④ 現在戴著的稱號都還擁有（最重要的一格）',
         case when not exists (select 1 from members m where m.deleted_at is null and m.title is not null
                                and not exists (select 1 from public._member_titles(m.id) t where t.title = m.title))
              then '✅' else '🔴' end,
         (select string_agg(distinct coalesce(title, '∅'), '、') from members where deleted_at is null)
  union all
  select 5, '⑤ 函式裡不再有「人人都有」那一行',
         case when pg_get_functiondef('public._member_titles(uuid)'::regprocedure) !~ '''註冊就有'''
              then '✅' else '🔴' end, null
  union all
  select 6, '⑥ 賽季來源文字推得出來（正對照）',
         case when (select count(*) from rank_seasons where label ~ '^\d{4} 段位.季賽$') = (select count(*) from rank_seasons)
              then '✅' else '🔴' end,
         (select string_agg(regexp_replace(label, '^(\d{4}) 段位(.)季賽$', '\1 \2季賽冠軍'), '、' order by code) from rank_seasons)
  union all
  select 7, '⑦ 新會員路徑：members.title 預設仍是新手上路',
         case when (select column_default from information_schema.columns
                     where table_schema = 'public' and table_name = 'members' and column_name = 'title') like '%新手上路%'
              then '✅' else '🔴' end, null
  union all
  select 8, '⑧ 新會員路徑：註冊觸發器還在發 member_registered',
         case when pg_get_functiondef('public.trg_members_achievements()'::regprocedure) ~ 'member_registered'
               and exists (select 1 from pg_trigger where tgname = 'trg_members_ach' and tgrelid = 'public.members'::regclass and tgenabled <> 'D')
              then '✅' else '🔴' end, null
  union all
  select 9, '⑨ _member_titles 授權沒被弄丟（前端仍叫不動）',
         case when not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                                where p.oid = 'public._member_titles(uuid)'::regprocedure and a.privilege_type = 'EXECUTE'
                                  and a.grantee in (0, 'anon'::regrole::oid, 'authenticated'::regrole::oid))
              then '✅' else '🔴' end, null
) v order by n;
