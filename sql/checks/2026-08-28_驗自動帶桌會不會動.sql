/* ============================================================
   驗：自動帶桌整條路到底會不會動
   2026-08-28 · 交易內測試，最後回滾，不留任何資料

   ⚠ **這支要走 Dashboard，MCP 幫不上忙** —— MCP 是唯讀連線
     （`supabase_read_only_user`），INSERT 會直接被 25006 擋掉。

   ── 為什麼要驗 ──────────────────────────────────────
   pg_cron 的 `auto-seat-matched` 每 5 分鐘在跑，但（2026-08-28 查證）：
     · `open_method = 'auto'` 的場次：**0**
     · 曾經到過 matched/seated 的房：**0**
     · 59 個房、`match_queue_players` 共 14 列而且**全部 left_at 不是 null**

   接線本身是對的（`create_match_queue_tx` 會寫開房者、
   `join_match_queue_tx` 會寫加入者並呼叫 `_finalize_queue_full_tx`），
   所以「0 次」最可能只是**從來沒有 4 個人在同一房**。

   🔴 但「沒被觸發過」等於「沒被驗證過」。
     CLAUDE.md 硬規則 7 的推論：**從未成功執行過的函式，
     它的每一行邏輯都從未被驗證。** `dev_reset_test_data_tx` 就是這樣 ——
     從建立以來一次都沒成功執行過，卻被當成已完成。
   ⚠ 而它是**每 5 分鐘自動在跑**的東西：真的壞了也不會有人發現。

   ── 完整路徑（2026-08-28 撈線上定義確認）────────────
     join_match_queue_tx（第 4 人加入）
       └─ _finalize_queue_full_tx      → status = 'matched'
            └─ _try_auto_seat_tx       → 找一張 auto_assign 且沒 open session 的桌
                 └─ pos_seat_queue_tx  → open_session_tx(open_method='auto')
                      └─ match_queues.status = 'seated'

   📌 順帶更正一個文件漂移：`sql/applied/2026-08-23_自動帶桌延到接近開打.sql`
     把自動帶桌改成「開打前 30 分鐘才帶」，但**線上版已經改回「湊滿就佔桌」**
     （`_try_auto_seat_tx` 的註解寫著理由：放回去給現場客人卻沒有預留機制，
     等於承諾兌現不了）。
     → 所以**沒有 30 分鐘門檻**，測試不用管 play_at 設多遠。
     → ⚠ 同硬規則 3：`sql/applied/` 不是線上現況的鏡像。

   ── 🔴 已知的一道會靜默卡死的擋牆 ────────────────────
   `pos_seat_queue_tx` 解析 `rounds`：必須含「三/3」或「二/2」，
   否則回 `rounds_not_supported`。
   而 `match_queues.rounds` 的**預設值是 `'一將'`**，
   現有資料裡也還有 **33 房是「一將」**。
   → 測試②刻意用「一將」驗證它會被擋下並回報清楚的理由，
     而不是靜靜什麼都不做。
   ============================================================ */

do $$
declare
  v_org uuid; v_store uuid; v_stake uuid;
  v_m1 uuid; v_m2 uuid; v_m3 uuid; v_m4 uuid;
  /* ⚠ 2026-08-28 修：第一版把回傳型別猜錯了（同硬規則 3，我自己踩）——
       create_match_queue_tx **RETURNS uuid**（不是 jsonb）
       join_match_queue_tx   **RETURNS text**（'matched' / 'waiting'）
     猜錯的症狀是 `invalid input syntax for type json`，
     而且錯在準備階段，測試本身完全沒跑到。 */
  v_q uuid; v_ret text; v_msg text := '';
  v_free int; v_seated_sid uuid; v_open_method text; v_label text;
  v_status text; v_players int;
