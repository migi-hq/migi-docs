/* ============================================================
   會員合併：`member_merges` 紀錄表 ＋ `merge_members_tx`
   2026-09-04 · MIGI · 待辦 15

   ── ✅ 2026-09-04 稍晚改口：**現在就跑** ──────────────
   這份原本標了「⏸ 暫緩」，理由是「現在上線它會是第 N 個建了沒人讀」。
   🔴 **那個判斷混淆了兩件事：寫它的成本，與跑它的成本。**
   · 反對的其實是「**花時間寫它**」—— 而那個成本已經付掉了
   · 剩下的只有「**要不要讓那 16 格驗證跑一次**」，而那的成本是零

   🎯 不跑的代價很具體：驗證要等到**真的有客訴、有兩個帳號要合併的
     那一天**才第一次執行 —— 那是**最不想除錯的時刻**。
     硬規則 7 講的正是這件事：**從未成功執行過的函式，
     它的每一行邏輯都從未被驗證。**

   ⚠ 唯一的真代價是「日後加表就少搬一個欄位」——
     但**那個問題跑不跑都存在**，而且跑了反而更容易發現：
     ✅ 錯誤儀表第 ⑨ 段已加上守衛，**盯「指向 members 的外鍵是不是還是 25 個」**，
       變了就叫你重跑 `checks/2026-09-04_合併會員前的盤點.sql`。

   ⚠ **它今天仍然沒有人能按**（migi-admin 沒有那一頁）——
     那是**下一批的事**，不是不跑這一份的理由。
     函式在線上、驗過、`can()` 擋著、`p_confirm` 擋著 ⇒ 不會被誤觸。

   ── 🔴 原本「為什麼寫好了卻不跑」的分析（保留，因為它的前半段仍然成立）──
   CLAUDE.md 待辦 21 ④ 把它列為「開 JWT 之前的阻擋條件」，理由是
   **「JWT 上線那一刻 LINE↔member 就固定下來，之後更難拆」**。

   🎯 **那個推論有一個缺口**：
   ```
   綁定固定下來  ⇐ 有重複帳號  ⇐ 有真實客人
   ```
   而 2026-09-04 的事實是：

   | | |
   |---|---|
   | 真實客人 | **0 個** |
   | 會員總數 | 5（4 個測試 ＋ 創辦人） |
   | A3「手機對得上就自動綁」的洞 | ✅ 2026-08-30 已堵 |
   | E（手機與 LINE 都換） | ✅ 已有自助認領 `claim_member_by_phone_tx` |

   ⇒ **真正的截止點是「真實客人開始註冊」＝上線當天，不是「JWT 之前」。**
     而 JWT 會在上線之前做完 ⇒ 原本那個截止點**過度保守**。

   ── ⚠ 現在上線的話，它會是第 N 個「建了沒人讀」──────
   合併要三步，這份只是第 ③ 步的執行器：
   ```
   ① 發現「這兩個是同一個人」    ← 沒有工具
   ② migi-admin 有一頁能按        ← 不存在
   ③ 執行合併                     ← 就是這一份
   ```
   前兩步都沒有 ⇒ 今天跑下去就是一支沒有人叫得動的函式。

   ── ✅ 觸發條件（滿足任一就跑這份）──────────────────
   · **設 `orgs.live_from` 那天**（上線當天清單的一部分）
   · 或更早：`members` 出現**第一個不是自己人的帳號**
     📌 錯誤儀表第 ⑧ 段「近 14 天的新會員」就是在盯這件事
   ⚠ 跑之前先重跑 `sql/checks/2026-09-04_合併會員前的盤點.sql` ——
     **每加一張帶 member_id 的表，這份就少搬一個欄位**（見下面第 ③ 點）。

   ⚠ CLAUDE.md 待辦 15 原本寫的另一個理由「做出來也沒人能按（需要
     `p_staff_id`，而店員登入卡在 LINE）」——**那個理由已經不成立**：
     合併是**總部級**操作，走 migi-admin 的 **Email Auth**（`staff.auth_uid`），
     而那條路今天就通（`can()` 已建立並實測）。
     🔴 **不成立的是那個理由，不是結論** —— 結論改由上面那個缺口支撐。

   ============================================================
   🔴 動手前盤點挖到的三件事（`sql/checks/2026-09-04_合併會員前的盤點.sql`）
   ============================================================
   **① 25 個外鍵指向 `members`，只有 16 個叫 `member_id`。**
   CLAUDE.md 的計畫寫「搬 rows（改 `member_id`）」—— **那會漏掉 9 個欄位**。

   **② 其中四對是自我參照，而且四對都有 `<>` 的 CHECK：**
   ```
   mahjong_buddies  CHECK (member_id  <> buddy_id)
   member_blocks    CHECK (blocker_id <> blocked_id)
   member_likes     CHECK (liker_id   <> target_id)
   buddy_invites    CHECK (inviter_id <> invitee_id)
   ```
   🔴 **撞 CHECK 跟撞唯一鍵不一樣**：唯一鍵可以 `on conflict do nothing`，
     CHECK 會讓**整個交易拋錯**。
   ✅ 這算好事（fail loud），但沒處理就是**合併永遠跑不完**。

   **③ 兩個數字漂了，而且是我自己弄漂的。**
   CLAUDE.md 記「23 個外鍵、7 個唯一鍵」，實際是 **25** 與 **8** ——
   差額全部來自 **2026-09-03 我自己新建的 `season_standings` / `season_champions`**。
   🎯 **那正是「越晚做越貴」的具體證明**：每加一張帶 member_id 的表，
     合併就多一個要處理的點，而**沒有任何東西會提醒你**。

   ✅ **仍然成立**：25 個外鍵**沒有一個是 CASCADE**（21 RESTRICT ＋ 4 NO ACTION）。
     🔴 CASCADE 才是最怕的（刪舊帳號時資料靜默消失）；
     **RESTRICT 反而是保護：搬不完就刪不掉，它會逼你做完。**

   ============================================================
   設計決定
   ============================================================
   **🔴 全部用 `raise`，不回 `{ok:false}`。**
   CLAUDE.md 記過 `join_session_tx` 那個坑：回 `{ok:false}` 而不拋，
   交易照樣提交。在這裡更嚴重 —— **一半完成的合併比什麼都沒做更糟**。

   **🔴 `p_confirm` 必須是字串 `'MERGE'`。**
   不可逆操作要有確認步驟。參數順序打錯（keep / drop 相反）
   會把**歷史比較貴的那個**軟刪掉，而 `p_confirm` 至少讓人停一秒。

   **硬擋兩件事（不是警告，是拒絕）：**
   | | 為什麼 |
   |---|---|
   | `drop` 有**已開立**發票 | 法律文件不能改開給別人（待辦 15 的硬條件 ①） |
   | 兩人在**同一場次**都有 `session_players` | 🔴 同一個人分飾兩角 ⇒ **檯費收了兩次**。那不只是資料問題，**是要不要退款的問題** —— 不該由一支函式決定 |

   **餘額用重算不用相加。**
   `wallet_txns` **沒有觸發器同步餘額**，所以「相加」是假設兩邊 `balance` 都對。
   搬完流水後呼叫 `fix_wallet_balance_tx(org, keep)` 重算 —— **能重算就不要相加**。

   **搬 `line_user_id`，不搬歷史；順序是：搬 rows → 軟刪 loser → 才寫 line_user_id。**
   ✅ `uq_members_line_user` 的 `WHERE deleted_at IS NULL` 讓順序做錯會**被擋下來**，
     不會靜默出錯 —— **索引本身就是順序的守衛**。

   **硬搬，不做別名**（`merged_into` 指標）。
   別名會讓**每一支查詢都必須記得跟指標**，漏一支就查到空的而且不報錯 ——
   那比「建了沒人讀」更糟。
   ============================================================ */

