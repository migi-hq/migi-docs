// 錢包頁（tab0）— 從 App.jsx 抽出
// Wallet + TopupSheet + Statement
import { useState, useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import { deco } from '../lib/components.jsx'
import { supabase } from '../lib/supabase'
import { DragSheet, showToast } from '../lib/ui.jsx'
import { couponStub, couponKind, groupCoupons } from '../lib/helpers.jsx'
import { track, snapWallet } from '../lib/analytics'

function Wallet({ member, go, matching = false, matchInfo = null }) {
  const [d, setD] = useState(null)
  const [sheet, setSheet] = useState(false)
  const [couponCode, setCouponCode] = useState('')
  const [topup, setTopup] = useState(false)
  const [stmt, setStmt] = useState(false)
  const [err, setErr] = useState('')
  const [loading, setLoading] = useState(true)
  useEffect(() => {
    supabase.rpc('get_wallet_tx', { p_member_id: member.id, p_txn_limit: 20 })
      .then(({ data, error }) => { setLoading(false); error ? setErr(error.message) : setD(data) })
  }, [])

  const points = loading ? '…' : (d?.balance ?? 0).toLocaleString()
  const _realCoupons = d?.coupons || []
  const coupons = _realCoupons.length > 0 ? _realCoupons : [
    { name: '新會員免費奶茶', kind: 'fnb', discount_type: 'free', discount_value: null, valid_from: '2026-06-29', valid_to: '2026-07-28' },
    { name: '檯費 9 折券', kind: 'table_discount', discount_type: 'percent', discount_value: 90, max_discount: 45, valid_from: '2026-06-29', valid_to: '2026-07-28' },
    { name: '儲值回饋 50 點', kind: 'table_discount', discount_type: 'fixed', discount_value: 50, valid_from: '2026-07-01', valid_to: '2026-08-31' },
  ]
  const txns = d?.txns || []
  const tile = (t) => ({ table_fee: ['桌', 'var(--brand)'], fnb: ['茶', '#EFE3DA'], topup: ['儲', '#FBEAF0'], merch: ['物', 'var(--gray-4)'], event_fee: ['活', '#EFE3DA'] }[t] || ['點', 'var(--gray-4)'])
  const ftime = (iso) => { const x = new Date(iso); return `${x.getMonth() + 1}/${x.getDate()} ${('0' + x.getHours()).slice(-2)}:${('0' + x.getMinutes()).slice(-2)}` }

  return (
    <>
      {/* 餘額主卡 */}
      <div style={{ padding: '0 20px' }}>
        <div style={{ background: 'var(--brand)', borderRadius: 22, padding: '17px 18px 15px', position: 'relative', overflow: 'hidden' }}>
          {deco}
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <p style={{ margin: 0, fontSize: 'var(--s)', fontWeight: 600, color: 'var(--ink)' }}>我的點數</p>
            <span style={{ background: 'rgba(255,255,255,0.7)', borderRadius: 'var(--r-pill)', padding: '3px 10px', fontSize: 10, fontWeight: 500, color: 'var(--ink)' }}>會員等級: 焦糖布丁</span>
          </div>
          <p style={{ marginTop: 6, marginBottom: 0, fontSize: 'var(--h)', fontWeight: 700, color: 'var(--ink)' }}>
            {points}<span style={{ fontSize: 'var(--l)', fontWeight: 700, marginLeft: 4, color: 'var(--ink)' }}>點</span>
          </p>
          <div style={{ display: 'flex', gap: 8, marginTop: 13 }}>
            <button className="ibtn" style={{ flex: 1, background: 'var(--ink)', padding: '10px 0', fontSize: 'var(--m)', fontWeight: 700, color: 'var(--white)' }} onClick={() => { track('topup_open', snapWallet(d?.balance ?? 0, { from: 'wallet_header' })); setTopup(true) }}>儲值</button>
            <button className="ibtn" style={{ flex: 1, background: 'rgba(255,255,255,0.75)', padding: '10px 0', fontSize: 'var(--m)', fontWeight: 700, color: 'var(--ink)' }} onClick={() => setStmt(true)}>明細</button>
          </div>
        </div>
      </div>

      {/* 優惠券入口 */}
      <div style={{ padding: '12px 20px 0' }}>
        <div onClick={() => setSheet(true)} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', border: '1.5px solid var(--gray-3)', borderRadius: 'var(--r-card)', padding: '11px 14px', cursor: 'pointer' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <span className="itile" style={{ background: 'var(--brand)', width: 30, height: 38, fontSize: 'var(--l)' }}>券</span>
            <div>
              <p style={{ margin: 0, fontSize: 'var(--m)', fontWeight: 700, color: 'var(--ink)' }}>我的優惠券</p>
              <p style={{ margin: 0, fontSize: 'var(--xs)', color: 'var(--gray-1)' }}>{coupons.length} 張可用 · 結帳時自動帶出</p>
            </div>
          </div>
          <span style={{ fontSize: 'var(--s)', fontWeight: 700, color: 'var(--accent)' }}>查看 ›</span>
        </div>
      </div>

      {err && <div style={{ padding: '12px 20px 0', color: 'var(--danger)', fontSize: 13 }}>讀取失敗：{err}</div>}

      {/* 最近消費 */}
      <div style={{ padding: '16px 20px 6px', display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
        <p style={{ margin: 0, fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>最近消費</p>
        <span onClick={() => setStmt(true)} style={{ fontSize: 'var(--s)', color: 'var(--accent)', fontWeight: 700, cursor: 'pointer' }}>全部 ›</span>
      </div>
      <div style={{ padding: '0 20px 16px' }}>
        {txns.length === 0 ? (
          <div style={{ border: '1px dashed var(--field-bd)', background: 'var(--field-bg)', borderRadius: 'var(--r-card)', padding: 20, textAlign: 'center', fontSize: 'var(--s)', color: 'var(--gray-1)' }}>還沒有紀錄</div>
        ) : txns.map((t, i) => {
          const [ic, bg] = tile(t.type)
          const last = i === txns.length - 1
          const amt = (t.amount > 0 ? '+' : '') + Number(t.amount).toLocaleString()
          return (
            <div key={t.id} className="irow" style={last ? { borderBottom: 'none' } : undefined}>
              <span className="itile" style={{ background: bg, width: 30, height: 38, fontSize: 'var(--l)' }}>{ic}</span>
              <div style={{ flex: 1 }}>
                <p style={{ margin: 0, fontSize: 'var(--m)', color: 'var(--ink)' }}>{(t.note || t.label || '').replace('[測試]', '')}</p>
                <p style={{ margin: 0, fontSize: 'var(--xs)', color: 'var(--gray-1)' }}>{ftime(t.created_at)}</p>
              </div>
              <span style={{ fontSize: 'var(--m)', fontWeight: 700, color: t.amount < 0 ? 'var(--ink)' : 'var(--accent)' }}>{amt}</span>
            </div>
          )
        })}
      </div>
    
      {sheet && (
        <DragSheet onClose={() => setSheet(false)} title="優惠券">
          {/* 券碼輸入 */}
          <div style={{ display: 'flex', gap: 8, marginBottom: 18 }}>
            <input
              value={couponCode}
              onChange={(e) => setCouponCode(e.target.value)}
              placeholder="輸入優惠代碼"
              style={{ flex: 1, border: '1.5px solid var(--gray-3)', borderRadius: 'var(--r-field)', padding: '12px 15px', fontSize: 14, color: 'var(--ink)', outline: 'none', background: 'var(--white)', fontFamily: 'inherit' }}
            />
            <button
              onClick={() => { if (couponCode.trim()) { showToast('優惠代碼功能開發中'); setCouponCode('') } }}
              style={{ flex: '0 0 72px', border: 'none', borderRadius: 'var(--r-field)', background: couponCode.trim() ? 'var(--accent)' : 'var(--gray-4)', color: couponCode.trim() ? 'var(--white)' : '#B4AEA9', fontSize: 15, fontWeight: 700, cursor: 'pointer', fontFamily: 'inherit', transition: '.15s' }}
            >新增</button>
          </div>

          {coupons.length === 0 ? (
            <div style={{ border: '1px dashed var(--field-bd)', background: 'var(--field-bg)', borderRadius: 'var(--r-card)', padding: 20, textAlign: 'center', color: 'var(--gray-2)', fontSize: 12 }}>目前沒有優惠券</div>
          ) : groupCoupons(coupons).map((c) => {
            const stub = couponStub(c)
            const fmtD = (iso) => { if (!iso) return ''; const x = new Date(iso); return `${x.getFullYear()}/${('0' + (x.getMonth() + 1)).slice(-2)}/${('0' + x.getDate()).slice(-2)}` }
            return (
              <div key={c.key} style={{ display: 'flex', alignItems: 'stretch', marginBottom: 11, border: '1.5px solid var(--brand)', borderRadius: 'var(--r-card)', overflow: 'hidden', background: 'var(--white)' }}>
                {/* 左側 stub 色塊 */}
                <div style={{ background: 'var(--brand)', width: 66, flex: '0 0 66px', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', color: 'var(--ink)', borderRadius: '13px 0 0 13px' }}>
                  <span style={{ fontSize: stub.sm ? 16 : 20, fontWeight: 700, lineHeight: 1 }}>{stub.big}</span>
                  <span style={{ fontSize: 10, marginTop: 2 }}>{stub.u}</span>
                </div>
                {/* 右側資訊 */}
                <div style={{ flex: 1, padding: '11px 13px', minWidth: 0 }}>
                  <p style={{ margin: 0, fontSize: 14, fontWeight: 700, color: 'var(--ink)' }}>{c.name}{c.qty > 1 && <span style={{ color: 'var(--accent)', marginLeft: 6 }}>×{c.qty}</span>}</p>
                  <p style={{ margin: '3px 0 0', fontSize: 11, color: 'var(--gray-1)' }}>{couponKind(c.kind)} · 結帳時可用</p>
                  {(c.valid_from || c.valid_to) && (
                    <p style={{ margin: '7px 0 0', fontSize: 11, color: 'var(--gray-2)' }}>有效期限 {fmtD(c.valid_from)} – {fmtD(c.valid_to)}</p>
                  )}
                </div>
              </div>
            )
          })}

          {/* 提示移到最下面 */}
          <p style={{ margin: '14px 0 0', fontSize: 11, color: '#B4AEA9', textAlign: 'center' }}>券只折抵檯費／餐飲／派車等服務費 · 結帳時自動帶出</p>
        </DragSheet>
      )}
      {topup && <TopupSheet balance={d?.balance ?? 0} onClose={() => setTopup(false)} />}
      {stmt && <Statement balance={d?.balance ?? 0} txns={txns} onClose={() => setStmt(false)} />}
    </>
  )
}

/* ===== 可拖曳底部抽屜（往上拖展開、往下拖收起/關閉，白塊跟著手指） ===== */
// 看自己版人物卡（點頂部頭像開）
/* ===== 寶貝牌 UI 元件 ===== */

// 寶貝牌卡：自己(own=true 顯示成就+更換) / 別人(own=false 唯讀)

function TopupSheet({ balance, onClose }) {
  const AMTS = [{ v: 150, b: '+0 贈點' }, { v: 500, b: '+0 贈點' }, { v: 1000, b: '+50 贈點' }, { v: 2000, b: '+150 贈點' }, { v: 3000, b: '+300 贈點' }]
  const PAYS = ['LINE Pay', '信用卡', '現金支付']
  const [amt, setAmt] = useState(1000)
  const [pay, setPay] = useState('LINE Pay')
  const [customOpen, setCustomOpen] = useState(false)
  const [customVal, setCustomVal] = useState('')
  // 放棄率追蹤：開了儲值面板卻沒完成的人，是最值得回頭撈的一群
  const openedAt = useRef(Date.now())
  const done = useRef(false)

  function close() {
    if (!done.current) {
      track('topup_abandon', snapWallet(balance, {
        last_amount: amt, last_pay: pay,
        seconds: Math.round((Date.now() - openedAt.current) / 1000),
      }))
    }
    onClose()
  }

  function confirm() {
    track('topup_confirm', snapWallet(balance, {
      amount: amt, pay_method: pay,
      is_custom: AMTS.every((a) => a.v !== amt),
      seconds: Math.round((Date.now() - openedAt.current) / 1000),
    }))
    if (pay === '現金支付') {
      // 導向臨櫃：不算放棄，是另一條轉換路徑
      done.current = true
      track('topup_to_counter', { amount: amt })
      return alert('請到櫃台付現，由店員為你加值')
    }
    alert('儲值金流串接後開放（' + pay + ' · ' + amt.toLocaleString() + ' 點）')
  }
  return (
    <DragSheet onClose={close} title="儲值點數" subtitle="點數用於檯費、餐飲、派車等服務 · 不可提領、不可換現">
      <div style={{ background: 'var(--field-bg)', borderRadius: 'var(--r-card)', padding: '13px 15px', display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16 }}>
        <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--ink)' }}>目前餘額</span>
        <span style={{ fontSize: 20, fontWeight: 700, color: 'var(--ink)' }}>{balance.toLocaleString()} 點</span>
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3,1fr)', gap: 10 }}>
        {AMTS.map((a) => (
          <div key={a.v} onClick={() => { track('topup_amount_select', { amount: a.v, is_custom: false }); setAmt(a.v) }}
            style={{ border: amt === a.v ? '1.5px solid var(--accent)' : '1.5px solid var(--gray-3)', background: amt === a.v ? 'var(--brand-light)' : 'var(--white)', borderRadius: 'var(--r-card)', padding: '14px 0', textAlign: 'center', cursor: 'pointer' }}>
            <div style={{ fontSize: 18, fontWeight: 700, color: 'var(--ink)' }}>{a.v.toLocaleString()}</div>
            {a.b && <div style={{ fontSize: 10, color: 'var(--accent)', marginTop: 3 }}>{a.b}</div>}
          </div>
        ))}
        {(() => {
          const isCustom = AMTS.every((a) => a.v !== amt)
          return (
            <div onClick={() => { setCustomVal(isCustom ? String(amt) : ''); setCustomOpen(true) }}
              style={{ border: isCustom ? '1.5px solid var(--accent)' : '1.5px solid var(--gray-3)', background: isCustom ? 'var(--brand-light)' : 'var(--white)', borderRadius: 'var(--r-card)', padding: '14px 0', textAlign: 'center', cursor: 'pointer' }}>
              <div style={{ fontSize: 18, fontWeight: 700, color: isCustom ? 'var(--ink)' : 'var(--gray-1)' }}>{isCustom ? amt.toLocaleString() : '自訂'}</div>
              <div style={{ fontSize: 10, color: 'var(--accent)', marginTop: 3 }}>{isCustom ? '修改' : '\u00A0'}</div>
            </div>
          )
        })()}
      </div>
      <p style={{ fontSize: 13, color: 'var(--gray-1)', margin: '18px 0 8px' }}>付款方式</p>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        {PAYS.map((p) => (
          <div key={p} onClick={() => { track('topup_pay_select', { pay_method: p }); setPay(p) }}
            style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', border: pay === p ? '2px solid var(--ink)' : '1.5px solid var(--gray-3)', borderRadius: 'var(--r-card)', padding: '14px 16px', cursor: 'pointer' }}>
            <span style={{ fontSize: 15, fontWeight: 600, color: 'var(--ink)', display: 'flex', flexDirection: 'column' }}>
              {p}{p === '現金支付' && <span style={{ fontSize: 11, fontWeight: 400, color: 'var(--gray-1)', marginTop: 3 }}>臨櫃付現，請櫃台人員為你加值</span>}
            </span>
            <span style={{ fontSize: 14, color: pay === p ? 'var(--ink)' : 'var(--gray-2)' }}>{pay === p ? '●' : '○'}</span>
          </div>
        ))}
      </div>
      <button onClick={confirm} style={{ width: '100%', marginTop: 18, background: 'var(--ink)', color: 'var(--white)', border: 'none', borderRadius: 'var(--r-card)', padding: 15, fontSize: 16, fontWeight: 700, cursor: 'pointer' }}>
        確認儲值 {amt.toLocaleString()} 點
      </button>
      {customOpen && (
        <div onClick={(e) => { if (e.target === e.currentTarget) setCustomOpen(false) }}
          style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: 'rgba(46,43,44,0.45)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 1100, padding: 28 }}>
          <div style={{ background: 'var(--white)', borderRadius: 20, width: '100%', maxWidth: 320, padding: '22px 20px' }}>
            <p style={{ margin: '0 0 4px', fontSize: 16, fontWeight: 700, color: 'var(--ink)' }}>自訂儲值點數</p>
            <p style={{ margin: '0 0 14px', fontSize: 12, color: 'var(--gray-2)' }}>輸入想儲值的點數</p>
            <input autoFocus inputMode="numeric" value={customVal}
              onChange={(e) => setCustomVal(e.target.value.replace(/[^0-9]/g, ''))}
              placeholder="例如 1500"
              style={{ width: '100%', fontSize: 18, fontWeight: 700, padding: '12px 14px', border: '1.5px solid var(--gray-3)', borderRadius: 'var(--r-field)', background: 'var(--field-bg)', color: 'var(--ink)', outline: 'none', textAlign: 'center' }} />
            <div style={{ display: 'flex', gap: 10, marginTop: 16 }}>
              <button onClick={() => setCustomOpen(false)} style={{ flex: 1, background: 'var(--gray-4)', color: 'var(--gray-1)', border: 'none', borderRadius: 'var(--r-field)', padding: 13, fontSize: 15, fontWeight: 600, cursor: 'pointer' }}>取消</button>
              <button onClick={() => { const n = parseInt(customVal, 10); if (n > 0) { setAmt(n); setCustomOpen(false) } }}
                style={{ flex: 1, background: 'var(--ink)', color: 'var(--white)', border: 'none', borderRadius: 'var(--r-field)', padding: 13, fontSize: 15, fontWeight: 700, cursor: 'pointer' }}>確定</button>
            </div>
          </div>
        </div>
      )}
    </DragSheet>
  )
}

/* ===== 明細整頁 ===== */

function Statement({ balance, txns, onClose }) {
  const [filter, setFilter] = useState('all')
  const tile = (t) => ({ table_fee: ['桌', 'var(--brand)'], fnb: ['茶', '#EFE3DA'], topup: ['儲', '#FBEAF0'], merch: ['物', 'var(--gray-4)'], event_fee: ['活', '#EFE3DA'], adjust: ['贈', '#FBEAF0'] }[t] || ['點', 'var(--gray-4)'])
  const list = txns.filter((t) => filter === 'all' ? true : filter === 'topup' ? t.amount > 0 : t.amount < 0)
  const groups = {}
  list.forEach((t) => {
    const d = new Date(t.created_at); const today = new Date()
    const key = d.toDateString() === today.toDateString() ? '今天' : `${d.getMonth() + 1} 月 ${d.getDate()} 日`
    ;(groups[key] = groups[key] || []).push(t)
  })
  const ftime = (iso) => { const x = new Date(iso); return `${('0' + x.getHours()).slice(-2)}:${('0' + x.getMinutes()).slice(-2)}` }
  return createPortal(
    <div className="sheet-anim" style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: 'var(--white)', zIndex: 1000, display: 'flex', flexDirection: 'column' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '16px 16px 12px', borderBottom: '0.5px solid var(--gray-4)' }}>
        <button onClick={onClose} style={{ background: 'none', border: 'none', fontSize: 22, color: 'var(--ink)', cursor: 'pointer', lineHeight: 1, padding: '0 4px' }}>‹</button>
        <span style={{ fontSize: 17, fontWeight: 700, color: 'var(--ink)' }}>點數明細</span>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: 16 }}>
        <div style={{ background: 'var(--brand)', borderRadius: 18, padding: '16px 18px', marginBottom: 14 }}>
          <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--ink)' }}>目前餘額</div>
          <div style={{ fontSize: 30, fontWeight: 700, color: 'var(--ink)', marginTop: 2 }}>{balance.toLocaleString()}<span style={{ fontSize: 14, fontWeight: 700, marginLeft: 4, color: 'var(--ink)' }}>點</span></div>
        </div>
        <div style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
          {[['all', '全部'], ['topup', '儲值'], ['spend', '消費']].map(([k, label]) => (
            <span key={k} onClick={() => setFilter(k)}
              style={{ border: filter === k ? '1px solid var(--brand)' : '1px solid var(--gray-3)', background: filter === k ? 'var(--brand)' : 'var(--white)', color: filter === k ? 'var(--ink)' : 'var(--gray-1)', fontWeight: filter === k ? 600 : 400, borderRadius: 'var(--r-pill)', padding: '6px 16px', fontSize: 13, cursor: 'pointer' }}>{label}</span>
          ))}
        </div>
        {list.length === 0 ? <p style={{ color: 'var(--gray-2)', fontSize: 13, textAlign: 'center', padding: 24 }}>沒有紀錄</p> :
          Object.keys(groups).map((day) => (
            <div key={day}>
              <p style={{ fontSize: 12, color: 'var(--gray-2)', margin: '16px 0 4px', fontWeight: 600 }}>{day}</p>
              {groups[day].map((t, i) => {
                const [ic, bg] = tile(t.type); const last = i === groups[day].length - 1
                const amt = (t.amount > 0 ? '+' : '') + Number(t.amount).toLocaleString()
                return (
                  <div key={t.id} className="irow" style={last ? { borderBottom: 'none' } : undefined}>
                    <span className="itile" style={{ background: bg, width: 30, height: 38, fontSize: 'var(--l)' }}>{ic}</span>
                    <div style={{ flex: 1 }}>
                      <p style={{ margin: 0, fontSize: 'var(--m)', color: 'var(--ink)' }}>{(t.note || t.label || '').replace('[測試]', '')}</p>
                      <p style={{ margin: 0, fontSize: 'var(--xs)', color: 'var(--gray-1)' }}>{ftime(t.created_at)}</p>
                    </div>
                    <span style={{ fontSize: 'var(--m)', fontWeight: 700, color: t.amount < 0 ? 'var(--ink)' : 'var(--accent)' }}>{amt}</span>
                  </div>
                )
              })}
            </div>
          ))}
      </div>
    </div>,
    document.body
  )
}

export { Wallet };
