// 個人設定群組 — 從 App.jsx 抽出
// BabyTileSheet(寶貝牌) + StyleQuizSheet(牌風問卷) + SettingPickSheet + SettingsPage + SelfProfileSheet
import { useState, useEffect } from 'react'
import { createPortal } from 'react-dom'
import DefaultAvatar from '../DefaultAvatar'
import { DragSheet, PencilIcon, ThumbIcon, showToast } from '../lib/ui.jsx'
import { BabyTileCard, StoreCityPicker } from '../lib/components.jsx'
import { MahjongTile, tileLabel } from '../lib/tiles.jsx'
import { fmtRank, getMyAvatar } from '../lib/helpers.jsx'
import { APP_VERSION } from '../lib/analytics.js'
import { fetchMyProfile, setMyNickname, setMyAbout, setMySched, setMyStyle, setMySeeScore, setMyBabyTile, setMyHomeStore } from '../lib/profile.js'
import { AvatarPickerSheet, TitlesSheet, CollectDetailSheet, EditTextSheet } from './rewards.jsx'
import { AvoidPage } from './match.jsx'

// 寶貝牌相關元件
const ALL_TILES = {
  萬: ['1萬', '2萬', '3萬', '4萬', '5萬', '6萬', '7萬', '8萬', '9萬'],
  筒: ['1筒', '2筒', '3筒', '4筒', '5筒', '6筒', '7筒', '8筒', '9筒'],
  索: ['1索', '2索', '3索', '4索', '5索', '6索', '7索', '8索', '9索'],
  字: ['東', '南', '西', '北', '中', '發', '白'],
}
// ===== 擬真麻將牌面 SVG（萬=霞鶩文楷國字 / 筒索=細線空心 / 8索WM / 黑+桃紅）=====

function BabyTileSheet({ initTile, initNote, onSave, onClose }) {
  const [sel, setSel] = useState(initTile || null)
  const [note, setNote] = useState(initNote || '')
  return (
    <DragSheet onClose={onClose} title="選一張你的寶貝牌">
      {Object.entries(ALL_TILES).map(([grp, tiles]) => (
        <div key={grp} style={{ marginBottom: 12 }}>
          <div style={{ fontSize: 'var(--xs)', color: 'var(--gray-1)', fontWeight: 700, margin: '4px 0 8px' }}>{grp === '字' ? '字牌' : grp + '子'}</div>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            {tiles.map((t) => (
              <span key={t} onClick={() => setSel(t)} style={{ cursor: 'pointer', borderRadius: 'var(--r-sm)', padding: 2, background: sel === t ? 'var(--brand-light)' : 'transparent', border: sel === t ? '2px solid var(--accent)' : '2px solid transparent', display: 'inline-flex', flex: '0 0 auto' }}><MahjongTile t={t} w={34} /></span>
            ))}
          </div>
        </div>
      ))}
      <div style={{ fontSize: 'var(--xs)', color: 'var(--gray-1)', fontWeight: 700, margin: '10px 0 6px' }}>寫一句話（選填）</div>
      <input value={note} onChange={(e) => setNote(e.target.value)} onFocus={(e) => { const el = e.target; setTimeout(() => { try { el.scrollIntoView({ block: 'center', behavior: 'smooth' }) } catch {} }, 300) }} maxLength={16} placeholder="例：這張牌帶給我好運！" style={{ width: '100%', border: '1.5px solid var(--gray-3)', background: 'var(--white)', borderRadius: 'var(--r-field)', padding: '11px 14px', fontSize: 'var(--s)', color: 'var(--ink)', outline: 'none', boxSizing: 'border-box' }} />
      <button className="ibtn" onClick={() => { if (sel) { onSave(sel, note.trim()); onClose() } }} style={{ width: '100%', marginTop: 12, padding: '12px 0', fontSize: 'var(--m)', fontWeight: 700, background: sel ? 'var(--ink)' : 'var(--gray-4)', color: sel ? 'var(--white)' : 'var(--gray-2)' }}>{sel ? '設定' + tileLabel(sel) + '為寶貝牌' : '請先選一張牌'}</button>
    </DragSheet>
  )
}

