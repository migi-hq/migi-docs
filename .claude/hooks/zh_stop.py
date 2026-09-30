# -*- coding: utf-8 -*-
"""Claude 回完之前檢查：這一輪寫給使用者看的文字裡有沒有整句英文（Stop hook）。

為什麼要有：「一律講中文」寫在 CLAUDE.md 硬規則 6.1 與記憶裡，而 Claude 還是一再破功
（2026-10-01 一天內被說了五六次，連「把英文翻成中文」那一則都寫成英文）。
提醒（zh_remind.py）擋不住，所以要有一道真的會擋的檢查 —— 同 CLAUDE.md 11.1：
**把規則變成不需要人記得的檢查。**

判定：
· 只看「這一輪」—— 從使用者最後一則真正的訊息之後，Claude 寫出來的文字（含工具之間的過場句）
· 先拿掉程式碼區塊、行內程式碼、連結網址、檔案路徑 —— 那些本來就可以是英文
· 剩下的文字裡，出現**連續 6 個以上的英文單字**（中間只隔空白）就算一句英文
  （「hook」「SQL」「Stop hook」這種夾在中文裡的短詞不會被抓）
· 抓到 ⇒ 擋下來，要 Claude 用中文重講那幾段
· 已經被擋過一次（stop_hook_active）就放行，避免無限迴圈
"""
import json
import re
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

ENGLISH_RUN = re.compile(r"[A-Za-z][A-Za-z'’\-]*(?:[ \t]+[A-Za-z][A-Za-z'’\-]*){5,}")

# 只有簡體中文才會出現的字（2026-10-01 使用者：「不要簡體中文」）。
# ⚠ 刻意**不收**繁體裡也合法的字（里、后、于、台、并、几、据、价、体、号、广、户…），
#   收了會把正常的繁體誤判成簡體 —— 一個常常誤擋的檢查會讓人學會忽略它。
SIMPLIFIED = set(
    "这们为说没对个过还时会让发开关实现问题应该视页数库设计从动进来边场员单钱点写读记认识请谢务"
    "东车门间见觉经结给线统转选错长张难头学业专区历变图报标构检测试验确显响顺须预馆饮饭产质级优"
    "积钮码块执删际汇队灯绿红蓝权录册与"
)


def clean(text):
    text = re.sub(r"```.*?```", " ", text, flags=re.S)          # 程式碼區塊
    text = re.sub(r"`[^`\n]*`", " ", text)                        # 行內程式碼
    text = re.sub(r"\]\([^)]*\)", "]", text)                      # 連結網址（保留連結文字）
    text = re.sub(r"https?://\S+", " ", text)                     # 裸網址
    text = re.sub(r"(?:[A-Za-z]:)?[\w.\-]*[/\\][\w./\\\-]+", " ", text)  # 檔案路徑
    return text


def is_real_user_prompt(entry):
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, str):
        return True
    if isinstance(content, list):
        kinds = {b.get("type") for b in content if isinstance(b, dict)}
        return "tool_result" not in kinds and "text" in kinds
    return False


def main():
    try:
        data = json.loads(sys.stdin.buffer.read().decode("utf-8") or "{}")
    except Exception:
        return 0
    if data.get("stop_hook_active"):
        return 0
    path = data.get("transcript_path")
    if not path:
        return 0
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except Exception:
        return 0

    texts = []
    for raw in reversed(lines):
        try:
            entry = json.loads(raw)
        except Exception:
            continue
        kind = entry.get("type")
        if kind == "user":
            if is_real_user_prompt(entry):
                break
            continue
        if kind == "assistant":
            content = (entry.get("message") or {}).get("content")
            if isinstance(content, list):
                for b in content:
                    if isinstance(b, dict) and b.get("type") == "text":
                        texts.append(b.get("text") or "")

    hits = []
    simp = []
    for t in reversed(texts):
        c = clean(t)
        for m in ENGLISH_RUN.finditer(c):
            hits.append(m.group(0).strip())
        last = -99
        for i, ch in enumerate(c):
            if ch in SIMPLIFIED and i - last > 16:      # 同一句只取一段，不要每個字印一次
                simp.append(c[max(0, i - 8):i + 8].replace("\n", " "))
                last = i
    if not hits and not simp:
        return 0

    parts = []
    if hits:
        parts.append("有英文句子：\n" + "\n".join("· " + h[:80] for h in hits[:3]))
    if simp:
        parts.append("有簡體字：\n" + "\n".join("· …" + s + "…" for s in simp[:3]))
    print(json.dumps({
        "decision": "block",
        "reason": (
            "這一輪寫給使用者看的文字不是全部繁體中文（CLAUDE.md 硬規則 6.1）。"
            "請把下面這幾段的意思用繁體中文重新講一次給使用者，不要只說『已改正』：\n" + "\n".join(parts)
        ),
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
