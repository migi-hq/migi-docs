-- ============================================================
-- 智慧計分板：選錯位置可以重選（2026-10-11 使用者：「開局選錯位置，應該要有可以重挑選機制」）
--
-- 起因：A1 第三將 YuDe 與呦選錯位置，只能由我寫 SQL 改（sql/applied/2026-10-11_A1第三將YuDe與呦對調.sql）。
--   第一將原本就能在記分前重定（tbl_set_order_tx），但前端沒有入口；第二將以後連後端都不能改。
--
-- 新增 tbl_reorder_round_tx(token, 莊家, 下家, 對家)：改「這一將」的繞桌順序與起莊
--   · 任何一將都用這一支（第一將也是）—— 只改 session_rounds.seat_ring／first_dealer_seat，
--     🔴 不改 session_players.seat：座位號代表那個人，前面幾將的局都記在座位號上
--   · 只在這一將還沒有任何一局時可以改；咔啦碰、分紅不算一局（不影響輪莊，同 _tbl_round_state）
--   · 有一局在等確認時不能改（先處理那一局）；這一將打完了要從「開始下一將」選
-- 權限：平板用裝置憑證（同其他 tbl_ 函式），2026-09-29 起新函式預設全關 ⇒ 下面明確 grant。
-- 行為測試另外跑 sql/checks/2026-10-11_驗計分板重選位置.sql（交易內自己造一場，最後回滾）。
-- ============================================================

create or replace function public.tbl_reorder_round_tx(
  p_token text, p_dealer_seat smallint, p_next_seat smallint, p_opposite_seat smallint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare d public.table_devices; s public.table_sessions; r public.session_rounds; v_last smallint; v_ring smallint[];
begin
  d := public._tbl_device(p_token);
  select * into s from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  select * into r from session_rounds where session_id = s.id and status = 'playing';
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_round', 'message', '這一將已經打完，請從「開始下一將」選位置');
  end if;
  if p_dealer_seat is null or p_next_seat is null or p_opposite_seat is null
     or p_dealer_seat not between 1 and 4 or p_next_seat not between 1 and 4 or p_opposite_seat not between 1 and 4
     or p_dealer_seat = p_next_seat or p_dealer_seat = p_opposite_seat or p_next_seat = p_opposite_seat then
    return jsonb_build_object('ok', false, 'reason', 'bad_order', 'message', '三個人要選不同的人');
  end if;
  if exists (select 1 from hands where round_id = r.id and status = 'pending') then
    return jsonb_build_object('ok', false, 'reason', 'pending_exists', 'message', '有一局在等確認，先處理那一局');
  end if;
  -- 咔啦碰、分紅不是一局（不推進局數與莊家），打過也可以重選
  if exists (select 1 from hands where round_id = r.id and status = 'confirmed' and result not in ('kala', 'bonus')) then
    return jsonb_build_object('ok', false, 'reason', 'already_started', 'message', '這一將已經開始記分了，位置不能再改');
  end if;

  select x into v_last from unnest('{1,2,3,4}'::smallint[]) x
   where x not in (p_dealer_seat, p_next_seat, p_opposite_seat);
  v_ring := array[p_dealer_seat, p_next_seat, p_opposite_seat, v_last];

  update session_rounds set first_dealer_seat = p_dealer_seat, seat_ring = v_ring where id = r.id;
  perform public._tbl_ping(s.id);
  return jsonb_build_object('ok', true, 'round_no', r.round_no, 'seat_ring', to_jsonb(v_ring));
end $function$;

revoke execute on function public.tbl_reorder_round_tx(text, smallint, smallint, smallint) from public;
grant  execute on function public.tbl_reorder_round_tx(text, smallint, smallint, smallint) to anon, authenticated;

-- ── 驗證（單一 SELECT）：版本數 1、DEFINER、anon 與 authenticated 明確有、PUBLIC 沒有 ──
select string_agg(x, E'\n') as "驗證" from (
  select case when count(*) = 1 then '✅ ① tbl_reorder_round_tx 只有一個版本' else '🔴 ① 版本數 ' || count(*) end x
    from pg_proc where pronamespace = 'public'::regnamespace and proname = 'tbl_reorder_round_tx'
  union all
  select case when bool_and(p.prosecdef) then '✅ ② SECURITY DEFINER' else '🔴 ② 不是 DEFINER' end
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'tbl_reorder_round_tx'
  union all
  select case when
      exists (select 1 from aclexplode(p.proacl) a where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
      and exists (select 1 from aclexplode(p.proacl) a where a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE')
      and not exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')
    then '✅ ③ 平板叫得動（anon、authenticated 明確授權；PUBLIC 沒有）'
    else '🔴 ③ 授權不對：' || coalesce(p.proacl::text, '（沒動過 ＝ PUBLIC 有）') end
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'tbl_reorder_round_tx'
) t;
