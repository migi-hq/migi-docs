-- ============================================================
-- 收掉會員身分的「前端退回」—— 身分一律以 JWT 為準（待辦 14 收尾）
-- 2026-09-20
--
-- 【為什麼現在可以收】
--   JWT 已經上線且運作正常。近 14 天 member_id_src 的分布：
--     prod  · jwt     118 筆   ← 正式站 **100% 走 JWT，零 param**
--     local · param   126 筆   ← 全部是本機 dev（localhost 進不去 LIFF，正常）
--   ⇒ 拿掉退回不會影響任何真實路徑。
--   📌 那個 host 欄位是 2026-09-11 補的，正是為了讓這個判斷「自己答得出來」
--     而不必每次做事件關聯 —— 今天它兌現了。
--
-- 【改什麼】
--   p_member_id := coalesce(public.current_member_id(), p_member_id);
--   ↓
--   p_member_id := public.current_member_id();
--   if p_member_id is null then raise exception '未登入…' using errcode='28000'; end if;
--
-- 🔴 **一定要加那道拒絕，不可以只拿掉 coalesce。**
--   少了它，沒有 JWT 時 p_member_id 會是 null ⇒
--     讀取類 → 回空（畫面空白，還好）
--     寫入類 → `update … where id = null` ⇒ **0 列，靜默失敗**
--   而「跑了、回了、什麼都沒發生」正是這個專案一再記錄的那個病（硬規則 4）。
--
-- 【動 21 支，另外 1 支刻意不動】
--   A 型 19 支   p_member_id := coalesce(…)
--   B 型  2 支   v_me := coalesce(…)        consume_snack_tx · get_game_tx
--   🔴 C 型  1 支   log_app_event_tx —— **不是退回，是條件覆寫**
--       它的寫法是 `case when p_member_id is null then null else coalesce(…) end`
--       ⇒ POS 送 null 時保持 null。無條件改成 current_member_id() 的話，
--         **每一筆 pos_error 會掛到當班店員的帳號上**（店員本身也是會員），
--         而 app_events 有 trg_app_events_no_mutate ⇒ **蓋錯了永遠改不掉**。
--       （2026-09-11 已經為這件事單獨處理過一次，不要再改回去。）
--
-- 【已知代價：本機開發要換一條路】
--   「種 localStorage.migi_member ＋ 燒保險絲」那條靠的就是這個退回，**它會死**。
--   ✅ 改走測試帳號（真 JWT）：`docs/09-環境流程/用測試帳號登入會員App.md`
--   📌 CLAUDE.md 硬規則 11.7 早就寫過「拿掉那個退回就死了」—— 這是那一天。
--
-- 【簽名不變】⇒ CREATE OR REPLACE、不用 DROP、不丟 GRANT、前端一行不用改
--   （前端照樣送 p_member_id，函式忽略它）
-- ============================================================

do $$
declare
  r        record;
  v_old    text;
  v_new    text;
  v_var    text;
  v_done   int := 0;
  v_names  text := '';
begin
  for r in
    select p.oid, p.proname
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prokind = 'f'
      and p.proname <> 'log_app_event_tx'                    -- 🔴 C 型，刻意跳過
      and pg_get_functiondef(p.oid) ~
          '\w+\s*:=\s*coalesce\s*\(\s*public\.current_member_id\(\)\s*,\s*p_member_id\s*\)\s*;'
    order by p.proname
  loop
    v_old := pg_get_functiondef(r.oid);

    -- 取出被指派的變數名（A 型是 p_member_id，B 型是 v_me）
    v_var := (regexp_match(v_old,
      '(\w+)\s*:=\s*coalesce\s*\(\s*public\.current_member_id\(\)\s*,\s*p_member_id\s*\)\s*;'))[1];

    v_new := regexp_replace(
      v_old,
      '(\w+)\s*:=\s*coalesce\s*\(\s*public\.current_member_id\(\)\s*,\s*p_member_id\s*\)\s*;',
      '\1 := public.current_member_id();' || E'\n' ||
      '  if \1 is null then raise exception ''未登入或登入已過期，請重新開啟 App'' using errcode = ''28000''; end if;',
      'g');

    -- guard ①：真的換到了嗎（沒換到就整份回滾，不要留下改一半的狀態）
    if v_new = v_old then
      raise exception '🔴 % 沒有換到，整份回滾', r.proname;
    end if;

    -- guard ②：換完不可以還有殘留的 coalesce 退回
    if v_new ~ 'coalesce\s*\(\s*public\.current_member_id\(\)\s*,\s*p_member_id\s*\)' then
      raise exception '🔴 % 還有殘留的退回，整份回滾', r.proname;
    end if;

    execute v_new;
    v_done  := v_done + 1;
    v_names := v_names || case when v_names = '' then '' else '、' end || r.proname;
  end loop;

  -- guard ③：期望值當場算出來比對（硬規則 3.56）
  --   21 = 22 支含退回的 − 1 支 log_app_event_tx（C 型，刻意跳過）
  if v_done <> 21 then
    raise exception '🔴 預期改 21 支，實際 %：%', v_done, v_names;
  end if;

  perform set_config('migi.done', v_done::text, true);
end $$;


-- ============================================================
-- 驗證（🔴 不可以用 raise —— 那會把上面的 DDL 一起回滾，硬規則 1.8）
-- ============================================================
do $$
declare
  v_msg   text := '';
  v_n     int;
  v_me    uuid;
  v_tmp   text;
