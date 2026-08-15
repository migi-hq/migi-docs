import { useState, useEffect } from 'react'
import { listProducts, createProduct, updateProduct, toggleActive, deleteProduct, CATEGORIES, catLabel, catPrefix, nextSku } from '../lib/products'

export default function Products() {
  const [rows, setRows] = useState([])
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [edit, setEdit] = useState(null) // null=關閉, {}=新增, {...}=編輯
  const [filter, setFilter] = useState('all')

  const load = async () => {
    setLoading(true); setErr('')
    try { setRows(await listProducts()) }
    catch (e) { setErr('載入失敗：' + (e.message || e)) }
    setLoading(false)
  }
  useEffect(() => { load() }, [])

  const shown = filter === 'all' ? rows : rows.filter((r) => r.category === filter)
  const grouped = CATEGORIES.map((c) => ({ ...c, items: shown.filter((r) => r.category === c.value) })).filter((g) => g.items.length > 0)

  return (
    <div>
      {/* 工具列 */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 20 }}>
        <div style={{ display: 'inline-flex', gap: 7 }}>
          {[['all', '全部'], ...CATEGORIES.map((c) => [c.value, c.label])].map(([v, l]) => (
            <div key={v} onClick={() => setFilter(v)}
              style={{ padding: '8px 17px', fontSize: 13, fontWeight: filter === v ? 700 : 600, borderRadius: 99, cursor: 'pointer', color: filter === v ? 'var(--ink)' : 'var(--text2)', background: filter === v ? 'var(--peach)' : '#fff', border: '1.5px solid ' + (filter === v ? 'var(--peach)' : 'var(--line)'), transition: '.12s' }}>{l}</div>
          ))}
        </div>
        <button onClick={() => setEdit({})}
          style={{ marginLeft: 'auto', border: 'none', borderRadius: 10, padding: '10px 18px', fontSize: 13.5, fontWeight: 700, background: 'var(--ink)', color: '#fff' }}>＋ 新增商品</button>
      </div>

      {err && <div style={{ background: '#FDECEA', color: 'var(--danger)', padding: '12px 16px', borderRadius: 10, fontSize: 13, marginBottom: 16 }}>{err}</div>}
      {loading ? (
        <div style={{ padding: 60, textAlign: 'center', color: 'var(--text3)', fontSize: 13 }}>載入中…</div>
      ) : rows.length === 0 ? (
        <div style={{ background: 'var(--surface)', border: '1px solid var(--line)', borderRadius: 14, padding: '48px 32px', textAlign: 'center' }}>
          <div style={{ fontSize: 14, color: 'var(--text2)', marginBottom: 6 }}>還沒有商品</div>
          <div style={{ fontSize: 13, color: 'var(--text3)' }}>點右上「新增商品」建立第一筆。建好後 POS 就能撈到。</div>
        </div>
      ) : (
        grouped.map((g) => (
          <div key={g.value} style={{ marginBottom: 26 }}>
            <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, marginBottom: 10 }}>
              <h2 style={{ fontSize: 14, fontWeight: 700, color: 'var(--text)' }}>{g.label}</h2>
              <span style={{ fontSize: 12, color: 'var(--text4)' }}>{g.hint} · {g.items.length} 項</span>
            </div>
            <div style={{ background: 'var(--surface)', border: '1px solid var(--line)', borderRadius: 14, overflow: 'hidden' }}>
              {/* 表頭 */}
              <div style={{ display: 'grid', gridTemplateColumns: '110px 1fr 90px 80px 90px 88px', gap: 12, padding: '11px 18px', borderBottom: '1px solid var(--peach)', fontSize: 11.5, fontWeight: 700, color: 'var(--ink)', background: 'var(--sakura)' }}>
                <div>貨號</div><div>品名</div><div style={{ textAlign: 'right' }}>價格</div><div style={{ textAlign: 'right' }}>庫存</div><div style={{ textAlign: 'center' }}>狀態</div><div style={{ textAlign: 'right' }}>操作</div>
              </div>
              {g.items.map((r, i) => (
                <div key={r.id} style={{ display: 'grid', gridTemplateColumns: '110px 1fr 90px 80px 90px 88px', gap: 12, padding: '13px 18px', borderBottom: i < g.items.length - 1 ? '1px solid var(--line)' : 'none', fontSize: 13.5, alignItems: 'center', opacity: r.is_active ? 1 : 0.5 }}>
                  <div className="mono" style={{ color: 'var(--text3)', fontSize: 12 }}>{r.sku}</div>
                  <div style={{ fontWeight: 600, color: 'var(--text)' }}>{r.name}</div>
                  <div className="mono" style={{ textAlign: 'right', fontWeight: 700 }}>${r.unit_price}</div>
                  <div className="mono" style={{ textAlign: 'right', color: r.category === 'service' ? 'var(--text4)' : 'var(--text2)' }}>{r.category === 'service' ? '—' : r.stock_qty}</div>
                  <div style={{ textAlign: 'center' }}>
                    <span
                      onClick={() => toggleActive(r.id, !r.is_active).then(load)}
                      title={r.is_active ? '上架中（點擊下架）' : '已下架（點擊上架）'}
                      style={{ display: 'inline-flex', alignItems: 'center', width: 38, height: 22, borderRadius: 999, background: r.is_active ? 'var(--rose)' : '#D6D2CF', cursor: 'pointer', padding: 2, transition: '.18s', verticalAlign: 'middle' }}>
                      <span style={{ width: 18, height: 18, borderRadius: '50%', background: '#fff', boxShadow: '0 1px 2px rgba(0,0,0,.2)', transform: r.is_active ? 'translateX(16px)' : 'translateX(0)', transition: '.18s' }} />
                    </span>
                  </div>
                  <div style={{ textAlign: 'right' }}>
                    <button onClick={() => setEdit(r)} style={{ border: '1px solid var(--line2)', background: '#fff', borderRadius: 8, padding: '5px 12px', fontSize: 12.5, fontWeight: 600, color: 'var(--text2)' }}>編輯</button>
                  </div>
                </div>
              ))}
            </div>
          </div>
        ))
      )}

      {edit !== null && <EditDrawer product={edit} rows={rows} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); load() }} />}
    </div>
  )
}

