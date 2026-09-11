# MIGI 資料庫現況快照

> **產生日期：2026-08-28**（前一版是 2026-08-14，已整份取代）
> **基準：`sql/applied/` 有 219 個 `.sql`**（＋ 2 個非 SQL 的 `.ts` / `.py`；
> 最後歸檔的是 `2026-09-11_包桌預約函式.sql`）
>
> 🔴 **這個數字在整份文件裡只出現這一次。** 2026-09-07 之前它同時
> 寫在檔頭與「怎麼知道它過期了」那一節，而**兩處漂開過三次**
> （136/150、158/185）—— 而第三次發生時，那一節裡就寫著
> 上一次漂移的檢討與修法「哪天把這一行改成引用檔頭」。
> **沒有人做那個修法，所以它又發生了一次。**
> 🎯 同一個數字寫兩個地方，就是同一族的病（`--gray-4` 一值兩用、
> `paid_count` 一名兩義）—— **判準是「這個值改了，哪些東西要跟著動」**。
>
> 🔴 **`pos_list_queues_tx` 2026-09-07 改簽名**（DROP ＋ 重建 ＋ 補 GRANT）：
> `(p_org, p_store, p_before timestamptz default null, p_limit int default 20)`
> · 進行中的房（waiting／matched／seated+開著）**永遠全給，不分頁**
>   —— 被截掉會出現「有一桌在等你結帳但它在第二頁」
> · 已收桌的才分頁，`p_limit` 夾在 1..100，依 `ended_at desc`
> · **時間窗口整個拿掉了**（先前是「只留今天」→「留 7 天」）——
>   配桌是延續的，前兩位可能是上一班找到的、靠下一班完成，
>   任何日／班的邊界都會把同一件事切成兩半
> ⚠ 前端只用 `p_limit`（成長式 20→40→60）；`p_before` 留給日後
>   migi-admin 的檔案庫（那一頁不輪詢，游標分頁才對）。**今天沒有呼叫點。**
>
> 🆕 **`session_players.final_score`**（2026-09-06 新增，integer nullable）
> ＝ 這一場的**桌上積分**，四家相加為 0。
> · `null` = 這桌不計積分（`stake_levels.is_hygiene`，純娛樂）或還沒資料
>   🔴 **null 不是 0** —— 0 是「打平」，塞給純娛樂的桌會變成
>     「純娛樂 · 第 1 名 · +1200」這種自相矛盾的畫面
> · ⚠ 與 `score_points` 不同：**那一欄裝的是段位分**（M4 正名 `rating_delta`）
> · 欄位名沿用 M4 設計稿（`game_players.final_score` 是**一將**的，
>   這裡是**一場**的 —— 同概念不同粒度，由表名區分）
> ✅ `get_my_games_tx` 已回傳它（玩家陣列 **13 個鍵**），
>   牌局詳情顯示成「積分 +120 ／ 段位分 +60」。
> ⏳ **勝率／最長連勝／單場最多積分／積分走勢還沒接** —— 那是聚合，
>   要另外算（`final_score > 0` 的比例、最長連續正值⋯）。
>
> 🔴 **`apply_session_rounds_tx` 的兩個語意 2026-09-06 都改了**：
> · `finish_rank` = **最後一將**的名次（不再是段位分加總的排名）
>   ⇒ 同分那條「由 `member_id` 字典序決定」的隱形規則整條消失
> · `score_points` = 每一將**實際變動**的加總（夾過降階保護之後）
>   ⇒ 卡在階級下限的人墊底時記 0 而不是 −20，
>     不會再出現「段位分 −10 但走勢圖 +30」那種同頁矛盾
> ⏳ M4 接上桌上分數後 `finish_rank` 改依桌上總分排、同分比座位
>
> ⏳ **2026-09-06 新增 `placeholder_ranks_tx`**：電子計分之前，
> `settle_session_tx` 收桌時給一份**隨機名次**並走真的
> `apply_session_rounds_tx`（段位分、定位賽、降階保護全部照真規則）。
> 🔴 **只在 `orgs.live_from` 還沒到時作用** —— 上線那天自動停止，
> 不需要有人記得移除。`anon` / `PUBLIC` 都收掉了，只有內部呼叫得動。
>
> 🎉 **2026-09-06：配桌整條路第一次從頭跑完** ——
> 湊滿 → 自動配桌 → 佔桌 → POS 收四份檯費（100/100/90/95 = 385，
> 等級折扣只折檯費那條規則同時被驗到）→ **開打 12:14 → 收桌 12:59**。
> ✅ `activate_session_tx` 與 `settle_session_tx` 也都走過真的資料了。
>
> 🔴 那一天在配桌線上一共修了 **11 個 bug，沒有一個會報錯**。
> 除了下面列的七個，還有：
> · `create_match_queue_tx` 對 `play_at` **完全沒有驗證**（可以開一個
>   開打時間在過去的房），且 `expires_at` 不看 `play_at`
> · 🔴 **冪等鍵撞到已作廢的場次** ⇒ 一個房只要被取消開桌一次，
>   就**永遠配不到新的桌**，而畫面上寫著「已成桌」
>   （`uq_sessions_idem` 是 UNIQUE，所以修法只能在產生鑰匙的地方）
> · 取消之後的房回到 `waiting` 而 `sweep_auto_seat_tx` **只掃 `matched`**
>   ⇒ 滿的房再也不會被配桌
> · 空桌回收用「桌建立 + 30 分」而不是「最晚開打 + 30 分」
>   ⇒ 一張 11:45 才配到、局是 11:30 的桌被佔到 12:20
>
> ✅ 同日新增：`match_queues.auto_seat`（自動配桌只做一次，取消後改手動）
> 與 **`pos_move_session_tx`（換桌）** —— 系統裡原本完全沒有換桌這個東西。
> `pos_list_queues_tx` 同日補回 `auto_seat`（**23 個鍵**），
> POS 才畫得出「這房要手動配桌」。
>
> ⚠ **兩支配桌 RPC 都不回 `table_label`**（`pos_seat_queue_tx` 回
> `ok / already / reason / session_id / members`，`_try_auto_seat_tx`
> 直接往上丟）—— 前端寫「已帶到 ${r.table_label}」會印出 `undefined`。
> `no_free_table` 那一條**有** `next_free_table` / `next_free_at`。
>
> ✅ **2026-09-06：自動配桌整條路第一次跑通**（`open_method='auto'` 在
> 這之前是 0 次）。四個測試帳號報名同一房 → `_finalize_queue_full_tx`
> → `sweep_auto_seat_tx` → A3 桌被佔住、`activated_at` null（預留中）。
> 🔴 同一次抓到**四個只有真的跑一次才會發現的 bug**，都已修：
> · `get_my_active_queue_tx` 沒有 `seated` ⇒ 成桌後會員 App 的房間消失
> · `pos_list_queues_tx` 的 seated 只活 10 分鐘 ⇒ 檯費沒收卡片就不見
> · 同一支不放行 `matched` ⇒ POS 的「已滿 · 沒有空桌」永遠不會顯示
> · 🔴 **`cleanup_empty_sessions_tx(30)` 會把配桌預留的桌清掉** ——
>   自動配桌是「湊滿就佔桌」（可能空等兩小時），而配桌佔的桌
>   在客人到店結帳前 `session_players` 永遠是 0
>   ⇒ **每一張自動配到的桌都必定在 30 分鐘後被作廢，一次都成功不了**。
>   實測 A3：00:25:37 建立 → 01:00:00 被排程作廢（沒有操作者）。
>   ✅ 改成保留到 `play_at + 寬限`，回傳多一個 `held_for_queue` 讓保護看得見。
> ⚠ 四個都**不會報錯**，只是東西不見或不出現。
>
> ✅ **第五個也修了**：桌被作廢時配桌房**不會被還原** ——
> 房永遠停在 `seated`、桌沒了，客人的配桌畫面無聲消失。
> 🎯 用**觸發器**（`trg_session_voided_release_queue`）不改函式，因為
> 桌會變 `voided` 有兩條路（店員按取消／排程回收），改函式會漏掉第三條。
> 兩種結局由「開打時間過了沒」決定：還沒到 → 房回 `waiting` ＋ 通知；
> 過了寬限 → `expired` ＋ 標離開（比照 `sweep_expired_queues_tx`）。
> ⚠ **寬限必須與 `cleanup_empty_sessions_tx` 一致（30 分）** ——
> 不一致會變成「排程收桌 → 觸發器放回 waiting → 又配一張桌 → 又被收」的無限循環。
> ⚠ 回 `waiting` 時**要延長 `expires_at`**，否則 `sweep_expired_queues_tx`
> （每 5 分鐘）下一輪就把它判流局，客人回到排隊三分鐘又被踢掉。
>
> ✅ **第六個（使用者發現）**：`_check_join_conflict` 只掃 `waiting`／`matched`
> ⇒ **成桌之後還能再開一桌**，而那支的規則本身寫著「同時只能參加一場」。
> ⚠ **不能只是把 `seated` 加進去** —— 它是終點狀態，打完收桌之後房仍然是
> `seated`，無條件擋會讓**打過一場的人從此永遠報不了名**。
> ✅ 綁「那張桌還開著」（`migi_seat_is_live()`），與另外兩支同一個界線。
> 📌 順帶補了原本漏掉的 `q.org_id = p_org_id` —— 舊版完全沒有比對 org。
>
> ✅ **第七個**：`get_my_active_queue_tx` 是 `order by joined_at desc`
> ⇒ 一個人在兩個房時**必定顯示後加入的那個**，也就是**沒有桌的那個**
> —— 客人已經被配到 A3 了，畫面卻寫「還差 2 位」。
> 改成「**活著的房優先**」（seated › matched › waiting）。
> 🎯 **修守衛不會修好已經產生的資料** —— 同一份還做了兩件一次性清理：
> 釋放孤兒房（觸發器只對今後的作廢生效）、清掉重複的房籍
> （`leave_reason='switched'`，CHECK 本來就允許的值）。
>
> 🎯 **「seated 且桌還開著」這個述詞現在出現在三支函式裡**，
> 只有 `_check_join_conflict` 改用了 `migi_seat_is_live()`；
> `get_my_active_queue_tx`（EXISTS 形）與 `pos_list_queues_tx`（已 join `ts`）
> 還是各寫一份 —— **下次動那兩支時一起換掉**。
> ⏳ `sql/pending/` 有 **1 份，而且刻意跑不動**：
> `2026-09-05_測試世界與正式世界分開.sql`（第 ⓪ 段要求「至少一間正式門市」，
> 今天 7 間全是 `is_test` ⇒ 上線當天標好真門市之後才跑）
>
> ✅ **2026-09-05：測試01～04 拿到合成的 `line_user_id`**（`TEST-01`…`TEST-04`）
> ＋ 可用密碼登入的 auth user ⇒ **不需要 LINE 帳號也能測多人社交**。
> 🎯 那不是 JWT 旁路（硬規則 5.7）—— 它們走的是跟真客人**完全一樣**的
> `app_metadata.line_user_id → migi_jwt_line_id() → current_member_id()`，
> 產品碼零改動，認證由 Supabase Auth 的密碼負責。
> 📄 怎麼登入：`docs/09-環境流程/用測試帳號登入會員App.md`
>
> 📌 **2026-09-05 歸檔的兩份（待辦 14）只改函式內容、不動結構** ——
> 實測 `函式 169 · 資料表 46 · 檢視表 22 · RLS policy 29` 與上一版**完全相同**，
> 所以本檔其餘內容不受影響（硬規則 1.6 的重跑匯出這次沒有東西會變）。
> 🔴 **但那 21 支會員 RPC 現在是「相容模式」，洞是開著的**：
> `p_member_id := coalesce(current_member_id(), p_member_id)`
> ⇒ 有 session 的走 JWT，沒有的仍然採信前端送的 id。
> 待辦 14 的收尾就是把那個 `coalesce` 拿掉，而那要等
> **每一條進入 App 的路都被實測過拿得到 session**（上次就是沒驗這一步才炸的）。
>
> 🔴 **2026-09-03 更正一個會讓人誤判的寫法**：上一版寫「148 個檔案」而且
> 說「依檔名排序最後一個是 `門市真實資料.sql`」，**兩個都會誤導**：
> · 148 是**全部檔案**（含 `M1_儲值EdgeFunction.ts` / `M1_計費邏輯測試.py`），
>   而人比對時多半只會數 `*.sql` —— 兩邊差 2，看起來像過期但其實沒有
> · 「依檔名排序最後一個」**取決於排序規則**（PowerShell 的中文排序與
>   git／VS Code 不同），同一個資料夾會得到不同答案
> → 從現在起記 **`.sql` 的數量**，並直接寫**最後歸檔的檔名**（那個沒有歧義）。
>

