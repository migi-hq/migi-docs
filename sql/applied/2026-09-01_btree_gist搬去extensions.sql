/* ============================================================
   `btree_gist` 從 `public` 搬到 `extensions`　2026-09-01 · MIGI

   ── 🔴 這是修我自己昨天造成的問題 ──────────────────
   `2026-09-01_賽季表.sql` 寫的是：
   ```sql
   create extension if not exists btree_gist;      -- ← 沒指定 schema
   ```
   → 預設就進 **`public`**，而它**帶了 188 支函式進來**。

   歸檔後依硬規則 1.6 重跑現況才發現：
   ```
   public 的函式  157  →  347
   ```
   🔴 **而且那 188 支全部「明確授權給 anon」** —— 不是 PUBLIC 繼承，
     是硬規則 2.6b 記的那條 default privileges：
   ```sql
   alter default privileges in schema public
     grant execute on functions to anon, authenticated, service_role;
   ```
   **在 `public` 新建的每一支函式，一建立就是 anon 叫得動的** ——
   `create extension` 建的也算。

   ── 這個專案的慣例本來就對，是我沒跟 ──────────────
   ```
   pgcrypto / uuid-ossp / pg_stat_statements   →  extensions   ✅
   btree_gist                                  →  public       🔴 只有我這個
   ```

   ── ⚠ 為什麼只搬 schema，不順便收 188 個授權 ────────
   它們是 GiST 的**型別支援函式**（`gbt_int4_compress` 那一類），
   索引掃描時由索引機制自己呼叫。
   🔴 **收掉有可能讓走到那個索引的查詢失敗，而那個失敗會出現在
     完全無關的地方**（任何用到 `rank_seasons` 排除約束的寫入）。
   → 搬 schema 已經達到目的：**它們不在 `public` 了，
     不會出現在函式盤點裡、也不能用不加前綴的名字呼叫**。
     這跟 Supabase 自己擺 `pgcrypto` 的方式一致。
   📌 收授權的收益是「理論上更小的暴露面」，代價是「可能弄壞寫入而且症狀在別處」——
     **不成比例。**

   ⚠ 搬 schema **不會動到既有的排除約束** —— 索引記的是 opclass 的 OID，
     不是名字。但那是推論，所以下面**兩個方向都實測**。
   ============================================================ */

alter extension btree_gist set schema extensions;


-- ── 驗證 ───────────────────────────────────────────────
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_out text := '';
begin
  begin
    v_out := v_out || E'\n' || '① btree_gist 現在在 extensions' || E'\t' ||
      (select case when n.nspname = 'extensions' then '✅ extensions'
                   else '🔴 還在 ' || n.nspname end
         from pg_extension e join pg_namespace n on n.oid = e.extnamespace
        where e.extname = 'btree_gist');

    /* 🔴 期望值是 **159 不是 157** —— 賽季那份自己也新增了 2 支
       （`current_season_tx` / `rating_window_start_tx`）。
       ```
       157 原本  ＋ 2 我寫的  ＋ 188 btree_gist  = 347 現在
       搬完 = 347 − 188 = 159
       ```
       ⚠ 我第一版寫 157，那會**紅得莫名其妙**而且我會去懷疑那個搬移動作。
         同這個 session 前面測 ㉖㉗ 那次：**函式是對的，是期望值算錯。** */
    v_out := v_out || E'\n' || '② public 的函式數回到 159' || E'\t' ||
      (select case when count(*) = 159 then '✅ 159（157 原本 ＋ 2 這批新增）'
                   else '🔴 ' || count(*) || '（搬之前 347）' end
         from pg_proc where pronamespace = 'public'::regnamespace and prokind = 'f');

    v_out := v_out || E'\n' || '③ 排除約束還在' || E'\t' ||
      (select coalesce(max(case when contype = 'x' then '✅ ' || conname end), '🔴 不見了')
         from pg_constraint where conrelid = 'rank_seasons'::regclass);

    /* 🔴 **「約束還在」不等於「約束還有效」** —— 索引可能被搬壞而
       變成 INVALID：存在、看得到、完全不擋，**而且沒有任何症狀**
       （同 `uq_members_line_user` 那一節記的）。所以一定要真的插一次。 */
    begin
      insert into rank_seasons (code, org_id, label, starts_at, ends_at)
      values ('X重疊', v_org, '測試', '2026-12-01+08', '2027-02-01+08');
      v_out := v_out || E'\n' || '④ 搬完之後重疊還是被擋' || E'\t' || '🔴 竟然插進去了 —— 約束失效';
    exception when exclusion_violation then
      v_out := v_out || E'\n' || '④ 搬完之後重疊還是被擋' || E'\t' || '✅ 擋下（exclusion_violation）';
    end;

    /* 正對照：不重疊的要插得進去 —— 少了這一格，
       一個「什麼都插不進去」的壞索引也會讓 ④ 變綠。 */
    begin
      insert into rank_seasons (code, org_id, label, starts_at, ends_at)
      values ('X不重疊', v_org, '測試', '2027-07-01+08', '2028-01-01+08');
      v_out := v_out || E'\n' || '⑤ 正對照：不重疊的還是插得進去' || E'\t' || '✅ 插入成功';
    exception when others then
      v_out := v_out || E'\n' || '⑤ 正對照：不重疊的還是插得進去' || E'\t' || '🔴 被擋了：' || sqlerrm;
    end;

    v_out := v_out || E'\n' || '⑥ 正對照：兩季種子沒被動到' || E'\t' ||
      (select case when count(*) = 2 then '✅ ' || string_agg(code, '、' order by code)
                   else '🔴 ' || count(*) end
         from rank_seasons where org_id = v_org and code in ('2026H2','2027H1'));

    v_out := v_out || E'\n' || '⑦ 正對照：current_season_tx 還答得出來' || E'\t' ||
      coalesce('✅ ' || (public.current_season_tx(v_org) ->> 'label'), '🔴 null');

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.gist', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.gist', true), E'\n')) as x
 where coalesce(x,'') <> '';