-- ── 合併紀錄（不可逆操作要留痕）────────────────────────
create table if not exists public.member_merges (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.orgs(id),
  kept_id       uuid not null references public.members(id),
  dropped_id    uuid not null references public.members(id),
  staff_id      uuid references public.staff(id),
  moved         jsonb not null default '{}'::jsonb,   -- 每張表搬了幾列
  notes         jsonb not null default '{}'::jsonb,   -- 去重/刪除/衝突處理的明細
  created_at    timestamptz not null default now(),
  constraint member_merges_not_self check (kept_id <> dropped_id)
);

comment on table public.member_merges is
  '會員合併紀錄。不可逆操作，moved 記每張表搬了幾列、notes 記去重與衝突處理。';

/* ⚠ 一個人只能被併掉一次 —— 併掉之後他就軟刪了，不該再出現。 */
create unique index if not exists uq_member_merges_dropped
  on public.member_merges(dropped_id);

alter table public.member_merges enable row level security;
/* 🔴 **刻意 0 條 policy** —— 只有 SECURITY DEFINER 進得去。
   那是這個系統裡最安全的狀態（46 張表裡有 20 張是這樣），
   不是「漏掉沒設」。要讓總部在後台看合併紀錄時，
   加的是一條 `can('member.merge')`，不是放寬成 org 級。 */


