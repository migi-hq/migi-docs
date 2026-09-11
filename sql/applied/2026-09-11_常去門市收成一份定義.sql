/* ============================================================
   「他常去哪一間店」收成一份有門檻的定義
   2026-09-11 · 使用者問「這個公式你自己定的嗎、常去的定義是什麼」

   ⚠ 這份要留下函式，所以整份不准 `raise`（硬規則 1.8）。

   ── 🔴 我原本寫的規則，以及它為什麼不夠 ────────────
   `search_teams_tx` 裡是這一句：
   ```
   他坐過最多場次的那間店，全期不限時間，沒有最低門檻
   ```
   而畫面上印的是「**推薦給你 · 你常去 OO 店**」——**那是一句斷言**。
   三個缺陷：
   ```
   沒有時間窗   兩年前常去的店，永遠贏過最近三個月天天報到的新店
   沒有門檻     只去過一次而且只有那一次，照樣說「你常去」
   平手不穩定   兩間各 3 場時，每次查可能給不同答案（沒有 tiebreak）
   ```
   🎯 而待辦 16 的「官方推薦」就是這樣被拿掉的：
     **一個不可信的標籤會讓人連帶略過所有標籤**，包括真的有意義的那些。

   ── 🔴 更嚴重的是：系統早就有一份「常」的定義，我沒有用它 ──
   2026-09-01 做牌咖卡的「常一起打」時定過，而且**當時我第一版也寫錯、
   被同一件事糾正過**（CLAUDE.md 待辦 26 原文）：

   > 門檻是「眾數要過半」不是「≥ 2 次」。週六 2 次／週日 2 次會讓
   > `≥2` 宣稱「常在週六」，而一半的場次不是週六。
   > **「最多的那一個」不等於「常」。** 都沒過半就回 null。

   ⇒ 同一個字在系統裡有兩套算法 —— 這個專案記過九次的那個病。

   ── ✅ 新的定義（照抄那一份的判準）──────────────────
   ```
   近 180 天 ＋ 場次數過半 ＋ 至少 3 場   →  那一間
   否則                                  →  null（畫面整行不畫）
   ```
   🎯 **「過半」順帶解決了平手** —— 一組數字裡最多只有一個能超過一半，
     所以答案必然唯一，不需要任何 tiebreak。
   ⚠ 今天的資料下它會一律回 null（場次太少）。**那是對的** ——
     不知道就不要說，而不是挑一個看起來合理的答案。

   📌 抽成獨立函式的理由**不是共用，是「這個問題會被問第二次」** ——
     MA 的召回、報表的主場分析、日後的門市推薦都會問同一句話。
     那時它應該找得到這一份，而不是各自再寫一個 `order by count desc`。
   ============================================================ */


/* ─────────────────────────────────────────────────────────
   ① 「常去門市」的唯一定義
   ───────────────────────────────────────────────────────── */
create or replace function public._member_home_store(p_member_id uuid)
returns uuid
language sql
stable
as $$
  with s as (
    select ts.store_id, count(*) as n
      from public.session_players sp
      join public.table_sessions ts on ts.id = sp.session_id
     where sp.member_id = p_member_id
       and ts.deleted_at is null
       and ts.store_id is not null
       /* ⚠ 時間用 `joined_at`（他真的坐下的那一刻），與牌咖團場次判定
          同一個時間戳 —— 系統裡不要有第二種「這場算哪一天」。 */
       and coalesce(sp.joined_at, ts.created_at) >= now() - interval '180 days'
     group by ts.store_id
  )
  select s.store_id from s
   where s.n >= 3                                  -- 最低門檻：三場
     and s.n * 2 > (select sum(x.n) from s x)      -- 過半（⇒ 答案必然唯一）
$$;

revoke execute on function public._member_home_store(uuid) from public;
revoke execute on function public._member_home_store(uuid) from anon, authenticated;


/* ─────────────────────────────────────────────────────────
   ② search_teams_tx 改用它
   ───────────────────────────────────────────────────────── */
/* ⚠ 簽名沒變 ⇒ `CREATE OR REPLACE` ⇒ 不用 DROP、不掉 GRANT。
   除了取「常去門市」那一段，其餘與 2026-09-11 那一版逐字相同。 */