// ===== 牌風問卷抽屜（3 題：出牌速度／打牌氣氛／規則態度 → ◯◯型玩家）=====
function StyleQuizSheet({ onClose, onDone }) {
  const QS = [
    { key: '出牌速度', q: '輪到你出牌時，通常？', a: [['乾脆俐落，很快打出', 'fast'], ['會多想一下再出手', 'slow']] },
    { key: '打牌氣氛', q: '你上桌打牌喜歡的氣氛是？', a: [['邊打邊聊，熱熱鬧鬧', 'social'], ['專心打牌，安靜專注', 'focus']] },
    { key: '規則態度', q: '對於牌桌規則，你偏向？', a: [['照標準規則，該怎樣就怎樣', 'strict'], ['輕鬆一點，開心就好', 'casual']] },
  ]
  const [step, setStep] = useState(0)
  const [ans, setAns] = useState({})
  const pick = (key, val) => {
    const na = { ...ans, [key]: val }
    setAns(na)
    if (step < QS.length - 1) { setStep(step + 1) }
    else {
      const speed = na['出牌速度'], mood = na['打牌氣氛'], rule = na['規則態度']
      // 對應 6 種型玩家
      let type, desc
      if (speed === 'fast' && mood === 'social') { type = '社交型玩家'; desc = '出牌快、愛聊天，喜歡輕鬆熱鬧的牌局' }
      else if (speed === 'fast' && mood === 'focus') { type = '速攻型玩家'; desc = '出牌明快、專注求勝，節奏俐落' }
      else if (speed === 'slow' && mood === 'focus' && rule === 'strict') { type = '謀略型玩家'; desc = '沉穩思考、講究章法，步步為營' }
      else if (speed === 'slow' && mood === 'focus') { type = '穩健型玩家'; desc = '謹慎思考、不急不徐，穩紮穩打' }
      else if (speed === 'slow' && mood === 'social') { type = '悠哉型玩家'; desc = '慢慢打、享受過程，重在盡興' }
      else { type = '均衡型玩家'; desc = '攻守兼備、隨機應變，沒有明顯偏好' }
      // 三維度：[標籤, 百分比]（雷達圖座標 + 進度條寬度用）
      const dims = {
        速度: speed === 'fast' ? ['明快', 85] : ['沉穩', 35],
        氣氛: mood === 'social' ? ['熱鬧', 85] : ['專注', 35],
        規則: rule === 'strict' ? ['嚴謹', 80] : ['隨和', 40],
      }
      onDone && onDone({ type, desc, dims })
    }
  }
  const cur = QS[step]
  return (
    <DragSheet onClose={onClose} title="牌風問卷" subtitle={'第 ' + (step + 1) + ' / ' + QS.length + ' 題 · ' + cur.key}>
      <div style={{ height: 6, background: 'var(--gray-4)', borderRadius: 'var(--r-pill)', overflow: 'hidden', margin: '2px 0 18px' }}>
        <div style={{ height: '100%', width: ((step + 1) / QS.length * 100) + '%', background: 'var(--accent)', borderRadius: 'var(--r-pill)', transition: 'width .3s' }} />
      </div>
      <p style={{ margin: '0 0 16px', fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)', lineHeight: 1.5 }}>{cur.q}</p>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10, paddingBottom: 8 }}>
        {cur.a.map(([txt, val]) => (
          <button key={txt} className="ibtn" onClick={() => pick(cur.key, val)} style={{ width: '100%', padding: '15px 16px', fontSize: 'var(--m)', fontWeight: 700, background: 'var(--white)', border: '1.5px solid var(--gray-3)', color: 'var(--ink)', textAlign: 'left', borderRadius: 'var(--r-card)' }}>{txt}</button>
        ))}
      </div>
    </DragSheet>
  )
}

// ===== 個人設定切頁（粉 Hero + 灰卡分組）=====
// ===== 設定用單選抽屜（門市/作息/成績權限共用）=====
function SettingPickSheet({ title, options, cur, onPick, onClose, z = 1000 }) {
  const [sel, setSel] = useState(cur)   // 先選、按儲存才真的送出
  return (
    <DragSheet onClose={onClose} title={title} z={z}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        {options.map((op) => (
          <div key={op} onClick={() => setSel(op)}
            style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', border: sel === op ? '2px solid var(--ink)' : '1.5px solid var(--gray-3)', borderRadius: 'var(--r-card)', padding: '14px 16px', cursor: 'pointer' }}>
            <span style={{ fontSize: 15, fontWeight: 600, color: 'var(--ink)' }}>{op}</span>
            <span style={{ fontSize: 14, color: sel === op ? 'var(--ink)' : 'var(--gray-2)' }}>{sel === op ? '●' : '○'}</span>
          </div>
        ))}
      </div>
      <div style={{ display: 'flex', gap: 10, marginTop: 18 }}>
        <button className="ibtn" onClick={onClose} style={{ flex: 1, padding: '13px 0', fontSize: 15, fontWeight: 700, background: 'var(--gray-4)', color: 'var(--gray-1)' }}>取消</button>
        <button className="ibtn" onClick={() => onPick(sel)} style={{ flex: 1, padding: '13px 0', fontSize: 15, fontWeight: 700, background: 'var(--ink)', color: 'var(--white)' }}>儲存</button>
      </div>
    </DragSheet>
  )
}

function SettingsPage({ member, prof, onBack, onLogout }) {
  const nm = (member && member.name) || '我'
  const load = (k, d) => { try { const v = localStorage.getItem(k); return v == null ? d : v === '1' } catch { return d } }
  const [notiTable, setNotiTable] = useState(() => load('migi_noti_table', true))
  const [notiEvent, setNotiEvent] = useState(() => load('migi_noti_event', true))
  const [notiInvite, setNotiInvite] = useState(() => load('migi_noti_invite', false))
  const save = (k, v) => { try { localStorage.setItem(k, v ? '1' : '0') } catch {} }
  const loadStr = (k, d) => { try { return localStorage.getItem(k) || d } catch { return d } }
  const [phone, setPhone] = useState(() => loadStr('migi_phone', ''))
  const [storeId, setStoreId] = useState(prof?.home_store_id || null)
  const [storeName, setStoreName] = useState(prof?.home_store_name || '尚未設定')
  const [sched, setSched] = useState(prof?.sched || '不一定')
  const [seeScore, setSeeScore] = useState(prof?.see_score || '牌咖')
  const [sheet, setSheet] = useState(null) // 'phone' | 'store' | 'sched' | 'seeScore'
  const [blOpen, setBlOpen] = useState(false)
  const Toggle = ({ on, set, k }) => (
    <span onClick={() => { const nv = !on; set(nv); save(k, nv) }} style={{ width: 40, height: 24, borderRadius: 'var(--r-pill)', background: on ? 'var(--accent)' : 'var(--field-bd)', position: 'relative', flex: '0 0 40px', cursor: 'pointer', transition: 'background .2s' }}>
      <span style={{ width: 20, height: 20, borderRadius: '50%', background: 'var(--white)', position: 'absolute', top: 2, left: on ? 18 : 2, boxShadow: '0 1px 2px rgba(0,0,0,.2)', transition: 'left .2s' }} />
    </span>
  )
  const sect = (t) => <p style={{ fontSize: 12, fontWeight: 700, color: 'var(--gray-2)', padding: '18px 20px 6px', margin: 0 }}>{t}</p>
  const rowStyle = { display: 'flex', alignItems: 'center', gap: 12, padding: '14px 20px', borderBottom: '.5px solid #F5F3F2', cursor: 'pointer' }
  const lbl = { flex: 1, fontSize: 14, fontWeight: 700, color: 'var(--ink)' }
  const val = { fontSize: 13, color: 'var(--gray-2)' }
  const arr = () => <span style={{ fontSize: 13, color: 'var(--gray-2)' }}>{'查看 \u203A'}</span>
  return createPortal(
    <div className="sheet-anim" style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: 'var(--white)', zIndex: 1050, display: 'flex', flexDirection: 'column' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '16px 16px 12px', borderBottom: '.5px solid var(--gray-4)', flex: '0 0 auto' }}>
        <button onClick={onBack} style={{ background: 'none', border: 'none', fontSize: 22, color: 'var(--ink)', cursor: 'pointer' }}>{'\u2039'}</button>
        <span style={{ fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>個人設定</span>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', paddingBottom: 24 }}>
        {sect('帳號')}
        <div style={{ ...rowStyle, cursor: 'default' }}><span style={lbl}>綁定 LINE</span><span style={{ fontSize: 11, fontWeight: 700, color: 'var(--ink)', background: 'var(--brand)', borderRadius: 'var(--r-pill)', padding: '3px 10px' }}>已綁定</span></div>
        <div style={rowStyle} onClick={() => setSheet('phone')}><span style={lbl}>手機號碼</span><span style={val}>{phone || '尚未綁定'} {'\u203A'}</span></div>

        {sect('偏好')}
        <div style={rowStyle} onClick={() => setSheet('store')}><span style={lbl}>預設門市</span><span style={val}>{storeName} {'\u203A'}</span></div>
        <div style={rowStyle} onClick={() => setSheet('sched')}><span style={lbl}>作息偏好</span><span style={val}>{sched} {'\u203A'}</span></div>

        {sect('通知')}
        <div style={{ ...rowStyle, cursor: 'default' }}><span style={lbl}>配桌成功通知</span><Toggle on={notiTable} set={setNotiTable} k="migi_noti_table" /></div>
        <div style={{ ...rowStyle, cursor: 'default' }}><span style={lbl}>活動與優惠通知</span><Toggle on={notiEvent} set={setNotiEvent} k="migi_noti_event" /></div>
        <div style={{ ...rowStyle, cursor: 'default' }}><span style={lbl}>牌咖邀請通知</span><Toggle on={notiInvite} set={setNotiInvite} k="migi_noti_invite" /></div>

        {sect('隱私與社交')}
        <div style={rowStyle} onClick={() => setBlOpen(true)}><span style={lbl}>黑名單管理</span>{arr()}</div>
        <div style={rowStyle} onClick={() => setSheet('seeScore')}><span style={lbl}>誰能看我的成績</span><span style={val}>{seeScore} {'\u203A'}</span></div>

        {sect('其他')}
        <div style={rowStyle} onClick={() => showToast('關於 MIGI · 即將推出')}><span style={lbl}>關於 MIGI</span>{arr()}</div>
        <div style={rowStyle} onClick={() => showToast('隱私權政策 · 即將推出')}><span style={lbl}>隱私權政策</span>{arr()}</div>
        <div style={rowStyle} onClick={() => showToast('意見回饋 · 即將推出')}><span style={lbl}>意見回饋</span>{arr()}</div>
        <div style={{ ...rowStyle, borderBottom: 'none' }} onClick={onLogout}><span style={{ ...lbl, color: 'var(--accent)' }}>登出</span></div>
      </div>
      <p style={{ textAlign: 'center', fontSize: 10, color: '#C9C5C2', margin: '14px 0 0' }}>MIGI 會員 {APP_VERSION}</p>
      {sheet === 'phone' && <EditTextSheet title="手機號碼" placeholder="輸入手機號碼" init={phone} maxLen={10} z={1350} onSave={(v) => { setPhone(v); try { localStorage.setItem('migi_phone', v) } catch {}; showToast('手機號碼已更新') }} onClose={() => setSheet(null)} />}
      {sheet === 'store' && (
        <DragSheet onClose={() => setSheet(null)} title="預設門市" z={1200}>
          <StoreCityPicker current={storeName} onPick={(s) => { setStoreId(s.id); setStoreName(s.name); setMyHomeStore(s.id); setSheet(null); showToast('預設門市：' + s.name) }} />
        </DragSheet>
      )}
      {sheet === 'sched' && <SettingPickSheet title="作息偏好" z={1200} options={['早上為主', '下午為主', '晚上為主', '深夜為主', '不一定']} cur={sched} onPick={(v) => { setSched(v); setMySched(v); setSheet(null); showToast('作息偏好：' + v) }} onClose={() => setSheet(null)} />}
      {sheet === 'seeScore' && <SettingPickSheet title="誰能看我的成績" z={1200} options={['所有人', '牌咖', '只有自己']} cur={seeScore} onPick={(v) => { setSeeScore(v); setMySeeScore(v); setSheet(null); showToast('成績公開範圍：' + v) }} onClose={() => setSheet(null)} />}
      {blOpen && <AvoidPage z={1200} title="黑名單管理" onBack={() => setBlOpen(false)} />}
    </div>, document.body)
}

function SelfProfileSheet({ member, onClose, onLogout, go }) {
  const [nick, setNick] = useState((member && member.name) || '我')
  // A 塊：開啟時拉真實資料（段位/稱號/獲讚），失敗則沿用預設不擋 UI
  const [prof, setProf] = useState(null)
  useEffect(() => { fetchMyProfile().then((d) => { if (d) { setProf(d); if (d.nickname) setNick(d.nickname) } }) }, [])
  const rankTxt = (prof && prof.rank) || '銅牌熊 I'
  const titleTxt = (prof && prof.title) || '新手上路'
  const likesCnt = prof ? prof.likes_count : 0
  const nm = nick
  const [nickOpen, setNickOpen] = useState(false)
  const [aboutText, setAboutText] = useState('')
  const [aboutOpen, setAboutOpen] = useState(false)
  const [titlesOpen, setTitlesOpen] = useState(false)
  const [tdetail, setTdetail] = useState(null)
  const [avatarOpen, setAvatarOpen] = useState(false)
  const [avatar, setAvatar] = useState(getMyAvatar)   // 自選頭像（null=預設）
  const [babyOpen, setBabyOpen] = useState(false)
  const [baby, setBaby] = useState(null)
  const [quizOpen, setQuizOpen] = useState(false)
  const [settingsOpen, setSettingsOpen] = useState(false)
  const [styleType, setStyleType] = useState(null)
  const [blacklistOpen, setBlacklistOpen] = useState(false)
  // prof 拉到後，同步灌進各欄位（about/牌風/寶貝牌 都是真資料）
  useEffect(() => {
    if (!prof) return
    setAboutText(prof.about || '')
    setBaby(prof.baby_tile || null)
    setStyleType((prof.style && prof.style.type) ? prof.style : null)
  }, [prof])
  // 作息偏好 → 牌咖卡標籤（早場/午場/晚場/夜場，不一定則不顯示）
  const SCHED_TAG = { '早上為主': '早場', '下午為主': '午場', '晚上為主': '晚場', '深夜為主': '夜場' }
  const hd = { margin: '0 0 12px', fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }
  const pill = (txt, color, bg, bd) => <span style={{ display: 'inline-flex', alignItems: 'center', height: 22, fontSize: 11, fontWeight: 700, color, background: bg, border: bd || 'none', borderRadius: 'var(--r-pill)', padding: '0 11px' }}>{txt}</span>
  const tg = (txt, pink) => <span key={txt} style={{ fontSize: 'var(--xs)', fontWeight: 700, background: pink ? 'var(--brand-light)' : 'var(--field-bg)', color: 'var(--ink)', borderRadius: 'var(--r-pill)', padding: '5px 13px' }}>{txt}</span>
  const setRow = (label, onClick) => (
    <div onClick={onClick} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '13px 0', cursor: 'pointer', borderTop: '1px solid var(--field-bg)' }}>
      <span style={{ fontSize: 'var(--s)', color: 'var(--ink)' }}>{label}</span>
      <span style={{ fontSize: 20, color: 'var(--ink)', fontWeight: 700 }}>{'\u203A'}</span>
    </div>
  )
  return createPortal(
    <div className="sheet-anim" style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: 'var(--white)', zIndex: 1000, display: 'flex', flexDirection: 'column' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '16px 16px 12px', borderBottom: '.5px solid var(--gray-4)', flex: '0 0 auto' }}>
        <button onClick={onClose} style={{ background: 'none', border: 'none', fontSize: 22, color: 'var(--ink)', cursor: 'pointer' }}>‹</button>
        <span style={{ fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>我的個人檔案</span>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '16px 16px 28px' }}>
      {/* Hero */}
      <div style={{ background: 'var(--brand-light)', borderRadius: 'var(--r-lg)', padding: '18px 16px', marginBottom: 4, position: 'relative' }}>
        {/* 我的獲讚數（右上）★之後接後端讀真實累計 */}
        <span style={{ position: 'absolute', top: 14, right: 14, display: 'inline-flex', alignItems: 'center', gap: 5, background: 'rgba(255,255,255,0.7)', borderRadius: 'var(--r-pill)', padding: '4px 11px', fontSize: 12, fontWeight: 700, color: 'var(--ink)' }}><ThumbIcon size={13} color="var(--ink)" /> {likesCnt}</span>
        <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
          <div onClick={() => setAvatarOpen(true)} style={{ cursor: 'pointer', flex: '0 0 80px', textAlign: 'center' }}>
            {avatar
              ? <span style={{ width: 80, height: 80, borderRadius: '50%', background: 'var(--white)', display: 'inline-flex', overflow: 'hidden' }}><img src={avatar} alt="" width="100%" height="100%" style={{ display: 'block' }} /></span>
              : <DefaultAvatar size={80} />}
            <div style={{ marginTop: 3, fontSize: 10, fontWeight: 700, color: 'var(--accent)' }}>更換頭像</div>
          </div>
          <div style={{ flex: 1 }}>
            <span onClick={() => setTitlesOpen(true)} style={{ cursor: 'pointer', display: 'inline-flex', alignItems: 'center' }}>
              <span style={{ fontSize: 12, fontWeight: 700, color: 'var(--ink)' }}>「{titleTxt}」</span>
            </span>
            <div style={{ display: 'flex', alignItems: 'center', gap: 7, marginTop: 6 }}><p style={{ margin: 0, fontSize: 'var(--xl)', fontWeight: 700, color: 'var(--ink)' }}>{nm}</p><span onClick={() => setNickOpen(true)} style={{ cursor: 'pointer', display: 'inline-flex' }}><PencilIcon /></span></div>
            <div style={{ display: 'flex', gap: 6, marginTop: 8, flexWrap: 'wrap' }}>
              <span style={{ display: 'inline-flex', alignItems: 'center', height: 22, fontSize: 11, fontWeight: 700, color: 'var(--ink)', background: 'rgba(255,255,255,0.7)', borderRadius: 'var(--r-pill)', padding: '0 11px' }}>{fmtRank(rankTxt)}</span>
            </div>
          </div>
        </div>
      </div>
      {/* 關於我 */}
      <div style={{ padding: '14px 0' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: 13 }}>
          <span style={{ fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>關於我</span>
          <span onClick={() => setAboutOpen(true)} style={{ fontSize: 'var(--xs)', fontWeight: 700, color: 'var(--accent)', cursor: 'pointer' }}>編輯 ›</span>
        </div>
        <div style={{ background: 'var(--field-bg)', borderRadius: 'var(--r-field)', padding: '13px 14px', fontSize: 'var(--s)', color: aboutText ? 'var(--ink)' : 'var(--gray-2)', lineHeight: 1.7, marginBottom: 14 }}>{aboutText || '還沒有自我介紹，點「編輯」寫一句話介紹自己吧'}</div>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
          {prof && prof.sched && SCHED_TAG[prof.sched] && tg(SCHED_TAG[prof.sched], true)}
          {styleType && tg(styleType.type, true)}
          {/* 玩法/花牌/底注等行為統計標籤：需累積≥5場真實配桌紀錄才顯示，待M2收桌資料到位後補上 */}
        </div>
      </div>
      {/* 足跡 */}
      <div style={{ padding: '14px 0', borderTop: '1px solid var(--field-bg)' }}>
        <p style={hd}>我的麻將足跡</p>
        <div style={{ display: 'flex' }}>
          {[['0', '打了幾場'], ['銅牌熊', '生涯最高'], ['1', '造訪門市'], ['0', '交手過的人']].map(([n, l]) => (
            <div key={l} style={{ flex: 1, textAlign: 'center' }}>
              <p style={{ margin: 0, fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>{n}</p>
              <p style={{ margin: '3px 0 0', fontSize: 'var(--xs)', color: 'var(--gray-1)' }}>{l}</p>
            </div>
          ))}
        </div>
      </div>
      {/* 最近亮點 空狀態 */}
      <div style={{ padding: '14px 0', borderTop: '1px solid var(--field-bg)' }}>
        <p style={{ margin: '0 0 2px', fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>最近亮點</p>
        <p style={{ margin: '0 0 12px', fontSize: 'var(--xs)', color: 'var(--gray-2)', lineHeight: 1.6 }}>胡出一手好牌，就會記下你近期最大台的一手</p>
        <div style={{ background: 'var(--field-bg)', borderRadius: 'var(--r-card)', padding: 15, textAlign: 'center' }}>
          <p style={{ margin: 0, fontSize: 'var(--s)', color: 'var(--gray-2)' }}>還沒有亮點紀錄</p>
        </div>
      </div>
      {/* 我的牌風 */}
      <div style={{ padding: '14px 0', borderTop: '1px solid var(--field-bg)' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: 12 }}>
          <span style={{ fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>我的牌風</span>
          <span onClick={() => setQuizOpen(true)} style={{ fontSize: 'var(--xs)', fontWeight: 700, color: 'var(--accent)', cursor: 'pointer' }}>{styleType ? '重測 \u203A' : '填寫 \u203A'}</span>
        </div>
        {styleType ? (() => {
          const sp = styleType.dims['速度'][1], mo = styleType.dims['氣氛'][1], ru = styleType.dims['規則'][1]
          const pt = (ox, oy, p) => (55 + (ox - 55) * p / 100).toFixed(0) + ',' + (55 + (oy - 55) * p / 100).toFixed(0)
          const poly = pt(55, 12, sp) + ' ' + pt(92, 76, mo) + ' ' + pt(18, 76, ru)
          const rows = [['出牌速度', styleType.dims['速度'][0], sp], ['打牌氣氛', styleType.dims['氣氛'][0], mo], ['規則態度', styleType.dims['規則'][0], ru]]
          return <>
            <div style={{ marginBottom: 14 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 9 }}>
                <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#C2607A" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z" /></svg>
                <p style={{ margin: 0, fontSize: 'var(--xl)', fontWeight: 700, color: 'var(--accent)' }}>{styleType.type}</p>
              </div>
              <p style={{ margin: '6px 0 0', fontSize: 'var(--xs)', color: 'var(--gray-1)', lineHeight: 1.6 }}>{styleType.desc}</p>
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              <svg width="150" height="138" viewBox="-14 -12 128 124" style={{ flex: '0 0 auto', marginLeft: -6 }}>
                <polygon points="55,12 92,76 18,76" fill="none" stroke="#ECE7E4" strokeWidth="1" />
                <polygon points="55,33 74,65 36,65" fill="none" stroke="#F2F0EE" strokeWidth="1" />
                <line x1="55" y1="55" x2="55" y2="12" stroke="#F2F0EE" /><line x1="55" y1="55" x2="92" y2="76" stroke="#F2F0EE" /><line x1="55" y1="55" x2="18" y2="76" stroke="#F2F0EE" />
                <polygon points={poly} fill="rgba(250,214,220,.6)" stroke="#C2607A" strokeWidth="2" />
                <text x="55" y="6" fill="#7A7572" fontSize="11" textAnchor="middle">速度</text>
                <text x="100" y="85" fill="#7A7572" fontSize="11" textAnchor="middle">氣氛</text>
                <text x="10" y="85" fill="#7A7572" fontSize="11" textAnchor="middle">規則</text>
              </svg>
              <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 13 }}>
                {rows.map(([k, v, w]) => (
                  <div key={k}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, marginBottom: 5 }}><span style={{ color: 'var(--gray-1)' }}>{k}</span><span style={{ color: 'var(--ink)', fontWeight: 700 }}>{v}</span></div>
                    <div style={{ height: 6, background: 'var(--gray-4)', borderRadius: 'var(--r-pill)', overflow: 'hidden' }}><div style={{ height: '100%', width: w + '%', background: 'var(--accent)', borderRadius: 'var(--r-pill)' }} /></div>
                  </div>
                ))}
              </div>
            </div>
          </>
        })() : <>
          <p style={{ margin: '0 0 12px', fontSize: 'var(--xs)', color: 'var(--gray-2)', lineHeight: 1.6 }}>填寫牌風問卷，系統將會分析出你屬於哪種類型</p>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <svg width="150" height="138" viewBox="-14 -12 128 124" style={{ flex: '0 0 auto', marginLeft: -6 }}>
              <polygon points="55,12 92,76 18,76" fill="none" stroke="#ECE7E4" strokeWidth="1" />
              <polygon points="55,33 74,65 36,65" fill="none" stroke="#F2F0EE" strokeWidth="1" />
              <line x1="55" y1="55" x2="55" y2="12" stroke="#F2F0EE" /><line x1="55" y1="55" x2="92" y2="76" stroke="#F2F0EE" /><line x1="55" y1="55" x2="18" y2="76" stroke="#F2F0EE" />
              <text x="55" y="6" fill="#7A7572" fontSize="11" textAnchor="middle">速度</text>
              <text x="100" y="85" fill="#7A7572" fontSize="11" textAnchor="middle">氣氛</text>
              <text x="10" y="85" fill="#7A7572" fontSize="11" textAnchor="middle">規則</text>
            </svg>
            <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 13 }}>
              {[['出牌速度'], ['打牌氣氛'], ['規則態度']].map(([k]) => (
                <div key={k}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, marginBottom: 5 }}><span style={{ color: 'var(--gray-1)' }}>{k}</span><span style={{ color: 'var(--gray-2)' }}>未設定</span></div>
                  <div style={{ height: 6, background: 'var(--gray-4)', borderRadius: 'var(--r-pill)' }} />
                </div>
              ))}
            </div>
          </div>
        </>}
      </div>
      {/* 我的寶貝牌（牌風下方） */}
      <div style={{ padding: '14px 0', borderTop: '1px solid var(--field-bg)' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: 6 }}>
          <span style={{ fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>我的寶貝牌</span>
          <span onClick={() => setBabyOpen(true)} style={{ fontSize: 'var(--xs)', fontWeight: 700, color: 'var(--accent)', cursor: 'pointer' }}>{baby ? '更換 ›' : '去設定 ›'}</span>
        </div>
        <p style={{ margin: '0 0 12px', fontSize: 'var(--xs)', color: 'var(--gray-2)', lineHeight: 1.6 }}>選一張最愛的牌，可完成相關成就與獲得獎勵</p>
        <BabyTileCard tile={baby ? baby.tile : null} note={baby ? baby.note : ''} own={true} onChange={() => setBabyOpen(true)} />
      </div>
      {/* 帳號 */}
      <div style={{ padding: '0' }}>
        {setRow('看我的成績', () => go && go(2))}
        {setRow('個人設定', () => setSettingsOpen(true))}
      </div>
      {titlesOpen && <TitlesSheet onClose={() => setTitlesOpen(false)} onPick={(it) => { setTitlesOpen(false); setTdetail(it) }} />}
      {babyOpen && <BabyTileSheet initTile={baby?.tile} initNote={baby?.note} onSave={(t, n) => { const v = { tile: t, note: n || '這張牌帶給我好運！' }; setMyBabyTile(v); setBaby(v); showToast('已設定寶貝牌：' + tileLabel(t)) }} onClose={() => setBabyOpen(false)} />}
      {quizOpen && <StyleQuizSheet onClose={() => setQuizOpen(false)} onDone={(res) => { setStyleType(res); setMyStyle(res); setQuizOpen(false); showToast('你的牌風：' + res.type) }} />}
      {settingsOpen && <SettingsPage member={member} prof={prof} onBack={() => setSettingsOpen(false)} onLogout={() => { setSettingsOpen(false); onLogout && onLogout() }} />}
      {nickOpen && <EditTextSheet title="編輯暱稱" placeholder="輸入暱稱" init={nick} maxLen={12} onSave={(v) => { setNick(v); setMyNickname(v); try { const m = JSON.parse(localStorage.getItem('migi_member') || '{}'); m.name = v; localStorage.setItem('migi_member', JSON.stringify(m)) } catch {} showToast('暱稱已更新') }} onClose={() => setNickOpen(false)} />}
      {aboutOpen && <EditTextSheet title="編輯自我介紹" placeholder="寫一句話介紹自己" init={aboutText} maxLen={40} multiline onSave={(v) => { setAboutText(v); setMyAbout(v); showToast('自我介紹已更新') }} onClose={() => setAboutOpen(false)} />}
      {avatarOpen && <AvatarPickerSheet onClose={() => setAvatarOpen(false)} onApply={(src) => setAvatar(src)} />}
      {tdetail && <CollectDetailSheet item={tdetail} onClose={() => setTdetail(null)} />}
      </div>
    </div>, document.body
  )
}


/* ===== 儲值抽屜 ===== */

export { SelfProfileSheet };
