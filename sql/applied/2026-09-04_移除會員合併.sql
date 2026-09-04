/* ============================================================
   移除會員合併（`merge_members_tx` ＋ `member_merges`）
   2026-09-04 · MIGI · 待辦 15 退回設計稿

   ── 為什麼移除 ──────────────────────────────────────
   🔴 **順序錯了：SQL 是在「判斷該不該做」之前就寫完的。**
   判斷完的結論是「今天不必要」——
   · 真實客人 **0 個**，5 個會員裡只有 **1 個綁了 LINE**
     ⇒ 重複帳號的前提（兩個都走過 LINE 註冊）**不成立**
   · A3 的洞 2026-08-30 已堵、E 也已經有自助認領
   · 而且合併要三步（① 發現是同一個人 ② migi-admin 有一頁能按 ③ 執行），
     **前兩步都不存在** ⇒ 留著就是「建了沒人讀」

   ⚠ 之後改口說「應該現在跑」的理由是「寫的成本已付、只剩驗證」——
     那個論證本身成立，但它**用沉沒成本掩蓋了前面的順序錯誤**。
     使用者指出了這一點，判斷是對的。

   🔴 **而它現在的狀態是最糟的一種**：第一次跑時驗證段炸在第 ③ 格
     （`table_sessions` 漏了 `mode`），但 DO 區塊的 exception handler
     把錯誤接住了沒往上拋 ⇒ **DDL 照樣提交** ——
     函式在線上、看起來正常、而它的每一行邏輯只被驗到第 ② 格。
     那正是硬規則 7 說的形狀，所以**不能就這樣放著**。

   ── ✅ 真正值錢的東西留著，不在這份裡 ─────────────────
   · `sql/checks/2026-09-04_合併會員前的盤點.sql` —— **留著**
     （25 個外鍵只有 16 個叫 `member_id`、四對自我參照都有 CHECK、
      外鍵 23→25 是同一週自己加表造成的）
   · `sql/_設計稿未落地/2026-09-04_會員合併.sql` —— 完整的實作留著，
     真要用的那天直接跑，**不用重寫**
   · CLAUDE.md 待辦 15 記著觸發條件與那三件盤點結果

   🎯 **這一份刪掉的只是「線上有一支沒人叫得動、而且沒驗完的函式」。**
   ============================================================ */

-- ⚠ 先函式再資料表 —— 函式引用了 `member_merges`。
drop function if exists public.merge_members_tx(uuid, uuid, uuid, uuid, text);

-- ⚠ `drop table` 會一併移除 `uq_member_merges_dropped` 與三個外鍵。
--   ⚠ 不用 `cascade`：如果有東西依賴它，**我要它報錯**而不是連著刪掉。
drop table if exists public.member_merges;


-- ── 驗證 ───────────────────────────────────────────────
do $$
declare v_out text := '';
begin
  v_out := v_out || E'\n' || '① merge_members_tx 已移除' || E'\t' ||
    case when not exists (select 1 from pg_proc
                           where pronamespace='public'::regnamespace
                             and proname='merge_members_tx')
         then '✅' else '🔴 還在' end;

  v_out := v_out || E'\n' || '② member_merges 已移除' || E'\t' ||
    case when to_regclass('public.member_merges') is null then '✅' else '🔴 還在' end;

  /* 🔴 **正對照**：只驗「東西不見了」的話，一份把整個 schema 刪光的 SQL
     也會讓 ①② 變綠。所以要驗**沒有誤傷**。
     ⚠ 期望值是**當場數出來的** —— 今天早上那幾支才剛建立，
       憑印象寫一個數字就是硬規則 3.56 那個坑。 */
  v_out := v_out || E'\n' || '③ 🎯 正對照：同批建立的其他函式都還在' || E'\t' ||
    (select case when count(*) = 5
                 then '✅ migi_jwt_uuid／can／has_store_access／'
                      || 'get_staff_by_line_tx／get_season_leaderboard_tx'
                 else '🔴 只剩 ' || count(*) || ' 支 —— 誤傷了' end
       from pg_proc where pronamespace='public'::regnamespace
        and proname in ('migi_jwt_uuid','can','has_store_access',
                        'get_staff_by_line_tx','get_season_leaderboard_tx'));

  v_out := v_out || E'\n' || '④ 🎯 正對照：members 的外鍵仍是 25 個' || E'\t' ||
    (select case when count(*) = 25 then '✅ 25'
                 else '🔴 ' || count(*) || ' —— member_merges 以外的東西被動到了' end
       from pg_constraint
      where contype='f' and confrelid='public.members'::regclass);

  /* ⑤ 錢包帳本沒有被碰過 —— 那份合併第一版曾經想 UPDATE 它。
     ⚠ 觸發器擋下了，所以理論上一列都沒動；但**理論不算數**。 */
  v_out := v_out || E'\n' || '⑤ 🎯 wallet_txns 的 append-only 守衛還在' || E'\t' ||
    (select case when count(*) = 2 then '✅ no_update ＋ no_delete 都在'
                 else '🔴 只剩 ' || count(*) || ' 個' end
       from pg_trigger
      where tgrelid='public.wallet_txns'::regclass and not tgisinternal);

  perform set_config('migi.rm', v_out, true);
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.rm', true), E'\n')) as x
 where coalesce(x,'') <> '';
