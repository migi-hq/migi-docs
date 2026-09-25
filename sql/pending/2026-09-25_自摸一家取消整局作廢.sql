/* ============================================================
   任何一人取消 ⇒ 這一局作廢、不推進，送出的人重送一次
   2026-09-25 · MIGI 咪吉麻將（使用者實機時拍板）

   ── 改之前（2026-09-23／24 的規則）──────────────────
   每一家各自確認、各自取消，互不影響：
     確認 ＝ 我這一份**當場入帳**；取消 ＝ 只有我這一份不算
   ⇒ 自摸（三家付）與包牌（付給三家）一家取消，另外兩家照算。

   ── 改之後：**所有類型一律全有或全無** ──────────────
     · 任何一個要確認的人按取消 ⇒ **整局立刻作廢**（status = rejected），
       已經按確認的也**不入帳**；作廢**不推進局數**，送出的人重送一次
     · 全部都確認 ⇒ **一次入帳**，金額就是送出時提出的那一份（proposed_delta）
   🎯 確認的當下不入帳，最後一個人確認時才一起入帳。
     不這樣做的話，先確認的人會看到分數先動、別人一取消又被退回來 ——
     畫面跳來跳去，而那筆分數從頭到尾都不該動。
   📌 實際改變行為的是**自摸**（三家付）與**包牌**（三家收）；
     放槍、咔啦碰只有一個人要確認，本來取消就等於作廢，結果不變。

   簽名不變 ⇒ CREATE OR REPLACE，授權不動。其餘邏輯照線上版（2026-09-25 撈）。
   ⚠ 檔名沿用第一版的「自摸」—— 範圍在同一天擴大成全部類型，檔頭為準。
   ============================================================ */

create or replace function public.tbl_confirm_hand_tx(p_token text, p_hand_id uuid, p_accept boolean)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
/* 確認與取消（2026-09-25 使用者拍板，取代 09-23／24 的「各付各的」）：
     **全有或全無** —— 任何一人取消 ⇒ 整局作廢、不推進，送出的人重送；
     全部確認 ⇒ 一次入帳（金額 ＝ 送出時提出的 proposed_delta）。 */
declare
  d public.table_devices; v_session uuid; v_me smallint; h public.hands;
  v_ok smallint[];
begin
  d := public._tbl_device(p_token);
  select id into v_session from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if v_session is null then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  select seat into v_me from session_players
   where session_id = v_session and device_id = d.id and left_at is null;

  select * into h from hands where id = p_hand_id and session_id = v_session for update;
  if not found or h.status <> 'pending' then
    return jsonb_build_object('ok', false, 'reason', 'not_pending', 'message', '這一局已經處理過了');
  end if;
  if v_me is null or not (v_me = any(h.need_confirm)) then
    return jsonb_build_object('ok', false, 'reason', 'not_yours', 'message', '這一局不需要你確認');
  end if;
  if v_me = any(h.confirmed_seats) or v_me = any(h.cancelled_seats) then
    return jsonb_build_object('ok', true, 'already', true);
  end if;

  /* ── 取消 ⇒ 整局作廢，立刻結束，不等其他人 ── */
  if not p_accept then
    update hands
       set cancelled_seats = h.cancelled_seats || v_me,
           -- 一分都不動（確認的當下本來就沒入帳，這裡保險再歸零一次）
           score_delta = (select coalesce(jsonb_object_agg(k, 0), '{}'::jsonb)
                            from jsonb_object_keys(h.proposed_delta) k),
           status = 'rejected', rejected_seat = v_me, confirmed_at = null
     where id = h.id;
    perform public._tbl_ping(v_session);
    return jsonb_build_object('ok', true, 'status', 'rejected', 'accepted', false, 'voided', true);
  end if;

  v_ok := h.confirmed_seats || v_me;

  -- 還有人沒確認 ⇒ 先記下「他確認了」，不入帳
  if exists (select 1 from unnest(h.need_confirm) x where not (x = any(v_ok))) then
    update hands set confirmed_seats = v_ok where id = h.id;
    perform public._tbl_ping(v_session);
    return jsonb_build_object('ok', true, 'status', 'pending', 'accepted', true);
  end if;

  -- 全部確認 ⇒ 一次入帳，就是當初提出的那一份
  update hands
     set score_delta = h.proposed_delta, confirmed_seats = v_ok,
         status = 'confirmed', confirmed_at = now()
   where id = h.id;
  if h.result <> 'kala' and (public._tbl_round_state(h.round_id) ->> 'finished')::boolean then
    update session_rounds set status = 'finished', finished_at = now() where id = h.round_id;
  end if;
  perform public._tbl_ping(v_session);
  return jsonb_build_object('ok', true, 'status', 'confirmed', 'accepted', true);
end $function$;


/* ── 驗證（結構；行為另跑 sql/checks/2026-09-25_驗自摸一家取消整局作廢.sql）
   🔴 不用 raise：這一份要留下東西（硬規則 1.8）── */
do $$
declare v_msg text := ''; v_def text; v_n int;
begin
  select count(*) into v_n from pg_proc where pronamespace = 'public'::regnamespace and proname = 'tbl_confirm_hand_tx';
  v_def := pg_get_functiondef('public.tbl_confirm_hand_tx(text,uuid,boolean)'::regprocedure);
  v_msg := case when v_n = 1 then '✅ ① 版本數 1' else '🔴 ① 版本數 ' || v_n end;
  v_msg := v_msg || E'\n' || case when v_def ~ 'set\s+score_delta\s*=\s*h\.proposed_delta'
    then '✅ ② 全部確認時一次入帳（proposed_delta）' else '🔴 ② 沒有一次入帳那一段' end;
  v_msg := v_msg || E'\n' || case when v_def ~ 'if\s+not\s+p_accept\s+then\s+update\s+hands'
    then '✅ ③ 任何取消直接作廢' else '🔴 ③ 取消沒有直接作廢' end;
  v_msg := v_msg || E'\n' || case when has_function_privilege('anon', 'public.tbl_confirm_hand_tx(text,uuid,boolean)', 'execute')
    then '✅ ④ 平板（anon）叫得動 —— 授權沒被動到' else '🔴 ④ 平板叫不動了' end;
  perform set_config('migi.v', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有訊息') as "驗證";
