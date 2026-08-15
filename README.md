# migi-docs

MIGI 麻將連鎖的**文件與資料庫變更**版控庫。

程式碼不在這裡 —— 三端各自獨立：
[migi-pos](https://github.com/migi-hq/migi-pos)（店員端）・
[migi-web](https://github.com/migi-hq/migi-web)（會員端 App）・
[migi-admin](https://github.com/migi-hq/migi-admin)（後台）。

## 為什麼文件單獨一個 repo

這裡放的都是**跨三端的東西** —— 同一個 Supabase 資料庫、同一套色彩 token、
同一份決策紀錄。塞進任何一個程式 repo，另外兩端就看不到。

只描述單一端的文件（元件、路由）應該放回該 repo 的 `docs/`，跟程式碼同一個 PR 改，才不會漂移。

## 內容

```
CLAUDE.md      ← 最重要的一份。硬規則 + 目前進度，Claude Code 每個 session 自動載入
docs/          ← 權威文件，分十類。先讀 docs/00-進度與索引/索引.md
sql/           ← 所有 Supabase SQL
  applied/     ← 已在 Dashboard 執行過
  pending/     ← 寫好還沒跑
  checks/      ← 唯讀盤點查詢，不是 migration
  tools/       ← 維運用工具查詢
  _設計稿未落地/ ← 寫過但實作方式後來改掉，僅供參考，不可當成已執行
_inbox/        ← 2026-08-14 整合前的原始檔封存，不要當成有效文件來讀
```

## 動手前

1. **`CLAUDE.md` 的硬規則不是建議，是踩過才寫下來的。**
2. **`docs/01-資料庫/db-現況快照.md` 是資料庫的事實層**，動 schema 前先讀。
3. **`sql/applied/` 不是線上現況的鏡像** —— 那是「當時交付的版本」，之後可能又改過。
   改既有函式一律先 `pg_get_functiondef` 撈線上版。

## SQL 的執行方式

**一律從 Supabase Dashboard 的 SQL Editor 手動執行**，不用 CLI、不做本機部署。

這是刻意的取捨：目前規模不值得架自動 migration pipeline。
代價是**這個 repo 不保證等於資料庫的實際狀態**，只是「我們記得跑過什麼」的紀錄。
接金流或開第二家店之後值得重新評估。
