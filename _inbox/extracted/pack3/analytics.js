/* ===================================================================
   分析追蹤（中央函式）
   -------------------------------------------------------------------
   一個埋點、多處輸出：所有頁面只呼叫 track()，要接哪些工具都改這裡。

   本檔負責四件基礎建設，缺了任何一項事後都補不回來：
     ① session_id  一次使用的行為串得起來（算得出「看幾局才報名」）
     ② event_id    網路重試時可去重，營收數字不會虛胖
     ③ 離線佇列    LINE WebView 網路不穩，送失敗先存著，連上再補
     ④ 測試閘門    測試帳號只寫自己的庫，永不送 GA4／Meta

   ④ 特別重要：GA4 與 Meta 不看資料庫的 is_test，資料進去洗不掉，
   還會讓廣告拿假轉換去學習受眾。唯一的防線就是在這裡擋住。
   =================================================================== */
import { supabase, MIGI_ORG_ID } from './supabase'

const MEMBER_KEY = 'migi_member'
const QUEUE_KEY = 'migi_evt_queue'
const SESSION_KEY = 'migi_session'
const SESSION_IDLE_MIN = 30        // 閒置逾時後視為新的一次使用

// 建置版本（vite.config define 注入；dev 模式下也有值）
export const APP_VERSION = typeof __APP_VERSION__ !== 'undefined' ? __APP_VERSION__ : 'dev'

export const ANALYTICS = {
  enabled: true,
  toConsole: true,
  toSupabase: true,       // 已接 app_events
  toGA4: false,           // 要投廣告時再開
  toMeta: false,          // 建議走後端 Conversions API，前端在 LIFF 內成功率低
  toPostHog: false,
}

/* ---------- 會員 ---------- */
function readMember() {
  try { return JSON.parse(localStorage.getItem(MEMBER_KEY) || 'null') } catch { return null }
}
export function currentMemberId() {
  const m = readMember(); return (m && m.id) || null
}
// 測試帳號 UUID（與 TestAccountSwitcher 同一份名單）。
// 直接比對 id 而非依賴 localStorage 是否寫了 is_test —— 切帳號的路徑有好幾條，
// 漏寫一次就會讓假資料流進 GA4／Meta，那是洗不掉的。
const TEST_MEMBER_IDS = [
  'd73fdac2-d6b9-4b8a-bcff-b19c2786056f',   // 測試01
  '218378e1-fb6c-43fb-b642-99fdbf5c52b1',   // 測試02
  'd0db928e-5a75-4535-90d4-93ede67790a8',   // 測試03
  '526aa8b9-cc93-4327-b878-6d21d399af8e',   // 測試04
]

export function isTestMember() {
  const m = readMember()
  if (!m) return false
  if (m.is_test) return true
  return TEST_MEMBER_IDS.indexOf(m.id) >= 0
}

/* ---------- session ---------- */
// 一次「使用」= 連續操作不中斷超過 30 分鐘。
// 沒有它就無法回答「一次使用裡看了幾局才報名」這類漏斗問題。
function currentSessionId() {
  const now = Date.now()
  let s = null
  try { s = JSON.parse(sessionStorage.getItem(SESSION_KEY) || 'null') } catch {}
  if (!s || !s.id || (now - (s.last || 0)) > SESSION_IDLE_MIN * 60000) {
    s = { id: uuid(), start: now, last: now, seq: 0 }
  }
  s.last = now
  s.seq = (s.seq || 0) + 1
  try { sessionStorage.setItem(SESSION_KEY, JSON.stringify(s)) } catch {}
  return s
}

function uuid() {
  try {
    if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID()
  } catch {}
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0
    return (c === 'x' ? r : ((r & 0x3) | 0x8)).toString(16)
  })
}

/* ---------- 離線佇列 ---------- */
// LINE WebView 常在網路不穩的環境（店裡 wifi、地下室），
// 送失敗的事件先存 localStorage，下次有機會再補送。
function queuePush(payload) {
  try {
    const q = JSON.parse(localStorage.getItem(QUEUE_KEY) || '[]')
    q.push(payload)
    // 上限 200 筆，滿了丟最舊的，避免無限長大撐爆 localStorage
    localStorage.setItem(QUEUE_KEY, JSON.stringify(q.slice(-200)))
  } catch {}
}

