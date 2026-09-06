/* ============================================================
   「已完成」是歷史紀錄，不是「今天」
   2026-09-07 · MIGI 咪吉麻將 · 一支 CREATE OR REPLACE，簽名不變

   ── 現在是什麼樣 ──────────────────────────────────────
   `pos_list_queues_tx` 只回**台北日曆日的今天**收的桌：
   ```sql
   and (ts.ended_at at time zone 'Asia/Taipei')::date
       = (now() at time zone 'Asia/Taipei')::date
   ```
   ⇒ **午夜一過，已完成分頁整個清空**。
   2026-09-07 01:23 實測：09-06 收的三桌（12:59／20:23／20:35）全部不見。

   🔴 **那個限制當初的理由是我寫的，而且是錯的。**
     原註解寫「店員交班時要看得到今天配了幾桌」——
     但這一頁是**歷史紀錄**，不是交班報表。交班的數字屬於日結（待辦 18），
     那一頁有自己的「一班是從幾點到幾點」的定義。
   ⚠ 兩個不同的問題用同一個判準，結果是**兩邊都不對**：
     歷史被切掉，而交班要的數字這裡本來就給不了。

   ── 🔴 配桌是延續的，不能被任何「日／班」切斷 ─────────
   使用者 2026-09-07 指出：**前兩位可能是上一班找到的，靠下一班完成。**
   ⇒ 這一頁不該有日曆日的概念。

   ✅ 好消息：**進行中那一半本來就沒有邊界** ——
     `waiting` 只看房自己的 `expires_at`，`matched` 與 `seated + open`
     完全沒有時間條件。跨班的房不會中斷。
   🔴 有邊界的只有「已收桌」那一段，而那正是消失的那些。

   ── 改成什麼：7 天 ────────────────────────────────────
   `ended_at >= now() - interval '7 days'`

   🔴 **為什麼是 7 天而不是拿掉限制**：這一頁**每 8 秒輪詢一次**，
     而且**沒有分頁** —— 整間店的房一次全撈，每一列還帶四個人的名單。
     把幾個月的歷史放進去，等於每 8 秒重新下載一次歷史。
     ⚠ 症狀會是「配桌列表越來越慢」，而沒有人會聯想到這一行。
   📌 換算：一天 20 桌 × 7 天 ≒ 140 列，那是清單的尺度。
     30 天就是 600 列 —— 對一個每 8 秒跑一次的查詢太重。

   ⚠ **這是清單不是檔案庫。** 要查一個月前的紀錄是 migi-admin 的事，
     不是收銀機。真的需要在 POS 往回翻，那時要做的是**分頁**
     （這支加 `p_before` / `p_limit`），不是把窗口拉長。

   ── ⚠ 只切「已收桌」那一段 ─────────────────────────────
   其餘三種（waiting／matched／seated 且場次還開著）**完全不受影響** ——
   它們是「現在的事」，本來就沒有時間界線。
   📌 特別是「檯費收齊但桌還在打」那種也在已完成分頁，
     而它走的是 `ts.status = 'open'` 那一條，不會被這次的日期條件碰到。
   ============================================================ */

do $mig$
declare
  v_def text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'pos_list_queues_tx' and p.prokind = 'f';

  if v_def is null then raise exception '找不到 pos_list_queues_tx'; end if;

  /* ① 日期條件換成 7 天。
     ⚠ 整個 pattern 只用非貪婪量詞 —— 混用貪婪與非貪婪時，
       PostgreSQL 依**第一個量詞**決定整個 RE 的貪婪性，
       2026-09-06 就因此把一支觸發器砍掉一半（那份 SQL 有完整記錄）。 */
  v_new := regexp_replace(v_def,
    'and \(ts\.ended_at at time zone ''Asia/Taipei''\)::date[\s\S]*?::date',
    'and ts.ended_at >= now() - interval ''7 days''');

  if v_new = v_def then
    raise exception '🔴 ① 沒有替換到日期條件 —— 線上版本跟預期不同，先撈出來看';
  end if;

  /* ② 那段註解也要改，不然它會說一件事、程式做另一件。 */
  v_new := replace(v_new,
    '今天已經收桌的也留著（只留今天，台北日曆日）——',
    '已收桌的留 7 天（這一頁是歷史紀錄，不是交班報表）——');
  v_new := replace(v_new,
    '店員交班時要看得到「今天配了幾桌」。',
    '🔴 不要改回「只留今天」：午夜一過整頁會清空。'
    || chr(10) || '         而且**配桌是延續的** —— 前兩位可能是上一班找到的，靠下一班完成，'
    || chr(10) || '         任何日／班的邊界都會把同一件事切成兩半。'
    || chr(10) || '       ⚠ 也不要把 7 天拉長：這一頁每 8 秒輪詢、沒有分頁，'
    || chr(10) || '         整間店的房一次全撈 —— 拉長等於每 8 秒重新下載一次歷史。'
    || chr(10) || '         真的要往回翻是加分頁（p_before / p_limit），不是加天數。');

  if v_new !~ 'interval ''7 days''' then
    raise exception '🔴 ② 7 天那段不見了';
  end if;

  execute v_new;
