/* ============================================================
   驗包桌預約：客人訂、容量掉、擋牆、店員帶桌、過期收回
   2026-09-11 · **在交易裡真的訂幾筆，最後整份回滾**

   ── 為什麼非要這一份（硬規則 7）────────────────────
   `2026-09-11_包桌預約函式.sql` 的驗證段只證明
   「函式建立了、授權對了、非店員被擋」。**那證明不了它算對容量。**

   而這一批最怕的錯**全部都不會報錯**：
   ```
   ① 容量沒扣        → 同一個時段答應兩組人，當天才發現沒桌
   ② 重疊判準寫窄    → 24 小時的預約擋不住中間那兩小時
   ③ 過期沒收        → 一筆死掉的預約永遠佔著容量
                       症狀是「明明沒人訂卻說滿了」，而沒有人查得出原因
   ④ 取消沒把容量還回來 → 同上，只是更難發現
   ```

   ── 這份會寫入，但一列都留不下來 ─────────────────
   `raise exception 'migi_rollback'`。🔴 訊息設在 exception handler 裡
   （硬規則 3.9）。⚠ **不歸檔到 `applied/`**。

   ── 每一格用不同的日期，那是刻意的 ─────────────────
   🔴 硬規則 3.57：**每一格開始前重建自己的前提，不要假設上一格
     沒有副作用。** 容量是共用的狀態 —— 全部擠在同一個時段的話，
     第 ⑧ 格會因為第 ① 格的預約而算錯，而表面症狀會是「函式壞了」。
   ⇒ 各格各用一天，互不干擾。
   ============================================================ */

do $$
declare
  v_msg   text := '';
  v_a     uuid; v_la text;      -- 客人 A
  v_b     uuid; v_lb text;      -- 客人 B
  v_ls    text;                 -- 店員（有 staff 列又綁了 LINE 的那位）
  v_store uuid; v_sname text;
  v_other uuid;                 -- 別間店的桌（驗 bad_table）
  v_tbl   uuid; v_total int;
  v_team  uuid;
  v_k1    uuid; v_k2 uuid;
  v_r     jsonb;
  v_free  int;
  v_t1    timestamptz; v_t2 timestamptz; v_t3 timestamptz; v_t4 timestamptz;
  v_stat  text;