create or replace function public.search_teams_tx(p_q text default null,
                                                  p_limit int default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me    uuid := public.current_member_id();
  v_org   uuid := public.current_org_id();
  v_store uuid;
  v_name  text;
  v_q     text := nullif(btrim(coalesce(p_q, '')), '');
  v_rows  jsonb;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  /* 🔴 「常去」有門檻，答不出來就回 null —— 畫面那一行整個不畫。
     在此之前這裡是「依場次數遞減取第一名」，也就是**去過一次也算常去**。
     ⚠ 這段說明**刻意不寫出那個舊寫法的字面**（硬規則 3.5）——
       驗證段要掃「舊寫法還在不在」，而 `pg_get_functiondef` 回的是
       含註解的全文，寫出來會讓那一格**永遠是紅的**，
       而一個永遠紅的檢查會讓人學會忽略紅色。 */
  v_store := public._member_home_store(v_me);
  select s.name into v_name from public.stores s where s.id = v_store;

  select coalesce(jsonb_agg(card order by ord, cnt desc, nm), '[]'::jsonb)
    into v_rows
    from (
      select public._team_card(t.id) as card,
             case when v_store is not null and t.home_store_id = v_store then 0 else 1 end as ord,
             (select count(*) from public.team_members tm
               where tm.team_id = t.id and tm.left_at is null) as cnt,
             t.name as nm
        from public.teams t
       where t.org_id = v_org
         and t.deleted_at is null
         and t.join_policy <> 'closed'
         and not exists (select 1 from public.team_members tm
                          where tm.team_id = t.id and tm.member_id = v_me and tm.left_at is null)
         and (v_q is null or t.name ilike '%' || v_q || '%')
       limit greatest(1, least(coalesce(p_limit, 20), 50))
    ) s;

  return jsonb_build_object('ok', true, 'teams', v_rows,
                            'q', v_q,
                            'recommend_store_id',   case when v_q is null then v_store end,
                            'recommend_store_name', case when v_q is null then v_name end);
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
  v_rec  record;
begin
  /* ① 函式在且只有一個版本 */
  select count(*) into v_n from pg_proc
   where pronamespace = 'public'::regnamespace
     and proname in ('_member_home_store', 'search_teams_tx');
  v_msg := v_msg || case when v_n = 2
    then '① ✅ 兩支都在，各只有一個版本'
    else '① 🔴 共 ' || v_n || ' 支，預期 2' end;

  /* ② search_teams_tx 真的改成呼叫它了，而且舊寫法不見了。
     🔴 只驗「有呼叫」不夠 —— 兩段並存的話舊的那段可能還在跑。 */
  v_msg := v_msg || E'\n' || case
    when position('_member_home_store' in
           pg_get_functiondef('public.search_teams_tx(text,integer)'::regprocedure)) > 0
     and position('order by count(*) desc' in
           lower(pg_get_functiondef('public.search_teams_tx(text,integer)'::regprocedure))) = 0
    then '② ✅ 改成呼叫 _member_home_store，而且舊的「取最多那一間」不見了'
    else '② 🔴 只改到一半 —— 兩種算法並存' end;

  /* ③ 授權：內部函式前端叫不到；search_teams_tx 仍給 authenticated */
  select count(*) into v_n
    from pg_proc p left join lateral aclexplode(p.proacl) a on true
   where p.pronamespace = 'public'::regnamespace and p.proname = '_member_home_store'
     and (a.grantee = 'anon'::regrole::oid or a.grantee = 0
          or a.grantee = 'authenticated'::regrole::oid)
     and a.privilege_type = 'EXECUTE';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '③ ✅ _member_home_store 前端叫不到'
    else '③ 🔴 內部函式被授權出去了（' || v_n || ' 筆）' end;

  select count(*) into v_n
    from pg_proc p join lateral aclexplode(p.proacl) a on true
   where p.pronamespace = 'public'::regnamespace and p.proname = 'search_teams_tx'
     and a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE';
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '④ ✅ search_teams_tx 仍然授權給 authenticated（沒掉 GRANT）'
    else '④ 🔴 前端叫不到它了 —— 找團那一頁會 403' end;

  /* ⑤ 🔴 新舊兩種算法逐人印出來讓人判讀（硬規則 3.5：
     不要回一個是非題，這種東西要看得見才判斷得出對不對）。 */
  v_msg := v_msg || E'\n⑤ ⚪ 逐人對照（舊＝最多的那一間／新＝過半且 ≥3 場）：';
  for v_rec in
    select m.display_name as who,
           (select s2.name from public.stores s2 where s2.id = (
              select ts.store_id from public.session_players sp
                join public.table_sessions ts on ts.id = sp.session_id
               where sp.member_id = m.id and ts.deleted_at is null and ts.store_id is not null
               group by ts.store_id order by count(*) desc limit 1)) as old_pick,
           (select s3.name from public.stores s3
             where s3.id = public._member_home_store(m.id)) as new_pick,
           (select count(*) from public.session_players sp
             join public.table_sessions ts on ts.id = sp.session_id
            where sp.member_id = m.id and ts.deleted_at is null) as games
      from public.members m
     where m.deleted_at is null
     order by m.created_at
  loop
    v_msg := v_msg || E'\n     ' || rpad(coalesce(v_rec.who, '?'), 14)
          || ' 場次 ' || v_rec.games
          || '　舊：' || coalesce(v_rec.old_pick, '（無）')
          || '　新：' || coalesce(v_rec.new_pick, '（不夠，不說）');
  end loop;

  /* ⑥ 借真身分實際跑一次（硬規則 7），確認那個鍵還在而且不會炸。 */
  select m.line_user_id into v_line from public.members m
   where m.line_user_id is not null and m.deleted_at is null
   order by m.created_at limit 1;
  if v_line is null then
    v_msg := v_msg || E'\n⑥ 🔴 找不到綁了 LINE 的會員 —— 測不了，而測不了不等於通過';
  else
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_line, 'role', 'authenticated')::text, true);
    v_r := public.search_teams_tx(null, 20);
    v_msg := v_msg || E'\n⑥ ' || case when (v_r->>'ok')::boolean
      then '✅ search_teams_tx 跑得動，推薦門市＝'
           || coalesce(v_r->>'recommend_store_name', '（答不出來，那一行不畫）')
      else '🔴 回 ' || coalesce(v_r->>'reason', '(沒有 reason)') end;
    perform set_config('request.jwt.claims', '', true);
  end if;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