end $mig$;

/* ── 驗證 ────────────────────────────────────────────────
   ⚠ 期望值當場算（硬規則 3.56），不寫死筆數。 */
with 回傳 as (
  select e.v
    from jsonb_array_elements(
           pos_list_queues_tx((select id from orgs limit 1),
                              '22222222-2222-2222-2222-222222222222'::uuid)) e(v)
),
應該有 as (
  select count(*) as n
    from match_queues q
    join table_sessions ts on ts.id = q.matched_session_id
   where q.store_id = '22222222-2222-2222-2222-222222222222'::uuid
     and q.status = 'seated' and ts.status = 'completed'
     and ts.deleted_at is null
     and ts.ended_at >= now() - interval '7 days'
)
select
  /* ① 昨天收的桌回來了 */
  (select case when count(*) = (select n from 應該有)
               then '✅ ① 7 天內收桌的房都在（' || count(*)::text || ' 房）'
               else '🔴 ① 回傳 ' || count(*)::text
                    || ' 房，資料表算出來是 ' || (select n from 應該有)::text end
     from 回傳 where (v ->> 'session_status') = 'completed') as ①歷史回來了,

  /* ② 🎯 正對照：**現在的事沒有被日期條件誤傷**。
     ⚠ 少了這一格，一支「把整個 where 換掉」的實作也會讓①變綠。 */
  (select case when count(*) = (select count(*) from match_queues q2
                                 where q2.store_id = '22222222-2222-2222-2222-222222222222'::uuid
                                   and q2.status in ('waiting','matched')
                                   and (q2.expires_at is null or q2.expires_at > now())
                                   and (q2.open_at is null or q2.open_at <= now()))
               then '✅ ② 等待中／已滿的房沒有被誤傷'
               else '🔴 ② 進行中的房數對不上' end
     from 回傳 where (v ->> 'session_status') is null) as ②進行中沒誤傷,

  /* ③ 🎯 正對照：**很久以前的不可以回來**。
     只驗①的話，一支「把日期條件整個刪掉」的實作也會過。 */
  (select case when count(*) = 0 then '✅ ③ 7 天以前的沒有跑進來'
               else '🔴 ③ 有 ' || count(*)::text || ' 房超過 7 天' end
     from 回傳 r
     join table_sessions ts on ts.id = (r.v ->> 'session_id')::uuid
    where ts.ended_at < now() - interval '7 days') as ③太舊的沒回來,

  /* ④ 註解沒有說謊。

     🔴 **第一次跑這一格是紅的，而錯的是這個檢查本身**（硬規則 3.5）。
       原本掃的禁字是 `只留今天` —— 而我在**新註解裡**就寫了
       「不要改回『只留今天』」⇒ 掃到自己寫的字。
     ⚠ 那條規則就寫在這個專案的硬規則裡，而我在同一份檔案裡
       引用了它、然後違反它。
     → 禁字改成**只會出現在舊版**的句子：`店員交班時要看得到`。
       同時正對照新註解真的進去了 —— 只驗「舊的不見」的話，
       一支「把整段註解刪光」的實作也會過。 */
  case when (select count(*) from pg_proc p
              where p.pronamespace = 'public'::regnamespace
                and p.proname = 'pos_list_queues_tx'
                and pg_get_functiondef(p.oid) ~ '店員交班時要看得到') = 0
       then '✅ ④ 舊註解已經改掉'
       else '🔴 ④ 舊註解還在' end as ④舊註解走了,

  case when (select count(*) from pg_proc p
              where p.pronamespace = 'public'::regnamespace
                and p.proname = 'pos_list_queues_tx'
                and pg_get_functiondef(p.oid) ~ '配桌是延續的') = 1
       then '✅ ⑤ 新註解在（配桌是延續的）'
       else '🔴 ⑤ 新註解沒進去' end as ⑤新註解在;
