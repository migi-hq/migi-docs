-- ============================================================
-- void_session_tx —— 店員手動取消尚未收費的開桌
-- ------------------------------------------------------------
-- 情境：
--   開桌設定按下去就會呼叫 open_session_tx 建立 table_sessions，
--   而 uq_sessions_open_table（table_id WHERE status='open'）會鎖住那張桌。
--   開錯桌、客人臨時不打了、設定選錯要重開 —— 目前店員沒有任何辦法清掉它，
--   只能等 pg_cron 的 cleanup_empty_sessions_tx(30)，
--   最久要 40 分鐘（30 分閒置門檻 + 10 分鐘排程間隔）。現場不可接受。
--
-- 本函式 = cleanup_empty_sessions_tx 的手動版，拿掉時間門檻、加上安全檢查。
--
-- 【安全設計：收過錢的桌不准用這支】
--   在現行流程裡 session_players 只在 join_session_tx（結帳）後才產生，
--   包含包桌後續零元入座者 —— 那代表開桌者已經付過整桌的錢。
--   所以只要有任何在座玩家就拒絕，請改走收桌結算。
--   清空 ≠ 退款；退款要走 reverse_txn_tx，是另一件事。
--
-- 【為什麼不需要 DROP FUNCTION】
--   void_session_tx 是全新函式，線上不存在同名者（2026-08-15 盤點確認），
--   不會產生多載。（硬規則 2 針對的是既有函式的簽名變更。）
--
-- 【欄位依據】
--   table_sessions.status 允許值 open / completed / voided
--     —— 注意是 voided，不是 void，只有這張表這樣拼（見 db-現況快照.md）
--   結束時間欄位是 ended_at，沒有 closed_at
--   審計欄為 updated_by（staffId 目前一律傳 null，函式接受 null）
--
-- 【SECURITY DEFINER】
--   POS 用 anon key 且無 auth session，INVOKER 會被 RLS 擋成靜默失敗（硬規則 4）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.void_session_tx(
  p_session_id uuid,
  p_staff_id   uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_status  text;
  v_table   uuid;
  v_label   text;
  v_players int;
begin
  -- 取場次現況（連桌號一起撈，回傳給 UI 顯示確認訊息）
  select ts.status, ts.table_id, t.label
    into v_status, v_table, v_label
    from table_sessions ts
    left join tables t on t.id = ts.table_id
   where ts.id = p_session_id;

  if v_status is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  -- 已經不是 open 就直接回報現況，不重複動作（可重複呼叫）
  if v_status <> 'open' then
    return jsonb_build_object(
      'ok', false, 'reason', 'not_open', 'status', v_status,
      'table_label', v_label);
  end if;

  -- 安全檢查：有任何在座玩家 = 已經收過錢，不准用這支清掉
  select count(*) into v_players
    from session_players sp
   where sp.session_id = p_session_id
     and sp.left_at is null;

  if v_players > 0 then
    return jsonb_build_object(
      'ok', false, 'reason', 'has_players', 'players', v_players,
      'table_label', v_label,
      'hint', '已有客人結帳入座，請改走收桌結算，不可直接作廢');
  end if;

  update table_sessions
     set status     = 'voided',
         ended_at   = now(),
         updated_at = now(),
         updated_by = coalesce(p_staff_id, updated_by)
   where id = p_session_id
     and status = 'open';   -- 併發保護：同時兩人按，只有一個會成功

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'race_lost');
  end if;

  return jsonb_build_object(
    'ok', true,
    'session_id',  p_session_id,
    'table_id',    v_table,
    'table_label', v_label);
end $function$;

COMMENT ON FUNCTION public.void_session_tx IS
  '店員手動取消尚未收費的開桌（無任何在座玩家才允許）。有人結帳過請改走收桌結算。';


-- ============================================================
-- 驗證（單一 SELECT —— SQL Editor 一次跑多個只顯示最後一個）
-- ------------------------------------------------------------
-- 期待結果：
--   版本數        = 1          （沒建出多載）
--   安全模式      = DEFINER
--   煙霧測試      = not_found   （拿不存在的 uuid 呼叫，證明函式真的跑得起來
--                                且不會有副作用 —— 硬規則 7：要看到回傳才算完成）
--   目前可清空的空桌 = 現在有幾張「open 但無人入座」的桌
-- ============================================================
select
  (select count(*)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'void_session_tx')        as 版本數,

  (select case when p.prosecdef then 'DEFINER' else 'INVOKER' end
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'void_session_tx'
    limit 1)                                                            as 安全模式,

  (void_session_tx('00000000-0000-0000-0000-000000000000'::uuid) ->> 'reason')
                                                                        as 煙霧測試,

  (select count(*)
     from table_sessions ts
    where ts.status = 'open'
      and not exists (select 1 from session_players sp
                       where sp.session_id = ts.id and sp.left_at is null))
                                                                        as 目前可清空的空桌;