> ✅ **2026-09-01：`players` 一個 key 兩種形狀已全部收完**（待辦 35）。
> `list_tables_tx` 與 `list_match_queues_tx` 只回 **`player_count`**（數字）；
> `get_my_games_tx` 與 `get_my_active_queue_tx` 的 `players` 是**陣列**，不變。
> ⚠ `pos_add_queue_member_tx` 的 `players` 仍在（一次性操作結果，刻意不動）。
> 🎯 **要回「有哪些人」請叫 `player_names`，不要再用 `players`。**
> ### 🔴 2026-09-09：消費明細拆成會員與店員兩支（待辦 14 的 ①②③a）
> ```
> _member_orders_core(member, limit, before)   ← 查詢本體「搬」過去，不是抄
>   ├─ get_my_orders_tx      會員：coalesce(current_member_id(), p_member_id)
>   └─ pos_member_orders_tx  店員：can('member.lookup') ＋ 同 org
> ```
> 🔴 **為什麼非拆不可**：POS 是「**店員查客人**」，而店員本人也是會員
> ⇒ 若走同一支，`current_member_id()` 會回**他自己**，
> **店員查客人時看到自己的帳，而且不會報錯**。
> ⚠ 也**不可以讓 POS 那支去呼叫 `get_my_orders_tx`** —— 同一個理由。
>
> 🎯 驗證用**筆數**而不是函式自己回報的字串（否則一支「永遠回 jwt 但沒覆寫」
> 的實作也會全綠）：同一組身分、兩支函式、**兩個相反的正確答案**
> ```
> get_my_orders_tx(測試01)      以咖勁凱的 JWT → 回 3 筆（咖勁凱）✅ 覆寫生效
> pos_member_orders_tx(測試01)  同一個身分     → 回 8 筆（測試01）✅ 沒被蓋掉
> ```
>
> **`can()` 同批長出第一個權限碼分岔** —— 在此之前它是一行
> `role in ('hq','owner')`，註解寫著「等真的出現『店長可以但店員不行』的碼再分岔」。
> 🎯 那一刻來了，**只是方向相反**：`member.read` 那一族是總部限定（報表、匯出），
> 而**查客人的餘額與最近消費是前場每天在做的事** ⇒ 新增 **`member.lookup`**
> （任何有 staff 列的人），**不放寬任何既有的碼**。
> ⚠ `can()` 被 **20 條 policy** 呼叫，所以驗證段用負對照盯著既有碼沒被改壞。
>
> **`get_my_orders_tx` 回傳多一個 `id_src`**（`jwt` / `param` / `jwt_override`）——
> 🎯 **那是待辦 14 收尾條件的量測端**：收掉 `anon` 之前要等 `param` 歸零，
> 而在此之前那個數字完全不存在。
> ⚠ 為什麼是回傳一個鍵而不是函式自己埋：它是 **STABLE** ⇒ **函式體裡不能 INSERT**。
> 🔴 `jwt_override` 是順帶換到的：它同時抓得到 **bug**（前端送錯 id）與**攻擊**
> （拿別人的 uuid 來查），而**在此之前那件事完全沒有痕跡**。
> ⏳ **`anon` 還在，收它是第 ③c 步。**
>
> **當下規模（2026-09-09 實測）：函式 183 · anon 明確 108 · PUBLIC 106**
>
> **（以下為 2026-09-08 的數字）當下規模：函式 181 · 資料表 46 · 檢視表 22 · RLS policy 29**
> （帶 `can()` 的 policy 20 · 明確授權 anon 的函式 **108** · **只靠 PUBLIC 的 0**）
>
> 📌 上一版（2026-09-05）是 函式 169 · anon 129 · PUBLIC 124。
>   函式 +12 是後台那三頁（商品 RPC 化 4 支、場次查詢 1 支、會員等級 2 支、
>   升等進度 1 支…）；**anon 129 → 108 是 2026-09-08 四份收斂的結果**，
>   不是漂移（見下面「2026-09-08 的授權收斂」）。
>
> ⚠ **「只靠 PUBLIC 0」不等於「PUBLIC 都收乾淨了」** —— 實際上
> **106 支函式 PUBLIC 仍然有 EXECUTE**，只是它們同時也明確授權給 anon。
> 🔴 所以要真的關掉一支給前端的函式，**兩行都要寫**（硬規則 2.6／2.6b）：
> ```sql
> revoke execute on function f(...) from public;   -- 舊的走這條
> revoke execute on function f(...) from anon;     -- 新建的走這條
> ```
> 只收一邊**不會報錯，也不會有效果** —— 兩個方向我在 2026-08-29 各踩過一次。
>
> 📌 **會員合併（`member_merges` ＋ `merge_members_tx`）當天建了又移除了。**
> 🔴 它一度處在**最糟的狀態**：第一次跑時驗證段炸在第 ③ 格，
> 而 **DO 區塊的 exception handler 把錯誤接住了沒往上拋 ⇒ DDL 照樣提交**
> —— 函式在線上、看起來正常、只驗到第 ② 格（硬規則 7 那個形狀）。
> ⚠ **這個機制值得記住**：`DO $$ ... exception when others ... $$` 裡的
> 驗證段失敗，**不會回滾同一份 SQL 前面的 DDL**。
> ✅ 實作退回 `sql/_設計稿未落地/2026-09-04_會員合併.sql`（要用直接跑）。
> （`public` 沒有任何擴充套件 —— 都在 `extensions`，見下面 btree_gist 那一段）
> ⚠ 這四個數字是**給下一個人比對用的** —— 對不上就是這份文件過期了，
>   而那個檢查**只要一句 SQL，不需要讀完整份文件**。
>
> 🔴 **2026-09-01 踩到一次，記在這裡因為它會再發生**：
> 依這條規則重跑之後，`public` 的函式數從 **157 變成 347**。
> 原因是賽季那份寫了 `create extension if not exists btree_gist;`
> **沒指定 schema** → 進了 `public` → **帶 188 支函式進來**，
> 而且依硬規則 2.6b 的 default privileges，那 188 支**全部明確授權給 anon**。
> ✅ **已搬到 `extensions` 並實測 7/7 通過**（`2026-09-01_btree_gist搬去extensions.sql`），
> 這個專案其他可搬的擴充（pgcrypto／uuid-ossp／pg_stat_statements）本來就在那裡。
> ⚠ **只搬 schema，沒有收那 188 個 anon 授權** —— 它們是 GiST 的型別支援函式，
>   索引掃描時由索引機制自己呼叫，收掉可能讓寫入 `rank_seasons` 失敗
>   **而症狀出現在完全無關的地方**。收益不成比例。
> 📌 **日後 `create extension` 一律寫 `with schema extensions`。**
> 🎯 **這是硬規則 1.6 第一次真的抓到東西** ——
>   而它抓到的不是「文件過期」，是**一個沒有人會發現的授權變動**。
>
> 🔴 **2026-08-30 補記一次漂移**：本文件在此之前**完全沒有 `phone_otps`、
> `members.phone_verified_at`、`otp_*` 那一整批** —— 也就是 08-30 上午的
> 簡訊驗證地基歸檔時**沒有依硬規則 1.6 同步更新**。
> ⚠ 這是這條規則第二次被跳過。**規則本身沒有錯，是執行時沒做。**
>
> 📌 依硬規則 1.6，歷次歸檔已同步更新本文件：
> `p_rounds` 與 `rounds` 欄位預設值、`topup_void_tx` 的 anon 授權、
> `orgs.live_from` 新欄位、`v_real_*` 從 5 個變 12 個、
> `set_my_profile_basics_tx` 與 `migi_norm_phone` 兩支新函式、`members_phone_chk`、
> `register_member_tx` 的暱稱正規化與 `display_name_reserved`、
> **簡訊驗證整批（`phone_otps` ＋ 8 支函式 ＋ `phone_verified_at`）**、
> **段位整批（`rank_tiers` / `rank_points` / `season_champions` ＋ `members.rank` 可為 null
> ＋ `get_my_games_tx` 補 `my_rating_after` / `settled_at`）**、
> **成績整批（`get_my_stats_tx` / `season_standings` / `season_rank_rows_tx`）**、
> **`migi_jwt_uuid` ＋ `can` 兩支新函式 ＋ 三條寫入 policy 收緊（見下面「身分與權限」）**、
> **2026-09-08 後台三頁整批**（商品改走 RPC 的 4 支 `admin_*_product_tx`、
> 場次查詢 `admin_search_sessions_tx`、會員等級 `admin_list_member_tiers_tx` ＋
> `admin_update_member_tier_tx` ＋ `member_tiers` 加 `updated_at` / `updated_by`、
> 升等進度 `member_tier_progress_tx`）、
> **2026-09-08 兩份授權收斂（anon 129 → 114，見「授權地雷」那一節）**。
> 來源：`sql/checks/2026-08-28_現況全匯出.sql`（pg_proc / pg_class / pg_constraint / pg_index / information_schema）

## 怎麼用這份

**它是背景事實的鏡像**：這張表有哪些欄位、這個約束在管什麼、這支函式有沒有授權給 anon。
這類問題直接查這裡，不用再跑一次查詢。

🔴 **但它不取代逐次查證。** 硬規則 3 永遠成立：
**改既有函式一律先 `pg_get_functiondef` 撈線上版**，這份只當背景參考。

## 怎麼知道它過期了（硬規則 1.7）

比對現在 `sql/applied/` 的 `.sql` 數與**檔頭的基準** —— **不同就是過期**。
這個檢查不需要資料庫。

```powershell
(Get-ChildItem "sql\applied" -Filter *.sql).Count
```

✅ **2026-09-07：這裡不再複寫那個數字了。**
🔴 它原本寫在這一行與檔頭**兩個地方**，而兩處漂開過**三次**
（136/150 → 2026-09-04 修 → 158/185 → 2026-09-07 又抓到）。
而第三次被抓到時，**這一段裡就寫著上一次的檢討**，還有修法
「或者哪天把這一行改成引用檔頭」—— 沒有人做，所以它又發生了。
🎯 **教訓不是「要記得同步」**（那已經失敗三次），
是**把重複的那一份刪掉**。同硬規則 1.6／1.7 的形狀：
靠記性的機制會壞，靠結構的不會。

⚠ **但它只能證明「確定過期」，不能證明「還是新的」。**
直接在 Dashboard 手改、沒留檔案的東西抓不到 ——
而那不是假設：`uq_members_line_user` 就是這樣來的（承重牆，`sql/` 裡完全找不到）。

📌 硬規則 1.6：**歸檔 `pending/` → `applied/` 時一併重跑匯出**。
上一版就是因為靠「記得更新」而在兩週內爛掉 —— 它連 `products` 這張表都沒有。

---

## 🔴 授權地雷（2026-08-28 新發現）

硬規則 2.5：**「函式在包裝裡跑得動」不代表「前端叫得動」** ——
權限是在**呼叫點**檢查的，而在 DEFINER 裡呼叫端的權限根本不會被檢查。

| 函式 | 狀況（2026-09-08 重新查證） | 後果 |
|---|---|---|
| `topup_void_tx` | DEFINER、**anon=🔴 仍在**、**三端 0 個呼叫點** | 2026-08-28 為了「日後做作廢儲值」補的授權，而那個功能到今天還沒做 ⇒ **一支沒人叫卻對外開著的作廢函式**。⏳ 待收 |
| `reverse_txn_tx` | INVOKER、**anon ＋ PUBLIC 都在**、**0 個呼叫點** | 🔴 **沖銷錢包交易**（`p_original_txn_id`）。⏳ 待收 |
| ~~`charge_matched_tx`~~ | ✅ anon=無 PUBLIC=無 | 本來就沒授權給任何人。舊世代收費函式，**死碼候選**（待辦 28） |
| ~~`charge_private_tx`~~ | ✅ 同上 | 同上 |
| ~~`checkout_tx`~~ | ✅ **2026-09-08 收乾淨**（anon／PUBLIC／authenticated 全收，只留 service_role） | 收之前是「有授權但不該被直接呼叫」；實測三端 0 個呼叫點，只被三支 DEFINER 包裝內部叫 |
| ~~`_charge_core`／`charge_fnb_tx`~~ | ✅ **2026-09-08 收乾淨** | 兩支一起收 —— 都是 INVOKER 且外層叫內層，只收一層會變成「外層叫得動、內層失敗」 |

### 🔴 2026-09-08 的授權收斂（anon 129 → 114）

兩份 SQL，起點都是「**這支到底有沒有人在叫**」而不是「它看起來危不危險」。

**① `2026-09-08_收掉三支沒人叫的會員函式.sql`**
`clear_avatar_photo_tx`（刪頭像照片，前端走 Edge Function）／
`set_invoice_pref_tx`（改發票載具統編，**三端都沒有人叫**）／
`member_rank_tx`（只被 3 支 DEFINER 內部呼叫）。三支全收，只留 `service_role`。
🔴 前兩支是真的洞：**知道一個 member uuid 就能刪別人的照片、改別人的發票設定**。
⚠ `social.js:516` 的註解本來就寫著「任何人可以刪掉任何會員的照片」——
  那個洞當時搬去 Edge Function 解決了，**但 RPC 的 anon 授權沒有跟著收**。

**② `2026-09-08_營運函式收掉anon.sql`**
POS 專用的 11 支收 `public` ＋ `anon`，**保留 `authenticated`**。
🎯 **能做的原因是一個過期的理由**：CLAUDE.md 待辦 20 把它們歸類為
「現況的必然 —— POS 用 anon key，收了會當場打壞收銀機」，
而**店員登入 2026-09-04 就做完了** ⇒ 每一支 POS 的 RPC 現在都帶店員 JWT。
✅ 實機端到端驗過（本機 POS ＋ 真實店員 session）：
```
店員 JWT  pos_member_detail_tx 200 ✅   has_daypass_tx 200 ✅
anon      兩支都是 401 · code=42501 permission denied
負對照    list_tables_tx 200 ✅   get_wallet_tx 200 ✅   ← 沒有誤傷
```

### ⚠ 刻意留著 anon 的兩支（不是漏掉）
· **`log_app_event_tx`** —— 三端埋點入口，而 migi-web **在還沒登入時就要發事件**
  （`member_session` 探針**就是在 `no_login` ＝ 沒有 session ＝ anon 那一刻發的**）。
  🔴 收了會讓那些列消失 ⇒ **探針看起來全綠，而那是假的**。一個會說謊的儀器比沒有更糟。
· **`get_my_orders_tx`** —— web（會員看自己）與 POS（店員查客人）都在叫，
  要先解「店員視角 vs 會員視角」才動得了。

### 🔴 掃描條件本身的盲點（2026-09-08 發現）—— 而換了判準之後又多找出 6 支
前兩份用的判準是「**簽名含 `p_member_id` 且 anon 叫得動且沒查 `current_member_id()`**」，
而 **`reverse_txn_tx`（`p_original_txn_id`）與 `topup_void_tx`（`p_topup_id`）
用的不是 member id，所以整批掃描都看不到它們**。
🎯 **金流函式不一定用會員當鍵** —— 沖銷用交易 id、作廢用單號。

✅ **判準換成「函式名裡有沒有動錢／動身分的動詞」**：
```
topup|checkout|charge|refund|reverse|void|grant|revoke|
rebind|merge|claim|settle|adjust|fix_wallet|reconcile
```
⇒ **當場又多找出 4 支**（第四批）：
| 函式 | 前端 | 怎麼收 |
|---|---|---|
| `settle_session_tx` 收桌 | POS ×1 | `public`＋`anon`，留 `authenticated` |
| `void_session_tx` 取消開桌 | POS ×1 | 同上 |
| `void_invoice_tx` 作廢發票 | **0**（發票整條未接、`invoices` 0 筆） | 全收 |
| `calc_topup_bonus_tx` 贈點試算 | **0**（只被 `topup_tx` 等兩支 DEFINER 內部叫） | 全收 |

🔴 前兩支的嚴重程度容易被低估：它們不動錢，但**知道一個 session id
  就能讓店裡正在打的一桌消失**，而店員看到的症狀是「系統自己把桌收了」，
  且查不到是誰（`p_staff_id` 從 `current_staff()` 覆寫，anon 呼叫時是 null）。

📌 **`settle_session_tx` 對找不到的場次是回 `{ok:false, reason:'session_not_found'}`
  不是拋例外** —— 所以驗證段那格印「假 session 居然沒報錯」是設計行為，
  不是異常（同硬規則 4 那一族：業務錯誤回值不 raise）。

### ⚠ 第四批也刻意不動兩類
· **`list_topup_plans_tx`** —— 儲值方案主檔，**會員 App 與 POS 都在讀**，
  而未登入的會員 App 是 anon。收了錢包頁的儲值方案會空掉。
· **`trg_session_voided_release_queue` / `trg_topup_set_no`** ——
  被上面那個正則**誤抓**的觸發器函式（名字裡有 `void` / `topup`）。
  🎯 `returns trigger` 的函式直接呼叫會被 Postgres 自己擋下
    （`trigger functions can only be called as triggers`），**沒有攻擊面**。
  ⚠ 寫在這裡是為了讓下一個人看到清單時不會又去「修」它們。

→ 四批之後 `anon` 明確授權 **129 → 108**，PUBLIC **124 → 106**。

---

## 🔴 身分與權限：`sub` 被當成兩種東西（2026-09-04）

### 地雷本身

`auth.uid()` 的定義是把 JWT 的 `sub` **cast 成 uuid**：
```sql
(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid
```
而系統裡 `sub` **有兩種來源**：

| 路徑 | `sub` 是什麼 |
|---|---|
| 總部（Supabase Auth Email，`admin@migi.tw`） | **uuid** → 比對 `staff.auth_uid` |
| 會員／店員（LINE） | **`U4af49806…`** → 比對 `members.line_user_id` |

🔴 而 `current_org_id()` 的 `coalesce` **第一行就叫 `auth.uid()`**
⇒ `sub` 是 LINE id 時它**不是回 null，是拋錯**：
```
invalid input syntax for type uuid: "U4af4980629abc..."
```
28 條 RLS policy 全部依賴這支函式 ⇒ **發出第一張會員／店員 JWT 的那一刻，
每一次查詢都會炸。**

⚠ **今天不是活著的 bug**：Edge Function `line-login` **沒有發任何 Supabase JWT**
（它在伺服器端驗完 LINE 的 id_token 後直接呼叫 `register_member_tx`）。
→ 這是**地雷不是火災**，它會在待辦 14／20 上線的那一刻引爆。

✅ **2026-09-04 已修**：新增 `migi_jwt_uuid()`（像 uuid 才轉，不像回 null），
`current_org_id()` 與 `current_staff()` 改用它。**語意完全不變，兩條路都在。**
⚠ 用 `CASE` 不是 `AND` —— **Postgres 不保證 `AND` 的求值順序**，
  寫成 `where sub ~ '…' and auth_uid = sub::uuid` 仍然可能先做 cast。
📌 只有那兩支函式用到 `auth.uid()`，**沒有任何 RLS policy 直接用**。

### 29 條 policy 的分布（2026-09-04 全部看過了）

| | 條數 | |
|---|---|---|
| 公開主檔（`using true`） | 4 | `member_tiers`／`product_taxonomy`／`queue_tags`／`topup_plans` —— 本來就該全 org 可讀 |
| **`ALL`（含寫入）→ 總部** | **3** | `products`／`order_items`／`order_payments` |
| **`SELECT` → 總部** | **17** | 個資 5 ＋ 錢 6 ＋ 營運 6（見下表） |
| `SELECT` ＋ org（維持） | 5 | `products`／`stores`／`tables`／`stake_levels`／`orgs` |

⇒ **帶 `can()` 的共 20 條**。錯誤儀表第 ⑥ 段會盯這個數字 ——
🔴 **policy 的「條數」抓不到「條件被改鬆了」**（收緊那 20 條時，
表／函式／索引／policy 四個數字**一個都沒動**）。

### 🔒 46 張表全部開了 RLS，其中 20 張是 **0 policy**

```
app_events        app_notifications  buddy_invites     doc_counters
invoices          legal_entities     match_queue_players  match_queues
member_app_state  member_blocks      member_likes      phone_otps
rank_points       rank_seasons       rank_sub_levels   rank_tiers
recurring_tables  season_champions   season_standings  wallet_balance_audit
```
🎯 **0 policy 是這個系統裡最安全的狀態**（只有 DEFINER 進得去），
不是「漏掉沒設」的意思。

🔴 **這推翻了 CLAUDE.md 待辦 23.5 的一句話**，它寫：
> 「`app_events` 的 RLS 是 `org_id = current_org_id()`；POS 用 anon 讀不到。
>   ⚠ 待辦 14／20 上線那天這個保護就破。」

**後半段是錯的** —— `app_events` 根本沒有 policy，**開 JWT 之後照樣讀不到**。
📌 也就是「只有總部分析數據的人看得到」這個承諾，
今天是靠**鎖死**達成的，不是靠「沒人有 session」。

### 17 條收緊的讀取，三個權限碼

| 碼 | 表 |
|---|---|
| `member.read` | `members`／`member_availability`／`member_interactions`（**店員備註**）／`mahjong_buddies`／`member_coupons` |
| `finance.read` | `wallets`／`wallet_txns`／`orders`／`order_items`／`order_payments`／`topup_orders` |
| `ops.read` | `table_sessions`／`session_players`／`staff`／`coupons`（**券的定義**）／`pricing_tiers`／`bonus_rules` |

