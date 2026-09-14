/* ============================================================
   團長失聯 → 系統自動推舉參與度最高的人接任
   2026-09-13
   ------------------------------------------------------------
   使用者：「團長很久沒出現，系統自動推舉第一參與度高的當團長」

   ── 現況與這份改什麼 ─────────────────────────────
   ```
   現在   手動：只有**年資最久**的那一位看得到「由我接任」，要他自己按
   之後   自動：每天掃一次，直接推舉**參與度最高**的那一位
   ```
   兩處都改：觸發方式（手動 → 自動）與合格者判準（年資 → 參與度）。

   🔴 **手動那條路留著，而且與自動共用同一支判準。**
     自動是每天一次，手動可以立刻。但「誰該接任」只能有一個答案 ——
     兩邊各寫一份就是這個專案記過八次的那個病（一個事實兩個名字）。
     ⇒ `_team_claim_check` 仍然是唯一的判準，`claim_team_leader_tx`
       與 `sweep_team_leaders_tx` 都問它。

   ── 參與度怎麼算（沒有發明新的口徑）─────────────
   團詳情畫面上那行「本月貢獻 N 場」用的是
   `_team_session_ids(team) 裡這個人坐過的場次數`。
   這份沿用**同一個來源**，只把窗口從「本月」換成「近 90 天」。
   🔴 不可以用「本月」：團長失聯的門檻是 60 天，而每個月 1 號大家都是 0，
     那時推舉出來的人只是 id 比較小的那一個。
   ⚠ 平手時取**年資最久**，再平手取 member_id ——
     答案必須是唯一的，否則同一個團在不同時間跑會得到不同的人。

   ── 失聯怎麼算（沿用既有的，一個字都沒改）───────
   `last_app_active_at` 與 `last_visit_at` 取**較晚**的那一個，60 天。
   🎯 只看 App 的話，「常來店但不開 App」的團長會被誤判失聯，
     而那正是老闆型團長的樣子。

   ── 已知代價，要先知道 ───────────────────────────
   · 舊團長回來之後就是一般團員，不能改團名、不能審核入團。
     ⇒ 所以兩邊**都要發通知**：新團長知道自己接手了，
       舊團長知道發生了什麼事（那則通知也可能正好把他叫回來）。
   · 只有團長一個人的團不會動 —— 沒有人可以接。
   · 這份**不會**動 `teams.deleted_at` 的團。

   ⚠ 硬規則 1.8：這份要留下 DDL，所以**一個 raise 都沒有**。
     行為測試（造樣本、驗真的換了人）在
     `sql/checks/2026-09-13_驗團長自動推舉.sql`，那份才會回滾。
   ============================================================ */

/* ── ① 參與度最高的人 ────────────────────────────
   回傳 team 裡**除了 p_exclude 以外**參與度最高的成員。
   沒有其他成員時回 null。 */
create or replace function public._team_top_contributor(
  p_team_id uuid, p_exclude uuid default null)
returns uuid
language sql
stable
as $$
  select tm.member_id
    from public.team_members tm
   where tm.team_id = p_team_id
     and tm.left_at is null
     and (p_exclude is null or tm.member_id <> p_exclude)
   order by
     /* 近 90 天在這個團打過幾場。與團詳情的「本月貢獻」同一個來源。 */
     (select count(*) from public._team_session_ids(p_team_id) ts
       where ts.played_at >= now() - interval '90 days'
         and exists (select 1 from public.session_players sp
                      where sp.session_id = ts.session_id
                        and sp.member_id = tm.member_id)) desc,
     tm.joined_at,          -- 平手：年資久的優先
     tm.member_id           -- 再平手：讓答案唯一
   limit 1;
$$;

comment on function public._team_top_contributor(uuid, uuid) is
  '團裡參與度最高的成員（近 90 天場次數，平手取年資）。團長失聯時由誰接任的唯一判準。';

/* ── ② 合格者從「年資最久」改成「參與度最高」 ────
   其餘一個字都沒動：失聯門檻、兩個欄位取較晚、沒有團長時直接讓人接。 */
create or replace function public._team_claim_check(p_team_id uuid, p_member_id uuid)
returns text
language plpgsql
stable
as $$
declare
  v_lead  uuid;
  v_first uuid;
  v_seen  timestamptz;
  v_days  constant int := 60;   -- 失聯門檻
