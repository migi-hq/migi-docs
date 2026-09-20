-- ============================================================
-- 收桌發成就事件（2026-09-20）—— 成就系統第 ③ 步
--   `settle_session_tx` 一支要發 4 個事件，而其中 3 個要判斷條件。
--
-- 📄 契約 `docs/03-會員App與社交/成就事件對照表_階段1.md` §1
-- 📄 引擎 `sql/applied/2026-09-20_成就系統核心RPC.sql`／`…_成就meta判定.sql`
--
-- | 事件 | 對誰發 | 判準（查證過，不是猜的） |
-- |---|---|---|
-- | `session_finished`     | 每一個坐過的人 | `session_players` 每一列都是結帳成功後才建立的 |
-- | `session_won`          | `final_score > 0` | 🔴 **不是名次**（CLAUDE.md：第 2 名照樣可能是負的） |
-- | `queue_session_done`   | 全桌 | `table_sessions.mode = 'matched'`（值域只有 matched／private） |
-- | `booking_session_done` | 全桌 | `bookings.seated_session_id = 這一場` |
--
-- ============================================================
-- 🔴 三件動手前查證到的事
-- ============================================================
--
-- ### ① 順序：一定要在 `placeholder_ranks_tx` **之後**
-- `session_won` 的判準是 `final_score`，而那一欄是 `placeholder_ranks_tx`
-- 在這一支裡面寫的。發在它前面的話 `final_score` 還是 null
-- ⇒ **`session_won` 永遠不會發**，而且不報錯。
--
-- ### ② `table_sessions` **沒有任何 booking 欄位**
-- 包桌的關聯是**反方向**的：`bookings.seated_session_id` 指過來。
-- （POS 的「帶到桌」只標記預約並記下桌號，檯費仍走開桌設定 → 結帳
--   ⇒ 場次那一側根本不知道自己來自一張預約單。）
--
-- ### ③ 整段吞例外，跟既有那兩塊同一個形狀
-- 這支是**收桌**。`placeholder_ranks_tx` 與結算通知都已經是
-- `begin … exception when others then null; end;`，成就照抄 ——
-- 🔴 **桌已經收了，成就失敗不可以回滾收桌。**
--
-- ⚠ 已知代價：`fire_event_tx` 收尾會叫 `ach_meta_tx`，所以
--   4 人 × 最多 4 個事件 = 最多 16 次對帳。今天 meta 只有 1 枚而且
--   `ach_meta_tx` 對「已解鎖」的 meta 會直接跳過計數 ⇒ 幾乎免費。
--   **300 枚全上之後要回來量一次**，不要現在先優化。
--
-- ⚠ 簽名不變 ⇒ `CREATE OR REPLACE`，不用 DROP、GRANT 不會掉（硬規則 2）。
-- ⚠ 這份要留下函式 ⇒ 驗證段一個字都不准 raise（硬規則 1.8）。
--   行為測試另一份：`sql/checks/2026-09-20_驗收桌發成就事件.sql`
-- ============================================================

