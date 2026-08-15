// 跨群組共用元件 — 從 App.jsx 抽出
// ProfileCardOther: 他人個人卡（被 Buddies / 獎勵頁群組 / Stats 共用）
import { useState, useEffect } from 'react'
import DefaultAvatar from '../DefaultAvatar'
import { fmtRank, FEATURES, distanceKm, fmtDistance, isStoreOpen, cityFromLatLng } from './helpers.jsx'
import { DragSheet, SearchIcon, ThumbIcon, showToast } from './ui.jsx'
import { sendBuddyInvite, blockMember, removeBuddy } from './social.js'
import { TileFace, tileLabel } from './tiles.jsx'
import { fetchStores } from './social.js'
import { fetchMyProfile } from './profile.js'

function ProfileCardOther({ b, onClose }) {
    const [blOpen, setBlOpen] = useState(false)
    const [invited, setInvited] = useState(false)
    const canPull = b.rel === 'buddy' || b.rel === 'team'
    const played = (b.tog || 0) > 0   // 同桌對局過才能邀成牌咖
    const relTxt = b.rel === 'buddy' ? '已加為牌咖好友' : b.rel === 'team' ? '同團成員' : '還不是牌咖'
    const loss = Math.max(0, b.tog - b.win)
    const hd = { margin: '0 0 12px', fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }
    const pill = (txt, color, bg, bd) => <span style={{ display: 'inline-flex', alignItems: 'center', height: 22, fontSize: 11, fontWeight: 700, color, background: bg, border: bd || 'none', borderRadius: 'var(--r-pill)', padding: '0 11px' }}>{txt}</span>
    const tg = (txt, pink) => <span key={txt} style={{ fontSize: 'var(--xs)', fontWeight: 700, background: pink ? 'var(--brand-light)' : 'var(--field-bg)', color: 'var(--ink)', borderRadius: 'var(--r-pill)', padding: '5px 13px' }}>{txt}</span>
    return (
      <DragSheet onClose={onClose} title="個人檔案">
          {/* Hero */}
          <div style={{ background: 'var(--brand-light)', borderRadius: 'var(--r-lg)', padding: '18px 16px', position: 'relative' }}>
            {/* 獲讚數（右上）★之後接後端讀真實累計 */}
            <span style={{ position: 'absolute', top: 14, right: 14, display: 'inline-flex', alignItems: 'center', gap: 5, background: 'rgba(255,255,255,0.7)', borderRadius: 'var(--r-pill)', padding: '4px 11px', fontSize: 12, fontWeight: 700, color: 'var(--ink)' }}><ThumbIcon size={13} color="var(--ink)" /> {b.likes != null ? b.likes : 36}</span>
            <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
              <DefaultAvatar size={60} />
              <div>
                <span style={{ fontSize: 12, fontWeight: 700, color: 'var(--ink)' }}>「早鳥達人」</span>
                <p style={{ margin: '4px 0 0', fontSize: 'var(--xl)', fontWeight: 700, color: 'var(--ink)' }}>{b.ini}</p>
                {canPull && <div style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontSize: 13, fontWeight: 700, color: 'var(--accent)', marginTop: 6 }}><span style={{ width: 15, height: 15, borderRadius: '50%', background: 'var(--accent)', color: 'var(--white)', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 10 }}>{'\u2713'}</span>{relTxt}</div>}
                <div style={{ display: 'flex', gap: 6, marginTop: 8, flexWrap: 'wrap' }}>
                  <span style={{ display: 'inline-flex', alignItems: 'center', height: 22, fontSize: 11, fontWeight: 700, color: 'var(--ink)', background: 'rgba(255,255,255,0.7)', borderRadius: 'var(--r-pill)', padding: '0 11px' }}>{fmtRank(b.rank)}</span>
                </div>
              </div>
            </div>
          </div>
          {/* 關於 */}
          <div style={{ padding: '16px 0 14px' }}>
            <p style={hd}>關於{b.ini}</p>
            <div style={{ background: 'var(--field-bg)', borderRadius: 'var(--r-field)', padding: '13px 14px', fontSize: 'var(--s)', color: 'var(--ink)', lineHeight: 1.7, marginBottom: 14 }}>「早上場固定班底，喜歡安靜認真打～」</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
              {tg('早鳥', true)}{tg('平日玩家', true)}{tg('咖啡派', true)}{tg('穩扎穩打', true)}{tg('台麻')}{tg('美麻')}{tg('無花')}{tg('10/10')}
            </div>
          </div>
          {/* 你和她 */}
          <div style={{ padding: '14px 0', borderTop: '1px solid var(--field-bg)' }}>
            <p style={hd}>你和{b.ini}</p>
            <div style={{ display: 'flex' }}>
              {[[b.tog, '同桌次數'], [b.win + ' / ' + loss, '勝 / 負'], [b.rank, '段位']].map(([n, l]) => (
                <div key={l} style={{ flex: 1, textAlign: 'center' }}>
                  <p style={{ margin: 0, fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>{n}</p>
                  <p style={{ margin: '3px 0 0', fontSize: 'var(--xs)', color: 'var(--gray-1)' }}>{l}</p>
                </div>
              ))}
            </div>
          </div>
          {/* 牌風 3維 */}
          <div style={{ padding: '14px 0', borderTop: '1px solid var(--field-bg)' }}>
            <p style={hd}>{b.ini}的牌風</p>
            <div style={{ marginBottom: 14 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 9 }}>
                <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#C2607A" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z" /></svg>
                <p style={{ margin: 0, fontSize: 'var(--xl)', fontWeight: 700, color: 'var(--accent)' }}>社交型玩家</p>
              </div>
              <p style={{ margin: '6px 0 0', fontSize: 'var(--xs)', color: 'var(--gray-1)', lineHeight: 1.6 }}>出牌快、愛聊天，喜歡輕鬆熱鬧的牌局</p>
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              <svg width="150" height="138" viewBox="-14 -12 128 124" style={{ flex: '0 0 auto', marginLeft: -6 }}>
                <polygon points="55,12 92,76 18,76" fill="none" stroke="#ECE7E4" strokeWidth="1" />
                <polygon points="55,33 74,65 36,65" fill="none" stroke="#F2F0EE" strokeWidth="1" />
                <line x1="55" y1="55" x2="55" y2="12" stroke="#F2F0EE" /><line x1="55" y1="55" x2="92" y2="76" stroke="#F2F0EE" /><line x1="55" y1="55" x2="18" y2="76" stroke="#F2F0EE" />
                <polygon points="55,33 80,68 38,60" fill="rgba(250,214,220,.6)" stroke="#C2607A" strokeWidth="2" />
                <text x="55" y="6" fill="#7A7572" fontSize="11" textAnchor="middle">速度</text>
                <text x="100" y="85" fill="#7A7572" fontSize="11" textAnchor="middle">氣氛</text>
                <text x="10" y="85" fill="#7A7572" fontSize="11" textAnchor="middle">規則</text>
              </svg>
              <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 13 }}>
                {[['出牌速度', '普通', 66], ['打牌氣氛', '安靜', 33], ['規則態度', '嚴格', 33]].map(([k, v, w]) => (
                  <div key={k}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, marginBottom: 5 }}><span style={{ color: 'var(--gray-1)' }}>{k}</span><span style={{ color: 'var(--ink)', fontWeight: 700 }}>{v}</span></div>
                    <div style={{ height: 6, background: 'var(--gray-4)', borderRadius: 'var(--r-pill)', overflow: 'hidden' }}><div style={{ height: '100%', width: w + '%', background: 'var(--accent)', borderRadius: 'var(--r-pill)' }} /></div>
                  </div>
                ))}
              </div>
            </div>
          </div>
          {/* 最近亮點 */}
          <div style={{ padding: '14px 0', borderTop: '1px solid var(--field-bg)' }}>
            <p style={hd}>最近亮點</p>
            <div style={{ background: 'var(--brand)', borderRadius: 'var(--r-card)', padding: 15, display: 'flex', alignItems: 'center', gap: 14 }}>
              <div style={{ flex: 1 }}>
                <p style={{ margin: 0, fontSize: 'var(--xs)', color: 'var(--ink)' }}>近期最大台的一手</p>
                <p style={{ margin: '5px 0 0', fontSize: 22, fontWeight: 800, color: 'var(--ink)' }}>清一色</p>
                <p style={{ margin: '4px 0 0', fontSize: 'var(--xs)', color: 'var(--ink)' }}>連 2 莊</p>
              </div>
              <div style={{ textAlign: 'center', paddingLeft: 14, borderLeft: '1px solid rgba(46,43,44,.15)' }}>
                <p style={{ margin: 0, fontSize: 26, fontWeight: 800, color: 'var(--ink)', lineHeight: 1 }}>8</p>
                <p style={{ margin: '3px 0 0', fontSize: 'var(--xs)', color: 'var(--ink)' }}>台</p>
              </div>
            </div>
          </div>
          {/* 寶貝牌（唯讀） */}
          <div style={{ padding: '14px 0', borderTop: '1px solid var(--field-bg)' }}>
            <p style={hd}>{b.ini}的寶貝牌</p>
            <BabyTileCard tile={b.baby || '8萬'} note={b.babyNote || '發財就靠這張！'} own={false} />
          </div>
          {/* 社交按鈕 */}
          <div style={{ padding: '14px 0 0' }}>
            {canPull ? (
              <>
                {b.rel === 'buddy' && <button className="ibtn" onClick={() => alert('邀 ' + b.ini + ' 加入牌咖團')} style={{ background: 'var(--brand)', color: 'var(--ink)', padding: '12px 0', fontSize: 'var(--m)', width: '100%' }}>邀進牌咖團</button>}
                {b.rel === 'buddy' && <button className="ibtn" onClick={async () => { if (!window.confirm(`確定要將「${b.ini}」解除牌咖嗎？對方不會收到通知`)) return; await removeBuddy(b.id); onClose(); showToast('已解除牌咖') }} style={{ marginTop: 9, background: 'var(--gray-4)', color: 'var(--gray-1)', padding: '12px 0', fontSize: 'var(--m)', width: '100%', fontWeight: 700 }}>解除牌咖</button>}
              </>
            ) : FEATURES.addBuddy ? (
              played ? (
                <>
                  <button className="ibtn" disabled={invited} onClick={async () => { setInvited(true); await sendBuddyInvite(b.id, 'profile'); showToast('已向 ' + b.ini + ' 送出牌咖邀請') }} style={{ background: invited ? 'var(--gray-4)' : 'var(--brand)', color: invited ? 'var(--gray-2)' : 'var(--ink)', padding: '12px 0', fontSize: 'var(--m)', width: '100%', fontWeight: 700 }}>{invited ? '已邀請' : '＋ 加牌咖'}</button>
                  <p style={{ margin: '8px 0 0', fontSize: 'var(--xs)', color: 'var(--gray-1)', textAlign: 'center' }}>對方接受邀請後，才會成為牌咖</p>
                </>
              ) : (
                <p style={{ margin: 0, fontSize: 'var(--xs)', color: 'var(--gray-2)', textAlign: 'center', background: 'var(--field-bg)', borderRadius: 'var(--r-field)', padding: '12px 0' }}>同桌對局過，才能加牌咖</p>
              )
            ) : null}
            <button onClick={() => setBlOpen(true)} style={{ marginTop: 9, width: '100%', background: 'var(--white)', border: '1px dashed #CFC9C5', color: 'var(--gray-1)', borderRadius: 'var(--r-pill)', padding: '10px 0', fontSize: 13, fontWeight: 700, cursor: 'pointer' }}>不想再跟 {b.ini} 同桌</button>
          </div>
          {blOpen && <BlacklistSheet name={b.ini} targetId={b.id} onClose={() => setBlOpen(false)} onBlocked={onClose} />}
      </DragSheet>
    )
  }

