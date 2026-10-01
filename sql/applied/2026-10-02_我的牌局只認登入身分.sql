/* ============================================================
   我的牌局（get_my_games_tx）只認登入身分 · 2026-10-02
   📄 使用者 2026-10-02：「要修」

   🔴 查證（2026-10-02，pg_proc ＋ aclexplode）：
     · 函式體一開頭：拿 JWT 解析出的會員；**沒有登入就改用前端傳來的 p_member_id**
     · EXECUTE 授權給 anon、authenticated、PUBLIC
   ⇒ 拿公開的 anon key、知道任何一位會員的 uuid，就能讀他的牌局歷史
     （跟誰同桌、名次、桌上積分、段位）。
   📌 2026-09-20 收掉 21 支會員函式的前端身分退回、09-29 又補了 54 支身分檢查 —— 這一支兩批都漏了。
     全庫同一個形狀只剩它；另一支 log_app_event_tx 是刻意保留的（POS 埋點要能送空的會員，CLAUDE.md 待辦 14）。

   ✅ 改法：比照已經收掉的那 21 支 —— 沒登入就拒絕（28000），有登入就一律用登入的身分，前端傳什麼都忽略。
   ✅ 呼叫點只有會員 App（migi-web/src/lib/social.js），它一定帶登入的 session ⇒ 收掉 anon 不會打壞畫面。
   ⚠ 簽名不變（CREATE OR REPLACE）⇒ 授權不會自己掉，所以下面明確收：anon 與 PUBLIC 兩個方向都要收（硬規則 2.6b）。
   ⚠ 改的是線上全文，錨點必須剛好出現一次（可重跑）。

   ── 同一份順便修第二件事（同一支函式，一次改完）──
   📄 使用者 2026-10-02：「我打完了，但 App 沒有自動出現紀錄」
   🔴 查證：那一場 02:43 打完最後一局，名次與段位分當下就自動結算了（session_players.finish_rank、rating_after 都有值），
     但場次還是 open（店員還沒在 POS 收桌）⇒ 這支只列「已收桌」的場次 ⇒ App 看不到。
   ⇒ 跟 09-29 拍板的分法對不上：「結算成績」是打完那一刻自動的，「收桌」是店員的另一件事（CLAUDE.md 13.9c），
     客人的紀錄不該卡在店員有沒有按收桌。
   ✅ 改成：已收桌，**或這個人在這一場已經有名次**（成績算好了）就列出來；排序用收桌時間，沒收桌的用結算時間。
     還在打、還沒有名次的場次照舊不列。
   ============================================================ */

do $$
declare
  v_def text;
  v_old text[] := array[
    $a$  p_member_id := coalesce(v_me, p_member_id);$a$,
    $a$      select s.id, s.ended_at$a$,
    $a$         and s.status     = 'completed'$a$,
    $a$       order by s.ended_at desc nulls last$a$];
  v_new text[] := array[
    $b$  /* 只認登入身分（2026-10-02）：沒登入就拒絕，前端傳的會員 id 一律忽略 */
  if v_me is null then
    raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000';
  end if;
  p_member_id := v_me;$b$,
    $b$      select s.id, coalesce(s.ended_at, sp.settled_at) as ended_at$b$,
    $b$         -- 已收桌，或成績已經算好（打完最後一將就自動結算，不等店員收桌，2026-10-02）
         and (s.status = 'completed' or sp.finish_rank is not null)$b$,
    $b$       order by coalesce(s.ended_at, sp.settled_at) desc nulls last$b$];
  v_n int; i int;
begin
  v_def := pg_get_functiondef('public.get_my_games_tx(uuid,uuid,integer)'::regprocedure);
  if position('p_member_id := v_me;' in v_def) > 0 and position('sp.finish_rank is not null' in v_def) > 0 then
    return;   -- 兩件都改過了（可重跑）
  end if;
  -- 先把四個錨點都檢查過才動手；任何一個不是剛好一次就整份不執行
  for i in 1 .. array_length(v_old, 1) loop
    v_n := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    if v_n <> 1 then
      raise exception 'get_my_games_tx 的第 % 個錨點出現 % 次（要剛好 1 次），整份不執行：%', i, v_n, left(v_old[i], 40);
    end if;
  end loop;
  for i in 1 .. array_length(v_old, 1) loop
    v_def := replace(v_def, v_old[i], v_new[i]);
  end loop;
  execute v_def;   -- 全部改完才重建一次
