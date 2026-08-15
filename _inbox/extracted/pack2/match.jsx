// 配桌頁（tab1）— 從 App.jsx 抽出
// Match + AvoidPage + RecordRow + RecordsPage + JoiningOverlay + BearAvatar + ReasonSheet + MatchedModal + TablesPage
import { useState, useEffect } from 'react'
import { createPortal } from 'react-dom'
import DefaultAvatar from '../DefaultAvatar'
import { DragSheet, DateField, TimeField, showToast } from '../lib/ui.jsx'
import { StorePickerSearch, MapPin, deco } from '../lib/components.jsx'
import { DEMO_BUDDIES, DEMO_LIVE, DEMO_FIX, DEMO_RECORDS, DEMO_MATCHES } from '../lib/data.jsx'
import { RecordDetailSheet } from '../lib/GameDetailSheet.jsx'
import { popPendingTableInvites, addPendingTableInvite, pendingTableInvites, sendTableInvite, hasInvited, fetchMatchQueues, createMatchQueue, joinMatchQueue, fetchStakes, fetchStores, fetchMyQueue, leaveMatchQueue, fetchNotifs, onSocial, respondTableReq, fetchBlocks, unblockMember, fetchBuddies } from '../lib/social.js'
import { track } from '../lib/analytics.js'
import { rankBearSrc, fmtType, fmtRank, cityFromLatLng } from '../lib/helpers.jsx'

// 同桌成員假資料（真實會員頭像＝段位熊）★之後接後端 session_players
// [暱稱, 段位, 是否為本人]
const TABLE_PLAYERS = [
  ['你', '金牌熊 II', true],
  ['雅琪', '金牌熊 I', false],
  ['阿凱', '銀牌熊 III', false],
  ['婉婷', '銅牌熊 I', false],
]
// 小圓頭像：段位熊真圖
function SeatAvatar({ rank, size = 42 }) {
  return <span style={{ width: size, height: size, borderRadius: '50%', background: 'var(--white)', overflow: 'hidden', display: 'inline-flex', flex: `0 0 ${size}px` }}><img src={rankBearSrc(rank)} alt="" width="100%" height="100%" style={{ display: 'block' }} /></span>
}

function AvoidPage({ onBack, z = 1000, title = '黑名單' }) {
  const [list, setList] = useState(null)   // null=載入中
  const load = () => fetchBlocks().then(setList)
  useEffect(() => { load() }, [])
  const unblock = async (b) => {
    if (!window.confirm(`確定要將「${b.nickname}」移出黑名單嗎？`)) return
    await unblockMember(b.id)
    showToast('已移出黑名單')
    load()
  }
  return createPortal(
    <div className="sheet-anim" style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: 'var(--white)', zIndex: z, display: 'flex', flexDirection: 'column' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '16px 16px 12px', borderBottom: '.5px solid var(--gray-4)' }}>
        <button onClick={onBack} style={{ background: 'none', border: 'none', fontSize: 22, color: 'var(--ink)', cursor: 'pointer', padding: '0 4px' }}>‹</button>
        <span style={{ fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>{title}</span>
      </div>
      <div style={{ flex: 1, overflowY: 'auto' }}>
        <p style={{ padding: '10px 20px 0', margin: 0, fontSize: 'var(--xs)', color: 'var(--gray-1)' }}>配桌時會自動跳過黑名單裡的人（雙向生效）· 隨時可以移除</p>
        <div style={{ height: 6 }} />
        {list === null ? (
          <p style={{ padding: '40px 20px', textAlign: 'center', color: 'var(--gray-2)', fontSize: 'var(--s)' }}>載入中…</p>
        ) : list.length === 0 ? (
          <p style={{ padding: '40px 20px', textAlign: 'center', color: 'var(--gray-2)', fontSize: 'var(--s)' }}>目前沒有黑名單</p>
        ) : list.map((b) => (
          <div key={b.id} style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '12px 20px', borderBottom: '.5px solid var(--gray-4)' }}>
            <SeatAvatar rank={b.rank} size={36} />
            <div style={{ flex: 1, minWidth: 0 }}>
              <p style={{ margin: 0, fontSize: 'var(--m)', color: 'var(--ink)' }}>{b.nickname}</p>
              <p style={{ margin: '2px 0 0', fontSize: 'var(--xs)', color: 'var(--gray-1)' }}>{fmtRank ? fmtRank(b.rank) : b.rank}</p>
            </div>
            <button className="ibtn" onClick={() => unblock(b)} style={{ background: 'var(--gray-4)', color: 'var(--gray-1)', padding: '7px 14px', fontSize: 'var(--xs)', fontWeight: 700, flex: '0 0 auto' }}>移除</button>
          </div>
        ))}
      </div>
    </div>, document.body
  )
}


