import { RANK_BEARS } from './images.js'

// 共用工具函式 — 從 App.jsx 抽出（純函式：段位/券顯示）

function fmtRank(r) {
  // 顯示格式：'段位: 銅牌熊 I'（全 App 段位膠囊統一前綴）
  return '段位: ' + r
}

function rankColor(rank) {
  const r = rank || ''
  if (r.indexOf('雀神') >= 0) return 'var(--accent)'   // 雀神熊=玫瑰
  if (r.indexOf('大師') >= 0) return 'var(--ink)'   // 大師=深墨
  if (r.indexOf('鑽石') >= 0) return '#A88898'   // 鑽石=玫瑰灰
  if (r.indexOf('白金') >= 0) return 'var(--gray-2)'   // 白金=銀灰
  if (r.indexOf('金牌') >= 0) return '#B8860B'   // 金=金棕
  if (r.indexOf('銀牌') >= 0) return 'var(--gray-2)'   // 銀=灰
  if (r.indexOf('銅牌') >= 0) return '#B08968'   // 銅=銅棕
  return 'var(--gray-1)'
}

// 功能開關：先關閉、未來開放時改 true 即可
const FEATURES = {
  addBuddy: true,    // 加牌咖（邀請制：發邀請 → 對方接受才成立）
}

// 段位熊頭像：依段位字串回傳圖檔（Vite hash 管理，見 images.js）
function rankBearSrc(rank) {
  const r = rank || ''
  if (r.indexOf('雀神') >= 0) return RANK_BEARS.quegod
  if (r.indexOf('大師') >= 0) return RANK_BEARS.master
  if (r.indexOf('鑽石') >= 0) return RANK_BEARS.diamond
  if (r.indexOf('白金') >= 0) return RANK_BEARS.platinum
  if (r.indexOf('金牌') >= 0) return RANK_BEARS.gold
  if (r.indexOf('銀牌') >= 0) return RANK_BEARS.silver
  return RANK_BEARS.bronze
}

// 自選頭像（localStorage）：值為圖檔路徑；null = 未設定（顯示預設頭像）
function getMyAvatar() { try { return localStorage.getItem('migi_avatar') || null } catch { return null } }
function saveMyAvatar(src) { try { if (src) localStorage.setItem('migi_avatar', src); else localStorage.removeItem('migi_avatar') } catch {} }

function couponTag(c) {
  if (c.discount_type === 'free') return '免費'
  if (c.discount_type === 'percent') return (c.discount_value / 10) + '折'
  if (c.discount_type === 'fixed') return '折 ' + c.discount_value + ' 點'
  return '可用'
}
// 票根 stub：左側大字 + 單位（依折抵型態與券種）
function couponStub(c) {
  const kindU = couponKind(c.kind)
  if (c.discount_type === 'free') return { big: '免費', sm: true, u: kindU }
  if (c.discount_type === 'percent') return { big: (c.discount_value / 10) + '折', sm: true, u: kindU }
  if (c.discount_type === 'fixed') {
    // 檯費用「點」，其餘(餐飲/派車)用「$」
    if (c.kind === 'table_discount') return { big: String(c.discount_value), sm: false, u: '點' }
    return { big: '$' + c.discount_value, sm: false, u: kindU }
  }
  return { big: '免費', sm: true, u: kindU }
}
function groupCoupons(list) {
  const map = {}
  list.forEach((c) => {
    const key = [c.name, c.kind, c.discount_type, c.discount_value].join('|')
    if (map[key]) map[key].qty += 1
    else map[key] = { ...c, key, qty: 1 }
  })
  return Object.values(map)
}
function couponKind(k) {
  return ({ table_discount: '檯費', unlimited_play: '暢打', ride: '派車', fnb: '餐飲', topup_bonus: '儲值', generic: '會員' }[k]) || '會員'
}


// 玩法顯示：game_type（台麻/美麻）與 flower（無花/有花）是兩個獨立項目
// 用「 · 」串接，與卡片其他欄位同權重；舊資料若仍是黏在一起的值則自動拆開
function fmtType(gameType, flower) {
  if (!gameType) return ''
  if (flower) return `${gameType} · ${flower}`
  return String(gameType).replace(/^(台麻|美麻)(無花|有花)$/, '$1 · $2')
}

// GPS 經緯度 → 縣市判斷（範圍法，涵蓋目前開放的四個城市；範圍外/定位失敗 fallback 高雄市）
const CITY_BOUNDS = [
  ['台北市', 24.96, 25.21, 121.45, 121.67],
  ['台中市', 24.02, 24.35, 120.55, 120.90],
  ['台南市', 22.90, 23.20, 120.10, 120.35],
  ['高雄市', 22.45, 22.85, 120.20, 120.50],
]
function cityFromLatLng(lat, lng) {
  for (const [name, latMin, latMax, lngMin, lngMax] of CITY_BOUNDS) {
    if (lat >= latMin && lat <= latMax && lng >= lngMin && lng <= lngMax) return name
  }
  return '高雄市'
}

// 距離計算（Haversine 公式，回傳公里，1位小數）
function distanceKm(lat1, lng1, lat2, lng2) {
  if (lat1 == null || lng1 == null || lat2 == null || lng2 == null) return null
  const R = 6371
  const dLat = (lat2 - lat1) * Math.PI / 180
  const dLng = (lng2 - lng1) * Math.PI / 180
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) * Math.sin(dLng / 2) ** 2
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
}
function fmtDistance(km) {
  if (km == null) return ''
  return km < 1 ? Math.round(km * 1000) + 'm' : km.toFixed(1) + 'km'
}

// 營業狀態判斷：open_time===close_time → 24小時；跨夜（close < open）→ 現在≥開店 或 <打烊；一般 → 介於中間
function isStoreOpen(openTime, closeTime, now = new Date()) {
  if (!openTime || !closeTime) return null   // 沒設定營業時間，不顯示狀態
  if (openTime === closeTime) return true    // 24小時營業
  const cur = now.getHours() * 60 + now.getMinutes()
  const [oh, om] = openTime.split(':').map(Number)
  const [ch, cm] = closeTime.split(':').map(Number)
  const openMin = oh * 60 + om, closeMin = ch * 60 + cm
  if (closeMin < openMin) return cur >= openMin || cur < closeMin   // 跨夜
  return cur >= openMin && cur < closeMin
}

export { FEATURES, fmtType, cityFromLatLng, distanceKm, fmtDistance, isStoreOpen, fmtRank, rankColor, rankBearSrc, getMyAvatar, saveMyAvatar, couponTag, couponStub, groupCoupons, couponKind };
