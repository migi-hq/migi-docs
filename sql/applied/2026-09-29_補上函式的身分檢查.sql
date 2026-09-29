/* ============================================================
   補上函式的身分檢查（anon／登入的客人不可以冒名、不可以叫店員與內部的函式）
   2026-09-29 · 唯讀 MCP 逐支查證後寫的

   ── 起點 ──────────────────────────────────────────────
   同日收掉 22 支檢視表的前端權限之後，使用者問「還有其他地方嗎」。
   掃「前端叫得動、繞過 RLS（DEFINER）、函式裡卻沒有任何身分檢查」的函式：
     · list_members_tx：給 org id（寫在前端程式裡）就回**全部會員的手機號碼**，
       用公開的 anon 金鑰實測 200
     · 一批會員功能把「你是誰」當參數收（p_member／p_inviter／p_liker…）
       ⇒ 知道別人的 id 就能讀他的通知、牌咖、黑名單，或用他的名義報名、封鎖、加好友
     · POS 與內部的函式任何「登入的人」都叫得動 —— 而**會員 App 的客人也是登入的人**
       （pos_member_detail_tx 回手機與餘額、dev_set_test_balance_tx 直接改餘額）
   🔴 為什麼 9/11、9/20 兩次收身分都沒抓到：那兩次掃的是「參數叫 p_member_id」，
     這一批叫 p_member／p_inviter／p_liker。**判準畫太窄，第三次**（9/10 頭像下架也是）。
     ⇒ 同批在錯誤儀表加一格，用結構判斷，不看參數名。

   ── 五種處理（每一支都查過前端呼叫點與內部呼叫者）─────────
   ① 本人（15 支）：身分一律改成登入的本人，前端送的 id 忽略；沒登入回 28000
   ② 本人或店員（3 支）：店員可代客人（POS 查牌咖／黑名單、總部隱藏會員時會替他退房）
   ③ 清單公開、身分選填（2 支）：配桌房間清單照舊公開，「我在不在房裡」只認本人
   ④ 開房的人或店員（1 支）：update_play_at_tx —— 原本任何人都能改任何房的開打時間
   ⑤ 限店員（15 支）：新增 _api_staff_only()，**只擋從 API 進來、又不是店員的人**
      —— 排程（pg_cron）沒有 API 身分照常能跑，這是刻意的：
      cleanup_empty_sessions_tx／sweep_auto_seat_tx 同時被排程與 POS 叫
   ⑥ 收回前端權限（15 支，沒有前端在叫、內部呼叫者全是 postgres 的 DEFINER 或排程）
      ＋ 3 支只收 anon（get_session_tx／list_tables_tx 是 POS 在叫；next_doc_no 被
        INVOKER 觸發器用，authenticated 要留著）

   ── 刻意不動（下一批，理由各不同）─────────────────────────
   · pos_list_queues_tx／pos_list_recurring_tx：純 SQL 函式，插不進檢查，要改寫成 plpgsql
   · pos_queue_members_tx／pos_table_forecast_tx／_try_auto_seat_tx：會被會員報名湊滿的路徑
     從內部叫（join → 成桌 → 自動帶桌），加「限店員」會讓客人報名失敗
   · _blocked_between／has_daypass_tx：只回 true／false，會員 App 與 POS 都直接叫

   ── 機制（同 2026-09-20）─────────────────────────────────
   撈線上全文 → 在第一個 begin 後面插一段 → 替換不到、版本不是 1、語言不是 plpgsql、
   宣告區先用到那個參數 —— 任何一項就整份回滾。簽名不變 ⇒ create or replace，授權不掉。
   插入的每一段都帶【身分 2026-09-29】標記，重跑會被擋下（不會插兩次）。
   ⚠ 這份要留下東西 ⇒ 驗證段一個字都不 raise（硬規則 1.8）。
     行為測試：sql/checks/2026-09-29_驗函式身分檢查.sql（交易內用真的身分叫，最後回滾）
   ============================================================ */

/* ── 限店員的檢查（⑤ 共用）──────────────────────────────
   「從 API 進來」＝ PostgREST 有設 request.jwt.claims 或 request.method（anon 金鑰本身
   也是一張 JWT，所以 anon 一定有 claims）。排程與 SQL Editor 兩個都沒有 ⇒ 放行。 */
