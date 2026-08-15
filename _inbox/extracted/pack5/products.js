import { supabase, MIGI_ORG_ID } from './supabase'

// 分類定義（category 對照顯示名）
export const CATEGORIES = [
  { value: 'service', label: '檯費', hint: '開桌服務費', prefix: 'SER-' },
  { value: 'fnb', label: '餐飲', hint: '飲料、餐點', prefix: 'FNB-' },
  { value: 'merch', label: '商品', hint: '零售商品', prefix: 'MER-' },
]

export function catLabel(v) {
  return (CATEGORIES.find((c) => c.value === v) || {}).label || v
}

export function catPrefix(v) {
  return (CATEGORIES.find((c) => c.value === v) || {}).prefix || ''
}

// 依分類自動產生下一個貨號：前綴 + 3位流水號（SER-001、FNB-002…）
// 掃描該分類現有貨號的數字尾，取最大 +1
export function nextSku(category, products) {
  const prefix = catPrefix(category)
  if (!prefix) return ''
  let max = 0
  for (const p of products) {
    if (p.category !== category || !p.sku) continue
    // 抓貨號尾端的數字（不管前綴長怎樣，取最後一段數字）
    const m = String(p.sku).match(/(\d+)\s*$/)
    if (m) {
      const n = parseInt(m[1], 10)
      if (n > max) max = n
    }
  }
  return prefix + String(max + 1).padStart(3, '0')
}

// 撈全部商品（未刪除的）
export async function listProducts() {
  const { data, error } = await supabase
    .from('products')
    .select('*')
    .is('deleted_at', null)
    .order('category', { ascending: true })
    .order('sku', { ascending: true })
  if (error) throw error
  return data || []
}

// 新增商品
export async function createProduct(p) {
  const { data, error } = await supabase
    .from('products')
    .insert({
      org_id: MIGI_ORG_ID,
      sku: p.sku.trim(),
      name: p.name.trim(),
      category: p.category,
      unit_price: p.unit_price,
      unit_cost: p.unit_cost || 0,
      stock_qty: p.stock_qty || 0,
      is_active: p.is_active !== false,
      is_available: p.is_available !== false,
    })
    .select()
    .single()
  if (error) throw error
  return data
}

// 更新商品
export async function updateProduct(id, p) {
  const { data, error } = await supabase
    .from('products')
    .update({
      sku: p.sku.trim(),
      name: p.name.trim(),
      category: p.category,
      unit_price: p.unit_price,
      unit_cost: p.unit_cost || 0,
      stock_qty: p.stock_qty || 0,
      is_active: p.is_active !== false,
      is_available: p.is_available !== false,
      updated_at: new Date().toISOString(),
    })
    .eq('id', id)
    .select()
    .single()
  if (error) throw error
  return data
}

// 上下架切換（快速）
export async function toggleActive(id, is_active) {
  const { error } = await supabase
    .from('products')
    .update({ is_active, updated_at: new Date().toISOString() })
    .eq('id', id)
  if (error) throw error
}

// 軟刪除
export async function deleteProduct(id) {
  const { error } = await supabase
    .from('products')
    .update({ deleted_at: new Date().toISOString() })
    .eq('id', id)
  if (error) throw error
}
