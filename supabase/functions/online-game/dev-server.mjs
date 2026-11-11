/* 本機模擬後端：給會員 App 的牌桌畫面接著測（2026-11-11）
   用法：node supabase/functions/online-game/dev-server.mjs        （預設 http://localhost:8787）
   · 跑的是**同一份** core.mjs（流程）與 engine.mjs（規則）；只有資料庫換成記憶體裡的假資料庫（testkit.mjs）
   · 你是 m1，另外三家（m2～m4）由機器人出牌 —— 它們跟你一樣只拿得到自己那一份畫面
   · 不碰 Supabase、不用登入、不寫任何真的資料；關掉就什麼都沒了
   · App 這邊：本機開發時在瀏覽器主控台打
       localStorage.setItem('migi_online_dev', 'http://localhost:8787')
     lib/online.js 就會改打這裡（正式打包沒有這段，見那支的說明）

   POST /            同 Edge Function：{ op: 'view' | 'act' | 'tick' | 'next' | 'bust', … }；標頭 x-dev-member 可以換成 m2～m4
   POST /reset       重開一場：{ planned: 1～3, flower: true/false, start: 起始積分, bots: true/false, speed: 機器人想多久的倍數,
                                 botBust: 機器人爆卡時追加多少（0 ＝ 結束整場） }
                     要快點看到爆卡與整場結算：start 給 100 */
import http from 'node:http'
import { handle } from './core.mjs'
import { fakeDb, botAction, CAT } from './testkit.mjs'

/* 測試副本的牌型名稱就是代碼；這裡換成主檔的中文名（正式後端回的就是這些），畫面才看得出真的樣子 */
const ZH = { zimo: '自摸', triplet_wind: '東南西北', triplet_dragon: '中發白', duting: '邊張單吊中洞', qianggang: '搶槓', menqing: '門清', gangshang: '槓上開花',
  haidi: '海底撈月', pinghu: '平胡', menqing_tsumo: '門清一摸三', quanqiuren: '全求', pengpenghu: '碰碰胡', sananke: '三暗刻', sianke: '四暗刻', wuanke: '五暗刻',
  xiaosanyuan: '小三元', dasanyuan: '大三元', xiaosixi: '小四喜', dasixi: '大四喜', hunyise: '混一色', qingyise: '清一色', ziyise: '字一色', zhenghua: '正花', huagang: '花槓',
  qiqiangyi: '七搶一', baxian: '八仙過海', quanhong: '全紅', shaigui: '骰龜', baozi: '豹子', tianhu: '天胡', migi: 'MIGI' }
CAT.forEach((p) => { p.label = ZH[p.code] || p.code })

const PORT = Number(process.env.PORT || 8787)
const NAMES = { m1: ['咖勁凱', '新手村制霸', '金牌熊 II'], m2: ['佳佳', '自摸達人', '鑽石熊 I'], m3: ['阿哲', '新手上路', '白金熊 III'], m4: ['小美', '海底撈月', '銀牌熊 I'] }
/* 三家機器人的小熊各穿各的（同預覽定稿那三套），看得出牌桌上的小熊會照每個人的穿搭畫 */
const OUTFITS = { m2: { head: 'antler', hair: 'star', feet: 'socks' }, m3: { head: 'beanie', neck: 'scarf' }, m4: { hair: 'sakura', hand: 'mug' } }
let W, cfg
function reset(o = {}) {
  cfg = { planned: 1, flower: true, start: 2000, bots: true, speed: 1, botBust: 0, ...o }
  W = fakeDb({ planned: cfg.planned, flower: cfg.flower, start: cfg.start, clock: () => new Date().toISOString() })
  W.D.players.forEach((p) => { const [nickname, title, rank] = NAMES[p.member_id]; Object.assign(p, { nickname, title, rank, avatar_source: 'bear', avatar_bear: null, outfit: OUTFITS[p.member_id] || {} }) })
  console.log('🀄 新的一場：約 ' + cfg.planned + ' 將、' + (cfg.flower ? '有花' : '無花') + '、起始 ' + cfg.start)
}
reset()

const me = (m) => ({ member_id: m, session_id: 's1' })
const rand = Math.random

/* 機器人：每 300 毫秒看一次自己的畫面，有事要做就「想一下」再做（出牌 0.9～1.9 秒、要不要叫牌 0.5～1.2 秒） */
const due = {}
let busy = false
setInterval(async () => {
  if (busy || !cfg.bots) return
  busy = true
  try {
    for (const m of ['m2', 'm3', 'm4']) {
      const v = await handle(W.db, me(m), { op: 'view' }, Date.now(), rand)
      // 機器人爆卡：照設定追加積分或結束整場（botBust：0 ＝ 結束，預設；其他數字 ＝ 追加那麼多）
      if (v.stage === 'bust' && v.bust && v.bust.seat === v.me.seat) {
        if (!due[m] || due[m].key !== 'bust') { due[m] = { key: 'bust', at: Date.now() + 2500 }; continue }
        if (Date.now() < due[m].at) continue
        delete due[m]
        await handle(W.db, me(m), { op: 'bust', amount: Number(cfg.botBust) || 0 }, Date.now(), rand)
        console.log('機器人 ' + m + ' 爆卡：' + (Number(cfg.botBust) ? '追加 ' + cfg.botBust : '結束整場'))
        continue
      }
      const a = v.stage === 'playing' ? botAction(v, rand) : null
      const key = m + ':' + (v.hand ? v.hand.id + ':' + v.hand.version : '')
      if (!a) { delete due[m]; continue }
      if (!due[m] || due[m].key !== key) { due[m] = { key, at: Date.now() + (v.table.options.claim ? 500 + rand() * 700 : 900 + rand() * 1000) * cfg.speed }; continue }
      if (Date.now() < due[m].at) continue
      delete due[m]
      const r = await handle(W.db, me(m), { op: 'act', version: v.hand.version, action: a }, Date.now(), rand)
      if (!r.ok && r.reason !== 'stale') console.log('機器人 ' + m + ' 的動作被拒絕：', r.reason, JSON.stringify(a))
    }
  } catch (e) { console.error('機器人出錯', e) } finally { busy = false }
}, 300)

const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-dev-member', 'Access-Control-Allow-Methods': 'POST, OPTIONS' }
http.createServer(async (req, res) => {
  const send = (code, body) => { res.writeHead(code, { ...CORS, 'Content-Type': 'application/json' }); res.end(body == null ? '' : JSON.stringify(body)) }
  if (req.method === 'OPTIONS') return send(204, null)
  if (req.method !== 'POST') return send(405, { ok: false, reason: 'method_not_allowed' })
  let raw = ''
  for await (const c of req) raw += c
  let body = {}
  try { body = raw ? JSON.parse(raw) : {} } catch { body = {} }
  try {
    if (req.url.startsWith('/reset')) { reset(body); return send(200, { ok: true, cfg }) }
    const m = NAMES[req.headers['x-dev-member']] ? req.headers['x-dev-member'] : 'm1'
    const out = await handle(W.db, me(m), body, Date.now(), rand)
    if (body.op === 'act') console.log(m, JSON.stringify(body.action), out.ok ? '✓' : '✗ ' + out.reason)
    send(200, out)
  } catch (e) {
    console.error(e)
    send(500, { ok: false, reason: 'server_error', message: String(e && e.message) })
  }
}).listen(PORT, () => console.log('本機模擬後端：http://localhost:' + PORT + '（你是 m1，m2～m4 是機器人）'))
