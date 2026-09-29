-- ════════════════════════════════════════════════════════════════════
-- 2026-09-29 「結算成績」與「收桌」拆成兩件事
-- 📄 討論：2026-09-29 對話（使用者：結算成績、收桌要怎麼安排比較簡化而且合理）
--
-- 之前：名次、桌上積分、段位分、成就全部在**收桌**那一下才做 ⇒
--       店員忘了按，客人的段位與成就就一直不更新；三將打完平板也拿不到真的段位分。
-- 之後：
--   結算成績  系統自動 —— 約定的將數打完那一刻（session_rounds 變成 finished 的觸發器）
--   收桌      店員在 POS 按 —— 關場次、放桌、放掉平板；**並記下是誰按的**（獎金依據）
--   ⇒ 沒打完約定將數就收桌的（客人提早走），成績仍由收桌補算（已有名次就跳過，段位分不會重複加）
--
-- 五件事：
--   ① table_sessions.closed_by_staff_id     誰收的桌（值從登入身分取，不採信前端；只有第一次按的人）
--   ② _session_scored(uuid)                 「這場成績算過了沒」＝ 有沒有人已經有名次（唯一一份定義）
--   ③ 兩個 session_rounds 觸發器
--        trg_session_rounds_auto_score  最後一將打完 ⇒ 呼叫既有的 _score_settle_tx（失敗吞掉，收桌會補）
--        trg_session_rounds_guard       成績算完後：不准再開新的一將、不准把打完的一將撤銷回 playing
--                                       （那兩件事會讓後面的分數沒被算到，而且不報錯）
--   ④ 改三支線上函式（拿 pg_get_functiondef 的線上全文做字串替換，替換不到就整份回滾）
--        _score_settle_tx   拿掉「放掉平板」（結算現在在打完當下就跑，平板還要看牌局結束卡）
--        settle_session_tx  放掉平板搬到這裡；記 closed_by_staff_id；已有名次就不再結算
--        tbl_state_tx       多回 rating_delta（座位 → 段位分變動），成績算完才有，否則 null
--   ⑤ 驗證（不 raise —— 硬規則 1.8）；行為在 sql/checks/2026-09-29_驗打完自動結算與收桌記錄.sql
--
-- 🔴 獎金「有按收桌才列入」：算獎金時只認 closed_by_staff_id is not null 的場次。
--    ⚠ v_real_table_sessions 的欄位是寫死的清單，新欄位不會自動進去 —— 套用後看錯誤儀表的
--      「檢視表漏欄位」那一格，紅了就要補（同 2026-09-11_補齊四個報表檢視表漏掉的欄位.sql）。
-- ⚠ 簽名都不變 ⇒ create or replace，授權不動（硬規則 2）。
-- ⚠ 套用前先跑 sql/checks/2026-09-29_打完自動結算_套用前先驗.sql，四個錨點都要 ✅。
-- ════════════════════════════════════════════════════════════════════

-- ① 誰收的桌 ─────────────────────────────────────────────────────────
alter table public.table_sessions
  add column if not exists closed_by_staff_id uuid references public.staff(id);

comment on column public.table_sessions.closed_by_staff_id is
  '按收桌的店員（settle_session_tx 從登入身分寫入，第一次按的人為準，之後不會被覆蓋）。
   null ＝ 還沒收桌，或不是店員收的。獎金只認這一欄有值的場次（2026-09-29 使用者）。
   跟 updated_by 不同：updated_by 任何後續更新都會被蓋掉，不能當依據。';

-- ② 成績算過了沒 ─────────────────────────────────────────────────────
create or replace function public._session_scored(p_session_id uuid)
returns boolean language sql stable security definer set search_path to 'public'
as $$
  select exists (select 1 from session_players
                  where session_id = p_session_id and finish_rank is not null);
$$;
revoke execute on function public._session_scored(uuid) from public;
revoke execute on function public._session_scored(uuid) from anon, authenticated;

-- ③ 觸發器 ───────────────────────────────────────────────────────────
create or replace function public.trg_session_rounds_auto_score()
returns trigger language plpgsql security definer set search_path to 'public'
as $$
declare v_planned int; v_status text;
begin
  if new.status = 'finished' and old.status is distinct from 'finished' then
    select planned_rounds, status into v_planned, v_status
      from table_sessions where id = new.session_id;
    /* 約定 2 將以上才自動算（1 將沒有段位分）；最後一將打完那一刻；還沒算過 */
    if v_status = 'open' and coalesce(v_planned, 0) >= 2 and new.round_no >= v_planned
       and not public._session_scored(new.session_id) then
      begin
        perform public._score_settle_tx(new.session_id);
      exception when others then
        null;   -- 🔴 不可以讓結算失敗把「確認最後一局」一起回滾；收桌會補算
      end;
    end if;
  end if;
  return new;
end $$;

