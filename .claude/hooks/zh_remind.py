# -*- coding: utf-8 -*-
"""每次使用者送出訊息時，把這段提醒塞進 Claude 的上下文（UserPromptSubmit hook）。

為什麼要有：CLAUDE.md 硬規則 6.1 與記憶都寫了「一律講中文」，而 Claude 還是一再破功 ——
最常在連續動作很久、或對話被壓縮接續之後。靠記得的規則一定會失效，所以改成每一則都提醒。
兜底的是 zh_stop.py（回完之前檢查，有整句英文就擋下來）。
"""
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

print(
    "【語言提醒】所有給使用者看的文字一律繁體中文："
    "包含工具呼叫之間的每一句過場話、最後的總結、表格、清單、commit 訊息、註解。"
    "程式碼識別字（變數、函式、檔名）維持原樣。"
    "每寫一句話之前先確認它是中文；越是連續動作越要檢查。"
)
