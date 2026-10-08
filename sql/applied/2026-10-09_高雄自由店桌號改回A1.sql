-- ════════════════════════════════════════════════════════════════════
-- 2026-10-09 高雄自由店桌號改回 A1–A5／B1–B5／C1–C4（撤銷同日那一份）
-- ════════════════════════════════════════════════════════════════════
-- 同日 `2026-10-09_高雄自由店桌號改成A1-1.sql` 是我理解錯了：
-- 使用者要的是**智慧計分板頂條的「桌號」顯示每台平板自己的編號**（後台「智慧計分板」頁的 A1-1～A1-4），
-- 不是把桌子改名。平板編號本來就是 A1-1～A1-4（table_devices.label），
-- 桌名改回去之後，計分板改讀平板編號（migi-table App.jsx），資料庫不用再動。
--
-- 只改「字母＋1-＋數字」形狀的桌號 ⇒ 重跑一次不會出錯。
-- ════════════════════════════════════════════════════════════════════

update tables t
   set label = substring(t.label from 1 for 1) || substring(t.label from 4)
  from stores s
 where s.id = t.store_id
   and s.code = 'S01'
   and t.deleted_at is null
   and t.label ~ '^[ABC]1-[0-9]+$';

-- ── 驗證（單一 SELECT，不 raise）──────────────────────────────────────
select concat_ws(E'\n',
  (select case when string_agg(t.label, ' ' order by t.sort_order)
                    = 'A1 A2 A3 A4 A5 B1 B2 B3 B4 B5 C1 C2 C3 C4'
               then '✅ ① 高雄自由店 14 張改回原本的桌號'
               else '🔴 ① 高雄自由店現在是：' || string_agg(t.label, ' ' order by t.sort_order) end
     from tables t join stores s on s.id = t.store_id
    where s.code = 'S01' and t.deleted_at is null),
  (select case when string_agg(t.label, ' ' order by t.sort_order) = 'T1 T2 T3 T4'
               then '✅ ② 前鎮店維持 T1–T4'
               else '🔴 ② 前鎮店被改到了' end
     from tables t join stores s on s.id = t.store_id
    where s.code = 'S02' and t.deleted_at is null),
  -- ③ 平板編號本來就是 A1-1～A1-4，不動
  (select case when string_agg(d.label, ' ' order by d.label) = 'A1-1 A1-2 A1-3 A1-4'
               then '✅ ③ 平板編號維持 A1-1～A1-4'
               else '🟡 ③ 平板編號：' || coalesce(string_agg(d.label, ' ' order by d.label), '（沒有）') end
     from table_devices d where d.revoked_at is null)
) as "驗證";
