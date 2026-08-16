# MIGI 台麻 AI 影像辨識 — POC 實作指南 v1.1

> **這是什麼／何時讀**:POC 等級的辨識系統實作指南(ROI 裁切、動態合法張數、多幀共識鎖定、驗證鐵則、AGPL 授權)。寫辨識推論程式、或要知道「這段程式碼有沒有 bug」時讀這份,比操作手冊更技術向。

> 定位:**固定環境 POC(概念驗證)實作指南**。完成本文全部機制並以獨立測試集驗證後,才進入門市部署討論。
> v1.1 合併外部技術審查意見:ROI 裁切、多幀共識鎖定、動態合法張數(含槓)、驗證鐵則、增強禁鏡像、DeckLink 敘述修正、GPU 驗證、AGPL 授權警語。
> 用語鐵則:台麻用語;不用日麻用語。名稱依官方統一寫 **YOLO11**(非 YOLOv11)。

---

## 與網路流傳版的差異(先看這裡)

| 原版說法 | 問題 | 本版做法 |
|---|---|---|
| 「台灣麻將共 34 種牌型 + 花牌」,標籤 0~33 | 34 類是日麻;照抄則花牌無類別可標 | **42 類**(+選配 `back` 共 43),標籤用 MIGI 兩碼編碼 |
| `pip install git+…yolov10.git` | 與官方 ultralytics 衝突 | **只裝官方 `pip install ultralytics`**,模型 `yolo11n.pt` |
| 影片每秒抽 1~2 張當訓練資料 | 相鄰影格重複,做出爛資料集 | 隔久抽一張 + 人工去重;重多樣性不重數量 |
| 「需要成千上萬張照片」/「150 張即接近 100%」 | 前者誇大、後者說過頭 | **150~300 張可做固定環境 POC 起點**;是否足夠須以跨影片/跨日期/跨光線的獨立測試集驗證,**不得宣稱固定可達接近 100%** |
| 整張畫面直接丟 YOLO 再 X 軸排序 | 會把河牌/別家牌/花牌混進「手牌」 | **先裁 ROI 再辨識**(見 §4.1) |
| 「偵測 <16 張就凍結」 | 玩家一吃碰就永久凍結 | **動態合法張數**(見 §4.2,含槓的情況) |
| 「連續完全相同 1 秒才更新」 | 一幀誤判即歸零,實務鎖不住 | **最近 N 幀多數共識**(見 §4.3) |

原版值得保留的兩個好點子(已納入):**遮擋樣本要標**、**狀態鎖定防抖**(升級為多幀共識)。

---

## 系統架構總覽

```
鏡頭(每家一支側面)
   ▼
ROI 裁切(玩家暗牌區 / 吃碰槓區 / 花牌區分開)
   ▼
YOLO11 單幀辨識(自訓 42 類台麻模型)
   ▼
時序共識(最近 N 幀投票,非單幀採信)
   ▼
手牌 / 吃碰槓狀態機(動態合法張數)
   ▼
hand_tracker(前後比對算摸打,事件帶 confidence)
   ▼
本機 JSONL / SQLite 佇列(防當機)
   ▼
非同步寫入 Supabase(對齊 paipu_events)
```

---

## 1. 資料採集與標註

### 1.1 素材
- 用實際部署鏡頭(或先手機)錄打牌過程;抽影格**同場景隔 30~60 秒一張**,人工去重。
- 目標 **150~300 張精選原圖**,涵蓋不同光線、角度、距離、背景、遮擋。

### 1.2 標註(Roboflow / LabelImg)
- 類別 **42 類,直接用 MIGI 兩碼編碼當標籤名**:

```
1m~9m / 1p~9p / 1t~9t / E0 S0 W0 N0 / B0 F0 C0 / H1~H8
```

- **不要建立紅 5(`0m/0p/0t`)**——台麻沒有紅 5。(註:`0s` 是其他牌譜系統常見的索子表示法,不是 MIGI 編碼;MIGI 條子為 `t`。)
- 可加一類 `back`(牌背),共 43 類,對俯視有用。
- **遮擋樣本要標**:被手指擋到一半的牌照樣畫框給類別。
- **花牌 `H1`~`H8` 要特別多拍**:每張只有一張、公開資料集沒有,是最易訓練不足的類別;驗收時逐類看 recall。

