/* ============================================================
   收桌之後，配桌列表不要再說「還沒收檯費」
   2026-09-06 · MIGI 咪吉麻將 · 一支 CREATE OR REPLACE，簽名不變

   ── 症狀 ──────────────────────────────────────────────
   已完成分頁那張卡（11:30 那房，11:45 帶到 A3，12:59 收桌）
   仍然寫著「前往 A3 **結帳** ›」—— 而那四份檯費
   （100/100/90/95 = 385）早就收完了。

   ── 根因 ──────────────────────────────────────────────
   ```sql
   'paid_count', (select count(*) from session_players sp
                   where sp.session_id = q.matched_session_id
                     and sp.left_at is null)     -- 🔴
   ```
   `settle_session_tx` 收桌時**把在座玩家一律寫 `left_at`**
   （CLAUDE.md 待辦 3：「在座玩家一律寫 left_at」）
   ⇒ 收桌的那一刻 `paid_count` 從 4 掉回 **0**。

   🔴 也就是這個欄位叫 `paid_count`，數的卻是「**現在還在座幾個人**」
     —— 同一族的病第六次（`wallet_txns.type` 一欄兩義／
     `staff.role` 一欄兩維度／`players` 一個 key 兩種形狀／
     `score_points` 一個名字兩個意思／`--gray-4` 同時是線與底色）。

   ── 為什麼直接拿掉那個條件就對 ──────────────────────
   `session_players` 的每一列都是 **checkout 成功之後才建立的** ——
   系統裡不存在「已入座但未付款」（待辦 3 有完整說明）。
   ⇒ **有列 = 這個人的檯費處理完了**，`left_at` 只是「他離座了」。
   ⚠ 暢打的人 `order_id` 是 null（那是「不用付」不是「還沒付」），
     所以**不可以改成數 `order_id is not null`** —— 那會讓
     持有暢打的客人永遠算不進去，而症狀是「這桌永遠差一個人沒收」。
     → 正解就是 `count(*)`，不加任何條件。

   ⚠ 這支沒有改簽名 → `CREATE OR REPLACE`，不用 DROP、不掉 GRANT。
   ============================================================ */

do $mig$
declare
  v_def text;
  v_new text;
  v_old text := 'where sp.session_id = q.matched_session_id and sp.left_at is null';
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'pos_list_queues_tx'
     and p.prokind = 'f';

  if v_def is null then
    raise exception '找不到 pos_list_queues_tx';
  end if;

  /* ⚠ 原始碼裡那段是換行排版的，所以先把空白正規化再比對 ——
     直接用字面字串比對會因為縮排差一格而找不到，
     然後這支 migration 會「成功」但什麼都沒改（靜默失敗）。 */
  v_new := regexp_replace(
             v_def,
             'where\s+sp\.session_id\s*=\s*q\.matched_session_id\s+and\s+sp\.left_at\s+is\s+null',
             'where sp.session_id = q.matched_session_id',
             'g');

  if v_new = v_def then
    raise exception '🔴 沒有替換到任何東西 —— 線上版本跟預期不同，先撈出來看過再改';
  end if;

  execute v_new;
end $mig$;

/* ── 驗證 ────────────────────────────────────────────────
   🔴 期望值**當場查出來**，不寫死（硬規則 3.56）——
     「4」是今天的樣本剛好四個人，不是規則。
   🔴 樣本也**當場挑**，而且挑不到要出聲（硬規則 3.57）——
     不要 `if … then` 安靜跳過，那會讓「沒測到」長得像「通過了」。 */
