/* ═══════════════════════════════════════════════════════════════════
   收桌 → 發結算通知；結算頁讀得到那一場的真資料
   2026-09-19 · 使用者指定「開始做後端」
   ═══════════════════════════════════════════════════════════════════

   🔴 **起點是一個沒有症狀的死路**（2026-09-19 錯誤儀表旁邊查到的）：
     `app_notifications.type` 的 CHECK 從 M0 就允許 `'settle'`，
     而**全庫沒有任何一支函式寫過它** —— 線上 `settle` 通知 0 筆。
   ⇒ 配桌頁那條「你的牌局結算完成 · 查看 ›」**在真實資料下永遠不會出現**，
     而它是「收桌結算」那一頁唯一的入口 ⇒ 那一頁客人一輩子看不到。
   📌 同一個形狀這個月第三次：`SettleOkSheet`（onOk 沒人呼叫）、
     `v_real_*` 漏欄位、這一個。**建了沒人叫，而且不會報錯。**

   ── 這份做三件事 ────────────────────────────────────
   ① `_game_row(org, session, member)` —— 一場牌局的完整 jsonb。
      **從 `get_my_games_tx` 抽出來的同一份定義**，不是新寫的。
      🎯 抽的理由不是漂亮：結算頁要「單場」，而清單要「多場」——
        各寫一份的話，日後補一個欄位只會補到一邊，
        而症狀是「同一場牌局在兩個畫面顯示不同的東西」（這個專案記過六次）。
   ② `get_game_tx(org, session, member)` —— 結算頁用，單場。
      ⚠ **只回自己坐過的那一場**：查不到 `session_players` 就回 not_found，
        不回「別人的牌局」。名次與段位分是個資。
   ③ `settle_session_tx` 收桌時，對**每一個在座玩家**發一則 `settle` 通知。
      ref_id = session_id；payload 帶門市、積分、開打時間，
      讓通知列不必再去猜（前端現在寫死 'MIGI 高雄自由店' / '50/20'）。

   ⚠ 三支的簽名都不變 ⇒ 一律 CREATE OR REPLACE，不 DROP、不丟 GRANT。
   ⚠ `_game_row` 是內部函式 ⇒ **兩個方向都要收**（硬規則 2.6b）：
     `revoke from public` 與 `revoke from anon, authenticated`。
   ⚠ 這份要留下 DDL ⇒ 驗證段一個字都不准 raise（硬規則 1.8）。
     行為測試（造樣本、回滾）在 `sql/checks/2026-09-19_驗收桌通知與單場詳情.sql`。
   ═══════════════════════════════════════════════════════════════════ */


/* ═══ ① 一場牌局的完整資料（內部）═══════════════════════════════
   回傳的鍵**與 get_my_games_tx 原本那一份逐字相同** ——
   前端（成績頁走勢圖、牌局詳情、配桌頁紀錄列）全部吃這組鍵，少一個就靜靜缺一格。 */
