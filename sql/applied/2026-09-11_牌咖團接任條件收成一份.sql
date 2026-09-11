/* ============================================================
   「能不能接任團長」收成一份定義，並讓 get_team_tx 說得出來
   2026-09-11 · 接在牌咖團那三批之後

   ⚠ 這份要留下函式，所以整份不准 `raise`（硬規則 1.8）。

   ── 為什麼要這一份 ────────────────────────────────
   寫前端資料層時我在註解裡寫了「前端只在 `get_team_tx` 說得出
   『團長很久沒出現』時才畫接任那顆按鈕」—— **而後端根本沒有回那個東西。**
   🔴 那是對自己開的空頭支票，而它的後果是二選一，兩個都不能接受：
   ```
   按鈕常駐    → 幾乎每次按都失敗（leader_active / not_eligible）
                 而一顆按了幾乎都會失敗的按鈕比沒有更糟
   按鈕不畫    → 功能永遠走不到，等於做了沒人讀
   ```

   ── 🔴 但這裡有一條隱私線，而它剛好是我自己畫的 ────
   2026-08-26 為「常來時段」定的：**對別人的單向側寫不給客人看**。
   「團長 60 天沒來」正是那一類 —— 名冊不給「上次來店」就是同一個理由。

   ✅ 解法是**只回一個關於「我」的能力旗標**，不回關於「他」的事實：
   ```
   ❌ leader_last_seen: '2026-07-01'      ← 對別人的側寫
   ❌ leader_stale: true                  ← 還是在講他
   ✅ can_claim_leader: true              ← 講的是「我現在能做什麼」
   ```
   ⚠ 而且它**只在我真的能接任時才是 true** —— 不是團員、不是年資最久、
     團長還活著，三種情況都回 false，看不出是哪一種。
   🎯 最小揭露：剛好夠讓按鈕畫得出來，不多一個位元。

   ── 判斷只有一份 ──────────────────────────────────
   `_team_claim_check(team, member)` 回 null ＝ 可以接任，
   否則回**原因碼**。兩個呼叫端各取所需：
   ```
   claim_team_leader_tx   拿原因碼去對話術（四種原因四句話）
   get_team_tx            只問「是不是 null」
   ```
   🔴 分成兩份寫的話，會出現「按鈕畫出來了但按下去說你不行」，
     而那不會報錯，只會讓人覺得系統在跟他吵架。
   ============================================================ */


/* ─────────────────────────────────────────────────────────
   ① 判斷本身
   ───────────────────────────────────────────────────────── */
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

  /* 年資最久的非團長成員（同時間時取 id 較小的，讓答案是唯一的）。
     ⚠ 不是「誰先按誰接任」—— 那會變成團長一失聯就被新人搶走。 */
  select tm.member_id into v_first from public.team_members tm
   where tm.team_id = p_team_id and tm.left_at is null
     and (v_lead is null or tm.member_id <> v_lead)
   order by tm.joined_at, tm.member_id
   limit 1;

  if v_first is distinct from p_member_id then return 'not_eligible'; end if;

  /* 沒有團長（例如資料異常）就不用等 60 天，直接讓最久的人接。 */
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

revoke execute on function public._team_claim_check(uuid, uuid) from public;
revoke execute on function public._team_claim_check(uuid, uuid) from anon, authenticated;


/* ─────────────────────────────────────────────────────────
   ② claim_team_leader_tx 改成用它
   ───────────────────────────────────────────────────────── */
