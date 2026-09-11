/* ============================================================
   驗「一起打了 N 場」：整桌都是團員才算
   2026-09-11 · **在交易裡真的建一個團，最後整份回滾**

   ── 為什麼非要行為測試不可 ────────────────────────
   `2026-09-11_牌咖團地基.sql` 的驗證段第 ⑥ 格只證明
   「函式跑得動、欄位名都對得上」—— 它回 0 列是必然的（那時還沒有團）。
   🔴 **而「回 0 列」同時是「規則正確」與「規則寫壞了」的症狀**
     （硬規則 3.55）。只驗那一半等於沒驗。

   而這支特別需要正對照，因為它**算錯不會有任何症狀**：
   ```
   規則寫鬆了 → 兩個團員加兩個陌生人那桌被算進團的戰績
              → 團的總場數偏高，而沒有任何地方會說為什麼
   規則寫緊了 → 一場都算不到，而畫面只會顯示「一起打了 0 場」，
                跟「真的還沒一起打過」長得一模一樣
   ```

   ── 這份會寫入，但一列都留不下來 ─────────────────
   `raise exception 'migi_rollback'` 讓整段退掉。
   🔴 訊息一定要設在 exception handler 裡 —— 寫在 raise 之前的
     `set_config(..., true)` 會跟著被回滾（硬規則 3.9）。
   ⚠ 這份**不歸檔到 `applied/`**，它不是 migration。

   ── 取樣完全由資料自己決定，不寫死任何 uuid ──────────
   🔴 硬規則 3.57：驗證段去借線上的資料就會跟真實世界賽跑。
     寫死 `d0000000-…-0009` 的話，那批 fixture 被清掉的那天
     這份會紅，而**表面症狀是「函式壞了」**，會讓人去改一個對的東西。
   ⇒ 改成用**形狀**取樣：
   ```
   團     ＝ 某一場人最多的場次，它的那幾個人
   純團桌 ＝ 在座的人全部都在團裡
   混桌   ＝ 在座有人不在團裡
   單人場 ＝ 只有一個人（驗下限 2）
   ```
   ⚠ 取不到樣本要**出聲**，不要 `if … then` 安靜跳過
     —— 2026-09-04 那次兩格沒出現，我以為全過。

   ── 期望值也不寫死 ────────────────────────────────
   🔴 硬規則 3.56：紅了先懷疑期望值。所以「入團時間」「退團時間」
     那兩格的期望值是**當場從基準清單算出來的**，不是我數的。
   ============================================================ */

/* ⚠ 先把「現在有幾場作廢」記下來，最後那一格拿它比對。
   🔴 不可以在最後寫死一個數字 —— 那是今天的線上狀態，
     有人作廢一場之後這一格就會紅，而症狀會是「規則壞了」（硬規則 3.57）。 */
select set_config('migi.voided0',
       (select count(*)::text from public.table_sessions where status = 'voided'), true);

do $$
declare
  v_msg     text := '';
  v_org     uuid;
  v_team    uuid;
  v_pure    uuid;          -- 整桌都是團員的那一場
  v_mixed   uuid;          -- 混了非團員的那一場
  v_solo    uuid;          -- 只有一個人的那一場
  v_base    int;           -- 基準：算得到幾場
  v_now     int;
  /* 🔴 兩個期望值必須在**任何改動之前**一次算完，見 ⑤⑥ 上面那段。 */
  v_want_hi int;           -- 切點之後（含）有幾場 → ⑤ 的預期
  v_want_lo int;           -- 切點之前有幾場     → ⑥ 的預期
  v_mid     timestamptz;   -- 早晚兩場之間的切點
  v_lo      timestamptz;
  v_hi      timestamptz;
  v_leader  uuid;
  v_other   uuid;
  v_stat0   text;          -- 樣本場次本來的狀態（⑦ 要原樣還原）
