/* ============================================================
   2026-11-06 · POS 包桌列表多回「最後一局打完的時間」
     使用者：「時間要顯示打完的時間，不能顯示收桌時間」
     例：11/4 23:07 開打的那一場，隔天 10:27 才收桌 —— 收桌常常比打完晚好幾個小時
   · 牌局紀錄彈窗不用改後端：pos_session_record_tx 的每一局本來就有時間（at），前端取最後一局
   · 這支（pos_list_private_sessions_tx）照 2026-11-06 線上版本重建，只多一個 last_hand_at
     ＝ 最後一局確認的時間（跟 _session_hands 的 at 同一個算法：coalesce(confirmed_at, created_at)）；沒記分就是 null，前端退回收桌時間
   · 簽名沒變 ⇒ create or replace，授權不會丟
   ============================================================ */

create or replace function public.pos_list_private_sessions_tx(p_store_id uuid, p_day date)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_org uuid;
begin
  perform public._api_staff_only();
  v_org := public.current_org_id();   -- 沒有 API 身分（SQL Editor）時是 null ⇒ 不限機構
  if p_store_id is null or p_day is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_args', 'message', '請先選門市與日期');
  end if;

  return jsonb_build_object('ok', true, 'list', coalesce((
    select jsonb_agg(jsonb_build_object(
             'session_id', ts.id, 'table_label', t.label, 'status', ts.status,
             'started_at', coalesce(ts.activated_at, ts.created_at), 'ended_at', ts.ended_at,
             -- 最後一局打完的時間（畫面顯示這個，不顯示收桌時間）
             'last_hand_at', (select max(coalesce(h.confirmed_at, h.created_at)) from hands h
                               where h.session_id = ts.id and h.status = 'confirmed' and h.undone_at is null),
             'hands', (select count(*) from hands h
                        where h.session_id = ts.id and h.status = 'confirmed' and h.undone_at is null
                          and h.result in ('ron', 'tsumo', 'draw', 'bao')),
             'players', coalesce((
               select jsonb_agg(jsonb_build_object('seat', sp.seat, 'name', m.display_name,
                                                   'rank', sp.finish_rank, 'final_score', sp.final_score)
                                order by sp.finish_rank nulls last, sp.seat)
                 from session_players sp join members m on m.id = sp.member_id
                where sp.session_id = ts.id), '[]'::jsonb))
           order by coalesce(ts.activated_at, ts.created_at))
      from table_sessions ts
      join stores s on s.id = ts.store_id
      left join tables t on t.id = ts.table_id
     where ts.store_id = p_store_id
       and (v_org is null or s.org_id = v_org)
       and ts.mode = 'private'
       and ts.status <> 'voided'
       and ts.deleted_at is null
       and (coalesce(ts.activated_at, ts.created_at) at time zone 'Asia/Taipei')::date = p_day), '[]'::jsonb));
end $function$;

/* ── 驗證（單一 SELECT）── */
select concat_ws(E'\n',
  case when has_function_privilege('authenticated', 'public.pos_list_private_sessions_tx(uuid, date)', 'execute')
        and not has_function_privilege('anon', 'public.pos_list_private_sessions_tx(uuid, date)', 'execute')
       then '✅ ① 授權照舊（登入的人叫得到、anon 叫不到）' else '🔴 ① 授權不對' end,
  /* 11-06 凌晨 A1 那一場：最後一局 07:35，收桌 10:33 —— 要回 07:35 */
  coalesce((
    select case when to_char((e->>'last_hand_at')::timestamptz at time zone 'Asia/Taipei', 'HH24:MI') = '07:35'
                then '✅ ② 11-06 凌晨 A1：最後一局 ' || to_char((e->>'last_hand_at')::timestamptz at time zone 'Asia/Taipei', 'HH24:MI')
                     || '（收桌 ' || to_char((e->>'ended_at')::timestamptz at time zone 'Asia/Taipei', 'HH24:MI') || '）'
                else '🔴 ② 最後一局時間不對：' || coalesce(e->>'last_hand_at', 'null') end
      from (select public.pos_list_private_sessions_tx(ts.store_id, date '2026-11-06') r
              from table_sessions ts where ts.id = '1fcb201f-92ed-460a-b727-11afe1b2554e') x,
           jsonb_array_elements(x.r->'list') e
     where e->>'session_id' = '1fcb201f-92ed-460a-b727-11afe1b2554e'), '🔴 ② 清單裡找不到那一場')
) as "驗證";
