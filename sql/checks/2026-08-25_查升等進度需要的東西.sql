/* ============================================================
   查：做「累積消費 + 升等進度」需要知道的四件事
   2026-08-25 · 唯讀

   目標：讓 POS 會員查詢能顯示
       「焦糖布丁　累積 $8,420　距提拉米蘇還差 $41,580」

   痛感排第一的理由：member_tiers.threshold_amount **早就建好了沒人讀**
   （2026-08-17 建立）。缺了這一格，等級制度對客人與店員都不存在 ——
   客人問「我怎麼升級」，店員答不出來。

   ⚠ 打算改 pos_member_detail_tx 而不是開新 RPC：
     它已經回傳 tier / balance / coupons，多兩個數字是同一次查詢，
     不必讓前端多打一支。
   ⚠ 硬規則 3：改既有函式一律先撈線上版。
   ============================================================ */

select 序, 項目, 內容 from (

  /* ① 線上版全文 —— 改之前必須看過，不能拿 applied/ 當基準 */
  select 1 as 序, '① pos_member_detail_tx 定義' as 項目,
         coalesce((select pg_get_functiondef(p.oid)
                     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public' and p.proname = 'pos_member_detail_tx'
                    limit 1), '🔴 函式不存在') as 內容

  union all
  /* ② member_tiers 主檔的實際內容
        要知道：門檻欄位叫什麼、值是多少、排序靠什麼、
        chef_special 是不是 null（邀請制，不靠累積取得）。 */
  select 2, '② member_tiers 第 ' ||
            row_number() over (order by coalesce(t.threshold_amount, 999999999))::text || ' 列',
         t.code || '　' || coalesce(t.label, '(無 label)') ||
         '　折抵 ' || coalesce(t.discount_pct::text, '—') || '%' ||
         '　門檻 ' || coalesce(t.threshold_amount::text, '(null＝不靠累積)') ||
         '　' || (case when t.is_active then '啟用' else '停用' end)
    from member_tiers t

  union all
  /* ③ orders.status 的實際分佈
        累積消費只能算 'paid'。這裡確認沒有別的狀態混在裡面，
        也確認 payable 這個欄位真的有值。 */
  select 3, '③ orders 依 status',
         o.status || '：' || count(*)::text || ' 筆　payable 合計 ' ||
         coalesce(sum(o.payable), 0)::text
    from orders o group by o.status

  union all
  /* ④ 順便：members 有沒有生日欄位（生日招待是已承諾的權益，
        但我沒查過它存不存在），以及發票載具那幾欄。 */
  select 4, '④ members 相關欄位',
         column_name || '　' || data_type
    from information_schema.columns
   where table_schema = 'public' and table_name = 'members'
     and (column_name ilike '%birth%' or column_name ilike '%bday%'
       or column_name ilike 'inv_%')

) x order by 序, 項目;