begin
  begin
    /* ── 取樣 ─────────────────────────────────────── */
    select m.id, m.line_user_id into v_a, v_la from public.members m
     where m.line_user_id is not null and m.deleted_at is null
       and not exists (select 1 from public.staff s where s.member_id = m.id and s.deleted_at is null)
     order by m.created_at offset 0 limit 1;
    select m.id, m.line_user_id into v_b, v_lb from public.members m
     where m.line_user_id is not null and m.deleted_at is null
       and not exists (select 1 from public.staff s where s.member_id = m.id and s.deleted_at is null)
     order by m.created_at offset 1 limit 1;
    select m.line_user_id into v_ls from public.members m
      join public.staff s on s.member_id = m.id and s.deleted_at is null
     where m.line_user_id is not null and m.deleted_at is null
     order by m.created_at limit 1;

    /* 有桌位最多的那一間。🔴 不要挑第一間 —— 七間裡有五間 0 桌。 */
    select t.store_id, s.name, count(*)::int into v_store, v_sname, v_total
      from public.tables t join public.stores s on s.id = t.store_id
     where t.is_active and t.deleted_at is null
     group by t.store_id, s.name order by count(*) desc limit 1;
    select t.id into v_tbl from public.tables t
     where t.store_id = v_store and t.is_active and t.deleted_at is null limit 1;
    select t.id into v_other from public.tables t
     where t.store_id <> v_store and t.is_active and t.deleted_at is null limit 1;

    if v_b is null or v_ls is null or v_store is null then
      v_msg := '🔴 取樣失敗：需要兩個非店員會員 ＋ 一個店員 ＋ 一間有桌位的店 —— '
            || 'A=' || coalesce(v_a::text, '(無)')
            || ' B=' || coalesce(v_b::text, '(無)')
            || ' 店員=' || coalesce(v_ls, '(無)')
            || ' 門市=' || coalesce(v_sname, '(無)');
      raise exception 'migi_rollback';
    end if;

    v_t1 := date_trunc('hour', now()) + interval '1 day'  + interval '19 hours';
    v_t2 := date_trunc('hour', now()) + interval '4 days' + interval '10 hours';
    v_t3 := date_trunc('hour', now()) + interval '7 days' + interval '19 hours';
    v_t4 := date_trunc('hour', now()) + interval '10 days' + interval '19 hours';

    /* ── ① 客人 A 訂一桌 ───────────────────────────── */
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_la, 'role', 'authenticated')::text, true);
    v_r := public.create_booking_tx(v_store, v_t1, 5, 1, null, 8, '生日聚會');
    v_k1 := (v_r->>'booking_id')::uuid;
    v_msg := v_msg || case when (v_r->>'ok')::boolean and v_k1 is not null
      then '① ✅ 訂位成功 · ' || v_sname || '（總桌數 ' || v_total || '）'
      else '① 🔴 訂位失敗：' || coalesce(v_r::text, 'null') end;
    if v_k1 is null then raise exception 'migi_rollback'; end if;

    /* ── ② 容量真的掉下來了 ────────────────────────── */
    v_r := public.booking_capacity_tx(v_store, v_t1, 5);
    v_msg := v_msg || E'\n' || case when (v_r->>'free')::int = v_total - 1
      then '② ✅ 同時段可接桌數 ' || v_total || ' → ' || (v_r->>'free')
      else '② 🔴 容量沒扣：預期 ' || (v_total - 1) || '，實際 ' || (v_r->>'free') end;

    /* ── ③ 同一個人同時段不可以再訂 ────────────────── */
    v_r := public.create_booking_tx(v_store, v_t1 + interval '1 hour', 2, 1);
    v_msg := v_msg || E'\n' || case when coalesce(v_r->>'reason', '') = 'already_booked'
      then '③ ✅ 同一個人同時段重複訂被擋下'
      else '③ 🔴 重複訂成功了：' || coalesce(v_r::text, 'null') end;

    /* ── ④⑤ 兩道時間牆 ────────────────────────────── */
    v_r := public.create_booking_tx(v_store, now() + interval '10 minutes', 2, 1);
    v_msg := v_msg || E'\n' || case when coalesce(v_r->>'reason', '') = 'too_soon'
      then '④ ✅ 太近的預約被擋下（店員來不及看到，那是做不到的承諾）'
      else '④ 🔴 十分鐘後的預約訂成功了：' || coalesce(v_r::text, 'null') end;

    v_r := public.create_booking_tx(v_store, now() + interval '120 days', 2, 1);
    v_msg := v_msg || E'\n' || case when coalesce(v_r->>'reason', '') = 'too_far'
      then '⑤ ✅ 太遠的預約被擋下'
      else '⑤ 🔴 120 天後的預約訂成功了：' || coalesce(v_r::text, 'null') end;

    /* ── ⑥ 🔴 「被整個包住」的重疊 ──────────────────
       B 訂 10:00 起 24 小時。A 想訂當天 14:00 的兩小時 ——
       開始時間不在任何人的「開始」附近，但整段都被包著。
       ⚠ 這是地基那份用假資料驗過的判準，這裡用**真的資料**再驗一次。 */
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_lb, 'role', 'authenticated')::text, true);
    v_r := public.create_booking_tx(v_store, v_t2, 24, 3);
    v_k2 := (v_r->>'booking_id')::uuid;

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_la, 'role', 'authenticated')::text, true);
    v_r := public.booking_capacity_tx(v_store, v_t2 + interval '4 hours', 2);
    v_msg := v_msg || E'\n' || case when (v_r->>'booked')::int = 3
      then '⑥ ✅ 24 小時的預約擋得住中間那兩小時（已訂 3 桌）'
      else '⑥ 🔴 被整個包住的區間沒算到：已訂 ' || (v_r->>'booked') || '，預期 3' end;

    /* ── ⑦ 訂超過容量，而且話術要給數字 ──────────── */
    /* 先把 T3 那個時段訂到只剩一點點。⚠ 一次最多 10 桌，所以分兩筆。 */
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_lb, 'role', 'authenticated')::text, true);
    perform public.create_booking_tx(v_store, v_t3, 5, 10);
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_la, 'role', 'authenticated')::text, true);
    v_r := public.booking_capacity_tx(v_store, v_t3, 5);
    v_free := (v_r->>'free')::int;
    v_r := public.create_booking_tx(v_store, v_t3, 5, v_free + 1);
    v_msg := v_msg || E'\n' || case
      when coalesce(v_r->>'reason', '') = 'no_capacity'
       and position((v_free::text) in coalesce(v_r->>'message', '')) > 0
      then '⑦ ✅ 超過容量被擋，而且訊息講得出「只剩 ' || v_free || ' 桌」'
      when coalesce(v_r->>'reason', '') = 'no_capacity'
      then '⑦ 🟡 擋下來了但訊息沒講出剩幾桌：' || coalesce(v_r->>'message', '')
      else '⑦ 🔴 超訂成功了：' || coalesce(v_r::text, 'null') end;

    /* ── ⑧ 掛一個自己不在的團 ───────────────────── */
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_lb, 'role', 'authenticated')::text, true);
    v_r := public.create_team_tx('＿探針團＿包桌', '🐻', null, 'closed', null);
    v_team := (v_r->'team'->>'id')::uuid;

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_la, 'role', 'authenticated')::text, true);
    v_r := public.create_booking_tx(v_store, v_t4, 2, 1, v_team);
    v_msg := v_msg || E'\n' || case when coalesce(v_r->>'reason', '') = 'not_member'
      then '⑧ ✅ 掛一個自己不在的團被擋下（不然可以用別人的團名訂位）'
      else '⑧ 🔴 掛了別人的團：' || coalesce(v_r::text, 'null') end;

    /* ── ⑨ 團長可以取消團員訂的那一筆 ─────────────── */
    insert into public.team_members (org_id, team_id, member_id)
    select t.org_id, t.id, v_a from public.teams t where t.id = v_team;

    v_r := public.create_booking_tx(v_store, v_t4, 2, 1, v_team);
    v_k2 := (v_r->>'booking_id')::uuid;
    if not (v_r->>'ok')::boolean then
      v_msg := v_msg || E'\n⑨ 🔴 進團之後仍然訂不了：' || coalesce(v_r::text, 'null');
    else
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_lb, 'role', 'authenticated')::text, true);
      v_r := public.cancel_booking_tx(v_k2, 'leader');
      v_msg := v_msg || E'\n' || case when (v_r->>'ok')::boolean
        then '⑨ ✅ 團長取消得掉團員訂的那一筆（訂的人聯絡不上時才有人收得掉）'
        else '⑨ 🔴 團長取消不了：' || coalesce(v_r::text, 'null') end;
    end if;

    /* ── ⑩ 不相干的人不可以取消 ───────────────────── */
    v_r := public.cancel_booking_tx(v_k1, 'x');
    v_msg := v_msg || E'\n' || case when coalesce(v_r->>'reason', '') = 'not_yours'
      then '⑩ ✅ 不是訂位人也不是團長，取消被擋下'
      else '⑩ 🔴 別人取消掉了：' || coalesce(v_r::text, 'null') end;

    /* ── ⑪ 訂的人取消，而且容量要還回來 ───────────── */
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_la, 'role', 'authenticated')::text, true);
    v_r := public.cancel_booking_tx(v_k1, 'member');
    v_r := public.booking_capacity_tx(v_store, v_t1, 5);
    v_msg := v_msg || E'\n' || case when (v_r->>'free')::int = v_total
      then '⑪ ✅ 取消之後容量回到 ' || v_total || '（不還回來的話那個時段會永遠說滿了）'
      else '⑪ 🔴 容量沒還回來：' || (v_r->>'free') || '，預期 ' || v_total end;

    /* ── ⑫ 店員列得出來（正對照）─────────────────── */
    /* 🔴 migration 只驗了「非店員被擋」那一半 —— 一支永遠回 not_staff
       的實作也會讓那一格變綠（硬規則 3.55）。 */
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_ls, 'role', 'authenticated')::text, true);
    v_r := public.pos_list_bookings_tx(v_store, (v_t2 at time zone 'Asia/Taipei')::date);
    v_msg := v_msg || E'\n' || case
      when (v_r->>'ok')::boolean and jsonb_array_length(v_r->'bookings') > 0
      then '⑫ ✅ 店員列得出那一天的預約（' || jsonb_array_length(v_r->'bookings') || ' 筆）'
      else '⑫ 🔴 店員列不出來：' || coalesce(v_r::text, 'null') end;

    /* ── ⑬ 指定別間店的桌要被擋 ───────────────────── */
    select k.id into v_k2 from public.bookings k
     where k.store_id = v_store and k.status = 'booked' order by k.play_at limit 1;
    if v_other is null then
      v_msg := v_msg || E'\n⑬ ⚪ 只有一間店有桌位 —— 「別店的桌」測不了';
    else
      v_r := public.pos_seat_booking_tx(v_k2, v_other);
      v_msg := v_msg || E'\n' || case when coalesce(v_r->>'reason', '') = 'bad_table'
        then '⑬ ✅ 指定別間店的桌被擋下'
        else '⑬ 🔴 別店的桌指得上去：' || coalesce(v_r::text, 'null') end;
    end if;

    /* ── ⑭ 指定本店的桌 → seated ──────────────────── */
    v_r := public.pos_seat_booking_tx(v_k2, v_tbl);
    select k.status into v_stat from public.bookings k where k.id = v_k2;
    v_msg := v_msg || E'\n' || case when (v_r->>'ok')::boolean and v_stat = 'seated'
      then '⑭ ✅ 指定本店的桌 → ' || coalesce(v_r->>'table_label', '?') || '，狀態變 seated'
      else '⑭ 🔴 帶桌失敗：' || coalesce(v_r::text, 'null')
           || '，狀態＝' || coalesce(v_stat, 'null') end;

    /* ── ⑮ 已經帶到桌的，客人不可以再取消 ─────────── */
    /* ⚠ 用**訂那一筆的人**去取消，不是隨便找一個人 ——
       否則會停在 `not_yours`，根本走不到「已經處理過了」那一格。 */
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_lb, 'role', 'authenticated')::text, true);
    v_r := public.cancel_booking_tx(v_k2, 'x');
    v_msg := v_msg || E'\n' || case
      when coalesce(v_r->>'reason', '') = 'already_decided' and v_r->>'status' = 'seated'
      then '⑮ ✅ 已帶到桌的取消不了，而且話術說得出「已經帶到桌了」'
      else '⑮ 🔴 預期 already_decided/seated，實際 ' || coalesce(v_r::text, 'null') end;

    /* ── ⑯ 🔴 過期的預約要被收掉，容量才還得回來 ───
       不收的話它會**永遠佔著那個時段**，而症狀是
       「明明沒人訂卻說滿了」—— 一個沒有人查得出原因的拒絕。
       ⚠ 這裡直接改 `play_at` 把時間推到過去（整份會回滾），
         因為「等 24 小時」在測試裡不是一個選項。 */
    select k.id into v_k2 from public.bookings k
     where k.store_id = v_store and k.status = 'booked' and k.table_count = 10 limit 1;
    if v_k2 is null then
      v_msg := v_msg || E'\n⑯ ⚪ 找不到第 ⑦ 格那筆 10 桌的預約 —— 過期那一格測不了';
    else
      update public.bookings
         set play_at = now() - interval '2 days', planned_hours = 2
       where id = v_k2;
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_la, 'role', 'authenticated')::text, true);
      v_r := public.booking_capacity_tx(v_store, v_t3, 5);
      select k.status into v_stat from public.bookings k where k.id = v_k2;
      v_msg := v_msg || E'\n' || case when v_stat = 'expired' and (v_r->>'booked')::int = 0
        then '⑯ ✅ 過了時間的預約被收成 expired，那個時段的容量回到 ' || (v_r->>'free')
        else '⑯ 🔴 狀態＝' || coalesce(v_stat, 'null')
             || '，已訂 ' || coalesce(v_r->>'booked', '?') || '（預期 expired 與 0）' end;
    end if;

    raise exception 'migi_rollback';

  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_msg := v_msg || E'\n🔴 中途拋出例外：' || sqlerrm;
    end if;
    perform set_config('request.jwt.claims', '', true);
    perform set_config('migi.chk', v_msg, true);
  end;
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息')
       || E'\n\n── 回滾確認（交易外的真實狀態）──'
       || E'\n⑰ ' || case when (select count(*) from public.bookings) = 0
                          then '✅ 預約一筆都沒有留下'
                          else '🔴 留下了 ' || (select count(*)::text from public.bookings) || ' 筆' end
       || E'\n⑱ ' || case when (select count(*) from public.teams) = 0
                          then '✅ 探針團一列都沒有留下'
                          else '🔴 留下了 ' || (select count(*)::text from public.teams) || ' 個團' end
       as "驗證";