begin
  /* ── 準備：撈一組可用的 org / store / stake / 四個會員 ── */
  select s.org_id, s.id into v_org, v_store
    from stores s
   where s.deleted_at is null and coalesce(s.is_active, true)
     and exists (select 1 from tables t
                  where t.store_id = s.id and t.deleted_at is null
                    and coalesce(t.is_active,true) and t.auto_assign
                    and not exists (select 1 from table_sessions ts
                                     where ts.table_id = t.id and ts.status='open'
                                       and ts.deleted_at is null))
   limit 1;

  select id into v_stake from stake_levels
   where org_id = v_org and (store_id = v_store or store_id is null)
     and deleted_at is null and is_active limit 1;

  -- 逐一取四個不同的會員（用 offset 而不是 array，錯誤訊息比較好讀）
  select id into v_m1 from members where org_id=v_org and deleted_at is null order by created_at offset 0 limit 1;
  select id into v_m2 from members where org_id=v_org and deleted_at is null order by created_at offset 1 limit 1;
  select id into v_m3 from members where org_id=v_org and deleted_at is null order by created_at offset 2 limit 1;
  select id into v_m4 from members where org_id=v_org and deleted_at is null order by created_at offset 3 limit 1;

  select count(*) into v_free
    from tables t
   where t.org_id = v_org and t.store_id = v_store and t.deleted_at is null
     and coalesce(t.is_active,true) and t.auto_assign
     and not exists (select 1 from table_sessions ts
                      where ts.table_id = t.id and ts.status='open' and ts.deleted_at is null);

  if v_org is null or v_stake is null or v_m4 is null then
    perform set_config('migi.seat',
      '⚠ 跳過：缺 org／stake／四個會員（org=' || coalesce(v_org::text,'null') ||
      ' stake=' || coalesce(v_stake::text,'null') ||
      ' 第四位會員=' || coalesce(v_m4::text,'null') || '）', true);
    return;
  end if;

  begin
    /* ══ 測試①：正常路徑（rounds = 2 將）══
       開房 → 三個人加入 → 第四人（含開房者共 4 人）應該觸發湊滿並自動帶桌 */
    v_q := create_match_queue_tx(v_org, v_m1, v_store, v_stake,
             now() + interval '3 hours', '台麻', '2 將', 4, '{}'::jsonb, '無花');
    if v_q is null then
      v_msg := '🔴 ① 開房就失敗（回傳 null）';
      raise exception 'rollback_on_purpose';
    end if;

    perform join_match_queue_tx(v_org, v_m2, v_q, 'browse');
    perform join_match_queue_tx(v_org, v_m3, v_q, 'browse');
    v_ret := join_match_queue_tx(v_org, v_m4, v_q, 'browse');   -- ★ 第四人：應該觸發

    select status, matched_session_id into v_status, v_seated_sid
      from match_queues where id = v_q;
    select count(*) into v_players from match_queue_players
     where queue_id = v_q and left_at is null;
    select ts.open_method, t.label into v_open_method, v_label
      from table_sessions ts join tables t on t.id = ts.table_id
     where ts.id = v_seated_sid;

    v_msg := '【測試① 正常路徑（2 將）】' ||
      E'\n  可用空桌：' || v_free::text || ' 張' ||
      E'\n  第四人加入的回傳：' || coalesce(v_ret, 'null') ||
      E'\n  房間狀態：' || coalesce(v_status,'null') ||
      '　在座人數：' || v_players::text || '/4' ||
      E'\n  帶到的場次：' || coalesce(v_seated_sid::text,'（沒有）') ||
      '　桌號=' || coalesce(v_label,'-') ||
      '　open_method=' || coalesce(v_open_method,'-') ||
      E'\n  → ' || case
          when v_status = 'seated' and v_seated_sid is not null and v_open_method = 'auto'
            then '✅ 整條路會動：湊滿 → matched → 自動帶桌 → seated'
          when v_status = 'matched' and v_seated_sid is null
            then '🟡 湊滿了但沒帶桌（多半是沒有空桌，排程下一輪會再試）'
          when v_status = 'waiting'
            then '🔴 四個人都加入了卻還是 waiting —— 湊滿判定沒觸發'
          else '🔴 非預期狀態' end;

    /* ══ 測試②：rounds = 一將（預設值）══
       目的不是「它應該成功」，而是確認它**明確回報原因**，
       而不是靜靜什麼都不做。33 個現有房間就是這個值。 */
    /* ⚠ play_at 要跟測試①拉開 —— `_check_join_conflict` 有**6 小時間隔檢查**，
         同一批會員在 6 小時內加入兩房會被擋（第一版排 +3h／+5h，測試②必掛）。
         這裡用 +30h，確定超出間隔。 */
    v_q := create_match_queue_tx(v_org, v_m1, v_store, v_stake,
             now() + interval '30 hours', '台麻', '一將', 4, '{}'::jsonb, '無花');
    if v_q is not null then
      perform join_match_queue_tx(v_org, v_m2, v_q, 'browse');
      perform join_match_queue_tx(v_org, v_m3, v_q, 'browse');
      v_ret := join_match_queue_tx(v_org, v_m4, v_q, 'browse');
      select status into v_status from match_queues where id = v_q;
      v_msg := v_msg || E'\n\n【測試② rounds=「一將」（預設值，33 個現有房是這個）】' ||
        E'\n  回傳：' || coalesce(v_ret,'null') ||
        E'\n  房間狀態：' || coalesce(v_status,'null') ||
        E'\n  → ' || case
            when v_status = 'seated' then '⚠ 竟然帶桌成功了 —— 那道 rounds 擋牆沒生效'
            when v_status = 'matched' then '✅ 停在 matched（符合預期：rounds 不支援，不會帶桌）'
            else '🟡 ' || coalesce(v_status,'null') end;
    else
      v_msg := v_msg || E'\n\n【測試②】開房回傳 null';
    end if;

    raise exception 'rollback_on_purpose';
  exception
    when others then
      /* ⚠ 硬規則 3.9：訊息一律設在處理器裡 ——
         set_config(..., true) 是交易內設定，寫在 raise 之前會跟著被回滾。 */
      if sqlerrm = 'rollback_on_purpose' then
        perform set_config('migi.seat', v_msg, true);
      else
        perform set_config('migi.seat',
          coalesce(nullif(v_msg,''), '') || E'\n🔴 測試拋錯：' || sqlerrm, true);
      end if;
  end;
end $$;

/* ============================================================
   驗證（單一 SELECT）

   ── 該看到什麼 ──────────────────────────────────────
   ① 測試結果，測試①應為 ✅
   ② ③ ④ 三個計數必須跟跑之前一樣（確認回滾乾淨）
   ============================================================ */
select 序, 項目, 內容 from (

  select 1 as 序, '① 測試結果' as 項目,
         coalesce(current_setting('migi.seat', true), '🔴 DO 區塊沒執行') as 內容

  union all
  select 2, '② 配桌房數（跑之前 59）',
         (select count(*)::text || ' 房' from match_queues)

  union all
  select 3, '③ 場次數（確認沒有留下自動開的桌）',
         (select count(*)::text || ' 場，其中 open_method=auto 有 ' ||
                 count(*) filter (where open_method = 'auto')::text || ' 場'
            from table_sessions)

  union all
  select 4, '④ 配桌玩家列數（跑之前 14）',
         (select count(*)::text || ' 列' from match_queue_players)

) x order by 序;