begin
  begin
    /* ── 取樣 ─────────────────────────────────────── */
    /* 人最多的那一場（同票時取最早的，讓結果穩定）。 */
    select ts.id, ts.org_id
      into v_pure, v_org
      from public.table_sessions ts
      join public.session_players sp on sp.session_id = ts.id
     where ts.deleted_at is null and ts.status <> 'voided'
     group by ts.id, ts.org_id
     order by count(*) desc, min(sp.joined_at)
     limit 1;

    if v_pure is null then
      v_msg := '🔴 取樣失敗：找不到任何有玩家的場次 —— 這份測不出東西';
      raise exception 'migi_rollback';
    end if;

    /* 建團。團員 ＝ 那一場的所有在座玩家。
       `joined_at` 先推到很早，讓基準那一格不受時間區間影響。 */
    select sp.member_id into v_leader
      from public.session_players sp where sp.session_id = v_pure
     order by sp.joined_at limit 1;

    insert into public.teams (org_id, name, crest_emoji, created_by, join_policy)
    values (v_org, '＿探針團＿', '🐻', v_leader, 'closed')
    returning id into v_team;

    insert into public.team_members (org_id, team_id, member_id, role, joined_at)
    select v_org, v_team, sp.member_id,
           case when sp.member_id = v_leader then 'leader' else 'member' end,
           timestamptz '2000-01-01'
      from public.session_players sp
     where sp.session_id = v_pure;

    /* 混桌：在座有人不在團裡，而且至少兩個人。 */
    select ts.id into v_mixed
      from public.table_sessions ts
      join public.session_players sp on sp.session_id = ts.id
     where ts.deleted_at is null and ts.status <> 'voided'
     group by ts.id
    having count(*) >= 2
       and count(*) <> count(*) filter (
             where exists (select 1 from public.team_members tm
                            where tm.team_id = v_team and tm.member_id = sp.member_id
                              and tm.left_at is null))
     order by ts.id limit 1;

    /* 單人場。 */
    select ts.id into v_solo
      from public.table_sessions ts
      join public.session_players sp on sp.session_id = ts.id
     where ts.deleted_at is null and ts.status <> 'voided'
     group by ts.id having count(*) = 1
     order by ts.id limit 1;

    /* ── ① 基準：算得到幾場，而且不可以是 0 ─────────── */
    select count(*) into v_base from public._team_session_ids(v_team);
    v_msg := v_msg || case when v_base > 0
      then '① ✅ 基準：這個團算得到 ' || v_base || ' 場（正對照 —— 不是 0）'
      else '① 🔴 基準是 0 場 —— 下面每一格「不該算到」都會假性通過' end;

    /* ── ② 純團桌要在清單裡 ──────────────────────── */
    select count(*) into v_now
      from public._team_session_ids(v_team) where session_id = v_pure;
    v_msg := v_msg || E'\n' || case when v_now = 1
      then '② ✅ 整桌都是團員的那一場，算進去了'
      else '② 🔴 整桌都是團員卻沒算到 —— 規則寫得太緊，團的場數會永遠是 0' end;

    /* ── ③ 混了非團員的不可以算 ─────────────────── */
    if v_mixed is null then
      v_msg := v_msg || E'\n③ ⚪ 找不到「混了非團員」的場次 —— 這一格測不了'
                     || '（今天的會員全部都在同一批場次裡）';
    else
      select count(*) into v_now
        from public._team_session_ids(v_team) where session_id = v_mixed;
      v_msg := v_msg || E'\n' || case when v_now = 0
        then '③ ✅ 在座有人不在團裡的那一場，沒有被算進去'
        else '③ 🔴 混桌被算進團的戰績了 —— 那是配桌不是團的活動' end;
    end if;

    /* ── ④ 下限 2：單人場不可以算 ───────────────── */
    if v_solo is null then
      v_msg := v_msg || E'\n④ ⚪ 找不到單人場次 —— 下限那一格測不了';
    else
      select count(*) into v_now
        from public._team_session_ids(v_team) where session_id = v_solo;
      v_msg := v_msg || E'\n' || case when v_now = 0
        then '④ ✅ 只有一個人的場次沒有被算進去（下限 2 有在擋）'
        else '④ 🔴 單人場被算成「一起打了一場」' end;
    end if;

    /* ── ⑤ 入團之前的場次不算 ───────────────────── */
    /* 🔴 這一格與 ⑥ 是這次改動的重點。使用者定的規則是「整桌都是團員」，
       而那讓「有人退團 ⇒ 他參與過的每一場全部失效」變成真的會發生。
       所以資格一定要看**當時**，不是看現在。 */
    select min(played_at), max(played_at) into v_lo, v_hi
      from public._team_session_ids(v_team);

    if v_lo = v_hi then
      v_msg := v_msg || E'\n⑤⑥ ⚪ 算得到的場次時間全部相同（' || to_char(v_lo,'MM-DD HH24:MI')
                     || '）—— 時間區間那兩格今天分不出來';
    else
      v_mid := v_lo + (v_hi - v_lo) / 2;

      /* 🔴 兩個期望值都在這裡算完，**在 ⑤ 動 `joined_at` 之前**。
         ⚠ 2026-09-11 第一次跑就踩了：⑥ 的期望值原本寫在 ⑤ 後面，
           而那時 `_team_session_ids` 已經只剩晚的那一場
           ⇒ 再用「切點之前」過濾就是 0，於是 ⑥ 報紅。
           **函式完全正確，錯的是腳本**（硬規則 3.56 那一族），
           而根因是硬規則 3.57 那條「每一格開始前重建自己的前提」
           —— 那句話就寫在這份檔案的抬頭，我寫完接著踩它。 */
      select count(*) filter (where played_at >= v_mid),
             count(*) filter (where played_at <  v_mid)
        into v_want_hi, v_want_lo
        from public._team_session_ids(v_team);

      update public.team_members set joined_at = v_mid where team_id = v_team;
      select count(*) into v_now from public._team_session_ids(v_team);
      v_msg := v_msg || E'\n' || case when v_now = v_want_hi
        then '⑤ ✅ 把入團時間推到 ' || to_char(v_mid,'MM-DD HH24:MI')
             || ' ⇒ ' || v_base || ' 場剩 ' || v_now || ' 場（之前的不算，算式對得上）'
        else '⑤ 🔴 入團時間之前的場次還在算：得到 ' || v_now || '，預期 ' || v_want_hi end;

      /* ── ⑥ 退團之後的場次不算（⑤ 的鏡像）───────── */
      -- ⚠ 先把入團時間還原，否則這一格量到的是兩個條件疊加的結果。
      update public.team_members
         set joined_at = timestamptz '2000-01-01', left_at = v_mid, left_reason = 'quit'
       where team_id = v_team;
      select count(*) into v_now from public._team_session_ids(v_team);
      v_msg := v_msg || E'\n' || case when v_now = v_want_lo
        then '⑥ ✅ 把退團時間設在 ' || to_char(v_mid,'MM-DD HH24:MI')
             || ' ⇒ 剩 ' || v_now || ' 場（之後的不算）'
        else '⑥ 🔴 退團之後的場次還在算：得到 ' || v_now || '，預期 ' || v_want_lo end;

      update public.team_members
         set joined_at = timestamptz '2000-01-01', left_at = null, left_reason = null
       where team_id = v_team;
    end if;

    /* ── ⑦ 作廢的場次不算 ───────────────────────── */
    /* ⚠ 線上 101 場 voided 全部沒有玩家，所以借不到現成樣本
       —— 只能把一場真的改成 voided 再看它掉出去（反正整份會回滾）。 */
    /* 🔴 還原要寫回**它本來的值**，不可以寫死 'completed' ——
       取樣挑到的很可能是一場 `open`。整份反正會回滾所以看不出來，
       而那正是這種錯活得久的原因。 */
    select count(*) into v_base from public._team_session_ids(v_team);
    select ts.status into v_stat0 from public.table_sessions ts where ts.id = v_pure;
    update public.table_sessions set status = 'voided' where id = v_pure;
    select count(*) into v_now from public._team_session_ids(v_team);
    update public.table_sessions set status = v_stat0 where id = v_pure;
    v_msg := v_msg || E'\n' || case when v_now = v_base - 1
      then '⑦ ✅ 把那一場改成作廢 ⇒ ' || v_base || ' 場剩 ' || v_now || ' 場'
      else '⑦ 🔴 作廢的場次還在算：' || v_base || ' → ' || v_now || '（預期少 1）' end;

    /* ── ⑧ 一團只能有一個團長 ──────────────────── */
    /* 🔴 這道牆沒有的話，轉讓團長寫錯順序會**安靜地**生出兩個團長，
       而畫面上兩個人都會看到團長的按鈕。 */
    select sp.member_id into v_other
      from public.session_players sp
     where sp.session_id = v_pure and sp.member_id <> v_leader
     limit 1;
    if v_other is null then
      v_msg := v_msg || E'\n⑧ ⚪ 那一場只有一個人，第二個團長測不了';
    else
      begin
        update public.team_members set role = 'leader'
         where team_id = v_team and member_id = v_other;
        v_msg := v_msg || E'\n⑧ 🔴 一個團出現兩個團長而且沒有被擋下來';
      exception when unique_violation then
        v_msg := v_msg || E'\n⑧ ✅ 第二個團長被唯一索引擋下來了';
      end;
    end if;

    /* ── ⑨ 同一個人不可以重複在同一個團 ──────────── */
    begin
      insert into public.team_members (org_id, team_id, member_id, role)
      values (v_org, v_team, v_leader, 'member');
      v_msg := v_msg || E'\n⑨ 🔴 同一個人在團裡出現兩列而且沒有被擋下來';
    exception when unique_violation then
      v_msg := v_msg || E'\n⑨ ✅ 重複加入被唯一索引擋下來了';
    end;

    /* ── ⑩ 離開了要有理由，沒離開不可以有理由 ────── */
    /* ⚠ 少了這道牆，`left_at` 有值而理由是 null 的列會慢慢長出來，
       而那種列在日後的流失分析裡是永遠查不出原因的一格。 */
    begin
      update public.team_members set left_at = now()
       where team_id = v_team and member_id = v_leader;
      v_msg := v_msg || E'\n⑩ 🔴 離開了卻沒有理由，沒有被擋下來';
    exception when check_violation then
      v_msg := v_msg || E'\n⑩ ✅ 「離開了卻沒有理由」被 CHECK 擋下來了';
    end;

    raise exception 'migi_rollback';

  exception when others then
    /* ⚠ 只有自己丟的那個字串是「刻意回滾」。其餘一律當成真的錯誤 ——
       把例外吞掉只記「失敗了」，會讓「腳本寫錯」偽裝成「規則寫錯」
       （2026-09-09 那次真的發生過，20 張表全部印成「拒絕」）。 */
    if sqlerrm <> 'migi_rollback' then
      v_msg := v_msg || E'\n🔴 中途拋出例外：' || sqlerrm;
    end if;
    perform set_config('migi.chk', v_msg, true);
  end;