end $$;

revoke execute on function public.get_my_games_tx(uuid, uuid, integer) from public;
revoke execute on function public.get_my_games_tx(uuid, uuid, integer) from anon;
grant  execute on function public.get_my_games_tx(uuid, uuid, integer) to authenticated;

/* ── 行為驗證（交易內換身分叫一次，訊息存進 set_config；不往外 raise，硬規則 1.8）──
   ③ 沒有身分 ⇒ 要被拒絕（28000）。🎯 **這一格才是洞補上的證明**：舊版沒登入時會改用傳進來的 id，不會拒絕
   ④ 正對照：模擬一位有打完牌局的測試帳號登入、卻傳「別人的」會員 id ⇒ 照樣回得來，而且只回他自己的
     ⚠ 這一格證明的是「登入的人沒有被一起擋掉」，不是修法本身（有登入時舊版也用登入身分）。
       只驗 ③ 的話，一支永遠拒絕的函式也會全綠（硬規則 3.55） */
do $$
declare
  v_me uuid; v_other uuid; v_line text; v_r jsonb; v_msg text := '';
  v_mine int; v_bad int;
begin
  perform set_config('request.jwt.claims', '', true);
  begin
    v_r := public.get_my_games_tx('7f7d3d1f-0000-0000-0000-000000000000'::uuid, gen_random_uuid(), 5);
    v_msg := '🔴 ③ 沒有身分卻沒被拒絕';
  exception when others then
    v_msg := case when sqlstate = '28000' then '✅ ③ 沒有身分 ⇒ 拒絕（28000）' else '🔴 ③ 拋了別的錯：' || sqlstate || ' ' || sqlerrm end;
  end;

  -- 挑一位「有打完牌局」的測試帳號（一場都沒有的話回傳是空的，這一格會假綠）
  select m.id, m.line_user_id into v_me, v_line from members m
   where m.is_test and m.deleted_at is null and m.hidden_at is null and m.line_user_id is not null
     and exists (select 1 from session_players sp join table_sessions s on s.id = sp.session_id
                  where sp.member_id = m.id and s.status = 'completed' and s.deleted_at is null)
   order by m.created_at limit 1;
  select sp.member_id into v_other from session_players sp
   where sp.member_id is not null and sp.member_id <> v_me limit 1;
  if v_me is null or v_other is null then
    v_msg := v_msg || E'\n⚪ ④ 找不到有打完牌局的測試帳號或另一位會員，這一格測不了';
  else
    perform set_config('request.jwt.claims',
      jsonb_build_object('role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', v_line))::text, true);
    begin
      v_r := public.get_my_games_tx((select org_id from members where id = v_me), v_other, 50);
      v_mine := jsonb_array_length(coalesce(v_r, '[]'::jsonb));
      -- 每一場的 players 裡，is_me 那一位必須是登入的人
      select count(*) into v_bad from jsonb_array_elements(coalesce(v_r, '[]'::jsonb)) g, jsonb_array_elements(g -> 'players') p
       where (p ->> 'is_me')::boolean and (p ->> 'member_id')::uuid <> v_me;
      v_msg := v_msg || E'\n' || case
        when v_mine = 0 then '🔴 ④ 登入的人叫得動，但一場都沒回來（他明明有打完的牌局）'
        when v_bad = 0 then '✅ ④ 登入的人照樣叫得動；傳別人的 id 也只回自己的牌局（' || v_mine || ' 場）'
        else '🔴 ④ 有 ' || v_bad || ' 場的 is_me 不是登入的人 —— 前端傳的 id 還有效' end;
    exception when others then
      v_msg := v_msg || E'\n🔴 ④ 登入的人叫不動：' || sqlstate || ' ' || sqlerrm;
    end;
  end if;
  /* ⑥ 打完、還沒收桌的場次要出現：挑一位「在還開著的場次裡已經有名次」的測試帳號，模擬他登入
     ⑦ 反向：還在打、還沒有名次的場次不可以出現（不然打到一半的牌局會跑進紀錄） */
  declare v_sess uuid; v_m2 uuid; v_l2 text; v_has boolean;
  begin
    select sp.session_id, m.id, m.line_user_id into v_sess, v_m2, v_l2
      from session_players sp join table_sessions s on s.id = sp.session_id join members m on m.id = sp.member_id
     where s.status = 'open' and s.deleted_at is null and sp.finish_rank is not null
       and m.is_test and m.hidden_at is null and m.line_user_id is not null limit 1;
    if v_sess is null then
      v_msg := v_msg || E'\n⚪ ⑥ 現在沒有「打完還沒收桌」的場次，這一格測不了';
    else
      perform set_config('request.jwt.claims',
        jsonb_build_object('role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', v_l2))::text, true);
      v_r := public.get_my_games_tx((select org_id from members where id = v_m2), v_m2, 50);
      select exists (select 1 from jsonb_array_elements(coalesce(v_r, '[]'::jsonb)) g where (g ->> 'session_id')::uuid = v_sess) into v_has;
      v_msg := v_msg || E'\n' || case when v_has then '✅ ⑥ 打完、還沒收桌的那一場有列出來' else '🔴 ⑥ 打完還沒收桌的那一場沒有列出來' end;
    end if;

    v_sess := null;
    select sp.session_id, m.id, m.line_user_id into v_sess, v_m2, v_l2
      from session_players sp join table_sessions s on s.id = sp.session_id join members m on m.id = sp.member_id
     where s.status = 'open' and s.deleted_at is null and sp.finish_rank is null
       and m.is_test and m.hidden_at is null and m.line_user_id is not null limit 1;
    if v_sess is null then
      v_msg := v_msg || E'\n⚪ ⑦ 現在沒有「還在打、沒有名次」的場次，這一格測不了';
    else
      perform set_config('request.jwt.claims',
        jsonb_build_object('role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', v_l2))::text, true);
      v_r := public.get_my_games_tx((select org_id from members where id = v_m2), v_m2, 50);
      select exists (select 1 from jsonb_array_elements(coalesce(v_r, '[]'::jsonb)) g where (g ->> 'session_id')::uuid = v_sess) into v_has;
      v_msg := v_msg || E'\n' || case when not v_has then '✅ ⑦ 還在打、沒有名次的那一場沒有列出來' else '🔴 ⑦ 還在打的場次跑進紀錄了' end;
    end if;
  exception when others then
    v_msg := v_msg || E'\n🔴 ⑥⑦ 出錯：' || sqlstate || ' ' || sqlerrm;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.games_fix', v_msg, true);