function BabyTileCard({ tile, note, own, onChange, ownerName }) {
  if (!tile) {
    // 自己還沒設定 → 引導設定
    return (
      <div onClick={onChange} style={{ display: 'flex', alignItems: 'center', gap: 14, background: 'var(--field-bg)', borderRadius: 'var(--r-card)', padding: '14px 16px', cursor: 'pointer' }}>
        <span style={{ width: 44, height: 58, borderRadius: 'var(--r-sm)', border: '1.5px dashed var(--field-bd)', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 24, color: '#C9C4C1', flex: '0 0 auto' }}>{'\uff1f'}</span>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 'var(--s)', fontWeight: 700, color: 'var(--gray-2)' }}>還沒設定寶貝牌</div>
        </div>
      </div>
    )
  }
  return (
    <>
      <div style={{ display: 'flex', alignItems: 'center', gap: 14, background: 'var(--field-bg)', borderRadius: 'var(--r-card)', padding: '14px 16px' }}>
        <TileFace t={tile} />
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 'var(--m)', fontWeight: 700, color: 'var(--ink)' }}>{tileLabel(tile)}</div>
          {note && <div style={{ fontSize: 'var(--xs)', color: 'var(--gray-1)', marginTop: 2 }}>{'\u300c' + note + '\u300d'}</div>}
        </div>
      </div>
    </>
  )
}

