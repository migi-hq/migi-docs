// 獎勵頁群組（tab5 小熊的房間）— 從 App.jsx 抽出
// 含: 養成小熊(Bear/NurtureBear/BearStageImg) + 獎勵子頁(AchWall/BearDex/Closet/Checkin/WeeklyTask/Event/Gacha) + 抽屜
import { useState, useEffect } from 'react'
import { createPortal } from 'react-dom'
import DefaultAvatar from '../DefaultAvatar'
import { DragSheet, PencilIcon, showToast } from '../lib/ui.jsx'
import { ProfileCardOther } from '../lib/components.jsx'
import { rankBearSrc, getMyAvatar, saveMyAvatar } from '../lib/helpers.jsx'
import { BEAR_LV, COACH_BEAR, SNACK_IMGS } from '../lib/images.js'
import { fetchMyProfile, saveAppState } from '../lib/profile.js'

// 小熊名字（localStorage）
function getBearName() { try { return localStorage.getItem('migi_bear_name') || '小熊' } catch { return '小熊' } }
function saveBearNameLS(v) { try { localStorage.setItem('migi_bear_name', v) } catch {} }

function NurtureBear() {
  return (
    <svg viewBox="0 0 120 120" width="82" height="82"><ellipse cx="34" cy="30" rx="15" ry="15" fill="#C9A07A" /><ellipse cx="86" cy="30" rx="15" ry="15" fill="#C9A07A" /><ellipse cx="34" cy="30" rx="8" ry="8" fill="#E8CBB0" /><ellipse cx="86" cy="30" rx="8" ry="8" fill="#E8CBB0" /><ellipse cx="60" cy="62" rx="40" ry="38" fill="#D8B392" /><ellipse cx="60" cy="74" rx="22" ry="19" fill="#EAD3B8" /><circle cx="47" cy="54" r="4.5" fill="#3A2D22" /><circle cx="73" cy="54" r="4.5" fill="#3A2D22" /><circle cx="48.5" cy="52.5" r="1.4" fill="#FFF" /><circle cx="74.5" cy="52.5" r="1.4" fill="#FFF" /><ellipse cx="60" cy="66" rx="5" ry="3.5" fill="#3A2D22" /><path d="M60 69 Q60 74 55 75 M60 69 Q60 74 65 75" stroke="#3A2D22" strokeWidth="1.6" fill="none" strokeLinecap="round" /><ellipse cx="40" cy="64" rx="5" ry="3.5" fill="#F4B8C4" opacity="0.7" /><ellipse cx="80" cy="64" rx="5" ry="3.5" fill="#F4B8C4" opacity="0.7" /><path d="M30 18 Q44 6 56 16 L52 24 Q44 17 36 24 Z" fill="#C2607A" /><circle cx="43" cy="14" r="4" fill="#FAD6DC" /></svg>
  )
}

// 成就牆切頁（全部成就）
function AchWallPage({ onBack, onPick }) {
  const [cat, setCat] = useState('全部')
  const CATS = ['全部', '新手', '牌局', '社交', '餐飲', '探索', '特殊']
  // tier: legend(傳說MIGI)/rare(稀有)/norm(普通); cat: 分類; done進度 cur/req, on=已解鎖
  const ACH = [
    // 傳說 MIGI
    { e: '\u{1F004}', n: '首次 MIGI', tier: 'legend', cat: '牌局', on: 1 },
    { e: '\u{1F004}', n: '十次 MIGI', tier: 'legend', cat: '牌局', cur: 3, req: 10 },
    { e: '\u{1F004}', n: '百次 MIGI', tier: 'legend', cat: '牌局', cur: 0, req: 100 },
    // 稀有
    { e: '\u{1F43B}', n: '升上金牌熊', tier: 'rare', cat: '牌局', on: 1 },
    { e: '\u{1F525}', n: '連莊 5 次', tier: 'rare', cat: '牌局', cur: 3, req: 5 },
    { e: '\u{1F451}', n: '當季雀神', tier: 'rare', cat: '牌局', cur: 0, req: 1 },
    { e: '\u{1F3AF}', n: '清一色', tier: 'rare', cat: '牌局', cur: 0, req: 1 },
    { e: '\u{1F31F}', n: '隱藏成就', tier: 'rare', cat: '特殊', hidden: 1, cur: 0, req: 1 },
    // 普通
    { e: '\u{1F43B}', n: '新手報到', tier: 'norm', cat: '新手', on: 1 },
    { e: '\u{1F43B}', n: '第一次同桌', tier: 'norm', cat: '新手', on: 1 },
    { e: '\u{1F43B}', n: '第一次胡牌', tier: 'norm', cat: '牌局', on: 1 },
    { e: '\u{1F43B}', n: '打滿 10 場', tier: 'norm', cat: '牌局', cur: 6, req: 10 },
    { e: '\u{1F375}', n: '點一杯飲料', tier: 'norm', cat: '餐飲', on: 1 },
    { e: '\u2600\uFE0F', n: '早鳥達人', tier: 'norm', cat: '新手', cur: 7, req: 10 },
    { e: '\u{1F319}', n: '夜貓王', tier: 'norm', cat: '新手', cur: 0, req: 10 },
    { e: '\u{1F46D}', n: '交到 5 個牌咖', tier: 'norm', cat: '社交', cur: 0, req: 5 },
    { e: '\u{1F37D}\uFE0F', n: '餐飲組合', tier: 'norm', cat: '餐飲', cur: 2, req: 5 },
    { e: '\u{1F4CD}', n: '造訪 3 家店', tier: 'norm', cat: '探索', cur: 1, req: 3 },
  ]
  const shown = cat === '全部' ? ACH : ACH.filter((a) => a.cat === cat)
  const groups = [
    { key: 'legend', label: '傳說 · MIGI 牌型', dot: 'var(--gold)', color: '#B8860B' },
    { key: 'rare', label: '稀有 · 高難度', dot: 'var(--brand)', color: '#A4566A' },
    { key: 'norm', label: '普通 · 日常', dot: 'var(--gray-2)', color: 'var(--gray-1)' },
  ]
  const total = ACH.length
  const unlocked = ACH.filter((a) => a.on).length
  const Cell = (a) => {
    const on = !!a.on
    const doing = !on && a.cur > 0
    const pct = a.req ? Math.round((a.cur / a.req) * 100) : 0
    const nm = a.hidden && !on ? '？？？' : a.n
    const desc = a.tier === 'legend' ? '在 MIGI 門市胡出 MIGI 牌型' : a.hidden ? '達成隱藏條件解鎖' : '達成特定條件解鎖'
    return (
      <div key={a.n} onClick={() => onPick({ kind: '成就', emoji: a.e, name: nm, got: on, migi: a.tier === 'legend', desc, kv: on ? [['稀有度', a.tier === 'legend' ? '傳說' : a.tier === 'rare' ? '稀有' : '普通'], ['達成日期', '2025 / 11 / 03']] : [['稀有度', a.tier === 'legend' ? '傳說' : a.tier === 'rare' ? '稀有' : '普通'], ['進度', a.req ? a.cur + ' / ' + a.req : '尚未達成']] })} style={{ flex: '0 0 calc(33.33% - 6px)', textAlign: 'center', cursor: 'pointer' }}>
        <div style={{ position: 'relative', width: '100%', aspectRatio: '1', borderRadius: '50%', overflow: 'visible', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 28, background: a.tier === 'legend' ? (on ? 'var(--ink)' : 'var(--field-bg)') : a.tier === 'rare' ? (on ? 'var(--brand-light)' : 'var(--field-bg)') : 'var(--field-bg)', border: a.tier === 'legend' ? '2px solid ' + (on ? 'var(--gold)' : '#EAD7CC') : 'none', opacity: on ? 1 : doing ? 0.75 : 0.4 }}>
          {doing && <span style={{ position: 'absolute', top: 2, right: 0, background: 'var(--accent)', color: 'var(--white)', fontSize: 10, fontWeight: 700, borderRadius: 'var(--r-pill)', padding: '1px 7px', whiteSpace: 'nowrap' }}>{a.cur}/{a.req}</span>}
          <span style={{ filter: !on ? 'grayscale(1)' : 'none' }}>{a.hidden && !on ? '\u2753' : a.e}</span>
        </div>
        <p style={{ margin: '5px 0 0', fontSize: 13, fontWeight: 700, color: on ? 'var(--ink)' : 'var(--gray-2)', lineHeight: 1.3 }}>{nm}</p>
        {on ? <p style={{ margin: '2px 0 0', fontSize: 12, fontWeight: 500, color: 'var(--accent)' }}>已解鎖</p>
          : doing ? <p style={{ margin: '2px 0 0', fontSize: 12, color: 'var(--gray-2)' }}>進行中</p>
          : <p style={{ margin: '2px 0 0', fontSize: 12, color: 'var(--gray-2)' }}>未解鎖</p>}
      </div>
    )
  }
  return createPortal(
    <div className="sheet-anim" style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: 'var(--white)', zIndex: 1000, display: 'flex', flexDirection: 'column' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '16px 16px 12px', borderBottom: '.5px solid var(--gray-4)' }}>
        <button onClick={onBack} style={{ background: 'none', border: 'none', fontSize: 22, color: 'var(--ink)', cursor: 'pointer' }}>‹</button>
        <span style={{ fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>我的成就</span>
      </div>
      {/* 分類 tab */}
      <div className="noscroll" style={{ display: 'flex', gap: 7, overflowX: 'auto', padding: '12px 16px 6px' }}>
        {CATS.map((c) => (
          <span key={c} onClick={() => setCat(c)} style={{ flex: '0 0 auto', fontSize: 14, fontWeight: cat === c ? 600 : 400, padding: '7px 16px', borderRadius: 'var(--r-pill)', whiteSpace: 'nowrap', cursor: 'pointer', border: cat === c ? '1px solid var(--brand)' : '1px solid var(--gray-3)', background: cat === c ? 'var(--brand)' : 'var(--white)', color: cat === c ? 'var(--ink)' : 'var(--gray-1)' }}>{c}</span>
        ))}
      </div>
      {/* 進度列：左已解鎖 右稀有度篩選 */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 16px 4px' }}>
        <span style={{ fontSize: 'var(--s)', fontWeight: 800, color: 'var(--ink)' }}>已解鎖 {unlocked} / {total}</span>
        <span onClick={() => showToast('稀有度排序 · 即將推出')} style={{ fontSize: 'var(--xs)', fontWeight: 700, color: 'var(--accent)', cursor: 'pointer' }}>稀有度 ▾</span>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '0 16px 24px' }}>
        
        {groups.map((g) => {
          const items = shown.filter((a) => a.tier === g.key)
          if (!items.length) return null
          return (
            <div key={g.key}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 7, margin: '16px 0 10px' }}>
                <span style={{ width: 7, height: 7, borderRadius: '50%', background: g.dot }} />
                <span style={{ fontSize: 15, fontWeight: 700, color: 'var(--ink)' }}>{g.label.split(' · ')[0]}</span>
                <span style={{ fontSize: 13, color: 'var(--gray-2)' }}>{g.label.split(' · ')[1]}</span>
              </div>
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: 9 }}>{items.map(Cell)}</div>
            </div>
          )
        })}
        {cat === '全部' && (
          <div style={{ marginTop: 24, paddingTop: 18, borderTop: '1px solid var(--gray-4)' }}>
            <p style={{ margin: '0 0 12px', fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>近期解鎖成就</p>
            <div style={{ display: 'flex', gap: 10 }}>
              {[['🀄', '首次 MIGI', '11/03', 1], ['🐻', '第一次胡牌', '11/01', 0], ['🍵', '點一杯飲料', '10/28', 0]].map(([e, n, d, migi]) => (
                <div key={n} onClick={() => onPick({ kind: '成就', emoji: e, name: n, got: true, migi: !!migi, desc: migi ? '在 MIGI 門市胡出 MIGI 牌型' : '達成特定條件解鎖', kv: [['稀有度', migi ? '傳說' : '普通'], ['達成日期', '2025 / ' + d.replace('/', ' / ')]] })} style={{ flex: 1, textAlign: 'center', cursor: 'pointer' }}>
                  <div style={{ width: '100%', aspectRatio: '1', borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 28, background: migi ? 'var(--ink)' : 'var(--field-bg)', border: migi ? '2px solid var(--gold)' : 'none' }}>{e}</div>
                  <p style={{ margin: '5px 0 0', fontSize: 11, fontWeight: 700, color: 'var(--gray-1)', lineHeight: 1.3 }}>{n}</p>
                  <p style={{ margin: '2px 0 0', fontSize: 11, color: 'var(--gray-2)' }}>{d}</p>
                </div>
              ))}
            </div>
          </div>
        )}
        {cat === '全部' && (
          <div style={{ marginTop: 24 }}>
            <p style={{ margin: '0 0 14px', fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>各分類進度</p>
            {[['新手', 8, 13], ['牌局', 12, 30], ['社交', 10, 25], ['餐飲', 3, 6], ['探索', 1, 4], ['特殊', 1, 5]].map(([nm, c, t]) => (
              <div key={nm} style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 14 }}>
                <span style={{ flex: '0 0 52px', fontSize: 13, fontWeight: 700, color: 'var(--ink)' }}>{nm}</span>
                <div style={{ flex: 1, height: 8, background: 'var(--gray-4)', borderRadius: 'var(--r-pill)', overflow: 'hidden' }}><div style={{ height: '100%', width: Math.round(c / t * 100) + '%', background: 'var(--accent)', borderRadius: 'var(--r-pill)' }} /></div>
                <span style={{ flex: '0 0 auto', minWidth: 42, textAlign: 'right', fontSize: 12, fontWeight: 700, color: 'var(--gray-1)' }}>{c} / {t}</span>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>, document.body
  )
}

function BearDexPage({ onBack, onPick }) {
  // 頭像圖鑑：段位熊造型頭像，解鎖後可在個人檔案選用
  const BEARS = [['銅牌熊', 1], ['銀牌熊', 1], ['金牌熊', 1], ['白金熊', 1], ['鑽石熊', 1], ['大師熊', 0], ['雀神熊', 0]]
  const got = BEARS.filter((b) => b[1]).length
  return createPortal(
    <div className="sheet-anim" style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: 'var(--white)', zIndex: 1000, display: 'flex', flexDirection: 'column' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '16px 16px 12px', borderBottom: '.5px solid var(--gray-4)' }}>
        <button onClick={onBack} style={{ background: 'none', border: 'none', fontSize: 22, color: 'var(--ink)', cursor: 'pointer' }}>‹</button>
        <span style={{ fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>頭像圖鑑</span>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '16px 16px 24px' }}>
        <div style={{ padding: '0 0 4px' }}><span style={{ fontSize: 'var(--s)', fontWeight: 800, color: 'var(--ink)' }}>已解鎖 {got} / {BEARS.length}</span></div>
        <p style={{ margin: '6px 0 14px', fontSize: 'var(--xs)', color: 'var(--gray-2)', lineHeight: 1.6 }}>升上各段位或解鎖成就，取得更多頭像造型。</p>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12 }}>
          {BEARS.map(([nm, on], bi) => (
            <div key={nm} onClick={() => onPick({ kind: '頭像圖鑑', name: nm, got: !!on, desc: on ? nm + '造型頭像，可在個人檔案選用' : '升到 ' + nm + ' 解鎖這個頭像', kv: [['編號', 'No.' + ('0' + (bi + 1)).slice(-2)], ['階級', (bi + 1) + ' / 7 階'], ['解鎖條件', '段位升到 ' + nm]] })} style={{ cursor: 'pointer', flex: '0 0 calc(33.33% - 8px)', textAlign: 'center' }}>
              <div style={{ display: 'inline-block', opacity: on ? 1 : 0.35, filter: on ? 'none' : 'grayscale(1)' }}>
                <DefaultAvatar size={72} />
              </div>
              <p style={{ margin: '6px 0 0', fontSize: 12, fontWeight: 700, color: on ? 'var(--ink)' : 'var(--gray-2)' }}>{nm}</p>
            </div>
          ))}
        </div>
      </div>
    </div>, document.body
  )
}


function ClosetPage({ onBack, onPick }) {
  // 小熊衣櫥：幫養成小熊裝扮的配件
  const ITEMS = [['🎀', '蝴蝶結', 1], ['🧣', '圍巾', 1], ['🎩', '紳士帽', 0], ['👑', '小皇冠', 0], ['🕶️', '墨鏡', 0], ['🧢', '鴨舌帽', 1], ['🎓', '學士帽', 0], ['🌸', '櫻花髮飾', 1], ['⛄', '雪人裝', 0]]
  const got = ITEMS.filter((b) => b[2]).length
  return createPortal(
    <div className="sheet-anim" style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: 'var(--white)', zIndex: 1000, display: 'flex', flexDirection: 'column' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '16px 16px 12px', borderBottom: '.5px solid var(--gray-4)' }}>
        <button onClick={onBack} style={{ background: 'none', border: 'none', fontSize: 22, color: 'var(--ink)', cursor: 'pointer' }}>‹</button>
        <span style={{ fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>小熊衣櫥</span>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '16px 16px 24px' }}>
        <div style={{ padding: '0 0 4px' }}><span style={{ fontSize: 'var(--s)', fontWeight: 800, color: 'var(--ink)' }}>已擁有 {got} / {ITEMS.length}</span></div>
        <p style={{ margin: '6px 0 14px', fontSize: 'var(--xs)', color: 'var(--gray-2)', lineHeight: 1.6 }}>收集配件，幫你的養成小熊換裝打扮。</p>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12 }}>
          {ITEMS.map(([e, n, on]) => (
            <div key={n} onClick={() => onPick({ kind: '小熊衣櫥', emoji: e, name: n, got: !!on, desc: on ? '幫養成小熊換上「' + n + '」' : '解鎖後可幫小熊裝扮', kv: [['類型', '配件'], ['狀態', on ? '已擁有' : '未解鎖']] })} style={{ cursor: 'pointer', flex: '0 0 calc(33.33% - 8px)', textAlign: 'center' }}>
              <div style={{ width: '100%', aspectRatio: '1', borderRadius: '50%', background: on ? 'var(--brand-light)' : 'var(--field-bg)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 32, opacity: on ? 1 : 0.4, filter: on ? 'none' : 'grayscale(1)' }}>{e}</div>
              <p style={{ margin: '6px 0 0', fontSize: 12, fontWeight: 700, color: on ? 'var(--ink)' : 'var(--gray-2)' }}>{n}</p>
            </div>
          ))}
        </div>
      </div>
    </div>, document.body
  )
}