create or replace function public._api_staff_only()
returns void language plpgsql stable security definer set search_path to 'public'
as $$
begin
  if (coalesce(current_setting('request.jwt.claims', true), '') <> ''
      or coalesce(current_setting('request.method', true), '') <> '')
     and not exists (select 1 from public.current_staff()) then
    raise exception '這個操作只有店員可以做' using errcode = '42501';
  end if;
end $$;
revoke all on function public._api_staff_only() from public, anon, authenticated;

do $mig$
declare
  r      record;
  v_oid  oid;
  v_n    int;
  v_old  text;
  v_new  text;
  v_ins  text;
  v_done int := 0;
  c_tag  constant text := '【身分 2026-09-29】';
begin
  for r in select * from (values
    -- ① 本人
    ('list_notifications_tx','p_member','self'),('unread_count_tx','p_member','self'),
    ('mark_notifs_read_tx','p_member','self'),('list_recent_players_tx','p_member','self'),
    ('join_match_queue_tx','p_member','self'),('send_buddy_invite_tx','p_inviter','self'),
    ('respond_buddy_invite_tx','p_invitee','self'),('remove_buddy_tx','p_member','self'),
    ('block_member_tx','p_blocker','self'),('unblock_member_tx','p_blocker','self'),
    ('like_player_tx','p_liker','self'),('send_table_invite_tx','p_inviter','self'),
    ('respond_table_invite_tx','p_invitee','self'),('get_my_active_queue_tx','p_member','self'),
    ('create_match_queue_tx','p_opener','self'),
    -- ② 本人或店員
    ('leave_match_queue_tx','p_member','self_or_staff'),('list_buddies_tx','p_member','self_or_staff'),
    ('list_blocks_tx','p_member','self_or_staff'),
    -- ③ 清單公開、身分選填
    ('list_match_queues_tx','p_member','flag'),('list_match_queues_by_city_tx','p_member','flag'),
    -- ④ 開房的人或店員
    ('update_play_at_tx','p_queue','opener'),
    -- ⑤ 限店員
    ('get_session_tx','-','staff'),('get_session_member_orders_tx','-','staff'),
    ('check_session_blocks_tx','-','staff'),('pos_member_detail_tx','-','staff'),
    ('pos_add_queue_member_tx','-','staff'),('pos_close_queue_tx','-','staff'),
    ('pos_create_queue_tx','-','staff'),('pos_create_recurring_tx','-','staff'),
    ('pos_set_recurring_enabled_tx','-','staff'),('set_table_active_tx','-','staff'),
    ('set_table_auto_assign_tx','-','staff'),('calc_session_fee_tx','-','staff'),
    ('cleanup_empty_sessions_tx','-','staff'),('sweep_auto_seat_tx','-','staff'),
    ('list_tables_tx','-','staff')
  ) t(fn, prm, kind)
  loop
    select count(*), min(p.oid) into v_n, v_oid
      from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = r.fn;
    if v_n <> 1 then raise exception '🔴 % 有 % 個版本，整份回滾', r.fn, v_n; end if;
    if (select l.lanname from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = v_oid) <> 'plpgsql' then
      raise exception '🔴 % 不是 plpgsql，插不進檢查，整份回滾', r.fn;
    end if;

    v_old := pg_get_functiondef(v_oid);
    if position(c_tag in v_old) > 0 then
      raise exception '🔴 % 已經改過了（有標記），不要重跑', r.fn;
    end if;
    if r.prm <> '-' then
      if pg_get_function_identity_arguments(v_oid) !~ ('\m' || r.prm || '\M') then
        raise exception '🔴 % 沒有參數 %，整份回滾', r.fn, r.prm;
      end if;
      if coalesce(substring(v_old from '\$function\$(.*?)\mbegin\M'), '') ~ ('\m' || r.prm || '\M') then
        raise exception '🔴 % 的宣告區先用到 %，插在 begin 後面的改寫不會生效，整份回滾', r.fn, r.prm;
      end if;
    end if;

    v_ins := case r.kind
      when 'self' then
        E'\n  -- ' || c_tag || E'只認登入的本人，前端送的 id 一律忽略\n  '
        || r.prm || E' := public.current_member_id();\n  if ' || r.prm
        || E' is null then raise exception ''未登入或登入已過期，請重新開啟 App'' using errcode = ''28000''; end if;'
      when 'self_or_staff' then
        E'\n  -- ' || c_tag || E'店員可以代客人操作；其他人只認登入的本人\n'
        || E'  if not exists (select 1 from public.current_staff()) then\n    '
        || r.prm || E' := public.current_member_id();\n    if ' || r.prm
        || E' is null then raise exception ''未登入或登入已過期，請重新開啟 App'' using errcode = ''28000''; end if;\n  end if;'
      when 'flag' then
        E'\n  -- ' || c_tag || E'清單本身公開；「我在不在房裡」只認登入的本人（店員照舊）\n'
        || E'  if not exists (select 1 from public.current_staff()) then ' || r.prm
        || E' := public.current_member_id(); end if;'
      when 'opener' then
        E'\n  -- ' || c_tag || E'只有開房的人或店員能改開打時間\n'
        || E'  if not exists (select 1 from public.current_staff())\n'
        || E'     and not exists (select 1 from public.match_queues q where q.id = ' || r.prm
        || E' and q.opened_by = public.current_member_id()) then\n'
        || E'    raise exception ''只有開房的人可以改開打時間'' using errcode = ''42501'';\n  end if;'
      when 'staff' then
        E'\n  -- ' || c_tag || E'從 API 進來的只有店員能叫（排程沒有 API 身分，照常）\n'
        || E'  perform public._api_staff_only();'
    end;

    -- 插在「$function$ 之後的第一個 begin」後面（不加 g ⇒ 只換第一個）
    v_new := regexp_replace(v_old, '^(.*?\$function\$.*?\mbegin\M)', '\1' || replace(v_ins, '\', '\\'));
    if v_new = v_old or position(c_tag in v_new) = 0 then
      raise exception '🔴 % 沒有插進去，整份回滾', r.fn;
    end if;
    execute v_new;
    v_done := v_done + 1;
  end loop;

  -- 期望值：15 本人 ＋ 3 本人或店員 ＋ 2 身分選填 ＋ 1 開房的人 ＋ 15 限店員 ＝ 36
  if v_done <> 36 then raise exception '🔴 預期改 36 支，實際 %', v_done; end if;
end $mig$;

/* ── ⑥ 收回前端權限 ─────────────────────────────────────── */
do $rv$
declare r record; v_n int := 0;
begin
  -- 前端完全碰不到（內部呼叫者都是 postgres 擁有的 DEFINER，或排程）
  for r in select p.oid::regprocedure as sig from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
              and p.proname in ('list_members_tx','get_order_tx','create_invoice_draft_tx',
                'mark_invoice_issued_tx','mark_invoice_failed_tx','_finalize_queue_full_tx',
                '_check_join_conflict','daily_wallet_audit_tx','dev_reset_test_data_tx',
                'dev_set_test_balance_tx','generate_recurring_instances_tx','reconcile_wallets_tx',
                'sweep_expired_queues_tx','fix_wallet_balance_tx','pos_set_recurring_tags_tx')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
    v_n := v_n + 1;
  end loop;
  if v_n <> 15 then raise exception '🔴 預期收 15 支，實際 %', v_n; end if;

  -- 只收 anon（POS／觸發器還要用 authenticated）
  v_n := 0;
  for r in select p.oid::regprocedure as sig from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
              and p.proname in ('get_session_tx','list_tables_tx','next_doc_no')
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated, service_role', r.sig);
    v_n := v_n + 1;
  end loop;
  if v_n <> 3 then raise exception '🔴 預期只收 anon 3 支，實際 %', v_n; end if;
end $rv$;

/* ── 驗證段（單一 SELECT，不 raise）────────────────────────── */
do $$
declare v_msg text := ''; v_n int; v_t text;
begin
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and pg_get_functiondef(p.oid) like '%【身分 2026-09-29】%';
  v_msg := v_msg || case when v_n = 36 then '✅ ① 36 支都插進身分檢查（15＋3＋2＋1＋15）'
                         else '🔴 ① 有標記的函式 ' || v_n || '/36' end;

  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and pg_get_functiondef(p.oid) like '%perform public._api_staff_only();%';
  v_msg := v_msg || E'\n' || case when v_n = 15 then '✅ ② 15 支限店員'
                                   else '🔴 ② 限店員 ' || v_n || '/15' end;

  /* ③ 前端碰不到那 15 支 —— 兩種來源都看（明確授權 ＋ PUBLIC，硬規則 2.6／2.6b） */
  select string_agg(p.proname, '、') into v_t from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname in ('list_members_tx','get_order_tx','create_invoice_draft_tx','mark_invoice_issued_tx',
       'mark_invoice_failed_tx','_finalize_queue_full_tx','_check_join_conflict','daily_wallet_audit_tx',
       'dev_reset_test_data_tx','dev_set_test_balance_tx','generate_recurring_instances_tx',
       'reconcile_wallets_tx','sweep_expired_queues_tx','fix_wallet_balance_tx','pos_set_recurring_tags_tx',
       '_api_staff_only')
     and (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
            where a.grantee in (0, 'anon'::regrole::oid, 'authenticated'::regrole::oid) and a.privilege_type = 'EXECUTE'));
  v_msg := v_msg || E'\n' || case when v_t is null then '✅ ③ 16 支內部函式前端都叫不到（含 _api_staff_only）'
                                   else '🔴 ③ 還叫得到：' || v_t end;

  select string_agg(p.proname, '、') into v_t from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname in ('get_session_tx','list_tables_tx','next_doc_no')
     and (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
            where a.grantee in (0, 'anon'::regrole::oid) and a.privilege_type = 'EXECUTE'));
  v_msg := v_msg || E'\n' || case when v_t is null then '✅ ④ get_session_tx／list_tables_tx／next_doc_no 的 anon 收掉了'
                                   else '🔴 ④ anon 還叫得到：' || v_t end;

  /* ⑤ 正對照：前端要用的還叫得動（沒有把 POS／會員 App 打壞） */
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and pg_get_functiondef(p.oid) like '%【身分 2026-09-29】%'
     and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  v_msg := v_msg || E'\n' || case when v_n = 36 then '✅ ⑤ 正對照：36 支登入的人照樣叫得動（檢查在函式裡，不是收權限）'
                                   else '🔴 ⑤ 只有 ' || v_n || '/36 還叫得動 —— 前端會壞' end;

  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname in ('list_members_tx','daily_wallet_audit_tx','sweep_expired_queues_tx','fix_wallet_balance_tx')
     and has_function_privilege('service_role', p.oid, 'EXECUTE');
  v_msg := v_msg || E'\n' || case when v_n = 4 then '✅ ⑥ 正對照：service_role 照樣叫得到內部函式'
                                   else '🔴 ⑥ service_role ' || v_n || '/4' end;

  /* ⑦ 結構性掃描：前端叫得動、帶「指定人」的參數、卻沒有任何身分檢查的 DEFINER 函式。
        期望剩下的剛好是刻意延後的 4 支 —— 多出任何一支就是新的洞 */
  select string_agg(p.proname, '、' order by p.proname collate "C") into v_t   -- collate "C"：底線的排序不受語系影響
    from pg_proc p, lateral (select pg_get_functiondef(p.oid) d) x
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.prosecdef
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     and pg_get_function_result(p.oid) <> 'trigger'
     and x.d !~ 'current_member_id\(\)|current_staff\(\)|\mcan\(|_api_staff_only|_tbl_(device|auth|hash)|p_token|migi_jwt'
     and pg_get_function_identity_arguments(p.oid) ~ 'p_(member|member_id|inviter|invitee|liker|blocker|opener|queue|order_id|session_id|invoice_id|team|a|b)\M';
  v_msg := v_msg || E'\n' || case
    when v_t = '_blocked_between、_try_auto_seat_tx、has_daypass_tx、pos_queue_members_tx'
      then '✅ ⑦ 沒有身分檢查的只剩刻意延後的 4 支：' || v_t
    else '🔴 ⑦ 沒有身分檢查的：' || coalesce(v_t, '（沒有）') || '（期望剛好是延後的 4 支）' end;

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
