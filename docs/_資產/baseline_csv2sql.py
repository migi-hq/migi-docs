#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 Supabase SQL Editor 匯出的 baseline CSV 轉成一份可執行的 .sql

    python docs/_資產/baseline_csv2sql.py <下載的.csv>

── 為什麼要有這支 ──────────────────────────────────────
CLAUDE.md 硬規則 1.65 寫著 baseline 的產生方式是
「執行 → 匯出 CSV → **用 Python 轉成 .sql**」。

🔴 而 2026-09-11 要用的時候發現：**那支 Python 根本不存在。**
   2026-08-29 那次是即席寫的，用完沒有留檔。
   ⇒ 文件裡「我們有一個工具」跟真的有，長得一模一樣
     —— 同 `jsxcomment.py` 那個坑（硬規則 3.6，那一行從寫下的
     當天起就有一半是假的，而沒有任何東西會告訴你）。

── 為什麼是 CSV 不是「全選複製」──────────────────────
匯出的每一列都是一段 DDL，而 DDL 裡有**換行、逗號、單引號、雙引號**。
複製貼上會讓那些內容跟欄位分隔混在一起，接回來的東西是壞的
**而且不會報錯** —— 它看起來就像一份 SQL。
⇒ 一律用 SQL Editor 右上角的下載，交給 csv 模組解析。

── 檔頭那兩個數字由這支自己算（硬規則 1.7）─────────────
「產生時間」與「當時 sql/applied/ 的檔案數與最後一個檔名」
是用來判斷 baseline 過期沒有的，而**那個檢查不需要資料庫**。
🎯 讓腳本算，就不必有人記得去改 —— 要人記得的檢查遲早等於不存在。
"""

import csv
import datetime
import pathlib
import sys

# 一段 DDL 可能是一支很長的函式，遠超過 csv 模組預設的 128KB 上限。
csv.field_size_limit(50 * 1024 * 1024)

ROOT = pathlib.Path(__file__).resolve().parents[2]
APPLIED = ROOT / "sql" / "applied"
OUTDIR = ROOT / "sql" / "_baseline"


def read_ddl(csv_path: pathlib.Path) -> list[str]:
    """讀出 ddl 那一欄。utf-8-sig 是為了吃掉 Excel 或瀏覽器可能加的 BOM。"""
    with csv_path.open(encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))

    if not rows:
        sys.exit("🔴 CSV 是空的 —— 先確認 SQL Editor 真的有回傳結果")

    # 🔴 欄位名寫死成 'ddl' 會在匯出腳本改欄位名那天壞掉，而症狀是
    #    「產出一個空檔案」。所以只有一欄時就用那一欄，不管它叫什麼。
    cols = list(rows[0].keys())
    if "ddl" in cols:
        key = "ddl"
    elif len(cols) == 1:
        key = cols[0]
    else:
        sys.exit(f"🔴 找不到 ddl 欄，CSV 的欄位是：{cols}")

    return [(r.get(key) or "").rstrip() for r in rows]


def applied_state() -> tuple[int, str]:
    """數 applied 的 .sql，並找出日期最新的那一份。"""
    files = sorted(p.name for p in APPLIED.glob("*.sql"))
    dated = [n for n in files if n[:4].isdigit()]
    last = max(dated) if dated else "(沒有帶日期的檔案)"
    return len(files), last


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)

    csv_path = pathlib.Path(sys.argv[1]).expanduser()
    if not csv_path.exists():
        sys.exit(f"🔴 找不到檔案：{csv_path}")

    ddl = read_ddl(csv_path)
    n_applied, last_applied = applied_state()
    today = datetime.date.today().isoformat()

    header = f"""/* ============================================================
   MIGI 資料庫完整結構 baseline
   產生日期：{today}
   基準：`sql/applied/` 有 {n_applied} 個 `.sql`，最後一份是
        `{last_applied}`

   🔴 **這份是機器產生的，不要手改。** 要更新就重跑一次：
      ① Supabase SQL Editor 執行 `sql/checks/匯出完整結構baseline.sql`
      ② 右上角**下載 CSV**（不要全選複製，DDL 裡有換行與引號）
      ③ `python docs/_資產/baseline_csv2sql.py <下載的.csv>`

   ── 怎麼判斷它過期了（不需要連資料庫）──────────────
   比對上面那個檔案數與現在的 `sql/applied/`。不一樣就是過期。
   ⚠ 但它**只能證明「確定過期」，不能證明「還是新的」** ——
     直接在 Dashboard 手改、沒留檔的東西抓不到，
     而那不是假設：`uq_members_line_user` 就是那樣來的。
   → 真要改 schema 時**硬規則 3 永遠成立**：先撈線上版。

   ── 這份不含什麼 ─────────────────────────────────
   種子資料／Storage bucket 與 policy／pg_cron 排程／
   Edge Functions／auth schema。
   ⇒ **重建 = 這份 baseline ＋ 之後累加的 `applied/`**，
     而 `applied/` 記的是「為什麼」，這份記的是「現在長什麼樣」。
     兩份都要。
   ============================================================ */

"""

    OUTDIR.mkdir(parents=True, exist_ok=True)
    out = OUTDIR / f"{today}_完整結構.sql"

    # ⚠ 一律 UTF-8 無 BOM（硬規則 9：PowerShell 寫出來的是 BOM 版，兩種都錯）。
    #   newline="\n" 避免 Windows 上被轉成 CRLF。
    with out.open("w", encoding="utf-8", newline="\n") as f:
        f.write(header)
        f.write("\n\n".join(d for d in ddl if d))
        f.write("\n")

    size_kb = out.stat().st_size / 1024
    print(f"✅ 寫出 {out.relative_to(ROOT)}")
    print(f"   {len(ddl)} 段 DDL · {size_kb:.0f} KB")
    print(f"   基準：applied {n_applied} 份，最後一份 {last_applied}")
    print()
    print("⚠ 還沒做完的兩件事：")
    print("   ① 更新 docs/01-資料庫/db-現況快照.md 檔頭的 baseline 日期")
    print("   ② 更新 sql/checks/錯誤儀表.sql 第 ⑥ 段的五個期望數字")
    print("      （那份自己的註解就寫著「更新 baseline 時記得一起改」）")


if __name__ == "__main__":
    main()
