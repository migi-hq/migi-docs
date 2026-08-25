/* ============================================================
   主廚特調的折抵幅度 10% → 20%
   2026-08-25

   ── 為什麼一行 UPDATE 就夠 ──────────────────────────
   2026-08-17 把折扣率從「兩支函式各一份寫死的 case」改成查 member_tiers
   主檔之後，這個值就是**資料**不是程式。
   checkout_tx 與 pos_member_detail_tx 都是即時查，**改完立刻生效**，
   不用部署、不用重建函式。

   ✅ 這正是當初做主檔的理由。改一個數字要跑一次 migration、
      改兩支金流函式、還要記得兩邊一起改 —— 那是舊世界。

   ── 已存的訂單不受影響（而且應該不受影響）────────────
   orders.tier_discount_pct 是**下單當時的快照**。
   過去的單維持當時的 10%，不會因為今天調價而變 ——
   那是對的：報表要能重現當時的實收金額。

   ── 20 的意思 ───────────────────────────────────────
   ⚠ 存的是**折抵幅度**不是折數：20 = 折掉 20% = 台灣話的「8 折」。
     （2026-08-17 拍板：資料庫存折抵幅度，畫面一律顯示折數。）
     所以 POS 會顯示「檯費 8 折」。

   ⚠ 只折檯費，不折餐飲與商品（2026-08-17 起）。

   ── ⏳ 「未來從總部調整」還沒有介面 ──────────────────
   migi-admin 目前**沒有 member_tiers 的編輯畫面** ——
   改折數還是要跑 SQL。這條已記進 CLAUDE.md 待辦。
   在那之前，這份檔案就是改法的範本。
   ============================================================ */

update member_tiers
   set discount_pct = 20
 where code = 'chef_special';


/* ============================================================
   驗證段（單一 SELECT）
   ⚠ 不只看主廚特調 —— 四級一起印出來，
     才看得出「有沒有不小心改到別人」。
     只查改的那一列，等於用一個不會分辨的儀器（同踩坑第 25 條）。
   ============================================================ */

select 序, 項目, 內容 from (

  select 1 as 序,
         row_number() over (order by coalesce(t.threshold_amount, 999999999))::text
           || '. ' || t.code as 項目,
         t.label
         || '　折抵 ' || coalesce(t.discount_pct::text, '—') || '%'
         || '（顯示為 ' ||
            (case when t.discount_pct is null or t.discount_pct = 0 then '無折扣'
                  else (case when (100 - t.discount_pct) % 10 = 0
                             then ((100 - t.discount_pct) / 10)::text
                             else round((100 - t.discount_pct) / 10.0, 1)::text end)
                       || ' 折' end)
         || '）　門檻 ' || coalesce(t.threshold_amount::text, '(null＝邀請制)')
         || '　' || (case when t.is_active then '啟用' else '停用' end) as 內容
    from member_tiers t

  union all
  select 2, '① 主廚特調是不是 20',
         (case when (select discount_pct from member_tiers where code = 'chef_special') = 20
               then '✅ 是' else '🔴 不是 —— UPDATE 沒生效' end)

  union all
  /* 其餘三級的值是這次之前就確認過的（0 / 5 / 10），
     任何一個變了就是誤傷。 */
  select 3, '② 其餘三級沒被動到',
         (case when (select count(*) from member_tiers
                      where (code = 'bubble_tea'       and discount_pct = 0)
                         or (code = 'caramel_pudding'  and discount_pct = 5)
                         or (code = 'tiramisu'         and discount_pct = 10)) = 3
               then '✅ 0 / 5 / 10 都沒變'
               else '🔴 有被動到，要查' end)

  union all
  /* 折扣率只該有一個來源。掃全庫確認沒有函式又把它寫死回去了。
     ⚠ 禁字用 'chef_special'（一個具體的等級代碼），不是 'discount' 這種
       到處都有的詞 —— 同硬規則 3.5。

     🔴 `prokind = 'f'` 不可省（2026-08-25 因此炸過一次）：
        **pg_get_functiondef 對聚合函式會拋錯**
        （ERROR 42809: "array_agg" is an aggregate function）。
        pg_proc 裡混著 f 一般函式 / a 聚合 / w 視窗 / p 預存程序。
     🔴 而且**光靠 nspname='public' 擋不住** —— WHERE 裡的函式可能在
        join 過濾之前就被求值，規劃器不保證順序。
        先前幾支同樣寫法沒炸，是因為它們還有 `proname = any(名單)`
        這個便宜的條件先把範圍縮掉了。
        → 用 pronamespace 直接比對（不 join），再加 prokind，兩道一起上。 */
  select 4, '③ 有沒有函式又寫死等級折扣',
         coalesce((select string_agg(p.proname, '、')
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f'
                      and pg_get_functiondef(p.oid) ilike '%chef_special%'),
                  '✅ 沒有任何函式提到 chef_special')

) x order by 序, 項目;