let flushing = false
export async function flushQueue() {
  if (flushing || !ANALYTICS.toSupabase) return
  let q = []
  try { q = JSON.parse(localStorage.getItem(QUEUE_KEY) || '[]') } catch { return }
  if (!q.length) return

  flushing = true
  const rest = []
  for (const p of q) {
    const ok = await sendOne(p)
    if (!ok) rest.push(p)
  }
  try { localStorage.setItem(QUEUE_KEY, JSON.stringify(rest)) } catch {}
  flushing = false
}

async function sendOne(payload) {
  try {
    const { error } = await supabase.rpc('log_app_event_tx', {
      p_org_id: MIGI_ORG_ID,
      p_member_id: payload.member_id,
      p_event: payload.event,
      p_props: payload.props,
      p_client_ts: payload.client_ts,
    })
    if (error) { console.warn('[track] 上傳失敗', error.message); return false }
    return true
  } catch (e) { console.warn('[track] 上傳失敗', e); return false }
}

/* ---------- 主函式 ---------- */
export function track(event, props = {}) {
  if (!ANALYTICS.enabled) return

  const s = currentSessionId()
  const testing = isTestMember()

  const payload = {
    event,
    member_id: currentMemberId(),
    client_ts: new Date().toISOString(),
    props: {
      // event_id 供後端去重：網路重試同一筆不會算兩次營收
      _eid: uuid(),
      _sid: s.id,
      _seq: s.seq,                                    // 這次使用的第幾個動作
      _sms: Math.round((s.last - s.start) / 1000),    // 進入本次使用後幾秒
      _schema_v: 2,                                   // 事件格式版本，改格式時歷史仍可讀
      app_version: APP_VERSION,
      ...props,
    },
  }

  if (ANALYTICS.toConsole) {
    try { console.log('[track]' + (testing ? '[TEST]' : ''), event, payload.props) } catch {}
  }

  // 自己的庫：測試帳號照樣寫入，但後端會標記 is_test，分析走 v_real_app_events
  if (ANALYTICS.toSupabase) {
    sendOne(payload).then((ok) => { if (!ok) queuePush(payload) })
  }

  // ★ 外部工具：測試帳號一律不送。
  //   GA4／Meta 收進去的資料無法回溯刪除，且會污染廣告受眾學習。
  if (testing) return

  if (ANALYTICS.toGA4) {
    try { window.gtag && window.gtag('event', event, payload.props) } catch {}
  }
  if (ANALYTICS.toMeta) {
    try { window.fbq && window.fbq('trackCustom', event, payload.props) } catch {}
  }
  if (ANALYTICS.toPostHog) {
    try { window.posthog && window.posthog.capture(event, payload.props) } catch {}
  }
}

/* ---------- 狀態快照 helper ---------- */
// 只記「他報名了」永遠答不出「還剩 1 位時報名率是否更高」。
// 決策當下的環境要一起記，事後補不回來。
export function snapQueue(q, extra = {}) {
  if (!q) return extra
  const seats = (q.seats_total || 4) - (q.joined_count || 0)
  return {
    queue_id: q.id,
    store: q.store_name,
    stake: q.stake_label,
    seats_left: seats,
    joined_count: q.joined_count,
    minutes_to_play: q.play_at
      ? Math.round((new Date(q.play_at) - Date.now()) / 60000) : null,
    is_recurring: q.source === 'recurring',
    ...extra,
  }
}

export function snapWallet(balance, extra = {}) {
  return { balance_before: balance, ...extra }
}

/* ---------- 滲透率 ---------- */
export function markAppActive() {
  const id = currentMemberId()
  if (!id) return
  if (ANALYTICS.toConsole) { try { console.log('[active]', id) } catch {} }
  if (ANALYTICS.toSupabase) {
    try {
      supabase.rpc('mark_app_active_tx', { p_org_id: MIGI_ORG_ID, p_member_id: id })
        .then(({ error }) => { if (error) console.warn('[active] 上傳失敗', error.message) })
    } catch (e) { console.warn('[active] 上傳失敗', e) }
  }
  flushQueue()   // 開 App 時順手補送離線期間累積的事件
}

// 回到前景時補送；離開時也試一次（不保證送完，故仍需佇列）
if (typeof document !== 'undefined') {
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') flushQueue()
  })
}
