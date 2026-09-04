/* ============================================================
   合併會員之前的盤點（待辦 15）
   2026-09-04 · MIGI · 唯讀

   🔴 **這一份存在的理由：CLAUDE.md 的合併計畫寫「搬 rows（改 member_id）」，
     而那會漏掉 9 個欄位。**

   ── 2026-09-04 的實際結果 ────────────────────────────
   **25 個外鍵指向 `members`，只有 16 個叫 `member_id`。**

   另外 9 個叫別的名字，其中**四對是自我參照**：
   | 表 | 兩個欄位 | 合併後 |
   |---|---|---|
   | `mahjong_buddies` | `member_id` / `buddy_id` | 🔴 自己是自己的牌咖 —— 而它有 `CHECK (member_id <> buddy_id)` |
   | `member_blocks` | `blocker_id` / `blocked_id` | 自己封鎖自己 |
   | `member_likes` | `liker_id` / `target_id` | 自己按讚自己 |
   | `buddy_invites` | `inviter_id` / `invitee_id` | 自己邀請自己 |
   剩下 1 個：`match_queues.opened_by`、`session_players.paid_by`（單向，不衝突）。

   🔴 **撞 CHECK 跟撞唯一鍵不一樣**：唯一鍵可以用 `on conflict do nothing`
     繞過，CHECK 會讓**整個交易拋錯**。
   ✅ 這一次算是好事（fail loud，不是靜默出錯），
     但沒處理就是**合併永遠跑不完**。

   ── ⚠ 兩個數字漂了，而且是我自己弄漂的 ──────────────
   CLAUDE.md 待辦 15 記「23 個外鍵」與 7 個唯一鍵，實際是 **25** 與 **8** ——
   差額全部來自 **2026-09-03 我自己新建的 `season_standings` / `season_champions`**。
   🎯 **那正是「合併工具越晚做越貴」的具體證明**：
     每加一張帶 member_id 的表，合併就多一個要處理的點，
     而**沒有任何東西會提醒你**。

   ✅ **仍然成立的**：25 個外鍵**沒有一個是 CASCADE**（21 RESTRICT ＋ 4 NO ACTION）。
     🔴 CASCADE 才是最怕的（刪舊帳號時資料靜默消失）；
     **RESTRICT 反而是保護：搬不完就刪不掉，它會逼你做完。**
   ============================================================ */

-- ① 所有指向 members 的外鍵（含**不叫 member_id** 的那些）
select '① 外鍵' as 段,
       c.conrelid::regclass::text as 表,
       (select string_agg(a.attname, ', ' order by k.ord)
          from unnest(c.conkey) with ordinality k(att, ord)
          join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.att) as 欄位,
       case c.confdeltype
         when 'a' then 'NO ACTION' when 'r' then 'RESTRICT'
         when 'c' then '🔴 CASCADE' when 'n' then 'SET NULL' when 'd' then 'SET DEFAULT'
       end as 刪除時
  from pg_constraint c
 where c.contype = 'f' and c.confrelid = 'public.members'::regclass
 order by 欄位, 表;

-- ② 含 member_id 的唯一約束／唯一索引
--    ⚠ **兩邊都要看**：`CREATE UNIQUE INDEX` 建的不會出現在 `pg_constraint` 裡
--      （待辦 29 ② 踩過這個坑）。
select '② 唯一鍵' as 段,
       t.relname as 表, i.relname as 索引,
       exists (select 1 from pg_constraint c where c.conindid = x.indexrelid) as 是約束,
       pg_get_indexdef(x.indexrelid) as 定義
  from pg_index x
  join pg_class i on i.oid = x.indexrelid
  join pg_class t on t.oid = x.indrelid
  join pg_namespace n on n.oid = t.relnamespace
 where n.nspname = 'public' and x.indisunique
   and pg_get_indexdef(x.indexrelid) ~ '\(([^)]*, *)?member_id'
 order by t.relname;

-- ③ 自我參照的表有哪些 CHECK（🔴 合併會撞的是這些，不只唯一鍵）
select '③ 自我參照的 CHECK' as 段,
       c.conrelid::regclass::text as 表,
       c.conname as 約束,
       pg_get_constraintdef(c.oid) as 定義
  from pg_constraint c
 where c.contype = 'c'
   and c.conrelid in ('public.mahjong_buddies'::regclass, 'public.member_blocks'::regclass,
                      'public.member_likes'::regclass,   'public.buddy_invites'::regclass)
 order by 表, 約束;

-- ④ 現在有幾個會員、幾個綁了 LINE（判斷「今天會不會真的發生」）
select '④ 會員現況' as 段,
       count(*) as 會員數,
       count(*) filter (where line_user_id is not null) as 綁了LINE,
       count(*) filter (where phone is not null) as 有手機,
       count(*) filter (where is_test) as 測試帳號,
       count(*) filter (where deleted_at is not null) as 已軟刪
  from members;