⚠ **今天這三個碼的答案完全一樣**（`can()` 一律看 hq/owner）——
分成三個是因為「店長能看自己店的訂單，但不能看全部會員的手機」
是必然會出現的區分，而到那天**只要改 `can()` 一支**（待辦 29 ①）。

### 維持 org 級的 5 條是決定，不是漏掉

`products` 🔴 **承重**（migi-admin 5 處直接查）；
`stores`／`tables`／`stake_levels` 是店家公開資訊；
`orgs` 的條件是 `id = current_org_id()`，已經是最緊的形狀。

🎯 **收緊幾乎沒有風險，因為 2026-09-04 掃過三個 repo 的 `.from(`：
整個系統只有 `migi-admin/src/lib/products.js` 直接查表**（`products` ×5），
其餘全是 `Array.from` 或 `supabase.storage.from`（Storage 的 policy 在
`storage` schema，與這 29 條無關）。
📌 順帶挖到兩處註解，是硬規則 4 留下的疤：
`migi-web/src/lib/avatar.js:187`「以前是 `supabase.from('members')`，
**而它從來沒有運作過**」、`social.js:375`「兩份都是死的」。

### ⚠ 已知代價（沒有症狀）

收緊之後，新加的直接查表程式碼會**回空陣列而且不報錯**。
而在此之前，**開了 JWT 的會員反而會讓那種寫法「看起來會動」**（因為他有 org）
—— 那更糟：**一個只在某些身分下才會動的查詢。**
→ 通則不變：**三端一律走 DEFINER RPC**（硬規則 4）。

### 三條寫入 policy（2026-09-04 收緊）

```sql
for all to authenticated
using (org_id = current_org_id() and can('product.write'))   -- products
using (org_id = current_org_id() and can('order.write'))     -- order_items / order_payments
```
🔴 **不能直接刪** —— `migi-admin/src/lib/products.js` 有 5 處直接
`.from('products')` 寫入，而 migi-admin 用的是真的 Supabase Auth。
**那條 policy 是承重的**，所以是**限縮角色**不是移除。

⚠ `order_payments` **原本只有那一條 policy**，所以同批**先補了
`order_payments_read_org`（SELECT）** 才收緊寫入 ——
不然會連讀取一起關掉（過度阻擋跟沒擋一樣糟）。
`products`（`products_org`）與 `order_items`（`oi_org`）各自另有 SELECT policy。

### `can()` 為什麼不是 `is_hq()`

待辦 29 ①：**判斷點一律呼叫 `can('動詞.名詞')`，不要比對 role 字串** ——
即使今天的實作就是一行 `role in ('hq','owner')`。
重點是**「權限怎麼決定」與「誰有權限」從第一天就分家**：
日後換成查 `role_permissions` 表時，**所有呼叫點一行都不用改**。
⚠ `authenticated` 的 EXECUTE **必須留著** —— policy 運算式是用**查詢者的身分**
執行的，收掉會讓那三條 policy 拋 permission denied（**不是擋住，是壞掉**）。

---

## 🎯 三個待辦其實已經做完了（文件漂移，2026-08-28 發現）

| 待辦 | CLAUDE.md 寫的 | 實際 |
|---|---|---|
| **5**（配桌） | 「⚠ 現在不要先建 `auto_assign` 欄位」 | 🎯 **`tables.auto_assign` 已存在**（NOT NULL default true），還有 `set_table_auto_assign_tx` |
| **5**（收桌保留給現場） | 「收桌彈窗加一個勾選」 | 🎯 **`settle_session_tx` 已有 `p_keep_for_walkin`** —— 後端做好了，只差前端 |
| **17**（贈點級距主檔） | 「建 `topup_plans` 主檔」 | 🎯 **`topup_plans` 表 ＋ `calc_topup_bonus_tx` ＋ `list_topup_plans_tx` 全都在** —— 只差 `topup_tx` 拿它驗證、POS 前端讀它 |

📌 固定牌局的後端也整套都在：`recurring_tables` 表、`pos_create_recurring_tx`、
`generate_recurring_instances_tx`、`pos_set_recurring_enabled_tx`。

---

## 🔴 `rounds` 的值決定帶不帶得了桌

`pos_seat_queue_tx` 解析 `rounds` 時**只吃「三/3」或「二/2」**，其餘一律回
`rounds_not_supported` —— 而且**只是不帶桌，不報錯**。

後果：房間湊滿 → `status='matched'` → 排程每 5 分鐘試一次 → 每次都失敗 →
**客人以為成桌了，桌永遠不會出現，沒有任何人知道。**

✅ **2026-08-28 已把五個地方的預設值從 `'一將'` 改成 `'2 將'`**
（三支建房函式的 `p_rounds` ＋ 兩張表的欄位預設）。
⚠ **既有的 33 個「一將」房沒有被動到**（全部已 expired/cancelled，不是活的問題）。
⚠ 但值本身**沒有 CHECK 約束** —— 明確傳一個不支援的值仍然存得進去。
  真要根治是讓約束與 `pos_seat_queue_tx` 的判準同源，那是另一個決定。

---

## ⚠️ 最容易踩的坑：`void` 還是 `voided`？

**不同表用不同值，沒有統一。**（`dev_reset_test_data_tx` 曾因此寫錯）

| 表 | 作廢值 | 完整允許值 |
|---|---|---|
| `table_sessions.status` | **`voided`** | open / completed / voided |
| `orders.status` | `void` | open / preparing / **served** / paid / void |
| `topup_orders.status` | `void` | pending / paid / void / refunded |
| `invoices.status` | `void` | pending / issued / void / failed |

**只有 `table_sessions` 用 `voided`，其餘一律 `void`。**

📌 `orders.status` 的 `preparing` / `served` **從來沒被用過**（`checkout_tx` 一律寫 `paid`）——
出餐佇列的狀態機地基已經在了，見 `docs/07-營運商業/首店餐飲籌備.md` 12-9。

---

## 一、欄位

> 讀法：`!` = NOT NULL，`=xxx` = 預設值。

| 表 | 欄位 |
|---|---|
| `app_events` | id! │ org_id! │ member_id │ event! │ props jsonb!={} │ client_ts │ created_at! │ **is_test!=false** │ store_id |
| `app_notifications` | id! │ org_id! │ member_id! │ type! │ payload jsonb!={} │ ref_id │ read_at │ created_at! |
| `bonus_rules` | id! │ org_id! │ store_id │ rule_key! │ amount! │ min_spend │ is_active!=true │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by |
| `buddy_invites` | id! │ org_id! │ inviter_id! │ invitee_id! │ status!=pending │ responded_at │ created_at! |
| `coupons` | id! │ org_id! │ name! │ kind! │ discount_type! │ discount_value │ applies_to │ valid_days │ valid_until │ is_active!=true │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by │ min_spend │ max_discount │ **free_product_id** │ cost_bearer!=store |
| `doc_counters` | org_id! │ store_id! │ doc_type! │ doc_date! │ last_no!=0 |
| `invoices` | id! │ org_id! │ entity_id │ store_id │ ref_table! │ ref_id! │ kind!=invoice │ parent_invoice_id │ status!=pending │ invoice_no │ invoice_at │ random_code │ period │ tax_type!='1' │ tax_rate!=0.05 │ sales_amount! │ tax_amount! │ total_amount! │ buyer_type!=B2C │ buyer_tax_id │ buyer_title │ carrier_type │ carrier_no │ donate_code │ donate_org_name │ print_mark!=false │ items jsonb!=[] │ void_at │ void_reason │ provider │ provider_ref │ raw │ idempotency_key │ created_at! │ created_by |
| `legal_entities` | id! │ org_id! │ name! │ tax_id │ kind! │ bank_account jsonb │ is_active!=true │ created_at! │ updated_at! |
| `mahjong_buddies` | id! │ org_id! │ member_id! │ buddy_id! │ **origin!** │ co_play_count!=1 │ **compat_score** │ linked_at! │ deleted_at │ created_at! |
| `match_queue_players` | id! │ org_id! │ queue_id! │ member_id! │ join_source │ joined_at! │ left_at │ leave_reason │ no_show!=false │ leave_detail │ **left_by_staff_id → staff**（2026-09-10：是誰讓他離開的，自己退房是 null）|
| `match_queues` | id! │ org_id! │ store_id! │ stake_level_id! │ game_type!='16張' │ **rounds!='2 將'**（2026-08-28 由 `'一將'` 改，見下）│ seats!=4 │ prefs jsonb!={} │ status!=waiting │ opened_by │ **play_at!** │ **matched_at** │ matched_session_id │ expires_at!=now()+2h │ created_at! │ updated_at! │ source!=member │ tags jsonb!=[] │ recurring_id │ recurring_freq │ flower │ **open_at** |
| `member_app_state` | member_id! │ org_id! │ bear jsonb!={} │ titles jsonb!=[] │ updated_at! |
| `member_availability` | id! │ org_id! │ member_id! │ weekday! │ slot! │ preference!=often │ **source!=stated** │ created_at! │ updated_at! |
| `member_blocks` | id! │ org_id! │ blocker_id! │ blocked_id! │ reason │ created_at! |
| `member_coupons` | id! │ org_id! │ member_id! │ coupon_id! │ status!=active │ granted_at! │ used_at │ used_txn_id │ **expires_at** │ created_at! │ code │ used_order │ discounted_amount │ cost_bearer |
| `member_interactions` | id! │ org_id! │ member_id! │ **staff_id** │ channel!=system │ kind! │ note │ created_at! │ created_by |
| `member_likes` | id! │ org_id! │ liker_id! │ target_id! │ session_id │ created_at! |
| `member_tiers` | **code!**（PK）│ label! │ discount_pct!=0 │ threshold_amount │ sort!=0 │ is_active!=true │ note │ created_at! │ **updated_at** │ **updated_by**<br>⚠ 後兩欄 2026-09-08 新增（後台編輯頁）。在此之前**改折扣完全沒有紀錄**，<br>而那是**不可回溯**的（硬規則 5.6）。<br>🔴 `threshold_amount` 為 **null ＝ 邀請制**（`chef_special`），不是「門檻是 0」。<br>📌 實際值 **0 / 6,000 / 20,000 / null** —— CLAUDE.md 一度記成「暫定 0 / 10,000 / 50,000」，<br>而那個錯的數字被《首店周邊商品規劃》拿去算杯子回本。**「暫定」兩個字讓沒有人回來對過。** |
| `members` | id! │ org_id! │ **line_user_id** │ display_name! │ phone │ home_store_id │ **tier!=bubble_tea** │ gender │ **birthday** │ occupation │ district │ acquisition_source │ avatar_url │ **last_visit_at** │ **visit_count!=0** │ lifecycle!=new │ **primary_staff_id** │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by │ **tier_override** │ last_app_active_at │ rank!='銅牌熊 I' │ title!='新手上路' │ likes_count!=0 │ **is_test!=false** │ about │ sched │ style jsonb │ see_score!='牌咖' │ baby_tile jsonb │ avatar_source!=bear │ avatar_photo_path │ avatar_photo_at │ avatar_blocked!=false │ avatar_removed_count!=0 │ inv_type!=member │ inv_carrier │ inv_donate_code │ inv_tax_id │ inv_title │ **phone_verified_at** |
| `order_items` | id! │ order_id! │ **product_id!** │ qty!=1 │ created_at! │ org_id! │ name │ unit_price! │ line_total │ **revenue_type!** │ **spec**（2026-09-10）<br>🆕 **`spec`** ＝ 結帳當下的規格快照，跟 `name` / `unit_price` 同一個道理。<br>🔴 **沒有它的話，商品改過份量之後「那一筆賣了幾顆」永遠算不回來** ——<br>而那正是進銷存第一個要問的數字（每項每日份數 × 進貨週期 = 冷凍櫃容量）。<br>⚠ 由 `checkout_tx` **回查主檔蓋章，不採信前端**（同 `unit_price`）。<br>📌 既有的 224 筆全是 null，那是對的：它們成立時這個欄位還不存在。<br><br>🔴 **所以收據上會有兩種列，而那不是 bug**（2026-09-11 量到）：<br>`89 筆`舊快照的 **`name` 裡還帶著「（10 顆／份）」**，而 `spec` 是 null。<br>```<br>舊　水餃（10 顆／份）　×1<br>新　水餃　10 顆／份　×1<br>```<br>⚠ **不可以回填** —— 快照存的是「當時的品名」，改了就是偽造歷史。<br>2026-09-11 那份 SQL 的第 ⑤ 格就是在盯「有沒有人去回填」。<br>📌 兩種列會並存到那 89 筆滾出查詢範圍為止，這是快照的本質不是缺陷。 |
| `order_payments` | id! │ org_id! │ store_id! │ order_id! │ method! │ amount! │ cash_received │ change_given │ ref_no │ staff_id │ created_at! |
| `orders` | id! │ org_id! │ store_id! │ member_id │ table_id │ **session_id** │ status!=open │ **channel!=counter** │ total_points!=0 │ deleted_at │ created_at! │ updated_at! │ **created_by** │ **updated_by** │ order_no │ subtotal!=0 │ coupon_discount!=0 │ tier_discount!=0 │ payable!=0 │ points_used!=0 │ cash_due!=0 │ tier_at_order │ **idempotency_key** │ wallet_txn_id │ paid_at │ entity_id │ is_test!=false │ tier_discount_pct │ txn_no |
| `orgs` | id! │ name! │ plan!=self │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by │ 🎯 **live_from**（2026-08-28 新增） |
| `phone_otps` | 🆕 2026-08-30。id! │ org_id! │ phone! │ code_hash! │ purpose! │ line_user_id │ attempts!=0 │ sent_at!=now() │ expires_at! │ verified_at │ consumed_at |
| `rank_tiers` | 🆕 2026-08-31 段位區間主檔。code!（PK）│ label! │ min_rating! │ **auto!=true** │ **band!='low'** │ sort! │ note。<br>✅ **2026-09-01 全面改成從 0 起算**：銅 **0**／銀 145／金 325／白金 505／鑽石 685／大師 865。<br>⚠ **銅牌大階寬 145，其餘 180** —— 銅牌的第一小階只要 10 分（見 `rank_sub_levels`）。<br>🔴 `sub_count` **已移除**（2026-09-01）：小階門檻改成資料，它從此沒有人讀，而且會誤導。<br>⚠ **大師熊 `auto=false`** —— 要「本季 ≥20 個不同對手」，**分數再高也只到鑽石熊 I**。<br>🔴 因此 `rank_detail_tx` / `rank_from_rating` **永遠不會回「大師熊」**，只有 `member_rank_tx` 會。<br>⚠ `band` 決定順位點：low（銅銀金）/ mid（白金鑽石）/ top（大師）。<br>⚠ RLS 啟用、**0 條 policy**：只被 DEFINER 函式讀。 |
| `rank_sub_levels` | 🆕 2026-09-01 小階門檻。tier_code!（FK）│ sub!（IV/III/II/I）│ **offset_pts!** │ sort!。PK (tier_code, sub)。20 列（大師熊 0 列）。<br>🔴 **存的是「距離大階下限幾分」不是絕對值** —— `rank_tiers.min_rating` 仍是唯一真相，**兩者不可能對不起來**。<br>銅牌 `0/10/55/100`（間距 10/45/45）；其餘四階 `0/45/90/135`。<br>🎯 **它取代了「區間平均切四段」那個算法** —— 銅牌 145÷4=36 會算成 0/36/72/108，不是 0/10/55/100。<br>🎯 收益當天就兌現：銅牌 III 從 5 改 10 時**一支函式都不用動**。 |
| `rank_points` | 🆕 2026-08-31 順位點主檔。band! │ place!（PK 兩欄）│ points!。**band 沒有 CHECK，只有 PK** ⇒ 加一組是免費的。<br>**16 列**，**分段正和**：low `+30/+15/0/−20`（**+25**）／mid `+30/+10/−10/−30`（0）／top `+30/+5/−20/−40`（**−25**）。<br>✅ **2026-09-01 新增 `placement`（定位賽）`+30/+15/+10/+5`** —— 四組裡唯一**沒有負數**的，那正是它存在的理由。<br>🔴 **只在「人生第一場」套用**，第二場就回到 low（第 4 名扣 20）。<br>⚠ 判準是「有沒有結算過的場次」，**不是 `rating_games = 0`**（那個每季歸零，而且逐將遞增）。 |
| `season_champions` | 🆕 2026-08-31。season! │ org_id! │ member_id │ rating │ awarded_at!。<br>🔴 **降階之前先記冠軍** —— 降完就再也算不出來了（不可回溯）。<br>⚠ 沒有人到大師時 `member_id` 是 **null**（誠實的「本季從缺」）。<br>✅ **2026-09-01 改 PK 為 `(org_id, season)`** —— 原本是 `(season)` 一欄，<br>兩個 org 不可能在同一季各有冠軍，而那張表**明明有 `org_id`**。<br>表當時是空的所以零成本。<br>✅ 同日加外鍵 `(org_id, season) → rank_seasons(org_id, code)`：<br>季別字串從「流程規範」變成**資料庫規則**。 |
| `rank_tiers.min_opponents` | 🆕 2026-09-01。**本季要遇過幾個不同對手才給這個段位**；null = 沒有這個條件。<br>只有 `master` 有值：**50**（2026-09-01 從 20 改成 50）。<br>🔴 **它是資料不是程式碼**：`member_rank_tx` 讀它，`list_rank_tiers_tx` 回傳它，<br>前端三處文案（級距表底下、教學第 5 步 ×2）全部從主檔拿。<br>⚠ 改之前那個數字同時寫在四個地方，而它一天內就改過一次。 |
| `rank_seasons` | 🆕 2026-09-01 賽季起訖。code! │ org_id! │ label! │ starts_at! │ ends_at! │ created_at!。**PK (org_id, code)**。<br>2 列：`2026H2` 2026 秋季賽（07-01 → 2027-01-01）／`2027H1` 2027 春季賽。<br>🔴 **`ends_at` 不含**（半開區間），所以 07-01 結束與 07-01 開始不算重疊。<br>🔴 **`rank_seasons_no_overlap`：`exclude using gist (org_id =, tstzrange &&)`**<br>—— 兩季重疊 = 「現在第幾季」有兩個答案。<br>⚠ 需要 **`btree_gist`**（`org_id WITH =` 要它；gist 原生只認範圍型別）。<br>⚠ RLS 啟用、**0 條 policy**，比照 `rank_tiers`。<br>⚠ **季別名稱與切點是資料不是程式碼** —— 改名／改切點就是一句 UPDATE。 |