end $$;

/* ⚠ 下面是**交易外的真實狀態**：探針團一列都不可以留下來。
   🔴 這一格不是形式 —— `teams` 有「團名同 org 唯一」的索引，
     留下來的話下一次跑這份會直接撞唯一鍵，而症狀是
     「規則壞了」而不是「上次沒收乾淨」。 */
select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息')
       || E'\n\n── 回滾確認（交易外的真實狀態）──'
       || E'\n⑪ ' || case
            when (select count(*) from public.teams) = 0
             and (select count(*) from public.team_members) = 0
            then '✅ 探針團一列都沒有留下'
            else '🔴 留下了 teams ' || (select count(*)::text from public.teams)
                 || ' 列 · team_members ' || (select count(*)::text from public.team_members)
                 || ' 列 —— 手動刪掉再重跑' end
       || E'\n⑫ ' || case
            when (select count(*)::text from public.table_sessions where status = 'voided')
                 = current_setting('migi.voided0', true)
            then '✅ 作廢場次還是跑之前那個數字（'
                 || current_setting('migi.voided0', true) || ' 場）—— ⑦ 那個 update 確實退掉了'
            else '🔴 作廢場次從 ' || coalesce(current_setting('migi.voided0', true), '?')
                 || ' 變成 '
                 || (select count(*)::text from public.table_sessions where status = 'voided')
                 || ' —— ⑦ 改到真的資料了' end
       as "驗證";