// 選牌抽屜

function BlacklistSheet({ name, targetId, onClose, onBlocked }) {
  const SOFT = ['出牌太快', '出牌太慢/慢手', '太愛聊天/說教', '太安靜/不講話', '太認真/愛計較', '很拐', '新手不懂規則', '年齡差距']
  const HARD = ['牌品差（摔牌/擺臉色）', '遲到/放鴿子', '言語騷擾/肢體碰觸', '很多小動作（切牌/惡碰）', '衛生習慣差/體味重', '賒帳/跑帳', '疑似作弊', '沒原因，就是不喜歡']
  const [picked, setPicked] = useState([])
  const [otherMode, setOtherMode] = useState(false)
  const [otherTxt, setOtherTxt] = useState('')
  const toggle = (r) => setPicked((p) => p.includes(r) ? p.filter((x) => x !== r) : [...p, r])
  const Opt = ({ r }) => {
    const on = picked.includes(r)
    return (
      <div onClick={() => toggle(r)} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', border: on ? '2px solid var(--ink)' : '1.5px solid var(--gray-3)', borderRadius: 'var(--r-field)', padding: '13px 15px', marginBottom: 9, fontSize: 14, fontWeight: on ? 700 : 400, color: 'var(--ink)', cursor: 'pointer' }}>
        <span>{r}</span>
        <span style={{ width: 20, height: 20, borderRadius: 6, border: on ? '1.5px solid var(--ink)' : '1.5px solid #CFC9C5', background: on ? 'var(--ink)' : 'var(--white)', display: 'flex', alignItems: 'center', justifyContent: 'center', flex: '0 0 20px' }}>{on && <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="3.5" strokeLinecap="round" strokeLinejoin="round"><path d="M20 6 9 17l-5-5" /></svg>}</span>
      </div>
    )
  }
  const otherOn = otherMode && !!otherTxt
  return (
    <DragSheet onClose={onClose} title="為什麼不想跟他同桌？" subtitle="可複選，只有你看得到（對方不會知道）">
      <p style={{ margin: '0 0 8px', fontSize: 'var(--xs)', color: 'var(--gray-2)', fontWeight: 700 }}>不太合拍</p>
      {SOFT.map((r) => <Opt key={r} r={r} />)}
      <p style={{ margin: '6px 0 8px', fontSize: 'var(--xs)', color: 'var(--gray-2)', fontWeight: 700 }}>行為問題</p>
      {HARD.map((r) => <Opt key={r} r={r} />)}
      {!otherMode ? (
        <div onClick={() => setOtherMode(true)} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', border: '1.5px solid var(--gray-3)', borderRadius: 'var(--r-field)', padding: '13px 15px', marginBottom: 9, fontSize: 14, color: 'var(--ink)', cursor: 'pointer' }}>
          <span>其他（可填）</span>
          <span style={{ width: 20, height: 20, borderRadius: 6, border: '1.5px solid #CFC9C5', background: 'var(--white)', flex: '0 0 20px' }} />
        </div>
      ) : (
        <div style={{ border: '2px solid var(--ink)', borderRadius: 'var(--r-field)', padding: '13px 15px', marginBottom: 9, display: 'flex', alignItems: 'center', gap: 10 }}>
          <input autoFocus value={otherTxt} onChange={(e) => setOtherTxt(e.target.value)} placeholder="輸入原因…" style={{ flex: 1, border: 'none', background: 'transparent', fontSize: 14, color: 'var(--ink)', fontFamily: 'inherit', outline: 'none' }} />
          <span style={{ width: 20, height: 20, borderRadius: 6, border: otherOn ? '1.5px solid var(--ink)' : '1.5px solid #CFC9C5', background: otherOn ? 'var(--ink)' : 'var(--white)', display: 'flex', alignItems: 'center', justifyContent: 'center', flex: '0 0 20px' }}>{otherOn && <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="3.5" strokeLinecap="round" strokeLinejoin="round"><path d="M20 6 9 17l-5-5" /></svg>}</span>
        </div>
      )}
      <p style={{ margin: '4px 0 0', fontSize: 10, color: 'var(--gray-2)', textAlign: 'center', lineHeight: 1.6 }}>原因只有 MIGI 看得到 · 對方不會知道</p>
      <button onClick={async () => { if (!window.confirm(`確定要將「${name}」加入黑名單嗎？之後不會配到同桌，可隨時在設定中解除`)) return; await blockMember(targetId); onClose(); onBlocked && onBlocked(); showToast('已加入黑名單') }} style={{ width: '100%', marginTop: 14, background: 'var(--ink)', color: 'var(--white)', border: 'none', borderRadius: 'var(--r-pill)', padding: '13px 0', fontSize: 15, fontWeight: 700, cursor: 'pointer' }}>加入黑名單</button>
      <button onClick={onClose} style={{ width: '100%', marginTop: 8, background: 'var(--gray-4)', color: 'var(--gray-1)', border: 'none', borderRadius: 'var(--r-pill)', padding: '13px 0', fontSize: 15, fontWeight: 600, cursor: 'pointer' }}>取消</button>
    </DragSheet>
  )
}