> 🆕 **2026-08-31 段位那一批新增的欄位**
> · `members.rating!=0` / `rating_games!=0`
>   ✅ **2026-09-01 預設從 1000 改成 0** —— 起點就是銅牌熊 IV。
>   🎯 **0 分比 1000 分好懂**：沒有人需要解釋「為什麼我一開始有 1000 分」。
>   ⚠ 改的當天全部重設為 0，因為**有段位的 0 人、有名次的 `session_players` 0 列**
>     —— 一場計分的牌局都還沒發生過。電子計分上線後就沒有這個機會了。
> · `session_players.rating_after`（那一場打完幾分）
>   ✅ **2026-08-31 起真的有讀者**：`get_my_games_tx` 回傳它，
>     成績頁的段位走勢圖（`migi-web/src/lib/ranktrend.jsx`）畫的就是這一欄。
>   🔴 **老實記一筆**：建立當天我在檔頭寫「成績頁要畫段位走勢圖就需要它」——
>     **那時候沒有任何人說過要做走勢圖**，我是從對 LOL 的印象推出一個需求，
>     再拿那個需求去合理化一個欄位。那正是「建了沒人讀」，而我一邊引用
>     那條規則一邊犯它。當天使用者問「我們有段位走勢圖嗎？」才發現。
>   📌 它撐得住的理由**不是**「圖需要它」，而是**不可回溯**：
>     不記的話，日後想在牌局紀錄上顯示「那場你還是銀牌熊」永遠做不到。
> 🔴 ~~`members.peak_rating`~~ **同日建了又刪掉**：歸零／降階設計不需要它，
>   而降階保護也不需要（規則是「不掉階」的話，當前分數本身就記著他到過哪一階）。
> 🔴 ~~小級（I–IV）沒有自己的門檻欄位，由區間平均切四段算出來~~
>   → **2026-09-01 改成 `rank_sub_levels`**。那個算法表達不出「銅牌第一階只要 10 分」
>   （145÷4=36），而那一條正是「打完第一場一定升級」的來源。
>   ⚠ 存**位移**不存絕對值，所以沒有第二個真相來源。
> **IV 最低、I 最高**（銅牌 IV **0** ／ III **10** ／ II 55 ／ I 100）。
> ⚠ **分數下限 0**（＝銅牌 IV，最低那一階的 `min_rating`，由 `min(min_rating) where auto` 算出來）。
>
> 🛡 **平時的降階保護（銅／銀／金）夾的是「大階」下限，不是小階：**
> ```
> 金牌熊 I 460 ── 連輸 ──> 440 → 420 → … → 325
>                                            ↑ 金牌熊 IV，卡在這裡
> ```
> ⇒ **會掉分、會掉小階、不會掉大階。** 銅 0 ／ 銀 145 ／ 金 325 就是各自的地板。
> ⚠ 白金以上**沒有**這個 clamp —— 那條線就是「平時開始會掉」的起點。
> ⚠ 賽季末降 2 大階是**另一種降階**（`reset_season_ratings_tx`），保護不管用。
>   文件曾經把這兩種混成一種，導致平時保護被誤刪過一次。

> 🔴 **`members.phone_verified_at`（2026-08-30 起才真的有人寫）** ——
> 欄位早就在，但在 `otp_consume_tx` 出現之前**掃全庫 0 支函式會寫它**。
> 也就是客人真的驗過簡訊，卻沒有人在他身上蓋章。
> 🎯 而**自助認領的分級完全建立在那個章上面**（未驗過的帳號只有在
> 沒有訂單也沒有餘額時才放行），所以那不是一個裝飾欄位。
>
> ⚠ `phone_otps` **啟用了 RLS 而且刻意 0 條 policy** ——
> 那不是漏掉：它只能被 service_role（Edge Function）碰到，
> 任何前端角色一律讀不到也寫不到。**驗證碼的雜湊沒有任何人需要看見。**

### 🎯 `orgs.live_from` —— 報表的第三層防線

**營運起始時間。`null` = 還沒上線 → 12 個 `v_real_*` 一律回 0 列。**

前兩層（根實體 `is_test`、自己的 `is_test`）**都依賴標記被正確設定**，
而那會壞 —— 2026-08-28 找到兩筆漏網事件（`test_event` 與一筆 `app_error`），
**兩筆都沒有門市也沒有會員，任何關聯都認不出它們是測試**。

🎯 **`coalesce(live_from, 'infinity')` 讓「忘記設」的後果是「報表全空」，
不是「報表錯的」。** 這個專案一再踩的坑（`is_test` 恆為 false、RLS 濾成空陣列、
`|| []` 讓數字通過）全都是「壞掉了但看起來正常」——**這個設計刻意讓失敗吵。**

⚠ **上線那天要做的唯一一件事**：
```sql
update orgs set live_from = '<真實客人開始使用的時間>';
```
🔴 那不是「修 bug 的日期」，是**真實客人開始使用**的時間。

### 12 個 `v_real_*`（報表一律查這些，不要查原表）

```
根實體  v_real_stores          v_real_members
交易    v_real_orders          v_real_order_items     v_real_order_payments
        v_real_topup_orders    v_real_wallet_txns     v_real_invoices
桌      v_real_table_sessions  v_real_session_players
配桌    v_real_match_queues
埋點    v_real_app_events
```

📌 **子表直接引用父表的 view**（`v_real_order_items` → `exists(v_real_orders)`）
—— 規則只定義一次，不可能漂。
⚠ 這些 view **一個授權都沒有** —— 只有 `service_role`／Dashboard 讀得到，
  跟「只有總部分析數據的人看得到」是一致的。
| `pricing_tiers` | id! │ org_id! │ store_id │ mode! │ rule_key! │ min_unit │ max_unit │ points! │ sort_order!=0 │ is_active!=true │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by |
| `product_taxonomy` | **dimension!** │ **code!**（PK 是兩者）│ label! │ parent_code │ sku_prefix │ sort!=0 │ is_active!=true │ note │ created_at! │ default_revenue_type<br>🆕 **2026-09-10 餐飲底下補到五個子分類**，而它們就是 **POS 結帳頁的商品分頁**：<br>`DRK 飲料 20 · DES 甜點 22 · FRY 炸物 24 · SNK 零嘴 26 · MEAL 主食 28`（數字是 `sort` ＝ 由左到右）。<br>🔴 **`MEAL` 的中文從「餐點」改成「主食」** —— 五類並列之後它會跟上一層的「餐飲」撞名。<br>🔴 **不要為分頁新增 `display_group` 欄位**（《首店餐飲籌備》第 10-1 節的提議已標成不做）：<br>`subcategory` 本來就在回答這件事，再加一個就是「一個事實兩個名字」。<br>🎯 真正會分岔的是**出餐站**（蛋塔歸甜點卻走廚房），那是第三個維度。 |
| `products` | id! │ org_id! │ **sku!** │ name! │ **category!** │ **unit_price!** │ unit_cost │ **is_active!=true** │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by │ **stock_qty!=0** │ **is_available!=true** │ **revenue_type!** │ **subcategory** │ **tracks_stock!=true** │ **is_system!=false** │ **discountable!=true** │ **spec**（2026-09-10）<br>🆕 **`spec`** ＝ 規格說明（「10 顆／份」），可空，POS 的商品卡與購物車印在品名下面。<br>🔴 它是**說明不是選項**：同一個商品要賣兩種份量（6 個裝／10 個裝）要**開兩個 SKU**，<br>在這一欄塞兩個值只會讓畫面說一件收不到錢的事。檯費那七支就是那種變體。<br>⚠ 沒填就整行不畫，不留空位。<br>📊 **2026-09-10 起共 39 筆**：32 餐飲（《首店餐飲籌備》第 1 節）＋ 7 檯費。<br>🔴 **餐飲 32 筆的 `stock_qty` 與 `unit_cost` 全是 0，那是刻意的** ——<br>會扣 `stock_qty` 的函式**至今 0 支**，填數字只會生出第二個「水餃 50」<br>（賣掉 224 筆從來沒動過，2026-09-10 一併清成 0）。 |
| `queue_tags` | code!（PK）│ label! │ sort_order!=0 │ is_active!=true │ created_at! |
| `recurring_tables` | id! │ org_id! │ store_id! │ weekday │ start_time! │ stake_level_id! │ game_type!='16張' │ **rounds!='2 將'**（同上）│ seats!=4 │ enabled!=true │ note │ created_at! │ frequency!=weekly │ flower │ lead_hours!=24 │ tags jsonb!=[] |
| `session_players` | id! │ org_id! │ session_id! │ member_id! │ join_type!=opener │ status!=playing │ charged_points!=0 │ **joined_at!** │ created_at! │ created_by │ finish_rank │ score_points │ settled_at │ **order_id** │ seat │ **left_at** │ **paid_by** │ **fee_waived_amount!=0** │ **fee_waived_reason** |
| `staff` | id! │ org_id! │ store_id │ **auth_uid** │ name! │ **role!=floor** │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by │ **member_id** |
| `stake_levels` | id! │ org_id! │ store_id │ label! │ base │ tai │ is_hygiene!=false │ sort_order!=0 │ is_active!=true │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by |
| `stores` | id! │ org_id! │ name! │ address │ is_active!=true │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by │ **code!** │ city │ district │ lat │ lng │ open_time │ close_time │ **store_type** │ **is_test!=false** │ entity_id │ phone │ parking │ photos jsonb!=[] │ note |
| `table_sessions` | id! │ org_id! │ store_id! │ table_id! │ **mode!** │ stake_level_id │ status!=open │ planned_minutes │ started_at! │ **ended_at** │ fee_points │ promoted_by_staff_id │ open_method │ deleted_at │ created_at! │ updated_at! │ created_by │ **updated_by** │ planned_rounds │ opened_by_staff_id │ activated_at │ idempotency_key │ is_test!=false │ game_type │ flower |
| `tables` | id! │ org_id! │ store_id! │ label! │ is_active!=true │ deleted_at │ created_at! │ updated_at! │ created_by │ updated_by │ area │ seats!=4 │ sort_order!=0 │ note │ 🎯 **auto_assign!=true** |
| `topup_orders` | id! │ org_id! │ store_id! │ member_id! │ topup_no │ points! │ **bonus_points!=0** │ amount_twd! │ pay_method! │ status!=paid │ external_ref │ idempotency_key │ invoice_no │ invoice_at │ wallet_txn_id │ staff_id │ note │ created_at! │ created_by │ entity_id │ held_by_entity │ **session_id** │ **cash_received** │ **change_given** │ txn_no |
| `topup_plans` | id! │ org_id! │ store_id │ **min_amount!** │ **bonus_points!=0** │ is_quick!=false │ sort_order!=0 │ is_active!=true │ created_at! |
| `wallet_balance_audit` | id bigint!（序列）│ member_id! │ org_id! │ old_balance! │ new_balance! │ delta! │ txn_sum │ is_synced │ db_user │ changed_at! |
| `wallet_txns` | id! │ org_id! │ store_id │ served_store_id │ member_id! │ **type txn_type!**（enum）│ amount! │ status!（enum）=completed │ counter_account │ reverses_txn_id │ idempotency_key │ external_ref │ **ref_table** │ **ref_id** │ staff_id │ note │ created_at! │ created_by |
| `wallets` | member_id!（PK）│ org_id! │ **balance!=0** │ updated_at! |

⚠ **`members` 沒有 `points_balance`** —— 餘額在 `wallets.balance`。
⚠ **`tables` 沒有 `status`** —— 桌況是從 `table_sessions` 動態算的。

---

## 🆕 牌咖團（2026-09-11 建立，三張表）

牌咖團**等同公會**（使用者 2026-09-11 拍板），不是一桌四個人。
前端 `buddies.jsx:136` 那個 `團員 · N/4` 是錯的，要拿掉。

```
teams          15 欄  org_id · name · intro · crest_emoji · crest_path · crest_blocked
                      home_store_id · join_policy · monthly_goal · member_limit
                      created_by · created_at · updated_at · deleted_at
team_members    9 欄  team_id · member_id · role · joined_at · left_at · left_reason
team_requests  11 欄  team_id · member_id · kind · status · created_by
                      decided_by · decided_at · expires_at
```
· `join_policy ∈ open | approval | closed` —— **三態**。八個朋友的團最常見
  的狀態就是「不要陌生人」，兩態少掉的正是那一個。
· `kind ∈ apply | invite` —— 申請與邀請是同一張表的兩個方向。
  🔴 `uq_team_request_pending` 保證同一組人同時只在談一筆。
  🎯 兩個方向撞在一起時**直接成交**，那正是雙方都同意的意思。
· `left_reason ∈ quit | kicked | disband` —— 移除寫 `kicked` 不重用 `quit`，
  否則那個欄位會說一件沒發生的事（同 2026-09-10 配桌那批的決定）。
· 三張表都 **RLS 開啟、0 條 policy** ⇒ 完全鎖死，只有 DEFINER 進得去。

### 🔴 「一起打了 N 場」只有一份定義：`_team_session_ids(team)`
```
一場算進團的戰績  ⇔  該場次每一位在座玩家，坐下的那一刻都還在團裡
                 且  在座人數 ≥ 2
```
· **整桌都是團員才算**（使用者明確推翻「兩位以上」）。兩個團員加兩個
  陌生人那桌不算 —— 那是配桌不是團的活動，正好對上包桌的語意。
· **資格看當時不看現在**（比對 `joined_at ~ left_at` 區間）。
  🔴 不這樣做的話，一個人退團會讓他參與過的每一場全部失效，
    團的總場數突然掉下來而且沒有任何地方會說為什麼。
· 下限放 2 不放 4 —— 只來三人的包桌是真的會發生（檯費就收三份）。
· 時間戳**只用 `session_players.joined_at`**，同時當「當時在不在團裡」
  與「這場算哪個月」用。刻意不碰 `table_sessions.started_at`
  （測試 fixture 那一欄比 `ended_at` 還晚）。
⚠ 驗證：`sql/checks/2026-09-11_驗牌咖團場次判定.sql`（12 格，含兩個方向的時間區間）。

### 函式 22 支（18 支對外給 `authenticated`，4 支內部誰都叫不到）
```
讀    list_my_teams_tx · get_team_tx · search_teams_tx · list_hot_teams_tx
建改  create_team_tx · update_team_tx · set_team_crest_tx · disband_team_tx
加入  apply_team_tx · invite_to_team_tx · respond_team_request_tx
      cancel_team_request_tx · list_team_requests_tx
治理  leave_team_tx · kick_team_member_tx · transfer_team_leader_tx
      claim_team_leader_tx
總部  admin_remove_team_crest_tx（`can('member.write')`，與頭像下架同一個碼）
內部  _team_session_ids · _team_card · _team_expire_requests · _team_notify
```
🔴 **這一批一律不收 `p_member_id`，身分只從 JWT 取**，而且
  `revoke from anon, public` ＋ `grant to authenticated`。
  全庫已經有 53 支簽名帶那個參數，不要變成 54（待辦 14）。
  ⚠ 已知代價：某個客人的 Supabase session 沒發成功時，牌咖團整頁 403，
    而其他頁照常。**那是大聲失敗**，比靜靜拿到別人的資料好。

🔴 **名冊只有團長拿得到 `member_id`**（2026-09-04 排行榜定的原則：
  不需要身分就不要交出身分）。
🔴 **名冊不給「上次來店」** —— 每一款手遊的公會名冊都有那一欄，但
  2026-08-26 為「常來時段」畫的那條線擋著：對別人的單向側寫不給客人看。
  給的是「本月一起打了幾場」，那是共同事實。

