# -*- coding: utf-8 -*-
"""提醒 Claude 先跑錯誤儀表（sql/checks/錯誤儀表.sql）。

為什麼要有：CLAUDE.md 硬規則 12 寫著「每次 session 開始跑一次錯誤儀表」，而它照樣被漏掉 ——
2026-10-16 下午 LINE 推播免費則數用完，儀表第 ⑳ 段當下就會亮紅燈，卻四天沒人跑，
118 則成桌／牌局結束卡沒送到客人手上（10-20 才發現）。同一次還抓到第 ⑦ 段已經紅了九天。
⇒ 靠記得的規則一定會失效，改成 hook。

兩種觸發（同一支程式）：
  python dash_remind.py session   SessionStart（開新對話、恢復、/clear、壓縮接續）—— 一定提醒
  python dash_remind.py prompt    UserPromptSubmit —— 距離上次提醒超過 12 小時才提醒
                                  （這個專案的對話常常一路接續好幾天，只靠 SessionStart 會漏）
上次提醒的時間記在 .claude/hooks/.dash_last（不進版控）。任何錯誤都安靜放過，不擋使用者的訊息。
"""
import sys, os, time

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

HOURS = 12
STAMP = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".dash_last")
MSG = (
    "【錯誤儀表】先用 Supabase MCP 跑 sql/checks/錯誤儀表.sql（唯讀）再做別的事，"
    "有 🔴 或 ⚠ 的格子要先跟使用者講。"
    "特別看 ⑳ LINE 推播（額度用完客人就收不到成桌通知）與 ① 近 7 天的錯誤。"
    "（2026-10-16 推播額度用完、儀表四天沒人跑，118 則通知沒送出 —— 這個提醒就是為了不再發生。）"
)


def last():
    try:
        with open(STAMP, encoding="utf-8") as f:
            return float(f.read().strip() or 0)
    except Exception:
        return 0.0


def mark():
    try:
        with open(STAMP, "w", encoding="utf-8") as f:
            f.write(str(time.time()))
    except Exception:
        pass


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "session"
    if mode == "prompt" and time.time() - last() < HOURS * 3600:
        return
    print(MSG)
    mark()


try:
    main()
except Exception:
    pass