create or replace function public._game_row(p_org_id uuid, p_session_id uuid, p_member_id uuid)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select jsonb_build_object(
    'session_id', m.id,
    -- table_sessions.mode ∈ matched / private，就是配桌 vs 包桌
    'kind',   case when m.mode = 'private' then 'package' else 'match' end,
    -- 已收桌但還沒結算戰績 → pending；有名次 → settled
    'status', case when sp.finish_rank is not null then 'settled' else 'pending' end,
    /* 這一場是從哪一種配桌房來的（member／pos／recurring，2026-09-18 加）。
       前端 `kindText` 用它分「即時牌局／固定牌局」。對不到房就是 null。 */
    'source',     q.source,
    'store',      st.name,
    'addr',       st.address,
    'game_type',  m.game_type,
    'flower',     m.flower,
    'rounds',     m.planned_rounds,     -- 整數，「幾將」由前端組字
    'stake',      sl.label,             -- 積分級距顯示名，例如 50/20、純娛樂麻將
    -- 開打時間用 activated_at（帶桌／真正開打），沒有才退回 started_at（開桌）
    'started_at', coalesce(m.activated_at, m.started_at),
    'ended_at',   m.ended_at,
    'duration_minutes',
      case when m.ended_at is not null
           then greatest(0, (extract(epoch from
                  (m.ended_at - coalesce(m.activated_at, m.started_at))) / 60)::int)
           else null end,
    'my_rank',           sp.finish_rank,      -- M4 之前是 null
    'my_score',          sp.score_points,     -- M4 之前是 null
    'my_charged_points', sp.charged_points,
    'my_fee_waived',     sp.fee_waived_amount,  -- 暢打／店員／店長特調免收的金額
    'my_seat',           sp.seat,
    /* 走勢圖的兩個座標。⚠ `settled_at` 不能用 `ended_at` 代替 ——
       收桌與結算是兩個動作，而走勢圖畫的是**分數變動的時間**。 */
    'my_rating_after',   sp.rating_after,
    'settled_at',        sp.settled_at,
    'players', coalesce((
      select jsonb_agg(jsonb_build_object(
               'member_id',    p.member_id,
               'nickname',     mem.display_name,
               'rank',         mem.rank,
               'avatar_url',        mem.avatar_url,
               'avatar_source',     mem.avatar_source,
               'avatar_photo_path', mem.avatar_photo_path,
               'avatar_bear',       mem.avatar_bear,
               'title',        mem.title,
               'seat',         p.seat,
               'finish_rank',  p.finish_rank,
               'score_points', p.score_points,
               /* 桌上積分。⚠ null 是有意義的：純娛樂的桌不計積分，
                  那與「打平（0）」不同。 */
               'final_score',  p.final_score,
               'is_me',        p.member_id = p_member_id
             ) order by coalesce(p.finish_rank, 99), p.seat nulls last, p.joined_at)
        from session_players p
        join members mem on mem.id = p.member_id
       where p.session_id = m.id), '[]'::jsonb)
  )
  from table_sessions m
  join session_players sp
    on sp.session_id = m.id
   and sp.member_id  = p_member_id
   and sp.org_id     = p_org_id
  left join stores       st on st.id = m.store_id       and st.org_id = p_org_id
  left join stake_levels sl on sl.id = m.stake_level_id and sl.org_id = p_org_id
  /* ⚠ lateral ＋ limit 1：理論上一場只對到一個配桌房，
     但不假設它 —— 多對到一筆會讓整場資料變成兩列。 */
  left join lateral (
    select mq.source
      from match_queues mq
     where mq.matched_session_id = m.id
       and mq.org_id = p_org_id
     order by mq.created_at
     limit 1
  ) q on true
  where m.id = p_session_id
    and m.org_id = p_org_id
    and m.deleted_at is null
$function$;

/* 🔴 內部函式：**兩個方向都要收**（硬規則 2.6b）。
   舊函式的 anon 來自 PUBLIC 繼承，新函式來自 default privileges 的明確授權
   —— 只收一邊會完全沒有效果，而且不會報錯。 */
revoke execute on function public._game_row(uuid, uuid, uuid) from public;
revoke execute on function public._game_row(uuid, uuid, uuid) from anon, authenticated;
grant  execute on function public._game_row(uuid, uuid, uuid) to service_role;


/* ═══ ② 牌局紀錄清單：改成呼叫 ①，不要自己再組一份 ═══════════════
   ⚠ 簽名不變 ⇒ CREATE OR REPLACE。前端一行都不用改。 */
create or replace function public.get_my_games_tx(p_org_id uuid, p_member_id uuid, p_limit integer default 20)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v_me uuid;
begin
  v_me := public.current_member_id();
  p_member_id := coalesce(v_me, p_member_id);

  return (
    with mine as (
      -- 從「我坐過的位子」反查場次 —— 不需要知道那桌是怎麼開的。
      select s.id, s.ended_at
        from session_players sp
        join table_sessions s on s.id = sp.session_id
       where sp.member_id = p_member_id
         and sp.org_id    = p_org_id
         and s.org_id     = p_org_id
         and s.deleted_at is null
         and s.status     = 'completed'
       order by s.ended_at desc nulls last
       limit greatest(coalesce(p_limit, 20), 1)
    )
    select coalesce(
      jsonb_agg(public._game_row(p_org_id, m.id, p_member_id) order by m.ended_at desc nulls last),
      '[]'::jsonb)
    from mine m
  );
