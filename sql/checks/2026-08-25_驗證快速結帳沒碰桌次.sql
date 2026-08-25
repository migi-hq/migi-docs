/* ============================================================
   驗證：pos_quick_checkout_tx 到底有沒有碰桌次
   2026-08-25 · 唯讀

   起因：
     2026-08-25_快速結帳補實收找零.sql 的驗證第 ⑤ 項回報
     「🔴 竟然引用了桌次」。

   ⚠ 但那一項是我自己寫壞的：
     我把 'session_id' 也列進禁字，而函式的**註解**裡就有
     「不回填 session_id」「快速結帳沒有桌次」這幾句。
     **字串比對分不出程式碼與註解。**

   ⚠ 這是第二次踩同一個形狀 ——
     2026-08-23 修店員角色值時，檢查 'clerk' 也被我自己寫的註解觸發。
     → 教訓：**掃全文找禁字時，禁字不能是自己註解裡會出現的詞。**
       真正該掃的是「會產生行為的東西」：table_sessions、session_players
       這種表名，不是 session_id 這種到處都有的欄位名。

   這支查詢把每一行印出來，讓「是註解還是程式碼」一眼可辨。
   ============================================================ */

select 行號, 判定, 原始碼 from (

  select t.n as 行號,
         (case
            when btrim(t.ln) like '--%'                        then '💬 註解'
            when btrim(t.ln) like '*%' or btrim(t.ln) like '/*%' then '💬 註解'
            when btrim(t.ln) like '⚠%' or btrim(t.ln) like '★%' then '💬 註解'
            else '🔴 程式碼'
          end) as 判定,
         t.ln as 原始碼
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    cross join lateral unnest(string_to_array(pg_get_functiondef(p.oid), E'\n'))
                with ordinality as t(ln, n)
   where ns.nspname = 'public'
     and p.proname = 'pos_quick_checkout_tx'
     and t.ln ~* '(session_id|table_sessions|session_players)'

) x order by 行號;
