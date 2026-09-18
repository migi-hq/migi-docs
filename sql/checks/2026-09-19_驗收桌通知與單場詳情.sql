/* ═══════════════════════════════════════════════════════════════════
   驗：收桌真的會發 settle 通知、單場詳情真的擋得住別人
   2026-09-19 · 搭配 sql/applied/2026-09-19_收桌發結算通知與單場詳情.sql
   ═══════════════════════════════════════════════════════════════════

   🔴 **這一份會寫入，然後整個回滾**（結尾 `raise exception 'migi_rollback'`）。
     那正是硬規則 1.8 的判準：
       · 要留下 DDL 的檔案 ⇒ 一個字都不准 raise
       · 要造樣本測行為的檔案 ⇒ 只能 raise，否則樣本會留在正式資料庫裡
     這個專案沒有 staging（硬規則 5.7），所以行為測試只能這樣做。

   🎯 **為什麼一定要有這一份**：那份 DDL 的驗證段只看得到「函式長什麼樣」，
     看不到「收一次桌會不會真的產生通知」。
     ⚠ 只驗「該擋的擋了」也不夠 —— 一支永遠回 not_found 的實作會讓
       擋牆那一格變綠（硬規則 3.55：過度阻擋跟沒擋一樣糟）。
       所以每一道牆都配一個**正對照**。

   ⚠ 自己造樣本、不借線上最新那一筆（硬規則 3.57：借來的樣本會跟真實世界賽跑）。
   ═══════════════════════════════════════════════════════════════════ */

do $$
declare
  v_org     uuid := '11111111-1111-1111-1111-111111111111';
  v_store   uuid;
  v_table   uuid;
  v_sess    uuid;
  v_me      uuid;
  v_other   uuid;
  v_third   uuid;   -- 擋牆用：真的存在、但沒坐過那一桌的人
  v_out     jsonb;
  v_msg     text := '';
  v_n       int;
  v_before  int;