-- ── 合併本體 ──────────────────────────────────────────
create or replace function public.merge_members_tx(
  p_org_id   uuid,
  p_keep_id  uuid,
  p_drop_id  uuid,
  p_staff_id uuid    default null,
  p_confirm  text    default null
) returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_keep members%rowtype;
  v_drop members%rowtype;
  v_moved jsonb := '{}'::jsonb;
  v_notes jsonb := '{}'::jsonb;
  v_n int;
  v_bal jsonb;
  v_titles jsonb;
begin
  ---- ① 擋牆 ------------------------------------------
  if p_confirm is distinct from 'MERGE' then
    raise exception 'confirm_required：不可逆操作，p_confirm 必須是 ''MERGE''';
  end if;

  /* ⚠ `can()` 讀的是**呼叫者**的 JWT —— DEFINER 不影響 `auth.jwt()`，
     所以這道牆在 DEFINER 裡仍然有效。 */
  if not public.can('member.merge') then
    raise exception 'forbidden：合併會員是總部級操作';
  end if;

  if p_keep_id = p_drop_id then
    raise exception 'same_member：留下的與併掉的是同一個人';
  end if;

  select * into v_keep from members where id = p_keep_id and org_id = p_org_id;
  if not found then raise exception 'keep_not_found'; end if;
  if v_keep.deleted_at is not null then
    raise exception 'keep_deleted：要留下的那個已經被軟刪了';
  end if;

  select * into v_drop from members where id = p_drop_id and org_id = p_org_id;
  if not found then raise exception 'drop_not_found'; end if;
  if v_drop.deleted_at is not null then
    raise exception 'drop_already_deleted：那個帳號已經被併掉或刪掉了';
  end if;

  /* 🔴 硬條件：已開立的發票是法律文件，不能改開給別人。
     ⚠ `invoices` 是**多型關聯**（`ref_table` + `ref_id`），不是 `order_id`
       —— 所以 orders 與 topup_orders 兩條路都要看。 */
  if exists (
    select 1 from invoices i
     where i.status = 'issued'
       and ((i.ref_table = 'orders'
             and exists (select 1 from orders o where o.id = i.ref_id and o.member_id = p_drop_id))
         or (i.ref_table = 'topup_orders'
             and exists (select 1 from topup_orders t where t.id = i.ref_id and t.member_id = p_drop_id)))
  ) then
    raise exception 'drop_has_issued_invoice：被併掉的帳號有已開立發票，'
      '請改成留下它（法律文件不能改開給別人）';
  end if;

  /* 🔴 硬條件：兩人在同一場次都入座過 ⇒ 同一個人分飾兩角 ⇒ **檯費收了兩次**。
     那是**要不要退款**的問題，不該由一支函式默默決定。 */
  if exists (
    select 1 from session_players a
     where a.member_id = p_keep_id
       and exists (select 1 from session_players b
                    where b.member_id = p_drop_id and b.session_id = a.session_id)
  ) then
    raise exception 'same_session_conflict：兩個帳號在同一場次都入座過'
      '（＝檯費可能收了兩次）。請先處理退款再合併';
  end if;

  ---- ② 先刪「合併後會自我參照」的列 --------------------
  /* 🔴 這四張表都有 `<>` 的 CHECK，不先刪會讓整個交易拋錯。
     ⚠ 刪的是「A 與 B 之間的關係」—— 合併後那個關係不存在了
       （你不會是自己的牌咖），所以刪掉是正確語意不是資料遺失。 */
  delete from mahjong_buddies
   where (member_id = p_keep_id and buddy_id = p_drop_id)
      or (member_id = p_drop_id and buddy_id = p_keep_id);
  get diagnostics v_n = row_count;
  v_notes := v_notes || jsonb_build_object('自我參照_牌咖', v_n);

  delete from member_blocks
   where (blocker_id = p_keep_id and blocked_id = p_drop_id)
      or (blocker_id = p_drop_id and blocked_id = p_keep_id);
  get diagnostics v_n = row_count;
  v_notes := v_notes || jsonb_build_object('自我參照_封鎖', v_n);

  delete from member_likes
   where (liker_id = p_keep_id and target_id = p_drop_id)
      or (liker_id = p_drop_id and target_id = p_keep_id);
  get diagnostics v_n = row_count;
  v_notes := v_notes || jsonb_build_object('自我參照_按讚', v_n);

  delete from buddy_invites
   where (inviter_id = p_keep_id and invitee_id = p_drop_id)
      or (inviter_id = p_drop_id and invitee_id = p_keep_id);
  get diagnostics v_n = row_count;
  v_notes := v_notes || jsonb_build_object('自我參照_邀請', v_n);

  ---- ③ 再刪「合併後會撞唯一鍵」的列（保留 keep 的）------
  /* ⚠ 一律**保留 keep 那一列、刪掉 drop 那一列** ——
     那些都是「狀態」不是「歷史」（是不是牌咖、在不在隊列、
     偏好哪個時段），保留哪一份在語意上沒有差別。
     🔴 唯一有差別的是 `wallets` 與 `member_app_state`，各自另外處理（見 ⑤⑥）。 */
  delete from mahjong_buddies d
   where d.member_id = p_drop_id
     and exists (select 1 from mahjong_buddies k
                  where k.member_id = p_keep_id and k.buddy_id = d.buddy_id
                    and k.deleted_at is null)
     and d.deleted_at is null;
  get diagnostics v_n = row_count;
  v_notes := v_notes || jsonb_build_object('去重_牌咖', v_n);

  /* ⚠ 反方向也要去重：別人把兩個帳號**都**加成牌咖。 */
  delete from mahjong_buddies d
   where d.buddy_id = p_drop_id
     and exists (select 1 from mahjong_buddies k
                  where k.buddy_id = p_keep_id and k.member_id = d.member_id
                    and k.deleted_at is null)
     and d.deleted_at is null;
  get diagnostics v_n = row_count;
  v_notes := v_notes || jsonb_build_object('去重_牌咖反向', v_n);

  delete from match_queue_players d
   where d.member_id = p_drop_id
     and exists (select 1 from match_queue_players k
                  where k.member_id = p_keep_id and k.queue_id = d.queue_id
                    and k.left_at is null)
     and d.left_at is null;
  get diagnostics v_n = row_count;
  v_notes := v_notes || jsonb_build_object('去重_隊列', v_n);

  delete from member_availability d
   where d.member_id = p_drop_id
     and exists (select 1 from member_availability k
                  where k.member_id = p_keep_id and k.weekday = d.weekday
                    and k.slot = d.slot and k.source = d.source);
  get diagnostics v_n = row_count;
  v_notes := v_notes || jsonb_build_object('去重_時段', v_n);

  delete from staff d
   where d.member_id = p_drop_id
     and exists (select 1 from staff k
                  where k.member_id = p_keep_id and k.store_id is not distinct from d.store_id
                    and k.deleted_at is null)
     and d.deleted_at is null;
  get diagnostics v_n = row_count;
  v_notes := v_notes || jsonb_build_object('去重_店員', v_n);

  /* `season_standings` 同一季兩筆 → **取段位分高的那一筆**。
     ⚠ 不是「取名次好的」—— 名次是**當季所有人比較**出來的結果，
       兩筆的名次來自同一次排名，取高分那筆的名次才對得上。 */
  delete from season_standings d
   where d.member_id = p_drop_id
     and exists (select 1 from season_standings k
                  where k.member_id = p_keep_id and k.org_id = d.org_id
                    and k.season = d.season and k.rating >= d.rating);
  get diagnostics v_n = row_count;
  v_notes := v_notes || jsonb_build_object('去重_賽季名次_丟掉drop', v_n);

  delete from season_standings k
   where k.member_id = p_keep_id
     and exists (select 1 from season_standings d
                  where d.member_id = p_drop_id and d.org_id = k.org_id
                    and d.season = k.season and d.rating > k.rating);
  get diagnostics v_n = row_count;
  v_notes := v_notes || jsonb_build_object('去重_賽季名次_drop較高', v_n);

  ---- ④ 搬 25 個欄位 -----------------------------------
  /* 🔴 **不只是 `member_id`** —— 9 個叫別的名字，漏一個就是資料留在死帳號上。 */
  update app_events            set member_id = p_keep_id where member_id = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('app_events', v_n);

  update app_notifications     set member_id = p_keep_id where member_id = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('app_notifications', v_n);

  update mahjong_buddies       set member_id = p_keep_id where member_id = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('mahjong_buddies.member_id', v_n);

  update mahjong_buddies       set buddy_id  = p_keep_id where buddy_id  = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('mahjong_buddies.buddy_id', v_n);

  update match_queue_players   set member_id = p_keep_id where member_id = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('match_queue_players', v_n);

  update match_queues          set opened_by = p_keep_id where opened_by = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('match_queues.opened_by', v_n);

  update member_availability   set member_id = p_keep_id where member_id = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('member_availability', v_n);

  update member_blocks         set blocker_id = p_keep_id where blocker_id = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('member_blocks.blocker_id', v_n);

  update member_blocks         set blocked_id = p_keep_id where blocked_id = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('member_blocks.blocked_id', v_n);

  update member_coupons        set member_id = p_keep_id where member_id = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('member_coupons', v_n);

  update member_interactions   set member_id = p_keep_id where member_id = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('member_interactions', v_n);

  update member_likes          set liker_id  = p_keep_id where liker_id  = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('member_likes.liker_id', v_n);

  update member_likes          set target_id = p_keep_id where target_id = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('member_likes.target_id', v_n);

  update buddy_invites         set inviter_id = p_keep_id where inviter_id = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('buddy_invites.inviter_id', v_n);

  update buddy_invites         set invitee_id = p_keep_id where invitee_id = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('buddy_invites.invitee_id', v_n);

  update orders                set member_id = p_keep_id where member_id = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('orders', v_n);

  update topup_orders          set member_id = p_keep_id where member_id = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('topup_orders', v_n);

  update season_champions      set member_id = p_keep_id where member_id = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('season_champions', v_n);

  update season_standings      set member_id = p_keep_id where member_id = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('season_standings', v_n);

  update session_players       set member_id = p_keep_id where member_id = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('session_players', v_n);

  update session_players       set paid_by   = p_keep_id where paid_by   = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('session_players.paid_by', v_n);

  update staff                 set member_id = p_keep_id where member_id = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('staff', v_n);

  update wallet_txns           set member_id = p_keep_id where member_id = p_drop_id;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('wallet_txns', v_n);

  ---- ⑤ 錢包：搬完流水後**重算**，不相加 ----------------
  /* 🔴 `wallets` 的 PK 是 `member_id`，兩邊各有一列 ⇒ 不能直接 update。
     ⚠ 而且 `wallet_txns` **沒有觸發器同步餘額**（CLAUDE.md 記過），
       所以「兩邊 balance 相加」是**假設兩邊都對**。流水已經全部搬過來了，
       **重算才是唯一不需要假設的做法**。 */
  delete from wallets where member_id = p_drop_id;
  get diagnostics v_n = row_count; v_notes := v_notes || jsonb_build_object('刪除_drop錢包', v_n);

  v_bal := public.fix_wallet_balance_tx(p_org_id, p_keep_id);
  v_notes := v_notes || jsonb_build_object('重算後餘額', v_bal);

  ---- ⑥ App 狀態：titles 聯集、bear 保留 keep 的 ---------
  /* ⚠ `titles` 是成就（只增不減），**聯集**才對；
     `bear` 是他自己選的造型，**保留 keep 的** —— 那是偏好不是成就。
     🔴 `member_app_state` 的 PK 是 `member_id`，所以要先合再刪。 */
  select coalesce(k.titles, '[]'::jsonb) || coalesce(d.titles, '[]'::jsonb)
    into v_titles
    from (select titles from member_app_state where member_id = p_keep_id) k
    full join (select titles from member_app_state where member_id = p_drop_id) d on true;

  if v_titles is not null then
    /* 聯集要去重：`||` 只是接起來。 */
    select coalesce(jsonb_agg(distinct t), '[]'::jsonb) into v_titles
      from jsonb_array_elements(v_titles) t;

    if exists (select 1 from member_app_state where member_id = p_keep_id) then
      update member_app_state set titles = v_titles, updated_at = now()
       where member_id = p_keep_id;
    else
      insert into member_app_state (member_id, org_id, titles)
      values (p_keep_id, p_org_id, v_titles);
    end if;
    v_notes := v_notes || jsonb_build_object('稱號聯集', v_titles);
  end if;

  delete from member_app_state where member_id = p_drop_id;
  get diagnostics v_n = row_count; v_notes := v_notes || jsonb_build_object('刪除_drop_app狀態', v_n);

  ---- ⑦ 軟刪 loser，**然後才**搬 line_user_id -----------
  /* 🔴 順序不能反：`uq_members_line_user` 是
     `UNIQUE (line_user_id) WHERE deleted_at IS NULL` ——
     先搬會撞唯一鍵。
     ✅ **索引本身就是順序的守衛**，做錯會被擋下來而不是靜默出錯。 */
  update members
     set deleted_at = now(),
         line_user_id = null,        -- 讓出來，不然軟刪也擋不住重複
         phone = null
   where id = p_drop_id;

  /* 只在 keep 沒有的時候才搬 —— **keep 的身分優先**。 */
  if v_keep.line_user_id is null and v_drop.line_user_id is not null then
    update members set line_user_id = v_drop.line_user_id where id = p_keep_id;
    v_notes := v_notes || jsonb_build_object('搬了line_user_id', true);
  end if;

  if v_keep.phone is null and v_drop.phone is not null then
    update members set phone = v_drop.phone,
                       phone_verified_at = v_drop.phone_verified_at
     where id = p_keep_id;
    v_notes := v_notes || jsonb_build_object('搬了phone', true);
  end if;

  ---- ⑧ 留痕 ------------------------------------------
  insert into member_merges (org_id, kept_id, dropped_id, staff_id, moved, notes)
  values (p_org_id, p_keep_id, p_drop_id, p_staff_id, v_moved, v_notes);

  return jsonb_build_object(
    'ok', true, 'kept', p_keep_id, 'dropped', p_drop_id,
    'moved', v_moved, 'notes', v_notes);
