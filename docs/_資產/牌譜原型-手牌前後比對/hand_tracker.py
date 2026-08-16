# -*- coding: utf-8 -*-
"""
hand_tracker.py
===============
側面鏡頭「前後手牌比對算摸打」的核心邏輯（原型階段，用假資料驗證）。

這支程式做的事，就是 Jim 講的那句話：
  「上一秒三張一餅，下一秒剩兩張一餅一張一條，那就知道摸了什麼牌。」

它不碰鏡頭、不碰 AI 模型。它假設「牌已經被辨識成一串牌名了」，
專門驗證：拿到前後兩份手牌，能不能正確算出「摸了什麼、打了什麼」。

台麻 16 張制：手牌休息時 16 張，摸一張變 17 張，打一張回 16 張。
"""

from collections import Counter


class HandTracker:
    """
    一支側面鏡頭 = 一位玩家 = 一個 HandTracker。
    每拍一張快照，就呼叫 feed()，它會回報這次偵測到什麼事件。
    """

    def __init__(self, player_name):
        self.player = player_name
        self.last_hand = None      # 上一次「有效」的手牌快照
        self.last_drawn = None     # 上一次偵測到摸進來、還沒打掉的牌

    def feed(self, snapshot):
        """
        餵進一張新快照（一串牌名，例如 ["一萬","一萬","五筒","九條", ...]）。
        回傳一個事件 dict，或 None（代表這張快照沒有意義，略過）。
        """
        new = Counter(snapshot)

        # 第一張快照 = 起手牌
        if self.last_hand is None:
            self.last_hand = new
            return {
                "事件": "起手",
                "玩家": self.player,
                "牌": sorted(snapshot),
                "張數": sum(new.values()),
            }

        old = self.last_hand
        added = new - old        # 多出來的牌（摸進來的）
        removed = old - new       # 少掉的牌（打出去 / 移到吃碰槓）
        delta = sum(new.values()) - sum(old.values())  # 張數變化

        added_list = list(added.elements())
        removed_list = list(removed.elements())

        event = None

        # ---- 情況 A：只多一張，沒少 → 摸牌（拍到「摸完、還沒打」的 17 張狀態）----
        if len(added_list) == 1 and len(removed_list) == 0 and delta == 1:
            self.last_drawn = added_list[0]
            event = {
                "事件": "摸牌",
                "玩家": self.player,
                "牌": added_list[0],
            }

        # ---- 情況 B：只少一張，沒多 → 打牌 ----
        elif len(added_list) == 0 and len(removed_list) == 1 and delta == -1:
            discarded = removed_list[0]
            if self.last_drawn is not None and discarded == self.last_drawn:
                kind = "摸到直接打"      # （日麻叫摸切，這裡用台麻白話）
            else:
                kind = "打手裡的牌"      # （日麻叫手切）
            self.last_drawn = None
            event = {
                "事件": "打牌",
                "玩家": self.player,
                "牌": discarded,
                "類型": kind,
            }

        # ---- 情況 C：多一張又少一張、張數不變 → 一次抓到整個回合（漏拍了 17 張狀態）----
        elif len(added_list) == 1 and len(removed_list) == 1 and delta == 0:
            self.last_drawn = None
            event = {
                "事件": "摸打",
                "玩家": self.player,
                "摸": added_list[0],
                "打": removed_list[0],
                "類型": "打手裡的牌",   # 摸進來留手、換別張打
            }

        # ---- 情況 D：完全沒變化 → 略過 ----
        # 注意：如果是「摸到直接打」但只拍到休息狀態（16→16），這裡會看不到，
        # 那張打出去的牌要靠俯視鏡頭（海底）補回來。
        elif len(added_list) == 0 and len(removed_list) == 0:
            event = None

        # ---- 情況 E：少了 2~3 張、沒摸 → 疑似碰/槓/吃（牌移到吃碰槓區）----
        elif len(added_list) == 0 and 2 <= len(removed_list) <= 3:
            event = {
                "事件": "疑似吃碰槓",
                "玩家": self.player,
                "少掉的牌": sorted(removed_list),
                "備註": "吃/碰/槓會把牌亮出落地，需俯視鏡頭確認來源與類型",
                "需人工或俯視複查": True,
            }

        # ---- 其他：對不上任何已知樣式 → 標記異常，不丟資料 ----
        else:
            event = {
                "事件": "異常變化",
                "玩家": self.player,
                "多出的牌": sorted(added_list),
                "少掉的牌": sorted(removed_list),
                "張數變化": delta,
                "需人工複查": True,
            }

        # 只有在「不是異常、也不是疑似吃碰槓」時，才更新基準手牌
        # （吃碰槓/異常先不移動基準，等俯視或人工確認後再處理，避免錯誤傳播）
        if event is None or event.get("事件") in ("起手", "摸牌", "打牌", "摸打"):
            self.last_hand = new

        return event


def is_valid_taiwan_hand(snapshot):
    """簡單檢查：台麻手牌休息時應為 16 張，摸牌時 17 張。回傳 (是否合理, 說明)。"""
    n = len(snapshot)
    if n in (16, 17):
        return True, f"{n} 張，合理"
    return False, f"{n} 張，不是 16 或 17，可能辨識漏牌或多牌"