begin
  -- ① 還有幾支留著前端退回（log_app_event_tx 那支應該還在 ⇒ 期望 1）
  select count(*) into v_n
  from pg_proc
  where pronamespace = 'public'::regnamespace and prokind = 'f'
    and pg_get_functiondef(oid) ~
        'coalesce\s*\(\s*public\.current_member_id\(\)\s*,\s*p_member_id\s*\)';
  v_msg := v_msg || case when v_n = 1
    then '✅ ① 只剩 1 支保留退回（log_app_event_tx，刻意的）'
    else '🔴 ① 還有 ' || v_n || ' 支留著退回，應該只剩 1' end;

  -- ② 那一支真的是 log_app_event_tx 嗎（不是別支被漏掉）
  select coalesce(string_agg(proname, '、'), '(沒有)') into v_tmp
  from pg_proc
  where pronamespace = 'public'::regnamespace and prokind = 'f'
    and pg_get_functiondef(oid) ~
        'coalesce\s*\(\s*public\.current_member_id\(\)\s*,\s*p_member_id\s*\)';
  v_msg := v_msg || E'\n' || case when v_tmp = 'log_app_event_tx'
    then '✅ ② 留著的正是 log_app_event_tx'
    else '🔴 ② 留著的是：' || v_tmp end;

  -- ③ 21 支都加上拒絕了嗎
  select count(*) into v_n
  from pg_proc
  where pronamespace = 'public'::regnamespace and prokind = 'f'
    and pg_get_functiondef(oid) ~ 'errcode\s*=\s*''28000''';
  v_msg := v_msg || E'\n' || case when v_n = 21
    then '✅ ③ 21 支都有拒絕未登入的擋牆'
    else '🔴 ③ 只有 ' || v_n || ' 支有擋牆，應為 21' end;

  -- ④ 授權沒掉（CREATE OR REPLACE 不該掉，但驗一次；log_app_event_tx 也算在內）
  select count(*) into v_n
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
    and pg_get_functiondef(p.oid) ~ 'errcode\s*=\s*''28000'''
    and exists (select 1 from aclexplode(p.proacl) a
                where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE');
  v_msg := v_msg || E'\n' || case when v_n >= 18
    then '✅ ④ 改過的函式仍有 anon 授權（' || v_n || ' 支）'
    else '🔴 ④ 只剩 ' || v_n || ' 支有 anon —— GRANT 可能掉了' end;

  -- ⑤ 🔴 負對照：沒有 JWT 呼叫要被拒絕（這一格才是整份的目的）
  begin
    perform set_config('request.jwt.claims', '', true);
    perform public.get_my_profile_tx(
      (select id from orgs limit 1),
      (select id from members where is_test order by created_at limit 1));
    v_msg := v_msg || E'\n' || '🔴 ⑤ 沒有 JWT 竟然查得到 —— 擋牆沒有生效';
  exception when others then
    v_msg := v_msg || E'\n' || case when sqlstate = '28000'
      then '✅ ⑤ 沒有 JWT 被正確拒絕（28000）'
      else '⚠ ⑤ 被擋下但錯誤碼是 ' || sqlstate || '：' || sqlerrm end;
  end;

  -- ⑥ ✅ 正對照：有 JWT 要正常運作（少了這格，一支永遠拒絕的實作也會全綠）
  --    硬規則 3.55：只驗「擋住了」的那一半等於沒驗
  begin
    select m.line_user_id into v_tmp
    from members m
    where m.is_test and m.line_user_id is not null and m.deleted_at is null
    order by m.created_at limit 1;

    if v_tmp is null then
      v_msg := v_msg || E'\n' || '⚪ ⑥ 找不到有綁 LINE 的測試帳號，這一格測不了';
    else
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_tmp, 'role', 'authenticated')::text, true);
      select public.current_member_id() into v_me;
      perform public.get_my_profile_tx(
        (select org_id from members where line_user_id = v_tmp limit 1), null);
      v_msg := v_msg || E'\n' || case when v_me is not null
        then '✅ ⑥ 有 JWT 正常運作，解析到 ' || left(v_me::text, 8) || '…（**而且第二個參數送 null 也通**）'
        else '🔴 ⑥ 有 JWT 卻解析不到會員' end;
    end if;
  exception when others then
    v_msg := v_msg || E'\n' || '🔴 ⑥ 有 JWT 卻失敗了：' || sqlstate || ' ' || sqlerrm;
  end;
  perform set_config('request.jwt.claims', '', true);

  -- ⑦ log_app_event_tx 沒被誤傷（它必須保持「POS 送 null 就維持 null」）
  select count(*) into v_n
  from pg_proc
  where pronamespace = 'public'::regnamespace and proname = 'log_app_event_tx'
    and pg_get_functiondef(oid) ~ 'case\s+when\s+p_member_id\s+is\s+null';
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '✅ ⑦ log_app_event_tx 的條件覆寫完好（POS 的埋點不會掛到店員頭上）'
    else '🔴 ⑦ log_app_event_tx 被改壞了' end;

  v_msg := v_msg || E'\n\n改了 ' ||
           coalesce(nullif(current_setting('migi.done', true), ''), '?') || ' 支。';

  perform set_config('migi.verify', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify', true), ''), '🔴 沒有驗證訊息') as "驗證";
