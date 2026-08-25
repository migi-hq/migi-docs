/* ============================================================
   查：wallet_topup_tx 是不是死碼
   2026-08-25 · 唯讀

   ── 為什麼要問 ──────────────────────────────────────
   contract 第三步要拿掉 topup_tx 的 p_bonus_points，
   而 topup_tx 有三個呼叫者：
       pos_checkout_with_topup_tx   （位置參數，要改）
       pos_quick_checkout_tx        （具名、沒送 bonus，不受影響）
       wallet_topup_tx              ← **我不知道它存在**

   三個前端的 rpc('...') 名單裡都沒有它。若它真的沒人叫，
   正確的動作是**刪掉它**，不是為了配合它而放棄清理 ——
   不要為了死碼付維護代價。

   ⚠ 但「前端沒叫」不等於「沒人叫」。還沒查的有：
     · 資料庫內部（別的函式、觸發器、RLS policy、預設值、視圖）
     · 排程（pg_cron）
   這支就是補那一塊。**只掃前端就下結論，跟看 api.js 推後端是同一種錯**
   （2026-08-25 已經犯過一次）。
   ============================================================ */

select 序, 項目, 內容 from (

  /* ① 它存不存在、什麼簽名 */
  select 1 as 序, '① wallet_topup_tx 簽名' as 項目,
         coalesce((select p.proname || '(' || pg_get_function_arguments(p.oid) || ')'
                          || '　' || (case when p.prosecdef then 'DEFINER' else 'INVOKER' end)
                          || '　anon ' ||
                          (case when has_function_privilege('anon', p.oid, 'EXECUTE')
                                then '✅ 可執行' else '🔴 不可' end)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname = 'wallet_topup_tx'
                    limit 1), '🔴 不存在') as 內容

  union all
  /* ② 有沒有別的函式呼叫它
        ⚠ prokind = 'f' 不可省（硬規則 3.7）——
          pg_get_functiondef 對聚合函式會直接拋錯。 */
  select 2, '② 哪些函式呼叫它',
         coalesce((select string_agg(p.proname, '、' order by p.proname)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
                      and p.proname <> 'wallet_topup_tx'
                      and pg_get_functiondef(p.oid) ilike '%wallet_topup_tx%'),
                  '✅ 沒有任何函式呼叫它')

  union all
  /* ③ 觸發器 */
  select 3, '③ 觸發器有沒有用它',
         coalesce((select string_agg(tg.tgname || '@' || t.relname, '、')
                     from pg_trigger tg
                     join pg_class t on t.oid = tg.tgrelid
                     join pg_proc p on p.oid = tg.tgfoid
                    where not tg.tgisinternal
                      and p.proname = 'wallet_topup_tx'),
                  '✅ 沒有')

  union all
  /* ④ pg_cron 排程（表可能不存在，用 to_regclass 先判斷再查，
        否則整句查詢會在**解析階段**就失敗 —— 2026-08-16 踩過） */
  select 4, '④ pg_cron 排程',
         case when to_regclass('cron.job') is null
              then '（沒有 cron.job 表 —— pg_cron 未安裝或不可見）'
              else coalesce((select string_agg(j.jobname || '：' || j.command, '　│　')
                               from cron.job j
                              where j.command ilike '%wallet_topup%'),
                            '✅ 沒有排程用到它') end

  union all
  /* ⑤ 順便：整個 public 有多少支函式從來沒被別人呼叫過。
        不是要一次清掉，是想知道死碼的規模 ——
        今天已經發現三個「建了沒人讀」的欄位，函式那邊可能也有一批。
        ⚠ 只看「有沒有被其他函式呼叫」，前端呼叫的不算在內，
          所以這個數字**一定偏高**，只能當粗略訊號不能當清單。 */
  select 5, '⑤ 沒有被任何函式呼叫的函式數（粗估）',
         (select count(*)::text || ' 支（總共 ' ||
                 (select count(*) from pg_proc
                   where pronamespace = 'public'::regnamespace and prokind = 'f')::text || ' 支）'
            from pg_proc a
           where a.pronamespace = 'public'::regnamespace and a.prokind = 'f'
             and not exists (
               select 1 from pg_proc b
                where b.pronamespace = 'public'::regnamespace and b.prokind = 'f'
                  and b.oid <> a.oid
                  and pg_get_functiondef(b.oid) ilike '%' || a.proname || '%'))

) x order by 序, 項目;
