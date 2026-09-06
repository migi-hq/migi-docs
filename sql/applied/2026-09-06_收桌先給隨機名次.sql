/* ============================================================
   電子計分之前：按收桌就先給隨機名次
   2026-09-06 · MIGI 咪吉麻將 · 使用者指定

   ── 為什麼 ────────────────────────────────────────────
   M4 的電子計分還沒做，所以每一場打完之後
   `session_players.finish_rank` 永遠是 null
   ⇒ 會員 App 的每一列都停在「等待結算」，
     段位分不動、段位走勢圖是平的、排行榜與名人堂永遠空。
   → 那條路上的畫面**沒有辦法被驗證**（硬規則 3.85：畫出來才會發現）。

   ── 做法：走真的結算，只有名次是隨機的 ──────────────
   🔴 **不要自己 UPDATE `finish_rank`。** 那會塞出一個
     「有名次但段位分沒動、`rating_after` 是 null」的四不像 ——
     而畫面吃的是 `score_points` 與 `rating_after`。
   ✅ 呼叫既有的 `apply_session_rounds_tx`，隨機的只有那份 `p_rounds`。
     ⇒ 定位賽（第一場 +30/+15/+10/+5）、低段降階保護、
       `rating_after`、`members.rank`、賽季排名 **全部照真的規則跑**。

   ── 🔴 它要怎麼自己消失 ───────────────────────────────
   硬規則 5.7 記著：「開發用的旁路一旦存在就會忘記拿掉」。
   所以這一支**不靠人記得**：

       只有 `orgs.live_from` 還沒到（null 或未來）時才會給名次。

   ⇒ **上線那天設 `live_from` 的那一刻，它自動停止**，
     而那本來就是上線清單的第 ① 項（`docs/09-環境流程/上線當天要設的東西.md`）。
   📌 同待辦 37 的 `live` 旗標：把「要記得關掉」換成
     「一個一定會發生的動作順便關掉它」。

   ⚠ 停止之後 App 會回到「等待結算」——**那是對的**：
     真實客人的成績本來就要等 M4，而不是拿隨機數字騙他。
   ============================================================ */

