/* ============================================================
   創辦人的會員帳號標記為測試（驗收期間）
   2026-08-29

   ── 背景 ────────────────────────────────────────────
   2026-08-29 06:02 用 LINE 走完第一次真實註冊，建立了第五個會員：
   ```
   Jim  0910768736  line_user_id=U368caa174ee…  1985-06-12  male
   is_test = false          ← register_member_tx 的預設值
   ```
   ✅ 這個帳號是**乾淨的**（沒有沿用測試01 的 70 筆訂單與 3,580 點），
     那是刻意的 —— 見 CLAUDE.md PENDING 的「創辦人的會員帳號」。

   ── 🔴 為什麼現在就要設 true ────────────────────────
   `orgs.live_from` 目前是 **null**，所以今天唯一的擋牆就是 `is_test`。
   而它有一個決定性的不對稱：

   | 資料 | 什麼時候判斷 is_test | 之後翻旗標 |
   |---|---|---|
   | `orders` / `wallet_txns` / `table_sessions` / `topup_orders`… | **查詢時**由 `v_real_*` 去 join `members` | ✅ **回溯生效**，隨時可翻 |
   | **`app_events`（埋點）** | **寫入時就蓋章**（`log_app_event_tx` 從 members 推） | 🔴 **改不掉** |

   🔴 `app_events` 有 `trg_app_events_no_mutate`，**UPDATE 與 DELETE 都擋**。
     → 驗收期間每一次點擊都會被**永久**蓋章成「真實客人」，
       而那正是資料庫裡那 2847 筆的成因（CLAUDE.md 已記）。

   → **現在設 true 的成本是零**（訂單那邊回溯，隨時翻得回來），
     **不設的成本是不可逆的**。

   ── ⏳ 什麼時候翻回 false ──────────────────────────
   **設 `orgs.live_from` 的那一天** —— 那是同一個動作的兩半。
   ⚠ 那時要順便決定一個會計問題：
     **老闆自己打牌的消費要不要進營收報表？**
     他若常免費打，那些資料會扭曲客單價與場地費營收。
     → 若答案是「不要」，那就**永遠留 true**，而不是翻。

   ⚠ 只改 `is_test`，**不動 `live_from`** —— 上線日還沒定，
     現在填一個假的比空著更糟（報表會以為它是真的）。
   ============================================================ */

update members
   set is_test = true, updated_at = now()
 where id = '69016205-afde-4036-95a6-5893c9d0e5fe';


/* ============================================================
   驗證（單一 SELECT）

   ① 這個帳號現在是測試
   ② 🎯 正對照：`v_real_members` 看不到他，但**看得到其他人**
      —— 只驗「他被擋掉」是不夠的；把 view 寫壞也會讓他消失，
        而那個症狀跟正確阻擋長得一模一樣（硬規則 3.55）。
        ⚠ 四個測試帳號本來就被擋，所以這一格的預期是
          **v_real_members 一個人都沒有** —— 那是對的，
          因為**今天資料庫裡確實沒有任何真實客人**。
        → 所以正對照要換一個問法：**直接數原表**，
          證明人還在、只是被 view 擋住。
   ③ 🔴 已經來不及的部分：他在標記之前產生的 app_events
      —— 那些蓋章蓋成 is_test=false 而且改不掉。列出來讓人看見損失。
   ============================================================ */
select 序, 項目, 內容 from (

  select 1 as 序, '① 創辦人帳號的測試標記' as 項目,
         (select display_name || '　is_test=' ||
                 case when is_test then '✅ true（驗收期間不進報表）'
                      else '🔴 false —— 沒改到' end
            from members where id = '69016205-afde-4036-95a6-5893c9d0e5fe') as 內容

  union all
  select 2, '② 🎯 正對照：原表有人、v_real_members 擋住幾個',
         (select '原表 ' || (select count(*)::text from members where deleted_at is null)
              || ' 人　v_real_members ' || (select count(*)::text from v_real_members) || ' 人'
              || case when (select count(*) from v_real_members) = 0
                        and (select count(*) from members where deleted_at is null) = 5
                      then E'\n  ✅ 五個人都在原表，report 一個都看不到 —— 正確'
                      else E'\n  ⚠ 數字不如預期，先確認 v_real_members 的定義' end)

  union all
  select 3, '③ 🔴 已經來不及的：標記前產生的埋點（改不掉）',
         coalesce((select '共 ' || count(*)::text || ' 筆　is_test=false ' ||
                          count(*) filter (where not is_test)::text || ' 筆'
                     from app_events
                    where member_id = (select id from members
                                        where id = '69016205-afde-4036-95a6-5893c9d0e5fe')),
                  '（一筆都沒有 —— 趕上了）')

  union all
  select 4, '④ orgs.live_from（刻意不動，上線日還沒定）',
         (select coalesce(live_from::text, 'null　⏳ 上線時才設，那天同時決定要不要把 is_test 翻回 false')
            from orgs where id = '11111111-1111-1111-1111-111111111111')

) x order by 序;