with 樣本 as (
  select q.id as qid, q.matched_session_id as sid, ts.status as 場次,
         (select count(*) from session_players sp where sp.session_id = q.matched_session_id) as 應該幾人,
         (select count(*) from session_players sp
           where sp.session_id = q.matched_session_id and sp.left_at is not null) as 已離座
    from match_queues q
    join table_sessions ts on ts.id = q.matched_session_id
   where q.matched_session_id is not null
   order by (ts.status = 'completed') desc, q.created_at desc
   limit 1
),
回傳 as (
  select e.v
    from 樣本 s,
         jsonb_array_elements(
           pos_list_queues_tx(
             (select org_id from match_queues where id = s.qid),
             (select store_id from match_queues where id = s.qid))) e(v)
   where (e.v ->> 'id')::uuid = s.qid
)
select
  case when not exists (select 1 from 樣本)
       then '🔴 ⓪ 找不到任何有配到桌的房 —— 這份驗證等於沒跑，不要當成通過'
       else '✅ ⓪ 樣本：場次 ' || (select 場次 from 樣本)
            || '　玩家 ' || (select 應該幾人 from 樣本)
            || ' 人（其中已離座 ' || (select 已離座 from 樣本) || '）' end
  as ⓪樣本,

  /* ① 主結果：收桌之後 paid_count 仍然等於玩家列數。
     🎯 挑樣本時 `order by (status='completed') desc` 就是為了優先挑
       **已收桌**的那一個 —— 那才是這次要修的情況。 */
  case when not exists (select 1 from 回傳) then '🔴 ① 回傳裡找不到那個房'
       when (select (v ->> 'paid_count')::int from 回傳)
          = (select 應該幾人 from 樣本)::int
       then '✅ ① paid_count = ' || (select v ->> 'paid_count' from 回傳)
            || '（＝玩家列數，收桌不再歸零）'
       else '🔴 ① paid_count = ' || (select v ->> 'paid_count' from 回傳)
            || '　但玩家有 ' || (select 應該幾人 from 樣本) || ' 列' end
  as ①收桌後不歸零,

  /* ② 🎯 正對照一：還沒有配到桌的房仍然是 0。
     ⚠ 只驗①的話，把 paid_count 寫死成 seats 也會通過。 */
  case when not exists (select 1 from match_queues
                         where matched_session_id is null
                           and created_at::date = current_date)
       then '⚪ ② 今天沒有「還沒配到桌」的房可以對照'
       when (select max((e.v ->> 'paid_count')::int)
               from jsonb_array_elements(
                      pos_list_queues_tx(
                        (select org_id from match_queues where matched_session_id is null
                          and created_at::date = current_date limit 1),
                        (select store_id from match_queues where matched_session_id is null
                          and created_at::date = current_date limit 1))) e(v)
              where (e.v ->> 'session_status') is null) = 0
       then '✅ ② 沒配到桌的房 paid_count 仍然是 0'
       else '🔴 ② 沒配到桌的房居然不是 0 —— 改過頭了' end
  as ②正對照_沒配到桌,

  /* ③ 🎯 正對照二：鍵的總數沒變。
     期望值 23 是 2026-09-06 補 `auto_seat` 之後查出來的（不是憑印象）。 */
  case when (select count(*) from 回傳, jsonb_object_keys(回傳.v)) = 23
       then '✅ ③ 回傳仍然是 23 個鍵'
       else '🔴 ③ 鍵數變成 '
            || (select count(*) from 回傳, jsonb_object_keys(回傳.v))::text
            || ' —— 23 = 22 原本 ＋ auto_seat' end
  as ③鍵數沒變,

  /* ④ 🎯 正對照三：那個條件真的從函式裡消失了。
     ⚠ 禁字用 `sp.left_at is null` 這種**會產生行為的寫法**，
       不是「left_at」三個字 —— 後者在我自己的註解裡就有（硬規則 3.5）。 */
  case when (select count(*) from pg_proc p
              where p.pronamespace = 'public'::regnamespace
                and p.proname = 'pos_list_queues_tx'
                and pg_get_functiondef(p.oid) ~ 'sp\.left_at\s+is\s+null') = 0
       then '✅ ④ 函式裡已經沒有 sp.left_at is null'
       else '🔴 ④ 還在' end
  as ④條件已移除;