function StoreRow({ s, selected, onPick, isDefault, myCoord }) {
  const km = myCoord ? distanceKm(myCoord.lat, myCoord.lng, s.lat, s.lng) : null
  const open = isStoreOpen(s.open_time, s.close_time)
  return (
    <div onClick={() => onPick(s)} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '13px 14px', borderTop: '.5px solid var(--gray-4)', cursor: 'pointer', background: selected ? 'var(--brand-light)' : 'var(--white)' }}>
      <div style={{ flex: '0 0 38px', width: 38, height: 38, borderRadius: '50%', background: 'var(--brand)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <MapPin />
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 'var(--s)', fontWeight: 700, color: 'var(--ink)', display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
          {s.name}
          {isDefault && <span style={{ fontSize: 10, fontWeight: 700, color: 'var(--accent)', background: '#FBEAF0', padding: '1px 7px', borderRadius: 'var(--r-pill)' }}>預設</span>}
          {s.store_type && <span style={{ fontSize: 10, fontWeight: 700, color: 'var(--gray-1)', background: 'var(--field-bg)', padding: '1px 7px', borderRadius: 'var(--r-pill)' }}>{s.store_type}</span>}
        </div>
        <div style={{ fontSize: 'var(--xs)', color: 'var(--gray-1)', marginTop: 2, display: 'flex', alignItems: 'center', gap: 6 }}>
          <span>{s.address}</span>
          {open !== null && <span style={{ color: open ? 'var(--accent)' : 'var(--gray-2)', fontWeight: 700, flexShrink: 0 }}>{open ? '營業中' : '已打烊'}</span>}
        </div>
      </div>
      <span style={{ marginLeft: 'auto', fontSize: 12, color: 'var(--accent)', fontWeight: 700, flex: '0 0 auto' }}>{selected ? '✓' : (km != null ? fmtDistance(km) : '')}</span>
    </div>
  )
}
// 公版A：搜尋版（開桌/預約/包桌用）— 搜尋框 + 縣市篩選 + 真實門市清單

