/* ============================================================
   查：測試帳號有沒有污染營運數據
   2026-08-26 · 唯讀

   ── 起因 ────────────────────────────────────────────
   使用者要接 LINE，四個測試帳號會拿到真實 LINE ID，問會不會污染。

   ✅ 綁 LINE 本身不會 —— is_test 是 members 的欄位，與 LINE ID 無關。
   🔴 但查證 set_is_test_from_store() 全文後發現一個**同型但更嚴重**的洞：

       if NEW.store_id is not null then
         select coalesce(s.is_test, false) into NEW.is_test
           from stores s where s.id = NEW.store_id;
       end if;

     **它只問門市，不問會員。** 而 orders / table_sessions 都掛這支觸發器。
     → 測試帳號在**正式門市**消費，orders.is_test = false
       → **那筆假的錢會被算進真實營收**。

   ⚠ 這與 2026-08-26 早上修掉的埋點漏洞是同一個形狀（只認一個訊號），
     但嚴重得多：埋點錯了是分析數字歪，**訂單錯了是財報數字歪**。

   這支查的是「有沒有已經發生」以及「規模多大」。
   ============================================================ */

select 序, 項目, 內容 from (

  /* ① 門市盤點：哪幾間是測試的 */
  select 1 as 序, '① 門市' as 項目,
         s.name || '　' || (case when coalesce(s.is_test,false) then '🧪 測試' else '營運' end) as 內容
    from stores s

  union all
  /* ② 測試會員盤點：幾個、有沒有已經綁 LINE */
  select 2, '② 測試會員',
         m.display_name || '　' ||
         (case when m.line_user_id is null then '未綁 LINE' else '已綁 LINE' end) ||
         '　tier=' || coalesce(m.tier, '?')
    from members m
   where coalesce(m.is_test, false) and m.deleted_at is null

  union all
  /* ③ 🔴 核心問題：測試會員的訂單，有幾筆被標成「非測試」 */
  select 3, '③ 測試會員的訂單怎麼標的',
         (case when coalesce(o.is_test,false) then '✅ 標為測試' else '🔴 標為營運（會進營收）' end)
         || '：' || count(*)::text || ' 筆　金額合計 ' || coalesce(sum(o.payable),0)::text
    from orders o
    join members m on m.id = o.member_id
   where coalesce(m.is_test, false)
   group by coalesce(o.is_test,false)

  union all
  /* ④ 反過來也要看：正式會員在測試門市的訂單
        —— 那些被標成測試是對的（門市是假的），但確認一下有沒有這種資料。 */
  select 4, '④ 正式會員在測試門市',
         count(*)::text || ' 筆'
    from orders o
    join members m on m.id = o.member_id
    join stores s on s.id = o.store_id
   where not coalesce(m.is_test,false) and coalesce(s.is_test,false)

  union all
  /* ⑤ 同一個洞在別的表：哪些表掛了 set_is_test_from_store()
        —— 要修的話是一起修，不是只修 orders。 */
  select 5, '⑤ 掛 set_is_test_from_store 的表',
         t.relname || '.' || tg.tgname
    from pg_trigger tg
    join pg_class t on t.oid = tg.tgrelid
    join pg_proc p on p.oid = tg.tgfoid
   where not tg.tgisinternal
     and p.proname = 'set_is_test_from_store'

  union all
  /* ⑥ v_real_* 檢視表到底怎麼濾的
        —— CLAUDE.md 說有四個，先確認它們存在且濾的是 is_test。 */
  select 6, '⑥ v_real_* 檢視表',
         c.relname
    from pg_class c
   where c.relnamespace = 'public'::regnamespace
     and c.relkind = 'v' and c.relname like 'v_real%'

  union all
  /* ⑦ 有沒有重複的人（同名或同手機）——
        接 LINE 之後若走註冊而不是綁定，會多出一批。
        先看現在的基準值，之後對照才知道有沒有長出來。 */
  select 7, '⑦ 會員總數與手機重複',
         '總計 ' || count(*)::text || ' 人　'
         || '測試 ' || count(*) filter (where coalesce(is_test,false))::text || ' 人　'
         || '已綁 LINE ' || count(*) filter (where line_user_id is not null)::text || ' 人　'
         || '手機重複 ' ||
            (select coalesce(count(*),0) from (
               select phone from members
                where phone is not null and deleted_at is null
                group by phone having count(*) > 1) d)::text || ' 組'
    from members
   where deleted_at is null

) x order by 序, 項目, 內容;