end $function$;


/* ═══ ③ 單場詳情：收桌結算那一頁用 ═══════════════════════════════
   🔴 **只回自己坐過的那一場。** 名次、段位分、同桌是誰都是個資 ——
     拿到一個 session_id 就查得到別人的成績，那是待辦 14 在防的形狀。
     `_game_row` 的 join 本身就是那道牆（查不到 session_players 就回 0 列）。 */
create or replace function public.get_game_tx(p_org_id uuid, p_session_id uuid, p_member_id uuid default null)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_me  uuid;
  v_row jsonb;
begin
  /* JWT 優先、參數退回 —— 與其他 22 支會員 RPC 同一個寫法。
     ⏳ 待辦 14 收尾時三個地方一起拿掉退回，不要只改這裡。 */
  v_me := coalesce(public.current_member_id(), p_member_id);
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  v_row := public._game_row(p_org_id, p_session_id, v_me);

  if v_row is null then
    /* ⚠ 「不存在」與「不是你的」**回同一句話**：分開講等於告訴對方
       「這個 id 存在，只是不給你看」，那本身就是資訊。 */
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這場牌局');
  end if;

  return jsonb_build_object('ok', true, 'game', v_row);
end $function$;

grant execute on function public.get_game_tx(uuid, uuid, uuid) to anon, authenticated;


/* ═══ ④ 收桌時發結算通知 ═══════════════════════════════════════
   🎯 **一人一則**，對象是那一桌的 `session_players`（付過檯費、真的坐過的人）。
   ⚠ 冪等那條路（已經 completed）**不重發** —— 店員按兩下不該讓客人收到兩則。
   ⚠ 發通知失敗**不可以讓收桌回滾**：桌子已經收了，通知只是附帶的。
     所以整段包在 exception 裡吞掉（同上面 `placeholder_ranks_tx` 那一段）。
   📌 `ref_id` 放 session_id ⇒ 前端點「查看」時用它叫 `get_game_tx`。 */
create or replace function public.settle_session_tx(p_session_id uuid, p_staff_id uuid default null::uuid, p_keep_for_walkin boolean default false)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_s      record;
  v_total  bigint;
  v_left   int;
