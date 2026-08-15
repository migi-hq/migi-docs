// 統計頁（tab2 成績）— 從 App.jsx 抽出
// Stats + SeasonInfoSheet + MatchRecordsPage + MatchDetail
import { useState } from 'react'
import { createPortal } from 'react-dom'
import DefaultAvatar from '../DefaultAvatar'
import { MahjongTile } from '../lib/tiles.jsx'
import { ProfileCardOther, deco } from '../lib/components.jsx'
import { DEMO_MATCHES, STORE_CATS } from '../lib/data.jsx'
import { rankBearSrc } from '../lib/helpers.jsx'
import { RecordDetailSheet } from '../lib/GameDetailSheet.jsx'

// 本季段位（demo 寫死；★之後接後端 get_member_rank_tx 換成動態）
const SEASON_RANK = '金牌熊 II'

// 三態牌局紀錄列（共用：主頁預覽＋全部頁）settled=已結算 pending=已成桌未結算 nomatch=未成桌
function MatchRow({ m, last, onOpen }) {
  const st = m.status || 'settled'
  const tile = st === 'settled' ? { txt: m.win ? '勝' : '負', bg: m.win ? 'var(--brand)' : 'var(--field-bg)', fg: 'var(--ink)' }
    : st === 'pending' ? { txt: '等', bg: 'var(--brand)', fg: 'var(--ink)' }
    : { txt: '未', bg: 'var(--gray-4)', fg: 'var(--gray-2)' }
  return (
    <div onClick={() => onOpen(m)} className="irow" style={{ cursor: 'pointer', ...(last ? { borderBottom: 'none' } : {}) }}>
      <span className="itile" style={{ background: tile.bg, color: tile.fg, width: 30, height: 38, fontSize: 'var(--l)' }}>{tile.txt}</span>
      <div style={{ flex: 1, minWidth: 0 }}>
        <p style={{ margin: 0, fontSize: 'var(--m)', color: st === 'nomatch' ? 'var(--gray-1)' : 'var(--ink)', fontWeight: 500 }}>{st === 'settled' ? `第 ${m.rank} 名 · ${m.stake}` : `${m.store.replace('MIGI ', '')} · ${m.stake}`}</p>
        <p style={{ margin: '2px 0 0', fontSize: 'var(--xs)', color: 'var(--gray-2)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{m.time}{st === 'settled' ? ` · ${m.store} · ${m.players}` : m.type ? ` · ${m.type}` : ''}</p>
      </div>
      {st === 'settled' && <span style={{ fontSize: 'var(--m)', fontWeight: 700, color: m.amt > 0 ? 'var(--accent)' : 'var(--ink)', marginRight: 8 }}>{m.amt > 0 ? '+' : ''}{m.amt}</span>}
      {st === 'pending' && <span style={{ background: 'var(--brand)', color: 'var(--ink)', borderRadius: 'var(--r-pill)', padding: '3px 10px', fontSize: 11, fontWeight: 700, flex: '0 0 auto', marginRight: 8 }}>已成桌</span>}
      {st === 'nomatch' && <span style={{ background: 'var(--field-bg)', color: 'var(--gray-2)', borderRadius: 'var(--r-pill)', padding: '3px 10px', fontSize: 11, fontWeight: 700, flex: '0 0 auto', marginRight: 8 }}>未成桌</span>}
      <span style={{ background: 'var(--gray-4)', color: 'var(--ink)', borderRadius: 'var(--r-pill)', padding: '6px 13px', fontSize: 12, fontWeight: 700, flex: '0 0 auto' }}>查看</span>
    </div>
  )
}

function Stats({ initRecordsFilter }) {
  const [view, setView] = useState(initRecordsFilter ? 'recordsPage' : 'list') // list | detail | recordsPage
  const [recFilter, setRecFilter] = useState(initRecordsFilter || 'all')
  const [cur, setCur] = useState(null)
  const [reviewM, setReviewM] = useState(null)   // 查看→review 詳情抽屜
  const [seasonInfo, setSeasonInfo] = useState(false)
  const [hallCard, setHallCard] = useState(null)
  const KPI = [['胡牌率', '23.4%'], ['放槍率', '11.2%'], ['平均順位', '2.4'], ['全國排名', '#128']]
  if (view === 'detail') return <MatchDetail m={cur} onBack={() => setView('list')} />
  const reviewSheet = reviewM && <RecordDetailSheet t={reviewM} onClose={() => setReviewM(null)} onReplay={(m) => { setReviewM(null); setCur(m); setView('detail') }} />
  if (view === 'recordsPage') return <>{<MatchRecordsPage onBack={() => setView('list')} onOpen={setReviewM} initFilter={recFilter} />}{reviewSheet}</>

  const Row = ({ m, last }) => <MatchRow m={m} last={last} onOpen={setReviewM} />


  return (
    <>
      {/* 段位卡 B：賽季標籤可點開說明 + 本季段位 + 本季段位 */}
      <div style={{ padding: '0 20px' }}>
        <div style={{ background: 'var(--brand)', borderRadius: 22, padding: '16px 18px', position: 'relative', overflow: 'hidden', marginTop: 4 }}>
          {deco}
          <span onClick={() => setSeasonInfo(true)} style={{ fontSize: 11, fontWeight: 700, color: 'var(--accent)', background: 'var(--white)', borderRadius: 'var(--r-pill)', padding: '4px 11px', display: 'inline-flex', alignItems: 'center', gap: 5, marginBottom: 11, cursor: 'pointer' }}>🏆 2026 春季賽 · 倒數 23 天 <span style={{ width: 13, height: 13, borderRadius: '50%', border: '1px solid var(--accent)', fontSize: 9, display: 'inline-flex', alignItems: 'center', justifyContent: 'center' }}>i</span></span>
          <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
            <span style={{ width: 58, height: 58, borderRadius: '50%', background: 'var(--white)', overflow: 'hidden', flex: '0 0 58px', boxShadow: 'var(--shadow-sm)' }}><img src={rankBearSrc(SEASON_RANK)} alt="" width="100%" height="100%" style={{ display: 'block' }} /></span>
            <div style={{ flex: 1 }}>
              <p style={{ margin: 0, fontSize: 'var(--m)', fontWeight: 700, color: 'var(--ink)' }}>本季 · {SEASON_RANK}</p>
              <p style={{ margin: '3px 0 0', fontSize: 'var(--xs)', color: 'var(--gray-1)' }}>距離白金熊還差 180 分</p>
              <div style={{ height: 8, background: 'rgba(255,255,255,.6)', borderRadius: 'var(--r-pill)', marginTop: 8 }}><div style={{ width: '64%', height: 8, background: 'var(--accent)', borderRadius: 'var(--r-pill)' }} /></div>
            </div>
          </div>
        </div>
      </div>
      {seasonInfo && <SeasonInfoSheet onClose={() => setSeasonInfo(false)} />}
      {/* 雀神熊教練 · AI 分析（4：無頭像，名前小熊，全包進框） */}
      <div style={{ padding: '14px 20px 0' }}>
        <div style={{ background: 'var(--brand-light)', border: '1px solid var(--brand)', borderRadius: 'var(--r-card)', padding: '12px 13px' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 8 }}>
            <span style={{ fontSize: 14 }}>🐻</span>
            <span style={{ fontSize: 11, fontWeight: 700, color: 'var(--ink)', letterSpacing: '.3px' }}>雀神熊教練</span>
            <span style={{ fontSize: 9, fontWeight: 700, color: 'var(--brand)', background: 'var(--ink)', borderRadius: 'var(--r-pill)', padding: '2px 8px', letterSpacing: '.5px', marginLeft: 'auto' }}>✦ AI 即時分析</span>
          </div>
          <p style={{ margin: 0, fontSize: 'var(--xs)', color: 'var(--gray-1)', lineHeight: 1.65 }}>「婷，AI 幫妳看完最近 5 局了。妳<b style={{ color: 'var(--accent)' }}>放槍偏多</b>、集中在局末，下次局末聽牌不夠大就打安全牌。其他都很穩，<b style={{ color: 'var(--accent)' }}>50/20</b> 是妳的主場。」</p>
        </div>
      </div>
      {/* KPI 2×2（比照簡報：標籤上、數字下、大格） */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2,1fr)', gap: 10, padding: '14px 20px 0' }}>
        {KPI.map(([k, v]) => (
          <div key={k} style={{ background: 'var(--field-bg)', border: '1.5px solid var(--field-bd)', borderRadius: 'var(--r-card)', padding: '13px 16px' }}>
            <div style={{ fontSize: 11, color: 'var(--gray-1)' }}>{k}</div>
            <div style={{ fontSize: 24, fontWeight: 700, color: 'var(--ink)', marginTop: 3 }}>{v}</div>
          </div>
        ))}
      </div>
      {/* 各積分級距勝率 */}
      <div style={{ padding: '18px 20px 8px' }}>
        <p style={{ margin: 0, fontSize: 'var(--m)', fontWeight: 700, color: 'var(--ink)' }}>各積分級距勝率</p>
      </div>
      <div style={{ padding: '0 20px' }}>
        {[['50/20', 58, 12], ['30/10', 44, 8], ['純娛樂', 67, 5]].map(([lv, pct, n], i, arr) => (
          <div key={lv} style={{ padding: '11px 0', borderBottom: i === arr.length - 1 ? 'none' : '.5px solid var(--gray-4)' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: 7 }}>
              <span style={{ fontSize: 'var(--s)', fontWeight: 700, color: 'var(--ink)' }}>{lv}</span>
              <span style={{ fontSize: 'var(--xs)', color: 'var(--gray-2)' }}><b style={{ color: 'var(--accent)', fontSize: 'var(--m)' }}>{pct}%</b> · {n} 場</span>
            </div>
            <div style={{ height: 7, background: 'var(--gray-4)', borderRadius: 'var(--r-pill)' }}><div style={{ width: pct + '%', height: 7, background: 'var(--accent)', borderRadius: 'var(--r-pill)' }} /></div>
          </div>
        ))}
      </div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', padding: '18px 20px 6px' }}>
        <span style={{ fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>牌局紀錄</span>
        <span onClick={() => setView('recordsPage')} style={{ fontSize: 'var(--s)', color: 'var(--accent)', fontWeight: 700, cursor: 'pointer' }}>全部 ›</span>
      </div>
      <div style={{ padding: '0 20px 16px' }}>
        {DEMO_MATCHES.slice(0, 3).map((m, i, arr) => <Row key={m.id} m={m} last={i === arr.length - 1} />)}
      </div>
      {/* 名人堂 · 時間軸 */}
      <div style={{ padding: '14px 20px 6px' }}>
        <span style={{ fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>本季全國排行榜</span>
      </div>
      <div style={{ padding: '0 20px 20px' }}>
        {/* 衛冕卡：頂部橫幅本季冠軍 */}
        <div onClick={() => setHallCard({ ini: '阿芳', av: '芳', rank: '雀神熊', rel: 'stranger', tog: 0, win: 0 })} style={{ cursor: 'pointer', background: 'var(--brand)', borderRadius: 'var(--r-card)', position: 'relative', padding: 15, marginBottom: 18 }}>
          <div style={{ position: 'absolute', top: 0, right: 18, background: 'var(--ink)', color: 'var(--brand)', fontWeight: 700, padding: '8px 12px 15px', display: 'inline-flex', flexDirection: 'column', alignItems: 'center', boxShadow: '0 2px 5px rgba(0,0,0,.15)', clipPath: 'polygon(0 0, 100% 0, 100% 100%, 50% 82%, 0 100%)' }}>
            <span style={{ fontSize: 16, fontWeight: 800, lineHeight: 1, color: 'var(--brand)' }}>#1</span>
            <span style={{ fontSize: 10, marginTop: 3, color: 'var(--brand)' }}>目前排行</span>
          </div>
          <div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 13, marginBottom: 14, paddingRight: 64 }}>
              <DefaultAvatar size={54} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <span style={{ display: 'inline-block', fontSize: 12, fontWeight: 700, color: 'var(--ink)', marginBottom: 4 }}>「雀神 · 2025秋」</span>
                <p style={{ margin: 0, fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>阿芳</p>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginTop: 6, flexWrap: 'wrap' }}>
                  <span style={{ display: 'inline-flex', alignItems: 'center', height: 20, fontSize: 11, fontWeight: 700, color: 'var(--ink)', background: 'rgba(255,255,255,0.7)', borderRadius: 'var(--r-pill)', padding: '0 10px' }}>段位: 雀神熊</span>
                </div>
              </div>
            </div>
            <div style={{ display: 'flex', background: 'rgba(255,255,255,0.55)', borderRadius: 'var(--r-field)', padding: '12px 0' }}>
              {[['286', '打了幾場'], ['62%', '勝率'], ['48,200', '總積分']].map(([n, l]) => (
                <div key={l} style={{ flex: 1, textAlign: 'center' }}>
                  <p style={{ margin: 0, fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>{n}</p>
                  <p style={{ margin: '3px 0 0', fontSize: 'var(--xs)', color: 'var(--gray-1)' }}>{l}</p>
                </div>
              ))}
            </div>
          </div>
        </div>
        {/* #2 #3 扁卡 */}
        {[['胡', '胡蝶', 2, '雀神熊', '46,800'], ['槓', '槓上花', 3, '大師熊 II', '44,200']].map(([av, ini, rk, rank, pts]) => (
          <div key={ini} onClick={() => setHallCard({ ini, av, rank, rel: 'stranger', tog: 0, win: 0 })} style={{ cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 12, background: 'var(--field-bg)', borderRadius: 'var(--r-field)', padding: '10px 13px', marginBottom: 10 }}>
            <span style={{ fontSize: 15, fontWeight: 800, color: 'var(--gray-2)', flex: '0 0 22px' }}>#{rk}</span>
            <DefaultAvatar size={38} />
            <div style={{ flex: 1, minWidth: 0 }}>
              <p style={{ margin: 0, fontSize: 'var(--s)', fontWeight: 700, color: 'var(--ink)' }}>{ini}</p>
              <p style={{ margin: '2px 0 0', fontSize: 11, color: 'var(--gray-1)' }}>{rank}</p>
            </div>
            <div style={{ textAlign: 'right', flex: '0 0 auto' }}><div style={{ fontSize: 'var(--s)', fontWeight: 700, color: 'var(--ink)' }}>{pts}</div><div style={{ fontSize: 10, color: 'var(--gray-2)', marginTop: 1 }}>總積分</div></div>
            <span style={{ color: 'var(--gray-2)', fontSize: 18, flex: '0 0 auto', marginLeft: 2 }}>{'\u203A'}</span>
          </div>
        ))}
        {/* 名人堂大標 + 歷代時間軸 */}
        <p style={{ margin: '22px 0 14px', fontSize: 'var(--l)', fontWeight: 700, color: 'var(--ink)' }}>名人堂</p>
        <p style={{ margin: '0 0 14px', fontSize: 'var(--xs)', fontWeight: 700, color: 'var(--gray-2)' }}>歷代雀神熊</p>
        <div style={{ position: 'relative', paddingLeft: 26 }}>
          <div style={{ position: 'absolute', left: 8, top: 6, bottom: 6, width: 2, background: 'var(--milktea)' }} />
          {[
            { av: '芳', ini: '阿芳', season: '2025 秋季賽 · 進行中', title: '雀神 · 2025秋', rank: '雀神熊', pts: '48,200', now: 1 },
            { av: '胡', ini: '胡蝶', season: '2025 春季賽', title: '雀神 · 2025春', rank: '大師熊 II', pts: '46,800', now: 0 },
            { av: '槓', ini: '槓上花', season: '2024 冬季賽', title: '雀神 · 2024冬', rank: '鑽石熊 I', pts: '44,200', now: 0 },
            { av: '聽', ini: '聽心妤', season: '2024 秋季賽', title: '雀神 · 2024秋', rank: '白金熊 III', pts: '41,500', now: 0 },
            { av: '莊', ini: '莊家寶', season: '2024 夏季賽', title: '雀神 · 2024夏', rank: '白金熊 I', pts: '39,800', now: 0 },
          ].map((h, idx, arr) => (
            <div key={h.ini} style={{ position: 'relative', paddingBottom: idx === arr.length - 1 ? 0 : 16 }}>
              <span style={{ position: 'absolute', left: -22, top: 14, width: 11, height: 11, borderRadius: '50%', background: h.now ? 'var(--accent)' : 'var(--brand)', border: '2px solid var(--white)' }} />
              <p style={{ margin: '0 0 6px', fontSize: 11, fontWeight: 700, color: 'var(--gray-2)' }}>{h.season}</p>
              <div onClick={() => setHallCard({ ini: h.ini, av: h.av, rank: h.rank, rel: 'stranger', tog: 0, win: 0 })} style={{ display: 'flex', alignItems: 'center', gap: 11, background: h.now ? 'var(--brand-light)' : 'var(--field-bg)', border: h.now ? '1.5px solid var(--accent)' : '1.5px solid transparent', borderRadius: 'var(--r-field)', padding: '11px 12px', cursor: 'pointer' }}>
                <DefaultAvatar size={42} />
                <div>
                  <p style={{ margin: 0, fontSize: 'var(--s)', fontWeight: 700, color: 'var(--ink)' }}>{h.ini}</p>
                  <div style={{ marginTop: 4 }}><span style={{ display: 'inline-flex', alignItems: 'center', height: 19, fontSize: 10, fontWeight: 700, color: 'var(--brand)', background: 'var(--ink)', border: '1px solid var(--gold)', borderRadius: 'var(--r-pill)', padding: '0 9px' }}>{h.title}</span></div>
                </div>
                <div style={{ marginLeft: 'auto', textAlign: 'right', flex: '0 0 auto' }}><div style={{ fontSize: 'var(--s)', fontWeight: 700, color: 'var(--ink)' }}>{h.pts}</div><div style={{ fontSize: 10, color: 'var(--gray-2)', marginTop: 1 }}>總積分</div></div>
                <span style={{ color: 'var(--gray-2)', fontSize: 18, flex: '0 0 auto', marginLeft: 2 }}>{'\u203A'}</span>
              </div>
            </div>
          ))}
        </div>
      </div>
      {hallCard && <ProfileCardOther b={hallCard} onClose={() => setHallCard(null)} />}
      {reviewSheet}
    </>
  )
}

function SeasonInfoSheet({ onClose }) {
  const rows = [
    ['賽季制', '段位每季重新計算，把握時間往上爬'],
    ['季末結算', '賽季結束時段位降 3 階，重新開始'],
    ['榮譽保留', '你的生涯最高永遠記錄在卡上，不會抹去'],
    ['雀神熊', '每季榜首獲頒雀神熊 · 進名人堂'],
  ]
  return createPortal(
    <div className="ov-anim" onClick={(e) => { if (e.target === e.currentTarget) onClose() }} style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: 'rgba(46,43,44,0.5)', display: 'flex', alignItems: 'flex-end', zIndex: 1000 }}>
      <div className="sheet-anim" style={{ background: 'var(--white)', borderRadius: '22px 22px 0 0', width: '100%', padding: '8px 20px 24px' }}>
        <div style={{ width: 38, height: 4, borderRadius: 'var(--r-pill)', background: 'var(--gray-3)', margin: '0 auto 14px' }} />
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
          <span style={{ fontSize: 17, fontWeight: 700, color: 'var(--ink)' }}>2026 春季賽</span>
          <button onClick={onClose} style={{ background: 'none', border: 'none', fontSize: 22, color: 'var(--gray-2)', cursor: 'pointer' }}>×</button>
        </div>
        <p style={{ margin: '2px 0 14px', fontSize: 12, color: 'var(--gray-2)' }}>本季還有 23 天 · 6/30 結算</p>
        {rows.map(([k, v], i) => (
          <div key={k} style={{ display: 'flex', gap: 12, padding: '11px 0', borderBottom: i === rows.length - 1 ? 'none' : '.5px solid var(--gray-4)', fontSize: 13, color: 'var(--gray-1)' }}>
            <b style={{ color: 'var(--ink)', flex: '0 0 64px' }}>{k}</b><span>{v}</span>
          </div>
        ))}
      </div>
    </div>, document.body)
}

function MatchRecordsPage({ onBack, onOpen, initFilter = 'all' }) {
  const [kf, setKf] = useState(initFilter)   // all | match | package
  const list = DEMO_MATCHES.filter((m) => kf === 'all' ? true : (m.kind || 'match') === kf)
  return createPortal(
    <div className="sheet-anim" style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: 'var(--white)', zIndex: 1000, display: 'flex', flexDirection: 'column' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '16px 16px 12px', borderBottom: '.5px solid var(--gray-4)' }}>
        <button onClick={onBack} style={{ background: 'none', border: 'none', fontSize: 22, color: 'var(--ink)', cursor: 'pointer', padding: '0 4px' }}>‹</button>
        <span style={{ fontSize: 17, fontWeight: 700, color: 'var(--ink)' }}>牌局紀錄</span>
      </div>
      {/* 配桌/包桌 pill 篩選（比照錢包明細）*/}
      <div style={{ display: 'flex', gap: 8, padding: '12px 20px 4px' }}>
        {[['all', '全部'], ['match', '配桌'], ['package', '包桌']].map(([k, label]) => (
          <span key={k} onClick={() => setKf(k)} style={{ border: kf === k ? '1px solid var(--brand)' : '1px solid var(--gray-3)', background: kf === k ? 'var(--brand)' : 'var(--white)', color: kf === k ? 'var(--ink)' : 'var(--gray-1)', fontWeight: kf === k ? 600 : 400, borderRadius: 'var(--r-pill)', padding: '6px 16px', fontSize: 13, cursor: 'pointer' }}>{label}</span>
        ))}
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '8px 20px 20px' }}>
        {list.length === 0 && <p style={{ textAlign: 'center', color: 'var(--gray-2)', fontSize: 13, padding: '30px 0' }}>還沒有這類紀錄</p>}
        {list.map((m, i, arr) => (
          <MatchRow key={m.id} m={m} last={i === arr.length - 1} onOpen={onOpen} />
        ))}
      </div>
    </div>, document.body)
}

