/* ============================================================
   查：LINE 綁定的兩條路實際長什麼樣
   2026-08-26 · 唯讀

   ── 要回答的問題 ────────────────────────────────────
   使用者的計畫是：
     · 四個測試帳號 → rebind_line_user_tx（綁到既有會員）
     · 真實客人     → 正常註冊登入

   形狀是對的，但兩條路現在都還不存在：
     · register_member_tx  —— **前端沒有在呼叫**
       （migi-web App.jsx:98 是 id: 'local-' + Date.now() 存 localStorage，
         註解寫「★之後改呼叫」）
     · rebind_line_user_tx —— 三個前端一次都沒出現過
     · App.jsx:64「LINE 尚未接上：**授權為模擬**」

   ⚠ 而且「**換**綁」顧名思義預期本來就有值，
     而那四個帳號的 line_user_id 現在是 **null**。
     **我沒看過它的內文，不能假設它處理得了 null。**

   🔴 最關鍵的一項是 ③：line_user_id 有沒有 UNIQUE。
     沒有的話，兩個會員可以共用同一個 LINE 帳號 ——
     而那會讓「同一個人兩個帳號」（待辦 15）從可能變成必然，
     且**不會有任何錯誤訊息**。
   ============================================================ */

select 序, 項目, 內容 from (

  /* ① 換綁函式的完整定義 —— 它能不能處理「本來沒綁」的情況 */
  select 1 as 序, '① rebind_line_user_tx' as 項目,
         coalesce((select pg_get_functiondef(p.oid)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname = 'rebind_line_user_tx'
                    limit 1), '🔴 不存在') as 內容

  union all
  /* ② 註冊函式的完整定義 —— 它是「查不到才建」還是「一律新建」。
        這決定真實客人第二次登入時會不會被建成第二個帳號。 */
  select 2, '② register_member_tx',
         coalesce((select pg_get_functiondef(p.oid)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname = 'register_member_tx'
                    limit 1), '🔴 不存在')

  union all
  /* ③ 🔴 members.line_user_id 的約束
        沒有 UNIQUE 的話，兩個會員共用同一個 LINE 帳號**不會報錯** ——
        那是最糟的形狀：錯了沒有任何症狀。 */
  select 3, '③ members 上與 line_user_id 有關的索引／約束',
         coalesce((select string_agg(i.relname || '　' || pg_get_indexdef(x.indexrelid), '　│　')
                     from pg_index x
                     join pg_class i on i.oid = x.indexrelid
                     join pg_class t on t.oid = x.indrelid
                    where t.relnamespace = 'public'::regnamespace
                      and t.relname = 'members'
                      and pg_get_indexdef(x.indexrelid) ilike '%line_user_id%'),
                  '🔴 完全沒有索引或約束 —— 兩個會員可以共用同一個 LINE 帳號')

  union all
  /* ④ 還有哪些函式會寫 line_user_id
        —— 綁定的入口不只一個的話，要每一個都檢查。 */
  select 4, '④ 哪些函式會碰 line_user_id',
         coalesce((select string_agg(p.proname, '、' order by p.proname)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
                      and pg_get_functiondef(p.oid) ilike '%line_user_id%'),
                  '（沒有）')

  union all
  /* ⑤ 有沒有「用手機找既有會員」的機制
        —— 那是避免「同一個人兩個帳號」最實際的一道防線：
           LINE 首次登入時先問手機，找得到就綁上去，不要新建。 */
  select 5, '⑤ 有沒有用手機查會員的函式',
         coalesce((select string_agg(p.proname || '(' || pg_get_function_arguments(p.oid) || ')',
                                     '　│　' order by p.proname)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
                      and (p.proname ilike '%phone%' or p.proname ilike '%find_member%'
                        or p.proname ilike '%lookup%')),
                  '🔴 沒有 —— 那道防線目前不存在')

) x order by 序, 項目;