### ✅ 團徽照片（2026-09-11，使用者決定**不審核**）
```
bucket   team-crests   公開 · 512 KB · webp/jpeg   ← 與 member-avatars 逐項相同
         🔴 0 條 storage policy ⇒ 寫入只剩 service_role
函式     _is_team_leader（內部）—— 「誰能換團徽」全系統只有這一份
         team_crest_guard_tx / clear_team_crest_tx —— **只給 service_role**
Edge     team-crest（已部署，Verify JWT 開著）
```
🔴 後兩支收 `p_member_id` 是刻意的也是安全的：Edge Function 手上只有
  驗過簽的 LINE `sub`，**沒有會員 JWT** ⇒ `current_member_id()` 必為 null。
  同 `get_staff_by_line_tx` 的先例。**它們不算待辦 14 那 53 支。**
🔴 `set_team_crest_tx` 多一道牆：路徑必須以自己的 `team_id` 開頭 ——
  少了它，前端可以把**別人的圖**掛到自己團上，而且不會報錯。
⚠ 實機打過五項（無 key 401／無 token／`../` 路徑／假 token 真的去問了 LINE／
  CORS 200），`bad_team_id` 在任何事發生之前就擋掉路徑注入。

⚠ **已知缺口，四個 bucket 共通**：換頭像、換團徽、解散團、刪帳號
  都會留下孤兒檔，而**沒有任何東西在收**。
  🟢 今天零成本 —— `storage.objects` 目前 **0 個檔案**（三個 bucket 全空）。
  🎯 打卡照片一上線就會變成真成本（那是第一個有量的）。清理要做時
    一次涵蓋全部 bucket，不要為團徽單獨做一個。
📌 `store-photos` 是**建了沒人寫**：全庫只有 `get_store_detail_tx` 讀
  `stores.photos`，沒有任何寫入端，7 間門市 0 筆有值。

## 🆕 包桌預約（2026-09-11 建立，`bookings` 一張表）

使用者 2026-09-11：「**牌咖團最重要的功能就是預約包桌，這是首要**」。

```
bookings  17 欄  org_id · store_id · team_id · member_id
                 play_at · planned_hours · table_count · party_size · note
                 status · table_id · seated_session_id
                 cancelled_reason · created_by_staff_id
函式      客人  booking_capacity_tx · create_booking_tx
                cancel_booking_tx   · list_my_bookings_tx        身分＝JWT
          店員  pos_list_bookings_tx · pos_seat_booking_tx
                pos_mark_booking_tx                              身分＝current_staff()
          內部  _booking_capacity · _booking_expire
```
· RLS 開著、**0 條 policy** ⇒ 完全鎖死，只有 DEFINER 進得去。
· `planned_hours ∈ 2 / 5 / 24`，對齊既有三支包桌商品（`SVC-TBL-P02/P05/P24`，
  **單人計價** 100／150／200）。存的是**時長級距不是價格** —— 價格結帳時查主檔。
· `status ∈ booked · seated · cancelled · no_show · expired`。
  🔴 **五個值不可以合併** —— `cancelled` 是客人取消、`no_show` 是他沒來、
  `expired` 是系統過時收掉。合成一個的話**爽約率永遠算不出來**，
  而那是日後要不要收訂金的唯一依據。

### 🔴 預約佔的是「容量」不是某一張桌
```
建立時   只記「幾桌」，table_id 是 null
當天     店員才指定桌（pos_seat_booking_tx）
```
⚠ 一建立就綁死一張桌的話，那是自動帶桌「湊滿就佔桌、空等兩小時」
  （待辦 34）的放大版 —— 預約可以提前 90 天。
📌 所以**我文件裡原本那句「接上 `list_tables_tx` 既有的 `is_hold`」只對一半** ——
  那支的 `hold_kind` 只有 `queue` 與 `setup`，兩個都是「現在就佔住」。
  要不要多一個值，是**指定桌之後**的事。

### 🔴 容量判定刻意不管現在有沒有人在打
```
free = 店裡可用桌數 − 同時段其他「還活著的預約」佔走的桌數
```
⚠ **不扣掉正在打的桌**：現場客人幾點走沒有人知道，把猜測算進去會讓系統
  **用一個假的精確度拒絕真的預約**。這道牆防的是「同一個時段答應兩組人」，
  現場滿不滿是店員當下的判斷。
🔴 區間重疊只有一種寫法：`a < b+hb 且 b < a+ha`。
  寫成「開始時間在區間內」會漏掉**被整個包住**的那一種
  （別人 10:00 訂 24 小時，你 14:00 訂 2 小時）。
  ⚠ 假資料六種相對位置 ＋ 真資料各驗過一次。

### 🔴 `team_id` 可空，那是刻意的
沒有團的客人打電話來訂位**一定會發生**，而系統做不到時櫃檯就會
另外發明一套（紙本、LINE 訊息、店長的腦袋）。
⇒ **一個預約機制，牌咖團只是它的入口之一**，所以這張表不叫 `team_bookings`。

⚠ 驗證：`sql/checks/2026-09-11_驗包桌預約流程.sql`（16 格＋2 格回滾確認）。

⏳ **還沒做**：前端（會員 App 的預約抽屜、POS 的當日預約清單）。

---

⏳ **牌咖團還沒做**：前端已改完但**還沒實機看過**（`buddies.jsx`
  2026-09-11 接上真後端，`npm run build` 與四個靜態檢查器都過）。

## 二、CHECK 約束（全部）

🔴 硬規則 3.8：**錯誤訊息只給約束名字不給定義**，看到 `xxx_check` 就推論它在管什麼是猜的。

### 金流