/* ===== 每日簽到主題頁（教練熊特訓 7 天）===== */
/* ===== 點心庫存抽屜（餅乾pill點開，物品欄格子風）===== */
/* ===== 養成熊改名（inline 輸入，不用 prompt，相容 LIFF）===== */
/* ===== 通用文字編輯彈窗（暱稱 / 自我介紹，inline 不用 prompt，相容 LIFF）===== */
function EditTextSheet({ title, placeholder, init, maxLen = 20, multiline, onSave, onClose, z = 1300 }) {
  const [val, setVal] = useState(init || '')
  const save = () => { const v = val.trim(); onSave(v); onClose() }
  return createPortal(
    <div className="ov-anim" onClick={(e) => { if (e.target === e.currentTarget) onClose() }} style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: 'rgba(46,43,44,0.4)', display: 'flex', alignItems: 'flex-end', zIndex: z }}>
      <div className="sheet-anim" style={{ width: '100%', background: 'var(--white)', borderRadius: '22px 22px 0 0', padding: '8px 20px calc(20px + env(safe-area-inset-bottom))' }}>
        <div style={{ width: 38, height: 4, borderRadius: 'var(--r-pill)', background: 'var(--gray-3)', margin: '6px auto 14px' }} />
        <p style={{ margin: '0 0 14px', fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>{title}</p>
        {multiline
          ? <textarea value={val} onChange={(e) => setVal(e.target.value)} maxLength={maxLen} placeholder={placeholder} rows={3} style={{ width: '100%', border: '1.5px solid var(--gray-3)', background: 'var(--white)', borderRadius: 'var(--r-field)', padding: '11px 14px', fontSize: 'var(--m)', color: 'var(--ink)', outline: 'none', boxSizing: 'border-box', resize: 'none', fontFamily: 'inherit' }} />
          : <input value={val} onChange={(e) => setVal(e.target.value)} maxLength={maxLen} placeholder={placeholder} style={{ width: '100%', border: '1.5px solid var(--gray-3)', background: 'var(--white)', borderRadius: 'var(--r-field)', padding: '12px 14px', fontSize: 'var(--m)', color: 'var(--ink)', outline: 'none', boxSizing: 'border-box' }} />}
        <div style={{ textAlign: 'right', fontSize: 11, color: 'var(--gray-2)', margin: '6px 2px 0' }}>{val.length}/{maxLen}</div>
        <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
          <button className="ibtn" onClick={onClose} style={{ flex: 1, padding: '12px 0', fontSize: 'var(--m)', fontWeight: 700, background: 'var(--gray-4)', color: 'var(--gray-1)' }}>取消</button>
          <button className="ibtn" onClick={save} style={{ flex: 1, padding: '12px 0', fontSize: 'var(--m)', fontWeight: 700, background: 'var(--ink)', color: 'var(--white)' }}>儲存</button>
        </div>
      </div>
    </div>, document.body)
}

function RenameBearSheet({ val, setVal, onSave, onClose, z = 1300 }) {
  return createPortal(
    <div className="ov-anim" onClick={(e) => { if (e.target === e.currentTarget) onClose() }} style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: 'rgba(46,43,44,0.4)', display: 'flex', alignItems: 'flex-end', zIndex: z }}>
      <div className="sheet-anim" style={{ width: '100%', background: 'var(--white)', borderRadius: '22px 22px 0 0', padding: '8px 20px calc(20px + env(safe-area-inset-bottom))' }}>
        <div style={{ width: 38, height: 4, borderRadius: 'var(--r-pill)', background: 'var(--gray-3)', margin: '6px auto 14px' }} />
        <p style={{ margin: '0 0 4px', fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>幫小熊取名</p>
        <p style={{ margin: '0 0 14px', fontSize: 'var(--xs)', color: 'var(--gray-2)' }}>取個喜歡的名字吧</p>
        <input value={val} onChange={(e) => setVal(e.target.value)} maxLength={6} placeholder="輸入名字" style={{ width: '100%', border: 'none', background: 'var(--field-bg)', borderRadius: 'var(--r-field)', padding: '12px 14px', fontSize: 'var(--m)', color: 'var(--ink)', outline: 'none', boxSizing: 'border-box' }} />
        <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
          <button className="ibtn" onClick={onClose} style={{ flex: 1, padding: '12px 0', fontSize: 'var(--m)', fontWeight: 700, background: 'var(--gray-4)', color: 'var(--gray-1)' }}>取消</button>
          <button className="ibtn" onClick={onSave} style={{ flex: 1, padding: '12px 0', fontSize: 'var(--m)', fontWeight: 700, background: 'var(--ink)', color: 'var(--white)' }}>儲存</button>
        </div>
      </div>
    </div>, document.body)
}

