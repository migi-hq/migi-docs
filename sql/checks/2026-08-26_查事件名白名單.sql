/* ============================================================
   查：app_events.event 的白名單長什麼樣
   2026-08-26 · 唯讀

   起因：2026-08-26_埋點補門市與測試隔離.sql 的煙霧測試失敗 ——
       violates check constraint "app_events_event_check"
   → 事件名是 CHECK 白名單，不能自己發明。

   ⚠ 結構驗過了（欄位、簽名、版本數、GRANT 都 ✅），
     但**「門市判定 is_test」那段邏輯一次都沒真的跑過**。
     硬規則 7：CREATE FUNCTION 沒報錯不等於函式能用。

   要決定的事：POS 的事件名怎麼進去。
     · 白名單短 → 直接擴充 CHECK（一次 migration）
     · 白名單長／常變 → 改成 app_event_types 註冊表（事件變成資料）
   看到實際內容再決定，不要先選形狀。
   ============================================================ */

select 序, 項目, 內容 from (

  /* ① CHECK 的完整定義 —— 允許哪些字 */
  select 1 as 序, '① app_events 的 CHECK' as 項目,
         c.conname || '　' || pg_get_constraintdef(c.oid) as 內容
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
   where t.relnamespace = 'public'::regnamespace
     and t.relname = 'app_events' and c.contype = 'c'

  union all
  /* ② 實際出現過的事件名與筆數
        ⚠ 跟 ① 對照：白名單裡有、但一筆都沒有的，是「埋了沒發生」或「白名單多寫」；
          兩邊對不上就代表白名單已經在漂。 */
  select 2, '② 實際出現過的事件',
         e.event || '：' || count(*)::text || ' 筆'
    from app_events e group by e.event

  union all
  /* ③ 其他表有沒有同樣的「事件名白名單」形狀
        —— 如果只有這一張，擴充 CHECK 就好；
           如果好幾張都這樣，那是一個模式，值得統一成註冊表。 */
  select 3, '③ 還有哪些 CHECK 在管字串白名單（前 10 個）',
         t.relname || '.' || c.conname
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
   where t.relnamespace = 'public'::regnamespace
     and c.contype = 'c'
     and pg_get_constraintdef(c.oid) ilike '%= ANY (ARRAY[%'
     and t.relname in ('app_events','member_interactions','wallet_txns',
                       'orders','match_queues','notifications','app_notifications')

) x order by 序, 項目, 內容;
