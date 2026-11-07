# -*- coding: utf-8 -*-
"""每個工具跑完之後檢查：Claude 剛寫的過場話有沒有整句英文（PostToolUse hook）。

為什麼要有（2026-11-07 使用者：「為什麼你一直說英文」「告訴我如何解決」）：
· zh_remind.py 只在使用者送訊息時提醒 —— 連續幾十個工具之後，提醒早就離得很遠
· zh_stop.py 在整輪回完才擋 —— 那時使用者已經看到英文了
⇒ 英文最常出現在「工具之間的過場話」，所以在每個工具之後就抓，下一句之前插警告。

判定沿用 zh_stop.py（同一份 clean 與英文句子規則，不另寫一份）。
同一段文字只警告一次（記在 .zh_mid_seen，不進版控）。
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zh_stop import ENGLISH_RUN, SIMPLIFIED, clean, is_real_user_prompt  # noqa: E402

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

SEEN = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".zh_mid_seen")


def main():
    try:
        data = json.loads(sys.stdin.buffer.read().decode("utf-8") or "{}")
    except Exception:
        return 0
    path = data.get("transcript_path")
    if not path:
        return 0
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()[-60:]
    except Exception:
        return 0
    try:
        with open(SEEN, encoding="utf-8") as f:
            seen = set(f.read().split())
    except Exception:
        seen = set()

    hits, flagged = [], []
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
        if kind != "assistant":
            continue
        uid = entry.get("uuid") or ""
        if uid in seen:
            continue
        content = (entry.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text":
                c = clean(b.get("text") or "")
                found = [m.group(0).strip() for m in ENGLISH_RUN.finditer(c)]
                if not found and any(ch in SIMPLIFIED for ch in c):
                    found = ["（有簡體字）"]
                if found:
                    hits.extend(found)
                    flagged.append(uid)
    if not hits:
        return 0
    try:
        with open(SEEN, "w", encoding="utf-8") as f:
            f.write("\n".join(list(seen)[-200:] + flagged))
    except Exception:
        pass
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": (
                "🔴 你剛才寫給使用者看的話不是繁體中文（CLAUDE.md 硬規則 6.1）：\n"
                + "\n".join("· " + h[:80] for h in hits[:3])
                + "\n下一句開始一律繁體中文，並在下一段文字裡用中文把這幾句的意思重講一次。"
            ),
        }
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
