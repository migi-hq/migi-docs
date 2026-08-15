# 資料模型與 RPC 總覽（會員 App 端）

**【這是什麼】** MA 系列新增的表、欄位、RPC 的一頁式索引，含與 M0/M1 既有結構的關係。
**【何時讀】** 要串接前端、寫新 RPC、或搞不清楚某支函式在哪個檔案時。

---

## 分層概念（最重要的一張圖）

```
會員 App 端                        POS / 營運端
─────────────────                  ─────────────────
match_queues      ← 等待撮合房      table_sessions   ← 已入座計費桌
match_queue_players                 session_players
        │                                   ▲
        └──── matched_session_id ───────────┘
              （線上湊齊 → 到店入座 → 店員開計費桌）
```

**鐵則：POS 與 App 所有查詢一律走 SECURITY DEFINER RPC。**
前端用 anon key 沒有 session，`current_org_id()` 回 null → 直接 `supabase.from('表').select()` 會**查詢成功但回空陣列且不報錯**，是最難察覺的失敗模式。

---

## A 塊：會員資料（已上線）

**`members` 新增欄位**
| 欄位 | 型別 | 說明 |
|---|---|---|
| `rank` | text | 段位快取，預設「銅牌熊 I」。未來由 M4 賽季 Elo 結算寫入 |
| `title` | text | 配戴中的稱號，預設「新手上路」 |
| `likes_count` | int | 累計獲讚（快取，`like_player_tx` 維護） |
| `is_test` | boolean | 測試帳號旗標 |
| `last_app_active_at` | timestamptz | 最後開 App 時間（滲透率快取） |

**新表**
- `member_likes` — 按讚明細（append-only 性質，同局同人只能讚一次）
- `member_app_state` — 養成熊進度、已解鎖稱號（jsonb 存檔，換手機不歸零）

**RPC**
| 函式 | 用途 |
|---|---|
| `get_my_profile_tx(org, member)` | 開 App 一次拉齊：段位/稱號/獲讚/頭像/熊進度 |
| `set_my_avatar_tx` | 頭像（存段位熊代號或 Storage 網址） |
| `set_my_title_tx` | 稱號（會驗證已解鎖） |
| `set_my_nickname_tx` | 暱稱（**待執行**，見「SQL-待執行」資料夾） |
| `save_app_state_tx` | 熊進度整包存；稱號採**聯集只增不減**防舊裝置覆蓋 |
| `like_player_tx` | 按讚/取消，同步維護 likes_count |
| `set/get_my_availability_tx` | 空檔時段（只動 `source='stated'`，不碰 M3 的 inferred） |

---

## B 塊：牌咖與通知（已上線）

**新表**
- `buddy_invites` — 牌咖邀請（pending/accepted/rejected，唯一索引防重複 pending）
- `app_notifications` — 通知中心資料源（type: settle/buddy_req/buddy_ok/table_req/table_ok/system）
- `mahjong_buddies`（M0 既有）— 補上 `uq_buddy_pair` 唯一索引防重複配對

**RPC**
| 函式 | 用途 |
|---|---|
| `send_buddy_invite_tx` | 發邀請＋寫對方通知 |
| `respond_buddy_invite_tx` | 接受＝寫兩筆互指＋回通知；拒絕＝僅改狀態（無痕） |
| `remove_buddy_tx` | 解除牌咖（靜默雙向軟刪） |
| `list_buddies_tx` | 我的牌咖（含段位/獲讚快照） |
| `list_recent_players_tx` | 最近 1 天同桌（**需 M2 有 session 資料才有內容**） |
| `list_notifications_tx` / `mark_notifs_read_tx` / `unread_count_tx` | 通知中心與鈴鐺紅點 |

---

## C 塊：配桌與黑名單（設計完成，未實作）

規劃中的表：`match_queues`、`match_queue_players`、`table_invites`、`member_blocks`
分析視圖：`v_member_wait_stats`、`v_member_join_hours`
詳見 `SQL-待執行/MA1C-配桌黑名單設計稿.sql`。

`match_queue_players` 的兩個行為分析欄位（不可省略）：
- `join_source`：opened / browse / invited（區分揪團核心客 vs 跟隨者）
- `leave_reason`：quit / cancelled / expired / switched
  **耐心值只能用 quit 的資料算**——被解散的人不是沒耐心，混算會污染分析。

---

## 埋點（已上線）

- `app_events`（append-only + 防刪觸發器）、`log_app_event_tx`、`mark_app_active_tx`
- 視圖 `v_app_daily_active`（已排除測試帳號）
- 事件字典見 `analytics-events.md`

---

## 前端資料層檔案對照

| 檔案 | 負責 |
|---|---|
| `src/lib/supabase.js` | client + `MIGI_ORG_ID` |
| `src/lib/profile.js` | A 塊 RPC 封裝 |
| `src/lib/social.js` | B 塊（牌咖/通知，已接後端）＋揪桌（暫 localStorage，待 C 塊） |
| `src/lib/analytics.js` | `track()` / `markAppActive()` / `APP_VERSION` |
| `src/lib/images.js` | 所有圖片 import 集中（Vite content hash 管理） |