/* ── ① 隨機名次（只在上線前有效）────────────────────── */
create or replace function public.placeholder_ranks_tx(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_org      uuid;
  v_rounds   int;
  v_n        int;
  v_live     timestamptz;
  v_payload  jsonb := '[]'::jsonb;
  i          int;
begin
  select ts.org_id, greatest(coalesce(ts.planned_rounds, 2), 2)
    into v_org, v_rounds
    from table_sessions ts
   where ts.id = p_session_id and ts.deleted_at is null;

  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found');
  end if;

  /* 🔴 **自動失效的那道閘門。** 上線之後就不再產生假名次。
     ⚠ 用 `>= now()` 判斷「還沒到」而不是只看 null ——
       上線日先填進去（排定未來某天）也應該還在測試狀態。 */
  select o.live_from into v_live from orgs o where o.id = v_org;
  if v_live is not null and v_live <= now() then
    return jsonb_build_object('ok', false, 'reason', 'already_live');
  end if;

  select count(*) into v_n
    from session_players sp where sp.session_id = p_session_id;

  /* `apply_session_rounds_tx` 硬性要求每一將剛好四個人（決策紀錄 ①）。
     ⚠ 不是四人就**安靜跳過**，不要報錯 —— 收桌不可以因為這個失敗。 */
  if v_n <> 4 then
    return jsonb_build_object('ok', false, 'reason', 'need_four_players', 'n', v_n);
  end if;

  /* 每一將各自洗一次牌：`order by random()` 給一個 1..4 的排列。
     ⚠ 一定要是**排列**不是四個獨立亂數 —— 後端會驗
       （`bad_ranks`），而兩個人同時第 1 名本來就不是名次。 */
  for i in 1 .. v_rounds loop
    v_payload := v_payload || jsonb_build_array((
      select jsonb_agg(jsonb_build_object(
               'member_id', x.member_id,
               'finish_rank', x.rn))
        from (select sp.member_id,
                     row_number() over (order by random()) as rn
                from session_players sp
               where sp.session_id = p_session_id) x
    ));
  end loop;

  return apply_session_rounds_tx(p_session_id, v_payload);
end $fn$;

/* 🔴 前端一律叫不動（硬規則 2.6／2.6b：兩個方向都要收）——
   它會改段位分，只該由 `settle_session_tx` 從內部呼叫。 */
revoke execute on function public.placeholder_ranks_tx(uuid) from public;
revoke execute on function public.placeholder_ranks_tx(uuid) from anon, authenticated;
grant  execute on function public.placeholder_ranks_tx(uuid) to service_role;

/* ── ② 收桌時順手叫它 ────────────────────────────────── */
do $mig$
declare
  v_def text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'settle_session_tx' and p.prokind = 'f';

  if v_def is null then raise exception '找不到 settle_session_tx'; end if;

  /* 插在「收完保留給現場」那一段之前。
     🔴 **包在自己的 exception 裡**：結算失敗不可以讓收桌整筆回滾 ——
       收桌是收錢那條路上的動作，名次只是附帶的。 */
  v_new := replace(v_def,
    '  -- ── 收完保留給現場 ─────────────────────────────────────',
    '  /* ⏳ 電子計分之前先給隨機名次（2026-09-06）。'                                 || chr(10) ||
    '     🔴 `orgs.live_from` 一到，`placeholder_ranks_tx` 自己會回'                  || chr(10) ||
    '       `already_live` 什麼都不做 —— **不需要有人記得移除這一段**。'              || chr(10) ||
    '     ⚠ 失敗一律吞掉：收桌不可以因為名次而回滾。 */'                              || chr(10) ||
    '  begin'                                                                          || chr(10) ||
    '    perform public.placeholder_ranks_tx(p_session_id);'                            || chr(10) ||
    '  exception when others then null;'                                                || chr(10) ||
    '  end;'                                                                            || chr(10) ||
    ''                                                                                  || chr(10) ||
    '  -- ── 收完保留給現場 ─────────────────────────────────────');

  if v_new = v_def then
    raise exception '🔴 沒有替換到 —— 線上的 settle_session_tx 跟預期不同，先撈出來看';
  end if;

  execute v_new;
end $mig$;

/* ── 驗證 ────────────────────────────────────────────────
   🎯 **樣本在交易內自己造**（硬規則 3.57）——
     借線上的場次會跟真實世界賽跑，而今天那張 A3 上還有人在打。
   🔴 整段最後 `raise` 回滾，一列都不會真的留下（沒有 staging，硬規則 5.7）。
   ⚠ 訊息一律設在 exception 處理器裡（硬規則 3.9）。 */
do $v$
declare
  v_org uuid; v_store uuid; v_tbl uuid;
  v_sid uuid; v_sid2 uuid;
  v_ids uuid[];
  v_r jsonb; v_r2 jsonb;
  v_ranks int[]; v_pts int;
  v_before int; v_after int;
  v_msg text := '';
begin
  select o.id into v_org from orgs o limit 1;
  select s.id into v_store from stores s
   where s.org_id = v_org and exists (select 1 from tables t where t.store_id = s.id)
   limit 1;

  /* 找一張現在沒有 open 場次的桌（`uq_sessions_open_table` 會擋）。 */
  select t.id into v_tbl from tables t
   where t.store_id = v_store and t.deleted_at is null
     and not exists (select 1 from table_sessions x
                      where x.table_id = t.id and x.status = 'open' and x.deleted_at is null)
   limit 1;

  select array_agg(m.id) into v_ids
    from (select id from members
           where org_id = v_org and deleted_at is null and is_test
           order by created_at limit 4) m;

  if v_tbl is null or coalesce(array_length(v_ids,1),0) <> 4 then
    v_msg := '🔴 ⓪ 造不出樣本（空桌 ' || coalesce(v_tbl::text,'無')
          || '／測試會員 ' || coalesce(array_length(v_ids,1),0) || ' 人）'
          || ' —— 這份驗證等於沒跑，不要當成通過';
      /* ⚠ 這裡**只設變數不設 config** —— `set_config(…, true)` 寫在 raise
       之前會跟著 savepoint 一起回滾，最後印出空白（硬規則 3.9）。 */
    raise exception 'migi_rollback';
  end if;

  select m.rating into v_before from members m where m.id = v_ids[1];

  -- 場次 ＋ 四位玩家
  insert into table_sessions (org_id, store_id, table_id, mode, planned_rounds, status)
  values (v_org, v_store, v_tbl, 'matched', 2, 'open') returning id into v_sid;
  insert into session_players (org_id, session_id, member_id)
  select v_org, v_sid, unnest(v_ids);

  -- ① 收桌 → 應該連名次一起有了
  v_r := settle_session_tx(v_sid, null, false);

  select array_agg(sp.finish_rank order by sp.finish_rank),
         max(sp.score_points)
    into v_ranks, v_pts
    from session_players sp where sp.session_id = v_sid;

  select m.rating into v_after from members m where m.id = v_ids[1];

  v_msg := case when (v_r ->> 'ok')::boolean then '✅ ① 收桌成功' else '🔴 ① 收桌失敗' end
        || E'\n② 名次 = ' || coalesce(v_ranks::text, '（沒有）')
        || case when v_ranks = array[1,2,3,4] then '　✅ 是 1..4 的排列'
                else '　🔴 不是排列' end
        || E'\n③ rating ' || v_before || ' → ' || v_after
        || case when v_after <> v_before then '　✅ 段位分真的動了（走的是真結算）'
                else '　🔴 沒動 —— 那就只是塞了個假欄位' end;

  -- ④ 🎯 冪等：再收一次不該重算
  v_r2 := settle_session_tx(v_sid, null, false);
  perform placeholder_ranks_tx(v_sid);
  v_msg := v_msg || E'\n④ 再收一次：'
        || case when (select count(distinct finish_rank) from session_players
                       where session_id = v_sid) = 4
                then '✅ 名次沒有被重算' else '🔴 名次變了' end;

  /* ⑤ 🎯 **反對照：上線之後就不該再給名次。**
     ⚠ 只驗「上線前會給」的話，一支**無條件**給名次的實作也會全綠 ——
       而那正是這一份最不能出錯的地方（硬規則 3.55）。 */
  update orgs set live_from = now() - interval '1 day' where id = v_org;

  select t.id into v_tbl from tables t
   where t.store_id = v_store and t.deleted_at is null
     and not exists (select 1 from table_sessions x
                      where x.table_id = t.id and x.status = 'open' and x.deleted_at is null)
   limit 1;
  insert into table_sessions (org_id, store_id, table_id, mode, planned_rounds, status)
  values (v_org, v_store, v_tbl, 'matched', 2, 'open') returning id into v_sid2;
  insert into session_players (org_id, session_id, member_id)
  select v_org, v_sid2, unnest(v_ids);
  perform settle_session_tx(v_sid2, null, false);

  v_msg := v_msg || E'\n⑤ 反對照（live_from 已到）：'
        || case when (select count(*) from session_players
                       where session_id = v_sid2 and finish_rank is not null) = 0
                then '✅ 沒有給名次（上線後自動失效）'
                else '🔴 還是給了 —— 那道閘門沒有作用' end;

  /* ⑥ 授權：anon 兩個來源都要是 false（硬規則 2.6b） */
  v_msg := v_msg || E'\n⑥ 授權：'
        || (select case when not exists (
                     select 1 from aclexplode(p.proacl) a
                      where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
                    and not exists (
                     select 1 from aclexplode(p.proacl) a
                      where a.grantee = 0 and a.privilege_type = 'EXECUTE')
                   then '✅ anon 沒有明確授權，PUBLIC 也沒有'
                   else '🔴 前端叫得動 —— 它會改段位分' end
              from pg_proc p
             where p.pronamespace = 'public'::regnamespace
               and p.proname = 'placeholder_ranks_tx');

  /* 🔴 **訊息一律在 exception 處理器裡設**（硬規則 3.9）。
     plpgsql 的變數不受回滾影響，`set_config` 受 —— 所以先存進 v_msg，
     等進了處理器再設。寫在 raise 之前的話這一整份會印出空白。 */
  raise exception 'migi_rollback';

exception when others then
  perform set_config('migi.v',
    v_msg || case when sqlerrm = 'migi_rollback' then ''
                  else E'
🔴 驗證途中拋錯：' || sqlerrm end, true);
end $v$;

select current_setting('migi.v', true) as 驗證結果;
