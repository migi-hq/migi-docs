# -*- coding: utf-8 -*-
"""
tiles.py
========
牌面編碼(兩碼制)—— 對應《牌面編碼對照表 v1.0》與技術設計 §3。

原則:**內部一律存兩碼**(對齊 paipu_events.tile 欄位),
      **顯示時才轉中文**(給人看)。

規則:
  萬 1m-9m / 筒 1p-9p / 條 1t-9t
  風 E0 S0 W0 N0 / 三元 B0 F0 C0
  花 H1-H8(春夏秋冬梅蘭竹菊)
  台麻無紅5。條用 t(不用日麻的 s/索)。花用 H(避開「發 F0」的 F)。
"""

TILE_NAMES = {
    # 萬
    "1m": "一萬", "2m": "二萬", "3m": "三萬", "4m": "四萬", "5m": "五萬",
    "6m": "六萬", "7m": "七萬", "8m": "八萬", "9m": "九萬",
    # 筒
    "1p": "一筒", "2p": "二筒", "3p": "三筒", "4p": "四筒", "5p": "五筒",
    "6p": "六筒", "7p": "七筒", "8p": "八筒", "9p": "九筒",
    # 條
    "1t": "一條", "2t": "二條", "3t": "三條", "4t": "四條", "5t": "五條",
    "6t": "六條", "7t": "七條", "8t": "八條", "9t": "九條",
    # 風牌
    "E0": "東", "S0": "南", "W0": "西", "N0": "北",
    # 三元牌
    "B0": "白", "F0": "發", "C0": "中",
    # 花牌
    "H1": "春", "H2": "夏", "H3": "秋", "H4": "冬",
    "H5": "梅", "H6": "蘭", "H7": "竹", "H8": "菊",
}

TILE_CODES = {v: k for k, v in TILE_NAMES.items()}   # 中文 → 碼


# ---- 分類判斷 ----
def is_suit(tile):   return tile[1] in ("m", "p", "t")     # 數牌
def is_wind(tile):   return tile in ("E0", "S0", "W0", "N0")
def is_dragon(tile): return tile in ("B0", "F0", "C0")
def is_honor(tile):  return is_wind(tile) or is_dragon(tile)
def is_flower(tile): return tile[0] == "H"


# ---- 牌組 ----
def build_wall(with_flowers=True):
    """完整牌組。台16(有花)144 張;南部台(無花)136 張。"""
    wall = []
    for suit in ("m", "p", "t"):
        for n in range(1, 10):
            wall += [f"{n}{suit}"] * 4
    for honor in ("E0", "S0", "W0", "N0", "B0", "F0", "C0"):
        wall += [honor] * 4
    if with_flowers:
        wall += [f"H{n}" for n in range(1, 9)]     # 花牌各 1 張
    return wall


# ---- 排序(顯示 / 理牌用)----
SUIT_ORDER = {"m": 0, "p": 1, "t": 2}
HONOR_ORDER = {"E0": 0, "S0": 1, "W0": 2, "N0": 3, "B0": 4, "F0": 5, "C0": 6}


def sort_key(tile):
    """萬 → 筒 → 條 → 風(東南西北)→ 三元(白發中)→ 花"""
    if is_flower(tile):
        return (4, int(tile[1]))
    if is_honor(tile):
        return (3, HONOR_ORDER[tile])
    return (SUIT_ORDER[tile[1]], int(tile[0]))


def sort_hand(tiles):
    return sorted(tiles, key=sort_key)


# ---- 顯示轉換 ----
def to_cn(tile):
    """單張:碼 → 中文。未知碼原樣回傳,不吞錯。"""
    return TILE_NAMES.get(tile, f"?{tile}")


def hand_to_cn(tiles, sort=True):
    """整副手牌:碼 → 中文字串。"""
    seq = sort_hand(tiles) if sort else tiles
    return "、".join(to_cn(t) for t in seq)


def from_cn(name):
    """中文 → 碼。"""
    return TILE_CODES.get(name)


def validate(tile):
    """檢查是否為合法兩碼牌面。"""
    return isinstance(tile, str) and len(tile) == 2 and tile in TILE_NAMES
