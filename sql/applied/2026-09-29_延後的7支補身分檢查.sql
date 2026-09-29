/* ============================================================
   補完同日延後的 7 支：拆成「內層（原本的程式）＋ 外層（先檢查身分）」
   2026-09-29 · 接 `2026-09-29_補上函式的身分檢查.sql`

   ── 為什麼上一批沒有直接加「限店員」──────────────────────
   | 函式 | 卡在哪 |
   |---|---|
   | pos_queue_members_tx   | POS 直接叫；**客人報名湊滿時**也會經 pos_seat_queue_tx 從內部叫到 |
   | pos_table_forecast_tx  | POS 直接叫；湊滿 → 自動帶桌（_try_auto_seat_tx）也會叫 |
   | _try_auto_seat_tx      | POS 直接叫；湊滿（_finalize_queue_full_tx）與排程（sweep_auto_seat_tx）也會叫 |
   | pos_list_queues_tx／pos_list_recurring_tx／has_daypass_tx | 純 SQL 函式，插不進檢查 |
   | _blocked_between       | 以為會員 App 在叫 —— **查證後前端根本沒叫**（搜到的是註解） |
   🔴 「限店員」是看**這一次 API 請求是誰發的**：客人按報名 ⇒ 整條路徑上都是客人的身分
     ⇒ 內部叫到的函式如果有「限店員」，報名就會失敗。

   ── 做法 ──────────────────────────────────────────────
   · 內層 `<名字>_core`：原本的程式**一字不改**複製過去（只換函式名），前端叫不到
   · 外層沿用原本的名字與簽名：先 `_api_staff_only()`，再轉給內層 ⇒ 前端一行不用改
   · 內部呼叫改接內層：pos_seat_queue_tx、_try_auto_seat_tx 的內層、
     _finalize_queue_full_tx、sweep_auto_seat_tx
   · has_daypass_tx 的內部呼叫者（calc_session_fee_tx／join_session_tx）都是 POS 路徑，
     維持呼叫外層即可
   · _blocked_between：直接收回前端權限（內部呼叫者全是 postgres 擁有的 DEFINER）
   ⚠ 外層把 sql 改成 plpgsql：create or replace 允許（簽名、回傳型別不變），授權不會掉
   ⚠ 內層是新建的 ⇒ 吃同日改好的「預設全關」—— 前端本來就叫不到，下面仍明確再收一次

   ── 這份要留下東西 ⇒ 驗證段一個字都不 raise（硬規則 1.8）──
     行為測試：sql/checks/2026-09-29_驗延後7支.sql（含「客人報名湊滿 → 自動帶桌」整條路）
   ============================================================ */

do $mig$
declare
  r      record;
  v_oid  oid;
  v_def  text;
  v_new  text;
  v_args text;
  v_names text;
  v_ret  text;
  v_vol  text;
  v_n    int;
