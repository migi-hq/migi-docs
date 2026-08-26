/* ============================================================
   撈 get_my_profile_tx 的線上定義
   2026-08-26 · 唯讀

   為什麼要整份：
     `set_my_birthday_tx` 已上線（會員可以填生日了），
     但 `get_my_profile_tx` **不回傳 birthday** ——
     前端讀不到現值，就只能永遠顯示空白，
     使用者會以為沒存成功而重填。

   ⚠ 硬規則 3：改既有函式一律先撈線上版。
     `sql/applied/` 只是「當時交付的版本」，後來可能又改過而沒留檔。

   ⚠ 順帶要看的兩件事：
     ① 它回傳的形狀（jsonb 物件？TABLE？）決定怎麼加欄位
     ② 有沒有其他欄位是「會員自己的資料」但也漏掉的
        —— 一次看完，不要改兩次
   ============================================================ */

select 序, 項目, 內容 from (

  select 1 as 序, '① get_my_profile_tx 定義' as 項目,
         coalesce((select pg_get_functiondef(p.oid)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname = 'get_my_profile_tx'
                    limit 1), '🔴 不存在') as 內容

  union all
  /* ② members 上「會員自己的資料」有哪些欄位 ——
        跟 ① 對照就知道還漏了什麼。
        ⚠ 排除系統欄位（id / org_id / 時間戳 / 稽核欄位）。 */
  select 2, '② members 的個人資料欄位',
         string_agg(column_name || ' ' || data_type, '　' order by ordinal_position)
    from information_schema.columns
   where table_schema = 'public' and table_name = 'members'
     and column_name not in ('id','org_id','created_at','updated_at',
                             'created_by','updated_by','deleted_at')

) x order by 序, 項目;
