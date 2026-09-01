/* ============================================================
   清除測試戰績（回到「還沒打過」的樣子）　常駐工具 · MIGI
   ⚠ 造資料用同一個資料夾的 `測試戰績_造.sql`。

   ── 只刪自己造的東西 ────────────────────────────────
   認的是那三個**固定 UUID**（`d0000000-…-0001/2/3`）——
   不是「刪掉所有測試場次」，所以**不可能誤刪別的東西**。

   ── 🔴 重設分數之前先確認沒有別的戰績 ────────────────
   把 `rating` 打回 0、`rank` 打回 null 是「還沒打過」的狀態。
   但如果那四個帳號**還有別的已結算場次**（例如日後真的打了），
   打回 0 就是**把真的紀錄抹掉**。
   → 所以刪完之後**先數**，還有別的就**拒絕重設**並告訴你有幾筆。
   ⚠ 這是 fail-safe：不重設只是「分數還留著」，不會弄壞東西；
     反過來硬重設才是不可逆的。
   ============================================================ */

do $$
declare
  v_sids uuid[] := array['d0000000-0000-0000-0000-000000000001'::uuid,
                         'd0000000-0000-0000-0000-000000000002'::uuid,
                         'd0000000-0000-0000-0000-000000000003'::uuid];
  v_ids uuid[] := array['d73fdac2-d6b9-4b8a-bcff-b19c2786056f'::uuid,  -- 測試01（創辦人）
                        '218378e1-fb6c-43fb-b642-99fdbf5c52b1'::uuid,  -- 測試02
                        'd0db928e-5a75-4535-90d4-93ede67790a8'::uuid,  -- 測試03
                        '526aa8b9-cc93-4327-b878-6d21d399af8e'::uuid]; -- 測試04
  v_sp int; v_ts int; v_left int; v_msg text;
begin
  delete from session_players where session_id = any(v_sids);
  get diagnostics v_sp = row_count;
  delete from table_sessions where id = any(v_sids);
  get diagnostics v_ts = row_count;

  /* 🔴 還有別的已結算場次嗎？有就不要碰分數。 */
  select count(*) into v_left
    from session_players
   where member_id = any(v_ids) and finish_rank is not null;

  if v_left > 0 then
    v_msg := '🔴 還有 ' || v_left || ' 列別的已結算戰績 —— **沒有重設分數**。'
          || '那些不是這支工具造的，打回 0 會抹掉真的紀錄。';
  else
    update members
       set rating = 0, rating_games = 0, rank = null
     where id = any(v_ids);
    v_msg := '✅ 四個測試帳號已回到「還沒打過」（rating 0 · rank null）';
  end if;

  perform set_config('migi.clean',
    '刪除 session_players ' || v_sp || ' 列、table_sessions ' || v_ts || ' 列' ||
    E'\n' || v_msg, true);
end $$;

-- ── 結果 ─────────────────────────────────────────────
select current_setting('migi.clean', true) as 清除結果;

select m.display_name as 會員,
       m.rating       as 分數,
       coalesce(m.rank, '尚未定位') as 段位,
       m.rating_games as 打過幾將,
       (select count(*) from session_players sp
         where sp.member_id = m.id and sp.finish_rank is not null) as 還剩幾場已結算
  from members m
 where m.id in ('d73fdac2-d6b9-4b8a-bcff-b19c2786056f',
                '218378e1-fb6c-43fb-b642-99fdbf5c52b1',
                'd0db928e-5a75-4535-90d4-93ede67790a8',
                '526aa8b9-cc93-4327-b878-6d21d399af8e')
 order by m.display_name;
