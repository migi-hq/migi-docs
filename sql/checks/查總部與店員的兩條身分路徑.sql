-- 【這是什麼】唯讀：確認「總部（Email）」與「店員（LINE）」這兩條身分路徑
--             在資料庫裡實際是怎麼實作的。
-- 【何時讀】修 current_staff() 之前。
--
-- ═══ 背景 ═══
--
-- 當初的決策是有理由的（docs/06-架構藍圖/總部後台架構藍圖.md:33、
-- docs/08-決策與踩坑/決策紀錄.md 第八節）：
--   ① 總部員工不是會員 —— 不打牌、不需要 LINE
--   ② **開機問題**：第一個管理員沒有人能升級他（那時一個 staff 都沒有），
--      所以必須有一條不依賴既有 staff 的路 → Dashboard 手動建 Auth 帳號
--   ③ 職能不同 —— HQ 管全集團建檔，POS 管單店現場
--
-- `staff.auth_uid` 這個欄位**正是為了那條路存在的**
-- （基石規範:114 原文：「insert 進 staff(role='hq', auth_uid=該帳號的 auth id)」）。
--
-- 🔴 但後來店員登入改成 LINE 時，current_staff() 被寫成**只認 LINE**，
--    而且是 `join members`（INNER）——
--    **總部那條路被順手切掉了，而且沒有人發現。**
--    現有那筆 member_id = null 的總部管理員就是證據。
--
-- ⚠ 所以要修的不是「總部改用 LINE」，是 current_staff() 漏了一條本來該支援的路。
--   但改之前要先知道：**migi-admin 現在讀得到資料，靠的是誰？**

select 項目, 結果
from (
  select 1 as ord, '① 🔴 current_org_id() 全文（migi-admin 現在靠它讀資料）' as 項目,
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='current_org_id' limit 1),
             '❌ 不存在') as 結果

  union all select 2, '② current_member_id() 全文（會員端那條路）',
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='current_member_id' limit 1),
             '❌ 不存在')

  -- 🔴 這一題是關鍵：現有那筆總部管理員，auth_uid 到底有沒有值？
  --    有值 → 那條路是活的，current_staff() 只是漏接
  --    沒值 → migi-admin 能讀資料是靠別的機制，要重新想
  union all select 3, '③ 🔴 現有 staff 的兩個身分欄位誰有值',
    coalesce((select string_agg(
                coalesce(s.name, '(無名)') || ' · ' || s.role ||
                '　member_id=' || case when s.member_id is null then '空' else '有' end ||
                '　auth_uid='  || case when s.auth_uid  is null then '空' else '有' end,
                chr(10) order by s.role)
                from staff s where s.deleted_at is null),
             '（沒有 staff）')

  union all select 4, '④ 那個 auth_uid 對得上 auth.users 裡的帳號嗎',
    coalesce((select string_agg(coalesce(s.name,'(無名)') || ' → ' ||
                     coalesce(u.email, '❌ auth.users 裡找不到這個 uid'), chr(10))
                from staff s
                left join auth.users u on u.id = s.auth_uid
               where s.auth_uid is not null and s.deleted_at is null),
             '（沒有任何 staff 有 auth_uid）')

  union all select 5, '⑤ auth.users 裡總共有幾個帳號（總部員工）',
    coalesce((select count(*)::text || ' 個：' ||
                     coalesce(string_agg(email, '、'), '(無 email)')
                from auth.users), '（查不到 —— 權限不足時會這樣）')

  -- 有哪些 policy 在用這兩支，決定改動的影響面
  union all select 10, '⑩ 有多少 RLS policy 用到 current_org_id()',
    coalesce((select count(*)::text || ' 條'
                from pg_policies
               where schemaname='public'
                 and (coalesce(qual,'') like '%current_org_id%'
                   or coalesce(with_check,'') like '%current_org_id%')), '—')

  union all select 11, '⑪ 有多少 RLS policy 用到 current_staff / has_store_access',
    coalesce((select count(*)::text || ' 條'
                from pg_policies
               where schemaname='public'
                 and (coalesce(qual,'') like '%current_staff%'
                   or coalesce(qual,'') like '%has_store_access%'
                   or coalesce(with_check,'') like '%current_staff%'
                   or coalesce(with_check,'') like '%has_store_access%')), '—')

  union all select 12, '⑫ 還有哪些函式會呼叫 current_staff()（改它的影響面）',
    coalesce((select string_agg(proname, '、' order by proname)
                from pg_proc
               where pronamespace='public'::regnamespace and prokind='f'
                 and proname <> 'current_staff'
                 and pg_get_functiondef(oid) like '%current_staff%'),
             '（沒有其他函式呼叫它）')
) x
order by ord;

-- ── 讀完之後 ──────────────────────────────────────────────
-- ①③④ 一起看：
--   · 若 current_org_id() 認 auth_uid，且 ③ 顯示總部那筆 auth_uid 有值
--     → **兩條路一直都是設計好的，只是 current_staff() 漏接**。
--       修法：把 join members 改成 LEFT JOIN，where 加一個
--       `or s.auth_uid = auth.uid()`。單點改動，風險低。
--   · 若 current_org_id() 也認 line_user_id
--     → 那 migi-admin 現在能讀資料是別的原因（可能全走 DEFINER RPC），
--       要重新盤點，不要照上面那個修法。
--
-- ⚠ ⑩⑪⑫ 是**影響面**：current_staff() 被多少 policy 與函式依賴。
--   數字大的話，改它就不是「單點改動」了 —— 那是要分批做的事。