begin
  if not exists (select 1 from public.team_members tm
                  join public.teams t on t.id = tm.team_id and t.deleted_at is null
                 where tm.team_id = p_team_id and tm.member_id = p_member_id
                   and tm.left_at is null) then
    return 'not_member';
  end if;

  select tm.member_id into v_lead from public.team_members tm
   where tm.team_id = p_team_id and tm.role = 'leader' and tm.left_at is null;

  if v_lead = p_member_id then return 'already_leader'; end if;

  /* 🔴 2026-09-13：這裡原本是「年資最久的非團長成員」。
     改成**參與度最高**（使用者指定）——「誰在撐這個團」比「誰待最久」
     更接近團長該是誰，而一個三年沒來的元老不會是好團長。
     ⚠ 仍然不是「誰先按誰接任」：答案由資料決定且唯一，
       所以團長一失聯也不會被新人搶走。 */
  v_first := public._team_top_contributor(p_team_id, v_lead);

  if v_first is distinct from p_member_id then return 'not_eligible'; end if;

  /* 沒有團長（例如資料異常）就不用等 60 天，直接讓參與度最高的人接。 */
  if v_lead is null then return null; end if;

  /* ⚠ 兩個欄位取**較晚**的那一個。只看 App 的話，
     「常來店但不開 App」的團長會被誤判失聯，而那正是老闆型團長的樣子。 */
  select greatest(coalesce(m.last_app_active_at, 'epoch'::timestamptz),
                  coalesce(m.last_visit_at,      'epoch'::timestamptz))
    into v_seen
    from public.members m where m.id = v_lead;

  if v_seen > now() - make_interval(days => v_days) then return 'leader_active'; end if;

  return null;
end $$;

/* ── ③ 每天掃一次，該換的直接換 ──────────────────
   🔴 換角色一律「**先降級再升級**」。`uq_team_one_leader` 是不可延遲的
     部分唯一索引，一句 UPDATE 同時改兩列時 Postgres 不保證哪一列先寫。
     （這一段與 `claim_team_leader_tx` 逐字相同，那裡踩過。） */
