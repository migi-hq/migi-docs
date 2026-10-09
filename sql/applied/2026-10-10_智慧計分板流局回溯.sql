-- ============================================================
-- 智慧計分板「流局回溯」（2026-10-09，使用者：本局流局左邊新增一個按鈕，以免有人誤流局）
--
-- tbl_undo_draw_tx(p_token)：撤銷「上一局的流局」。照抄 tbl_undo_last_tx（撤銷上一局）的流程，多兩道：
--   · 最後一筆已入帳的局**必須是流局** —— 這顆按鈕不可以拿來撤別人的胡牌、咔啦碰、分紅
--   · 有人爆卡在等決定時不能撤（同等確認時的規矩）
-- 流局一定是連莊、不會結束一將，所以不會碰到「回溯到上一將」的情況；
-- 萬一那一將被標成打完，照 tbl_undo_last_tx 一樣改回 playing。
-- 不需要其他三家確認：流局四家都是 0 分，撤銷也不動任何人的積分。
--
-- ⚠ 計分規則有三份要一起改（CLAUDE.md 待辦 51）：這支、教學模式的 migi-table/src/lib/engine.js（undoDraw，同日已改）。
-- ⚠ 2026-09-29 起新建函式預設全關 ⇒ 下面明確開給 anon（平板用 anon 金鑰 ＋ 平板憑證）與 authenticated，
--   跟其他 tbl_ 函式一樣；身分由函式自己用憑證認（_tbl_device）。
-- ============================================================

create or replace function public.tbl_undo_draw_tx(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare d public.table_devices; v_session uuid; v_me smallint; h public.hands;
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
  if exists (select 1 from hands where session_id = v_session and status = 'pending') then
    return jsonb_build_object('ok', false, 'reason', 'pending_exists', 'message', '上一局還有人沒確認，先處理那一局');
  end if;
  if exists (select 1 from session_busts where session_id = v_session and decision = 'pending') then
    return jsonb_build_object('ok', false, 'reason', 'bust_pending', 'message', '有人爆卡在等決定，不能回溯');
  end if;

  -- 最後一筆已入帳的局（作廢的將裡的不算）
  select h2.* into h from hands h2
    join session_rounds r on r.id = h2.round_id and r.status <> 'voided'
   where h2.session_id = v_session and h2.status = 'confirmed'
   order by h2.created_at desc limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'nothing', 'message', '還沒有可以回溯的流局');
  end if;
  if h.result <> 'draw' then
    return jsonb_build_object('ok', false, 'reason', 'not_draw', 'message', '上一局不是流局，不能回溯');
  end if;

  update hands set status = 'undone', undone_at = now() where id = h.id;
  update session_rounds set status = 'playing', finished_at = null where id = h.round_id and status = 'finished';

  perform public._tbl_ping(v_session);
  return jsonb_build_object('ok', true, 'undone_hand_id', h.id);
end $function$;

revoke execute on function public.tbl_undo_draw_tx(text) from public;
grant  execute on function public.tbl_undo_draw_tx(text) to anon, authenticated;

-- ── 驗證（單一 SELECT；提交之後仍要另外查一次線上）──
select string_agg(x, E'\n' order by x) as "驗證"
from (
  -- ⚠ union all 的欄位名取自第一個 select，所以別名寫在這裡（2026-10-10 第一次跑就是漏了它，整份回滾）
  select case when count(*) = 1 then '✅' else '🔴' end || ' ① 函式只有一個版本（' || count(*) || '）' as x
    from pg_proc where pronamespace = 'public'::regnamespace and proname = 'tbl_undo_draw_tx'
  union all
  select case when has_function_privilege('anon', 'public.tbl_undo_draw_tx(text)'::regprocedure, 'execute')
               and has_function_privilege('authenticated', 'public.tbl_undo_draw_tx(text)'::regprocedure, 'execute')
              then '✅' else '🔴' end || ' ② 平板叫得動（anon ＋ authenticated）'
  union all
  select case when p.prosecdef then '✅' else '🔴' end || ' ③ SECURITY DEFINER'
    from pg_proc p where p.oid = 'public.tbl_undo_draw_tx(text)'::regprocedure
  union all
  -- 正對照：它跟撤銷上一局用的是同一支認平板的函式
  select case when pg_get_functiondef('public.tbl_undo_draw_tx(text)'::regprocedure) ~ '_tbl_device\(p_token\)'
               and pg_get_functiondef('public.tbl_undo_last_tx(text)'::regprocedure) ~ '_tbl_device\(p_token\)'
              then '✅' else '🔴' end || ' ④ 認平板的方式與撤銷上一局相同'
  union all
  -- 流局檢查真的拿來判斷（不是只出現在註解裡）
  select case when pg_get_functiondef('public.tbl_undo_draw_tx(text)'::regprocedure) ~ $q$if h\.result <> 'draw' then$q$
              then '✅' else '🔴' end || ' ⑤ 只撤流局的那道檢查在'
) v;
