# 這台電腦的 Git 多帳號設定（已完成，供日後查閱與擴充）

> 這是什麼：說明為什麼這台 Windows 機器上 git 的身分會隨資料夾自動切換。
> 什麼時候讀：commit 掛錯帳號、clone private repo 認證失敗、
> 或要再加第三個 GitHub 帳號的時候。
> 狀態：2026-08-14 設定完成並驗證通過。

## 背景

同一台電腦有兩個不相干的 GitHub 帳號：

| 用途 | GitHub 帳號 | 本機資料夾 |
| --- | --- | --- |
| 樂活眼鏡 | （既有帳號） | `C:\Users\user\Desktop\lohas github\` |
| MIGI | `migi-hq` | `C:\Users\user\Desktop\migi github\` |

兩個都在 `github.com` 網域下，而 Windows 的 Git Credential Manager (GCM)
預設「一個網域只記一組憑證」，所以需要額外設定才能並存。

---

## 已套用的設定

### 一、認證：憑證按 repo 路徑分開存

```
git config --global credential.https://github.com.useHttpPath true
```

憑證的 key 從 `git:https://github.com` 變成
`git:https://github.com/migi-hq/migi-pos` 這種帶路徑的形式，
兩個帳號的憑證因此不會互相覆蓋。

**代價**：每一個新 repo 第一次 clone 都要重新授權一次（GCM 會彈登入視窗）。
這是隔離本身的性質，不是設定錯誤。

### 二、commit 署名：按資料夾自動切換

`C:\Users\user\.gitconfig`（全域）末尾加了：

```
[includeIf "gitdir:C:/Users/user/Desktop/migi github/"]
    path = C:/Users/user/.gitconfig-migi
```

`C:\Users\user\.gitconfig-migi`：

```
[user]
    name = MIGI
    email = admin@migi.tw
```

路徑必須用**正斜線**，且**結尾一定要有斜線**，漏掉會靜默失效。

---

## 目前的解析結果

git 決定 commit 作者時，後讀到的會蓋掉先讀到的：

1. 全域 `.gitconfig` → Jim Huang / lohas.jimhuang@gmail.com
2. `.gitconfig-migi` → 只在 `migi github` 資料夾底下才被讀入

因此：

- 在 `migi github\` 底下 commit → 署名 **MIGI**
- 在其他任何位置 commit → 署名 **Jim Huang**（全域預設）

> **這是「位置決定身分」，不是「repo 決定身分」。**
> 把 MIGI 的 repo clone 到桌面或其他地方，commit 會靜默掛回 Jim Huang，
> 沒有任何警告。MIGI 的東西一律放在 `migi github\` 底下。

---

## 已知的陷阱

- **全域那組是歷史遺留**，不是刻意選的——這台第一個 git 專案是樂活，
  當時直接設了 `--global`，於是「沒被規則命中的地方一律算樂活」。
  想更嚴謹的話，可以給樂活也加一條 `includeIf`，讓全域留白當作
  「未分類」的標記。目前不影響運作，屬於優化項。
- **email 一定要綁在該 GitHub 帳號上**，否則 commit 不會連到帳號、
  貢獻圖也不算。`migi-hq` 帳號可用的有 `admin@migi.tw`（Primary、已驗證）
  與 noreply 位址 `295379977+migi-hq@users.noreply.github.com`。
- **憑證亂掉的處理方式**：控制台 → 認證管理員 → Windows 認證，
  找 `git:https://github.com` 開頭的項目刪掉，下次操作會重新詢問。

---

## 如果帳號數量長大（4 個以上）

現在這套規則是一條 `includeIf` 對一個絕對路徑，帳號多了會變成
一堆規則加一堆 `.gitconfig-xxx`，而且路徑一改就靜默失效。

到那個規模建議整組換掉：

1. **收斂目錄**：改成 `C:\code\<帳號>\<repo>` 的兩層結構，
   `includeIf` 就能用萬用字元一條蓋掉整個帳號，不用逐一新增。
2. **認證改用 SSH**：每個帳號一把金鑰，`~/.ssh/config` 設 Host 別名
   （`github-migi`、`github-lohas`…），remote 寫成
   `git@github-migi:migi-hq/migi-pos.git`。設定一次之後永不再授權，
   也不會有拿錯帳號憑證的問題。

不用現在做——等實際的使用模式浮現再一次性重整比較划算。
