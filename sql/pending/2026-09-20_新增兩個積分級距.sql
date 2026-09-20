-- ============================================================
-- 新增兩個積分級距：60/20 與 100/50（2026-09-20 使用者指定）
--
-- 非娛樂局從 6 級變成 8 級（加上純娛樂共 9 列）：
--   10/10 · 30/10 · 50/20 · **60/20** · 100/20 · **100/50** · 200/50 · 300/100
--
-- ✅ 兩支清單 RPC 都會自己吃到（撈過本體確認，不用改函式）：
--   list_stakes_tx / list_stake_levels_tx
--     where is_active and deleted_at is null and (store_id is null or 符合該店)
--     order by sort_order
--   ⇒ 新列 store_id = null（全連鎖）、is_active = true ⇒ 三端立刻看得到。
--
-- 🔴 `stake_levels` **沒有任何 label 的唯一鍵**（約束與索引兩邊都查過，
--   只有 pkey 與兩個外鍵）⇒ `on conflict` 無處可掛，重跑會**靜默長出第二筆**，
--   而症狀是開桌設定的積分選單出現兩顆一模一樣的膠囊。
--   ⇒ 冪等只能靠 `where not exists`。
--
-- ### 🎯 sort_order 用「算出來」的，不要手打九個數字
--   它其實完全由 `(is_hygiene, base, tai)` 決定：純娛樂第一，其餘照底、台遞增。
--   手打的話這次要改六列既有資料，而打錯一個數字**不會報錯**，
--   只會讓選單的順序悄悄不對。
--   ⚠ `is distinct from` 讓沒變的列不進 UPDATE ⇒ 它們的 `updated_at` 不會被動到，
--     第 ④ 格那個負對照才有意義。
-- ============================================================

-- ---------- ① 新增（冪等） ----------
insert into stake_levels (org_id, store_id, label, base, tai, is_hygiene, sort_order, is_active)
select o.id, null, v.label, v.base, v.tai, false, 0, true
  from orgs o
 cross join (values ('60/20', 60, 20), ('100/50', 100, 50)) v(label, base, tai)
 where o.deleted_at is null
   and not exists (
     select 1 from stake_levels s
      where s.org_id = o.id and s.label = v.label and s.deleted_at is null);

-- ---------- ② 重新編號（由 is_hygiene / base / tai 推出來） ----------
with ord as (
  select id,
         row_number() over (order by is_hygiene desc, base, tai) as n
    from stake_levels
   where deleted_at is null
)
update stake_levels s
   set sort_order = ord.n,
       updated_at = now()
  from ord
 where ord.id = s.id
   and s.sort_order is distinct from ord.n;


-- ============================================================
-- 驗證
-- ============================================================
do $$
declare
  v_msg text := '';
  v_n   int;
  v_txt text;
begin
  -- ① 兩個新級距都在，而且值正確
  select count(*) into v_n
    from stake_levels
   where deleted_at is null and is_active and not is_hygiene and store_id is null
     and ((label = '60/20'  and base = 60  and tai = 20)
       or (label = '100/50' and base = 100 and tai = 50));
  v_msg := case when v_n = 2
    then '✅ ① 60/20 與 100/50 都在，底台正確'
    else '🔴 ① 符合的新級距有 ' || v_n || ' 個（應為 2）' end;

  -- ② 🔴 冪等：沒有任何 label 重複
  --    這一格比 ① 重要 —— 沒有唯一鍵擋著，重跑一次就會多兩列而且不報錯
  select count(*) into v_n
    from (select label from stake_levels
           where deleted_at is null
           group by label having count(*) > 1) d;
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ② 沒有重複的 label（重跑這份不會長出第二筆）'
    else '🔴 ② 有 ' || v_n || ' 個 label 重複了 —— 這份被跑過兩次' end;

  -- ③ 總數：期望值用算式寫出來，不要憑印象（硬規則 3.56）
  --    1 純娛樂 ＋ 6 原有 ＋ 2 這批新增 = 9
  select count(*) into v_n from stake_levels where deleted_at is null;
  v_msg := v_msg || E'\n' || case when v_n = 9
    then '✅ ③ 共 9 級（1 純娛樂 ＋ 6 原有 ＋ 2 新增）'
    else '🔴 ③ 共 ' || v_n || ' 級，應為 9（1 ＋ 6 ＋ 2）' end;

  -- ④ 🔴 負對照：既有六級的底台一個數字都不准動
  --    只驗「新的加進來了」的話，把舊的改壞也會全綠（硬規則 3.55）
  select string_agg(label || '=' || base || '/' || tai, '　' order by sort_order)
    into v_txt
    from stake_levels
   where deleted_at is null and not is_hygiene
     and label in ('10/10','30/10','50/20','100/20','200/50','300/100');
  v_msg := v_msg || E'\n' || case
    when v_txt = '10/10=10/10　30/10=30/10　50/20=50/20　100/20=100/20　200/50=200/50　300/100=300/100'
    then '✅ ④ 既有六級的底台原封不動'
    else '🔴 ④ 既有六級被動到了：' || coalesce(v_txt, '⚪ 這一格取不到（0 列）') end;

  -- ⑤ 純娛樂還在最前面，而且 is_hygiene 還是 true
  --    🔴 它現在 base/tai 是 30/10（與 30/10 那一列同值），
  --      排序靠的是 is_hygiene desc ⇒ 這一格在盯「那個 desc 沒被拿掉」
  select label || '／' || case when is_hygiene then '不計積分' else '🔴 竟然計積分' end
    into v_txt
    from stake_levels where deleted_at is null order by sort_order limit 1;
  v_msg := v_msg || E'\n' || case when v_txt = '純娛樂／不計積分'
    then '✅ ⑤ 純娛樂仍然排第一而且仍然不計積分'
    else '🔴 ⑤ 排第一的是「' || coalesce(v_txt, '⚪ 取不到') || '」' end;

  -- ⑥ 整份順序印出來讓人判讀（不回是非題，硬規則 3.5）
  v_msg := v_msg || E'\n' || coalesce(
    (select '　　順序：' || string_agg(sort_order || '.' || label, ' ' order by sort_order)
       from stake_levels where deleted_at is null),
    '⚪ 這一格取不到（0 列）');   -- 字串 || NULL 是 NULL，會吃掉前面五格（硬規則 3.555）

  -- ⑦ sort_order 連號無重複（重新編號真的跑過了）
  select count(*) into v_n
    from stake_levels where deleted_at is null
      and sort_order between 1 and 9;
  v_msg := v_msg || E'\n' || case when v_n = 9
    then '✅ ⑦ sort_order 是 1–9 連號'
    else '🔴 ⑦ 只有 ' || v_n || ' 列落在 1–9，重新編號那段沒跑完' end;

  perform set_config('migi.verify', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify', true), ''), '🔴 沒有驗證訊息') as "驗證";