begin
  /* ── ① 建內層：原本的全文，只把函式名換成 _core ──────────
        順序有關係：pos_table_forecast_tx 的內層要先建，因為 _try_auto_seat_tx 的內層會叫它 */
  for r in select * from (values
      (1, 'pos_table_forecast_tx'), (2, 'pos_queue_members_tx'), (3, '_try_auto_seat_tx'),
      (4, 'pos_list_queues_tx'), (5, 'pos_list_recurring_tx'), (6, 'has_daypass_tx')) t(ord, fn)
    order by ord
  loop
    select count(*), min(p.oid) into v_n, v_oid from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = r.fn;
    if v_n <> 1 then raise exception '🔴 % 有 % 個版本，整份回滾', r.fn, v_n; end if;
    if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = r.fn || '_core') then
      raise exception '🔴 %_core 已經存在，不要重跑', r.fn;
    end if;
    v_def := pg_get_functiondef(v_oid);
    if position('_api_staff_only' in v_def) > 0 then
      raise exception '🔴 % 已經有身分檢查了，不要重跑', r.fn;
    end if;

    v_new := regexp_replace(v_def, 'FUNCTION public\.' || r.fn || '\(', 'FUNCTION public.' || r.fn || '_core(');
    if v_new = v_def then raise exception '🔴 % 的函式名換不到，整份回滾', r.fn; end if;
    -- _try_auto_seat_tx 的內層改叫預測的內層（外層之後會限店員，而客人湊滿時會走到這裡）
    if r.fn = '_try_auto_seat_tx' then
      v_def := v_new;
      v_new := regexp_replace(v_def, '(\W)pos_table_forecast_tx(\s*\()', '\1pos_table_forecast_tx_core\2', 'g');
      if v_new = v_def then raise exception '🔴 _try_auto_seat_tx 裡找不到預測的呼叫，整份回滾'; end if;
    end if;
    execute v_new;
    execute format('revoke all on function %s from public, anon, authenticated',
                   (select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = r.fn || '_core'));
    execute format('grant execute on function %s to service_role',
                   (select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = r.fn || '_core'));
  end loop;

  /* ── ② 外層：原本的名字與簽名，先檢查身分再轉給內層 ────── */
  for r in select unnest(array['pos_table_forecast_tx','pos_queue_members_tx','_try_auto_seat_tx',
                               'pos_list_queues_tx','pos_list_recurring_tx','has_daypass_tx']) as fn
  loop
    select p.oid into v_oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = r.fn;
    v_args := pg_get_function_arguments(v_oid);
    v_ret  := pg_get_function_result(v_oid);
    select string_agg(quote_ident(a), ', ' order by i) into v_names
      from unnest((select proargnames from pg_proc where oid = v_oid)) with ordinality x(a, i);
    select case provolatile when 's' then 'stable' when 'i' then 'immutable' else 'volatile' end
      into v_vol from pg_proc where oid = v_oid;
    if v_ret not in ('jsonb', 'boolean') then raise exception '🔴 % 回傳 %，外層寫法不適用', r.fn, v_ret; end if;
    execute format($f$
      create or replace function public.%1$I(%2$s) returns %3$s
      language plpgsql %4$s security definer set search_path to 'public'
      as $w$
      begin
        -- 【身分 2026-09-29】從 API 進來的只有店員能叫；內部呼叫一律接 %1$s_core
        perform public._api_staff_only();
        return public.%5$I(%6$s);
      end $w$ $f$, r.fn, v_args, v_ret, v_vol, r.fn || '_core', v_names);
  end loop;

  /* ── ③ 內部呼叫改接內層 ─────────────────────────────── */
  for r in select * from (values
      ('pos_seat_queue_tx',       'pos_queue_members_tx'),
      ('_finalize_queue_full_tx', '_try_auto_seat_tx'),
      ('sweep_auto_seat_tx',      '_try_auto_seat_tx')) t(caller, callee)
  loop
    select count(*), min(p.oid) into v_n, v_oid from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = r.caller;
    if v_n <> 1 then raise exception '🔴 % 有 % 個版本，整份回滾', r.caller, v_n; end if;
    v_def := pg_get_functiondef(v_oid);
    v_new := regexp_replace(v_def, '(\W)' || r.callee || '(\s*\()', '\1' || r.callee || '_core\2', 'g');
    if v_new = v_def then raise exception '🔴 % 裡找不到 % 的呼叫，整份回滾', r.caller, r.callee; end if;
    execute v_new;
  end loop;

  /* ── ④ _blocked_between：前端沒在叫，直接收 ──────────────── */
  if exists (select 1 from pg_proc q
              where q.pronamespace = 'public'::regnamespace and q.prokind = 'f' and q.proname <> '_blocked_between'
                and pg_get_functiondef(q.oid) ~ '\m_blocked_between\s*\('
                and not (q.prosecdef and pg_get_userbyid(q.proowner) = 'postgres')) then
    raise exception '🔴 有非 postgres DEFINER 的函式在叫 _blocked_between，收了會壞，整份回滾';
  end if;
  execute 'revoke all on function public._blocked_between(uuid, uuid, uuid) from public, anon, authenticated';
  execute 'grant execute on function public._blocked_between(uuid, uuid, uuid) to service_role';
end $mig$;