function SnackSheet({ onClose, snacks, onFeed }) {
  const SNACKS = [
    { key: 'cookie', e: '🍪', img: SNACK_IMGS.cookie, n: '小熊餅乾', grow: 10 },
    { key: 'milktea', e: '🧋', img: SNACK_IMGS.milktea, n: '珍珠奶茶', grow: 15 },
    { key: 'pudding', e: '🍮', img: SNACK_IMGS.pudding, n: '焦糖布丁', grow: 25 },
    { key: 'tiramisu', e: '🍰', img: SNACK_IMGS.tiramisu, n: '提拉米蘇', grow: 50 },
    { key: 'cupcake', e: '🧁', img: SNACK_IMGS.cupcake, n: '杯子蛋糕', grow: 20 },
    { key: 'donut', e: '🍩', img: SNACK_IMGS.donut, n: '甜甜圈', grow: 18 },
  ]
  return (
    <DragSheet onClose={onClose} title="小熊的點心櫃" subtitle="收集店裡的點心，餵給小熊長大（不同點心成長不同）">
      <div>
        {SNACKS.map((x, i) => {
          const have = snacks[x.key] || 0
          const owned = have > 0
          return (
            <div key={x.key} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '12px 0', borderBottom: i === SNACKS.length - 1 ? 'none' : '.5px solid var(--gray-4)', opacity: owned ? 1 : 0.85 }}>
              <span style={{ width: 44, height: 44, flex: '0 0 44px', display: 'inline-flex', borderRadius: '50%', overflow: 'hidden' }}><img src={x.img} alt={x.n} width="44" height="44" style={{ display: 'block', filter: owned ? 'none' : 'grayscale(1)', opacity: owned ? 1 : 0.6 }} /></span>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
                  <span style={{ fontSize: 'var(--m)', fontWeight: 700, color: 'var(--ink)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{x.n}</span>
                  {owned && <span style={{ flex: '0 0 auto', color: 'var(--accent)', fontSize: 'var(--m)', fontWeight: 800 }}>{'\u00d7' + have}</span>}
                </div>
                <div style={{ fontSize: 11, marginTop: 3, color: 'var(--gray-2)', fontWeight: 700 }}>{owned ? '成長 +' + x.grow : '店裡消費可獲得'}</div>
              </div>
              {owned
                ? <button className="ibtn" onClick={() => { onFeed(x.key, x.grow); showToast('餵了小熊 ' + x.n + ' \u00b7 成長+' + x.grow) }} style={{ flex: '0 0 auto', padding: '8px 18px', fontSize: 'var(--xs)', fontWeight: 700, background: 'var(--ink)', color: 'var(--white)' }}>餵小熊</button>
                : <span style={{ flex: '0 0 auto', padding: '8px 16px', fontSize: 'var(--xs)', fontWeight: 700, background: 'var(--gray-4)', color: 'var(--gray-2)', borderRadius: 'var(--r-pill)' }}>未獲得</span>}
            </div>
          )
        })}
      </div>
      <button className="ibtn" onClick={onClose} style={{ width: '100%', marginTop: 16, padding: '12px 0', fontSize: 'var(--m)', fontWeight: 700, background: 'var(--gray-4)', color: 'var(--gray-1)' }}>關閉</button>
    </DragSheet>
  )
}
function CheckinPage({ onBack, onClaim, claimed, season = true }) {
  // 7 天節點：done已領 / today今天 / 之後未到。w=麻將牌字(哨), 否則餅乾+數量, coach=教練熊造型
  const DAYS = [
    { d: 1, done: true },
    { d: 2, done: true },
    { d: 3, today: true, qty: 2 },
    { d: 4, qty: 2 },
    { d: 5, tile: '哨' },
    { d: 6, qty: 3 },
    { d: 7, coach: true },
  ]
  const Node = ({ x }) => {
    let inner, ring
    if (x.done) { ring = { background: 'var(--accent)', color: 'var(--white)', fontSize: 22, fontWeight: 900 }; inner = <span style={{ fontWeight: 900, fontSize: 22 }}>{'\u2713'}</span> }
    else if (x.coach) { ring = { background: 'var(--brand)', overflow: 'hidden' }; inner = <img src={COACH_BEAR} alt="" width="100%" height="100%" style={{ display: 'block' }} /> }
    else if (x.tile) { ring = { background: 'var(--gray-3)' }; inner = <span style={{ fontSize: 20 }}>{'\ud83d\udce3'}</span> }
    else { // 餅乾+數量
      ring = x.today ? { background: 'var(--white)', border: '2px solid var(--accent)', boxShadow: '0 2px 8px rgba(194,96,122,.25)' } : { background: 'var(--gray-3)' }
      inner = <><span style={{ width: x.today ? 20 : 18, height: x.today ? 20 : 18, borderRadius: '50%', overflow: 'hidden', display: 'inline-flex' }}><img src={SNACK_IMGS.cookie} alt="" width="100%" height="100%" style={{ display: 'block' }} /></span><span style={{ fontSize: 10, fontWeight: 700, color: x.today ? 'var(--accent)' : 'var(--gray-1)' }}>{'\u00d7' + x.qty}</span></>
    }
    const sz = (x.today || x.coach) ? 48 : 44
    const labelColor = x.done ? 'var(--accent)' : x.coach ? 'var(--accent)' : x.today ? 'var(--accent)' : 'var(--gray-1)'
    return (
      <div style={{ textAlign: 'center' }}>
        <div style={{ width: sz, height: sz, borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto', position: 'relative', zIndex: 2, lineHeight: 1, ...ring }}>{inner}</div>
        <div style={{ fontSize: 9, color: labelColor, fontWeight: (x.done || x.today || x.coach) ? 700 : 400, marginTop: 5 }}>第{x.d}天{x.coach ? ' 造型' : ''}</div>
      </div>
    )
  }
  return createPortal(
    <div className="sheet-anim" style={{ position: 'fixed', inset: 0, background: 'var(--white)', zIndex: 1100, display: 'flex', flexDirection: 'column' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '16px 16px 12px', borderBottom: '.5px solid var(--gray-4)', flex: '0 0 auto' }}>
        <button onClick={onBack} style={{ background: 'none', border: 'none', fontSize: 22, color: 'var(--ink)', cursor: 'pointer' }}>{'\u2039'}</button>
        <span style={{ fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>每日報到</span>
      </div>
      <div style={{ flex: 1, overflowY: 'auto' }}>
        {/* Hero */}
        <div style={{ background: 'var(--brand)', padding: '18px 18px 16px', textAlign: 'center' }}>
          {season
            ? <div style={{ width: 62, height: 62, margin: '0 auto 8px', borderRadius: '50%', overflow: 'hidden', background: 'var(--white)' }}><img src={COACH_BEAR} alt="教練熊" width="100%" height="100%" style={{ display: 'block' }} /></div>
            : <div style={{ width: 62, height: 62, margin: '0 auto 8px', borderRadius: '50%', background: 'var(--white)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}><span style={{ fontSize: 30 }}>{'\ud83d\udcc5'}</span></div>}
          <p style={{ margin: 0, fontSize: 'var(--xl)', fontWeight: 800, color: 'var(--ink)' }}>抽屜的日記</p>
          <p style={{ margin: '8px 0 0', fontSize: 'var(--xs)', color: 'var(--gray-1)' }}>{season ? '每天來報到，教練熊陪你變厲害' : '每天來報到，累積連續天數領獎勵'}</p>
        </div>
        {/* 第一排 1-4 */}
        <div style={{ padding: '22px 16px 0' }}>
          <div style={{ position: 'relative', margin: '0 14px' }}>
            <div style={{ position: 'absolute', left: 0, right: 0, top: 20, height: 3, background: 'var(--gray-4)' }} />
            <div style={{ position: 'absolute', left: 0, width: '66%', top: 20, height: 3, background: 'var(--accent)' }} />
            <div style={{ display: 'flex', justifyContent: 'space-between', position: 'relative' }}>
              {DAYS.slice(0, 4).map((x) => <Node key={x.d} x={x} />)}
            </div>
          </div>
        </div>
        {/* 第二排 5-7 */}
        <div style={{ padding: '18px 16px 6px' }}>
          <div style={{ position: 'relative', margin: '0 34px' }}>
            <div style={{ position: 'absolute', left: 0, right: 0, top: 20, height: 3, background: 'var(--gray-4)' }} />
            <div style={{ display: 'flex', justifyContent: 'space-between', position: 'relative' }}>
              {DAYS.slice(4).map((x) => <Node key={x.d} x={x} />)}
            </div>
          </div>
        </div>
        <div style={{ padding: '12px 18px 4px', textAlign: 'center' }}>
          <span style={{ fontSize: 'var(--xs)', color: 'var(--gray-1)' }}>再 4 天領 <b style={{ color: 'var(--accent)' }}>{season ? '教練熊造型' : '限定大獎'}</b></span>
        </div>
        <div style={{ padding: '12px 18px 24px' }}>
          <button className="ibtn" disabled={claimed} onClick={() => { onClaim(2); showToast('領到小熊餅乾 \u00d72', false, SNACK_IMGS.cookie) }} style={{ width: '100%', padding: '13px 0', fontSize: 'var(--m)', fontWeight: 700, background: claimed ? 'var(--field-bd)' : 'var(--ink)', color: 'var(--white)' }}>{claimed ? '今天已報到' : '今日報到 \u00b7 領獎勵'}</button>
        </div>
      </div>
    </div>, document.body)
}

// ===== 養成小熊：成長階段換圖（依 Lv 選圖，無圖 fallback DefaultAvatar）=====
// 圖放 src/assets/ 並在 images.js 註冊（Vite hash 管理）
function bearStageSrc(lv) {
  const stage = lv >= 20 ? 20 : lv >= 10 ? 10 : 1
  return BEAR_LV[stage] || BEAR_LV[1]
}
function BearStageImg({ lv, size = 150 }) {
  const [broken, setBroken] = useState(false)
  const src = bearStageSrc(lv)
  if (broken) return <DefaultAvatar size={size} />
  return <img src={src} alt="" width="100%" height="100%" style={{ display: 'block', transform: 'scale(1.09)' }} onError={() => setBroken(true)} />
}
// 狀態台詞：依情境回一句話
function bearMood({ justFed, grow, lv }) {
  if (justFed) { const m = ['謝謝你，我又更有精神了。', '營養補滿，繼續加油！', '感覺又成長了一點。']; return m[Math.floor(Math.random() * m.length)] }
  if (grow >= 80) return '再一點點就能升級了。'
  if (grow <= 15) return '有點餓了，補充點能量吧。'
  const idle = ['今天也一起加油吧。', '好久不見，今天想打牌嗎？', '保持好心情，牌運會更好。', '今天想打什麼牌呢。', '休息夠了，再戰一局吧。']
  return idle[lv % idle.length]
}

function useCountdown(init) {
  const [t, setT] = useState(init)
  useEffect(() => {
    const iv = setInterval(() => setT((p) => {
      let { d, h, m, s } = p; s--
      if (s < 0) { s = 59; m--; if (m < 0) { m = 59; h--; if (h < 0) { h = 23; d-- } } }
      return { d, h, m, s }
    }), 1000)
    return () => clearInterval(iv)
  }, [])
  return t.d + '天' + t.h + '時' + t.m + '分' + t.s + '秒'
}
function WeeklyTaskPage({ onBack, onClaim, season = true }) {
  const [tasks, setTasks] = useState([
    { t: (season ? '教練說：' : '') + '來店打 3 場', n: 3, done: true, claimed: false },
    { t: (season ? '教練說：' : '') + '點二杯飲料 (1/2)', n: 3, done: false, claimed: false },
    { t: (season ? '教練說：' : '') + '參加 1 場配桌', n: 3, done: false, claimed: false },
    { t: (season ? '教練說：' : '') + '跟朋友一起包桌', n: 5, done: false, claimed: false },
  ])
  const claim = (i) => { setTasks((a) => a.map((x, j) => j === i ? { ...x, claimed: true } : x)); onClaim(tasks[i].n); showToast('領到小熊餅乾 \u00d7' + tasks[i].n, false, SNACK_IMGS.cookie) }
  const doneCount = tasks.filter((x) => x.claimed || x.done).length
  return createPortal(
    <div className="sheet-anim" style={{ position: 'fixed', inset: 0, background: 'var(--white)', zIndex: 1100, display: 'flex', flexDirection: 'column' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '16px 16px 12px', borderBottom: '.5px solid var(--gray-4)', flex: '0 0 auto' }}>
        <button onClick={onBack} style={{ background: 'none', border: 'none', fontSize: 22, color: 'var(--ink)', cursor: 'pointer' }}>{'\u2039'}</button>
        <span style={{ fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>每週任務</span>
      </div>
      <div style={{ flex: 1, overflowY: 'auto' }}>
        {/* Hero：教練熊課表 + 進度條 + 總目標獎 */}
        <div style={{ background: 'var(--brand)', padding: '16px 18px 15px', textAlign: 'center' }}>
          {season
            ? <div style={{ width: 62, height: 62, margin: '0 auto 8px', borderRadius: '50%', overflow: 'hidden', background: 'var(--white)' }}><img src={COACH_BEAR} alt="" width="100%" height="100%" style={{ display: 'block' }} /></div>
            : <div style={{ width: 62, height: 62, margin: '0 auto 8px', borderRadius: '50%', background: 'var(--white)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}><span style={{ fontSize: 30 }}>{'\ud83c\udf92'}</span></div>}
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8 }}>
            <span style={{ fontSize: 'var(--m)', fontWeight: 700, color: 'var(--ink)' }}>{season ? '教練熊的本週課表' : '書包裡的功課'}</span>
          </div>
          <div style={{ marginTop: 10, display: 'flex', alignItems: 'center', gap: 8, justifyContent: 'center' }}>
            <div style={{ width: 150, height: 8, background: 'rgba(255,255,255,0.6)', borderRadius: 'var(--r-pill)', overflow: 'hidden' }}><div style={{ height: '100%', width: (doneCount / tasks.length * 100) + '%', background: 'var(--accent)', borderRadius: 'var(--r-pill)', transition: 'width .4s' }} /></div>
            <span style={{ fontSize: 'var(--xs)', fontWeight: 800, color: 'var(--ink)' }}>{doneCount}/{tasks.length}</span>
          </div>
          {season
            ? <p style={{ margin: '8px 0 0', fontSize: 'var(--xs)', color: 'var(--gray-1)' }}>完成整週課表，解鎖教練熊哨子配件</p>
            : <div style={{ margin: '12px auto 0', display: 'inline-flex', alignItems: 'center', gap: 6, background: 'var(--white)', borderRadius: 'var(--r-pill)', padding: '6px 14px' }}><span style={{ fontSize: 'var(--xs)', color: 'var(--gray-1)', fontWeight: 700 }}>全部完成領</span><span style={{ fontSize: 'var(--l)', fontWeight: 800, color: 'var(--accent)', lineHeight: 1 }}>50</span><span style={{ fontSize: 'var(--xs)', color: 'var(--gray-1)', fontWeight: 700 }}>點</span></div>}
        </div>
        {/* 任務清單：圓勾 tdot */}
        <div style={{ padding: '8px 20px 18px' }}>
          {tasks.map((x, i) => {
            const ok = x.claimed || x.done
            return (
              <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '13px 0', borderTop: i === 0 ? 'none' : '1px solid var(--gray-4)' }}>
                <span style={{ width: 24, height: 24, borderRadius: '50%', flex: '0 0 24px', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 13, fontWeight: 900, background: ok ? 'var(--accent)' : 'transparent', color: 'var(--white)', border: ok ? 'none' : '2px solid var(--field-bd)' }}>{ok ? '\u2713' : ''}</span>
                <div style={{ flex: 1, fontSize: 'var(--s)', fontWeight: 700, color: 'var(--ink)' }}>{x.t}</div>
                {x.claimed
                  ? <span style={{ fontSize: 'var(--xs)', color: 'var(--gray-2)', fontWeight: 700 }}>已領</span>
                  : <button className="ibtn" onClick={() => x.done && claim(i)} style={{ padding: '6px 14px', fontSize: 'var(--xs)', fontWeight: 700, background: x.done ? 'var(--ink)' : 'var(--gray-4)', color: x.done ? 'var(--white)' : 'var(--gray-2)' }}>{x.done ? '領 \ud83c\udf6a\u00d7' + x.n : '\ud83c\udf6a\u00d7' + x.n}</button>}
              </div>
            )
          })}
        </div>
      </div>
    </div>, document.body)
}
function EventPage({ onBack }) {
  const cd = useCountdown({ d: 23, h: 5, m: 12, s: 8 })
  const stages = [
    { at: '5場', reward: '哨子', done: true }, { at: '10場', reward: '稱號', done: true },
    { at: '15場', reward: '頭像', icon: '\ud83c\udf80' }, { at: '20場', reward: '牌尺', coach: true },
  ]
  return createPortal(
    <div className="sheet-anim" style={{ position: 'fixed', inset: 0, background: 'var(--white)', zIndex: 1100, display: 'flex', flexDirection: 'column' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '16px 16px 12px', borderBottom: '.5px solid var(--gray-4)', flex: '0 0 auto' }}>
        <button onClick={onBack} style={{ background: 'none', border: 'none', fontSize: 22, color: 'var(--ink)', cursor: 'pointer' }}>{'\u2039'}</button>
        <span style={{ fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>限時活動</span>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', paddingBottom: 24 }}>
        {/* Hero：本季訪客(小灰字) + 教練熊特訓週 */}
        <div style={{ background: 'var(--brand)', padding: '18px 18px 16px', textAlign: 'center' }}>
          <p style={{ margin: '0 0 2px', fontSize: 'var(--xs)', color: 'var(--gray-1)', fontWeight: 600 }}>本季訪客</p>
          <p style={{ margin: '0 0 10px', fontSize: 'var(--xl)', fontWeight: 800, color: 'var(--ink)' }}>教練熊</p>
          <div style={{ width: 76, height: 76, margin: '0 auto', borderRadius: '50%', overflow: 'hidden', background: 'var(--white)', boxShadow: 'var(--shadow-sm)' }}><img src={COACH_BEAR} alt="" width="100%" height="100%" style={{ display: 'block' }} /></div>
          <p style={{ margin: '8px 0 8px', fontSize: 'var(--xs)', color: 'var(--gray-1)' }}>「跟著我特訓，證明你的實力！」</p>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, background: 'var(--ink)', color: 'var(--white)', borderRadius: 'var(--r-pill)', padding: '5px 13px', fontSize: 'var(--xs)', fontWeight: 800, fontVariantNumeric: 'tabular-nums' }}>活動倒數 {cd}</span>
        </div>

        {/* 每週優惠 (v2排版: sect標題+sectsub副標) */}
        <div style={{ padding: '18px 20px 4px' }}>
          <p style={{ margin: 0, fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>教練熊每週請客</p>
          <p style={{ margin: '2px 0 12px', fontSize: 'var(--xs)', color: 'var(--gray-2)' }}>活動期間限定 · 每週固定回饋</p>
          <div style={{ display: 'flex', alignItems: 'center', gap: 13, background: 'var(--field-bg)', borderRadius: 'var(--r-card)', padding: '14px 16px' }}>
            <span className="itile" style={{ width: 30, height: 38, background: 'var(--brand)', color: 'var(--ink)', fontSize: 'var(--l)', flex: '0 0 30px' }}>折</span>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 'var(--s)', fontWeight: 700, color: 'var(--ink)' }}>每週二 · 點數優惠 7 折</div>
              <div style={{ fontSize: 'var(--xs)', color: 'var(--gray-1)', marginTop: 1 }}>每週二來店，檯費點數 7 折</div>
            </div>
          </div>
        </div>

        {/* 特訓積累 (v2排版: 進度條節點) */}
        <div style={{ padding: '18px 20px 4px' }}>
          <p style={{ margin: 0, fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>教練熊特訓班</p>
          <p style={{ margin: '2px 0 0', fontSize: 'var(--xs)', color: 'var(--gray-2)' }}>整季拚場數 · 分階段解鎖教練熊限定獎勵</p>
          <div style={{ position: 'relative', margin: '18px 6px 4px' }}>
            <div style={{ position: 'absolute', left: 0, right: 0, top: 32, height: 3, background: 'var(--gray-4)' }} />
            <div style={{ position: 'absolute', left: 0, width: '55%', top: 32, height: 3, background: 'var(--accent)' }} />
            <div style={{ display: 'flex', justifyContent: 'space-between', position: 'relative' }}>
              {stages.map((st, i) => (
                <div key={i} style={{ textAlign: 'center' }}>
                  <div style={{ fontSize: 10, color: 'var(--gray-1)', marginBottom: 4, fontWeight: 700 }}>{st.at}</div>
                  <div style={{ width: 28, height: 28, borderRadius: '50%', background: st.done ? 'var(--accent)' : st.coach ? 'var(--ink)' : 'var(--brand)', color: st.done ? 'var(--white)' : 'var(--accent)', fontSize: st.coach ? 0 : 12, display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto', overflow: 'hidden' }}>
                    {st.done ? '\u2713' : st.coach ? <img src={COACH_BEAR} alt="" width="100%" height="100%" style={{ display: 'block' }} /> : st.icon}
                  </div>
                  <div style={{ fontSize: 10, color: 'var(--ink)', fontWeight: 700, marginTop: 4 }}>{st.reward}</div>
                </div>
              ))}
            </div>
          </div>
          <div style={{ marginTop: 12, background: 'var(--field-bg)', borderRadius: 'var(--r-field)', padding: '11px 13px', textAlign: 'center', fontSize: 'var(--xs)', color: 'var(--gray-1)' }}>目前 <b style={{ color: 'var(--ink)' }}>12</b> 場 · 再 3 場解鎖頭像</div>
        </div>

        {/* 排位賽 (v2排版: 粉底大卡) */}
        <div style={{ padding: '18px 20px 8px' }}>
          <p style={{ margin: 0, fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>跟著教練熊衝排名</p>
          <p style={{ margin: '2px 0 12px', fontSize: 'var(--xs)', color: 'var(--gray-2)' }}>賽季成績拚排名，前 100 名可拿到教練熊 AI 分析工具</p>
          <div style={{ background: 'var(--brand)', borderRadius: 'var(--r-lg)', padding: '16px 16px 14px' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
              <div><div style={{ fontSize: 11, color: 'var(--gray-1)' }}>你目前排名</div><div style={{ fontSize: 26, fontWeight: 800, color: 'var(--ink)', lineHeight: 1.2 }}>#128</div></div>
              <div style={{ textAlign: 'right' }}><div style={{ fontSize: 11, color: 'var(--gray-1)' }}>距離前 100 名</div><div style={{ fontSize: 14, fontWeight: 700, color: 'var(--accent)' }}>還差 28 名</div></div>
            </div>
          </div>
          <button className="ibtn" onClick={() => showToast('前往排行榜')} style={{ width: '100%', marginTop: 12, padding: '12px 0', fontSize: 'var(--m)', fontWeight: 700, background: 'var(--ink)', color: 'var(--white)' }}>看完整排行榜</button>
        </div>
      </div>
    </div>, document.body)
}
function GachaPage({ onBack, season = true }) {
  const [phase, setPhase] = useState('idle') // idle | draw | reveal | draw10 | reveal10
  const [prize, setPrize] = useState(null)
  const [poolOpen, setPoolOpen] = useState(false)
  const [tenResults, setTenResults] = useState([])
  // 四階獎品池（B版：餅乾四階遞增 + 其他固定）。tier: norm/rare/epic/legend
  const POOL = {
    norm:   { label: '普通', prob: 61, items: [ { e: '🍪', img: SNACK_IMGS.cookie, n: '餅乾 ×1' }, { e: '🍡', n: '點心 ×1' }, { e: '🧋', n: '飲料兌換券' } ] },
    rare:   { label: '稀有', prob: 28, items: [ { e: '🍪', img: SNACK_IMGS.cookie, n: '餅乾 ×3' }, { e: '🎫', n: '檯費折抵券 50 元' }, { e: '🍰', n: '高級點心 · 提拉米蘇' }, { e: '🎟️', n: '點心兌換券' } ] },
    epic:   { label: '史詩', prob: 9,  items: [ { e: '🍪', img: SNACK_IMGS.cookie, n: '餅乾 ×5' }, { e: '🎀', n: 'MIGI 熊配件' }, { e: '🖼️', n: 'MIGI 熊限定頭像' } ] },
    legend: { label: '傳說', prob: 2,  items: [ { e: '🍪', img: SNACK_IMGS.cookie, n: '餅乾 ×10' }, { e: '📏', n: 'MIGI 熊牌尺' }, { e: '👕', n: 'MIGI 熊T恤' } ] },
  }
  const TIERS = ['norm', 'rare', 'epic', 'legend']
  const pickTier = () => { let r = Math.random() * 100, a = 0; for (const t of TIERS) { a += POOL[t].prob; if (r <= a) return t } return 'norm' }
  const draw = async () => {
    if (phase !== 'idle') return
    const t = pickTier(); const its = POOL[t].items; const it = its[Math.floor(Math.random() * its.length)]
    setPrize({ tier: t, ...it })
    setPhase('draw'); await new Promise((r) => setTimeout(r, 1600))
    setPhase('reveal')
  }
  const close = () => { setPhase('idle'); setPrize(null) }
  const drawTen = async () => {
    if (phase !== 'idle') return
    const results = []
    for (let i = 0; i < 10; i++) { const t = pickTier(); const its = POOL[t].items; const it = its[Math.floor(Math.random() * its.length)]; results.push({ tier: t, ...it }) }
    setTenResults(results)
    setPhase('draw10'); await new Promise((r) => setTimeout(r, 1600))
    setPhase('reveal10')
  }
  const closeTen = () => { setPhase('idle'); setTenResults([]) }
  // 稀有度視覺設定
  const TIER_UI = {
    norm:   { name: '普通', color: 'rgba(255,255,255,.85)', ring: 'var(--milktea)', iconBg: 'var(--white)',    iconText: 'var(--ink)', btn: 'var(--white)',    btnText: 'var(--ink)', ovl: 'rgba(46,43,44,0.55)', glow: false, sparkle: false, halo: false },
    rare:   { name: '稀有', color: 'var(--milktea)',              ring: 'var(--milktea)', iconBg: 'var(--white)',    iconText: 'var(--ink)', btn: 'var(--milktea)', btnText: 'var(--ink)', ovl: 'rgba(46,43,44,0.55)', glow: false, sparkle: true,  halo: false },
    epic:   { name: '史詩', color: 'var(--brand)',              ring: 'var(--brand)', iconBg: 'var(--white)',    iconText: 'var(--ink)', btn: 'var(--brand)', btnText: 'var(--ink)', ovl: 'rgba(46,43,44,0.62)', glow: true,  sparkle: false, halo: false },
    legend: { name: '傳說', color: 'var(--gold)',              ring: 'var(--gold)', iconBg: 'var(--ink)', iconText: 'var(--white)',    btn: 'var(--gold)', btnText: 'var(--ink)', ovl: 'rgba(46,43,44,0.74)', glow: true,  sparkle: false, halo: true },
  }
  const ui = prize ? TIER_UI[prize.tier] : TIER_UI.norm
  return createPortal(
    <div className="sheet-anim" style={{ position: 'fixed', inset: 0, background: 'var(--white)', zIndex: 1100, display: 'flex', flexDirection: 'column' }}>
      <style>{`
        @keyframes migiSweep { 0% { left: -50%; } 100% { left: 120%; } }
        @keyframes migiRub { 0%,100% { transform: translateX(-3px) rotate(-3deg); } 50% { transform: translateX(3px) rotate(3deg); } }
        @keyframes migiPop { 0% { transform: scale(.3); opacity: 0; } 60% { transform: scale(1.1); } 100% { transform: scale(1); opacity: 1; } }
        @keyframes migiGlow { 0%,100% { box-shadow: 0 0 20px 4px rgba(232,184,155,.55); } 50% { box-shadow: 0 0 36px 12px rgba(232,184,155,.9); } }
        @keyframes migiGlowPink { 0%,100% { box-shadow: 0 0 16px 3px rgba(250,214,220,.55); } 50% { box-shadow: 0 0 28px 9px rgba(250,214,220,.9); } }
        @keyframes migiTwinkle { 0%,100% { opacity: 0; transform: scale(.4); } 50% { opacity: 1; transform: scale(1); } }
        @keyframes migiSpin { to { transform: rotate(360deg); } }
        .migi-mjback { position: relative; border-radius: 8px; overflow: hidden; box-shadow: 0 6px 16px rgba(0,0,0,.3), inset 0 2px 3px rgba(255,255,255,.7), inset 0 -3px 6px rgba(0,0,0,.12); }
        .migi-mjback::after { content: ''; position: absolute; top: 0; left: -50%; width: 45%; height: 100%; background: linear-gradient(105deg, transparent, rgba(255,255,255,.85), transparent); transform: skewX(-18deg); animation: migiSweep 1.6s ease-in-out infinite; }
        .migi-rub { animation: migiRub .4s ease-in-out infinite; }
        .migi-pop { animation: migiPop .5s cubic-bezier(.2,.8,.3,1.2) forwards; }
      `}</style>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '16px 16px 12px', borderBottom: '.5px solid var(--gray-4)', flex: '0 0 auto' }}>
        <button onClick={onBack} style={{ background: 'none', border: 'none', fontSize: 22, color: 'var(--ink)', cursor: 'pointer' }}>{'\u2039'}</button>
        <span style={{ fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>隨機抽牌</span>
      </div>
      <div style={{ flex: 1, overflowY: 'auto' }}>
        {/* 卡池 Hero */}
        <div style={{ background: 'var(--brand)', padding: '20px 20px 18px', textAlign: 'center', position: 'relative' }}>
          <span style={{ position: 'absolute', top: 14, right: 16, display: 'inline-flex', alignItems: 'center', gap: 5, fontSize: 11, fontWeight: 700, color: 'var(--ink)', background: 'rgba(255,255,255,0.7)', borderRadius: 'var(--r-pill)', padding: '4px 12px' }}><span style={{ color: 'var(--gray-1)', fontWeight: 500 }}>我的點數</span>1,250</span>
          {season
            ? <><div style={{ width: 62, height: 62, margin: '0 auto 6px', borderRadius: '50%', overflow: 'hidden', background: 'var(--white)', boxShadow: 'var(--shadow-md)' }}><img src={COACH_BEAR} alt="教練熊" width="100%" height="100%" style={{ display: 'block' }} /></div>
            <p style={{ margin: '0 0 6px', fontSize: 'var(--m)', fontWeight: 800, color: 'var(--ink)' }}>教練熊牌堆</p>
            <p style={{ margin: 0, fontSize: 'var(--xs)', color: 'var(--gray-1)', lineHeight: 1.5 }}>「我是來幫大家變厲害的教練熊！<br />搓搓看，把我帶回家吧～」</p></>
            : <><div style={{ width: 62, height: 62, margin: '0 auto 6px', borderRadius: '50%', background: 'var(--white)', boxShadow: 'var(--shadow-md)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 30 }}>{'\ud83c\udc04'}</div>
            <p style={{ margin: '0 0 6px', fontSize: 'var(--m)', fontWeight: 800, color: 'var(--ink)' }}>牌桌上的麻將</p>
            <p style={{ margin: 0, fontSize: 'var(--xs)', color: 'var(--gray-1)', lineHeight: 1.5 }}>搓一張牌，抽各種優惠與造型配件</p></>}
        </div>
        {/* 保底進度條 */}
        <div style={{ padding: '16px 20px 4px' }}>
          {[{ label: '史詩保底', cur: 8, max: 20 }, { label: '傳說保底', cur: 8, max: 50 }].map((b) => (
            <div key={b.label} style={{ marginBottom: 11 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 5 }}>
                <span style={{ fontSize: 'var(--xs)', fontWeight: 700, color: 'var(--ink)' }}>{b.label}</span>
                <span style={{ fontSize: 'var(--xs)', color: 'var(--gray-2)' }}>{b.cur} / {b.max}</span>
              </div>
              <div style={{ height: 7, background: 'var(--gray-4)', borderRadius: 'var(--r-pill)', overflow: 'hidden' }}><div style={{ height: '100%', width: (b.cur / b.max * 100) + '%', background: 'var(--accent)', borderRadius: 'var(--r-pill)' }} /></div>
            </div>
          ))}
        </div>
        {/* 十連主打大按鈕 + 單抽 */}
        <div style={{ padding: '12px 20px 8px' }}>
          <button className="ibtn" onClick={drawTen} style={{ width: '100%', borderRadius: 'var(--r-pill)', padding: '16px 0', fontSize: 'var(--l)', fontWeight: 700, background: 'var(--ink)', color: 'var(--white)', marginBottom: 9 }}>搓 10 張 · 450 點 <span style={{ fontSize: 11, background: 'var(--accent)', color: 'var(--white)', fontWeight: 800, padding: '2px 8px', borderRadius: 'var(--r-pill)', marginLeft: 4 }}>省 50</span></button>
          <button className="ibtn" onClick={draw} style={{ width: '100%', borderRadius: 'var(--r-pill)', padding: '13px 0', fontSize: 'var(--m)', fontWeight: 700, background: 'var(--white)', border: '1.5px solid var(--ink)', color: 'var(--ink)' }}>搓 1 張 · 50 點</button>
          <p onClick={() => setPoolOpen(true)} style={{ margin: '14px 0 20px', textAlign: 'center', fontSize: 'var(--xs)', color: 'var(--accent)', fontWeight: 700, cursor: 'pointer' }}>查看獎品與機率 ›</p>
        </div>
      </div>

      {/* 搓牌動畫：全畫面灰遮罩 + 單張大牌搓（掃光反光） */}
      {phase === 'draw' && (
        <div style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: 'rgba(46,43,44,0.5)', zIndex: 1200, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center' }}>
          <div className="migi-mjback migi-rub" style={{ width: 70, height: 96, background: 'var(--brand)', marginBottom: 20 }} />
          <p style={{ margin: 0, fontSize: 'var(--l)', fontWeight: 700, color: 'var(--white)' }}>搓～搓～</p>
        </div>
      )}

      {/* 揭曉：四階 */}
      {phase === 'reveal' && prize && (
        <div style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: ui.ovl, zIndex: 1200, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', overflow: 'hidden' }}>
          {ui.halo && <>
            <div style={{ position: 'absolute', top: '44%', left: '50%', width: 360, height: 360, margin: '-180px 0 0 -180px', borderRadius: '50%', background: 'radial-gradient(circle, rgba(232,184,155,.75) 0%, rgba(232,184,155,.38) 22%, rgba(232,184,155,.14) 42%, transparent 66%)', zIndex: 0 }} />
            <div style={{ position: 'absolute', top: '44%', left: '50%', width: 340, height: 340, margin: '-170px 0 0 -170px', borderRadius: '50%', background: 'conic-gradient(from 0deg, transparent 0deg, rgba(232,184,155,.6) 8deg, transparent 26deg, transparent 45deg, rgba(232,184,155,.6) 53deg, transparent 71deg, transparent 90deg, rgba(232,184,155,.6) 98deg, transparent 116deg, transparent 135deg, rgba(232,184,155,.6) 143deg, transparent 161deg, transparent 180deg, rgba(232,184,155,.6) 188deg, transparent 206deg, transparent 225deg, rgba(232,184,155,.6) 233deg, transparent 251deg, transparent 270deg, rgba(232,184,155,.6) 278deg, transparent 296deg, transparent 315deg, rgba(232,184,155,.6) 323deg, transparent 341deg)', WebkitMask: 'radial-gradient(circle, transparent 17%, rgba(0,0,0,.7) 34%, transparent 66%)', mask: 'radial-gradient(circle, transparent 17%, rgba(0,0,0,.7) 34%, transparent 66%)', animation: 'migiSpin 16s linear infinite', zIndex: 0 }} />
          </>}
          <div className="migi-pop" style={{ textAlign: 'center', position: 'relative', zIndex: 3 }}>
            <div style={{ fontSize: 17, fontWeight: 800, letterSpacing: 2, marginBottom: 16, color: ui.color }}>{ui.name}</div>
            <div style={{ position: 'relative', width: 112, height: 112, margin: '0 auto 16px' }}>
              <div style={{ width: 112, height: 112, borderRadius: '50%', background: ui.iconBg, border: '2px solid ' + ui.ring, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 54, animation: ui.glow ? (prize.tier === 'legend' ? 'migiGlow 1.3s ease-in-out infinite' : 'migiGlowPink 1.4s ease-in-out infinite') : 'none' }}>{prize.img ? <span style={{ width: 72, height: 72, borderRadius: '50%', overflow: 'hidden', display: 'inline-flex' }}><img src={prize.img} alt="" width="100%" height="100%" style={{ display: 'block' }} /></span> : prize.e}</div>
              {ui.sparkle && [{ t: -6, l: 10, d: '0s', s: 14 }, { b: 8, r: -8, d: '.5s', s: 11 }, { t: 2, l: -6, d: '.9s', s: 12 }, { b: -4, r: 14, d: '1.2s', s: 10 }, { t: 14, r: -4, d: '1.5s', s: 10 }, { b: 20, l: -2, d: '.3s', s: 9 }].map((sp, i) => (
                <span key={i} style={{ position: 'absolute', top: sp.t != null ? sp.t : 'auto', bottom: sp.b != null ? sp.b : 'auto', left: sp.l != null ? sp.l : 'auto', right: sp.r != null ? sp.r : 'auto', color: 'var(--white)', fontSize: sp.s, animation: 'migiTwinkle 1.3s ease-in-out infinite', animationDelay: sp.d, textShadow: '0 0 6px rgba(255,255,255,.9)', zIndex: 3, pointerEvents: 'none' }}>{'\u2726'}</span>
              ))}
            </div>
            <p style={{ margin: '0 0 4px', fontSize: 'var(--l)', fontWeight: 800, color: 'var(--white)' }}>{prize.n}</p>
            <p style={{ margin: 0, fontSize: 'var(--s)', fontWeight: 700, color: 'rgba(255,255,255,.9)' }}>{prize.tier === 'legend' ? '恭喜！超稀有獎勵' : prize.tier === 'norm' ? '拿去餵小熊長大' : '收進你的獎勵'}</p>
            <button className="ibtn" onClick={close} style={{ border: 'none', borderRadius: 'var(--r-pill)', padding: '11px 0', fontSize: 'var(--s)', fontWeight: 700, width: 180, background: ui.btn, color: ui.btnText, marginTop: 20 }}>收下</button>
          </div>
        </div>
      )}

      {/* 十連搓牌動畫 */}
      {phase === 'draw10' && (
        <div style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: 'rgba(46,43,44,0.5)', zIndex: 1200, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center' }}>
          <div style={{ display: 'flex', gap: 6, justifyContent: 'center', marginBottom: 20 }}>
            {[0, 1, 2].map((i) => <div key={i} className="migi-mjback migi-rub" style={{ width: 48, height: 66, background: 'var(--brand)', animationDelay: (i * 0.12) + 's' }} />)}
          </div>
          <p style={{ margin: 0, fontSize: 'var(--l)', fontWeight: 700, color: 'var(--white)' }}>搓～搓～</p>
        </div>
      )}

      {/* 十連揭曉：2欄格狀(無方框, 各自稀有度效果) */}
      {phase === 'reveal10' && tenResults.length > 0 && (
        <div style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: 'rgba(46,43,44,0.62)', zIndex: 1200, display: 'flex', flexDirection: 'column', padding: '22px 20px 20px', overflowY: 'auto' }}>
          <p style={{ margin: '0 0 4px', textAlign: 'center', fontSize: 'var(--m)', fontWeight: 800, color: 'var(--white)' }}>搓 10 張！</p>
          <p style={{ margin: '0 0 20px', textAlign: 'center', fontSize: 'var(--xs)', color: 'rgba(255,255,255,.7)' }}>這次的收穫～</p>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '22px 10px' }}>
            {tenResults.map((r, i) => {
              const u = TIER_UI[r.tier]
              return (
                <div key={i} className="migi-pop" style={{ textAlign: 'center', position: 'relative', animationDelay: (i * 0.05) + 's' }}>
                  {u.halo && <div style={{ position: 'absolute', top: 31, left: '50%', width: 104, height: 104, transform: 'translate(-50%,-50%)', borderRadius: '50%', background: 'radial-gradient(circle, rgba(232,184,155,.85) 0%, rgba(232,184,155,.4) 40%, transparent 70%)', zIndex: 0, pointerEvents: 'none' }} />}
                  <div style={{ position: 'relative', width: 54, height: 54, margin: '0 auto 6px', zIndex: 2 }}>
                    <div style={{ width: 54, height: 54, borderRadius: '50%', background: u.iconBg, border: '2px solid ' + u.ring, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 26, animation: u.glow ? (r.tier === 'legend' ? 'migiGlow 1.3s ease-in-out infinite' : 'migiGlowPink 1.4s ease-in-out infinite') : 'none' }}>{r.img ? <span style={{ width: 36, height: 36, borderRadius: '50%', overflow: 'hidden', display: 'inline-flex' }}><img src={r.img} alt="" width="100%" height="100%" style={{ display: 'block' }} /></span> : r.e}</div>
                    {u.sparkle && [{ t: -5, l: -3, d: '0s', s: 11 }, { t: -3, r: -4, d: '.5s', s: 9 }, { b: -2, l: 2, d: '.9s', s: 10 }, { b: 0, r: -3, d: '1.2s', s: 8 }].map((sp, j) => (
                      <span key={j} style={{ position: 'absolute', top: sp.t != null ? sp.t : 'auto', bottom: sp.b != null ? sp.b : 'auto', left: sp.l != null ? sp.l : 'auto', right: sp.r != null ? sp.r : 'auto', color: 'var(--white)', fontSize: sp.s, animation: 'migiTwinkle 1.3s ease-in-out infinite', animationDelay: sp.d, textShadow: '0 0 6px rgba(255,255,255,.9)', zIndex: 3, pointerEvents: 'none' }}>{'\u2726'}</span>
                    ))}
                  </div>
                  <div style={{ fontSize: 10, fontWeight: 800, color: r.tier === 'legend' ? 'var(--gold)' : r.tier === 'epic' ? 'var(--brand)' : r.tier === 'rare' ? 'var(--milktea)' : 'var(--white)' }}>{u.name}</div>
                  <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--white)', marginTop: 1 }}>{r.n}</div>
                </div>
              )
            })}
          </div>
          <button className="ibtn" onClick={closeTen} style={{ width: '100%', marginTop: 22, border: 'none', borderRadius: 'var(--r-pill)', background: 'var(--white)', color: 'var(--ink)', padding: '13px 0', fontSize: 'var(--m)', fontWeight: 700, flex: '0 0 auto' }}>全部收下</button>
        </div>
      )}

      {poolOpen && (
        <div onClick={() => setPoolOpen(false)} style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: 'rgba(46,43,44,0.4)', display: 'flex', alignItems: 'flex-end', zIndex: 1400 }}>
          <div className="sheet-anim" onClick={(e) => e.stopPropagation()} style={{ width: '100%', background: 'var(--white)', borderRadius: '22px 22px 0 0', maxHeight: '78vh', display: 'flex', flexDirection: 'column' }}>
            <div style={{ padding: '10px 0 4px', display: 'flex', justifyContent: 'center', flex: '0 0 auto' }}><div style={{ width: 36, height: 4, background: 'var(--field-bd)', borderRadius: 'var(--r-pill)' }} /></div>
            <div style={{ padding: '6px 20px 12px', borderBottom: '.5px solid var(--gray-4)', flex: '0 0 auto', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}><p style={{ margin: 0, fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>獎品與機率</p><button onClick={() => setPoolOpen(false)} style={{ background: 'none', border: 'none', fontSize: 22, color: 'var(--gray-2)', cursor: 'pointer', lineHeight: 1 }}>×</button></div>
            <div style={{ padding: '8px 20px 28px', overflowY: 'auto' }}>
              {TIERS.slice().reverse().map((t) => {
                const p = POOL[t]
                return (
                  <div key={t} style={{ display: 'flex', alignItems: 'flex-start', gap: 10, padding: '10px 0', borderTop: '1px solid var(--field-bg)' }}>
                    <span style={{ minWidth: 40, fontSize: 'var(--xs)', fontWeight: 800, color: t === 'norm' ? 'var(--gray-2)' : t === 'rare' ? '#B8A48C' : t === 'epic' ? 'var(--accent)' : '#B8860B' }}>{p.label}</span>
                    <span style={{ flex: 1, fontSize: 'var(--xs)', color: 'var(--ink)', lineHeight: 1.6 }}>{p.items.map((it) => it.n).join('、')}</span>
                    <span style={{ fontSize: 'var(--s)', fontWeight: 800, color: 'var(--accent)', minWidth: 34, textAlign: 'right' }}>{p.prob}%</span>
                  </div>
                )
              })}
              <p style={{ margin: '14px 0 0', fontSize: 11, color: 'var(--gray-2)', textAlign: 'center' }}>史詩保底 20 抽 · 傳說保底 50 抽，抽滿必得對應獎勵</p>
            </div>
          </div>
        </div>
      )}
    </div>, document.body)
}

function TitlesSheet({ onClose, onPick }) {
  // A 裝備稱號：目前配戴 + 可切換列表
  const ALL = [['三屆雀神', '2025 秋季賽', 1], ['自由店店霸', '月勝場第一', 1], ['早鳥達人', '100 場早場', 1], ['夜貓王', '50 場夜場', 0], ['揪團達人', '揪滿 10 桌', 0]]
  const [equip, setEquip] = useState('三屆雀神')
  return (
    <DragSheet onClose={onClose} title="我的稱號" subtitle="你獲得的稱號，將顯示在頭像旁邊">
      {/* 稱號列表 */}
      {ALL.map(([nm, dt, on]) => (
        <div key={nm} style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '11px 0', borderBottom: '.5px solid var(--gray-4)' }}>
          <span style={{ width: 8, height: 8, borderRadius: '50%', background: on ? (equip === nm ? 'var(--gold)' : 'var(--brand)') : 'var(--gray-3)', flex: '0 0 8px' }} />
          <div onClick={() => onPick({ kind: '典藏', emoji: '\u{1F3C5}', name: nm, got: !!on, desc: '在 MIGI 獲得的專屬稱號', kv: [['獲得方式', dt], ['狀態', on ? (equip === nm ? '使用中' : '已獲得') : '尚未獲得']] })} style={{ flex: 1, cursor: 'pointer' }}>
            <div style={{ fontSize: 14, fontWeight: 700, color: on ? 'var(--ink)' : 'var(--gray-2)' }}>{nm}</div>
            <div style={{ fontSize: 10, color: 'var(--gray-1)', marginTop: 1 }}>{on ? dt : '尚未獲得'}</div>
          </div>
          {on ? (equip === nm
            ? <span style={{ fontSize: 11, fontWeight: 700, background: 'var(--ink)', color: 'var(--white)', borderRadius: 'var(--r-pill)', padding: '5px 12px', flex: '0 0 auto' }}>使用中</span>
            : <button onClick={() => { setEquip(nm); showToast('已設定「' + nm + '」') }} style={{ fontSize: 11, fontWeight: 700, background: 'var(--field-bg)', color: 'var(--gray-1)', border: '1px solid var(--gray-3)', borderRadius: 'var(--r-pill)', padding: '5px 12px', cursor: 'pointer', flex: '0 0 auto' }}>設定</button>
          ) : <span style={{ fontSize: 11, color: 'var(--gray-2)', flex: '0 0 auto' }}>未獲得</span>}
        </div>
      ))}
    </DragSheet>
  )
}

function AvatarPickerSheet({ onClose, onApply }) {
  // 選頭像：已解鎖段位熊頭像可選用；未來支援上傳真實照片
  const BEARS = [['銅牌熊', 1], ['銀牌熊', 1], ['金牌熊', 1], ['白金熊', 1], ['鑽石熊', 1], ['大師熊', 0], ['雀神熊', 0]]
  // 目前頭像 → 反查段位名當初始選取（未設定則預設金牌熊）
  const [sel, setSel] = useState(() => {
    const cur = getMyAvatar()
    const hit = BEARS.find(([nm]) => rankBearSrc(nm) === cur)
    return hit ? hit[0] : '金牌熊'
  })
  return (
    <DragSheet onClose={onClose} title="選擇頭像" subtitle="升上各段位或解鎖成就，取得更多頭像造型">
      <div onClick={() => showToast('上傳照片 · 即將推出')} style={{ display: 'flex', alignItems: 'center', gap: 12, background: 'var(--field-bg)', borderRadius: 'var(--r-card)', padding: '13px 14px', marginBottom: 16, cursor: 'pointer' }}>
        <span style={{ width: 40, height: 40, borderRadius: '50%', background: 'var(--field-bg)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#2E2B2C" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z" /><circle cx="12" cy="13" r="4" /></svg></span>
        <div style={{ flex: 1 }}><div style={{ fontSize: 'var(--s)', fontWeight: 700, color: 'var(--ink)' }}>上傳照片</div><div style={{ fontSize: 'var(--xs)', color: 'var(--gray-2)', marginTop: 2 }}>用自己的照片當頭像</div></div>
        <span style={{ fontSize: 18, color: 'var(--gray-2)' }}>{'\u203A'}</span>
      </div>
      <p style={{ margin: '0 0 12px', fontSize: 'var(--xs)', fontWeight: 700, color: 'var(--gray-2)' }}>小熊頭像</p>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12 }}>
        {BEARS.map(([nm, on]) => (
          <div key={nm} onClick={() => on ? setSel(nm) : showToast('升到 ' + nm + ' 解鎖')} style={{ cursor: 'pointer', flex: '0 0 calc(25% - 9px)', textAlign: 'center', background: sel === nm ? 'var(--brand-light)' : 'transparent', borderRadius: 'var(--r-card)', padding: '8px 4px' }}>
            <div style={{ display: 'inline-block', opacity: on ? 1 : 0.35, filter: on ? 'none' : 'grayscale(1)', width: 52, height: 52, borderRadius: '50%', overflow: 'hidden', background: 'var(--white)' }}><img src={rankBearSrc(nm)} alt={nm} width="100%" height="100%" style={{ display: 'block' }} /></div>
            <p style={{ margin: '6px 0 0', fontSize: 11, fontWeight: 700, color: on ? 'var(--ink)' : 'var(--gray-2)' }}>{nm}</p>
          </div>
        ))}
      </div>
      <button onClick={() => { const src = rankBearSrc(sel); saveMyAvatar(src); if (onApply) onApply(src); showToast('頭像已更新'); onClose() }} style={{ width: '100%', marginTop: 20, border: 'none', borderRadius: 'var(--r-pill)', padding: '14px 0', fontSize: 'var(--m)', fontWeight: 700, background: 'var(--ink)', color: 'var(--white)', cursor: 'pointer' }}>套用</button>
    </DragSheet>
  )
}

function CollectDetailSheet({ item, onClose }) {
  const { kind, emoji, name, desc, got, migi, kv, prog, reward, hall } = item
  const heroBg = migi ? 'var(--ink)' : 'var(--brand-light)'
  const [who, setWho] = useState(null)
  if (item.profileCard) return <ProfileCardOther b={item.profileCard} onClose={onClose} />
  if (hall) {
    // E 肖像牆 Gallery — 點人開完整人物卡
    const HALL = [
      { av: '芳', ini: '阿芳', yr: '衛冕中', legend: 1, rank: '雀神熊', rel: 'stranger', tog: 0, win: 0 },
      { av: '婷', ini: '小婷', yr: '三屆', legend: 0, rank: '大師熊 II', rel: 'stranger', tog: 0, win: 0 },
      { av: '美', ini: '美美', yr: '兩屆', legend: 0, rank: '鑽石熊 I', rel: 'stranger', tog: 0, win: 0 },
      { av: '琪', ini: '雅琪', yr: '一屆', legend: 0, rank: '白金熊 III', rel: 'stranger', tog: 0, win: 0 },
      { av: '琳', ini: '小琳', yr: '一屆', legend: 0, rank: '白金熊 I', rel: 'stranger', tog: 0, win: 0 },
      { av: '華', ini: '大華', yr: '一屆', legend: 0, rank: '鑽石熊 II', rel: 'stranger', tog: 0, win: 0 },
    ]
    if (who) return <ProfileCardOther b={who} onClose={() => setWho(null)} />
    return (
      <DragSheet onClose={onClose} title="名人堂 · 歷代雀神熊" subtitle="每季冠軍將進入名人堂，享有最高榮譽與終身優惠">
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 9 }}>
          {HALL.map((h) => (
            <div key={h.ini} onClick={() => setWho(h)} style={{ cursor: 'pointer', flex: '0 0 calc(33.33% - 6px)', borderRadius: 'var(--r-card)', padding: '12px 6px 10px', textAlign: 'center', background: h.legend ? 'var(--field-bg)' : 'var(--field-bg)', border: h.legend ? '1.5px solid var(--gold)' : '1px solid var(--milktea)' }}>
              {!!h.legend && <div style={{ fontSize: 13, marginBottom: 2 }}>{'\u{1F451}'}</div>}
              <DefaultAvatar size={48} />
              <p style={{ margin: 0, fontSize: 12, fontWeight: 700, color: 'var(--ink)' }}>{h.ini}</p>
              <p style={{ margin: '2px 0 0', fontSize: 9, color: 'var(--gray-1)' }}>{h.yr}</p>
            </div>
          ))}
        </div>
      </DragSheet>
    )
  }
  return (
    <DragSheet onClose={onClose} title={kind}>
      {kind === '頭像圖鑑' ? (
        <div style={{ margin: '4px auto 14px', display: 'flex', justifyContent: 'center', filter: got ? 'none' : 'grayscale(1)', opacity: got ? 1 : 0.5 }}>
          <DefaultAvatar size={88} />
        </div>
      ) : (
        <div style={{ width: 88, height: 88, borderRadius: '50%', margin: '4px auto 14px', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 42, background: heroBg, border: migi ? '2px solid var(--gold)' : 'none', position: 'relative', filter: got ? 'none' : 'grayscale(1)', opacity: got ? 1 : 0.5 }}>
          {emoji}
        </div>
      )}
      <p style={{ margin: '0 0 6px', fontSize: 18, fontWeight: 700, color: 'var(--ink)', textAlign: 'center' }}>{name}</p>
      {desc && <p style={{ margin: '0 auto 16px', fontSize: 13, color: 'var(--gray-1)', textAlign: 'center', lineHeight: 1.6, maxWidth: 260 }}>{desc}</p>}
      {got && !prog && <div style={{ textAlign: 'center', marginBottom: 14 }}><span style={{ display: 'inline-block', background: 'var(--brand)', color: 'var(--ink)', fontSize: 11, fontWeight: 700, padding: '4px 12px', borderRadius: 'var(--r-pill)' }}>{kind === '小熊圖鑑' ? '✓ 已收集' : '✓ 已達成'}</span></div>}
      {/* 成就 A+B：進度條 */}
      {prog && (
        <>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11, color: 'var(--gray-1)', marginBottom: 6 }}><span>目前進度</span><span>{prog[0]} / {prog[1]}</span></div>
          <div style={{ height: 9, background: 'var(--gray-4)', borderRadius: 'var(--r-pill)', overflow: 'hidden', marginBottom: 14 }}><div style={{ height: '100%', width: Math.round(prog[0] / prog[1] * 100) + '%', background: 'var(--ink)', borderRadius: 'var(--r-pill)' }} /></div>
        </>
      )}
      {/* kv 列 */}
      {kv && kv.map(([k, v]) => (
        <div key={k} style={{ background: 'var(--field-bg)', borderRadius: 'var(--r-field)', padding: '12px 14px', display: 'flex', justifyContent: 'space-between', fontSize: 13, marginBottom: 8 }}>
          <span style={{ color: 'var(--gray-1)' }}>{k}</span><span style={{ color: 'var(--ink)', fontWeight: 600 }}>{v}</span>
        </div>
      ))}
      {/* 成就獎勵 */}
      {reward && <div style={{ background: 'var(--brand-light)', borderRadius: 'var(--r-field)', padding: '12px 14px', display: 'flex', justifyContent: 'space-between', fontSize: 13, marginTop: 2 }}><span style={{ color: 'var(--gray-1)' }}>獎勵</span><span style={{ color: 'var(--ink)', fontWeight: 700 }}>{reward}</span></div>}
    </DragSheet>
  )
}

function Bear() {
  const [bearName, setBearNameState] = useState(getBearName())
  const [renameOpen, setRenameOpen] = useState(false)
  const [renameVal, setRenameVal] = useState('')
  const openRename = () => { setRenameVal(bearName); setRenameOpen(true) }
  const saveRename = () => { const v = renameVal.trim(); if (v) { saveBearNameLS(v); setBearNameState(v); showToast('改名成功：' + v) } setRenameOpen(false) }
  const [detail, setDetail] = useState(null) // 收藏詳情抽屜 { kind, ... }
  const bears = [['銅牌熊', 1], ['銀牌熊', 1], ['金牌熊', 1], ['白金熊', 1], ['鑽石熊', 1], ['大師熊', 0], ['雀神熊', 0]]
  // 養成中心 state
  const [cookies, setCookies] = useState(8)
  const [lv, setLv] = useState(1)
  const [grow, setGrow] = useState(60)
  const [fed, setFed] = useState(false)
  const [lvUpMsg, setLvUpMsg] = useState('')
  const [claimedCheckin, setClaimedCheckin] = useState(false)
  const eventCd = useCountdown({ d: 2, h: 18, m: 45, s: 9 })
  const [snackOpen, setSnackOpen] = useState(false)
  // 點心庫存（多種點心，各有成長值）
  const [snacks, setSnacks] = useState({ cookie: 8, milktea: 3, pudding: 2, tiramisu: 1 })
  // A 塊：養成熊進度雲端化 —— 開啟時載入，變動時 debounce 存回（換手機不歸零）
  const [loaded, setLoaded] = useState(false)
  useEffect(() => {
    fetchMyProfile().then((d) => {
      const b = d && d.app_state
      if (b && Object.keys(b).length) {
        if (typeof b.lv === 'number') setLv(b.lv)
        if (typeof b.grow === 'number') setGrow(b.grow)
        if (b.snacks) setSnacks(b.snacks)
      }
      setLoaded(true)
    })
  }, [])
  // 進度變動 → 存回後端（載入完成後才存，避免用初始值覆蓋雲端；600ms debounce 併寫）
  useEffect(() => {
    if (!loaded) return
    const t = setTimeout(() => { saveAppState({ lv, grow, snacks }) }, 600)
    return () => clearTimeout(t)
  }, [loaded, lv, grow, snacks])
  const applyGrow = (add) => {
    setFed(true); setTimeout(() => setFed(false), 500)
    setGrow((g) => {
      let ng = g + add, lvUp = 0
      while (ng >= 100) { ng -= 100; lvUp++ }
      if (lvUp > 0) { setLv((l) => l + lvUp); setLvUpMsg('🎉 升級囉！解鎖新造型！'); setTimeout(() => setLvUpMsg(''), 2600) }
      return ng
    })
  }
  // 餅乾快速餵(主頁用)：吃 n 片餅乾，每片+10
  const feedBear = (n) => {
    if (snacks.cookie < n) n = snacks.cookie
    if (n <= 0) return
    setSnacks((s) => ({ ...s, cookie: s.cookie - n }))
    applyGrow(n * 10)
  }
  // 餵單一點心(櫥窗用)：吃1個某點心，給該點心成長值
  const feedSnack = (key, growth) => {
    if (snacks[key] <= 0) return
    setSnacks((s) => ({ ...s, [key]: s[key] - 1 }))
    applyGrow(growth)
  }
  const [page, setPage] = useState(null) // 切頁: null | 'ach'(成就牆) | 'bear'(小熊圖鑑)



  // nurture（每日養成 = 房間裡的東西）
  return (
      <>
        <style>{`
          @keyframes bearNom { 0%,100% { transform: scale(1); } 30% { transform: scale(1.08) rotate(-2deg); } 60% { transform: scale(.96) rotate(2deg); } }
          .bear-nom { animation: bearNom .5s ease-in-out; }
        `}</style>
        {/* 我的養成小熊 主標 */}
        <div style={{ padding: '16px 20px 0' }}>
          <p style={{ margin: 0, fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>我的養成小熊</p>
          <p style={{ margin: '2px 0 0', fontSize: 'var(--xs)', color: 'var(--gray-1)' }}>餵小熊吃點心，牠會長大且越來越強</p>
        </div>
        {/* 小熊舞台（養成熊超大 + 卡內右上餅乾pill + 左上Lv） */}
        <div style={{ padding: '12px 20px 0' }}>
          <div style={{ background: 'var(--brand)', borderRadius: 20, padding: '20px 18px', textAlign: 'center', position: 'relative' }}>
            <span style={{ position: 'absolute', top: 14, left: 16, background: 'rgba(255,255,255,0.7)', borderRadius: 'var(--r-pill)', padding: '4px 11px', fontSize: 10, fontWeight: 700, color: 'var(--ink)' }}>Lv.{lv}</span>
            <span onClick={() => setSnackOpen(true)} style={{ position: 'absolute', top: 14, right: 16, display: 'inline-flex', alignItems: 'center', gap: 5, fontSize: 14, fontWeight: 800, color: 'var(--accent)', cursor: 'pointer' }}><span style={{ width: 22, height: 22, borderRadius: '50%', overflow: 'hidden', display: 'inline-flex' }}><img src={SNACK_IMGS.cookie} alt="餅乾" width="22" height="22" style={{ display: 'block' }} /></span>{'\u00d7' + snacks.cookie}</span>
            <div className={fed ? 'bear-nom' : ''} style={{ width: 150, height: 150, margin: '6px auto 0', borderRadius: '50%', background: 'var(--white)', display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: 'var(--shadow-md)', position: 'relative', overflow: 'hidden' }}><BearStageImg lv={lv} size={150} /></div>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 7, margin: '16px 0 4px' }}><p style={{ margin: 0, fontSize: 'var(--xl)', fontWeight: 700, color: 'var(--ink)' }}>{bearName}</p><span onClick={openRename} style={{ cursor: 'pointer', display: 'inline-flex' }}><PencilIcon /></span></div>
            <p style={{ margin: '0 0 10px', fontSize: 'var(--xs)', color: '#7A6F6C', minHeight: 18 }}>{'\u300c' + bearMood({ justFed: fed, grow, lv }) + '\u300d'}</p>
            {lvUpMsg && <p style={{ margin: '0 0 12px', fontSize: 'var(--xs)', color: 'var(--accent)', fontWeight: 700 }}>{lvUpMsg}</p>}
            <div style={{ height: 10, background: 'rgba(255,255,255,0.55)', borderRadius: 'var(--r-pill)', overflow: 'hidden' }}><div style={{ height: '100%', width: grow + '%', background: 'var(--accent)', borderRadius: 'var(--r-pill)', transition: 'width .5s ease' }} /></div>
            <p style={{ margin: '6px 0 0', fontSize: 10, color: 'var(--gray-1)' }}>成長 {grow}% · 再 {Math.ceil((100 - grow) / 10)} 片餅乾升 Lv.{lv + 1}</p>
          </div>
        </div>
        {/* 餵食按鈕 */}
        <div style={{ padding: '14px 20px 6px', display: 'flex', gap: 8 }}>
          <button className="ibtn" disabled={snacks.cookie <= 0} onClick={() => feedBear(1)} style={{ flex: 1, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 5, padding: '12px 0', fontSize: 'var(--m)', fontWeight: 700, background: snacks.cookie > 0 ? 'var(--ink)' : 'var(--field-bd)', color: 'var(--white)' }}>餵 1 片小熊餅乾</button>
          <button className="ibtn" disabled={snacks.cookie <= 0} onClick={() => feedBear(snacks.cookie)} style={{ flex: '0 0 auto', padding: '12px 18px', fontSize: 'var(--m)', fontWeight: 700, background: 'var(--white)', border: '1.5px solid var(--ink)', color: 'var(--ink)' }}>全部餵</button>
        </div>
        {/* 小熊的房間 */}
        <div style={{ padding: '10px 20px 8px' }}><p style={{ margin: 0, fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>小熊的房間</p><p style={{ margin: '2px 0 0', fontSize: 'var(--xs)', color: 'var(--gray-1)' }}>每天來陪牠活動成長、把房間佈置得更豐富</p></div>
        <div style={{ padding: '0 20px 18px', display: 'flex', flexDirection: 'column', gap: 10 }}>
          {[
            { w: '抽', t: '牌桌上的麻將', sub: '隨機抽牌', d: '搓一張牌，抽各種優惠與造型配件', go: 'gacha', cta: '去搓', event: false },
            { w: '報', t: '抽屜的日記', sub: '每日報到', d: claimedCheckin ? '今天已經記上一筆了' : '連續寫了 3 天，今天還沒記上一筆', go: 'checkin', cta: '去報到', event: false },
            { w: '課', t: '書包裡的功課', sub: '每週任務', d: '本週功課完成 2/3，記得去寫', go: 'task', cta: '去完成', event: false },
          ].map((r) => (
            <div key={r.t} onClick={() => { if (r.go === 'checkin') setPage('checkin'); else if (r.go === 'task') setPage('task'); else if (r.go === 'gacha') setPage('gacha'); else showToast(r.t + ' · 即將推出') }} style={{ display: 'flex', alignItems: 'center', gap: 13, padding: '13px 14px', borderRadius: 'var(--r-card)', background: 'var(--field-bg)', cursor: 'pointer' }}>
              <span className="itile" style={{ width: 30, height: 38, background: 'var(--brand)', color: 'var(--ink)', fontSize: 'var(--l)', flex: '0 0 30px' }}>{r.w}</span>
              <div style={{ flex: 1 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}><span style={{ fontSize: 'var(--s)', fontWeight: 700, color: 'var(--ink)' }}>{r.t}</span><span style={{ fontSize: 10, color: 'var(--accent)', fontWeight: 700, background: 'var(--brand-light)', borderRadius: 'var(--r-pill)', padding: '2px 8px' }}>{r.sub}</span></div>
                <div style={{ fontSize: 'var(--xs)', color: 'var(--gray-1)', marginTop: 2 }}>{r.d}</div>
              </div>
              <span style={{ fontSize: 'var(--xs)', color: 'var(--accent)', fontWeight: 700 }}>{r.cta} ›</span>
            </div>
          ))}
          {/* 限時活動：教練熊來訪（粉底+頭像+倒數）→ 切到教練熊tab */}
          <div onClick={() => setPage('event')} style={{ display: 'flex', alignItems: 'center', gap: 13, padding: '13px 14px', borderRadius: 'var(--r-card)', background: 'var(--brand)', cursor: 'pointer' }}>
            <div style={{ width: 48, height: 48, borderRadius: '50%', overflow: 'hidden', background: 'var(--white)', flex: '0 0 48px' }}><img src={COACH_BEAR} alt="" width="100%" height="100%" style={{ display: 'block' }} /></div>
            <div style={{ flex: 1 }}>
              <div><span style={{ background: 'var(--accent)', color: 'var(--white)', borderRadius: 'var(--r-pill)', padding: '2px 10px', fontSize: 10, fontWeight: 800 }}>限時活動</span></div>
              <div style={{ fontSize: 'var(--s)', fontWeight: 700, color: 'var(--ink)', marginTop: 3 }}>本季訪客：教練熊</div>
              <div style={{ marginTop: 3 }}><span style={{ background: 'var(--ink)', color: 'var(--white)', borderRadius: 'var(--r-pill)', padding: '3px 10px', fontSize: 10, fontWeight: 800, fontVariantNumeric: 'tabular-nums' }}>倒數{eventCd}</span></div>
            </div>
            <span style={{ fontSize: 'var(--xs)', color: 'var(--accent)', fontWeight: 700, alignSelf: 'center' }}>去參加 ›</span>
          </div>
        </div>
              {/* 房間的收藏 */}
        {/* 我的成就 */}
        <div style={{ padding: '14px 20px 0', display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
          <p style={{ margin: 0, fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>牆上的獎牌</p>
          <span onClick={() => setPage('ach')} style={{ fontSize: 'var(--xs)', color: 'var(--accent)', fontWeight: 700, cursor: 'pointer' }}>查看全部 ›</span>
        </div>
        <p style={{ margin: 0, padding: '2px 20px 10px', fontSize: 'var(--xs)', color: 'var(--gray-2)' }}>達成里程碑收藏的成就徽章</p>
        <div style={{ padding: '0 20px', display: 'flex', gap: 10 }}>
          {[['🀄', '首次 MIGI', 1], ['🐻', '升上金牌熊', 1], ['🔥', '連莊 5 次', 0], ['🍵', '點一杯飲料', 1]].map(([e, n, migi]) => (
            <div key={n} onClick={() => setDetail({ kind: '成就', emoji: e, name: n, got: true, migi: !!migi, desc: migi ? '在 MIGI 門市胡出 MIGI 牌型' : '達成特定條件解鎖', kv: [['稀有度', migi ? '傳說' : '普通'], ['達成日期', '2025 / 11 / 03']] })} style={{ flex: 1, textAlign: 'center', cursor: 'pointer' }}>
              <div style={{ width: '100%', aspectRatio: '1', borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 28, background: migi ? 'var(--ink)' : 'var(--field-bg)', border: migi ? '2px solid var(--gold)' : 'none' }}>
                {e}
              </div>
              <p style={{ margin: '5px 0 0', fontSize: 11, fontWeight: 700, color: 'var(--gray-1)', lineHeight: 1.3 }}>{n}</p>
            </div>
          ))}
        </div>
        {/* 頭像圖鑑 */}
        <div style={{ padding: '18px 20px 0', display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
          <p style={{ margin: 0, fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>書架上的圖鑑</p>
          <span onClick={() => setPage('bear')} style={{ fontSize: 'var(--xs)', color: 'var(--accent)', fontWeight: 700, cursor: 'pointer' }}>查看全部 ›</span>
        </div>
        <p style={{ margin: 0, padding: '2px 20px 10px', fontSize: 'var(--xs)', color: 'var(--gray-2)' }}>解鎖各種造型頭像，可在我的個人檔案自由更換</p>
        <div style={{ padding: '0 20px', display: 'flex', gap: 10 }}>
          {bears.slice(0, 4).map(([nm, on], bi) => (
            <div key={nm} onClick={() => setDetail({ kind: '頭像圖鑑', name: nm, got: !!on, desc: on ? nm + '造型頭像，可在個人檔案選用' : '升到 ' + nm + ' 解鎖這個頭像', kv: [['階級', (bi + 1) + ' / 7 階'], ['解鎖條件', '段位升到 ' + nm]] })} style={{ cursor: 'pointer', flex: 1, textAlign: 'center' }}>
              <div style={{ position: 'relative', display: 'inline-block', opacity: on ? 1 : 0.35, filter: on ? 'none' : 'grayscale(1)' }}><DefaultAvatar size={56} /></div>
              <p style={{ margin: '5px 0 0', fontSize: 11, color: on ? 'var(--gray-1)' : 'var(--gray-2)', fontWeight: 700 }}>{nm}</p>
            </div>
          ))}
        </div>
        {/* 小熊衣櫥 */}
        <div style={{ padding: '18px 20px 0', display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
          <p style={{ margin: 0, fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>衣櫥裡的配件</p>
          <span onClick={() => setPage('closet')} style={{ fontSize: 'var(--xs)', color: 'var(--accent)', fontWeight: 700, cursor: 'pointer' }}>查看全部 ›</span>
        </div>
        <p style={{ margin: 0, padding: '2px 20px 10px', fontSize: 'var(--xs)', color: 'var(--gray-2)' }}>幫養成小熊換上不同造型配件</p>
        <div style={{ padding: '0 20px', display: 'flex', gap: 10 }}>
          {[['🎀', '蝴蝶結', 1], ['🧣', '圍巾', 1], ['🎩', '紳士帽', 0], ['👑', '小皇冠', 0]].map(([e, n, on]) => (
            <div key={n} onClick={() => setDetail({ kind: '小熊衣櫥', emoji: e, name: n, got: !!on, desc: on ? '幫養成小熊換上「' + n + '」' : '解鎖後可幫小熊裝扮', kv: [['類型', '配件'], ['狀態', on ? '已擁有' : '未解鎖']] })} style={{ cursor: 'pointer', flex: 1, textAlign: 'center' }}>
              <div style={{ width: '100%', aspectRatio: '1', borderRadius: '50%', background: on ? 'var(--brand-light)' : 'var(--field-bg)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 26, opacity: on ? 1 : 0.4, filter: on ? 'none' : 'grayscale(1)' }}>{e}</div>
              <p style={{ margin: '5px 0 0', fontSize: 11, color: on ? 'var(--gray-1)' : 'var(--gray-2)', fontWeight: 700 }}>{n}</p>
            </div>
          ))}
        </div>
        {detail && <CollectDetailSheet item={detail} onClose={() => setDetail(null)} />}
        {page === 'ach' && <AchWallPage onBack={() => setPage(null)} onPick={(it) => setDetail(it)} />}
        {page === 'bear' && <BearDexPage onBack={() => setPage(null)} onPick={(it) => setDetail(it)} />}
        {page === 'closet' && <ClosetPage onBack={() => setPage(null)} onPick={(it) => setDetail(it)} />}
        {page === 'checkin' && <CheckinPage onBack={() => setPage(null)} onClaim={(n) => { setCookies((c) => c + n); setClaimedCheckin(true) }} claimed={claimedCheckin} season={false} />}
        {page === 'task' && <WeeklyTaskPage onBack={() => setPage(null)} onClaim={(n) => setCookies((c) => c + n)} season={false} />}
        {page === 'event' && <EventPage onBack={() => setPage(null)} />}
        {page === 'gacha' && <GachaPage onBack={() => setPage(null)} season={false} />}
        {snackOpen && <SnackSheet onClose={() => setSnackOpen(false)} snacks={snacks} onFeed={feedSnack} />}
        {renameOpen && <RenameBearSheet val={renameVal} setVal={setRenameVal} onSave={saveRename} onClose={() => setRenameOpen(false)} />}
      </>
    )
  }

/* ===== 2 成績（摘要 + 對戰紀錄 + 對戰詳細 + 避開牌咖；前端 demo） ===== */

export { Bear, AvatarPickerSheet, TitlesSheet, CollectDetailSheet, EditTextSheet };