create or replace function public.settle_session_tx(
  p_session_id uuid,
  p_staff_id uuid default null::uuid,
  p_keep_for_walkin boolean default false
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_s        record;
  v_total    bigint;
  v_left     int;
  v_booking  boolean := false;   -- 🆕 這一場是不是來自一張包桌預約
  v_p        record;             -- 🆕 發成就事件用
  v_idem     text;
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
    -- 🎯 成就事件**不在這條路重發**：`fire_event_tx` 本身對 specific 型
    --   是冪等的（已解鎖回 already），但累積型會被多加一次。
    --   而「已經收好了」本來就不該是第二次收桌。
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
     ⚠ 失敗一律吞掉：收桌不可以因為名次而回滾。
     🔴 **成就事件一定要排在這之後** —— `session_won` 看的是
       `final_score`，而那一欄就是這一步寫的。 */
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

  /* 🆕 2026-09-20：成就事件（第 ③ 步）。
     📄 契約見《成就事件對照表_階段1》§1。
     ⚠ 整段吞例外，理由同上面兩塊：**桌已經收了，成就失敗不可以回滾收桌**。
     ⚠ 冪等鍵用 `settle:<session_id>` —— `fire_event_tx` 會再串上事件名與
       成就代碼，所以同一場不會把同一枚重複計。 */
  begin
    v_idem := 'settle:' || p_session_id::text;

    -- 包桌的關聯是**反方向**的：場次那一側沒有任何 booking 欄位
    select exists (select 1 from bookings b
                    where b.seated_session_id = p_session_id) into v_booking;

    for v_p in
      select sp.member_id, sp.final_score
        from session_players sp
       where sp.session_id = p_session_id
         and sp.member_id is not null
    loop
      perform public.fire_event_tx(v_p.member_id, 'session_finished', 1, null, v_idem);

      -- 🔴 「贏」看**桌上積分的正負**，不是名次（CLAUDE.md 拍板）——
      --   第 2 名照樣可能是負的，而定位賽四個人的得點全是正的。
      -- ⚠ 純娛樂的 final_score 是 **null 不是 0** ⇒ 不算贏也不算輸。
      if coalesce(v_p.final_score, 0) > 0 then
        perform public.fire_event_tx(v_p.member_id, 'session_won', 1, null, v_idem);
      end if;

      if v_s.mode = 'matched' then
        perform public.fire_event_tx(v_p.member_id, 'queue_session_done', 1, null, v_idem);
      end if;

      if v_booking then
        perform public.fire_event_tx(v_p.member_id, 'booking_session_done', 1, null, v_idem);
      end if;
    end loop;
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


-- ============================================================
-- 驗證
-- ============================================================
do $$
declare
  v_msg text := '';
  v_n   int;
  v_def text;
  v_txt text;
begin
  select pg_get_functiondef(oid) into v_def
    from pg_proc where pronamespace='public'::regnamespace and proname='settle_session_tx';

  -- ① 版本數 1（多載會讓 POS 挑到舊的那一支，而且不報錯）
  select count(*) into v_n from pg_proc
   where pronamespace='public'::regnamespace and proname='settle_session_tx';
  v_msg := case when v_n = 1
    then '✅ ① settle_session_tx 版本數 1'
    else '🔴 ① 有 ' || v_n || ' 個版本 —— 簽名被改到了' end;

  -- ② 四個事件名都在（逐一對照契約，不是數數量）
  select string_agg(e || '=' || case when v_def ~ ('''' || e || '''') then '✅' else '🔴' end,
                    '　' order by ord)
    into v_txt
    from unnest(array['session_finished','session_won',
                      'queue_session_done','booking_session_done'])
         with ordinality t(e, ord);
  v_msg := v_msg || E'\n' || '　　② 四個事件：' || coalesce(v_txt, '⚪ 取不到');

  -- ③ 🔴 順序：成就那一段一定要排在 placeholder_ranks_tx 之後
  --    排在前面的話 final_score 還是 null ⇒ session_won 永遠不發，而且不報錯
  v_msg := v_msg || E'\n' || case
    when position('placeholder_ranks_tx' in v_def) > 0
     and position('fire_event_tx' in v_def) > position('placeholder_ranks_tx' in v_def)
    then '✅ ③ 成就事件排在 placeholder_ranks_tx 之後（final_score 已經寫好）'
    else '🔴 ③ 順序不對 —— session_won 會讀到 null 而永遠不發' end;

  -- ④ 🔴 整段有吞例外：桌已經收了，成就失敗不可以回滾收桌
  --    數 exception 區塊：placeholder ＋ 通知 ＋ 成就 = 3 個
  select count(*) into v_n
    from regexp_matches(v_def, 'exception when others then null', 'g') m;
  v_msg := v_msg || E'\n' || case when v_n = 3
    then '✅ ④ 三個副作用區塊都吞例外（名次／通知／成就）'
    else '🔴 ④ 吞例外的區塊有 ' || v_n || ' 個，應為 3' end;

  -- ⑤ 負對照：既有的東西一個都沒掉
  --    只驗「新的加上去了」的話，把收桌本體改壞也會全綠（硬規則 3.55）
  select string_agg(k || '=' || case when v_def ~ k then '✅' else '🔴' end, '　' order by ord)
    into v_txt
    from unnest(array['current_staff','already_settled','session_not_open',
                      'fee_points','app_notifications','auto_assign'])
         with ordinality t(k, ord);
  v_msg := v_msg || E'\n' || '　　⑤ 既有段落：' || coalesce(v_txt, '⚪ 取不到');

  -- ⑥ 🔴 已收桌那條路**不可以**發成就（累積型會被多加一次）
  --    判準：already_settled 的 return 排在第一個 fire_event_tx 之前
  v_msg := v_msg || E'\n' || case
    when position('already_settled' in v_def) < position('fire_event_tx' in v_def)
    then '✅ ⑥ 已收桌那條路在成就之前就 return 了（不會重發）'
    else '🔴 ⑥ 重複收桌會再發一次成就事件' end;

  -- ⑦ GRANT 沒掉（CREATE OR REPLACE 不該掉，但這一格是那個假設的證據）
  select string_agg(g || '=' || case when exists (
           select 1 from pg_proc p, aclexplode(p.proacl) a
            where p.pronamespace='public'::regnamespace and p.proname='settle_session_tx'
              and a.grantee = case when g='PUBLIC' then 0 else g::regrole::oid end
              and a.privilege_type='EXECUTE') then '有' else '沒有' end, '　' order by ord)
    into v_txt
    from unnest(array['anon','authenticated','service_role','PUBLIC'])
         with ordinality t(g, ord);
  v_msg := v_msg || E'\n' || '　　⑦ 授權：' || coalesce(v_txt, '⚪ 取不到')
    || E'\n' || '　　（POS 用 anon ⇒ anon 必須是「有」，收掉會當場打壞收銀機）';

  perform set_config('migi.verify', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify', true), ''), '🔴 沒有驗證訊息') as "驗證";