// 公版B：縣市+區域下拉版（大量門市時用，如個人設定預設門市）— 與「開始配桌」同款排版
function StoreCityPicker({ current, onPick }) {
  const [stores, setStores] = useState([])
  const [myCoord, setMyCoord] = useState(null)
  const [defaultStoreId, setDefaultStoreId] = useState(null)
  const [city, setCity] = useState('高雄市')
  const [area, setArea] = useState('全部')
  const [located, setLocated] = useState(false)
  useEffect(() => { fetchStores().then(setStores) }, [])
  useEffect(() => { fetchMyProfile().then((p) => { if (p && p.home_store_id) setDefaultStoreId(p.home_store_id) }) }, [])
  useEffect(() => {
    if (!navigator.geolocation) return
    navigator.geolocation.getCurrentPosition(
      (pos) => { setMyCoord({ lat: pos.coords.latitude, lng: pos.coords.longitude }); setCity(cityFromLatLng(pos.coords.latitude, pos.coords.longitude)); setLocated(true) },
      () => {}, { timeout: 6000, maximumAge: 300000 }
    )
  }, [])
  const CITY_LIST = Array.from(new Set(stores.map((s) => s.city).filter(Boolean)))
  useEffect(() => {
    if (CITY_LIST.length > 0 && !CITY_LIST.includes(city)) { setCity(CITY_LIST[0]); setArea('全部') }
  }, [stores.length, city])
  const areas = ['全部', ...Array.from(new Set(stores.filter((s) => s.city === city).map((s) => s.district).filter(Boolean)))]
  const list = stores
    .filter((s) => s.city === city && (area === '全部' || s.district === area))
    .slice()
    .sort((a, b) => {
      if (!myCoord) return 0
      const da = distanceKm(myCoord.lat, myCoord.lng, a.lat, a.lng), db = distanceKm(myCoord.lat, myCoord.lng, b.lat, b.lng)
      if (da == null) return 1; if (db == null) return -1
      return da - db
    })
  return (
    <div>
      {located && <p style={{ margin: '0 0 8px', fontSize: 11, color: 'var(--accent)', fontWeight: 600, display: 'flex', alignItems: 'center', gap: 4 }}><MapPin />已定位你在 {city}</p>}
      <div style={{ display: 'flex', gap: 10, marginBottom: 12 }}>
        <div style={{ position: 'relative', flex: 1 }}>
          <select value={city} onChange={(e) => { setCity(e.target.value); setArea('全部') }} style={{ width: '100%', appearance: 'none', WebkitAppearance: 'none', outline: 'none', border: '1px solid var(--field-bd)', borderRadius: 'var(--r-field)', padding: '11px 34px 11px 14px', fontSize: 'var(--m)', fontWeight: 700, color: 'var(--ink)', background: 'var(--field-bg)', fontFamily: 'inherit', cursor: 'pointer' }}>{CITY_LIST.map((c) => <option key={c} value={c}>{c}</option>)}</select>
          <span style={{ position: 'absolute', right: 13, top: '50%', transform: 'translateY(-50%)', pointerEvents: 'none', color: 'var(--ink)', fontSize: 16, fontWeight: 700 }}>▾</span>
        </div>
        <div style={{ position: 'relative', flex: 1 }}>
          <select value={area} onChange={(e) => setArea(e.target.value)} style={{ width: '100%', appearance: 'none', WebkitAppearance: 'none', outline: 'none', border: '1px solid var(--field-bd)', borderRadius: 'var(--r-field)', padding: '11px 34px 11px 14px', fontSize: 'var(--m)', fontWeight: 700, color: 'var(--ink)', background: 'var(--field-bg)', fontFamily: 'inherit', cursor: 'pointer' }}>{areas.map((a) => <option key={a} value={a}>{a === '全部' ? '全部區域' : a}</option>)}</select>
          <span style={{ position: 'absolute', right: 13, top: '50%', transform: 'translateY(-50%)', pointerEvents: 'none', color: 'var(--ink)', fontSize: 16, fontWeight: 700 }}>▾</span>
        </div>
      </div>
      <div style={{ border: '1px solid var(--field-bd)', borderRadius: 'var(--r-card)', overflow: 'hidden' }}>
        {list.length === 0
          ? <p style={{ textAlign: 'center', color: 'var(--gray-2)', fontSize: 'var(--xs)', padding: '18px 0' }}>此區域尚無門市</p>
          : list.map((s) => <StoreRow key={s.id} s={s} selected={current === s.name} myCoord={myCoord} isDefault={defaultStoreId && s.id === defaultStoreId} onPick={onPick} />)}
      </div>
    </div>
  )
}