| 約束 | 定義 |
|---|---|
| `orders.orders_amount_balance` | `payable = subtotal - coupon_discount - tier_discount` 且 `cash_due = payable - points_used`，且五個金額欄位皆 >= 0 |
| `orders.orders_status_check` | open / preparing / served / paid / void |
| `orders.orders_channel_check` | counter / table_qr / online |
| `order_payments.cash_fields_only_for_cash` | `method<>'cash'` → cash_received 與 change_given **都必須 NULL**；`method='cash'` → cash_received NOT NULL 且 **>= amount**，且 `change_given = cash_received - amount` |
| `order_payments.order_payments_method_check` | cash / credit_card / line_pay |
| `order_payments.order_payments_amount_check` | amount > 0 |
| `order_items.order_items_qty_check` | qty > 0 |
| `order_items.order_items_revenue_type_chk` | NULL 或 venue_fee / fnb / retail / other（⚠ 欄位本身是 NOT NULL，所以 NULL 走不到） |
| `wallets.wallets_balance_check` | balance >= 0 |
| `wallet_txns.chk_amount_direction` | type ∈ topup/refund/reversal/adjust **不限方向**；type ∈ table_fee/fnb/merch/event_fee/**spend** 則 **amount < 0** |

### 商品與券

| 約束 | 定義 |
|---|---|
| `products.products_category_check` | fnb / merch / service |
| `products.products_revenue_type_check` | NULL 或 venue_fee / fnb / retail / other |
| `products.products_unit_price_check` | unit_price >= 0 |
| `products.products_stock_qty_check` | stock_qty >= 0 |
| `product_taxonomy.product_taxonomy_dimension_check` | **category / subcategory / revenue_type** |
| `coupons.coupons_kind_check` | table_discount / unlimited_play / ride / fnb / topup_bonus / generic |
| `coupons.coupons_discount_type_check` | **percent / fixed / free** |
| `coupons.coupons_applies_to_check` | NULL 或 table_fee / fnb / **ride** / **topup** ⚠ 後兩個不是商品分類（待辦 0.8） |
| `coupons.coupons_cost_bearer_chk` | store / hq |
| `coupons.coupons_min_spend_check` / `max_discount_check` | NULL 或 >= 0 |
| `member_coupons.member_coupons_status_check` | active / used / expired |
| `member_coupons.member_coupons_cost_bearer_chk` | NULL 或 store / hq |
| `member_coupons.member_coupons_discounted_amount_check` | NULL 或 >= 0 |

### 會員

| 約束 | 定義 |
|---|---|
| `members.members_tier_chk` | NULL 或 bubble_tea / caramel_pudding / tiramisu / chef_special |
| `members.members_tier_override_chk` | 同上（作用於 `tier_override`）|
| `members.members_display_name_chk` | NOT NULL 且 `= migi_norm_nickname(display_name)` 且長度 **1–12** 且不含 `migi\|官方\|客服\|店長\|管理員\|系統\|admin` |
| `members.members_gender_check` | NULL 或 female / male / other |
| `members.members_lifecycle_check` | new / growing / regular / at_risk / churned |
| `members.members_sched_chk` | NULL 或 早上為主／下午為主／晚上為主／深夜為主／**不一定**（NOT VALID）|
| `members.members_see_score_chk` | 所有人／牌咖／只有自己（NOT VALID）|
| `members.members_avatar_source_chk` | bear / photo　⚠ **只有兩個值** —— LINE 大頭貼要走 `photo`（抓下來存自己的 storage），不要加第三個值 |
| `members.avatar_bear` | 🆕 2026-08-29。會員選用的小熊造型名稱（例：`金牌熊`）。**null = 沒選過，依 `rank` 推導**（維持原行為）。<br>⚠ **刻意不加 CHECK**：小熊清單是**內容**不是狀態，會增加；壞值時 `rankBearSrc()` 會 fallback 回**銅牌熊**，不會壞掉。<br>📌 渲染規則：`rankBearSrc(avatar_bear \|\| rank)` |
| `members.rank` | NOT NULL **DEFAULT `'銅牌熊 I'`**，🔴 **沒有 CHECK**。<br>⚠ `rankBearSrc()` 是用 `indexOf` 逐條比對關鍵字（雀神→大師→鑽石→白金→金牌→銀牌→其餘銅牌），<br>所以 `'大師級銅牌熊'` 會匹配到**大師** —— 順序決定結果。今天只有系統在寫這欄，但值得知道 |
| `members.members_phone_chk` | NULL 或 `= migi_norm_phone(phone)`（2026-08-28 新增）—— **等於強制只收 09 開頭 10 碼**，市話與國際格式在寫入時就被擋 |
| `members.members_inv_type_chk` | member / mobile / citizen / donate / company / paper |
| `member_tiers.member_tiers_pct_chk` | 0 <= discount_pct <= 100 |
| `member_availability.*_slot_check` | **morning / afternoon / evening / late**<br>🔴 **幾點到幾點的定義在 `migi_slot_of(ts)`**（2026-09-01 建，全系統唯一一份）：<br>`late 00–06`／`morning 06–12`／`afternoon 12–18`／`evening 18–24`（**台北時間**）。<br>⚠ M3 的推斷引擎要用**同一支**，不要再寫一份「晚上是幾點」<br>—— 那就是同一個名字兩種意思（同待辦 35 那個病）。<br>⚠ 該函式 anon 與 PUBLIC 都收掉了，只給 service_role（只被 DEFINER 內部呼叫）。 |
| `member_availability.*_preference_check` | **often / sometimes / never** |
| `member_availability.*_source_check` | **stated / inferred** |
| `member_availability.*_weekday_check` | 0–6 |
| `member_interactions.*_channel_check` | system / staff |
| `member_interactions.*_kind_check` | care / birthday / winback / welcome / note |
| `member_blocks` / `member_likes` / `buddy_invites` | 各有「不可對自己」的 CHECK |
| `mahjong_buddies.*_origin_check` | **pre_existing / matched** 🎯 護城河深度 = `count(*) where origin='matched'` |
| `mahjong_buddies.mahjong_buddies_check` | member_id <> buddy_id |
| `buddy_invites.*_status_check` | pending / accepted / rejected |
| `phone_otps.phone_otps_purpose_check` | **register / claim / change** 🆕 2026-08-30。<br>⚠ 註冊流程實際用的是 **`register`**（驗過之後由後端決定是註冊還是認領）；<br>`claim` 留給日後獨立出來的認領入口，`change` 給個人設定改手機 |

### 桌與配桌

| 約束 | 定義 |
|---|---|
| `table_sessions.*_status_check` | open / completed / **voided** |
| `table_sessions.*_mode_check` | matched / private |
| `table_sessions.*_open_method_check` | NULL 或 **auto / manual** |
| `table_sessions.*_game_type_chk` | NULL 或 台麻 / 美麻 |
| `table_sessions.*_flower_chk` | NULL 或 無花 / 有花 |
| `session_players.*_join_type_check` | opener / mid_join / sub |
| `session_players.*_status_check` | **playing / completed / late / forfeit**（⚠ 沒有 `left`）|
| `session_players.chk_finish_rank` | NULL 或 1–4（NOT VALID）|
| `match_queues.*_status_check` | waiting / matched / seated / cancelled / expired |
| `match_queues.*_source_check` | member / **pos** / recurring |
| `match_queues.*_seats_check` | 2–4 |
| `match_queues.*_game_type_chk` / `*_flower_chk` | 台麻／美麻、無花／有花（NOT VALID）|
| `match_queue_players.*_leave_reason_check` | quit / cancelled / expired / **switched** / **staff_removed**（後者 2026-09-10 新增）<br>⚠ `switched` 在 2026-09-10 之前**沒有任何函式寫過** —— schema 為「移動」保留的字，線上唯一那一列是手動改的 |
| `recurring_tables.*_frequency_check` | daily / weekly |
| `recurring_tables.recurring_lead_hours_chk` | 1–720 |
| `pricing_tiers.*_mode_check` | matched / private |

### 其他

| 約束 | 定義 |
|---|---|
| `app_events.app_events_event_check` | 🔴 **不是白名單，是格式** —— `event ~ '^[a-z][a-z0-9_]{0,49}$'` |
| `app_events.app_events_props_check` | `pg_column_size(props) <= 8192` |
| `app_notifications.*_type_check` | settle / buddy_req / buddy_ok / table_req / table_ok / system / **table_expired** |
| `invoices.invoices_amount_chk` | `sales_amount + tax_amount = total_amount` |
| `invoices.invoices_status_chk` | pending / issued / void / failed |
| `invoices.invoices_kind_chk` | invoice / allowance |
| `invoices.invoices_ref_chk` | ref_table ∈ orders / topup_orders |
| `invoices.invoices_tax_chk` | tax_type ∈ 1/2/3/4/9 |
| `topup_orders.*_status_check` | pending / paid / void / refunded |
| `topup_orders.*_pay_method_check` | cash / credit_card / line_pay / **jko** / other |
| `topup_orders.*_points_check` | points > 0；`bonus_points >= 0`；`amount_twd > 0` |
| `topup_plans.*` | min_amount >= 0；bonus_points >= 0 |
| `staff.staff_role_check` | **floor / manager / hq / owner** |
| `stores.stores_store_type_chk` | NULL 或 直營／加盟／系統授權／自家場 |
| `legal_entities.legal_entities_kind_chk` | hq / franchise / licensed |
| `orgs.orgs_plan_check` | self / franchise / licensed |
| `bonus_rules.*_rule_key_check` | match_made / visit_commission |

---

## 三、唯一性（約束與索引兩邊）

🔴 2026-08-26 的教訓：查「有沒有唯一限制」時 **`pg_constraint` 與 `pg_index` 兩邊都要看** ——
`CREATE UNIQUE INDEX` 建的**不會出現在 `pg_constraint` 裡**。

### 部分唯一索引（有 WHERE 條件 —— 最容易誤判的一類）

| 索引 | 定義 |
|---|---|
| 🔴 `members.uq_members_line_user` | `(line_user_id)` WHERE line_user_id IS NOT NULL AND deleted_at IS NULL —— **全域唯一，承重牆**（`sql/` 裡找不到，Dashboard 手建）|
| `members.uq_members_line` | `(org_id, line_user_id)` 同條件 —— M0 地基，與上者意圖矛盾但兩個都留 |
| `members.uq_members_phone` | `(org_id, phone)` WHERE phone IS NOT NULL AND deleted_at IS NULL |
| `table_sessions.uq_sessions_open_table` | `(table_id)` WHERE **status='open' AND deleted_at IS NULL** 🎯 收桌自動放桌就靠這個 |
| `table_sessions.uq_sessions_idem` | `(idempotency_key)` WHERE NOT NULL |
| `orders.uq_orders_idem` | `(idempotency_key)` WHERE NOT NULL |
| `orders.orders_org_no_uq` | `(org_id, order_no)` |
| `wallet_txns.uq_txn_idempotency` | `(org_id, idempotency_key)` WHERE NOT NULL |
| `topup_orders.topup_orders_idem_uq` | `(org_id, idempotency_key)` WHERE NOT NULL |
| `topup_orders.topup_orders_org_no_uq` | `(org_id, topup_no)` |
| `mahjong_buddies.uq_buddies` | `(member_id, buddy_id)` WHERE deleted_at IS NULL |
| `session_players.uq_session_player` | `(session_id, member_id)` ⚠ **無 WHERE** —— 帳號合併最刺的一個 |
| `staff.uq_staff_member_store` | `(member_id, store_id)` WHERE deleted_at IS NULL —— 一人可多列，同店只能一列 |
| `match_queue_players.uq_queue_member` | `(queue_id, member_id)` WHERE left_at IS NULL |
| `buddy_invites.uq_pending_invite` | `(inviter_id, invitee_id)` WHERE status='pending' |
| `member_blocks.uq_block_pair` | `(blocker_id, blocked_id)` |
| `member_likes.uq_like_per_session` | `(liker_id, target_id, session_id)` WHERE session_id IS NOT NULL |
| `member_availability.uq_availability` | `(member_id, weekday, slot, source)` |
| `member_coupons.member_coupons_org_code_uq` | `(org_id, code)` |
| `products.uq_products_sku` | `(org_id, sku)` WHERE deleted_at IS NULL |
| `tables.uq_tables_store_label` | `(store_id, label)` WHERE deleted_at IS NULL |
| `stores.stores_org_code_uq` | `(org_id, code)` |
| `topup_plans.uq_topup_plans_tier` | `(org_id, coalesce(store_id,'000…'), min_amount)` |

✅ 全部 `indisvalid = true`（INVALID 的索引會存在、看得到、但完全不擋，而且沒有症狀）。

### 約束型唯一

`staff.staff_auth_uid_key` UNIQUE(auth_uid) ⚠ **總部 Email 那條路一人只能一列**
`invoices.invoices_idempotency_key_key` UNIQUE(idempotency_key)

### 複合主鍵

`doc_counters (org_id, store_id, doc_type, doc_date)`｜`product_taxonomy (dimension, code)`
`member_tiers (code)`｜`queue_tags (code)`｜`wallets (member_id)`｜`member_app_state (member_id)`

---

## 四、函式（全部，含授權）

> 讀法：`DEFINER/INVOKER`　`anon=` 是 POS 與會員 App 用的角色。
> 🔴 硬規則 2.5：**讓前端第一次直接呼叫某支既有 RPC 時，必須先確認它有 `anon EXECUTE`。**

### 🔴 `pos_` 前綴的函式一律不給 anon（2026-09-09 起）

```
19 支 pos_*     anon 0 · PUBLIC 0 · authenticated 19
全庫 anon 明確授權   108 → 95
全庫 PUBLIC          106 → 93
函式總數             183（不變）
```
`2026-09-09_pos函式全面收掉anon.sql`（7/7 全過）。收之前 **13 支 anon 叫得動、
而且零權限檢查**，其中最嚴重的是：

```
pos_search_members_tx(p_org_id, p_keyword)
回傳 id · nickname · phone · tier · rank · title · avatar · balance · is_test
比對 display_name ilike '%kw%' OR phone like '%kw%'   limit 20
```
`p_org_id` 寫在公開前端的打包檔裡 ⇒ 送 `keyword = '0'` 就能列出 20 個會員的
**手機、餘額、member_id** —— 正是 2026-08-30 收掉 `register_member_tx` 時堵住的洞。
✅ 同批補上 `can('member.lookup')`，且 `p_org_id := public.current_org_id()`
（**只收授權不夠** —— 收成 `authenticated` 之後任何登入的會員仍然叫得動）。

🎯 **判準是前綴本身，不是簽名也不是動詞。** 一支叫 `pos_*` 的函式，
**照定義就是店員操作** —— 那是**結構性的**，不用維護一份清單。
🔴 前四批（2026-09-04／09-08）用「簽名含 `p_member_id`」與金錢動詞正則，
  **13 支全部漏掉** —— 那些判準描述的是「它長什麼樣子」，
  而前綴描述的是「**它是什麼**」。同 `analytics.js` 用 `pos_` / `admin_` 前綴、
  錯誤儀表改掃 `%\_error` 的理由：**讓涵蓋範圍是結構，不是一份要維護的清單。**

⚠ **刻意仍然給 anon 的四支**（負對照，這批沒動）：
`log_app_event_tx`（埋點）／`get_my_orders_tx`／`list_topup_plans_tx`／`list_tables_tx`。

### 金流（🔴 全部是 INVOKER —— 前端不可直接呼叫）

```
checkout_tx(p_member_id, p_store_id, p_items jsonb, p_coupon_ids uuid[],
            p_points_used, p_payments jsonb, p_idempotency_key, p_staff_id)   INVOKER anon=✅
_charge_core(...)                                                              INVOKER anon=✅
charge_fnb_tx(...)                                                             INVOKER anon=✅
reverse_txn_tx(p_original_txn_id, p_idempotency_key, p_reason)                 INVOKER anon=✅
charge_matched_tx(...)                                                         INVOKER anon=無 auth=無 🔴 死碼候選
charge_private_tx(...)                                                         INVOKER anon=無 auth=無 🔴 死碼候選
```

### 結帳包裝層（DEFINER，前端呼叫這些）

```
join_session_tx(p_session_id, p_member_id, p_join_type, p_coupon_ids, p_points_used,
                p_payments, p_staff_id, p_idempotency_key, p_pay_for uuid[], p_items)  DEFINER ✅
pos_addon_checkout_tx(p_session_id, p_member_id, p_items, p_coupon_ids,
                      p_points_used, p_payments, p_idempotency_key, p_staff_id)        DEFINER ✅
pos_quick_checkout_tx(p_member_id, p_store_id, p_items, p_coupon_ids, p_points_used,
                      p_payments, p_idempotency_key, p_staff_id, p_topup_points,
                      p_topup_amount, p_topup_method, p_topup_cash_received,
                      p_topup_change_given, p_note)                                    DEFINER ✅
pos_checkout_with_topup_tx(p_session_id, p_member_id, p_join_type, p_items, p_coupon_ids,
                      p_points_used, p_payments, p_pay_for, p_staff_id, p_idempotency_key,
                      p_topup_points, p_topup_bonus, p_topup_amount, p_topup_method,
                      p_topup_cash_received, p_topup_change_given)                     DEFINER ✅
topup_tx(p_member_id, p_store_id, p_points, p_amount_twd, p_pay_method,
         p_idempotency_key, p_bonus_points, p_external_ref, p_staff_id, p_note)        DEFINER ✅
topup_void_tx(p_topup_id, p_idempotency_key, p_staff_id, p_reason)          DEFINER anon=無 🔴
calc_topup_bonus_tx(p_org_id, p_store_id, p_amount_twd)                                DEFINER ✅
calc_session_fee_tx(p_session_id, p_join_type, p_member_id)                             DEFINER ✅
has_daypass_tx(p_org_id, p_member_id, p_store_id)                                       DEFINER ✅
```

### 錢包稽核

```
fix_wallet_balance_tx(p_org_id, p_member_id)      reconcile_wallets_tx(p_org_id)
audit_wallet_balance()                             daily_wallet_audit_tx(p_org_id)
```

### 開桌 / 桌況

```
open_session_tx(p_table_id, p_mode, p_stake_level_id, p_planned_rounds, p_planned_minutes,
                p_staff_id, p_open_method, p_idempotency_key, p_game_type, p_flower)
activate_session_tx(p_session_id, p_staff_id)
settle_session_tx(p_session_id, p_staff_id, 🎯 p_keep_for_walkin)
void_session_tx(p_session_id, p_staff_id)
cleanup_empty_sessions_tx(p_idle_minutes)
get_session_tx(p_session_id)          get_session_member_orders_tx(p_session_id, p_member_id)
list_tables_tx(p_org_id, p_store_id)  set_table_active_tx / 🎯 set_table_auto_assign_tx
check_session_blocks_tx(p_session_id, p_member_id)
```

### 配桌 / 固定局

```
create_match_queue_tx / join_match_queue_tx / leave_match_queue_tx / update_play_at_tx
list_match_queues_tx / list_match_queues_by_city_tx / get_my_active_queue_tx
dev_clear_my_queues_tx / sweep_expired_queues_tx / sweep_auto_seat_tx
_check_join_conflict / _finalize_queue_full_tx / _try_auto_seat_tx
pos_create_queue_tx / pos_list_queues_tx / pos_close_queue_tx / pos_seat_queue_tx
pos_add_queue_member_tx / pos_queue_members_tx / pos_table_forecast_tx
🎯 pos_create_recurring_tx / pos_list_recurring_tx / pos_set_recurring_enabled_tx
🎯 pos_set_recurring_tags_tx / generate_recurring_instances_tx
send_table_invite_tx / respond_table_invite_tx / list_queue_tags_tx
```

### 社交

```
send_buddy_invite_tx / respond_buddy_invite_tx / remove_buddy_tx

list_buddies_tx(p_org_id, p_member)  DEFINER · anon ✅
  ✅ 2026-09-01 補 `last_played_at`（簽名不變）—— 牌咖卡的「上次同桌」。
  ⚠ **從 `session_players` 即時算，`mahjong_buddies` 沒有這個欄位、也不該加**
    （同待辦 1 的 B 案：存計數欄位會出現「欄位與事實對不上而且無從得知
    哪邊才對」，退款／作廢／補登漏一次回沖就永久偏差）。
  🔴 **不加 `finish_rank is not null` 的條件** —— 同桌是**事實**，
    輸贏才需要結算。加了的話這一格在 M4 的 L0 電子計分之前永遠是空的，而且沒有症狀。
  ✅ 2026-09-01 再補 `play_pattern`（**常一起打**，取代牌咖卡的「段位」那一格）。
    回**結構** `{weekday, slot, n}` 不回句子 —— 組字是顯示規則，不住在資料庫裡。
    🔴 **門檻是「眾數要過半」不是「≥ 2 次」**：
      週六 2 次／週日 2 次會讓 `≥2` 宣稱「常在週六」，而一半的場次不是週六。
      **「最多的那一個」不等於「常」。**
    兩層退化：`(星期,時段)` 過半 → 給星期｜只有 `時段` 過半 → `weekday: null`｜
      都沒過半 → **整個回 null**（前端顯示 `—`）。另加總同桌 ≥ 3 場。
    🔒 **只統計「查看者自己也坐過」的場次** —— 那是兩人共同的事實，
      不是對他的側寫（硬規則 26 的界線：行為推斷只有總部看得到）。
      ⚠ 日後想加「他通常幾點來」就越線了。
  🗑 **刻意不回傳 `win_count` / `loss_count`**：牌咖卡的「勝 / 負」那一格
    2026-09-01 拿掉了（電子計分之前每一格都會是 `0 / 0`）。
    📌 定義當天有拍板：**分數比對方高就是勝**（+20 對 +10 記一勝）。
      要加回來時 `loss` 一定要**後端各自數**，不可以用「同桌次數 − 勝」
      —— 那會把**平手**與**未結算**的場次全部算成輸。
    ⚠ 那是**對戰成績**不是勝率；成績頁的「各級距勝率」沒有對手可以比，
      **仍然沒有定義**。
list_recent_players_tx / like_player_tx / _blocked_between
block_member_tx / unblock_member_tx / list_blocks_tx
list_notifications_tx / mark_notifs_read_tx / unread_count_tx
```

### 會員 / 個人檔案

```
register_member_tx(p_org_id, p_display_name, p_phone, p_line_user_id, p_home_store_id, p_created_by)
  find-or-bind-or-create，回傳 action ∈
    existing_line / rebound / line_conflict / existing_phone / created
  ⚠ **raise 的訊息是英文代碼不是中文人話**（前端必須自己翻，見 App.jsx 的 REG_ERR）：
    phone_invalid ／ display_name_reserved ／ display_name too long (max 12)
    ／ display_name required ／ need phone or line_user_id ／ org_id required
  ✅ 2026-08-28 起：**暱稱與手機都在「查詢之前」與「寫入之前」正規化**
    （migi_norm_nickname／migi_norm_phone），禁字改成明確 raise
    `display_name_reserved` 而不是讓 CHECK 拋 23514。
    🔴 在此之前只做 trim → 暱稱有連續兩個空格或全形空格就撞
      members_display_name_chk，客人看到「資料有誤」而永遠註冊不了。
rebind_line_user_tx(p_member_id, p_new_line_user_id, p_staff_id, p_reason)
  ⚠ 這是**店員的補救工具**不是註冊流程的一部分（簽名有 p_staff_id 就是證據）
get_wallet_tx / get_my_orders_tx

get_my_profile_tx(p_org_id, p_member_id)  DEFINER · STABLE · anon ✅
  ✅ **2026-09-01 補兩個埋點用的欄位**（簽名不變，待辦 37）：
  | 欄位 | 回答什麼 | 誰決定 |
  |---|---|---|
  | `is_test` | **這個人**是不是測試帳號 | 🔴 **人**（`members.is_test` DEFAULT **false**） |
  | `live` | **整間店**上線了沒有 | ✅ **事實**（`orgs.live_from` 有值**且已到**） |

  🔴 **只有 `is_test` 不夠**：它預設 `false` ⇒ **新的測試帳號預設會被當成
    真實客人**，而且沒有症狀。2026-08-29 真的發生了（創辦人用 LIFF
    註冊出 `山劍八舞澤`，而前端那份寫死的 uuid 清單不知道）。
  🎯 **`live` 不是猜的是定義**：`live_from` 是 null 就是還沒開店 ⇒
    那時沒有任何人是真實客人。12 支 `v_real_*` 一直用同一個事實。
  ⇒ 前端判準是 `!live || is_test`：上線前**沒有人需要記得標記任何帳號**。
  ⚠ **兩個都要在這一支回**，不能只放在 `register_member_tx`：
    創辦人是**註冊完約一小時後**才被標成測試的
    （`app_events` 裡 2 筆 false、632 筆 true，分界在 8/29 07:00）——
    只存註冊當下的值等於沒修。同 CLAUDE.md 的快取鐵律：
    **只能有一個寫入點，而且要會自我校正。**
  ⚠ 前端 `App.jsx` 開機也拉一次 —— 在此之前 `fetchMyProfile()`
    只在配桌／個人設定／獎勵頁 mount 時跑，而**預設落地頁是錢包**。

get_my_games_tx(p_org_id, p_member_id, p_limit = 20)
  DEFINER · STABLE · language=sql · anon ✅
  ⚠ 只回 `table_sessions.status = 'completed'` 且我坐過的場次
  ✅ 2026-08-31 補回傳兩欄（簽名不變）：
    `my_rating_after`（那一場結算後的段位分數）
    `settled_at`（結算時間 —— **不是 `ended_at`**，收桌與結算是兩個動作）
    → 成績頁的**段位走勢圖**唯一的資料來源（`lib/ranktrend.jsx`）
  ⚠ M4／電子計分之前這兩欄**全部是 null**，那是預期的不是壞掉

get_my_stats_tx(p_org_id, p_member_id)                    ★ 2026-09-03 新增
  DEFINER · STABLE · language=plpgsql · anon ✅
  → { ok, season_from, min_games,
      season: { games, avg_rank, ranks, national_rank, national_total,
                opp_rating, opp_rank, stakes[],
                scored, wins, best_score, streak },        ★ 2026-09-07
      all:    { games, avg_rank, ranks, stakes[],
                minutes, peak_rating, peak_rank, stores, opponents,
                best_rank,
                scored, wins, best_score } }               ★ 2026-09-07
  stakes[] 每一列 = { label, games, scored, wins, hygiene }  ★ hygiene 2026-09-07

  ── ★ 桌上積分那一批（2026-09-07，簽名沒變 ⇒ CREATE OR REPLACE）──
  `scored` **有積分的場數**（分母）· `wins` 積分 > 0 · `best_score` max
  `streak` 最長連勝 —— **只有 season 有**（連勝會被打斷、會重來，
          是賽季性質不是生涯性質）。⚠ 平（0 分）**會中斷連勝**。
  🔴 **分母是 `scored` 不是 `games`**：純娛樂的 `final_score` 是
    **null 不是 0** ⇒ 不進分母。用 `games` 當分母的話，常打純娛樂的人
    勝率會被稀釋成一個爬不上去的數字，**而畫面上完全看不出原因**。
  🔴 **`hygiene` 不是裝飾**：`scored = 0` 有兩種完全不同的原因 ——
    純娛樂（設計，那桌不計積分）與 09-06 之前收的桌（欄位還不存在），
    **在數字上一模一樣**。少了這個旗標，前端只能對兩件事說同一句話。
  🔴 **絕不可以改回讀 `score_points`** —— 它叫 score，裝的是**段位分**
    （`apply_session_rounds_tx` 寫的），用它等於「只要沒掉段就算贏」，
    而且定位賽四家得點全是正的 ⇒ 第 4 名會算成勝。2026-09-01 移除過一次。
  ⚠ 連勝排序用 **`coalesce(ended_at, settled_at)`** 不是 `settled_at` ——
    `sql/_工具/測試戰績_造.sql` 造的 8 場 `settled_at` 全部相同，
    照它排是任意順序。段位走勢圖用的也是同一個時間軸。

### 🔴 賽季名次快照（2026-09-03）—— 排名只能有一個定義
```
season_standings(org_id, season, member_id, rating, rank_no, games, recorded_at)
  PK (org_id, season, member_id) ＋ ix_season_standings_member (org_id, member_id, rank_no)
  RLS 開著、**0 條 policy** —— 跟 rank_tiers / rank_points / rank_seasons /
  season_champions 一致：誰都不能直接讀，只有 DEFINER 函式讀得到
  （它裝的是全體會員的分數與名次）

season_rank_rows_tx(p_org_id, p_from, p_to = null)
  → setof (member_id, rating, rank_no, games)
  DEFINER · STABLE · 🔴 **anon 與 PUBLIC 都收掉了**（只有 service_role）
```
🎯 **`get_my_stats_tx` 的即時排名與 `reset_season_ratings_tx` 的名次快照
  都呼叫 `season_rank_rows_tx`。** 各寫一份的症狀是
  「他看到自己第 3 名，歷史卻記成第 5 名」—— **而且不會報錯**。
  （同 `migi_slot_of()` / `rating_window_start_tx()` 那兩次的做法。）

⚠ **`reset_season_ratings_tx` 的順序有兩個不能反的地方**：
  ① 先記冠軍 ② **再存名次快照** ③ 才降 2 大階。
  🔴 快照寫在降階之後，存下來的就是**新一季的起點**而不是那一季的成績 ——
    而那個錯誤在畫面上完全看不出來。
  ⚠ 快照的上限用那一季的 `ends_at` 不是 `now()` ——
    結算晚了幾天的話，那幾天的牌局屬於**下一季**。

⚠ **冠軍 ≠ 榜首，兩者刻意不同**：
  `season_champions` 要求「**是大師熊**」（含 50 位不同對手），
  `season_standings` 第 1 名只看**分數最高**。
  ⇒ **沒有人到大師熊的那一季，冠軍是 null 但榜首有人。**
    那是對的：雀神熊是頒給達標者的，排行榜是排所有人的。
  ✅ `season_champions.member_id` 是 nullable，所以「沒有冠軍」插得進去。

✅ **大師熊以上段位分沒有上限**（2026-09-03 實測 900 → 960）——
  `apply_session_rounds_tx` 只有下限（低段 `greatest(v_new, v_floor)`），
  **沒有任何 `least(...)`**。所以拿段位分排名在榜首附近依然分得出高下。
  🔴 哪天有人加了封頂，排行榜會靜靜變成一堆並列而**不會報錯** ——
    那支 SQL 的驗證段第 ⑩ 格就是在守這件事。

⚠ **驗證段要插 `rank_seasons` 必須避開現有賽季的區間**（2026-09-03 炸過一次）：
  `EXCLUDE USING gist (org_id WITH =, tstzrange(starts_at, ends_at) WITH &&)`。
  現有只有 2026H2（2026-07-01 → 2027-01-01）與 2027H1（→ 2027-07-01），
  所以測試用 **2020 年**那一段。
  ✅ 那次炸掉**沒有留下任何測試資料** —— `begin…exception` 的子交易會把
    任何例外回滾到儲存點，而 DDL 在 DO 區塊外面所以照樣提交。
    **這個樣板是 fail-safe 的。**

  ### 🎯 分工原則（2026-09-03 盤點後定的，兩邊都不要放同一種東西）
  ```
  足跡／歷史（all）  只增不減的「量」    → 總數・最高・第一次
  賽季 KPI（season） 會上下的「率與位置」 → 比率・名次・排名
  ```
  🔴 **放錯邊的代價很具體**：累計數字放進賽季，**換季那天全部歸零**，
    客人會以為紀錄不見了；「率」放進足跡，那個數字十年不會動。
  ⚠ 所以 `minutes` / `stores` / `opponents` / `peak_*` 一律在 `all`，
    `opp_rating` / `national_rank` 一律在 `season`。

  ### 🔴 各級距「勝率」已停用到 M4（2026-09-03，同一天建了又拆）
  `stakes[]` 現在**只回 `label` 與 `games`**（沒有 `wins`、沒有 `pct`）。
  原因是一個資料層的誤會，值得記著：
  ```sql
  -- apply_session_rounds_tx 裡：
  score_points = (e->>'pts')::int      -- pts 累加自 rank_points（段位積分）
  ```
  ⇒ **`session_players.score_points` 裝的是段位積分，不是桌上積分。**
    實測創辦人九場，它與段位分變動**逐列相同**（60 / 30 / 0 / −40 …）。
  ⇒ 我當天早上定的「勝 = `score_points > 0`」實際上等於
    「**段位分有沒有上升**」—— 而使用者明確講過不要用 MIGI 積分。
    它的效果是「名次 ≤ 2 才算贏」，也就是日麻的**連對率**。
  🔴 **桌上積分在資料庫裡根本沒有欄位**（`session_players` 只有
    `charged_points` 檯費、`score_points` 段位分、`rating_after`）。
    要等**電子計分（M4）**。
  🔴 **`score_points` 這個欄位名本身是陷阱**（一個名字兩種意思，
    CLAUDE.md 記過三次的病）。M4 時要一起處理：真正的桌上分數另開欄位，
    或把這一欄正名成 `rating_delta`。**不要在那之前讓任何新功能讀它。**
  📌 同一批也拿掉了 `avg_score`（前端「平均得點」那一格已刪 —— 它印的是
    平均段位分，而段位走勢圖已經在講同一件事）與 `champions`
    （前端「雀神次數」那一格已刪）。**回了沒人讀就是下一個「建了沒人讀」。**

  ★ 2026-09-03 補的（`create or replace`、簽名沒變）：

  · **`ranks`** = 名次分布 `{"1":n,"2":n,"3":n,"4":n}`，**回次數不回百分比**。
    🔴 為什麼要它：**平均順位單獨看不出人** —— `2.5` 同時是
      「永遠 2、3 名」與「一半第一、一半第四」的答案。天鳳／雀魂的個人頁
      頭條就是這個分布，平均順位反而是附註。
    🎯 對 MIGI 更硬：段位規則裡**第 4 名扣最多**（鑽石以上 −30／−40）
      ⇒「4 位幾次」直接就是「我為什麼掉分」的答案。
    ⚠ **四個鍵一律都在**（沒拿過第 3 名就是 `"3": 0`）——
      少一個鍵的話前端得寫 `?? 0`，那是第二份預設值。

  · **`min_games` = 5（樣本數門檻）**。目前只有**名次分布的百分比**在用
    （勝率停用中，見上）；M4 把勝率接回來時要用**同一個**，不要另挑數字。
    🔴 為什麼要門檻：天鳳／雀魂／Chess.com Insights 全都有 ——
      「100% · 3 場」不是成績是噪音。
    ✅ **門檻在後端不在前端** —— 放前端的話它會變成第二份規則，
      而下一個加百分比的地方一定會忘記套。門檻值一併回傳，
      前端才講得出「再 N 場看比率」而不用自己寫死一個 5。
    ⚠ 判斷要用 `== null` **不是** `!x` —— **0% 是一個真的成績**（全輸），
      `!0` 會把它誤判成未達門檻。
    ⚠ 名次分布的**次數**不套門檻：次數在任何場數下都是事實，只有百分比要。

  · **`opp_rating` / `opp_rank`（本季對手平均段位）**
    🎯 **校正用的**：平均順位 2.1 在「對手都是銅牌」與「對手都是大師」
      之下意義完全不同 —— 少了它就分不出「我很強」與「我遇到的人很弱」。
    ⚠ 取對手**當時的** `rating_after`，**不是**他們現在的 `members.rating`
      —— 後者會一直漂，今天算出來的數字下週就變了，而那一季的事實不該變。
    ⚠ 不含自己（驗證段有正對照：把自己算進去會從 50 變成 137）。

  · **`best_rank`（最高全國排名，`all` 底下）** ★ 2026-09-03
    ```
    best_rank = min(season_standings 各季名次, 本季目前名次)
    ```
    🎯 **含「本季目前」是刻意的** —— 只看已結算賽季的話，正在第 1 名的人
      會看到 `—`，而「最高」問的是「你到過最好的位置」。
    ⚠ 測試帳號回 **null**（不列入榜單），所以今天每個人都是 null ——
      **那是對的不是壞了**。

  · **足跡四項（`all` 底下）**：`minutes`（累積分鐘）、
    `peak_rating` ＋ `peak_rank`（生涯最高）、`stores`、`opponents`。
    🎯 **不需要 `peak_rating` 欄位** —— `session_players.rating_after`
      每一場都記著，`max()` 就是生涯最高。
    ⚠ `opponents` 用 `count(distinct member_id)`：同一個人打十次還是一個人
      （驗證段有正對照：`count(*)` 的寫法會得到 4 而不是 2）。
    ⚠ 沒打過的人：`minutes/stores/opponents` 是 **0**（真的是零），
      但 **`peak_rating` 是 null**（「還沒有最高」不是「最高是 0 分」）。
    📌 個人檔案「我的麻將足跡」六格讀它 ——
      生涯場數・累積時數・造訪門市／交手過的人・生涯最高・最長連勝（M4，`—`）。
  成績頁的 KPI 四格（平均順位／全國排名）與各積分級距勝率，
  以及「查看歷史累積數據」那個切換 —— **本季與歷史一次回兩份**。

  🎯 **勝 ＝ `session_players.score_points > 0`（桌上積分為正）**
    🔴 **不是 `rating`／MIGI 段位積分** —— 拿 rating 判斷會變成
      「只要沒掉段就算贏」，意思完全不同。
    ⚠ `> 0` 不是 `>= 0`，剛好打平不算贏。期望值約 50% 不是四人桌的 25%。
  ⚠ **本季用 `rating_window_start_tx(org)`**，不要再寫第二份「本季」。
    它回 null（一季都沒建）時本季＝全部，兩份會一樣。
  ⚠ `stakes` **只回打過的**，長度隨人而異，而且本季與歷史的長度**不一樣**
    （本季沒打過但以前打過的只出現在 `all`）。
  🔴 **`all` 刻意沒有 `national_rank`** —— `rating` 每季歸零（換季降 2 個段位），
    「歷代總排名」在這個制度下沒有意義。前端那一格改放「打了幾場」。
  🔴 **全國排名的母體 = 本季打過至少一場已結算牌局 ＋ `is_test = false`。**
    不能拿全部會員排：`members.rating` 是 `NOT NULL DEFAULT 0`，
    沒打過的人也有 0 分，那樣分母會變成「開過帳號的人數」。
    ⚠ 所以**測試帳號自己永遠回 null**，而今天所有帳號都是測試帳號
      ⇒ 這一格現在一定是 `—`。**那是對的不是壞了。**
  🔴 **胡牌率／放槍率／自摸率不在這裡，而且今天做不出來**：
    2026-09-03 掃過 `information_schema.tables`，符合
    `hand|round|tile|replay|discard|win|record` 的表**一張都沒有** ——
    不是「還沒排到」是**沒有任何來源**。要等 **M4 的 L0 電子計分**
    （`hands`：誰胡／誰放槍／自摸／台數／連莊）—— **不用等牌譜辨識**。
    🔴 M 編號以 `里程碑總路線圖.md` 為準：**M4 ＝ 段位機制 ＋ 牌譜辨識**，
      **M5 ＝ 連鎖化**，跟牌譜無關。
    ⚠ **自摸率比另外兩個更深**：胡牌率只要知道「誰胡了」，
      自摸率還要知道「**怎麼胡的**」（自摸／放槍／詐胡）——
      **電子計分即使上線也給不出來**，一定要牌譜。
  📌 前端那一區（2026-09-03 定版）：
    · **本季 8 格**：打了幾場・平均順位・全國排名・**對手平均段位**・
      勝率(—)・胡牌率(—)・放槍率(—)・自摸率(—)
    · **歷史 8 格**：**生涯場數**・平均順位 ＋ 三組「率／次數」成對
      （胡牌率＋胡牌次數同一列，一列一個主題）
    兩份底下都再接**名次分布**與**各積分級距勝率**。
    ⚠ 歷史那份叫「生涯場數」不叫「打了幾場」—— 同一個標籤在兩個時間範圍
      出現，客人切過去會以為數字沒更新。
    ⚠ 順序刻意把**有數字的排前面** —— 幾個「率」排最上面的話整塊看起來像壞了。
  ⚠ **為什麼不讓前端拿 `get_my_games_tx` 自己加總**：那支有 `p_limit`，
    前 N 筆的平均不是本季平均，**而且畫面上看不出來**（同待辦 1 的累積消費）。
set_my_nickname_tx / set_my_avatar_tx / set_my_title_tx / set_my_about_tx
set_my_sched_tx / set_my_style_tx / set_my_baby_tile_tx / set_my_see_score_tx
set_my_home_store_tx / set_my_birthday_tx / set_my_availability_tx / get_my_availability_tx
set_avatar_tx / admin_remove_avatar_tx / save_app_state_tx / mark_app_active_tx
set_invoice_pref_tx / list_members_tx

set_my_profile_basics_tx(p_org_id, p_member_id, p_birthday date = null, p_gender text = null)
  DEFINER · anon ✅ · 2026-08-28 新增
  ⚠ **null = 不動那一欄**（不是清空）—— 註冊時生日與性別可以分開補
  ⚠ 性別在函式裡驗（回 `gender_invalid`），不是丟給 CHECK 拋 23514
```

### 🔴 身分與簡訊驗證（2026-08-30 · **全部只給 service_role**）

```
otp_request_tx(p_org_id, p_phone, p_purpose, p_line_user_id)      → 產碼 ＋ 三道限流
otp_verify_tx(p_org_id, p_phone, p_code, p_purpose)               → 驗碼（5 次上限）
phone_recently_verified_tx(p_org_id, p_phone, p_line_user_id, p_purpose) → 15 分鐘內驗過？
otp_consume_tx(p_org_id, p_phone, p_line_user_id, p_purpose, p_member_id) → 用掉 ＋ 蓋章
claim_member_by_phone_tx(p_org_id, p_phone, p_line_user_id, p_purpose='register')
set_member_phone_tx(p_org_id, p_line_user_id, p_phone)
get_member_by_line_tx(p_org_id, p_line_user_id)                   → whoami（手機遮罩）
phone_in_use_tx(p_org_id, p_phone, p_line_user_id)                → ⏳ 目前沒有人呼叫
register_member_tx(...)                                           → 🔴 2026-08-30 收回 anon
```

🔴 **這九支一律 `只給 service_role`，前端一個都叫不動。**
  它們每一支不是「改你是誰」就是「決定要不要把一個帳號交給你」——
  唯一的入口是 Edge Function `line-login`（驗過 LINE 簽章之後才碰得到）。
  ⚠ 收的時候**兩個方向都要收**（硬規則 2.6／2.6b）：
  `revoke from public`（舊函式的 PUBLIC 繼承）＋
  `revoke from anon`（新函式的 default privileges 明確授權）。

🔴 **`get_my_profile_tx` 回的是完整手機，不是遮罩**（2026-08-30 下午改回來）。
  它一度做成 `phone_masked`（`0910***736`），當天就換掉 ——
  遮罩答不出「**這是我的哪一支**」，而那是個人設定顯示它的唯一用途。
  ⚠ 代價：這支是 **anon ＋ 前端送 `p_member_id`** ⇒ 知道某人的 member uuid
    就查得到他的手機。**已知並接受的取捨**（它本來就已經回生日與性別了），
    待辦 14 改吃 `auth.uid()` 之後歸零。
  ⚠ **`get_member_by_line_tx`（whoami）仍然是遮罩的** —— 那條路上沒有畫面
    在讀它。兩支的行為不同是刻意的，不是漏改。

📌 **`phone_in_use_tx` 現在沒有任何呼叫端。**
  它原本給註冊第 2 步「邊打邊查這支號碼有人用嗎」，
  2026-08-30 整個拿掉 —— 那個訊息是死路（**真正的號碼主人也被擋在門外**），
  而且它本身是一個「有 LINE 就能一直問某支號碼是不是會員」的查詢器。
  ⚠ 先留著不刪：它是**唯一**「不會順手建立帳號」的手機查詢，
  日後 POS 幫客人註冊時很可能會用到。**但下次盤點死碼時要重新問一次。**

### 🆕 段位（2026-08-31）

> 🔴 **規則以《決策紀錄》第二十三節為準。** 這一段只寫「資料庫裡實際是什麼」。
> ⚠ 2026-08-31 當天做過兩版：先是我憑對 LOL 的印象做的 Elo 版（已作廢），
>   當天改成拍板的**分段正和**。`apply_session_results_tx` 已刪除。

```
apply_session_rounds_tx(p_session_id, p_rounds)     🔴 只給 service_role
  p_rounds = [ [ {"member_id":"…","finish_rank":1}, …四人 ], …一將一個陣列 ]
  一將一將依序套用 → 寫 finish_rank/score_points/rating_after → 更新 rating/rank
  🎓 **人生第一場走 `placement` band**（2026-09-01）：+30/+15/+10/+5，不會扣分
     ⚠ 判準：`not exists (有別的 session 的 finish_rank)`，**不是 `rating_games = 0`**
       · `rating_games` 每季歸零 ⇒ 會變成每季送一次
       · 它逐將遞增 ⇒ 同一場的第 2 將就不算了，承諾只兌現一半
     ⚠ `finish_rank` 是整場收尾才寫的 ⇒ 判斷不會被這一場自己汙染
  🛡 銅／銀／金夾在**大階**下限（會掉小階、不會掉大階）
  ⚠ 未滿 2 將 → too_few_rounds　｜　不是四人 → need_four_players
  ⚠ 冪等：任一人已有 finish_rank → already_applied（重按不會再扣一次分）
  ⚠ 名次必須剛好是 1..n（不接受並列、不接受跳號）
reset_season_ratings_tx(org, season, drop_tiers=2)  🔴 只給 service_role
  先記冠軍 → 所有人降 2 大階 → 夾在下限 0　｜　同一季只能結一次
  🔴 **2026-09-01 起不能再寫死 360** —— 那個寫法能成立是因為六個大階以前都 180 寬，
     現在銅牌是 145。改成 **`目前大階的 min − 往下 N 階的 min`**，依他當下的段位算。
     ```
     鑽石 I 820 → 685−325=360 → 460 = 金牌 I     ✅ 真的降兩階
     銀牌 IV 145 → 只剩一階可降 → 145−0=145 → 0   ✅ 夾在下限
     ```
  ✅ 2026-09-01：季別不在 rank_seasons → season_not_found
     （在此之前 p_season 是**呼叫端隨手打的字串**，打錯不會有人知道）
member_opponents_tx(member_id) → int  🔴 anon 與 PUBLIC 都收掉，只給 service_role
  🆕 2026-09-02。**「本季不同對手數」全系統唯一的一份定義。**
  🔴 在此之前那段查詢**只寫在 `member_rank_tx` 裡**，而 Hero 也要同一個數字
    ⇒ 複製一份就是兩份「本季」的定義（而它 9/1 才剛從「最近 50 場」改成「本季」）。
  ✅ 2026-09-01 視窗＝「**上次歸零之後**」（＝本季）
  ⚠ 過濾的是**我那一列**的 settled_at，不是對手那一列的
  🔴 它**自己會退化**，這是刻意的：
     有當季 → 當季開始｜沒當季但有過去的季 → 最後一季 ends_at｜一季都沒有 → 退回最近 50 場
     寫死「本季，沒有就不給大師」會在忘記建下一季時**靜靜把大師降成鑽石**
  ⚠ 那個 fallback 的 `limit 50` 是**視窗大小**，跟門檻 `min_opponents`
    **是兩件事**，數字剛好一樣是巧合。

member_rank_tx(member_id) → text  anon ✅  含大師的對手多樣性判斷
  ✅ 2026-09-02 起只問 `member_opponents_tx` 的結果，不自己查
get_my_rank_tx(org, member) → jsonb anon ✅  成績頁 Hero 用（含大師的對手多樣性）
  ✅ 2026-09-01 多回 `season`（code/label/starts_at/ends_at/days_left），
     **未定位的人也有** —— 那顆膠囊跟他有沒有段位無關
  ✅ **2026-09-02 多回 `opponents` / `opponents_need`，但只在鑽石熊 I 以上**。
     🎯 在爬到那裡之前，大師熊的條件完全不影響他 ——
       提早顯示只是一個看不懂而且令人焦慮的數字（「不同對手 0 / 50」）。
     ⚠ 門檻是**算出來的**（最高 auto 階 ＋ 它最後一個小級的位移 = 820），
       **不要寫死** —— 那個數字 9/1 才因為銅牌熊調整而從 815 變過一次。
     ⚠ 前端靠「這兩個鍵在不在」決定顯不顯示，**不自己判斷段位**
  ⚠ 沒有涵蓋現在的季別時 `season` 是 **null**，前端就不畫膠囊。
     **不要退回上一季** —— 客人沒有辦法知道那一季已經結束了
current_season_tx(org)        → jsonb 🔴 anon 與 PUBLIC 都收掉，只給 service_role
rating_window_start_tx(org)   → timestamptz 🔴 同上
  ⚠ 兩支都只被 DEFINER 函式從內部呼叫（呼叫端權限不會被檢查，所以不用授權）
rank_detail_tx(rating)    → jsonb anon ✅
  小級：rank / tier / sub / band / tier_min / progress / to_next / at_top
  大階：next_tier / to_next_tier / tier_progress   ← Hero 的進度條用這一組
rank_from_rating(rating)  → text  anon ✅  只是取 rank_detail_tx 的 rank
```

🔴 **名次只給 service_role**：那是店員登記的**事實**，不是客人可以宣告的。
  讓前端叫得動就等於「自己填自己第一名」（同待辦 40 的稱號那個病）。
  ⏳ 店員登入（待辦 20）做好之後 POS 包一層 DEFINER 呼叫；
  名次的最終來源是**電子計分**（決策紀錄二十四）。

### 🔴 兩條容易搞混的降階規則

| | 銅／銀／金 | 白金以上 |
|---|---|---|
| **賽季中** | 🛡 **不掉階**（扣分後夾在當前階的下限） | ✅ 會掉 |
| **賽季末** | ✅ **降 2 大階** | ✅ 降 2 大階 |

🎯 **賽季中的保護不需要 `peak_rating`** —— 規則是「不掉階」的話，
  當前分數本身就記著他到過哪一階（因為他掉不出去），夾在當前階下限即可自我維持。
⚠ **階內仍然可以降小級**（I→II→III→IV）。
⚠ **band 會在一場之內重算** —— 白金掉到金牌之後，下一將吃的是低段的 −20 不是 −30。
⚠ **大階寬度從主檔算，不要寫死 180** —— 每階 45 一定會調。

### 🎯 小級與大階是兩組數字，不要混用

| | 用在哪 |
|---|---|
| **小級**（`progress` / `to_next`） | 標題的「金牌熊 **II**」—— 動得比較頻繁，細顆粒回饋 |
| **大階**（`tier_progress` / `to_next_tier`） | **成績頁 Hero 的進度條與副標** |

🔴 **進度條一定要用大階**：獎勵是小熊，而**小熊只在大階換** ——
  進度條填滿卻什麼都沒發生，是最糟的一種回饋。
⚠ **進度條與副標必須同一個維度**，一個講小級一個講大階的話，
  條滿了字還說「還差 90 分」，那看起來就是壞的。
⚠ `next_tier` **要看全部的階**（含 `auto=false` 的大師熊）——
  客人爬到鑽石 I 之後仍然要看得到「大師熊」這個目標。

### 🎯 認領的分級（`claim_member_by_phone_tx`）

| 舊帳號的狀態 | 自助 | 回傳 |
|---|---|---|
| 已經綁在**你自己**的 LINE 上 | ✅ | `already_yours`（**排在驗證檢查之前** —— 見下） |
| 手機**驗過** | ✅ | `claimed` |
| 未驗 ＋ 沒訂單也沒餘額 | ✅ | `claimed` |
| 未驗 ＋ **有訂單或有餘額** | 🔴 | `staff_required` |
| 已綁**別的** LINE | 🔴 | `line_bound_elsewhere` |
| 你的 LINE 已經有別的會員 | 🔴 | `merge_required` |

🔴 **`already_yours` 與 `unchanged` 必須排在驗證檢查之前。**
  驗證碼**用過一次就消耗**，排在後面的話雙擊的第二次會拿到 `not_verified`
  —— 客人看到「成功的那一次顯示失敗」。
  **冪等不可以依賴一個會被用掉的東西。**
  ⚠ 那不是洩漏：它只認得出「這個帳號已經綁在你自己的 LINE 上」，
  而 `whoami` 開機時早就告訴他了。

✅ ~~沒有「改手機」的 RPC~~ → **`set_member_phone_tx` 已於 2026-08-30 建立**
  （待辦 36 的 D2）。舊號碼是什麼**不重要** —— 你證明的是「我控制這支新號碼」。
  驗不了（手機已經不在手上）才要找店員。

### POS 專用

```
pos_member_detail_tx / pos_search_members_tx / pos_add_member_note_tx
list_products_tx / list_fee_menu_tx / list_daypass_tx / list_stakes_tx / list_stake_levels_tx
list_stores_tx / get_store_detail_tx / get_order_tx
```

### 總部後台專用（★ 2026-09-08 新增四支）

```
admin_list_products_tx()                        STABLE   · authenticated ✅ anon ❌
admin_upsert_product_tx(p_id, p_sku, p_name, p_category, p_subcategory,
                        p_revenue_type, p_tracks_stock, p_unit_price,
                        p_unit_cost, p_stock_qty, p_is_active, p_is_available,
                        p_spec default null)          ★ 2026-09-10 加第 13 個參數
admin_set_product_active_tx(p_id, p_is_active)
admin_delete_product_tx(p_id)
admin_remove_avatar_tx(p_member_id, p_reason, p_block)   （既有）
```

🔴 **四支都帶 `can('product.write')`，而且 org 與操作者都不由呼叫端宣告**
（`current_org_id()` / `current_staff()`）。收 `p_staff_id` 的話，
登入的人可以填別人的 id —— **那比沒有稽核更糟**（它看起來有，而且指向錯的人）。

🎯 **這一批換到的是兩件看不到的事**：
- **稽核**：`created_by` / `updated_by` 由後端寫。在此之前 **9 筆商品全是 null**，
  改價格完全沒有紀錄，而且**不可回溯**。
- **`is_system` 保護**：在此之前那道牆**只存在於 `Products.jsx` 的一個 `if`**，
  資料庫端沒有觸發器也沒有約束。停用系統商品會讓開桌回 `product_not_found`，
  而**那個錯誤訊息不會指向後台**。
  ⇒ 系統商品：不可停用、不可刪除、不可改貨號；**品名與價格可以改**（調檯費是正當的）。

🔴 **`p_spec` 放在參數列最後而且給預設值，那兩件事都是刻意的**（2026-09-10）：
Postgres 要求有預設值的參數排在後面，而這樣也順便是 **expand-safe** ——
**那份 SQL 可以在前端部署之前先跑**，舊的前端不送它照樣能用。
⚠ 加參數 ＝ **改簽名** ⇒ 要 `DROP` ＋ 重建 ⇒ **GRANT 會被一起丟掉**（硬規則 2）。
那份檔案結尾補回 `authenticated, service_role`，驗證段第 ⑦ 格專門盯這件事：
**只驗「函式在」的話，一支沒人叫得動的函式也會讓其他格變綠，而後台會當場壞掉。**

⚠ **`admin_list_products_tx` 不是 `list_products_tx`** —— 後者是 **POS** 的清單：
濾掉停用與 `is_available`、排除 `SVC-TBL-%`。
兩個需求不同，所以是兩支，**不要加參數把它變成兩用**。
📌 **`list_products_tx` 2026-09-10 從 7 個鍵變 9 個**（`CREATE OR REPLACE`，簽名沒變）：
加了 **`spec`**（商品卡與購物車那一行）與 **`subcategory`**（結帳頁的商品分頁讀它）。
🔴 前端拿不到 `subcategory` 就分不了頁，而症狀是**所有商品掉進「其他」分頁**
（不報錯、點得到、也結得了帳）—— 所以那支 SQL 的驗證段有一格專門盯它。

⏳ **`products_org_write` 那條 ALL policy 還留著**（expand → migrate → contract
的中間態）。前端已切走，但要等部署驗證過才 contract。
✅ 已查證**沒有任何函式在寫 `products`**，所以日後拿掉是安全的。

### 主檔 / 身分 / 系統

```
list_member_tiers_tx()          無參數
list_product_taxonomy_tx()      無參數
list_topup_plans_tx(p_org_id, p_store_id)
current_org_id() / current_member_id() / current_staff()
migi_jwt_uuid()          STABLE · authenticated ✅ anon ❌ · 2026-09-04 新增
migi_jwt_line_id()       STABLE · authenticated ✅ anon ❌ · 2026-09-04 新增
  「這個 JWT 代表哪一個 LINE 帳號」。與 `migi_jwt_uuid()` 是**一對**，
  合起來就是**身分解析那一層** —— 三支身分函式都只透過它們讀 JWT。
  ① `app_metadata.line_user_id`（走 Supabase Auth 之後的形狀）
  ② `sub` 不是 uuid ⇒ 它本身就是 LINE id（今天的形狀）
  🔴 **一定要 `app_metadata` 不可以是 `user_metadata`** ——
    後者**客戶端自己就能改**（`supabase.auth.updateUser({ data: … })`），
    讀它等於「輸入任何 line_user_id 就能變成他」。
    ⚠ 兩者在 JWT 裡長得幾乎一樣，**而其中一個是完整的身分偽造**。
  ⚠ 用「不是 uuid」判斷而不是比對 `^U…` 的格式 ——
    格式寫死會在 LINE 改格式那天壞掉，而症狀是**所有人都登不進去**。
  🎯 為什麼現在就包：查出 Supabase 用 **ES256（非對稱）**
    ⇒ Edge Function 不能自簽 JWT ⇒ 只能走 Supabase Auth
    ⇒ **`sub` 一定會變成 uuid**。包了之後那個變動只要改這一支。
can(p_perm text)         DEFINER · authenticated ✅ anon ❌ · 2026-09-04 新增
has_store_access(p_store_id)   DEFINER · authenticated ✅ anon ❌
  🔴 2026-09-04 修：原本是 `cs.role = 'hq'`，**漏掉了 `owner`**
    （`staff_role_check` 允許 floor/manager/hq/owner）
    ⇒ 一個 role='owner'、store_id=null 的老闆**什麼店都進不去**。
  ✅ 修法不是「把 owner 也加進去」（那會是**第三份**「誰是最高權限」的定義），
    而是改呼叫 `can('store.all')` —— 從此只有一份。
  ⚠ 這條 **0 個 policy 在用**，所以改它零風險 ——
    **但那也正是它能錯這麼久沒被發現的原因。**
get_staff_by_line_tx(p_org_id, p_line_user_id)
  DEFINER · **只有 service_role**（anon/PUBLIC/authenticated 全收）· 2026-09-04 新增
  給 Edge Function 問「這個 LINE 是哪位店員」，形狀比照 `get_member_by_line_tx`。
  🔴 **不可以用 `current_staff()` 代替** —— 那支讀 `auth.jwt()`，
    而 Edge Function 手上只有驗過簽的 `sub`，沒有 JWT context。
  ⚠ 刻意**不回傳 `auth_uid`** —— 那是另一條登入路徑（Email）的憑據。
  🎯 授權收得夠緊的實證：用 MCP（`supabase_read_only_user`）呼叫它會拿到
    `permission denied` —— **連唯讀的 DB user 都叫不動**。
grant_staff_tx(p_member_id, p_store_id, p_role, p_name) / revoke_staff_tx(p_staff_id)
  🔴 **2026-09-05 加了 `p_name`，而且它是必填的**（不給回 `name_required`）。
    在此之前這支拿 `members.display_name`（LINE 暱稱）當預設值填進 `staff.name`
    ⇒ **POS 側邊欄顯示的是客人看到的暱稱，不是員工的真實姓名**。
  🔴 而且舊版是 `name = coalesce(name, v_name)`（已經有名字就不改）
    ⇒ **「改名」這個動作在這支函式裡做不到**。現在直接用傳進來的值。
  ⚠ **不給預設值是刻意的** —— 「店員叫什麼」不該有一個猜出來的答案。
list_staff_tx(p_org_id)   ← 2026-09-05 新增，`can('ops.read')`
  🎯 **存在的唯一理由是 `last_sign_in_at`** —— 它在 `auth.users`，
    不在 `public` schema，所以前端查不到。
    而那一欄是**抓殭屍帳號**（離職半年沒人記得收回）唯一會露馬腳的地方。
  📌 其餘欄位 migi-admin 本來就查得到（它有 Email Auth ＋ hq 身分）。
next_doc_no(p_org_id, p_store_id, p_doc_type)
log_app_event_tx(p_org_id, p_member_id, p_event, p_props, p_client_ts, p_store_id)
dev_reset_test_data_tx(p_reset_balance) / dev_set_test_balance_tx(p_display_name, p_balance)
migi_norm_nickname(p text)
migi_norm_phone(p text)   INVOKER · anon ✅ · 2026-08-28 新增
  去掉所有非數字 → `+886`／`886` 開頭補回 `0` → 必須符合 `^09\d{8}$`，否則回 null
  ⚠ **`register_member_tx` 在「查詢之前」與「寫入之前」都會正規化** ——
    所以客人填 `0912-345-678` 找得到用 `0912345678` 註冊的舊帳號。
    那正是情境 C（換 LINE 帳號）唯一的橋。
```

### 發票

```
create_invoice_draft_tx(p_order_id, p_idempotency_key)
mark_invoice_issued_tx(...) / mark_invoice_failed_tx(...) / void_invoice_tx(...)
```
🔴 全部存在但 **POS 原始碼裡 `invoice` 一次都沒出現**，`invoices` 表 0 筆（待辦 13）。

### 觸發器函式（不要直接呼叫）

```
set_updated_at / prevent_org_change / create_wallet_for_member / set_is_test_from_store
trg_orders_set_no / trg_topup_set_no / trg_coupon_set_code
trg_members_norm_display_name / trg_orders_touch_member_visit
app_events_no_mutate / payments_no_mutate / block_txn_mutation
```