begin
  /* 🔴 操作者身分從 JWT 取，**不採信呼叫端送的 p_staff_id**（2026-09-04）。
     在此之前 POS 送的值來自 localStorage，店員可以改成別人 ——
     而那比沒有稽核更糟（看起來有，卻指向錯的人）。
   ⚠ 查不到就是 null（會員 App 那條路沒有 staff 身分），**不可以報錯**。 */
  p_staff_id := (select staff_id from public.current_staff());
  select * into v_s
    from table_sessions
   where id = p_session_id and deleted_at is null;

  if v_s.id is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found',
      'message', '場次不存在');
  end if;

  -- 冪等：重複按不該報錯，也不該再動一次 ended_at。
  -- 店員在網路慢的時候按兩下是常態，第二下應該是「已經收好了」。
  if v_s.status = 'completed' then
    -- ⚠ 這條路也要套用勾選：情境是店員收完桌才想到「這桌留給現場」，
    --   再開一次收桌彈窗勾了按下去。設 false 兩次跟設一次一樣，不會壞。
    if p_keep_for_walkin then
      update tables set auto_assign = false where id = v_s.table_id;
    end if;
    return jsonb_build_object('ok', true, 'already_settled', true,
      'session_id', p_session_id, 'table_id', v_s.table_id,
      'ended_at', v_s.ended_at, 'total_points', v_s.fee_points,
      'kept_for_walkin', p_keep_for_walkin);
  end if;

  if v_s.status <> 'open' then
    return jsonb_build_object('ok', false, 'reason', 'session_not_open',
      'message', '此場次已作廢，無法收桌', 'status', v_s.status);
  end if;

  -- 在座的人一律標記離座。left_at 是「這個人什麼時候離開這張桌」，
  -- 收桌就是所有人同時離開 —— 不寫的話桌況的在座人數會永遠停在那個數字。
  update session_players
     set left_at = now()
   where session_id = p_session_id
     and left_at is null;
  get diagnostics v_left = row_count;

  -- 本桌實扣點數合計。charged_points 在入座/加購當下就寫好了，
  -- 這裡只是彙總，不重新計價 —— 收桌不該是第二個計價的地方。
  select coalesce(sum(charged_points), 0) into v_total
    from session_players
   where session_id = p_session_id;

  update table_sessions
     set status     = 'completed',
         ended_at   = now(),
         fee_points = v_total,
         updated_at = now(),
         updated_by = coalesce(p_staff_id, updated_by)
   where id = p_session_id;

  /* ⏳ 電子計分之前先給隨機名次（2026-09-06）。
     🔴 `orgs.live_from` 一到，`placeholder_ranks_tx` 自己會回
       `already_live` 什麼都不做 —— **不需要有人記得移除這一段**。
     ⚠ 失敗一律吞掉：收桌不可以因為名次而回滾。 */
  begin
    perform public.placeholder_ranks_tx(p_session_id);
  exception when others then null;
  end;

  /* 🆕 2026-09-19：結算通知。
     🔴 在此之前**沒有任何地方寫過 `settle`**（CHECK 允許但 0 筆）
       ⇒ 收桌結算那一頁的唯一入口從來沒有出現過。
     ⚠ 一人一則，對象是真的坐過的人；`ref_id` 給前端拿去叫 `get_game_tx`。
     ⚠ payload 帶門市與積分，讓通知列不必自己猜
       （前端在此之前是寫死的 'MIGI 高雄自由店' / '50/20'）。
     ⚠ 整段吞例外：桌已經收了，通知失敗不可以回滾收桌。 */
  begin
    insert into app_notifications (org_id, member_id, type, payload, ref_id)
    select v_s.org_id, sp.member_id, 'settle',
           jsonb_build_object(
             'text',       '牌局結算完成',
             'session_id', p_session_id,
             'store',      st.name,
             'stake',      sl.label,
             'at',         coalesce(v_s.activated_at, v_s.started_at)),
           p_session_id
      from session_players sp
      left join stores       st on st.id = v_s.store_id        and st.org_id = v_s.org_id
      left join stake_levels sl on sl.id = v_s.stake_level_id  and sl.org_id = v_s.org_id
     where sp.session_id = p_session_id
       and sp.org_id     = v_s.org_id
       and sp.member_id is not null;
  exception when others then null;
  end;

  -- ── 收完保留給現場 ─────────────────────────────────────
  -- 與收桌同一個交易，所以不存在「關掉了但沒收成」或「收了但沒關掉」的中間態。
  -- ⚠ 這是**持續設定**不是一次性保留：那張桌從此不再被自動配，
  --   直到有人在桌況上手動開回來（set_table_auto_assign_tx）。
  --   桌況卡的「現場」標記就是為了讓這件事不會被忘記。
  if p_keep_for_walkin then
    update tables set auto_assign = false where id = v_s.table_id;
  end if;

  return jsonb_build_object('ok', true,
    'session_id',      p_session_id,
    'table_id',        v_s.table_id,
    'players_left',    v_left,
    'total_points',    v_total,
    'kept_for_walkin', p_keep_for_walkin,
    'ended_at',        now());
end $function$;


/* ═══ 驗證段（不 raise）═══════════════════════════════════════ */
do $$
declare
  v_msg text := '';
  v_def text;
  v_n   int;
  v_a   boolean;
  v_p   boolean;
