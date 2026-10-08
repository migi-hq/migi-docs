-- ════════════════════════════════════════════════════════════════════
-- 2026-10-09 高雄自由店桌號改成「區號-桌號」
-- ════════════════════════════════════════════════════════════════════
-- 使用者：「桌號改 A1-1、A1-2…」→ 選「每區各自編號」
--
--   A1–A5 → A1-1～A1-5
--   B1–B5 → B1-1～B1-5
--   C1–C4 → C1-1～C1-4
--   前鎮店（T1–T4）不動
--
-- 只改 tables.label（顯示用的名字）。歷史牌局、計分板配對、預約都是掛 table_id，不受影響。
-- 前端查過（2026-10-09）：四個 repo 都沒有拿桌號的字母或數字去做分區或排序，
--   排序靠 sort_order（沒動）。
-- 只改「字母＋一個數字」形狀的桌號 ⇒ 重跑一次不會變成 A1-1-1。
-- ════════════════════════════════════════════════════════════════════

update tables t
   set label = substring(t.label from 1 for 1) || '1-' || substring(t.label from 2)
  from stores s
 where s.id = t.store_id
   and s.code = 'S01'
   and t.deleted_at is null
   and t.label ~ '^[ABC][0-9]+$';

-- ── 驗證（單一 SELECT，不 raise）──────────────────────────────────────
select concat_ws(E'\n',
  -- ① 高雄自由店 14 張全部是新格式，順序照 sort_order
  (select case when string_agg(t.label, ' ' order by t.sort_order)
                    = 'A1-1 A1-2 A1-3 A1-4 A1-5 B1-1 B1-2 B1-3 B1-4 B1-5 C1-1 C1-2 C1-3 C1-4'
               then '✅ ① 高雄自由店 14 張都改好了'
               else '🔴 ① 高雄自由店現在是：' || string_agg(t.label, ' ' order by t.sort_order) end
     from tables t join stores s on s.id = t.store_id
    where s.code = 'S01' and t.deleted_at is null),
  -- ② 負對照：前鎮店沒被動到
  (select case when string_agg(t.label, ' ' order by t.sort_order) = 'T1 T2 T3 T4'
               then '✅ ② 前鎮店維持 T1–T4'
               else '🔴 ② 前鎮店被改到了：' || string_agg(t.label, ' ' order by t.sort_order) end
     from tables t join stores s on s.id = t.store_id
    where s.code = 'S02' and t.deleted_at is null)
) as "驗證";
