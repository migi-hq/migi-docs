-- ════════════════════════════════════════════════════════════════════
-- 回到第一局：每一將都能用（2026-10-20 使用者：「改成每一將的前 3 局都能回到第一局」）
--
-- 原本（2026-10-16）只有第 1 將能用；這份只拿掉「第 1 將」那一個條件，其餘規則不變：
--   · 畫面上是第 2 或第 3 局（這一將已經記了 1～2 局；咔啦碰、分紅不算一局）
--   · 沒有一局在等確認
--   · 這一場沒有人爆卡過（仍然看整場 —— 教學模式 engine.js 同一條，兩份要一致）
--   · 成績算好了就不行
-- 撤銷的範圍仍然只有「目前這一將」已記的局（含咔啦碰、分紅）；前面幾將打完的不動。
--
-- 簽名不變 ⇒ CREATE OR REPLACE，授權不會掉。
-- 前端（migi-table）同批：主畫面按鈕出現條件、教學 engine.js 拿掉「第 1 將」。
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

  -- 目前這一將（2026-10-20 起不限第 1 將）
  select * into r from session_rounds
   where session_id = v_session and status <> 'voided' order by round_no desc limit 1;
  if r.id is null or r.status <> 'playing' then
    return jsonb_build_object('ok', false, 'reason', 'not_playing', 'message', '這一將已經打完了');
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

-- 驗證（單一 SELECT）：版本 1 個、不再限第 1 將、其餘擋牆都還在、授權沒掉
select
  case when (select count(*) from pg_proc where proname = 'tbl_reset_round_tx' and pronamespace = 'public'::regnamespace) = 1
       then '✅ 1 個版本' else '🔴 版本數不對' end as "①",
  case when pg_get_functiondef(p.oid) !~ 'round_no\s*<>\s*1' then '✅ 不再限第 1 將' else '🔴 還有第 1 將的條件' end as "②",
  case when pg_get_functiondef(p.oid) ~ 'too_late' and pg_get_functiondef(p.oid) ~ 'pending_exists'
        and pg_get_functiondef(p.oid) ~ 'session_busts' and pg_get_functiondef(p.oid) ~ '_session_scored'
       then '✅ 第 4 局／等確認／爆卡／已結算 四道都在' else '🔴 少了擋牆' end as "③",
  case when has_function_privilege('anon', p.oid, 'execute') and has_function_privilege('authenticated', p.oid, 'execute')
       then '✅ 平板叫得到（anon 與 authenticated）' else '🔴 授權掉了' end as "④"
from pg_proc p
where p.proname = 'tbl_reset_round_tx' and p.pronamespace = 'public'::regnamespace;