### 1.3 資料增強(在資料切割「之後」才做,見 §2.2)
- 允許:小幅旋轉(幅度以實際鏡頭偏角為準,固定鏡頭偏 5° 就別增到 ±15°)、亮度/色溫變化、曝光不足、輕微動態模糊、局部遮擋、小幅透視變形、壓縮雜訊、鏡頭失焦。
- **禁止:水平或垂直鏡像翻轉。** 麻將牌的文字與圖案沒有鏡像版本,鏡像會生成現實不存在的反向萬字/風牌/中發白/花牌文字,污染訓練。

---

## 2. 訓練與驗證

### 2.1 安裝與 GPU 驗證(Windows)

```
pip install ultralytics
```

裝完**先驗證有沒有吃到 GPU**(一行安裝完成不代表在用 NVIDIA):

```
python -c "import torch, ultralytics; print('ultralytics=', ultralytics.__version__); print('cuda=', torch.cuda.is_available()); print('gpu=', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'CPU')"
```

`cuda= False` → 依《操作手冊》安裝 CUDA 版 PyTorch,或改走 Google Colab。

訓練指令(明確指定 device):

```
yolo detect train model=yolo11n.pt data="C:\mahjong\dataset\data.yaml" epochs=100 imgsz=640 device=0
```

產出 `runs\detect\train\weights\best.pt`。

> ⚠ **商用授權**:Ultralytics YOLO11 採 **AGPL-3.0 / Enterprise 雙授權**。MIGI 若作為閉源商業系統部署,**正式商用前須確認 Enterprise 授權,或由法律顧問確認 AGPL 義務**。POC 階段不受影響,但商轉前必辦。

### 2.2 驗證鐵則(防「假高分」)
1. **以整場影片 / 拍攝日期分組切割** train / val / test;**同一場影片的影格不得跨集**。
2. **先切割、再增強**;增強只作用於訓練集。建議先建「無增強基準版本」確認原始資料品質。
3. 不只看 mAP,驗收指標包含:
   - 單牌分類正確率、**每類 recall(尤其 H1~H8)**
   - **整手完全正確率**(單張 99% 時 16 張全對僅約 0.99¹⁶ ≈ 85%,單牌高分 ≠ 整手可靠)
   - 合法張數通過率、摸牌事件正確率、打牌事件正確率、每小時錯誤事件數

---

## 3. 視訊流接收

- **UVC USB 鏡頭 / UVC USB 擷取盒**:通常可直接 `cv2.VideoCapture(index)`。
- **Blackmagic DeckLink(PCIe 專業擷取卡)**:**不保證能直接以 OpenCV 裝置編號讀取**——取決於驅動、後端與格式;必要時走 Blackmagic Desktop Video / DeckLink SDK、DirectShow、FFmpeg 或 GStreamer 接收後再入辨識管線。
- **多鏡頭管理**:不要依賴 Windows 開機後可能改變的裝置編號順序;正式系統應保存每支鏡頭的設定檔:

```
camera_id / device_name / serial_number / seat / ROI / 解析度 / FPS / 旋轉方向
```

---

## 4. 核心機制

### 4.1 ROI 裁切(必要,不可整張畫面直接辨識)

**YOLO 輸入必須先裁切玩家手牌 ROI;不可直接把整桌辨識結果用 X 軸排序當作手牌。** 否則河牌、別家的牌、花牌全混進 `tiles`,即使每張都認對,手牌陣列仍是錯的。

至少拆分:

```
concealed_roi:玩家暗牌區(第一版先只做這個)
meld_roi:吃碰槓區
flower_roi:花牌區
discard_roi:河牌區(俯視鏡頭負責)
```

```python
x1, y1, x2, y2 = HAND_ROI                      # 每支鏡頭各自校準、存設定檔
hand_frame = frame[y1:y2, x1:x2]
results = model(hand_frame, conf=0.6, verbose=False)[0]
```

### 4.2 動態合法張數(否則第一次碰牌後整局凍結)

依**鏡頭 ROI 拍到哪裡**決定算法(吃、碰、明槓、暗槓都算一組 meld):

**情況 A:ROI 只拍暗牌區(建議的第一版)**

```
expected_rest = 16 - 3 * meld_count      # 未吃碰槓16;1組13;2組10;3組7
expected_draw = expected_rest + 1
```

**情況 B:ROI 同時拍到暗牌 + 吃碰槓區**

```
expected_rest = 16 + kong_count          # 槓一組是 4 張,每槓總數 +1
expected_draw = 17 + kong_count
```

