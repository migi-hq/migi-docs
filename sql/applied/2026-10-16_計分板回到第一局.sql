-- ════════════════════════════════════════════════════════════════════
-- 2026-10-16 智慧計分板「回到第一局」按鈕（使用者：「加一個回到第一局按鈕，第 3 局後就會消失」）
-- 起因：10-15 A3 按錯兩局，要我寫 SQL 撤（sql/applied/2026-10-15_A3撤回前兩局.sql）—— 這種事桌上自己就該能做
--
-- 規則（教學模式 migi-table/src/lib/engine.js 的 resetRound 同一條，改一邊要改另一邊）：
--   · 只在第 1 將、這一將還在打
--   · 已經記了 1～2 局（＝畫面上是第 2 或第 3 局；咔啦碰、分紅不算一局）—— 打到第 4 局就不行
--   · 沒有一局在等確認、這一場沒有人爆卡過
--   · 這一將已記的局（含咔啦碰、分紅）全部標成 undone ⇒ 莊家、局數、四家積分回到開局
--   做法同計分板既有的「撤銷上一局」（tbl_undo_last_tx）：status → undone、記 undone_at
-- ════════════════════════════════════════════════════════════════════
create or replace function public.tbl_reset_round_tx(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare d public.table_devices; v_session uuid; v_me smallint; r public.session_rounds; v_n int; v_k int;
begin
  d := public._tbl_device(p_token);
  select id into v_session from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if v_session is null then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  select seat into v_me from session_players
   where session_id = v_session and device_id = d.id and left_at is null;
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'no_seat', 'message', '請先選「我是誰」');
  end if;
  if public._session_scored(v_session) then
    return jsonb_build_object('ok', false, 'reason', 'scored', 'message', '這一場成績已經算好了');
  end if;

  select * into r from session_rounds
   where session_id = v_session and status <> 'voided' order by round_no desc limit 1;
  if r.id is null or r.round_no <> 1 or r.status <> 'playing' then
    return jsonb_build_object('ok', false, 'reason', 'not_first_round', 'message', '只有第 1 將打到第 3 局以前可以回到第一局');
  end if;
  if exists (select 1 from hands where session_id = v_session and status = 'pending') then
    return jsonb_build_object('ok', false, 'reason', 'pending_exists', 'message', '有一局在等確認，先處理那一局');
  end if;
  if exists (select 1 from session_busts where session_id = v_session) then
    return jsonb_build_object('ok', false, 'reason', 'bust', 'message', '有人爆卡過，不能回到第一局，請找店員');
  end if;

  select count(*) into v_n from hands
   where round_id = r.id and status = 'confirmed' and result not in ('kala', 'bonus');
  if v_n < 1 then
    return jsonb_build_object('ok', false, 'reason', 'nothing', 'message', '還沒有打任何一局');
  end if;
  if v_n > 2 then
    return jsonb_build_object('ok', false, 'reason', 'too_late', 'message', '已經打到第 4 局，不能回到第一局了');
  end if;

  update hands set status = 'undone', undone_at = now()
   where round_id = r.id and status = 'confirmed';
  get diagnostics v_k = row_count;

  perform public._tbl_ping(v_session);
  return jsonb_build_object('ok', true, 'undone', v_k);
end $function$;

-- 計分板用 anon 金鑰 ＋ 裝置憑證認身分（同其他 tbl_ 函式）；2026-09-29 起新建的函式預設全關，要明確給
revoke all on function public.tbl_reset_round_tx(text) from public;
grant execute on function public.tbl_reset_round_tx(text) to anon, authenticated;

-- ════════════ 驗證（單一 SELECT，不 raise）════════════
select string_agg(x, E'\n' order by n) as "驗證" from (
  select 1 n, case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'tbl_reset_round_tx') = 1
                    and (select prosecdef from pg_proc where oid = 'public.tbl_reset_round_tx(text)'::regprocedure)
              then '✅ ① 函式一個版本、DEFINER' else '🔴 ① 函式' end x
  union all
  select 2, case when has_function_privilege('anon', 'public.tbl_reset_round_tx(text)', 'execute')
              then '✅ ② 計分板叫得動（anon）' else '🔴 ② anon 叫不動' end
  union all
  select 3, case when pg_get_functiondef('public.tbl_reset_round_tx(text)'::regprocedure) ~ 'v_n > 2'
                  and pg_get_functiondef('public.tbl_reset_round_tx(text)'::regprocedure) ~ 'round_no <> 1'
              then '✅ ③ 只在第 1 將、記了 1～2 局才能用' else '🔴 ③ 條件' end
) t;
