/* ============================================================
   清除測試戰績（回到「還沒打過」的樣子）　常駐工具 · MIGI
   ⚠ 造資料用同一個資料夾的 `測試戰績_造.sql`。

   ── 🔴 2026-09-01 修過一次：不要寫死會員 id ──────────
   第一版把四個會員 id 抄自 CLAUDE.md（那句話已經漂掉了），
   所以它重設的是**跟造的那一組不同的人**。
   → 現在**先從那三場裡撈出有誰**，再刪、再重設。
     那組人一定跟造的時候完全一致，不需要任何比對規則。

   ── 只刪自己造的東西 ────────────────────────────────
   認的是那三個**固定 UUID**（`d0000000-…-0001/2/3`）——
   不是「刪掉所有測試場次」，所以**不可能誤刪別的東西**。

   ── 🔴 重設分數之前先確認沒有別的戰績 ────────────────
   把 `rating` 打回 0、`rank` 打回 null 是「還沒打過」的狀態。
   但如果那些帳號**還有別的已結算場次**，打回 0 就是**把真的紀錄抹掉**。
   → 刪完之後**先數**，還有別的就**拒絕重設**並告訴你有幾筆。
   ⚠ 這是 fail-safe：不重設只是「分數還留著」，不會弄壞東西；
     反過來硬重設才是不可逆的。
   ============================================================ */

do $$
declare
  v_sids uuid[] := array['d0000000-0000-0000-0000-000000000001'::uuid,
                         'd0000000-0000-0000-0000-000000000002'::uuid,
                         'd0000000-0000-0000-0000-000000000003'::uuid];
  v_ids uuid[]; v_sp int; v_ts int; v_left int; v_msg text; v_who text;
begin
  /* 🎯 **先撈出「那三場裡有誰」** —— 刪掉之後就查不到了。 */
  select array_agg(distinct member_id) into v_ids
    from session_players where session_id = any(v_sids);

  select string_agg(display_name, '、' order by display_name) into v_who
    from members where id = any(coalesce(v_ids, '{}'::uuid[]));

  delete from session_players where session_id = any(v_sids);
  get diagnostics v_sp = row_count;
  delete from table_sessions where id = any(v_sids);
  get diagnostics v_ts = row_count;

  if coalesce(array_length(v_ids, 1), 0) = 0 then
    v_msg := '⚠ 那三場不存在 —— 沒有東西要清（可能已經清過了）。';
  else
    /* 🔴 還有別的已結算場次嗎？有就不要碰分數。 */
    select count(*) into v_left
      from session_players
     where member_id = any(v_ids) and finish_rank is not null;

    if v_left > 0 then
      v_msg := '🔴 這些人還有 ' || v_left || ' 列別的已結算戰績 —— **沒有重設分數**。'
            || '那些不是這支工具造的，打回 0 會抹掉真的紀錄。';
    else
      update members set rating = 0, rating_games = 0, rank = null
       where id = any(v_ids);
      v_msg := '✅ 「' || coalesce(v_who,'?') || '」已回到「還沒打過」（rating 0 · rank null）';
    end if;
  end if;

  perform set_config('migi.clean',
    '刪除 session_players ' || v_sp || ' 列、table_sessions ' || v_ts || ' 列' ||
    E'\n' || v_msg, true);
end $$;

-- ── 結果 ─────────────────────────────────────────────
select current_setting('migi.clean', true) as 清除結果;

/* 順便印出**所有測試帳號**的現況 —— 這樣可以一眼看出
   「該歸零的歸零了、不該動的沒被動到」。
   ⚠ 不寫死 id（第一版就是寫死才印錯人）。 */
select m.display_name as 會員,
       m.phone        as 手機,
       m.rating       as 分數,
       coalesce(m.rank, '尚未定位') as 段位,
       m.rating_games as 打過幾將,
       (select count(*) from session_players sp
         where sp.member_id = m.id and sp.finish_rank is not null) as 還剩幾場已結算,
       (m.line_user_id is not null) as 綁了LINE
  from members m
 where m.org_id = '11111111-1111-1111-1111-111111111111'
   and m.deleted_at is null and m.is_test
 order by m.created_at;