/* ===== 1 配桌（前端 demo） ===== */
// 官方 pill 代碼→顯示文字對照表（受控清單，只有 POS/官方能掛；改文案只改這裡）
const QUEUE_TAGS = { newbie: '新手友善', influencer: '網紅在這桌', pro: '職業選手桌' }
const _hhmm = (d) => `${('0' + d.getHours()).slice(-2)}:${('0' + d.getMinutes()).slice(-2)}`
const fmtPlayAt = (iso) => {
  if (!iso) return ''
  const d = new Date(iso), t = new Date()
  const same = d.toDateString() === t.toDateString()
  return (same ? '今天 ' : `${d.getMonth() + 1}/${d.getDate()} `) + _hhmm(d)
}
// 固定局頻率標籤：daily=每日開桌、weekly=每週X開桌（讀實例帶的 recurring_freq）
const WEEK_CH = ['日', '一', '二', '三', '四', '五', '六']
const freqLabel = (q) => {
  if (q?.recurring_freq === 'daily') return '每日開桌'
  if (q?.play_at) return `每週${WEEK_CH[new Date(q.play_at).getDay()]}開桌`
  return '固定場次'
}
// 黑白線條 icon：固定局=日曆、即時局=時鐘
const IconCalendar = ({ size = 15, color = 'var(--ink)' }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" style={{ flexShrink: 0 }}><rect x="3" y="4" width="18" height="18" rx="2" /><line x1="16" y1="2" x2="16" y2="6" /><line x1="8" y1="2" x2="8" y2="6" /><line x1="3" y1="10" x2="21" y2="10" /></svg>
)
const IconClock = ({ size = 15, color = 'var(--gray-1)' }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" style={{ flexShrink: 0 }}><circle cx="12" cy="12" r="9" /><polyline points="12 7 12 12 15 14" /></svg>
)
function Match({ phase, setPhase, active, setActive, onOpenSettle, onGoStats }) {
  const roundUp30 = (d) => { const x = new Date(d); const m = x.getMinutes(); if (m === 0) return x; x.setMinutes(m <= 30 ? 30 : 60, 0, 0); return x }
  const hhmm = (d) => `${('0' + d.getHours()).slice(-2)}:${('0' + d.getMinutes()).slice(-2)}`
  const fromNow = (mins) => hhmm(roundUp30(new Date(Date.now() + mins * 60000)))

  const [store, setStore] = useState({ name: 'MIGI 高雄自由店', area: '左營區', dist: '1.2km', addr: '高雄市左營區自由三路410號', lat: 22.675671, lng: 120.312763 })
  const [mahjongKind, setMahjongKind] = useState('台麻')   // 台麻 / 美麻
  const [flower, setFlower] = useState('無花')             // 無花 / 有花
  const [stake, setStake] = useState('50/20')
  const dayStr = (n) => { const d = new Date(); d.setDate(d.getDate() + n); return `${d.getFullYear()}-${('0'+(d.getMonth()+1)).slice(-2)}-${('0'+d.getDate()).slice(-2)}` }
  const [matchDay, setMatchDay] = useState(dayStr(0))
  const [startT, setStartT] = useState(() => fromNow(60))    // 預設：現在 +1 小時（動態）
  const [endT, setEndT] = useState(() => fromNow(240))       // 預設：現在 +4 小時（動態）
  const [rounds, setRounds] = useState('2 將')
  const [setupOpen, setSetupOpen] = useState(false)   // ⑬ 按了我要配桌才展開
  const [avoidExpand, setAvoidExpand] = useState(false)  // 我的黑名單 收合
  const [myBlocks, setMyBlocks] = useState([])  // 我的黑名單（真資料，開抽屜時載入）
  useEffect(() => { if (setupOpen) fetchBlocks().then(setMyBlocks) }, [setupOpen])
  // phase 由 MemberApp 提供：idle | waiting | matched
  // active/phase 由 MemberApp 提供（跨 tab 共用）   // 成桌區的這場(等待中/已成桌)
  const [showModal, setShowModal] = useState(false)   // 成桌浮窗
  const [tablesPage, setTablesPage] = useState(false)
  const [reasonSheet, setReasonSheet] = useState(false)
  const [joining, setJoining] = useState(false)  // 『正在加入牌局…』過場
  const [avoidPage, setAvoidPage] = useState(false)
  const [recordsPage, setRecordsPage] = useState(false)
  const [inviteSheet, setInviteSheet] = useState(null)  // null | 'pending'(開桌前先勾) | 'now'(配桌中直接邀)
  const [viewRecord, setViewRecord] = useState(null)
  const [records, setRecords] = useState(DEMO_RECORDS)

  // 真配桌資料層：門市 id、底注對照表、waiting 房清單（5 秒輪詢）
  const [storeId, setStoreId] = useState(null)
  const [stores, setStores] = useState([])
  const [stakeMap, setStakeMap] = useState({})
  const [stakes, setStakes] = useState([])
  const [queues, setQueues] = useState([])
  const [myQueue, setMyQueue] = useState(null)   // 我目前所在的房（本桌動態資料源）
  const [pendingReqs, setPendingReqs] = useState([])   // 配桌相關待處理：揪桌邀請＋收桌
  useEffect(() => {
    const load = () => fetchNotifs().then((ns) => setPendingReqs(ns.filter((n) => n.type === 'table_req' || n.type === 'settle')))
    load()
    return onSocial(load)
  }, [])
  useEffect(() => {
    fetchStores().then((ss) => { setStores(ss); const s = ss.find((x) => x.name === store.name) || ss[0]; if (s) setStoreId(s.id) })
    fetchStakes().then((ks) => { const m = {}; ks.forEach((k) => { m[k.id] = k.label }); setStakeMap(m); setStakes(ks); if (ks[0]) setStake(ks[0].label) })
  }, [])
  useEffect(() => {
    if (!storeId) return
    let alive = true
    const load = () => fetchMatchQueues(storeId).then((q) => { if (alive) setQueues(q || []) })
    load()
    const timer = setInterval(load, 5000)
    return () => { alive = false; clearInterval(timer) }
  }, [storeId])
  // 本桌動態：持續輪詢「我目前的房」，湊滿自動翻成桌、房沒了回 idle
  useEffect(() => {
    let alive = true
    const load = () => fetchMyQueue().then((q) => {
      if (!alive) return
      setMyQueue(q)
      if (q && q.status === 'matched') setPhase((ph) => (ph === 'waiting' ? 'matched' : ph))
      if (q && q.status === 'waiting') setPhase((ph) => (ph === 'idle' ? 'waiting' : ph))
      if (!q) setPhase((ph) => (ph === 'waiting' ? 'idle' : ph))
      // 把即時人數併進 active，讓錢包頁提示能顯示「目前 X/4」
      if (q) setActive((a) => a ? { ...a, players: q.player_count, seats: q.seats } : a)
    })
    load()
    const timer = setInterval(load, 5000)
    return () => { alive = false; clearInterval(timer) }
  }, [])

  const inProgress = phase !== 'idle'   // ⑤ 進行中 → 其他收起
  const liveQueues = queues.filter((q) => q.source !== 'recurring')   // 即時牌局：會員房＋官方房
  const fixQueues = queues.filter((q) => q.source === 'recurring')    // 固定牌局：排程生成的實例
  const navTo = () => { const a = active?.addr || store.addr || ''; const dest = a ? encodeURIComponent(a) : `${store.lat},${store.lng}`; window.open(`https://www.google.com/maps/dir/?api=1&destination=${dest}`, '_blank') }

  // 共用：先顯示『正在加入牌局…』過場，再進等待中；need≤1 的 demo 桌過場後自動成桌
  const enterQueue = (card, autoMatch) => {
    setActive(card); setTablesPage(false); setJoining(true)
    setTimeout(() => {
      setJoining(false); setPhase('waiting')
      track('match_join', { store: card.store, stake: card.stake })
      // 從牌咖頁「揪他」帶過來的：開桌成功 → 自動送出揪桌邀請
      const pending = popPendingTableInvite()
      if (pending) { sendTableInvite(pending, 'auto_after_open'); showToast('已自動邀請 ' + pending + ' 加入你的牌桌') }
      if (autoMatch) setTimeout(() => simMatched(), 1200)
    }, 1100)
  }
  const joinTable = (t) => {
    const card = { store: t.store || store.name, addr: store.addr, stake: t.stake, type: t.type, rounds, time: t.at || ('今天 ' + hhmm(roundUp30(new Date(Date.now() + 5 * 60000)))) }
    enterQueue(card, t.need <= 1)
  }
  const startMatch = async () => {
    if (!storeId) { showToast('門市資料載入中，請稍候'); return }
    const s = stakes.find((x) => x.label === stake) || stakes[0]
    if (!s) { showToast('底注資料載入中，請稍候'); return }
    // play_at＝「最晚幾點前開打」當開打錨點；不限→預設 +1 小時
    let playAt
    if (startT && startT !== '不限' && /^\d{2}:\d{2}$/.test(startT)) playAt = new Date(`${matchDay}T${startT}:00`)
    else playAt = new Date(Date.now() + 60 * 60000)
    setJoining(true)
    const res = await createMatchQueue({
      storeId, stakeId: s.id, playAt: playAt.toISOString(), gameType: mahjongKind, flower, rounds,
      prefs: (endT && endT !== '不限') ? { play_until: endT } : {},
    })
    setJoining(false)
    if (res.error) { showToast(res.error === '你已在一個配桌房裡' ? '你已在一個配桌房裡' : '開桌失敗，請稍後再試'); return }
    popPendingTableInvites()   // 清掉暫存的揪桌名單（揪桌 id 化後再串真實邀請）
    track('table_open', { store: store.name, stake: s.label })
    setActive({ store: store.name, addr: store.addr, stake: s.label, type: mahjongKind, flower, rounds, time: fmtPlayAt(playAt.toISOString()) })
    const mq = await fetchMyQueue(); setMyQueue(mq)   // 立即帶出本桌動態（1/4），不必等輪詢
    setPhase('waiting')
  }
  const simMatched = () => { setPhase('matched'); setShowModal(true) }
  // 加入真實配桌房（Slice 1）：接 joinMatchQueue，用回傳 status 決定成桌/等待
  const joinReal = async (q) => {
    const card = { queueId: q.id, store: store.name, addr: store.addr, stake: stakeMap[q.stake_level_id] || '', type: q.game_type, flower: q.flower, rounds: q.rounds, time: fmtPlayAt(q.play_at) }
    setActive(card); setTablesPage(false); setJoining(true)
    const res = await joinMatchQueue(q.id, 'browse')
    setJoining(false)
    if (res && res.error) { showToast(res.error === '此桌目前無法加入' ? '此桌目前無法加入' : '加入失敗，請稍後再試'); setActive(null); return }
    track('match_join', { store: card.store, stake: card.stake })
    if (res && res.status === 'matched') { setPhase('matched'); setShowModal(true) }
    else setPhase('waiting')
  }
  const cancelWith = (reason) => { setReasonSheet(false); if (myQueue?.id) leaveMatchQueue(myQueue.id, reason); setMyQueue(null); setPhase('idle'); setActive(null); setSetupOpen(false); showToast('已取消配桌') }

  const Chips = ({ opts, val, set }) => (
    <div style={{ display: 'flex', flexWrap: 'wrap' }}>{opts.map((o) => <span key={o} onClick={() => set(o)} className={`ichip ${val === o ? 'on' : ''}`}>{o}</span>)}</div>
  )
  const Group = ({ label, opts, val, set }) => (
    <div style={{ padding: '14px 0 0' }}><p style={{ margin: '0 0 8px', fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>{label}</p><Chips opts={opts} val={val} set={set} /></div>
  )
  // 官方推薦徽章（焦糖布丁/金牌熊樣式：白底半透明 pill）
  const RecmdBadge = () => <span style={{ background: 'var(--accent)', borderRadius: 'var(--r-pill)', padding: '3px 11px', fontSize: 11, fontWeight: 700, color: 'var(--white)' }}>官方推薦</span>
  const LiveCard = ({ t, kind }) => (
    <div style={{ border: '1.5px solid var(--brand)', background: 'var(--brand-light)', borderRadius: 'var(--r-card)', padding: '11px 13px', display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8 }}>
      <div style={{ flex: 1 }}>
        {t.recmd && <div style={{ marginBottom: 8, display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}><RecmdBadge />{t.feat && <span style={{ fontSize: 11, color: 'var(--accent)', fontWeight: 600 }}>{t.feat}</span>}</div>}
        <div style={{ fontSize: 'var(--s)', fontWeight: 600, color: 'var(--ink)' }}>{t.store} · {t.at ? t.at + ' · ' : ''}{t.stake} · {t.type}{t.rounds ? ' · ' + t.rounds : ''}</div>
        <div style={{ fontSize: 'var(--xs)', color: 'var(--gray-1)', marginTop: 2 }}>{kind === 'fix' ? `已報名 ${4 - t.need}/4 · 時間到開桌` : `目前 ${4 - t.need}/4（還差 ${t.need} 位）· 預估等 ${t.wait}`}</div>
      </div>
      <button className="ibtn" onClick={() => joinTable({ ...t, store: t.store })} style={{ background: 'var(--ink)', color: 'var(--white)', borderRadius: 'var(--r-pill)', padding: '7px 16px', fontSize: 'var(--xs)', fontWeight: 700 }}>{kind === 'fix' ? '報名' : '加入'}</button>
    </div>
  )

  // 成桌區（常駐；等待中=找牌咖，成桌=即將開始完整資訊）
  const ActiveZone = () => (
    <div style={{ padding: '14px 20px 0' }}>
      <p style={{ margin: '0 0 8px', fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>{phase === 'waiting' ? '配桌進度' : '即將開始'}</p>
      <div style={{ background: 'var(--brand-light)', border: '1.5px solid var(--brand)', borderRadius: 'var(--r-lg)', padding: '14px 16px' }}>
        {phase === 'waiting' ? <>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8 }}>
            <span className="spin" style={{ width: 18, height: 18, border: '2.5px solid #F3D9E1', borderTopColor: 'var(--accent)', borderRadius: '50%', display: 'inline-block' }} />
            <p style={{ margin: 0, fontSize: 'var(--m)', fontWeight: 700, color: 'var(--ink)' }}>正在等待配桌，請稍候…</p>
          </div>
          <div style={{ display: 'flex', justifyContent: 'center', gap: 12, margin: '12px 0 10px' }}>
            {Array.from({ length: myQueue?.seats || 4 }).map((_, k) => {
              const p = myQueue?.players?.[k]
              return p
                ? <SeatAvatar key={k} rank={p.rank} size={48} />
                : <div key={k} style={{ width: 48, height: 48, borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', fontWeight: 700, fontSize: 14, background: 'var(--white)', color: '#E2A9B8', border: '1.5px dashed #E2A9B8' }}>?</div>
            })}
          </div>
          <p style={{ textAlign: 'center', fontSize: 14, color: 'var(--accent)', fontWeight: 700, margin: '0 0 4px' }}>目前 {myQueue?.player_count || 0} / {myQueue?.seats || 4} · 還差 {(myQueue?.seats || 4) - (myQueue?.player_count || 0)} 位成桌</p>
          <div className="queue"><p style={{ margin: '0 0 6px', fontSize: 14, fontWeight: 700, color: 'var(--ink)' }}>本桌動態</p>
            {(myQueue?.events || (myQueue?.players || []).map((p) => ({ type: 'join', nickname: p.nickname, at: p.joined_at }))).map((e, k) => (
              <div className="qrow" key={k}><span className="qt">{_hhmm(new Date(e.at))}</span><span className="qx"><b>{e.nickname}</b> {e.type === 'leave' ? '離開配桌' : '加入等待'}</span></div>
            ))}
          </div>
          {/* 牌局資訊（kv 列，放本桌動態下面）*/}
          <div style={{ marginTop: 12 }}>
            <p style={{ margin: '0 0 2px', fontSize: 14, fontWeight: 700, color: 'var(--ink)' }}>牌局資訊</p>
            {[['門市', active?.store || 'MIGI 高雄自由店'], ['玩法', `${fmtType(active?.type, active?.flower) || '台麻 · 無花'} · ${active?.stake || '50/20'}${active?.rounds ? ' · ' + active.rounds : ''}`], ['開打時間', active?.time || '今天 19:30']].map(([k, v], idx, arr) => (
              <div key={k} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 14, padding: '7px 0', borderBottom: idx === arr.length - 1 ? 'none' : '0.5px solid var(--gray-4)', fontSize: 14 }}>
                <span style={{ color: 'var(--ink)', flex: '0 0 auto' }}>{k}</span>
                <span style={{ color: 'var(--ink)', fontWeight: 700, textAlign: 'right' }}>{v}</span>
              </div>
            ))}
          </div>
          <button onClick={() => setInviteSheet('now')} style={{ marginTop: 12, width: '100%', background: 'var(--ink)', color: 'var(--white)', border: 'none', borderRadius: 'var(--r-pill)', padding: '11px 0', fontSize: 14, fontWeight: 700, cursor: 'pointer' }}>＋ 邀牌咖加入這桌</button>
          <button onClick={() => setReasonSheet(true)} style={{ marginTop: 8, width: '100%', background: 'var(--white)', border: '1px dashed #CFC9C5', color: 'var(--gray-2)', borderRadius: 'var(--r-pill)', padding: '11px 0', fontSize: 13, fontWeight: 700, cursor: 'pointer' }}>取消配桌</button>
        </> : <>
          {/* 成桌紅字標題（比照配桌中樣式） */}
          <p style={{ margin: '0 0 12px', fontSize: 'var(--m)', fontWeight: 700, color: 'var(--ink)', textAlign: 'center' }}>你已經成桌囉！</p>
          {/* 同桌四人：真實頭像＋暱稱＋段位 */}
          <div style={{ display: 'flex', justifyContent: 'center', gap: 14, margin: '2px 0 14px' }}>
            {(myQueue?.players || []).map((p, k) => (
              <div key={k} style={{ textAlign: 'center', width: 56 }}>
                <SeatAvatar rank={p.rank} size={44} />
                <p style={{ margin: '5px 0 0', fontSize: 11, fontWeight: 700, color: 'var(--ink)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{p.nickname}</p>
                <p style={{ margin: '1px 0 0', fontSize: 9, color: 'var(--gray-2)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{p.rank}</p>
              </div>
            ))}
          </div>
          {/* 資訊 kv 列（對標成桌彈窗） */}
          {[['時間', active?.time || '今天 19:30'], ['門市', active?.store || 'MIGI 高雄自由店'], ['地址', active?.addr || '高雄市左營區自由三路 410 號'], ['玩法', `${fmtType(active?.type, active?.flower) || '台麻 · 無花'} · ${active?.stake || '50/20'} · ${active?.rounds || '3 將'}`]].map(([k, v], idx, arr) => (
            <div key={k} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 14, padding: '7px 0', borderBottom: idx === arr.length - 1 ? 'none' : '0.5px solid var(--gray-4)', fontSize: 14 }}>
              <span style={{ color: 'var(--ink)', flex: '0 0 auto' }}>{k}</span>
              <span style={{ color: 'var(--ink)', fontWeight: 700, textAlign: 'right' }}>{v}</span>
            </div>
          ))}
          {/* 注意事項（直接展開，白底灰框） */}
          <div style={{ marginTop: 12, background: 'var(--white)', border: '1px solid #E2DEDB', borderRadius: 13, padding: '11px 14px' }}>
            <p style={{ margin: '0 0 6px', fontSize: 13, fontWeight: 700, color: 'var(--ink)' }}>注意事項</p>
            <p style={{ margin: 0, fontSize: 13, color: 'var(--gray-1)', lineHeight: 2 }}>· 嚴禁賭博，點數只用於檯費與餐飲<br />· 請務必準時到達，遲到視情況懲罰扣點<br />· 店內全面禁菸，含電子菸與加熱菸<br />· 特殊玩法（骰龜／豹子／哩咕等）請現場與同桌客人討論</p>
          </div>
          <div style={{ display: 'flex', gap: 10, marginTop: 14 }}>
            <button onClick={navTo} style={{ flex: 1, background: 'var(--ink)', color: 'var(--white)', border: 'none', borderRadius: 'var(--r-pill)', padding: '12px 0', fontSize: 'var(--m)', fontWeight: 700, cursor: 'pointer' }}>導航過去</button>
            <button onClick={() => alert('叫車服務即將推出')} style={{ flex: 1, background: 'var(--white)', border: '1.5px solid var(--ink)', color: 'var(--ink)', borderRadius: 'var(--r-pill)', padding: '12px 0', fontSize: 'var(--m)', fontWeight: 700, cursor: 'pointer' }}>叫車過去</button>
          </div>
        </>}
      </div>
    </div>
  )

  return (
    <>
      <div style={{ padding: '0 20px' }}>
        <div style={{ background: 'var(--brand)', borderRadius: 22, padding: '15px 18px', position: 'relative', overflow: 'hidden' }}>{deco}
          <p style={{ margin: 0, fontSize: 'var(--xl)', fontWeight: 700, color: 'var(--ink)' }}>我要配桌</p>
          <p style={{ margin: '2px 0 0', fontSize: 'var(--xs)', color: 'var(--gray-1)' }}>依積分、時間幫妳湊一桌</p>
          {!inProgress && <div style={{ display: 'flex', gap: 8, marginTop: 13 }}>
            <button className="ibtn" style={{ flex: 1, background: 'var(--ink)', padding: '10px 0', fontSize: 'var(--m)', fontWeight: 700, color: 'var(--white)' }} onClick={() => setTablesPage(true)}>開始配桌</button>
            <button className="ibtn" style={{ flex: 1, background: 'rgba(255,255,255,0.75)', padding: '10px 0', fontSize: 'var(--m)', fontWeight: 700, color: 'var(--ink)' }} onClick={() => setSetupOpen(true)}>自己開一桌</button>
          </div>}
        </div>
      </div>

      {/* 配桌待處理提示欄（揪桌邀請＋收桌，與通知中心同步）*/}
      {pendingReqs.length > 0 && (
        <div style={{ padding: '12px 20px 0', display: 'flex', flexDirection: 'column', gap: 8 }}>
          {pendingReqs.map((n) => (
            <div key={n.id} style={{ display: 'flex', alignItems: 'center', gap: 10, background: 'var(--brand-light)', border: '1px solid var(--brand)', borderRadius: 'var(--r-card)', padding: '10px 12px' }}>
              <span style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--brand)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 16, flex: '0 0 34px' }}>{n.type === 'settle' ? '🀄' : '👋'}</span>
              <p style={{ margin: 0, flex: 1, fontSize: 'var(--xs)', color: 'var(--ink)', lineHeight: 1.5, minWidth: 0 }}>{n.type === 'settle' ? `你的 ${n.at || '7/16 20:00'} ${n.store || 'MIGI 高雄自由店'} · ${n.stake || '50/20'} 牌局結算完成` : n.text}</p>
              {n.type === 'settle'
                ? <button className="ibtn" onClick={() => onOpenSettle && onOpenSettle()} style={{ background: 'none', padding: '6px 4px', fontSize: 'var(--xs)', color: 'var(--accent)', fontWeight: 700, flex: '0 0 auto' }}>查看 ›</button>
                : <>
                    <button className="ibtn" onClick={() => { respondTableReq(n.id, false); showToast('已拒絕（對方不會收到通知）') }} style={{ background: 'var(--white)', padding: '6px 12px', fontSize: 'var(--xs)', color: 'var(--gray-1)', flex: '0 0 auto' }}>拒絕</button>
                    <button className="ibtn" onClick={() => { respondTableReq(n.id, true); showToast('已加入 ' + n.from + ' 的牌桌') }} style={{ background: 'var(--ink)', padding: '6px 12px', fontSize: 'var(--xs)', color: 'var(--white)', fontWeight: 700, flex: '0 0 auto' }}>接受</button>
                  </>}
            </div>
          ))}
        </div>
      )}

      {/* 成桌區（進行中時，常駐第一眼可見） */}
      {inProgress && <ActiveZone />}

      {/* 預設狀態（非進行中才顯示門市/牌局/設定） */}
      {!inProgress && <>
        <div style={{ padding: '12px 20px 0', display: 'flex', alignItems: 'center', gap: 6 }}>
          <MapPin /><span style={{ fontSize: 'var(--s)', color: 'var(--gray-1)' }}>你在 <b style={{ color: 'var(--ink)', fontWeight: 700 }}>高雄市</b> · 附近 3 家店有牌局</span>
        </div>

        <div style={{ padding: '14px 20px 0' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <p style={{ margin: '0 0 8px', fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>目前有的牌局</p>
            <span onClick={() => setTablesPage(true)} style={{ fontSize: 13, fontWeight: 700, color: 'var(--accent)', cursor: 'pointer' }}>全部 ›</span>
          </div>
          {liveQueues.length === 0 && fixQueues.length === 0 && (
            <div style={{ border: '1px dashed var(--field-bd)', background: 'var(--field-bg)', borderRadius: 'var(--r-card)', margin: '0 0 8px', fontSize: 'var(--xs)', color: 'var(--gray-2)', textAlign: 'center', padding: '16px 0' }}>目前沒有等待中的牌局，開一桌吧！</div>
          )}
          {liveQueues.length > 0 && <p style={{ margin: '4px 0 8px', fontSize: 13, fontWeight: 600, color: 'var(--gray-1)' }}>即時牌局</p>}
          {liveQueues.slice(0, 2).map((q) => (
            <div key={q.id} style={{ border: '1.5px solid var(--brand)', background: 'var(--brand-light)', borderRadius: 'var(--r-card)', padding: '11px 13px', display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8 }}>
              <div style={{ flex: 1, minWidth: 0 }}>
                {q.source === 'pos' && <div style={{ marginBottom: 6, display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}><RecmdBadge />{(q.tags || []).map((tg) => QUEUE_TAGS[tg] && <span key={tg} style={{ fontSize: 11, color: 'var(--accent)', fontWeight: 600 }}>{QUEUE_TAGS[tg]}</span>)}</div>}
                <div style={{ fontSize: 'var(--s)', fontWeight: 600, color: 'var(--ink)' }}>{store.name.replace('MIGI ', '')} · {fmtPlayAt(q.play_at)} · {stakeMap[q.stake_level_id] || ''} · {fmtType(q.game_type, q.flower)}{q.rounds ? ' · ' + q.rounds : ''}</div>
                <div style={{ fontSize: 'var(--xs)', color: 'var(--gray-1)', marginTop: 2 }}>目前 {q.players || 0}/{q.seats || 4}，還差 {(q.seats || 4) - (q.players || 0)} 位成桌</div>
              </div>
              <button className="ibtn" onClick={() => joinReal(q)} style={{ background: 'var(--ink)', color: 'var(--white)', borderRadius: 'var(--r-pill)', padding: '7px 16px', fontSize: 'var(--xs)', fontWeight: 700 }}>加入</button>
            </div>
          ))}
          {fixQueues.length > 0 && <p style={{ margin: '10px 0 8px', fontSize: 13, fontWeight: 600, color: 'var(--gray-1)' }}>固定牌局</p>}
          {fixQueues.slice(0, 2).map((q) => (
            <div key={q.id} style={{ border: '1.5px solid var(--gold)', background: 'var(--milktea)', borderRadius: 'var(--r-card)', padding: '11px 13px', display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8 }}>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 14, fontWeight: 700, color: 'var(--gray-1)', marginBottom: 3 }}>
                  <IconCalendar size={15} color="var(--gray-1)" />{freqLabel(q)}
                </div>
                <div style={{ fontSize: 'var(--s)', fontWeight: 600, color: 'var(--ink)' }}>{store.name.replace('MIGI ', '')} · {fmtPlayAt(q.play_at)} · {stakeMap[q.stake_level_id] || ''} · {fmtType(q.game_type, q.flower)}{q.rounds ? ' · ' + q.rounds : ''}</div>
                <div style={{ fontSize: 'var(--xs)', color: 'var(--gray-1)', marginTop: 2 }}>目前 {q.players || 0}/{q.seats || 4}，還差 {(q.seats || 4) - (q.players || 0)} 位成桌</div>
              </div>
              <button className="ibtn" onClick={() => joinReal(q)} style={{ background: 'var(--ink)', color: 'var(--white)', borderRadius: 'var(--r-pill)', padding: '7px 16px', fontSize: 'var(--xs)', fontWeight: 700 }}>報名</button>
            </div>
          ))}
        </div>

      </>}

      {/* 開一桌設定抽屜 */}
      {setupOpen && (
        <DragSheet onClose={() => setSetupOpen(false)} title="我要自己開一桌" subtitle="設定條件，幫你湊齊一桌">
            <div style={{ padding: '8px 0 0' }}><p style={{ margin: '0 0 8px', fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>要在哪開桌</p>
              <StorePickerSearch current={store.name} onPick={(x) => setStore({ ...store, name: x.name, area: x.area })} />
            </div>
            <Group label="遊戲規則" opts={['台麻', '美麻']} val={mahjongKind} set={setMahjongKind} />
            <Group label="花牌" opts={['無花', '有花']} val={flower} set={setFlower} />
            <Group label="想打多少積分" opts={stakes.length ? stakes.map((s) => s.label) : [stake]} val={stake} set={setStake} />
            <div style={{ padding: '14px 0 0' }}><p style={{ margin: '0 0 8px', fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>哪一天</p>
              <div><DateField value={matchDay} onChange={setMatchDay} /></div>
              <div style={{ display: 'flex', flexWrap: 'wrap' }}>{[['今天', dayStr(0)], ['明天', dayStr(1)], ['這週末', dayStr((6 - new Date().getDay() + 7) % 7 || 6)]].map(([lb, val]) => <span key={lb} onClick={() => setMatchDay(val)} className={`ichip ${matchDay === val ? 'on' : ''}`}>{lb}</span>)}</div>
            </div>
            <div style={{ padding: '14px 0 0' }}><p style={{ margin: '0 0 8px', fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>最晚幾點前開打</p>
              <div><TimeField value={startT} onChange={setStartT} hidden={startT === '不限'} /></div>
              <div style={{ display: 'flex', flexWrap: 'wrap' }}>{[['+30 分', fromNow(30)], ['+1 小時', fromNow(60)], ['不限', '不限']].map(([lb, val]) => <span key={lb} onClick={() => setStartT(val)} className={`ichip ${startT === val ? 'on' : ''}`}>{lb}</span>)}</div>
            </div>
            <div style={{ padding: '14px 0 0' }}><p style={{ margin: '0 0 8px', fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>我可以打到</p>
              <div><TimeField value={endT} onChange={setEndT} hidden={endT === '不限'} /></div>
              <div style={{ display: 'flex', flexWrap: 'wrap' }}>{[['+3 小時', fromNow(180)], ['+4 小時', fromNow(240)], ['不限', '不限']].map(([lb, val]) => <span key={lb} onClick={() => setEndT(val)} className={`ichip ${endT === val ? 'on' : ''}`}>{lb}</span>)}</div>
            </div>
            <Group label="我可以打" opts={['2 將', '3 將']} val={rounds} set={setRounds} />
            <div style={{ padding: '14px 0 0' }}>
              {(() => { const av = myBlocks; return (
                <>
                  <div onClick={() => av.length > 0 && setAvoidExpand((o) => !o)} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: av.length > 0 ? 'pointer' : 'default' }}>
                    <p style={{ margin: '0 0 4px', fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>我的黑名單 {av.length > 0 && <span style={{ fontSize: 'var(--xs)', color: 'var(--danger)', fontWeight: 700 }}>· {av.length} 人</span>}</p>
                    {av.length > 0 && <span style={{ fontSize: 'var(--s)', color: 'var(--accent)', fontWeight: 700 }}>{avoidExpand ? '收合 ▲' : '展開 ▼'}</span>}
                  </div>
                  <p style={{ margin: '0 0 8px', fontSize: 'var(--xs)', color: 'var(--gray-1)' }}>配桌會自動跳過這些人</p>
                  {av.length === 0 ? (
                    <div style={{ border: '1px dashed var(--field-bd)', background: 'var(--field-bg)', borderRadius: 'var(--r-card)', padding: 14, textAlign: 'center', fontSize: 'var(--s)', color: 'var(--gray-1)' }}>目前沒有黑名單</div>
                  ) : avoidExpand && (
                    <div style={{ border: '1px solid var(--field-bd)', borderRadius: 'var(--r-card)', overflow: 'hidden' }}>
                      {av.map((b, k, arr) => (
                        <div key={b.id} style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '10px 14px', background: 'var(--gray-4)', borderBottom: k === arr.length - 1 ? 'none' : '.5px solid var(--gray-3)' }}>
                          <SeatAvatar rank={b.rank} size={34} />
                          <span style={{ fontSize: 'var(--m)', color: 'var(--ink)', flex: 1, minWidth: 0 }}>{b.nickname}</span>
                          <button className="ibtn" onClick={async () => { if (!window.confirm(`確定要將「${b.nickname}」移出黑名單嗎？`)) return; await unblockMember(b.id); showToast('已移出黑名單'); fetchBlocks().then(setMyBlocks) }} style={{ background: 'none', color: 'var(--danger)', fontSize: 'var(--xs)', fontWeight: 600, padding: '4px 8px', flex: '0 0 auto' }}>移除</button>
                        </div>
                      ))}
                    </div>
                  )}
                </>
              ) })()}
            </div>
            <div style={{ padding: '14px 0 0' }}><button className="ibtn" onClick={() => setInviteSheet('pending')} style={{ width: '100%', background: 'var(--brand)', color: 'var(--ink)', padding: '11px 0', fontSize: 'var(--m)', fontWeight: 700 }}>＋ 邀牌咖加入{pendingTableInvites().length > 0 ? '（已選 ' + pendingTableInvites().length + ' 位）' : ''}</button></div>
            <div style={{ padding: '10px 0 0' }}><button className="ibtn" onClick={() => { setSetupOpen(false); startMatch() }} disabled={joining} style={{ width: '100%', background: joining ? 'var(--gray-2)' : 'var(--ink)', padding: '13px 0', fontSize: 'var(--l)', fontWeight: 700, color: 'var(--white)', cursor: joining ? 'default' : 'pointer' }}>{joining ? '正在加入牌局…' : '開始配桌'}</button></div>
        </DragSheet>
      )}

      {/* 歷史配桌紀錄（最近三筆配桌；全部→成績頁牌局紀錄的配桌篩選）*/}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', padding: '18px 20px 6px' }}>
        <span style={{ fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>歷史配桌紀錄</span>
        <span onClick={() => onGoStats && onGoStats()} style={{ fontSize: 13, fontWeight: 700, color: 'var(--accent)', cursor: 'pointer' }}>全部 ›</span>
      </div>
      <div style={{ padding: '0 20px 16px' }}>
        {inProgress && active && (
          <div className="irow">
            <span className="itile" style={{ background: phase === 'matched' ? 'var(--brand)' : 'var(--gray-4)', color: phase === 'matched' ? 'var(--ink)' : 'var(--gray-2)', width: 30, height: 38, fontSize: 'var(--l)' }}>桌</span>
            <div style={{ flex: 1, minWidth: 0 }}>
              <p style={{ margin: 0, fontSize: 'var(--m)', color: 'var(--ink)', fontWeight: 500 }}>{active.store} · {active.stake} · {fmtType(active.type, active.flower)}</p>
              <p style={{ margin: '2px 0 0', fontSize: 'var(--xs)', color: 'var(--gray-1)' }}>{phase === 'matched' ? active.time + ' 開打' : '配桌中…'}</p>
            </div>
            <span style={{ fontSize: 11, fontWeight: 700, padding: '3px 9px', borderRadius: 'var(--r-pill)', background: '#FBEAF0', color: 'var(--accent)' }}>{phase === 'matched' ? '即將開始' : '配桌中'}</span>
          </div>
        )}
        {DEMO_MATCHES.filter((m) => (m.kind || 'match') === 'match').slice(0, 3).map((m, i, arr) => (
          <div key={m.id} onClick={() => setViewRecord(m)} className="irow" style={{ cursor: 'pointer', ...(i === arr.length - 1 ? { borderBottom: 'none' } : {}) }}>
            <span className="itile" style={{ background: m.status === 'settled' ? (m.win ? 'var(--brand)' : 'var(--field-bg)') : m.status === 'pending' ? 'var(--brand)' : 'var(--gray-4)', color: m.status === 'nomatch' ? 'var(--gray-2)' : 'var(--ink)', width: 30, height: 38, fontSize: 'var(--l)' }}>{m.status === 'settled' ? (m.win ? '勝' : '負') : m.status === 'pending' ? '等' : '未'}</span>
            <div style={{ flex: 1, minWidth: 0 }}>
              <p style={{ margin: 0, fontSize: 'var(--m)', color: m.status === 'nomatch' ? 'var(--gray-1)' : 'var(--ink)', fontWeight: 500 }}>{m.status === 'settled' ? `第 ${m.rank} 名 · ${m.stake}` : `${m.store.replace('MIGI ', '')} · ${m.stake}`}</p>
              <p style={{ margin: '2px 0 0', fontSize: 'var(--xs)', color: 'var(--gray-2)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{m.time}{m.status === 'settled' ? ` · ${m.store}` : ''}</p>
            </div>
            {m.status === 'settled' && <span style={{ fontSize: 'var(--m)', fontWeight: 700, color: m.amt > 0 ? 'var(--accent)' : 'var(--ink)', marginRight: 8 }}>{m.amt > 0 ? '+' : ''}{m.amt}</span>}
            {m.status === 'pending' && <span style={{ background: 'var(--brand)', color: 'var(--ink)', borderRadius: 'var(--r-pill)', padding: '3px 10px', fontSize: 11, fontWeight: 700, flex: '0 0 auto', marginRight: 8 }}>已成桌</span>}
            <span style={{ background: 'var(--gray-4)', color: 'var(--ink)', borderRadius: 'var(--r-pill)', padding: '6px 13px', fontSize: 12, fontWeight: 700, flex: '0 0 auto' }}>查看</span>
          </div>
        ))}
      </div>

      {tablesPage && <TablesPage store={store} stores={stores} storeId={storeId} onPickStore={setStoreId} queues={queues} stakeMap={stakeMap} onJoin={joinReal} onClose={() => setTablesPage(false)} />}
      {viewRecord && <RecordDetailSheet t={viewRecord} onClose={() => setViewRecord(null)} />}
      {showModal && active && <MatchedModal t={{ ...active, players: myQueue?.players }} onClose={() => setShowModal(false)} />}
      {avoidPage && <AvoidPage onBack={() => setAvoidPage(false)} />}
      {reasonSheet && <ReasonSheet onPick={cancelWith} onClose={() => setReasonSheet(false)} />}
      {inviteSheet && <InviteBuddySheet mode={inviteSheet} onClose={() => setInviteSheet(null)} />}
      {joining && <JoiningOverlay />}
    </>
  )
}


// 配桌紀錄列（左邊形狀比照消費紀錄 .itile）
function RecordRow({ r, last, onView }) {
  return (
    <div className="irow" style={last ? { borderBottom: 'none' } : undefined}>
      <span className="itile" style={{ background: r.ok ? 'var(--brand)' : 'var(--gray-4)', color: r.ok ? 'var(--ink)' : 'var(--gray-2)', width: 30, height: 38, fontSize: 'var(--l)' }}>桌</span>
      <div style={{ flex: 1, minWidth: 0 }}>
        <p style={{ margin: 0, fontSize: 'var(--m)', color: 'var(--ink)', fontWeight: 500 }}>{r.store} · {r.stake} · {r.type}</p>
        <p style={{ margin: '2px 0 0', fontSize: 'var(--xs)', color: 'var(--gray-1)' }}>{r.time}</p>
      </div>
      {r.ok ? <>
        <span style={{ fontSize: 11, fontWeight: 700, padding: '3px 9px', borderRadius: 'var(--r-pill)', background: 'var(--brand)', color: 'var(--ink)', marginRight: 8 }}>已成桌</span>
        <button onClick={onView} className="ibtn" style={{ background: 'var(--gray-4)', padding: '6px 14px', fontSize: 12, color: 'var(--ink)', fontWeight: 700, flex: '0 0 auto' }}>查看</button>
      </> : <span style={{ fontSize: 11, fontWeight: 700, padding: '3px 9px', borderRadius: 'var(--r-pill)', background: 'var(--field-bg)', color: 'var(--gray-2)' }}>未成桌</span>}
    </div>
  )
}

function RecordsPage({ records, onView, onClose }) {
  return createPortal(
    <div className="sheet-anim" style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: 'var(--white)', zIndex: 1000, display: 'flex', flexDirection: 'column' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '16px 16px 12px', borderBottom: '.5px solid var(--gray-4)' }}>
        <button onClick={onClose} style={{ background: 'none', border: 'none', fontSize: 22, color: 'var(--ink)', cursor: 'pointer', padding: '0 4px' }}>‹</button>
        <span style={{ fontSize: 17, fontWeight: 700, color: 'var(--ink)' }}>配桌紀錄</span>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '8px 20px 20px' }}>
        {records.map((r, i, arr) => <RecordRow key={r.id} r={r} last={i === arr.length - 1} onView={() => onView(r)} />)}
      </div>
    </div>, document.body)
}

/* —— 邀牌咖抽屜：mode='now' 配桌中直接邀 / mode='pending' 開桌前先勾、開桌後自動邀 —— */
function InviteBuddySheet({ mode, onClose }) {
  const [myBuddies, setMyBuddies] = useState(null)   // 我的牌咖名單（真資料，接 list_buddies_tx）
  useEffect(() => { fetchBuddies().then(setMyBuddies) }, [])
  const [invitedNow, setInvitedNow] = useState([])   // now 模式：本次已直接邀請的人
  const picked = (nm) => mode === 'now' ? invitedNow.indexOf(nm) >= 0 : pendingTableInvites().indexOf(nm) >= 0
  const pick = (nm) => {
    if (picked(nm)) return
    if (mode === 'now') { sendTableInvite(nm, 'direct'); setInvitedNow((p) => [...p, nm]); showToast('已邀請 ' + nm + ' 加入你的牌桌') }
    else { addPendingTableInvite(nm); setInvitedNow((p) => [...p, nm]); showToast('開桌後會自動邀請 ' + nm) }
  }
  return (
    <DragSheet onClose={onClose} title="邀牌咖" subtitle={mode === 'now' ? '邀請牌咖加入這一桌' : '開桌成功後會自動送出邀請'}>
      {myBuddies === null ? (
        <p style={{ padding: '30px 0', textAlign: 'center', color: 'var(--gray-2)', fontSize: 'var(--s)' }}>載入中…</p>
      ) : myBuddies.length === 0 ? (
        <p style={{ padding: '30px 0', textAlign: 'center', color: 'var(--gray-2)', fontSize: 'var(--s)' }}>你還沒有牌咖，先去牌咖頁加朋友吧</p>
      ) : myBuddies.map((b, i) => {
        const nm = b.nickname
        const on = picked(nm)
        return (
          <div key={b.id} className="irow" style={i === myBuddies.length - 1 ? { borderBottom: 'none' } : undefined}>
            <SeatAvatar rank={b.rank} size={36} />
            <p style={{ margin: 0, flex: 1, fontSize: 'var(--m)', color: 'var(--ink)' }}>{nm}</p>
            <button className="ibtn" disabled={on} onClick={() => pick(nm)} style={{ background: on ? 'var(--gray-4)' : 'var(--brand)', color: on ? 'var(--gray-2)' : 'var(--ink)', padding: '6px 16px', fontSize: 'var(--xs)', fontWeight: 700 }}>{on ? '已邀請' : '邀請'}</button>
          </div>
        )
      })}
      <p style={{ margin: '10px 0 0', fontSize: 11, color: 'var(--gray-2)', textAlign: 'center' }}>對方接受後會自動加入 · 拒絕的話你不會收到通知</p>
      <button className="ibtn" onClick={onClose} style={{ width: '100%', marginTop: 12, background: 'var(--ink)', color: 'var(--white)', padding: '13px 0', fontSize: 14 }}>完成</button>
    </DragSheet>
  )
}

function JoiningOverlay() {
  return createPortal(
    <div className="ov-anim" style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: 'rgba(46,43,44,0.5)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 1200 }}>
      <div className="pop-anim" style={{ background: 'var(--white)', borderRadius: 18, padding: '22px 30px', textAlign: 'center' }}>
        <div className="spin" style={{ width: 30, height: 30, border: '3px solid var(--brand)', borderTopColor: 'var(--accent)', borderRadius: '50%', margin: '0 auto 12px' }} />
        <p style={{ margin: 0, fontSize: 15, fontWeight: 700, color: 'var(--ink)' }}>正在加入牌局…</p>
      </div>
    </div>, document.body)
}

function BearAvatar() {
  return <svg viewBox="0 0 40 40" width="100%" height="100%"><rect width="40" height="40" fill="#C99BAA" /><circle cx="20" cy="16" r="7.5" fill="#fff" /><path d="M7 39 Q7 27 20 27 Q33 27 33 39 Z" fill="#fff" /></svg>
}

function ReasonSheet({ onPick, onClose }) {
  const REASONS = ['臨時有事', '等待太久', '其他地方找到了', '想換玩法／積分']
  const [sel, setSel] = useState(null)
  const [otherMode, setOtherMode] = useState(false)
  const [otherTxt, setOtherTxt] = useState('')
  return (
    <DragSheet onClose={onClose} title="取消配桌的原因？" subtitle="選一個原因，讓其他同桌的人知道">
      {REASONS.map((r) => (
        <div key={r} onClick={() => { setSel(r); setOtherMode(false) }}
          style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', border: sel === r ? '2px solid var(--ink)' : '1.5px solid var(--gray-3)', borderRadius: 'var(--r-field)', padding: '13px 15px', marginBottom: 9, fontSize: 14, fontWeight: sel === r ? 700 : 400, color: 'var(--ink)', cursor: 'pointer' }}>
          <span>{r}</span><span style={{ fontSize: 14, color: sel === r ? 'var(--ink)' : 'var(--gray-2)' }}>{sel === r ? '\u25CF' : '\u25CB'}</span>
        </div>
      ))}
      {!otherMode ? (
        <div onClick={() => { setOtherMode(true); setSel(otherTxt || null) }}
          style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', border: '1.5px solid var(--gray-3)', borderRadius: 'var(--r-field)', padding: '13px 15px', marginBottom: 9, fontSize: 14, color: 'var(--ink)', cursor: 'pointer' }}>
          <span>其他（可填）</span><span style={{ fontSize: 14, color: 'var(--gray-2)' }}>{'\u25CB'}</span>
        </div>
      ) : (
        <div style={{ border: '2px solid var(--ink)', borderRadius: 'var(--r-field)', padding: '13px 15px', marginBottom: 9, display: 'flex', alignItems: 'center', gap: 10 }}>
          <input autoFocus value={otherTxt} onChange={(e) => { setOtherTxt(e.target.value); setSel(e.target.value || null) }} placeholder="輸入你的原因…"
            style={{ flex: 1, border: 'none', background: 'transparent', fontSize: 14, color: 'var(--ink)', fontFamily: 'inherit', outline: 'none' }} />
          <span style={{ fontSize: 14, color: 'var(--ink)' }}>{'\u25CF'}</span>
        </div>
      )}
      <button onClick={onClose} style={{ width: '100%', marginTop: 6, background: 'var(--ink)', border: 'none', color: 'var(--white)', borderRadius: 'var(--r-pill)', padding: '13px 0', fontSize: 15, fontWeight: 700, cursor: 'pointer' }}>先不要取消</button>
      {sel && <button onClick={() => onPick(sel)} style={{ width: '100%', marginTop: 8, background: 'var(--gray-4)', border: 'none', color: 'var(--gray-1)', borderRadius: 'var(--r-pill)', padding: '13px 0', fontSize: 15, fontWeight: 600, cursor: 'pointer' }}>確定取消</button>}
    </DragSheet>
  )
}
// 配桌詳情（紀錄回顧）— 通用抽屜：DragSheet 標題+×，與通知詳情/優惠券同款


function MatchedModal({ t, onClose, mode = 'matched' }) {
  const isDetail = mode === 'detail'
  const [showNotice, setShowNotice] = useState(false)
  const ppl = (t.players && t.players.length ? t.players : [
    { ini: '你', name: '你' }, { ini: '小', name: '小美' }, { ini: '阿', name: '阿凱' }, { ini: '婉', name: '婉婷' },
  ])
  // 時間：今天就寫「今天 HH:MM」，否則寫「M/D HH:MM」
  // 時間：今天→「今晚/今天 HH:MM」，非今天→「M/D HH:MM」（示意值今晚）
  const timeText = t.time || '今天 19:30'
  return createPortal(
    <div className="ov-anim" onClick={(e) => { if (e.target === e.currentTarget) onClose() }} style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: 'rgba(46,43,44,0.5)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 1000, padding: 18 }}>
      <div className="pop-anim" style={{ background: 'var(--white)', borderRadius: 24, width: '100%', maxHeight: '92%', overflowY: 'auto', overflowX: 'hidden', position: 'relative' }}>
        {/* 滿版粉頭圖 + 右上關閉 */}
        <div style={{ background: 'var(--brand)', padding: '20px 20px 16px', textAlign: 'center', position: 'relative' }}>
          <button onClick={onClose} style={{ position: 'absolute', top: 12, right: 14, width: 30, height: 30, borderRadius: '50%', background: 'rgba(255,255,255,0.6)', border: 'none', fontSize: 18, color: 'var(--ink)', cursor: 'pointer', lineHeight: 1 }}>×</button>
          <p style={{ margin: 0, fontSize: 20, fontWeight: 700, color: 'var(--ink)' }}>{isDetail ? '配桌詳情' : '成桌囉！'}</p>
          <p style={{ margin: '3px 0 0', fontSize: 12, color: 'var(--gray-1)' }}>{isDetail ? '這場配桌的紀錄' : '四人到齊，準備開打'}</p>
        </div>
        <div style={{ padding: '13px 20px 18px' }}>
          {/* 同桌四人：真實頭像＋暱稱＋段位 */}
          <div style={{ display: 'flex', justifyContent: 'center', gap: 14, margin: '2px 0 14px' }}>
            {(t.players && t.players.length ? t.players.map((p) => [p.nickname, p.rank]) : TABLE_PLAYERS).map(([nm, rank], k) => (
              <div key={k} style={{ textAlign: 'center', width: 58 }}>
                <SeatAvatar rank={rank} size={40} />
                <p style={{ margin: '5px 0 0', fontSize: 11, fontWeight: 700, color: 'var(--ink)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{nm}</p>
                <p style={{ margin: '1px 0 0', fontSize: 9, color: 'var(--gray-2)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{rank}</p>
              </div>
            ))}
          </div>
          {/* 資訊 */}
          {[['時間', timeText], ['門市', t.store || 'MIGI 高雄自由店'], ['地址', t.addr || '高雄市左營區自由三路 410 號'], ['玩法', `${fmtType(t.type, t.flower) || '台麻 · 無花'} · ${t.stake || '50/20'} · ${t.rounds || '3 將'}`]].map(([k, v], idx, arr) => (
            <div key={k} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 14, padding: '7px 0', borderBottom: '0.5px solid var(--gray-4)', fontSize: 14 }}>
              <span style={{ color: 'var(--ink)', flex: '0 0 auto' }}>{k}</span>
              <span style={{ color: 'var(--ink)', fontWeight: 700, textAlign: 'right' }}>{v}</span>
            </div>
          ))}
          {/* 成桌前才顯示注意事項；配桌詳情(回顧)不顯示動態/注意事項 */}
          {!isDetail && (
            <div style={{ marginTop: 12, background: 'var(--field-bg)', border: '1px solid var(--field-bd)', borderRadius: 13, overflow: 'hidden' }}>
              <div onClick={() => setShowNotice(!showNotice)} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '11px 14px', cursor: 'pointer' }}>
                <span style={{ fontSize: 13, fontWeight: 700, color: 'var(--ink)' }}>注意事項</span>
                <span style={{ fontSize: 12, color: 'var(--accent)', fontWeight: 700 }}>{showNotice ? '收合 ▲' : '展開 ▼'}</span>
              </div>
              {showNotice && (
                <p style={{ margin: 0, padding: '0 14px 12px', fontSize: 13, color: 'var(--gray-1)', lineHeight: 2 }}>· 嚴禁賭博，點數只用於檯費與餐飲<br />· 請務必準時到達，遲到視情況懲罰扣點<br />· 店內全面禁菸，含電子菸與加熱菸<br />· 特殊玩法（骰龜／豹子／哩咕等）請現場與同桌客人討論</p>
              )}
            </div>
          )}
          {isDetail ? (
            <button onClick={onClose} style={{ width: '100%', marginTop: 14, background: 'var(--gray-4)', color: 'var(--gray-1)', border: 'none', borderRadius: 'var(--r-pill)', padding: '13px 0', fontSize: 14, fontWeight: 700, cursor: 'pointer' }}>關閉</button>
          ) : (
            <>
              <button onClick={onClose} style={{ width: '100%', marginTop: 14, marginBottom: 9, background: 'var(--ink)', color: 'var(--white)', border: 'none', borderRadius: 'var(--r-pill)', padding: '13px 0', fontSize: 14, fontWeight: 700, cursor: 'pointer' }}>我知道了</button>
              <button onClick={() => { const a = t.addr || '高雄市左營區自由三路410號'; const url = `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(a)}`; const w = window.open(url, '_blank'); if (!w) window.location.href = url }} style={{ width: '100%', background: 'var(--white)', border: '1.5px solid var(--ink)', color: 'var(--ink)', borderRadius: 'var(--r-pill)', padding: '13px 0', fontSize: 14, fontWeight: 700, cursor: 'pointer' }}>導航過去</button>
            </>
          )}
        </div>
      </div>
    </div>, document.body)
}


function TablesPage({ store, stores, storeId, onPickStore, queues, stakeMap, onJoin, onClose }) {
  const [filt, setFilt] = useState('全部')
  const [myCity, setMyCity] = useState('高雄市')   // 預設高雄市，定位成功後更新
  const [city, setCity] = useState('高雄市')
  useEffect(() => {
    if (!navigator.geolocation) return
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        const c = cityFromLatLng(pos.coords.latitude, pos.coords.longitude)
        setMyCity(c); setCity(c)
      },
      () => { /* 使用者拒絕定位或失敗 → 維持預設高雄市，不擋 UI */ },
      { timeout: 6000, maximumAge: 300000 }
    )
  }, [])
  const [area, setArea] = useState('全部')
  const CITY_LIST = Array.from(new Set(stores.map((s) => s.city).filter(Boolean)))
  // GPS 定位到的城市若沒有門市 → 自動降回清單第一個有開店的城市（純粹依開店狀況決定，不管使用者在哪）
  useEffect(() => {
    if (CITY_LIST.length > 0 && !CITY_LIST.includes(city)) { setCity(CITY_LIST[0]); setArea('全部') }
  }, [stores.length, city])
  const areas = ['全部', ...Array.from(new Set(stores.filter((s) => s.city === city).map((s) => s.district).filter(Boolean)))]
  // 篩選 chips：官方推薦＝真的濾 source=pos；其餘先為視覺（即時/固定分流待固定局功能上線）
  const shown = filt === '官方推薦' ? queues.filter((q) => q.source === 'pos')
    : filt === '固定' ? queues.filter((q) => q.source === 'recurring')
    : filt === '即時' ? queues.filter((q) => q.source !== 'recurring')
    : queues
  const Card = ({ q }) => {
    const players = q.players || 0
    const need = (q.seats || 4) - players
    const tags = Array.isArray(q.tags) ? q.tags : []
    const isPos = q.source === 'pos'
    const isFix = q.source === 'recurring'
    return (
      <div style={{ border: isFix ? '1.5px solid var(--gold)' : '1.5px solid var(--brand)', background: isFix ? 'var(--milktea)' : 'var(--brand-light)', borderRadius: 'var(--r-card)', padding: '11px 13px', display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8 }}>
        <div style={{ flex: 1 }}>
          {isFix && (
            <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 14, fontWeight: 700, color: 'var(--gray-1)', marginBottom: 3 }}>
              <IconCalendar size={15} color="var(--gray-1)" />{freqLabel(q)}
            </div>
          )}
          {(isPos || tags.length > 0) && (
            <div style={{ marginBottom: 8, display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
              {isPos && <span style={{ background: 'var(--accent)', borderRadius: 'var(--r-pill)', padding: '3px 11px', fontSize: 11, fontWeight: 700, color: 'var(--white)' }}>官方推薦</span>}
              {tags.filter((t) => QUEUE_TAGS[t]).map((t) => <span key={t} style={{ fontSize: 11, color: 'var(--accent)', fontWeight: 600 }}>{QUEUE_TAGS[t]}</span>)}
            </div>
          )}
          <div style={{ fontSize: 'var(--s)', fontWeight: 600, color: 'var(--ink)', display: 'flex', alignItems: 'center', gap: 5 }}>{!isFix && <IconClock size={14} />}{fmtPlayAt(q.play_at)} · {stakeMap[q.stake_level_id] || ''} · {fmtType(q.game_type, q.flower)}{q.rounds ? ' · ' + q.rounds : ''}</div>
          <div style={{ fontSize: 'var(--xs)', color: 'var(--gray-1)', marginTop: 2 }}>目前 {players}/{q.seats || 4}，還差 {need} 位成桌</div>
        </div>
        <button className="ibtn" onClick={() => onJoin(q)} style={{ background: 'var(--ink)', color: 'var(--white)', borderRadius: 'var(--r-pill)', padding: '7px 16px', fontSize: 'var(--xs)', fontWeight: 700 }}>{isFix ? '報名' : '加入'}</button>
      </div>
    )
  }
  return createPortal(
    <div className="sheet-anim" style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: 'var(--white)', zIndex: 1000, display: 'flex', flexDirection: 'column' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '16px 16px 12px', borderBottom: '.5px solid var(--gray-4)' }}>
        <button onClick={onClose} style={{ background: 'none', border: 'none', fontSize: 22, color: 'var(--ink)', cursor: 'pointer', padding: '0 4px' }}>‹</button>
        <span style={{ fontSize: 17, fontWeight: 700, color: 'var(--ink)' }}>目前有的牌局</span>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '14px 20px 20px' }}>
        <p style={{ margin: '0 0 8px', fontSize: 11, color: 'var(--accent)', fontWeight: 600, display: 'flex', alignItems: 'center', gap: 4 }}><MapPin />已定位你在 {myCity}</p>
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
        <div style={{ display: 'flex', gap: 8, overflowX: 'auto', marginBottom: 8 }}>
          {['全部', '即時', '固定', '官方推薦'].map((f) => <span key={f} onClick={() => setFilt(f)} style={{ flex: '0 0 auto', border: filt === f ? '1px solid var(--brand)' : '1px solid var(--gray-3)', background: filt === f ? 'var(--brand)' : 'var(--white)', color: filt === f ? 'var(--ink)' : 'var(--gray-1)', fontWeight: filt === f ? 600 : 400, borderRadius: 'var(--r-pill)', padding: '6px 16px', fontSize: 13, cursor: 'pointer' }}>{f}</span>)}
        </div>
        {shown.length === 0
          ? <div style={{ textAlign: 'center', color: 'var(--gray-2)', fontSize: 13, padding: '48px 0' }}>目前沒有適合你的牌桌，開一桌吧！</div>
          : shown.map((q) => <Card key={q.id} q={q} />)}
      </div>
    </div>, document.body)
}

export { Match, AvoidPage };
