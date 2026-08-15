import { useState } from 'react'
import { supabase } from '../lib/supabase'

export default function Login() {
  const [email, setEmail] = useState('')
  const [pw, setPw] = useState('')
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)

  const signIn = async () => {
    if (!email.trim() || !pw) { setErr('請輸入帳號和密碼'); return }
    setBusy(true); setErr('')
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password: pw })
    setBusy(false)
    if (error) setErr('登入失敗，請確認帳號密碼')
  }

  return (
    <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'linear-gradient(160deg, #FFE7EE 0%, #F6F5F4 55%)', padding: 20 }}>
      <div style={{ width: '100%', maxWidth: 380 }}>
        {/* 品牌標誌 */}
        <div style={{ textAlign: 'center', marginBottom: 28 }}>
          <div style={{ fontSize: 30, fontWeight: 800, letterSpacing: 3, color: 'var(--ink)' }}>MIGI</div>
          <div style={{ fontSize: 13, color: 'var(--text3)', marginTop: 4, letterSpacing: 1 }}>總部後台</div>
        </div>

        <div style={{ background: 'var(--surface)', borderRadius: 18, padding: '30px 26px', boxShadow: 'var(--shadow-lg)' }}>
          <label style={{ display: 'block', fontSize: 12, fontWeight: 600, color: 'var(--text2)', marginBottom: 6 }}>帳號</label>
          <input
            type="email" value={email} onChange={(e) => setEmail(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && signIn()}
            placeholder="user@example.com"
            style={{ width: '100%', border: '1.5px solid var(--line)', borderRadius: 10, padding: '11px 13px', fontSize: 14, outline: 'none', marginBottom: 16, background: '#fff', color: 'var(--text)' }}
          />
          <label style={{ display: 'block', fontSize: 12, fontWeight: 600, color: 'var(--text2)', marginBottom: 6 }}>密碼</label>
          <input
            type="password" value={pw} onChange={(e) => setPw(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && signIn()}
            placeholder="••••••••"
            style={{ width: '100%', border: '1.5px solid var(--line)', borderRadius: 10, padding: '11px 13px', fontSize: 14, outline: 'none', marginBottom: err ? 10 : 20, background: '#fff', color: 'var(--text)' }}
          />
          {err && <div style={{ fontSize: 12.5, color: 'var(--danger)', marginBottom: 16 }}>{err}</div>}
          <button
            onClick={signIn} disabled={busy}
            style={{ width: '100%', border: 'none', borderRadius: 10, padding: 13, fontSize: 14.5, fontWeight: 700, background: busy ? 'var(--text4)' : 'var(--ink)', color: '#fff', transition: '.15s' }}
          >{busy ? '登入中…' : '登入'}</button>
        </div>

        <p style={{ textAlign: 'center', fontSize: 11.5, color: 'var(--text4)', marginTop: 18 }}>僅限總部授權人員</p>
      </div>
    </div>
  )
}