- `meld_count` / `kong_count` 由「疑似吃碰槓」事件(手牌驟降 2~3 張)+ 俯視 / meld_roi 確認後遞增。
- **花牌不改基準**:台麻亮花後補牌,張數復原,僅短暫 −1,由時序共識自然吸收。
- 凍結條件改為:「**張數不符合目前牌局狀態的合法值**」才凍結,不是寫死 <16。

### 4.3 多幀共識鎖定(取代「連續完全相同 1 秒」)

單幀採信的問題:只要一幀把 `5p` 誤判成 `6p`,「完全相同」計時就歸零,實務上可能長時間鎖不住。改為**最近 N 幀投票**:

```python
from collections import deque, Counter
import time

history = deque(maxlen=8)                  # 幀數與門檻為起始值,依實測調整

def hand_key(hand):
    return tuple(hand)

# 每幀:
history.append(current)
if len(history) == history.maxlen:
    counts = Counter(hand_key(h) for h in history)
    best_hand, votes = counts.most_common(1)[0]
    if votes >= 6 and list(best_hand) != locked_hand:      # 8 幀中 ≥6 幀一致
        # 且張數須為 §4.2 的合法值
        if len(best_hand) in (expected_rest, expected_draw):
            locked_hand = list(best_hand)
            # → hand_tracker.feed(locked_hand)
```

- 時間量測一律用 `time.monotonic()`,不用可能被系統校時影響的 `time.time()`。
- 進階(視 POC 結果決定是否需要):每個位置獨立投票、分類信心平均、座標容許小幅位移、最低有效幀數、整手信心分數。
- ⚠ 上述為示意起始值;**maxlen 與票數門檻必須實測調整**,不是定論。

### 4.4 摸打事件的誠實推論(不寫死百分之百)

`locked_hand` 更新後餵 `hand_tracker.feed()` 做前後比對,但**「自然算出所有摸打」說得太滿**,以下情況會失敗或降級:

| 情況 | 處理 |
|---|---|
| 16→17 | 疑似摸牌 |
| 17→16 | 疑似打牌 |
| 16→16 內容有異(17 態沒鎖到) | 疑似摸打:Counter 差異推「新增1/移除1」,confidence 降 |
| 16→16 內容完全相同 | 可能**原張摸打**(摸到什麼打什麼且與手牌重複)→ 標 `unresolved`,交俯視/三方對帳 |
| 同名牌 2~3 張 | 無法確定動的是哪一張實體 → 事件成立、實體歸屬標不確定 |
| 理牌換位(內容同、順序變) | 非動作,忽略(以 multiset 比對,不以順序) |
| 張數驟降 2~3 | 疑似吃碰槓,搭配 meld_roi / 俯視判定 |

事件一律帶 confidence 與推論方式,對齊 `paipu_events`:

```json
{
  "action": "discard",
  "tile": "5p",
  "confidence": 0.82,
  "meta": { "inference_type": "16_to_16_diff", "draw_state_observed": false }
}
```

---

## 5. 資料落地

- 事件先寫**本機 JSONL / SQLite 佇列**(防當機、防斷網),再**非同步**寫入 Supabase(`paipu_events`:`game_id / hand_id / seat / turn_no / action / tile / meta / confidence`)。
- 座位→會員由開桌流程綁定(`game_players`,技術設計 §10.5);鏡頭只認座位不認人。
- Roboflow 匯出格式:選其介面當下顯示的 **YOLO11 相容格式**。

---

## 6. 實務提醒(沿用既有結論)

- **側面先做、俯視後做**;俯視抓牌落地瞬間最難,別先挑戰。
- **手搓死角仍在**:全程牌背朝外、摸進留手的牌,靠三方對帳補集合、標低 confidence(技術設計 §10.3)。
- **原型先錄影、事後跑**(鏡頭安裝規格 §4.4),先拿錄好的影片驗模型與 hand_tracker,再上即時。

---

## 升版條件(POC → 正式 v2)

1. ROI 裁切與動態合法張數上線並實測。
2. 多幀共識參數(N、票數)以實錄影片調校完成。
3. 以跨影片/跨日期的獨立測試集完成 §2.2 全部驗收指標。

---

## 連動文件
- 《牌面編碼對照表 v1.0》/《台麻牌辨識 Windows 操作手冊 v1.0》
- 《牌譜鏡頭安裝規格 v0.1》/《牌譜成績資料中台技術設計 v0.4》
- 原型 `hand_tracker.py` / `tiles.py`
