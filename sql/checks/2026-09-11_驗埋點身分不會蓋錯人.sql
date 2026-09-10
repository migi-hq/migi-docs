/* ============================================================
   驗 `log_app_event_tx` 的身分覆寫：該蓋的蓋、不該蓋的不要碰
   2026-09-11 · **在交易裡真的寫幾筆，最後整份回滾**

   ── 為什麼一定要真的執行 ────────────────────────────
   `2026-09-11_埋點的會員身分以JWT為準.sql` 的驗證段只讀函式定義 ——
   而**讀定義證明不了行為**：`CREATE FUNCTION` 不檢查函式體
   （硬規則 7 那個 `dev_reset_test_data_tx` 從建立以來一次都沒成功過）。

   🔴 而這一支特別需要行為測試，因為它**改錯了不會有症狀**：
   ```
   蓋錯人 → app_events 多一筆掛在別人身上
          → 那張表有 trg_app_events_no_mutate（UPDATE 與 DELETE 都擋）
          → **永遠改不掉**
   ```
   ⚠ 而寫入端是靜默的：沒有人在看 `log_app_event_tx` 的回傳。

   ── 這份會寫入，但一列都留不下來 ─────────────────────
   `raise exception 'migi_rollback'` 讓整段退掉。
   🔴 訊息一定要設在 exception handler 裡 —— 寫在 raise 之前的
     `set_config(..., true)` 會跟著被回滾（硬規則 3.9）。
   ⚠ 這份**不歸檔到 `applied/`**。

   ── 四種情境，而第四種是這次真正的重點 ──────────────
   ```
   ① 沒有 JWT ＋ 送 null      → 維持 null      （POS 今天的樣子）
   ② 沒有 JWT ＋ 送 A         → 維持 A          （還沒發 session 的那條路）
   ③ 有 JWT(A) ＋ 送 B        → **改成 A**      ← 洞堵住了沒
   ④ 有 JWT(A) ＋ 送 null     → **維持 null**   ← 🔴 這一格是這次的重點
   ```
   🎯 ④ 若失敗，代表店員登入之後 POS 的每一筆事件都會掛到他自己的
     會員帳號上，而且跟著他的 `is_test` 被標成測試。
     **那個錯誤寫進去就改不掉。**
   ============================================================ */

do $$
declare
  v_msg  text := '';
  v_org  uuid;
  v_a    uuid; v_a_line text;   -- 有 LINE 的會員（拿來當 JWT 身分）
  v_b    uuid;                  -- 另一個會員（拿來當「前端送別人的」）
  v_got  uuid;
  v_ev   text := '_probe_id_overwrite';   -- ⚠ 底線開頭會被 CHECK 擋，見下