end $$;

/* ── 驗證（單一 SELECT）── */
with
fn as (select p.oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'get_my_games_tx'),
acl as (
  select bool_or(a.grantee = 0) as pub,
         bool_or(a.grantee = 'anon'::regrole::oid) as anon,
         bool_or(a.grantee = 'authenticated'::regrole::oid) as auth
    from fn, aclexplode(coalesce((select proacl from pg_proc where oid = fn.oid), acldefault('f', (select proowner from pg_proc where oid = fn.oid)))) a
   where a.privilege_type = 'EXECUTE')
select concat_ws(E'\n',
  case when (select count(*) from fn) = 1 then '✅ ① 版本數 1' else '🔴 ① 版本數 ' || (select count(*) from fn) end,
  case when (select pg_get_functiondef(oid) from fn) ~ 'p_member_id := v_me;'
        and (select pg_get_functiondef(oid) from fn) !~ 'coalesce\(v_me'
       then '✅ ② 函式體只認登入身分（前端傳的 id 不再有效）' else '🔴 ② 函式體沒有改到' end,
  case when (select pg_get_functiondef(oid) from fn) ~ 'sp\.finish_rank is not null'
       then '✅ ②b 打完就列出來（不等收桌）' else '🔴 ②b 還是只列已收桌的場次' end,
  coalesce(nullif(current_setting('migi.games_fix', true), ''), '🔴 ③④⑥⑦ 沒有行為測試訊息'),
  case when not coalesce((select pub from acl), false) and not coalesce((select anon from acl), false) and coalesce((select auth from acl), false)
       then '✅ ⑤ 授權：anon 與 PUBLIC 都收掉了，登入的人（authenticated）照樣叫得動'
       else '🔴 ⑤ 授權不對：PUBLIC=' || coalesce((select pub from acl), false) || ' anon=' || coalesce((select anon from acl), false) || ' authenticated=' || coalesce((select auth from acl), false) end
) as "驗證";