function StorePickerSearch({ current, onPick }) {
  const [q, setQ] = useState('')
  const [open, setOpen] = useState(false)
  const [cityFilt, setCityFilt] = useState('全部')
  const [stores, setStores] = useState([])
  const [myCoord, setMyCoord] = useState(null)
  const [defaultStoreId, setDefaultStoreId] = useState(null)
  useEffect(() => { fetchStores().then(setStores) }, [])
  useEffect(() => { fetchMyProfile().then((p) => { if (p && p.home_store_id) setDefaultStoreId(p.home_store_id) }) }, [])
  useEffect(() => {
    if (!navigator.geolocation) return
    navigator.geolocation.getCurrentPosition(
      (pos) => setMyCoord({ lat: pos.coords.latitude, lng: pos.coords.longitude }),
      () => {}, { timeout: 6000, maximumAge: 300000 }
    )
  }, [])
  const cities = ['全部', ...Array.from(new Set(stores.map((s) => s.city).filter(Boolean)))]
  const list = stores
    .filter((s) => (cityFilt === '全部' || s.city === cityFilt) && (!q || s.name.includes(q) || (s.district && s.district.includes(q)) || (s.city && s.city.includes(q))))
    .slice()
    .sort((a, b) => {
      if (!myCoord) return 0
      const da = distanceKm(myCoord.lat, myCoord.lng, a.lat, a.lng), db = distanceKm(myCoord.lat, myCoord.lng, b.lat, b.lng)
      if (da == null) return 1; if (db == null) return -1
      return da - db
    })
  const cur = stores.find((s) => s.name === current) || stores[0] || { name: current || '選擇門市' }
  return (
    <div>
      <div onClick={() => setOpen((o) => !o)} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', background: 'var(--field-bg)', border: '1px solid var(--field-bd)', borderRadius: 'var(--r-card)', padding: '12px 14px', cursor: 'pointer' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
          <MapPin /><span style={{ fontSize: 'var(--m)', fontWeight: 700, color: 'var(--ink)' }}>{cur.name}</span>
          {defaultStoreId && cur.id === defaultStoreId && <span style={{ fontSize: 10, fontWeight: 700, color: 'var(--accent)', background: '#FBEAF0', padding: '1px 7px', borderRadius: 'var(--r-pill)' }}>預設</span>}
        </div>
        <span style={{ fontSize: 'var(--s)', color: 'var(--accent)', fontWeight: 700, transform: open ? 'rotate(90deg)' : 'none', transition: 'transform .2s' }}>›</span>
      </div>
      {open && (
        <div style={{ border: '1px solid var(--field-bd)', borderRadius: 'var(--r-card)', marginTop: 8, overflow: 'hidden' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, background: '#F4F2F1', borderRadius: 11, padding: '10px 13px', margin: '11px 12px 4px' }}>
            <SearchIcon />
            <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="搜尋門市或地區" style={{ border: 'none', background: 'transparent', outline: 'none', fontSize: 13, color: 'var(--ink)', flex: 1, fontFamily: 'inherit' }} />
          </div>
          <div style={{ display: 'flex', gap: 6, padding: '8px 12px 4px', flexWrap: 'wrap' }}>{cities.map((c) => <span key={c} onClick={() => setCityFilt(c)} style={{ fontSize: 12, padding: '5px 13px', borderRadius: 'var(--r-pill)', cursor: 'pointer', border: '1px solid ' + (c === cityFilt ? 'var(--brand)' : 'var(--gray-3)'), background: c === cityFilt ? 'var(--brand)' : 'var(--white)', color: c === cityFilt ? 'var(--ink)' : 'var(--gray-1)', fontWeight: c === cityFilt ? 600 : 400 }}>{c}</span>)}</div>
          <div style={{ paddingTop: 4, paddingBottom: 4 }}>
            {list.length === 0 ? <p style={{ textAlign: 'center', color: 'var(--gray-2)', fontSize: 'var(--xs)', padding: '18px 0' }}>找不到門市</p> :
              list.map((s) => <StoreRow key={s.id} s={s} selected={current === s.name} myCoord={myCoord} isDefault={defaultStoreId && s.id === defaultStoreId} onPick={(x) => { onPick(x); setOpen(false); setQ('') }} />)}
          </div>
        </div>
      )}
    </div>
  )
}

function MapPin() {
  return <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="#2E2B2C" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" style={{ verticalAlign: -3 }}><path d="M21 10c0 6-9 12-9 12s-9-6-9-12a9 9 0 0 1 18 0Z" /><circle cx="12" cy="10" r="3" /></svg>
}

export { ProfileCardOther, BabyTileCard, BlacklistSheet, StoreRow, StorePickerSearch, StoreCityPicker, MapPin };

// 共用裝飾（卡片右下角半透明斜角方塊）
export const deco = (
  <span style={{ position: 'absolute', right: -8, bottom: -14, width: 56, height: 72, borderRadius: 13, background: 'var(--white)', opacity: 0.16, transform: 'rotate(14deg)' }} />
)