function EditDrawer({ product, rows, onClose, onSaved }) {
  const isNew = !product.id
  const [f, setF] = useState({
    sku: product.sku || (product.id ? '' : nextSku(product.category || 'fnb', rows)), name: product.name || '', category: product.category || 'fnb',
    unit_price: product.unit_price ?? 0, unit_cost: product.unit_cost ?? 0, stock_qty: product.stock_qty ?? 0,
    is_active: product.is_active !== false, is_available: product.is_available !== false,
  })
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const set = (k, v) => setF((s) => ({ ...s, [k]: v }))

  const save = async () => {
    if (!f.sku.trim()) { setErr('請填貨號'); return }
    if (!f.name.trim()) { setErr('請填品名'); return }
    setBusy(true); setErr('')
    try {
      if (isNew) await createProduct(f)
      else await updateProduct(product.id, f)
      onSaved()
    } catch (e) {
      setErr('儲存失敗：' + (e.message || e))
      setBusy(false)
    }
  }

  const del = async () => {
    if (!confirm(`確定刪除「${product.name}」？此動作無法復原。`)) return
    setBusy(true)
    try { await deleteProduct(product.id); onSaved() }
    catch (e) { setErr('刪除失敗：' + (e.message || e)); setBusy(false) }
  }

  const isService = f.category === 'service'

  return (
    <div style={{ position: 'fixed', inset: 0, background: 'rgba(46,43,44,.35)', zIndex: 1000, display: 'flex', justifyContent: 'flex-end' }}>
      <div style={{ width: 420, maxWidth: '92vw', height: '100%', background: 'var(--surface)', display: 'flex', flexDirection: 'column', boxShadow: '-8px 0 30px rgba(0,0,0,.12)' }}>
        <div style={{ padding: '20px 24px', borderBottom: '1px solid var(--line)', display: 'flex', alignItems: 'center' }}>
          <h2 style={{ fontSize: 16, fontWeight: 700 }}>{isNew ? '新增商品' : '編輯商品'}</h2>
          <button onClick={onClose} style={{ marginLeft: 'auto', background: 'none', border: 'none', fontSize: 22, color: 'var(--text3)' }}>×</button>
        </div>

        <div style={{ flex: 1, overflowY: 'auto', padding: 24 }}>
          <Field label="分類">
            <div style={{ display: 'flex', gap: 6 }}>
              {CATEGORIES.map((c) => (
                <div key={c.value} onClick={() => {
                    set('category', c.value)
                    // 貨號自動帶號：貨號為空、或還是某分類前綴、或是自動生成的號時，重算下一號（不動使用者手打的自訂貨號）
                    const allPrefixes = CATEGORIES.map((x) => x.prefix)
                    const cur = f.sku.trim()
                    const isAutoSku = allPrefixes.some((p) => cur.indexOf(p) === 0 && /^\d*$/.test(cur.slice(p.length)))
                    if (!cur || allPrefixes.includes(cur) || isAutoSku) {
                      set('sku', nextSku(c.value, rows))
                    }
                  }}
                  style={{ flex: 1, textAlign: 'center', padding: '9px 0', borderRadius: 9, fontSize: 13, fontWeight: f.category === c.value ? 700 : 600, cursor: 'pointer', border: '1.5px solid ' + (f.category === c.value ? 'var(--peach)' : 'var(--line)'), background: f.category === c.value ? 'var(--peach)' : '#fff', color: f.category === c.value ? 'var(--ink)' : 'var(--text2)' }}>{c.label}</div>
              ))}
            </div>
          </Field>

          <Field label="貨號 SKU" hint="唯一識別，例如 FNB-DUMP">
            <input value={f.sku} onChange={(e) => set('sku', e.target.value)} placeholder="FNB-XXX" style={inp} />
          </Field>
          <Field label="品名">
            <input value={f.name} onChange={(e) => set('name', e.target.value)} placeholder="例如：珍珠奶茶" style={inp} />
          </Field>
          <Field label="價格" hint="新台幣（元）">
            <div style={{ position: 'relative' }}>
              <span style={{ position: 'absolute', left: 13, top: '50%', transform: 'translateY(-50%)', color: 'var(--text3)', fontSize: 14, fontWeight: 600 }}>$</span>
              <input type="number" value={f.unit_price} onChange={(e) => set('unit_price', Number(e.target.value))} style={{ ...inp, paddingLeft: 26 }} />
            </div>
          </Field>
          <Field label="成本" hint="選填，新台幣（元），用於利潤分析">
            <div style={{ position: 'relative' }}>
              <span style={{ position: 'absolute', left: 13, top: '50%', transform: 'translateY(-50%)', color: 'var(--text3)', fontSize: 14, fontWeight: 600 }}>$</span>
              <input type="number" value={f.unit_cost} onChange={(e) => set('unit_cost', Number(e.target.value))} style={{ ...inp, paddingLeft: 26 }} />
            </div>
          </Field>
          {!isService && (
            <Field label="庫存量" hint="檯費無庫存概念，餐飲/商品才需要">
              <input type="number" value={f.stock_qty} onChange={(e) => set('stock_qty', Number(e.target.value))} style={inp} />
            </Field>
          )}


          {err && <div style={{ background: '#FDECEA', color: 'var(--danger)', padding: '10px 14px', borderRadius: 9, fontSize: 12.5, marginTop: 8 }}>{err}</div>}
        </div>

        <div style={{ padding: 20, borderTop: '1px solid var(--line)', display: 'flex', gap: 10 }}>
          {!isNew && <button onClick={del} disabled={busy} style={{ border: '1px solid #F0C4BE', background: '#fff', color: 'var(--danger)', borderRadius: 10, padding: '11px 16px', fontSize: 13.5, fontWeight: 600 }}>刪除</button>}
          <button onClick={save} disabled={busy} style={{ flex: 1, border: 'none', borderRadius: 10, padding: 12, fontSize: 14, fontWeight: 700, background: busy ? 'var(--text4)' : 'var(--ink)', color: '#fff' }}>{busy ? '儲存中…' : '儲存'}</button>
        </div>
      </div>
    </div>
  )
}

const inp = { width: '100%', border: '1.5px solid var(--line)', borderRadius: 10, padding: '10px 13px', fontSize: 14, outline: 'none', background: '#fff', color: 'var(--text)' }

function Field({ label, hint, children }) {
  return (
    <div style={{ marginBottom: 18 }}>
      <label style={{ display: 'block', fontSize: 12.5, fontWeight: 600, color: 'var(--text2)', marginBottom: 6 }}>{label}{hint && <span style={{ fontWeight: 400, color: 'var(--text4)', marginLeft: 6 }}>{hint}</span>}</label>
      {children}
    </div>
  )
}
