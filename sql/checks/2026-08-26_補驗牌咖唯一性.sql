/* ============================================================
   補驗：刪掉 uq_buddy_pair 之後，uq_buddies 真的還在擋重複
   2026-08-26 · 交易內測試，會回滾，不留資料

   ── 為什麼要補 ──────────────────────────────────────
   2026-08-26_刪掉重複的牌咖唯一索引.sql 的第 ⑤ 項失敗了，
   但**失敗原因與改動無關**：
       violates check constraint "mahjong_buddies_origin_check"
   —— 我在測試裡寫 origin = 'manual'，而那不在允許值裡。

   🔴 這與硬規則 3.8 是同一個病的另一面：
     3.8 是「不要猜約束的**內容**」，這次是「不要猜約束允許的**值**」。
     ⚠ 而我今天讀過那張表的定義（M0 第 495–505 行），
       只是 origin 的 check 在我沒讀到的上面幾行 —— **讀一半比沒讀更危險**。

   ── 這次的做法：從約束本身把值取出來 ────────────────
   不再猜，用 regexp 從 `pg_get_constraintdef` 抓第一個合法值。
   ✅ 這樣就算日後允許值改了，測試也不會壞。

   ── 為什麼一定要補這一次 ────────────────────────────
   「刪掉一個唯一索引」最壞的結果不是少一個索引，
   是**唯一性沒了而且沒人發現** —— 那要等到有兩筆重複的牌咖關係、
   而且有人剛好注意到，才會被發現。
   ⚠ `indisunique = true` 且 `indisvalid = true` 幾乎可以確定它在擋，
     但硬規則 7 說的是「看到它動」，不是「推論它應該會動」。
   ============================================================ */

do $$
declare
  v_a uuid; v_b uuid; v_org uuid; v_origin text;
begin
  /* ★ 合法的 origin 從約束定義裡撈出來，不要猜。
     pg_get_constraintdef 會給類似
       CHECK ((origin = ANY (ARRAY['xxx'::text, 'yyy'::text])))
     這裡抓第一個帶引號的字面值。 */
  select (regexp_matches(pg_get_constraintdef(c.oid), '''([a-zA-Z0-9_]+)''::text'))[1]
    into v_origin
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
   where t.relnamespace = 'public'::regnamespace
     and t.relname = 'mahjong_buddies' and c.contype = 'c'
     and pg_get_constraintdef(c.oid) ilike '%origin%'
   limit 1;

  select m.id, m.org_id into v_a, v_org from members m
   where m.deleted_at is null order by m.created_at limit 1;
  select m.id into v_b from members m
   where m.deleted_at is null and m.id <> v_a order by m.created_at limit 1;

  if v_a is null or v_b is null or v_origin is null then
    perform set_config('migi.b2',
      '⚠ 跳過：會員不足或撈不到合法 origin（origin=' ||
      coalesce(v_origin, 'null') || '）', true);
    return;
  end if;

  begin
    insert into mahjong_buddies(org_id, member_id, buddy_id, origin)
    values (v_org, v_a, v_b, v_origin);
    -- 第二筆完全一樣：唯一索引應該擋下來
    insert into mahjong_buddies(org_id, member_id, buddy_id, origin)
    values (v_org, v_a, v_b, v_origin);
    perform set_config('migi.b2',
      '🔴 重複的牌咖關係插得進去 —— 唯一性沒了（origin=' || v_origin || '）', true);
    raise exception 'rollback_on_purpose';
  exception
    when unique_violation then
      /* ⚠ 訊息設在處理器裡（硬規則 3.9）—— 設在成功路徑上再 raise 會被回滾。 */
      perform set_config('migi.b2',
        '✅ uq_buddies 擋住了重複（用 origin=' || v_origin || ' 測）', true);
    when others then
      if sqlerrm = 'rollback_on_purpose' then
        null;
      else
        perform set_config('migi.b2', '🔴 測試出錯：' || sqlerrm, true);
      end if;
  end;
end $$;

select 序, 項目, 內容 from (

  /* ① 把 origin 的允許值印出來 —— 這是我猜錯的那個，記下來免得再猜 */
  select 1 as 序, '① mahjong_buddies 的 CHECK' as 項目,
         c.conname || '　' || pg_get_constraintdef(c.oid) as 內容
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
   where t.relnamespace = 'public'::regnamespace
     and t.relname = 'mahjong_buddies' and c.contype = 'c'

  union all
  select 2, '② 唯一性補驗',
         coalesce(current_setting('migi.b2', true), '🔴 DO 區塊沒執行')

  union all
  select 3, '③ 牌咖筆數（確認回滾乾淨）',
         (select count(*)::text || ' 列' from mahjong_buddies)

) x order by 序, 項目;