/* ⚠ 簽名沒變 ⇒ `CREATE OR REPLACE` ⇒ 不用 DROP、不掉 GRANT。 */
create or replace function public.claim_team_leader_tx(p_team_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me   uuid := public.current_member_id();
  v_why  text;
  v_lead uuid;
  v_team text;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  v_why := public._team_claim_check(p_team_id, v_me);
  if v_why is not null then
    return jsonb_build_object('ok', false, 'reason', v_why, 'message', case v_why
      when 'not_member'     then '你不在這個團裡'
      when 'already_leader' then '你已經是團長了'
      when 'not_eligible'   then '要由團裡待最久的人接任'
      when 'leader_active'  then '團長還在活動中，不能接任'
      else '現在不能接任' end);
  end if;

  select tm.member_id into v_lead from public.team_members tm
   where tm.team_id = p_team_id and tm.role = 'leader' and tm.left_at is null;

  /* 🔴 先降級再升級。`uq_team_one_leader` 是不可延遲的部分唯一索引，
     一句 UPDATE 同時改兩列時 Postgres 不保證哪一列先寫。 */
  if v_lead is not null then
    update public.team_members set role = 'member'
     where team_id = p_team_id and member_id = v_lead and left_at is null;
  end if;
  update public.team_members set role = 'leader'
   where team_id = p_team_id and member_id = v_me and left_at is null;

  select t.name into v_team from public.teams t where t.id = p_team_id;
  return jsonb_build_object('ok', true, 'message', '你現在是 ' || v_team || ' 的團長了');
end $$;


/* ─────────────────────────────────────────────────────────
   ③ get_team_tx 多回一個 can_claim_leader
   ───────────────────────────────────────────────────────── */
/* ⚠ 簽名沒變。多的只有一個布林值，而它講的是**我能做什麼**，
   不是團長怎麼了（見檔頭那條隱私線）。 */
create or replace function public.get_team_tx(p_team_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me      uuid := public.current_member_id();
  v_card    jsonb;
  v_role    text;
  v_from    timestamptz;
  v_members jsonb;
  v_pending int := 0;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  v_card := public._team_card(p_team_id);
  if v_card is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;

  select tm.role into v_role
    from public.team_members tm
   where tm.team_id = p_team_id and tm.member_id = v_me and tm.left_at is null;

  if v_role is null then
    return jsonb_build_object('ok', true, 'team', v_card, 'my_role', null,
                              'members', '[]'::jsonb, 'can_claim_leader', false);
  end if;

  v_from := (date_trunc('month', (now() at time zone 'Asia/Taipei')) at time zone 'Asia/Taipei');

  select coalesce(jsonb_agg(x order by x->>'role', x->>'joined_at'), '[]'::jsonb)
    into v_members
    from (
      select jsonb_build_object(
               /* 🔴 只有團長拿得到 member_id —— 不需要身分就不要交出身分
                  （2026-09-04 排行榜定的原則）。只有他要按移除與轉讓。 */
               'member_id', case when v_role = 'leader' then tm.member_id else null end,
               'is_me',     tm.member_id = v_me,
               'nickname',  m.display_name,
               'rank',      m.rank,
               'title',     m.title,
               'role',      tm.role,
               'joined_at', tm.joined_at,
               /* 🔴 名冊**不給「上次來店」** —— 手遊公會名冊都有那一欄，
                  但 2026-08-26 為常來時段畫的線擋著：對別人的單向側寫
                  不給客人看。本月貢獻是**共同事實**，所以可以。 */
               'month_contrib', (
                 select count(*) from public._team_session_ids(p_team_id) ts
                  where ts.played_at >= v_from
                    and exists (select 1 from public.session_players sp
                                 where sp.session_id = ts.session_id
                                   and sp.member_id = tm.member_id))) as x
        from public.team_members tm
        join public.members m on m.id = tm.member_id
       where tm.team_id = p_team_id and tm.left_at is null
    ) s;

  if v_role = 'leader' then
    select count(*) into v_pending
      from public.team_requests r
     where r.team_id = p_team_id and r.status = 'pending'
       and r.kind = 'apply' and r.expires_at > now();
  end if;

  return jsonb_build_object('ok', true, 'team', v_card, 'my_role', v_role,
                            'members', v_members, 'pending_count', v_pending,
                            /* ✅ 只回「我現在能不能接任」。三種不能的原因
                               都回 false，看不出是哪一種 —— 最小揭露。 */
                            'can_claim_leader',
                            public._team_claim_check(p_team_id, v_me) is null);
end $$;


/* ============================================================
   驗證（唯讀，不准 raise）
   ============================================================ */
do $$
declare
  v_msg  text := '';
  v_n    int;
  v_line text;
  v_r    jsonb;
begin
  /* ① 三支都在且各一個版本 */
  select count(*) into v_n from pg_proc
   where pronamespace = 'public'::regnamespace
     and proname in ('_team_claim_check','claim_team_leader_tx','get_team_tx');
  v_msg := v_msg || case when v_n = 3
    then '① ✅ 三支都在，各只有一個版本'
    else '① 🔴 共 ' || v_n || ' 支，預期 3' end;

  /* ② 兩個呼叫端都真的改成用共用那支了。
     🔴 只改一邊的話會出現「按鈕畫出來了但按下去說你不行」，而它不報錯。 */
  v_msg := v_msg || E'\n' || case
    when position('_team_claim_check' in
           pg_get_functiondef('public.claim_team_leader_tx(uuid)'::regprocedure)) > 0
     and position('_team_claim_check' in
           pg_get_functiondef('public.get_team_tx(uuid)'::regprocedure)) > 0
    then '② ✅ claim 與 get_team 都呼叫 _team_claim_check（判斷只有一份）'
    else '② 🔴 只有一邊改到 —— 兩份判斷遲早會漂' end;

  /* ③ 🔴 負對照：`get_team_tx` 不可以回任何「團長上次出現」的東西。
     那是 2026-08-26 那條隱私線，而它只有靠檢查才守得住。 */
  v_msg := v_msg || E'\n' || case
    when pg_get_functiondef('public.get_team_tx(uuid)'::regprocedure)
         !~ 'last_app_active_at|last_visit_at|leader_last_seen|leader_stale'
    then '③ ✅ 名冊沒有回傳任何「上次來店／上次開 App」'
    else '③ 🔴 回傳裡出現了對團長的單向側寫 —— 越過 2026-08-26 那條線' end;

  /* ④ 授權沒被改壞 */
  select count(*) into v_n
    from pg_proc p join lateral aclexplode(p.proacl) a on true
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('claim_team_leader_tx','get_team_tx')
     and a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE';
  v_msg := v_msg || E'\n' || case when v_n = 2
    then '④ ✅ 兩支仍然授權給 authenticated（CREATE OR REPLACE 沒掉 GRANT）'
    else '④ 🔴 只有 ' || v_n || '/2 —— 前端會 403' end;

  select count(*) into v_n
    from pg_proc p left join lateral aclexplode(p.proacl) a on true
   where p.pronamespace = 'public'::regnamespace and p.proname = '_team_claim_check'
     and (a.grantee = 'anon'::regrole::oid or a.grantee = 0
          or a.grantee = 'authenticated'::regrole::oid)
     and a.privilege_type = 'EXECUTE';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '⑤ ✅ _team_claim_check 前端叫不到'
    else '⑤ 🔴 內部函式被授權出去了（' || v_n || ' 筆）' end;

  /* ⑥ 借真身分實際跑一次（硬規則 7）。
     ⚠ 這位會員不在任何團裡（今天 0 個團）⇒ 正確答案是 not_found，
       而 `can_claim_leader` 這個鍵要存在。 */
  select m.line_user_id into v_line from public.members m
   where m.line_user_id is not null and m.deleted_at is null
   order by m.created_at limit 1;
  if v_line is null then
    v_msg := v_msg || E'\n⑥ 🔴 找不到綁了 LINE 的會員 —— 測不了，而測不了不等於通過';
  else
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_line, 'role', 'authenticated')::text, true);
    v_r := public.get_team_tx('00000000-0000-0000-0000-000000000000'::uuid);
    v_msg := v_msg || E'\n' || case when coalesce(v_r->>'reason','') = 'not_found'
      then '⑥ ✅ get_team_tx 跑得動（不存在的團回 not_found）'
      else '⑥ 🔴 預期 not_found，實際 ' || coalesce(v_r::text,'null') end;
    perform set_config('request.jwt.claims', '', true);
  end if;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
