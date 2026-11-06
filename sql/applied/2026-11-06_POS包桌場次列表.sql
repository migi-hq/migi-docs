/* ============================================================
   2026-11-06 · POS 看得到包桌場次（使用者：「讓 POS 也能看到包桌列表」）
     包桌不在配桌列表裡 ⇒ 收桌之後 POS 完全看不到（例：11-06 凌晨 A1 那一局）。
     放在 POS「包桌預約」那一頁（本來就一次看一天）：預約清單下面多一段「這一天的包桌」，
     每一場可以點「牌局紀錄 ›」（同配桌卡片，叫 pos_session_record_tx）。

   pos_list_private_sessions_tx(門市, 日期) →
     { ok, list: [ { session_id, table_label, status, started_at, ended_at, hands,
                     players: [ { seat, name, rank, final_score } ] } ] }
   · 「這一天」看開打時間（沒開打看開桌時間）的台北日曆日 —— 凌晨開打的算那一天
   · 有預約帶到桌的、現場直接開的都列（就是 table_sessions.mode = 'private'）；取消開桌（voided）的不列
   · hands ＝ 智慧計分板記了幾局（咔啦碰、分紅不算一局，同 _member_hand_counts）
   · 只有店員叫得到（_api_staff_only），而且只看自己機構的門市（current_org_id）
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

revoke execute on function public.pos_list_private_sessions_tx(uuid, date) from public, anon;
grant  execute on function public.pos_list_private_sessions_tx(uuid, date) to authenticated;

/* ── 驗證（單一 SELECT）── */
select concat_ws(E'\n',
  case when to_regprocedure('public.pos_list_private_sessions_tx(uuid, date)') is not null
       then '✅ ① pos_list_private_sessions_tx 建好了' else '🔴 ① 不存在' end,
  case when has_function_privilege('authenticated', 'public.pos_list_private_sessions_tx(uuid, date)', 'execute')
        and not exists (select 1 from aclexplode(coalesce((select proacl from pg_proc where oid = 'public.pos_list_private_sessions_tx(uuid, date)'::regprocedure), '{}')) a
                         where a.grantee in (0, 'anon'::regrole::oid) and a.privilege_type = 'EXECUTE')
       then '✅ ② 登入的人叫得到、anon 與 PUBLIC 叫不到（函式裡再擋非店員）' else '🔴 ② 授權不對' end,
  /* 正對照：11-06 凌晨 A1 那一場包桌（02:44 開打、4 人、98 局）要在 11-06 那一天的清單裡 */
  coalesce((
    select case when exists (select 1 from jsonb_array_elements(r->'list') e
                              where e->>'session_id' = '1fcb201f-92ed-460a-b727-11afe1b2554e'
                                and jsonb_array_length(e->'players') = 4 and (e->>'hands')::int = 98)
                then '✅ ③ 11-06 凌晨 A1 那一場包桌在清單裡（4 人、98 局）；那天共 ' || jsonb_array_length(r->'list') || ' 場包桌'
                else '🔴 ③ 清單裡找不到那一場：' || left(r::text, 300) end
      from (select public.pos_list_private_sessions_tx(ts.store_id, date '2026-11-06') r
              from table_sessions ts where ts.id = '1fcb201f-92ed-460a-b727-11afe1b2554e') x), '⚪ ③ 找不到那一場，這一格測不了')
) as "驗證";