create or replace function public.trg_session_rounds_guard()
returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  if tg_op = 'INSERT' then
    if public._session_scored(new.session_id) then
      raise exception '這場的成績已經結算，不能再開新的一將（請店員收桌）';
    end if;
  elsif old.status = 'finished' and new.status = 'playing'
        and public._session_scored(new.session_id) then
    raise exception '這場的成績已經結算，不能再撤銷（請店員處理）';
  end if;
  return new;
end $$;

revoke execute on function public.trg_session_rounds_auto_score() from public;
revoke execute on function public.trg_session_rounds_auto_score() from anon, authenticated;
revoke execute on function public.trg_session_rounds_guard() from public;
revoke execute on function public.trg_session_rounds_guard() from anon, authenticated;

drop trigger if exists trg_session_rounds_guard on public.session_rounds;
create trigger trg_session_rounds_guard
  before insert or update of status on public.session_rounds
  for each row execute function public.trg_session_rounds_guard();

drop trigger if exists trg_session_rounds_auto_score on public.session_rounds;
create trigger trg_session_rounds_auto_score
  after update of status on public.session_rounds
  for each row execute function public.trg_session_rounds_auto_score();

-- ④ 改三支線上函式 ───────────────────────────────────────────────────
do $mig$
declare
  v_old text; v_new text; v_pat text; v_n int;
begin
  -- ── _score_settle_tx：拿掉「放掉平板」 ──
  v_old := pg_get_functiondef('public._score_settle_tx(uuid)'::regprocedure);
  if v_old like '%搬到收桌%' then
    raise exception '_score_settle_tx 已經改過了，不要重跑這一段';
  end if;
  -- ⚠ 樣式一律用 \s 與 [[:blank:]]：Postgres 的方括號裡 \n 不會當換行，跨行會對不上（2026-09-29 套用前檢查踩到）
  v_pat := '[[:blank:]]*-- ⑤[^[:cntrl:]]*\s+update session_players set device_id = null\s+where session_id = p_session_id and device_id is not null;';
  select count(*) into v_n from regexp_matches(v_old, v_pat, 'g');
  if v_n <> 1 then
    raise exception '_score_settle_tx 找不到「放掉平板」那一段（命中 % 處），整份回滾', v_n;
  end if;
  v_new := regexp_replace(v_old, v_pat,
    '  /* ⑤ 放掉平板：2026-09-29 搬到收桌（settle_session_tx）。結算現在在最後一將打完時自動跑，那時平板還要看牌局結束卡。 */');
  if v_new = v_old or v_new like '%set device_id = null%' then
    raise exception '_score_settle_tx 沒有換乾淨，整份回滾';
  end if;
  execute v_new;

  -- ── settle_session_tx：放掉平板搬來這裡、記誰收的桌、已有名次就不再結算 ──
  v_old := pg_get_functiondef('public.settle_session_tx(uuid,uuid,boolean)'::regprocedure);
  if v_old like '%_session_scored%' then
    raise exception 'settle_session_tx 已經改過了，不要重跑這一段';
  end if;

  v_pat := '(update table_sessions\s+set\s+status\s*=\s*''completed'',)';
  select count(*) into v_n from regexp_matches(v_old, v_pat, 'g');
  if v_n <> 1 then
    raise exception 'settle_session_tx 找不到「update table_sessions set status = completed」（命中 % 處），整份回滾', v_n;
  end if;
  v_new := regexp_replace(v_old, v_pat,
    E'update session_players set device_id = null   /* 🆕 2026-09-29 放掉平板：從結算搬到收桌 */\n'
    || E'   where session_id = p_session_id and device_id is not null;\n'
    || E'  update table_sessions\n'
    || E'     set closed_by_staff_id = p_staff_id,   /* 🆕 誰收的桌（獎金依據）；冪等那條路在前面就 return，第一次按的人為準 */\n'
    || E'         status = ''completed'',');

  v_pat := 'v_score := public._score_settle_tx(p_session_id);';
  v_n := (length(v_new) - length(replace(v_new, v_pat, ''))) / length(v_pat);
  if v_n <> 1 then
    raise exception 'settle_session_tx 找不到「v_score := _score_settle_tx」（命中 % 處），整份回滾', v_n;
  end if;
  v_new := replace(v_new, v_pat,
    E'/* 🆕 2026-09-29 成績在最後一將打完時就結算過了（trg_session_rounds_auto_score）⇒ 已經有名次就不再算\n'
    || E'       （段位分算兩次會重複加）；沒打完約定將數就收桌的，仍然在這裡補算 */\n'
    || E'    if public._session_scored(p_session_id) then\n'
    || E'      v_score := jsonb_build_object(''ok'', true, ''already_scored'', true);\n'
    || E'    else\n'
    || E'      v_score := public._score_settle_tx(p_session_id);\n'
    || E'    end if;');
  if v_new = v_old or v_new not like '%closed_by_staff_id%' or v_new not like '%_session_scored%' then
    raise exception 'settle_session_tx 沒有換到預期的兩處，整份回滾';
  end if;
  execute v_new;

  -- ── tbl_state_tx：多回 rating_delta ──
  v_old := pg_get_functiondef('public.tbl_state_tx(text)'::regprocedure);
  if v_old like '%rating_delta%' then
    raise exception 'tbl_state_tx 已經改過了，不要重跑這一段';
  end if;
  v_pat := '(''log'',\s*coalesce\(v_log,\s*''\[\]''::jsonb\),\s*''patterns'',\s*v_catalog)\)';
  select count(*) into v_n from regexp_matches(v_old, v_pat, 'g');
  if v_n <> 1 then
    raise exception 'tbl_state_tx 找不到結尾的 ''log''…''patterns'', v_catalog（命中 % 處），整份回滾', v_n;
  end if;
  v_new := regexp_replace(v_old, v_pat,
    E'\\1,\n'
    || E'    /* 🆕 2026-09-29 段位分變動（座位 → 分數）：成績算完才有，沒算過是 null ⇒ 前端顯示「—」。\n'
    || E'       score_points ＝ 每一將實際變動的加總（夾過降階保護之後），就是 App 牌局詳情的「段位分」 */\n'
    || E'    ''rating_delta'', (select jsonb_object_agg(sp.seat::text, sp.score_points)\n'
    || E'                       from session_players sp\n'
    || E'                      where sp.session_id = s.id and sp.seat is not null\n'
    || E'                        and sp.finish_rank is not null and sp.score_points is not null))');
  if v_new = v_old or v_new not like '%rating_delta%' then
    raise exception 'tbl_state_tx 沒有換到預期的位置，整份回滾';
  end if;
  execute v_new;