/* ── 驗證段（單一 SELECT，不 raise）────────────────────────── */
do $$
declare v_msg text := ''; v_n int; v_t text;
begin
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('pos_table_forecast_tx_core','pos_queue_members_tx_core','_try_auto_seat_tx_core',
                       'pos_list_queues_tx_core','pos_list_recurring_tx_core','has_daypass_tx_core')
     and not has_function_privilege('anon', p.oid, 'EXECUTE')
     and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
     and has_function_privilege('service_role', p.oid, 'EXECUTE');
  v_msg := v_msg || case when v_n = 6 then '✅ ① 6 支內層都建好，前端叫不到、service_role 叫得到'
                         else '🔴 ① 內層 ' || v_n || '/6' end;

  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('pos_table_forecast_tx','pos_queue_members_tx','_try_auto_seat_tx',
                       'pos_list_queues_tx','pos_list_recurring_tx','has_daypass_tx')
     and pg_get_functiondef(p.oid) like '%perform public._api_staff_only();%'
     and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  v_msg := v_msg || E'\n' || case when v_n = 6 then '✅ ② 6 支外層都先檢查身分，而且 POS（登入的人）照樣叫得動'
                                   else '🔴 ② 外層 ' || v_n || '/6' end;

  /* ③ 內部呼叫都改接內層了（湊滿 → 自動帶桌那條路不會撞到「限店員」） */
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and ((p.proname = 'pos_seat_queue_tx'       and pg_get_functiondef(p.oid) ~ 'pos_queue_members_tx_core\s*\(' and pg_get_functiondef(p.oid) !~ 'pos_queue_members_tx\s*\(')
       or (p.proname = '_finalize_queue_full_tx' and pg_get_functiondef(p.oid) ~ '_try_auto_seat_tx_core\s*\('  and pg_get_functiondef(p.oid) !~ '_try_auto_seat_tx\s*\(')
       or (p.proname = 'sweep_auto_seat_tx'      and pg_get_functiondef(p.oid) ~ '_try_auto_seat_tx_core\s*\('  and pg_get_functiondef(p.oid) !~ '_try_auto_seat_tx\s*\(')
       or (p.proname = '_try_auto_seat_tx_core'  and pg_get_functiondef(p.oid) ~ 'pos_table_forecast_tx_core\s*\(' and pg_get_functiondef(p.oid) !~ 'pos_table_forecast_tx\s*\('));
  v_msg := v_msg || E'\n' || case when v_n = 4 then '✅ ③ 4 個內部呼叫點都改接內層'
                                   else '🔴 ③ 內部呼叫點 ' || v_n || '/4 —— 客人報名湊滿可能會被擋' end;

  select case when has_function_privilege('anon', 'public._blocked_between(uuid,uuid,uuid)', 'EXECUTE')
                or has_function_privilege('authenticated', 'public._blocked_between(uuid,uuid,uuid)', 'EXECUTE')
              then '🔴 ④ _blocked_between 前端還叫得到' else '✅ ④ _blocked_between 前端叫不到了' end into v_t;
  v_msg := v_msg || E'\n' || v_t;

  /* ⑤ 結構掃描：前端叫得動、收指定人參數、沒有身分檢查的 —— 期望 0 支（延後的全部處理完） */
  select string_agg(p.proname, '、' order by p.proname collate "C") into v_t
    from pg_proc p, lateral (select pg_get_functiondef(p.oid) d) x
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.prosecdef
     and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
     and pg_get_function_result(p.oid) <> 'trigger'
     and x.d !~ 'current_member_id\(\)|current_staff\(\)|\mcan\(|_api_staff_only|_tbl_(device|auth|hash)|p_token|migi_jwt'
     and pg_get_function_identity_arguments(p.oid) ~ 'p_(member|member_id|inviter|invitee|liker|blocker|opener|queue|order_id|session_id|invoice_id|team|a|b|target|buddy|blocked)\M';
  v_msg := v_msg || E'\n' || case when v_t is null then '✅ ⑤ 沒有任何「前端叫得動卻不檢查身分」的函式了'
                                   else '🔴 ⑤ 還有：' || v_t end;

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
