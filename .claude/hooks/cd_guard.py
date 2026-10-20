# -*- coding: utf-8 -*-
"""擋下「cd 進子資料夾」的指令（PreToolUse hook，管 PowerShell 與 Bash）。

為什麼要有（2026-10-21 使用者：「為什麼一直都會點不開，不要讓我重複說」）：
  在 PowerShell 裡下 `cd "...\\migi-table"; npm run build`，工作資料夾會跟著停在子 repo，
  之後給使用者的 `sql/pending/...` 相對連結就指到 `migi-table/sql/pending/...` ⇒ 點不開。
  同一天發生三次，前兩次只是「切回去」與「寫記憶提醒自己」—— 靠記性一定會再發生。
  ⇒ 改成機制：指令裡一出現 cd／Set-Location／Push-Location 就擋下，叫 Claude 改用不改工作資料夾的寫法。

替代寫法：
  git       git -C "C:/Users/user/Desktop/migi github/migi-pos" status
  npm       npm --prefix "C:/Users/user/Desktop/migi github/migi-pos" run build
  其他      在指令裡寫完整路徑；真的需要換目錄就用子殼層：
            PowerShell  & { Set-Location 'X'; ... } 也不行（同一個行程），請用 Start-Process -WorkingDirectory 或改寫成完整路徑
⚠ 擋的是「這一個 session 的工作資料夾會被改掉」這件事，不是安全性問題。
"""
import json
import re
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

try:
    data = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace") or "{}")
except Exception:
    sys.exit(0)  # 讀不到就放行，不能因為 hook 自己壞掉把所有指令擋死

cmd = ((data.get("tool_input") or {}).get("command") or "")
# 只看指令開頭或分隔符號（; & | 換行 && ||）之後的 cd 類指令；字串裡的 "cd" 不算
pat = re.compile(r"(?:^|[;&|\n]|&&|\|\|)\s*(?:cd|chdir|Set-Location|Push-Location|sl|pushd)(?:\s|$)", re.IGNORECASE)
if pat.search(cmd):
    sys.stderr.write(
        "【擋下 cd】指令裡不要切換資料夾 —— 工作資料夾會跟著停在子 repo，給使用者的 sql/ 連結就會點不開。\n"
        "請改寫成不換目錄的形式：\n"
        "  git -C \"C:/Users/user/Desktop/migi github/<repo>\" <git 指令>\n"
        "  npm --prefix \"C:/Users/user/Desktop/migi github/<repo>\" run build\n"
        "  其他指令一律寫完整路徑。\n"
    )
    sys.exit(2)
sys.exit(0)