end $mig$;

-- ⑤ 驗證（單一 SELECT，不 raise）────────────────────────────────────────
do $$
declare
  v text := ''; n int; t text; ok text := '✅ '; bad text := '🔴 ';
begin
  select count(*) into n from information_schema.columns
   where table_schema = 'public' and table_name = 'table_sessions' and column_name = 'closed_by_staff_id';
  v := v || (case when n = 1 then ok else bad end) || '① table_sessions.closed_by_staff_id 欄位在' || E'\n';

  select count(*) into n from pg_trigger
   where tgrelid = 'public.session_rounds'::regclass and not tgisinternal
     and tgname in ('trg_session_rounds_auto_score', 'trg_session_rounds_guard');
  v := v || (case when n = 2 then ok else bad end) || '② session_rounds 兩個觸發器都在（' || n || '/2）' || E'\n';

  select count(*) into n from pg_proc
   where pronamespace = 'public'::regnamespace and proname = '_score_settle_tx'
     and pg_get_functiondef(oid) like '%set device_id = null%';
  v := v || (case when n = 0 then ok else bad end) || '③ _score_settle_tx 不再放掉平板' || E'\n';

  select count(*) into n from pg_proc
   where pronamespace = 'public'::regnamespace and proname = 'settle_session_tx'
     and pg_get_functiondef(oid) like '%closed_by_staff_id%'
     and pg_get_functiondef(oid) like '%_session_scored%'
     and pg_get_functiondef(oid) like '%set device_id = null%';
  v := v || (case when n = 1 then ok else bad end) || '④ settle_session_tx 有放平板／記誰收的／跳過已結算' || E'\n';

  select count(*) into n from pg_proc
   where pronamespace = 'public'::regnamespace and proname = 'tbl_state_tx'
     and pg_get_functiondef(oid) like '%rating_delta%';
  v := v || (case when n = 1 then ok else bad end) || '⑤ tbl_state_tx 回 rating_delta' || E'\n';

  -- 三支函式各只有一個版本（簽名沒變、沒有多載）
  select count(*) into n from pg_proc
   where pronamespace = 'public'::regnamespace and proname in ('_score_settle_tx', 'settle_session_tx', 'tbl_state_tx');
  v := v || (case when n = 3 then ok else bad end) || '⑥ 三支函式各一個版本（' || n || '/3）' || E'\n';

  -- 授權：兩種來源都要看（硬規則 2.6／2.6b）。新函式一律不給前端叫
  select string_agg(p.proname || '（' ||
           case when p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')
                then 'PUBLIC有 ' else '' end ||
           case when exists (select 1 from aclexplode(p.proacl) a where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
                then 'anon有' else '' end || '）', '、')
    into t
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('_session_scored', 'trg_session_rounds_auto_score', 'trg_session_rounds_guard')
     and (p.proacl is null
          or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')
          or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE'));
  v := v || (case when t is null then ok else bad end) || '⑦ 新的三支函式沒有 PUBLIC／anon 可執行' || coalesce('：' || t, '') || E'\n';

  -- 負對照：收桌與結算原本該有的東西沒被誤傷
  select count(*) into n from pg_proc
   where pronamespace = 'public'::regnamespace and proname = 'settle_session_tx'
     and pg_get_functiondef(oid) like '%placeholder_ranks_tx%'
     and pg_get_functiondef(oid) like '%p_keep_for_walkin%';
  v := v || (case when n = 1 then ok else bad end) || '⑧ 負對照：收桌仍保留隨機名次備援與「留給現場」' || E'\n';

  perform set_config('migi.v', v, true);
end $$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有訊息') as "驗證";
