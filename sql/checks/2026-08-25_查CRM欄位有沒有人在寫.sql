/* ============================================================
   查：members 的 CRM 欄位有沒有人在寫
   2026-08-25 · 唯讀

   上一支查出 members 有一整組欄位我不知道：
       last_visit_at   visit_count   lifecycle
       primary_staff_id   last_app_active_at

   🔴 這決定兩件事：
   ① **上次來訪要從哪裡讀。**
      我今天做的是從 orders 即時算（get_my_orders_tx 的第一筆）。
      如果 last_visit_at 有在維護，那就是第二套 ——
      而兩套遲早會不一致，且沒人知道哪邊才對。
   ② **造訪次數做不做得起來。**
      visit_count 若有在累加，總部後台的行銷分析就有現成的；
      沒有的話它是第五個「建了沒人寫」。

   ⚠ 判準只有兩個：**有沒有值** ＋ **有沒有函式會寫它**。
     欄位存在不代表有人維護（同踩坑第 29 條的另一面）。
   ⚠ 掃函式內文一律先過濾 prokind = 'f'（硬規則 3.7）——
     pg_get_functiondef 對聚合函式會直接拋錯。
   ============================================================ */

select 序, 項目, 內容 from (

  /* ① 有沒有值。全 null 就是沒人寫。 */
  select 1 as 序, '① 欄位實際有值的比例' as 項目,
         'last_visit_at ' || count(*) filter (where last_visit_at is not null)::text ||
         '／visit_count>0 ' || count(*) filter (where coalesce(visit_count,0) > 0)::text ||
         '／lifecycle ' || count(*) filter (where lifecycle is not null)::text ||
         '／primary_staff_id ' || count(*) filter (where primary_staff_id is not null)::text ||
         '／last_app_active_at ' || count(*) filter (where last_app_active_at is not null)::text ||
         '　（會員總數 ' || count(*)::text || '）' as 內容
    from members

  union all
  /* ② 有沒有函式會寫它們。
        禁字用「欄位名 + 賦值」的形狀不夠精準，所以退一步：
        只要函式內文提到該欄位就列出來，由人判讀是讀還是寫。
        ⚠ 同硬規則 3.5：不回傳是非題，把名字印出來讓人看。 */
  select 2, '② 提到 last_visit_at 的函式',
         coalesce((select string_agg(p.proname, '、' order by p.proname)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
                      and pg_get_functiondef(p.oid) ilike '%last_visit_at%'),
                  '🔴 沒有任何函式提到它')

  union all
  select 3, '③ 提到 visit_count 的函式',
         coalesce((select string_agg(p.proname, '、' order by p.proname)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
                      and pg_get_functiondef(p.oid) ilike '%visit_count%'),
                  '🔴 沒有任何函式提到它')

  union all
  select 4, '④ 提到 lifecycle 的函式',
         coalesce((select string_agg(p.proname, '、' order by p.proname)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
                      and pg_get_functiondef(p.oid) ilike '%lifecycle%'),
                  '🔴 沒有任何函式提到它')

  union all
  /* ⑤ 觸發器也可能在寫（不一定透過具名函式呼叫） */
  select 5, '⑤ members 上的觸發器',
         coalesce((select string_agg(tg.tgname || ' → ' || pg_get_triggerdef(tg.oid), '　│　')
                     from pg_trigger tg
                     join pg_class t on t.oid = tg.tgrelid
                    where t.relnamespace = 'public'::regnamespace
                      and t.relname = 'members' and not tg.tgisinternal),
                  '（沒有觸發器）')

  union all
  /* ⑥ member_interactions 現在有沒有資料、什麼形狀
        —— 店員備註要寫進這張表，先看它是空的還是已經有東西。 */
  select 6, '⑥ member_interactions 現況',
         coalesce((select string_agg(t.k, '　' order by t.k)
                     from (select channel || '/' || kind || '：' || count(*)::text as k
                             from member_interactions group by channel, kind) t),
                  '（空的 —— 還沒有任何互動紀錄）')

  union all
  /* ⑦ lifecycle 的允許值（CHECK）—— 分眾要用它，先看有哪些格 */
  select 7, '⑦ lifecycle 的允許值',
         coalesce((select string_agg(pg_get_constraintdef(c.oid), '　')
                     from pg_constraint c
                     join pg_class t on t.oid = c.conrelid
                    where t.relnamespace = 'public'::regnamespace
                      and t.relname = 'members' and c.contype = 'c'
                      and pg_get_constraintdef(c.oid) ilike '%lifecycle%'),
                  '（沒有 CHECK —— 任何字串都能寫）')

) x order by 序, 項目;