end;
$function$;

comment on function public.merge_members_tx(uuid, uuid, uuid, uuid, text) is
  '合併兩個會員。不可逆，p_confirm 必須是 MERGE，需要 can(member.merge)。'
  '硬擋：drop 有已開立發票、兩人在同一場次都入座過。餘額用重算不用相加。';

/* 🔴 兩個方向都要收（硬規則 2.6b）。
   ⚠ `authenticated` 要留 —— migi-admin 用真的 Supabase Auth，
     它就是走這個角色。權限由函式內的 `can()` 把關。 */
revoke execute on function public.merge_members_tx(uuid, uuid, uuid, uuid, text) from public;
revoke execute on function public.merge_members_tx(uuid, uuid, uuid, uuid, text) from anon;
grant  execute on function public.merge_members_tx(uuid, uuid, uuid, uuid, text) to authenticated, service_role;


-- ══════════════════════════════════════════════════════
-- 驗證：造兩個假會員 → 真的合併 → 逐項檢查 → 全部回滾
-- ══════════════════════════════════════════════════════
/* 🔴 硬規則 7：**RPC 寫完必須實際執行並看到回傳才算完成**，而且
   **從未成功執行過的函式，它的每一行邏輯都從未被驗證。**
   所以這裡不是「叫一次看有沒有拋錯」，是**故意造出每一種衝突**：
   自我參照 ×1、唯一鍵 ×3、稱號聯集、餘額重算、以及兩道硬擋的正對照。
   ⚠ 全部包在 `raise exception 'migi_rollback'` 裡，**一列都不會真的寫進去**
     （沒有 staging，硬規則 5.7）。 */
