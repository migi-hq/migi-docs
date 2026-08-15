/* POS 資料層：所有後端呼叫集中在這裡，頁面只管畫面
 *
 * ⚠️ 重要：本專案的資料表都有 RLS policy（org_id = current_org_id()），
 * 而 current_org_id() 依賴 auth session（staff.auth_uid / members.line_user_id）。
 * POS 目前用 anon key 連線、沒有 auth session，直接查表一律回空陣列（不會報錯）。
 * → 所有查詢必須走 SECURITY DEFINER 的 RPC，不可用 supabase.from('表').select()
 * 待認證升級（LINE Login → Supabase Auth）完成後，才能考慮直接查表。
 */
import { supabase, MIGI_ORG_ID, getStoreId } from './supabase.js'

/* ---------- 門市 ---------- */
export async function listStores() {
  const { data, error } = await supabase.rpc('list_stores_tx', { p_org_id: MIGI_ORG_ID })
  if (error) { console.warn('listStores', error); return [] }
  return data || []
}

/* ---------- 桌況 ---------- */
export async function listTables(storeId) {
  const sid = storeId || getStoreId()
  if (!sid) return []
  const { data, error } = await supabase.rpc('list_tables_tx', {
    p_org_id: MIGI_ORG_ID, p_store_id: sid,
  })
  if (error) { console.warn('listTables', error); return [] }
  return data || []
}

// 桌位停用／啟用（維修中等現場狀況）
export async function setTableActive(tableId, active, note) {
  const { data, error } = await supabase.rpc('set_table_active_tx', {
    p_table_id: tableId, p_active: active, p_note: note || null,
  })
  if (error) { console.warn('setTableActive', error); return { ok: false } }
  return data || { ok: false }
}

/* ---------- 開桌流程 ---------- */
// 建立場次（不收費）
export async function openSession(opts) {
  const { data, error } = await supabase.rpc('open_session_tx', {
    p_table_id: opts.tableId,
    p_mode: opts.mode,                       // 'matched' | 'private'
    p_stake_level_id: opts.stakeLevelId || null,
    p_planned_rounds: opts.rounds || null,   // 配桌 2 / 3
    p_planned_minutes: opts.minutes || null, // 包桌 120 / 300 / 1440
    p_staff_id: opts.staffId || null,
    p_open_method: opts.openMethod || 'manual',
    p_idempotency_key: opts.idempotencyKey || null,
  })
  if (error) { console.warn('openSession', error); return { ok: false, reason: error.message } }
  return data || { ok: false }
}

// 試算某人應收檯費
// memberId 必傳，否則後端無法判斷此人是否持有當日暢打（持有者配桌檯費為 0）
export async function calcFee(sessionId, joinType, memberId) {
  const { data, error } = await supabase.rpc('calc_session_fee_tx', {
    p_session_id: sessionId,
    p_join_type: joinType || 'opener',
    p_member_id: memberId || null,
  })
  if (error) { console.warn('calcFee', error); return { ok: false } }
  return data || { ok: false }
}

// 加人並收費（內部走 checkout_tx，支援券／點數／混合付款）
export async function joinSession(opts) {
  const { data, error } = await supabase.rpc('join_session_tx', {
    p_session_id: opts.sessionId,
    p_member_id: opts.memberId,
    p_join_type: opts.joinType || 'opener',  // opener | mid_join | sub
    p_coupon_ids: opts.couponIds || null,
    p_points_used: opts.pointsUsed || 0,
    p_payments: opts.payments || null,       // [{method,amount,cash_received,change_given}]
    p_staff_id: opts.staffId || null,
    p_idempotency_key: opts.idempotencyKey || null,
    // 代付名單：此人要幫哪些會員付檯費。
    // 後端會把檯費份數算成「自己 1 份 + 代付人數」，並為被代付者建立入座記錄
    // （charged_points=0、paid_by=付款人），消費金額與發票都歸付款人。
    p_pay_for: opts.payFor && opts.payFor.length ? opts.payFor : null,
  })
  if (error) { console.warn('joinSession', error); return { ok: false, reason: error.message } }
  return data || { ok: false }
}

// 互黑檢查（警示用，不阻擋）
export async function checkBlocks(sessionId, memberId) {
  const { data, error } = await supabase.rpc('check_session_blocks_tx', {
    p_session_id: sessionId, p_member_id: memberId,
  })
  if (error) { console.warn('checkBlocks', error); return { ok: false, has_conflict: false } }
  return data || { has_conflict: false }
}

// 啟動桌子（帶桌）
export async function activateSession(sessionId, staffId) {
  const { data, error } = await supabase.rpc('activate_session_tx', {
    p_session_id: sessionId, p_staff_id: staffId || null,
  })
  if (error) { console.warn('activateSession', error); return { ok: false } }
  return data || { ok: false }
}

// 場次詳情（本桌頁）
export async function getSession(sessionId) {
  const { data, error } = await supabase.rpc('get_session_tx', { p_session_id: sessionId })
  if (error) { console.warn('getSession', error); return null }
  return data
}

/* ---------- 台數級距 ---------- */
export async function listStakeLevels(storeId) {
  const { data, error } = await supabase.rpc('list_stake_levels_tx', {
    p_org_id: MIGI_ORG_ID, p_store_id: storeId || getStoreId(),
  })
  if (error) { console.warn('listStakeLevels', error); return [] }
  return data || []
}

/* ---------- 商品 ---------- */
export async function listProducts() {
  const { data, error } = await supabase.rpc('list_products_tx', { p_org_id: MIGI_ORG_ID })
  if (error) { console.warn('listProducts', error); return [] }
  return data || []
}

/* ---------- 會員 ---------- */
export async function searchMembers(keyword) {
  const kw = (keyword || '').trim()
  if (kw.length < 1) return []
  const { data, error } = await supabase.rpc('pos_search_members_tx', {
    p_org_id: MIGI_ORG_ID, p_keyword: kw,
  })
  if (error) { console.warn('searchMembers', error); return [] }
  return data || []
}

// 會員詳情（餘額、等級、可用券）
export async function getMemberDetail(memberId) {
  const { data, error } = await supabase.rpc('pos_member_detail_tx', {
    p_org_id: MIGI_ORG_ID, p_member_id: memberId,
  })
  if (error) { console.warn('getMemberDetail', error); return null }
  return data
}