function MatchDetail({ m, onBack }) {
  const tiles = (arr) => arr.map((t, i) => <MahjongTile key={i} t={t.t} w={22} cur={!!t.cur} />)
  return (
    <div style={{ position: 'fixed', inset: 0, maxWidth: 480, margin: '0 auto', background: 'var(--white)', zIndex: 30, display: 'flex', flexDirection: 'column' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '16px 16px 12px', borderBottom: '.5px solid var(--gray-4)' }}>
        <button onClick={onBack} style={{ background: 'none', border: 'none', fontSize: 22, color: 'var(--ink)', cursor: 'pointer', padding: '0 4px' }}>‹</button>
        <span style={{ fontSize: 17, fontWeight: 700, color: 'var(--ink)' }}>對戰詳細</span>
      </div>
      <div style={{ flex: 1, overflowY: 'auto' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '12px 18px', background: 'var(--field-bg)' }}>
          <p style={{ margin: 0, fontSize: 13, color: 'var(--ink)' }}><b style={{ fontWeight: 700 }}>結果:</b> 妳 第 {m.rank} 名 · {m.self}</p>
          <span style={{ background: m.amt > 0 ? 'var(--brand)' : 'var(--field-bg)', color: m.amt > 0 ? 'var(--accent)' : 'var(--gray-2)', borderRadius: 'var(--r-pill)', padding: '3px 10px', fontSize: 11, fontWeight: 700 }}>{m.amt > 0 ? '+' : ''}{m.amt}</span>
        </div>
        <div style={{ padding: '10px 18px 0', fontSize: 11, color: 'var(--gray-1)' }}>{m.time} · {m.store} · {m.stake}</div>
        <div style={{ padding: '12px 18px 0' }}>
          <p style={{ margin: '0 0 8px', fontSize: 13, fontWeight: 700, color: 'var(--ink)' }}>逐手重播 · 各家打牌序</p>
          <div className="prow2"><span className="seat">東 妳</span><div className="tiles">{tiles([{ t: '中', c: '#8A3A3E' }, { t: '1萬' }, { t: '東', c: '#1A4E8A' }, { t: '9索', c: '#1A6E5A' }, { t: '8萬' }])}</div></div>
          <div className="prow2"><span className="seat">南 美美</span><div className="tiles">{tiles([{ t: '北', c: '#1A4E8A' }, { t: '2索', c: '#1A6E5A' }, { t: '白', c: '#8A3A3E' }, { t: '7筒', c: 'var(--accent)' }])}</div></div>
          <div className="prow2"><span className="seat">西 小美</span><div className="tiles">{tiles([{ t: '9萬' }, { t: '西', c: '#1A4E8A' }, { t: '4索', c: '#1A6E5A' }, { t: '5筒', cur: true }])}</div></div>
          <div className="prow2"><span className="seat">北 阿芳</span><div className="tiles">{tiles([{ t: '發', c: '#8A3A3E' }, { t: '3萬' }, { t: '6索', c: '#1A6E5A' }])}</div></div>
          <p style={{ margin: '8px 0 0', fontSize: 10, color: 'var(--gray-2)' }}>第 23 / 68 手 · 西家 小美 打出 5筒</p>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '12px 16px' }}>
          <span className="pbbtn">◀ 上一手</span>
          <div style={{ flex: 1, height: 5, background: 'var(--gray-4)', borderRadius: 'var(--r-pill)' }}><div style={{ width: '34%', height: 5, background: 'var(--accent)', borderRadius: 'var(--r-pill)' }} /></div>
          <span className="pbbtn">下一手 ▶</span>
        </div>
        <div style={{ padding: '0 18px 18px' }}>
          <p style={{ margin: '0 0 6px', fontSize: 13, fontWeight: 700, color: 'var(--ink)' }}>本局重點</p>
          <div style={{ fontSize: 12, color: 'var(--gray-1)', lineHeight: 1.8 }}>· 第 6 輪碰 7 筒，加速聽牌<br />· 第 12 輪轉聽，放掉危險的 3 萬<br />· {m.self} 結束本局</div>
        </div>
      </div>
    </div>
  )
}

// 場地分類：麻將館（直營/加盟/合作）vs 自家場（C2C）
const storeCat = (t) => t === '自家場' ? '自家場' : '麻將館'

export { Stats };