begin
  /* ── 樣本：自己開一張桌、自己開一場、放兩個測試會員進去 ──
     ⚠ 找不到樣本要**出聲**，不要 `if ... then` 安靜跳過（硬規則 3.57）。 */
  select id into v_store from stores where org_id = v_org and is_test order by created_at limit 1;
  if v_store is null then
    select id into v_store from stores where org_id = v_org order by created_at limit 1;
  end if;

  select id into v_me    from members where org_id = v_org and is_test and deleted_at is null order by created_at limit 1;
  select id into v_other from members where org_id = v_org and is_test and deleted_at is null and id <> v_me order by created_at limit 1;

  if v_store is null or v_me is null or v_other is null then
    /* ⚠ 訊息只存進**變數**，不要在這裡 set_config —— 見檔尾那段。 */
    v_msg := '⚪ 取不到樣本（門市或測試會員不足）—— 這一份測不了，不要當成通過';
    raise exception 'migi_rollback';
  end if;

  insert into tables (org_id, store_id, label, seats, auto_assign)
  values (v_org, v_store, 'ZZ-驗證用', 4, false)
  returning id into v_table;

  insert into table_sessions (org_id, store_id, table_id, mode, status,
                              started_at, activated_at, game_type, flower, planned_rounds)
  values (v_org, v_store, v_table, 'matched', 'open',
          now() - interval '2 hours', now() - interval '2 hours', '台麻', '無花', 3)
  returning id into v_sess;

  insert into session_players (org_id, session_id, member_id, charged_points, joined_at)
  values (v_org, v_sess, v_me,    100, now() - interval '2 hours'),
         (v_org, v_sess, v_other, 100, now() - interval '2 hours');

  select count(*) into v_before from app_notifications where type = 'settle';

  /* ── ① 收桌 ───────────────────────────────────────── */
  v_out := public.settle_session_tx(v_sess, null, false);
  v_msg := case when coalesce((v_out->>'ok')::boolean, false)
    then '✅ ① 收桌成功（players_left=' || coalesce(v_out->>'players_left','?') || '）'
    else '🔴 ① 收桌失敗：' || coalesce(v_out->>'reason','?') end;

  /* ── ② 每個坐過的人各收到一則，而且 ref_id 指得回那一場 ── */
  select count(*) into v_n
    from app_notifications
   where type = 'settle' and ref_id = v_sess;
  v_msg := v_msg || E'\n' || case when v_n = 2
    then '✅ ② 兩個玩家各一則 settle 通知'
    else '🔴 ② 通知 ' || v_n || ' 則（應該是 2）' end;

  /* ── ③ payload 帶得出門市與積分（前端在此之前是寫死的）── */
  select count(*) into v_n
    from app_notifications
   where type = 'settle' and ref_id = v_sess
     and payload ? 'session_id' and payload ? 'store' and payload ? 'at';
  v_msg := v_msg || E'\n' || case when v_n = 2
    then '✅ ③ payload 有 session_id / store / at'
    else '🔴 ③ payload 少了鍵（' || v_n || '/2 則完整）' end;

  /* ── ④ 冪等：再收一次不該再發一輪 ──
     店員在網路慢時按兩下是常態，第二下不可以讓客人再收到一則。 */
  perform public.settle_session_tx(v_sess, null, false);
  select count(*) into v_n from app_notifications where type = 'settle' and ref_id = v_sess;
  v_msg := v_msg || E'\n' || case when v_n = 2
    then '✅ ④ 再收一次沒有重複發（仍然 2 則）'
    else '🔴 ④ 重複發了 —— 現在 ' || v_n || ' 則' end;

  /* ── ⑤ 單場詳情：自己查得到，而且四個欄位都在 ──
     🔴 這是**正對照**：少了它，一支永遠回 not_found 的實作會讓 ⑥ 變綠。 */
  v_out := public.get_game_tx(v_org, v_sess, v_me);
  v_msg := v_msg || E'\n' || case
    when coalesce((v_out->>'ok')::boolean, false)
     and v_out->'game' ? 'players'
     and jsonb_array_length(v_out->'game'->'players') = 2
     and v_out->'game' ? 'duration_minutes'
    then '✅ ⑤ 自己查得到那一場（players 2 人、有時長）'
    else '🔴 ⑤ 自己查不到或欄位缺：' || left(coalesce(v_out::text,'null'), 120) end;

  /* ── ⑥ 擋牆：沒坐過那一桌的人查不到 ──
     ⚠ 用一個**真的存在但不在這桌**的會員，不要用亂數 uuid ——
       後者連「這個人存不存在」都沒測到。 */
  select id into v_third from members where org_id = v_org and deleted_at is null
     and id not in (v_me, v_other) limit 1;
  if v_third is null then
    v_msg := v_msg || E'\n⚪ ⑥ 找不到第三個會員，擋牆這一格測不了';
  else
    v_out := public.get_game_tx(v_org, v_sess, v_third);
    v_msg := v_msg || E'\n' || case
      when coalesce((v_out->>'ok')::boolean, true) = false and v_out->>'reason' = 'not_found'
      then '✅ ⑥ 沒坐過的人拿到 not_found（而且不告訴他那一場存在）'
      else '🔴 ⑥ 擋牆沒擋住：' || left(coalesce(v_out::text,'null'), 120) end;
  end if;

  /* ── ⑦ 清單那支改用 _game_row 之後，形狀沒變 ── */
  v_out := public.get_my_games_tx(v_org, v_me, 5);
  v_msg := v_msg || E'\n' || case
    when jsonb_typeof(v_out) = 'array' and jsonb_array_length(v_out) >= 1
     and (v_out->0) ? 'session_id' and (v_out->0) ? 'players' and (v_out->0) ? 'my_rating_after'
    then '✅ ⑦ 紀錄清單仍然是陣列、鍵沒少（' || jsonb_array_length(v_out) || ' 筆）'
    else '🔴 ⑦ 清單形狀變了：' || left(coalesce(v_out::text,'null'), 120) end;

  raise exception 'migi_rollback';

/* 🔴 **訊息一定要設在 exception 處理器裡，不可以設在 raise 之前**（硬規則 3.9）。
   `set_config(..., true)` 是**交易內**的設定 ⇒ 寫在 raise 之前會跟著一起被回滾，
   最後印出「🔴 沒有驗證訊息」。
   ⚠ 2026-09-19 第一版就是這樣錯的，而它看起來像「測試整個沒跑」——
     實際上七格都跑完了，只是話被回滾掉了。
   📌 變數 `v_msg` 不受回滾影響（那是記憶體不是資料），所以整段訊息在這裡還在。 */
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.verify_settle_behavior', v_msg, true);
  else
    perform set_config('migi.verify_settle_behavior',
      coalesce(v_msg, '') || E'\n🔴 中途炸了：' || sqlerrm, true);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.verify_settle_behavior', true), ''),
                '🔴 沒有驗證訊息') as "行為驗證（已全部回滾）";
