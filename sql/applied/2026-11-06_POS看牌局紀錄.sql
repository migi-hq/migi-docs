/* ============================================================
   2026-11-06 · POS 看得到收桌之後的牌局紀錄
     使用者：「POS 看得到牌局紀錄嗎」→ 看不到（收桌後 POS 沒有任何入口）→「照妳建議做」
     POS 配桌列表「已收桌」的卡片多一顆「牌局紀錄」，點開：四個人的名次、桌上積分、段位分變動 ＋ 每一局

   ── 這支回什麼 ──
   pos_session_record_tx(場次 id) →
     { ok, session: { table_label, mode, game_type, flower, planned_rounds, stake_label, hygiene, started_at, ended_at },
       players: [ { seat, name, rank, final_score, rating_delta, rating_after } ]（照座位排）,
       hands: 每一局,
       unfinished_rounds: [沒打完的將] —— 那幾將的局有記、但不算進桌上積分（收桌只結算打完的將） }
   · 每一局沿用 _session_hands（會員 App 牌局回放那一份），不另外寫一份
   · 段位分變動讀 session_players.score_points —— 跟平板「牌局結束」卡（_tbl_state_for_device 的 rating_delta）同一個來源
     ⚠ CLAUDE.md 記過 score_points 名字說的是 score、裝的是段位分；這裡只是跟平板用同一份，日後正名時兩處一起改
   · 只有店員叫得到（_api_staff_only ＋ current_staff），而且只看得到自己機構的場次
   · 前端叫得到 ⇒ 明確 grant 給 authenticated（硬規則 2.7）
   ============================================================ */

create or replace function public.pos_session_record_tx(p_session_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_org uuid;
  s     record;
begin
  /* 從 API 進來（前端）⇒ 一定要是店員（_api_staff_only），而且只看自己機構的場次。
     沒有 API 身分（SQL Editor、排程、別的函式在內部叫）⇒ _api_staff_only 放行，v_org 是 null ⇒ 不限機構。
     ⚠ 不可以「查不到店員就 raise」—— 那會讓驗證段在 SQL Editor 裡拋錯、整份回滾（硬規則 1.8） */
  perform public._api_staff_only();
  v_org := public.current_org_id();   -- ⚠ current_staff() 沒有回 org_id（staff_id／member_id／store_id／role／name），第一版寫錯過

  select ts.*, t.label as table_label, sl.label as stake_label, coalesce(sl.is_hygiene, false) as hygiene
    into s
    from table_sessions ts
    left join tables t on t.id = ts.table_id
    left join stake_levels sl on sl.id = ts.stake_level_id
   where ts.id = p_session_id and (v_org is null or ts.org_id = v_org) and ts.deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這一場');
  end if;

  return jsonb_build_object('ok', true,
    'session', jsonb_build_object(
      'table_label', s.table_label, 'mode', s.mode, 'game_type', s.game_type, 'flower', s.flower,
      'planned_rounds', s.planned_rounds, 'stake_label', s.stake_label, 'hygiene', s.hygiene,
      'started_at', coalesce(s.activated_at, s.started_at), 'ended_at', s.ended_at, 'status', s.status),
    'players', coalesce((
      select jsonb_agg(jsonb_build_object(
               'seat', sp.seat, 'name', m.display_name, 'rank', sp.finish_rank,
               'final_score', sp.final_score, 'rating_delta', sp.score_points, 'rating_after', sp.rating_after)
             order by sp.seat nulls last, sp.joined_at)
        from session_players sp join members m on m.id = sp.member_id
       where sp.session_id = p_session_id), '[]'::jsonb),
    'hands', public._session_hands(p_session_id),
    /* 沒打完的將：收桌時只結算打完的將（2026-10-01 規則），這幾將裡的局有記在計分板上、但不算進桌上積分
       ⇒ 畫面要標出來，不然店員自己加總會對不上 */
    'unfinished_rounds', coalesce((
      select jsonb_agg(r.round_no order by r.round_no) from session_rounds r
       where r.session_id = p_session_id and r.status <> 'finished'), '[]'::jsonb));
end $function$;

revoke execute on function public.pos_session_record_tx(uuid) from public, anon;
grant  execute on function public.pos_session_record_tx(uuid) to authenticated;

/* ── 驗證（單一 SELECT）── */
select concat_ws(E'\n',
  case when to_regprocedure('public.pos_session_record_tx(uuid)') is not null
       then '✅ ① pos_session_record_tx 建好了' else '🔴 ① 不存在' end,
  case when has_function_privilege('authenticated', 'public.pos_session_record_tx(uuid)', 'execute')
        and not exists (select 1 from aclexplode(coalesce((select proacl from pg_proc where oid = 'public.pos_session_record_tx(uuid)'::regprocedure), '{}')) a
                         where a.grantee in (0, 'anon'::regrole::oid) and a.privilege_type = 'EXECUTE')
       then '✅ ② 登入的人叫得到、anon 與 PUBLIC 叫不到（函式裡再擋非店員）' else '🔴 ② 授權不對' end,
  /* 正對照：拿最近一場收過桌、有局數的場次，以「沒有 API 身分」的方式（SQL Editor）直接叫 —— 內容要湊得起來 */
  coalesce((
    select case when (r->>'ok')::boolean and jsonb_array_length(r->'players') between 1 and 4 and jsonb_array_length(r->'hands') = x.n
                then '✅ ③ 試讀最近一場（' || coalesce(r#>>'{session,table_label}', '?') || '）：' || jsonb_array_length(r->'players') || ' 人、' || x.n || ' 局，跟資料表數的一樣'
                else '🔴 ③ 讀出來對不上：' || left(r::text, 200) end
      from (select ts.id, (select count(*) from hands h where h.session_id = ts.id and h.status = 'confirmed' and h.undone_at is null) n
              from table_sessions ts
             where ts.status = 'completed' and ts.deleted_at is null
               and exists (select 1 from hands h where h.session_id = ts.id and h.status = 'confirmed')
             order by ts.ended_at desc limit 1) x,
           lateral (select public.pos_session_record_tx(x.id) r) y), '⚪ ③ 找不到有局數的已收桌場次，這一格測不了')
) as "驗證";