begin
  begin
    /* 🔴 事件名不可以用底線開頭。`app_events_event_check` 是
       `event ~ '^[a-z][a-z0-9_]{0,49}$'` —— 2026-08-26 就踩過一次
       （`_smoke_pos_log` 敗在底線開頭，而錯誤訊息只給約束名字）。 */
    v_ev := 'probe_id_overwrite';

    select m.org_id, m.id, m.line_user_id
      into v_org, v_a, v_a_line
      from members m
     where m.line_user_id is not null and m.deleted_at is null
     order by m.created_at
     limit 1;

    select m.id into v_b
      from members m
     where m.org_id = v_org and m.deleted_at is null and m.id <> v_a
     order by m.created_at
     limit 1;

    if v_a is null or v_b is null then
      v_msg := '🔴 取樣失敗：需要「一個有 LINE 的會員」＋「另一個會員」——'
            || ' 有 LINE 的：' || coalesce(v_a::text,'(無)')
            || '　另一個：' || coalesce(v_b::text,'(無)');
      raise exception 'migi_rollback';
    end if;

    /* ── ①② 沒有 JWT ──────────────────────────────── */
    perform set_config('request.jwt.claims', '', true);

    perform public.log_app_event_tx(v_org, null, v_ev, '{"case":"1"}'::jsonb);
    select member_id into v_got from app_events
     where event = v_ev and props->>'case' = '1' limit 1;
    v_msg := v_msg || case when v_got is null
      then '① ✅ 沒有 JWT ＋ 送 null → 維持 null（POS 的情境）'
      else '① 🔴 沒有 JWT 卻被填上了：' || v_got end;

    perform public.log_app_event_tx(v_org, v_a, v_ev, '{"case":"2"}'::jsonb);
    select member_id into v_got from app_events
     where event = v_ev and props->>'case' = '2' limit 1;
    v_msg := v_msg || E'\n' || case when v_got = v_a
      then '② ✅ 沒有 JWT ＋ 送 A → 維持 A（還沒發 session 的那條路照舊）'
      else '② 🔴 被改掉了：' || coalesce(v_got::text,'null') end;

    /* ── ③④ 有 JWT，身分是 A ─────────────────────────
       ⚠ 模擬的是**今天的形狀**：還沒發 Supabase JWT 時 `sub` 直接
         就是 LINE user id（`migi_jwt_line_id()` 的第 ② 條路）。 */
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_a_line, 'role', 'authenticated')::text, true);

    if public.current_member_id() is distinct from v_a then
      v_msg := v_msg || E'\n🔴 模擬 JWT 失敗：current_member_id() 回 '
            || coalesce(public.current_member_id()::text,'null')
            || '，預期 ' || v_a || ' —— 下面兩格測不準';
    end if;

    perform public.log_app_event_tx(v_org, v_b, v_ev, '{"case":"3"}'::jsonb);
    select member_id into v_got from app_events
     where event = v_ev and props->>'case' = '3' limit 1;
    v_msg := v_msg || E'\n' || case when v_got = v_a
      then '③ ✅ 有 JWT(A) ＋ 送 B → 改成 A（前端送別人的會被改回自己）'
      else '③ 🔴 沒有改回來，寫進去的是：' || coalesce(v_got::text,'null') end;

    /* 🔴 這一格是這次的重點。 */
    perform public.log_app_event_tx(v_org, null, v_ev, '{"case":"4"}'::jsonb);
    select member_id into v_got from app_events
     where event = v_ev and props->>'case' = '4' limit 1;
    v_msg := v_msg || E'\n' || case when v_got is null
      then '④ ✅ 有 JWT(A) ＋ 送 null → 維持 null（POS 的事件不會掛到店員身上）'
      else '④ 🔴 被掛到 ' || v_got || ' 身上了 —— 而 app_events 改不掉' end;

    /* ── ⑤ 順帶確認測試旗標仍然照原本的規則推 ────────── */
    select count(*) into v_got from app_events where event = v_ev;
    v_msg := v_msg || E'\n⑤ ⚪ 這一輪造了 ' || v_got || ' 筆探針事件（等一下全部回滾）';

    raise exception 'migi_rollback';

  exception when others then
    /* ⚠ 只有自己丟的那個字串是「刻意回滾」。其餘一律當成真的錯誤 ——
       把例外吞掉只記「失敗了」，會讓「工具用錯」偽裝成「系統壞了」。 */
    if sqlerrm <> 'migi_rollback' then
      v_msg := v_msg || E'\n🔴 中途拋出例外：' || sqlerrm;
    end if;
    perform set_config('request.jwt.claims', '', true);
    perform set_config('migi.chk', v_msg, true);
  end;
end $$;

/* ⚠ 下面是**交易外的真實狀態**：探針事件一筆都不可以留下來。
   🔴 `app_events` 是 append-only（UPDATE 與 DELETE 都被觸發器擋），
     所以萬一留下來了**清不掉** —— 這一格不是形式。 */
select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息')
       || E'\n\n── 回滾確認（交易外的真實狀態）──'
       || E'\n⑥ ' || case when (select count(*) from app_events
                                 where event = 'probe_id_overwrite') = 0
                          then '✅ 探針事件一筆都沒有留下'
                          else '🔴 留下了 '
                               || (select count(*)::text from app_events
                                    where event = 'probe_id_overwrite')
                               || ' 筆 —— 而 app_events 刪不掉' end
       as "驗證";