do $$
declare
  v_out text := '';
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_a uuid; v_b uuid; v_c uuid; v_store uuid; v_sess uuid;
  v_r jsonb; v_n int; v_bal int; v_txt text;
begin
  begin
    select id into v_store from stores where org_id = v_org limit 1;

    ---- 造 A（keep）、B（drop）、C（第三人，用來製造衝突）----
    insert into members (org_id, display_name) values (v_org, '合併測試甲') returning id into v_a;
    insert into members (org_id, display_name, line_user_id, phone)
      values (v_org, '合併測試乙', 'U_merge_test_b', '0900000001') returning id into v_b;
    insert into members (org_id, display_name) values (v_org, '合併測試丙') returning id into v_c;

    ---- 造衝突 ------------------------------------------
    -- ① 自我參照：A 與 B 互為牌咖 → 合併後會變成「自己是自己的牌咖」
    insert into mahjong_buddies (org_id, member_id, buddy_id, origin)
      values (v_org, v_a, v_b, 'matched');
    -- ② 唯一鍵：A 與 B 都跟 C 是牌咖 → 合併後撞 uq_buddies
    insert into mahjong_buddies (org_id, member_id, buddy_id, origin)
      values (v_org, v_a, v_c, 'matched'), (v_org, v_b, v_c, 'pre_existing');
    -- ③ 唯一鍵：兩人同一個 (weekday, slot, source)
    insert into member_availability (org_id, member_id, weekday, slot)
      values (v_org, v_a, 3, 'evening'), (v_org, v_b, 3, 'evening');
    -- ④ 唯一鍵：同一季的名次快照，B 的段位分比較高
    insert into season_standings (org_id, season, member_id, rating, rank_no, games)
      values (v_org, '_merge_test', v_a, 100, 50, 5),
             (v_org, '_merge_test', v_b, 300, 10, 9);
    -- ⑤ 稱號聯集
    insert into member_app_state (member_id, org_id, titles)
      values (v_a, v_org, '["新手上路"]'::jsonb), (v_b, v_org, '["三屆雀神","新手上路"]'::jsonb);
    -- ⑥ 餘額：兩邊各有流水（🔴 wallets 由觸發器自動建立）
    insert into wallet_txns (org_id, member_id, type, amount)
      values (v_org, v_a, 'topup', 100), (v_org, v_b, 'topup', 250), (v_org, v_b, 'spend', -50);

    ---- 🎯 正對照 ①：沒有 can() 會被擋 -------------------
    /* ⚠ 這裡不換 role（換了就叫不動函式），改成把 claims 設成
       一個**沒有 staff 列**的 sub —— `can()` 讀的就是它。 */
    perform set_config('request.jwt.claims',
      '{"sub":"99999999-9999-9999-9999-999999999999"}', true);
    begin
      v_r := public.merge_members_tx(v_org, v_a, v_b, null, 'MERGE');
      v_txt := '🔴 竟然通過了';
    exception when others then
      v_txt := case when sqlerrm like 'forbidden%' then '✅ 擋住了' else '🔴 ' || sqlerrm end;
    end;
    v_out := v_out || E'\n' || '① 🎯 沒有 can(member.merge) 會被擋' || E'\t' || v_txt;

    ---- 換成總部身分 -------------------------------------
    perform set_config('request.jwt.claims',
      (select '{"sub":' || to_json(auth_uid::text)::text || '}'
         from staff where auth_uid is not null and deleted_at is null limit 1), true);

    ---- 🎯 正對照 ②：p_confirm 打錯會被擋 -----------------
    begin
      v_r := public.merge_members_tx(v_org, v_a, v_b, null, 'merge');
      v_txt := '🔴 竟然通過了';
    exception when others then
      v_txt := case when sqlerrm like 'confirm_required%' then '✅ 擋住了' else '🔴 ' || sqlerrm end;
    end;
    v_out := v_out || E'\n' || '② 🎯 p_confirm 不是 ''MERGE'' 會被擋' || E'\t' || v_txt;

    ---- 🎯 正對照 ③：同場次衝突會被擋（檯費收兩次）--------
    if v_store is not null then
      insert into table_sessions (org_id, store_id, table_id, status)
        select v_org, v_store, t.id, 'open' from tables t where t.store_id = v_store limit 1
        returning id into v_sess;
      if v_sess is not null then
        insert into session_players (org_id, session_id, member_id)
          values (v_org, v_sess, v_a), (v_org, v_sess, v_b);
        begin
          v_r := public.merge_members_tx(v_org, v_a, v_b, null, 'MERGE');
          v_txt := '🔴 竟然通過了 —— 檯費收兩次會被默默合併掉';
        exception when others then
          v_txt := case when sqlerrm like 'same_session_conflict%' then '✅ 擋住了'
                        else '🔴 ' || sqlerrm end;
        end;
        v_out := v_out || E'\n' || '③ 🎯 同場次都入座過會被擋（＝檯費收兩次）' || E'\t' || v_txt;
        -- 清掉，讓後面的正式合併跑得下去
        delete from session_players where session_id = v_sess;
        delete from table_sessions where id = v_sess;
      end if;
    end if;

    ---- 🎯 真的合併一次 -----------------------------------
    begin
      v_r := public.merge_members_tx(v_org, v_a, v_b, null, 'MERGE');
      v_txt := '✅ 成功';
    exception when others then v_txt := '🔴 ' || sqlerrm; end;
    v_out := v_out || E'\n' || '④ 🎯 正式合併' || E'\t' || v_txt;

    ---- 逐項驗收 -----------------------------------------
    select count(*) into v_n from mahjong_buddies
     where member_id = v_a and buddy_id = v_a;
    v_out := v_out || E'\n' || '⑤ 🔴 沒有「自己是自己的牌咖」（CHECK 會炸）' || E'\t' ||
      case when v_n = 0 then '✅ 0 列' else '🔴 ' || v_n || ' 列' end;

    select count(*) into v_n from mahjong_buddies
     where member_id = v_a and buddy_id = v_c and deleted_at is null;
    v_out := v_out || E'\n' || '⑥ 🎯 跟 C 的牌咖關係去重成 1 列' || E'\t' ||
      case when v_n = 1 then '✅' else '🔴 ' || v_n || ' 列' end;

    select count(*) into v_n from member_availability
     where member_id = v_a and weekday = 3 and slot = 'evening';
    v_out := v_out || E'\n' || '⑦ 🎯 常來時段去重成 1 列' || E'\t' ||
      case when v_n = 1 then '✅' else '🔴 ' || v_n || ' 列' end;

    select count(*), max(rating) into v_n, v_bal from season_standings
     where member_id = v_a and season = '_merge_test';
    v_out := v_out || E'\n' || '⑧ 🎯 同季名次留 1 筆，且取段位分高的' || E'\t' ||
      case when v_n = 1 and v_bal = 300 then '✅ 1 筆 · 300 分'
           else '🔴 ' || v_n || ' 筆 · ' || coalesce(v_bal, -1) || ' 分' end;

    select balance into v_bal from wallets where member_id = v_a;
    v_out := v_out || E'\n' || '⑨ 🎯 餘額是**重算**出來的（100＋250－50）' || E'\t' ||
      case when v_bal = 300 then '✅ 300' else '🔴 ' || coalesce(v_bal, -1) end;

    select count(*) into v_n from wallets where member_id = v_b;
    v_out := v_out || E'\n' || '⑩ drop 的錢包已刪除' || E'\t' ||
      case when v_n = 0 then '✅' else '🔴 還在' end;

    select jsonb_array_length(titles) into v_n from member_app_state where member_id = v_a;
    v_out := v_out || E'\n' || '⑪ 🎯 稱號是聯集且去重（新手上路＋三屆雀神＝2）' || E'\t' ||
      case when v_n = 2 then '✅ 2 個' else '🔴 ' || coalesce(v_n, -1) || ' 個' end;

    select count(*) into v_n from wallet_txns where member_id = v_b;
    v_out := v_out || E'\n' || '⑫ 流水全部搬走（drop 剩 0 筆）' || E'\t' ||
      case when v_n = 0 then '✅' else '🔴 還有 ' || v_n || ' 筆' end;

    select line_user_id into v_txt from members where id = v_a;
    v_out := v_out || E'\n' || '⑬ 🎯 line_user_id 搬到存活者' || E'\t' ||
      case when v_txt = 'U_merge_test_b' then '✅' else '🔴 ' || coalesce(v_txt, 'null') end;

    select count(*) into v_n from members
     where id = v_b and deleted_at is not null and line_user_id is null;
    v_out := v_out || E'\n' || '⑭ drop 已軟刪且讓出 line_user_id' || E'\t' ||
      case when v_n = 1 then '✅' else '🔴' end;

    select count(*) into v_n from member_merges where dropped_id = v_b;
    v_out := v_out || E'\n' || '⑮ 留下了合併紀錄' || E'\t' ||
      case when v_n = 1 then '✅' else '🔴 ' || v_n || ' 筆' end;

    ---- 🎯 正對照 ④：同一個人不能被併第二次 ---------------
    begin
      v_r := public.merge_members_tx(v_org, v_a, v_b, null, 'MERGE');
      v_txt := '🔴 竟然通過了';
    exception when others then
      v_txt := case when sqlerrm like 'drop_already_deleted%' then '✅ 擋住了'
                    else '🔴 ' || sqlerrm end;
    end;
    v_out := v_out || E'\n' || '⑯ 🎯 併過的帳號不能再併一次' || E'\t' || v_txt;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.mrg', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.mrg', true), E'\n')) as x
 where coalesce(x,'') <> '';