create or replace function public.sweep_team_leaders_tx(p_org_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  r        record;
  v_new    uuid;
  v_why    text;
  v_n      int := 0;
  v_names  text[] := '{}';
  v_newnm  text;
begin
  for r in
    select t.id as team_id, t.name as team_name, t.org_id, tm.member_id as lead_id
      from public.teams t
      join public.team_members tm
        on tm.team_id = t.id and tm.role = 'leader' and tm.left_at is null
     where t.deleted_at is null
       and (p_org_id is null or t.org_id = p_org_id)
  loop
    /* 候選人先算出來，再拿他去問判準 ——
       判準會自己檢查「是不是他」「團長是不是真的失聯」。
       ⇒ 自動與手動走的是同一個檢查，不會有兩套結論。 */
    v_new := public._team_top_contributor(r.team_id, r.lead_id);
    if v_new is null then continue; end if;          -- 團裡只有團長一個人

    v_why := public._team_claim_check(r.team_id, v_new);
    if v_why is not null then continue; end if;      -- 團長還活著，或其他理由

    update public.team_members set role = 'member'
     where team_id = r.team_id and member_id = r.lead_id and left_at is null;
    update public.team_members set role = 'leader'
     where team_id = r.team_id and member_id = v_new and left_at is null;

    select display_name into v_newnm from public.members where id = v_new;

    /* 兩邊都要通知。舊團長那一則不是禮貌，是**他有權知道自己被換掉了** ——
       而且那可能正好把他叫回來。 */
    perform public._team_notify(r.org_id, v_new, 'team_ok', r.team_name,
             '團長很久沒出現，你已接任 ' || r.team_name || ' 的團長',
             r.team_id, r.team_name, null);
    perform public._team_notify(r.org_id, r.lead_id, 'team_ok', r.team_name,
             '你在 ' || r.team_name || ' 的團長已由 ' || coalesce(v_newnm, '團員') || ' 接任',
             r.team_id, r.team_name, null);

    v_n := v_n + 1;
    v_names := v_names || r.team_name;
  end loop;

  return jsonb_build_object('ok', true, 'changed', v_n, 'teams', to_jsonb(v_names));
end $$;

comment on function public.sweep_team_leaders_tx(uuid) is
  '每天掃一次：團長失聯 60 天就把團長交給參與度最高的成員，兩邊都發通知。';

/* ── ④ 授權（硬規則 2.6b：新建的函式預設就給了 anon）────
   這兩支不是前端該叫的：一支是內部判準，一支是排程。
   🔴 **兩條路都要收**：`public` 的繼承與 default privileges 的明確授權。 */
revoke execute on function public._team_top_contributor(uuid, uuid) from public;
revoke execute on function public._team_top_contributor(uuid, uuid) from anon, authenticated;
revoke execute on function public.sweep_team_leaders_tx(uuid) from public;
revoke execute on function public.sweep_team_leaders_tx(uuid) from anon, authenticated;
grant execute on function public.sweep_team_leaders_tx(uuid) to service_role;

/* ⚠ `_team_claim_check` 是 `claim_team_leader_tx`（DEFINER）從內部呼叫的，
   呼叫端的權限在 DEFINER 裡不會被檢查，所以它不需要對外授權。
   這裡不動它既有的授權，免得動到一個本來就在跑的路徑。 */

/* ── ⑤ 排程：每天凌晨 4 點 ───────────────────────
   ⚠ 挑 04:00 是因為那時店裡最可能沒有人在打 ——
     換團長會發兩則通知，不要在客人正在配桌時跳出來。 */
select cron.unschedule('team-leader-handover')
 where exists (select 1 from cron.job where jobname = 'team-leader-handover');

select cron.schedule('team-leader-handover', '0 20 * * *',
  $cron$select public.sweep_team_leaders_tx('11111111-1111-1111-1111-111111111111'::uuid)$cron$);
/* 📌 cron 走的是 UTC，20:00 UTC = 台北 04:00。
   既有的 `daily-wallet-audit` 用 `0 21 * * *` 也是同一個換算（台北 05:00）。 */

/* ============================================================
   驗證。🔴 一個 raise 都沒有 —— 這份要留下 DDL（硬規則 1.8）。
   行為（真的換了人沒有）在 checks/ 那一份。
   ============================================================ */
do $$
declare v_msg text := '';
begin
  v_msg := v_msg || '① 三支函式版本數（各應為 1）：'
    || coalesce((select string_agg(x.proname || '=' || x.n, '　') from (
         select p.proname, count(*)::text as n
           from pg_proc p
          where p.pronamespace = 'public'::regnamespace
            and p.proname in ('_team_top_contributor', '_team_claim_check', 'sweep_team_leaders_tx')
          group by p.proname order by p.proname) x), '🔴 一支都沒有');

  /* ② 判準只有一份：掃全庫還有誰在決定「誰能接任」。
     ⚠ 用**函式名**當關鍵字（硬規則 3.5：欄位名會出現在說明文字裡，函式名不會）。 */
  v_msg := v_msg || E'\n② 呼叫 _team_top_contributor 的函式（應為 _team_claim_check ＋ sweep）：'
    || coalesce((select string_agg(p.proname, '　' order by p.proname)
         from pg_proc p
        where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
          and p.proname <> '_team_top_contributor'
          and pg_get_functiondef(p.oid) like '%\_team\_top\_contributor%'), '🔴 沒有人用它');

  v_msg := v_msg || E'\n③ 排程：'
    || coalesce((select jobname || '　' || schedule from cron.job
                  where jobname = 'team-leader-handover'), '🔴 沒有建立');

  /* ④ 授權：這兩支都不該讓前端叫得動。
     ⚠ 同時看「明確授權」與「PUBLIC 繼承」——
       只看 has_function_privilege 的話，兩種來源分不出來（硬規則 2.6）。 */
  v_msg := v_msg || E'\n④ 前端叫得動嗎（都應為 f/f）：'
    || coalesce((select string_agg(p.proname || ' anon=' ||
           (exists (select 1 from aclexplode(p.proacl) a
                     where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE'))::text
           || ' public=' ||
           (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                     where a.grantee = 0 and a.privilege_type = 'EXECUTE'))::text, '　' order by p.proname)
         from pg_proc p
        where p.pronamespace = 'public'::regnamespace
          and p.proname in ('_team_top_contributor', 'sweep_team_leaders_tx')), '🔴 查不到');

  /* ⑤ 現況掃描（唯讀）：今天有幾個團符合換人條件。
     ⚠ 預期是 0 —— 只有一個團而且團長今天還在活動。
       **0 在這裡不代表功能沒用**，所以下一格是正對照。 */
  v_msg := v_msg || E'\n⑤ 今天真的會換人的團數（預期 0）：'
    || coalesce((select count(*)::text from public.teams t
         join public.team_members tm on tm.team_id = t.id and tm.role = 'leader' and tm.left_at is null
        where t.deleted_at is null
          and public._team_top_contributor(t.id, tm.member_id) is not null
          and public._team_claim_check(t.id, public._team_top_contributor(t.id, tm.member_id)) is null), '🔴 算不出來');

  /* ⑥ 正對照（硬規則 3.55）：把失聯門檻當成 0 天來算，看它找不找得到人。
     🔴 少了這一格，一支永遠回 null 的 `_team_top_contributor`
       也會讓第 ⑤ 格印出 0，而那看起來完全正確。 */
  v_msg := v_msg || E'\n⑥ 正對照 · 每個團算得出候選人嗎：'
    || coalesce((select string_agg(t.name || '→' ||
           coalesce((select m.display_name from public.members m
                      where m.id = public._team_top_contributor(t.id, tm.member_id)),
                    '（團裡只有團長）'), '　')
         from public.teams t
         join public.team_members tm on tm.team_id = t.id and tm.role = 'leader' and tm.left_at is null
        where t.deleted_at is null), '⚪ 一個團都沒有');

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
