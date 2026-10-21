/* ============================================================
   店員取消配桌房（2026-10-21 使用者：「這邊要能取消牌局」）
   ------------------------------------------------------------
   起因：POS 配桌列表上「四人已湊齊，這桌要手動開桌」的房只有「隨機開桌」「指定開桌」，沒有取消的路；
     原本的 pos_close_queue_tx 只關**沒有人報名**的房（它的註解寫著：有人報名的房要先有「通知報名者」才能關）。

   新增 pos_cancel_queue_tx(p_org_id, p_queue, p_reason)：
   · 可以取消：等人中（waiting）與已湊滿還沒帶到桌（matched）
   · 不能取消：已帶到桌（seated）⇒ 回 seated，請到桌上「取消開桌」（那邊才會處理場次與桌）
   · 已經取消／流局 ⇒ 冪等，回 ok ＋ already
   · 房裡每一位還在的人：
       ① 收到一則 App 通知（type = table_expired，內文寫「店家取消了 MM/DD HH:MM 的牌局（門市）」＋原因）
          使用者選「只發 App 通知」⇒ 不推 LINE（_push_enqueue 的白名單本來就只有 table_ok／settle）
       ② 標離開：leave_reason = 'cancelled'（CHECK 早就有這個值）、記下是哪位店員取消的
   · 房改成 cancelled
   ⚠ 固定牌局的這一場取消後不會被排程重新生出來（generate_recurring_instances_tx 只看「這個時間有沒有實例」，不看狀態）。
   ⚠ 新函式預設權限全關（硬規則 2.7）⇒ 下面明確 grant 給 authenticated；身分由函式自己問（_api_staff_only ＋ current_staff）。
   ============================================================ */

create or replace function public.pos_cancel_queue_tx(p_org_id uuid, p_queue uuid, p_reason text default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_staff uuid; v_status text; v_play_at timestamptz; v_store text;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_text text; v_n int;
begin
  -- 只有店員能叫；是哪位店員由登入身分解析，不收前端送的 id
  perform public._api_staff_only();
  select staff_id into v_staff from public.current_staff();
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff');
  end if;

  select q.status, q.play_at, s.name
    into v_status, v_play_at, v_store
    from match_queues q left join stores s on s.id = q.store_id
   where q.id = p_queue and q.org_id = p_org_id
     for update of q;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  if v_status in ('cancelled', 'expired') then
    return jsonb_build_object('ok', true, 'already', v_status);
  end if;
  -- 已經帶到桌：那一場有場次、佔著桌，要從桌上「取消開桌」處理
  if v_status = 'seated' then
    return jsonb_build_object('ok', false, 'reason', 'seated');
  end if;

  v_text := '店家取消了 '
         || coalesce(to_char(v_play_at at time zone 'Asia/Taipei', 'MM/DD HH24:MI') || ' 的牌局', '這場牌局')
         || coalesce('（' || v_store || '）', '')
         || coalesce('：' || v_reason, '');

  -- ① 先通知（之後就要標離開了，順序不能反）
  insert into app_notifications (org_id, member_id, type, payload, ref_id)
  select p_org_id, qp.member_id, 'table_expired',
         jsonb_build_object('text', v_text, 'queue_id', p_queue, 'play_at', v_play_at, 'cancelled_by_store', true),
         p_queue
    from match_queue_players qp
   where qp.queue_id = p_queue and qp.left_at is null;
  get diagnostics v_n = row_count;

  -- ② 房裡的人標離開，記下是哪位店員取消的
  update match_queue_players
     set left_at = now(), leave_reason = 'cancelled', leave_detail = v_reason, left_by_staff_id = v_staff
   where queue_id = p_queue and left_at is null;

  -- ③ 房取消
  update match_queues set status = 'cancelled', updated_at = now() where id = p_queue;

  return jsonb_build_object('ok', true, 'notified', v_n);
end $function$;

revoke execute on function public.pos_cancel_queue_tx(uuid, uuid, text) from public, anon;
grant  execute on function public.pos_cancel_queue_tx(uuid, uuid, text) to authenticated, service_role;


/* ── 驗證（單一 SELECT，不 raise）──────────────────────────── */
select
  (select case when count(*) = 1 then '✅ ① pos_cancel_queue_tx 建好了（1 個版本）' else '🔴 ① 版本數 ' || count(*) end
     from pg_proc where pronamespace = 'public'::regnamespace and proname = 'pos_cancel_queue_tx') || E'\n' ||
  (select case when has_function_privilege('authenticated', 'public.pos_cancel_queue_tx(uuid,uuid,text)', 'execute')
                and not has_function_privilege('anon', 'public.pos_cancel_queue_tx(uuid,uuid,text)', 'execute')
               then '✅ ② 登入的人叫得動、沒登入的叫不動' else '🔴 ② 授權不對' end) || E'\n' ||
  (select case when pg_get_functiondef('public.pos_cancel_queue_tx(uuid,uuid,text)'::regprocedure) ~ '_api_staff_only\(\)'
                and pg_get_functiondef('public.pos_cancel_queue_tx(uuid,uuid,text)'::regprocedure) ~ 'current_staff\(\)'
               then '✅ ③ 函式自己檢查店員身分' else '🔴 ③ 沒有身分檢查' end) || E'\n' ||
  (select case when pg_get_functiondef(p.oid) ~ 'in \(''table_ok'', ''settle''\)'
               then '✅ ④ LINE 推播白名單仍然只有成桌與牌局結束（取消通知只在 App）' else '⚠ ④ 推播白名單變了，確認取消通知會不會推到 LINE' end
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = '_push_enqueue')
  as "驗證";
