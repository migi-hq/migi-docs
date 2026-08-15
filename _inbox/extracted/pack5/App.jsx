import { useState, useEffect } from 'react'
import { supabase } from './lib/supabase'
import Login from './pages/Login.jsx'
import Products from './pages/Products.jsx'

// 導航模組（第一波先放商品/券，其他標「規劃中」）
const NAV = [
  { key: 'products', label: '商品管理', icon: '□', ready: true },
  { key: 'coupons', label: '優惠券', icon: '◇', ready: false },
  { key: 'members', label: '會員', icon: '○', ready: false },
  { key: 'reports', label: '報表', icon: '△', ready: false },
  { key: 'stores', label: '門市', icon: '▽', ready: false },
]

export default function App() {
  const [session, setSession] = useState(undefined) // undefined=載入中, null=未登入
  const [nav, setNav] = useState('products')

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSession(data.session))
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSession(s))
    return () => sub.subscription.unsubscribe()
  }, [])

  // 載入中
  if (session === undefined) {
    return <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'var(--text3)', fontSize: 13 }}>載入中…</div>
  }
  // 未登入
  if (!session) return <Login />

  const cur = NAV.find((n) => n.key === nav)

  return (
    <div style={{ display: 'flex', minHeight: '100vh' }}>
      {/* 側邊導航 */}
      <aside style={{ width: 220, flexShrink: 0, background: 'var(--surface)', borderRight: '1px solid var(--line)', display: 'flex', flexDirection: 'column', position: 'sticky', top: 0, height: '100vh' }}>
        <div style={{ padding: '22px 22px 18px', borderBottom: '1px solid var(--line)' }}>
          <div style={{ fontSize: 20, fontWeight: 800, letterSpacing: 2, color: 'var(--ink)' }}>MIGI</div>
          <div style={{ fontSize: 11, color: 'var(--text3)', marginTop: 2, letterSpacing: 1 }}>總部後台</div>
        </div>

        <nav style={{ flex: 1, padding: '12px 12px' }}>
          {NAV.map((n) => {
            const on = nav === n.key
            return (
              <div
                key={n.key}
                onClick={() => n.ready && setNav(n.key)}
                style={{
                  display: 'flex', alignItems: 'center', gap: 11, padding: '10px 13px', borderRadius: 10, marginBottom: 3,
                  cursor: n.ready ? 'pointer' : 'default',
                  background: on ? 'var(--sakura)' : 'transparent',
                  color: on ? 'var(--ink)' : n.ready ? 'var(--text2)' : 'var(--text4)',
                  fontWeight: on ? 700 : 500, fontSize: 14, transition: '.12s',
                }}
              >
                <span style={{ fontSize: 15, width: 18, textAlign: 'center' }}>{n.icon}</span>
                <span style={{ flex: 1 }}>{n.label}</span>
                {!n.ready && <span style={{ fontSize: 10, color: 'var(--text4)', background: 'var(--bg)', padding: '2px 7px', borderRadius: 99 }}>規劃中</span>}
              </div>
            )
          })}
        </nav>

        {/* 帳號 + 登出 */}
        <div style={{ padding: 14, borderTop: '1px solid var(--line)' }}>
          <div style={{ fontSize: 12, color: 'var(--text2)', marginBottom: 8, padding: '0 4px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{session.user.email}</div>
          <button
            onClick={() => supabase.auth.signOut()}
            style={{ width: '100%', border: '1px solid var(--line2)', background: '#fff', color: 'var(--text2)', borderRadius: 9, padding: '8px', fontSize: 13, fontWeight: 600 }}
          >登出</button>
        </div>
      </aside>

      {/* 內容區 */}
      <main style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column' }}>
        <header style={{ height: 60, flexShrink: 0, background: 'var(--surface)', borderBottom: '1px solid var(--line)', display: 'flex', alignItems: 'center', padding: '0 28px' }}>
          <h1 style={{ fontSize: 17, fontWeight: 700, color: 'var(--text)' }}>{cur?.label}</h1>
        </header>
        <div style={{ flex: 1, padding: 28, overflowY: 'auto' }}>
          {nav === 'products' ? <Products /> : <Placeholder label={cur?.label} />}
        </div>
      </main>
    </div>
  )
}

// 佔位（各模組實作前的內容）
function Placeholder({ label }) {
  return (
    <div style={{ background: 'var(--surface)', border: '1px solid var(--line)', borderRadius: 14, padding: '48px 32px', textAlign: 'center' }}>
      <div style={{ fontSize: 15, fontWeight: 700, color: 'var(--text)', marginBottom: 8 }}>{label}</div>
      <div style={{ fontSize: 13, color: 'var(--text3)' }}>此模組即將實作。骨架已就緒，登入與導航正常運作。</div>
    </div>
  )
}