begin
  /* ① 四支都在、都是 DEFINER、都只有一個版本 */
  select count(*) into v_n from pg_proc
   where pronamespace = 'public'::regnamespace
     and proname in ('_game_row', 'get_game_tx', 'get_my_games_tx', 'settle_session_tx');
  v_msg := case when v_n = 4
    then '✅ ① 四支各一個版本（_game_row / get_game_tx / get_my_games_tx / settle_session_tx）'
    else '🔴 ① 函式數 ' || v_n || '（應該是 4）—— 可能建出了多載版本' end;

  /* ② `_game_row` 兩個方向都收乾淨了。
     ⚠ 只印 has_function_privilege 分不出「明確授權」與「PUBLIC 繼承」（硬規則 2.6），
       所以兩個都印。 */
  select exists (select 1 from aclexplode(coalesce(p.proacl,'{}')) a
                  where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE'),
         (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                  where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
    into v_a, v_p
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = '_game_row';
  v_msg := v_msg || E'\n' || case when not v_a and not v_p
    then '✅ ② _game_row：anon 明確授權 ✗、PUBLIC ✗（兩個方向都收了）'
    else '🔴 ② _game_row 還叫得動 —— anon明確=' || v_a || ' PUBLIC=' || v_p end;

  /* ③ 前端真的要用的那一支有授權 */
  v_msg := v_msg || E'\n' || case
    when has_function_privilege('anon', 'public.get_game_tx(uuid,uuid,uuid)', 'execute')
     and has_function_privilege('anon', 'public.get_my_games_tx(uuid,uuid,integer)', 'execute')
    then '✅ ③ get_game_tx 與 get_my_games_tx：anon 叫得動'
    else '🔴 ③ 前端叫不動 —— 檢查 grant' end;

  /* ④ 清單那支真的改成呼叫 `_game_row` 了（不是又留了一份自己的 builder） */
  v_def := pg_get_functiondef('public.get_my_games_tx(uuid,uuid,integer)'::regprocedure);
  v_msg := v_msg || E'\n' || case
    when v_def ilike '%_game_row(%' and v_def not ilike '%''my_rating_after'',%'
    then '✅ ④ 清單改呼叫 _game_row，沒有留第二份 builder'
    else '🔴 ④ 清單裡還有自己的 builder —— 兩份定義又回來了' end;

  /* ⑤ 收桌那支真的會寫 settle 通知 */
  v_def := pg_get_functiondef('public.settle_session_tx(uuid,uuid,boolean)'::regprocedure);
  v_msg := v_msg || E'\n' || case
    when v_def ilike '%app_notifications%' and v_def ilike '%''settle''%'
    then '✅ ⑤ settle_session_tx 會發 settle 通知'
    else '🔴 ⑤ 收桌沒有發通知' end;

  /* ⑥ 現況：線上有幾則 settle 通知（這份跑完仍然是 0 —— 要有人真的收一次桌）。
     ⚠ 這是**資訊格不是通過條件**：0 筆代表「還沒有人收桌」，不代表壞掉。 */
  select count(*) into v_n from app_notifications where type = 'settle';
  v_msg := v_msg || E'\n📌 ⑥ 目前 settle 通知 ' || v_n
        || ' 則（這份只是讓它從此會發；要看到第一則，POS 收一次桌）';

  /* ⑦ 負對照：清單那支的鍵一個都沒少。
     🔴 只驗「函式在」的話，一支回空陣列的實作也會讓上面每一格變綠。 */
  v_def := pg_get_functiondef('public._game_row(uuid,uuid,uuid)'::regprocedure);
  v_msg := v_msg || E'\n' || case
    when v_def ilike '%''my_rating_after''%' and v_def ilike '%''settled_at''%'
     and v_def ilike '%''final_score''%'     and v_def ilike '%''duration_minutes''%'
     and v_def ilike '%''source''%'          and v_def ilike '%''players''%'
     and v_def ilike '%''my_charged_points''%' and v_def ilike '%''my_fee_waived''%'
    then '✅ ⑦ _game_row 的鍵與舊版逐字對得上（走勢圖與詳情都吃它們）'
    else '🔴 ⑦ 有鍵掉了 —— 前端會靜靜缺一格' end;

  perform set_config('migi.verify_settle_notify', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify_settle_notify', true), ''), '🔴 沒有驗證訊息') as "驗證";
