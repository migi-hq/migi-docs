/* 把 engine.mjs ＋ core.mjs ＋ index.ts 合併成一個檔案，給 Supabase Dashboard 貼上用。
   用法：node supabase/functions/online-game/build.mjs
   產出：supabase/functions/online-game/部署用_整支貼上.ts（🔴 產生出來的，不要手改；改了那三支之後重跑這一支）

   為什麼要合併：這個專案的 Edge Function 一律是在 Dashboard「新增 → 貼上 → Deploy」，其他幾支都只有一個檔案。
   這一支拆成三個是為了能各自測試（engine.test.mjs、core.test.mjs），部署時合回一個，才不用在 Dashboard 一個一個加檔案。
   做法：引擎與流程各包在一個立即執行的函式裡（裡面的名字互相看不到，不會撞名），只把需要的幾支交出來。 */
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const dir = dirname(fileURLToPath(import.meta.url))
const read = (f) => readFileSync(join(dir, f), 'utf8').replace(/\r\n/g, '\n')
const noExport = (s) => s.replace(/^export (function|const|async function)/gm, '$1')
const noImport = (s) => s.replace(/^(\/\/ @ts-ignore[^\n]*\n)?import [^\n]*\n/gm, '')
const indent = (s) => s.split('\n').map((l) => (l ? '  ' + l : l)).join('\n')

const engine = noExport(read('engine.mjs'))
const core = noExport(noImport(read('core.mjs')))
const index = noImport(read('index.ts'))

// index.ts 最前面那一大段說明留在最上面，其餘接在引擎與流程後面
const headEnd = index.indexOf('*/') + 2
const head = index.slice(0, headEnd), body = index.slice(headEnd)

/* 流程（core.mjs）向引擎拿哪幾支函式：**直接從 core.mjs 自己的 import 那一行讀**，不在這裡另外列一份。
   🔴 2026-11-11 踩到：這裡原本寫死四個名字，core.mjs 後來多用了一支 botMove（電腦的牌理）而這裡沒跟上 ——
     合出來的檔案裡 botMove 在流程那一段是「沒有這個東西」，被流程自己的保險接住、退回最笨的打法，而且**沒有任何錯誤訊息**。
     測試全部都是跑分開的三支檔案，所以也測不到。下面另外有一道檢查：合完之後真的把檔案載起來，確認每一支都拿得到 */
const fromEngine = (read('core.mjs').match(/^import \{([^}]+)\} from '\.\/engine\.mjs'/m) || [])[1]
if (!fromEngine) throw new Error('build.mjs：在 core.mjs 找不到「import { … } from ./engine.mjs」那一行')
const engineNames = fromEngine.split(',').map((x) => x.trim()).filter(Boolean)
for (const nm of engineNames) {
  if (!new RegExp('^(function|const|async function) ' + nm + '\\b', 'm').test(engine)) throw new Error('build.mjs：engine.mjs 裡沒有 ' + nm)
}

const out = `// @ts-nocheck
/* 🔴 這個檔案是產生出來的（node supabase/functions/online-game/build.mjs），不要手改。
   它是 engine.mjs ＋ core.mjs ＋ index.ts 三支合起來的樣子，只用來貼進 Supabase Dashboard。
   要改東西請改那三支，跑測試，再重跑 build.mjs。 */
${head}

/* ═══════════ 牌局規則（engine.mjs）═══════════ */
const ENGINE = (() => {
${indent(engine)}
  return { ${engineNames.join(', ')} }
})()

/* ═══════════ 流程（core.mjs）═══════════ */
const CORE = (() => {
  const { ${engineNames.join(', ')} } = ENGINE
${indent(core)}
  return { handle }
})()
const { handle } = CORE

/* ═══════════ 入口（index.ts）═══════════ */
${body.replace(/^\n+/, '')}`

const target = join(dir, '部署用_整支貼上.ts')
writeFileSync(target, out, 'utf8')
console.log('✅ 已產生 ' + target + '（' + out.split('\n').length + ' 行）')

/* ── 合完之後真的載起來跑一小段（2026-11-11 加）──
   測試（engine.test.mjs、core.test.mjs）跑的是分開的三支檔案，合併這一步自己出的錯它們看不到。
   這裡把合好的「規則＋流程」那兩段載進來，讓一個真人加三個電腦打一下：
   電腦有用到牌理的話一定會吃碰槓；退回「摸什麼打什麼」的話永遠不會 ⇒ 沒看到就整支失敗，不要讓一份壞的部署檔被貼上去 */
{
  const { pathToFileURL } = await import('node:url')
  const { unlinkSync } = await import('node:fs')
  const from = out.indexOf('/* ═══════════ 牌局規則（engine.mjs）═══════════ */'), to = out.indexOf('/* ═══════════ 入口（index.ts）═══════════ */')
  if (from < 0 || to < 0) throw new Error('build.mjs：合好的檔案裡找不到分段的記號')
  const probe = join(dir, '.build-probe.mjs')
  writeFileSync(probe, out.slice(from, to) + '\nexport { handle }\n', 'utf8')
  try {
    const merged = await import(pathToFileURL(probe).href + '?t=' + Date.now())
    const { fakeDb } = await import('./testkit.mjs')
    const { db, D } = fakeDb({ start: 200000, bots: 3 })
    let seedR = 42
    const rand = () => { seedR = (seedR * 1103515245 + 12345) & 0x7fffffff; return seedR / 0x7fffffff }
    const me = { member_id: 'm1', session_id: 's1' }
    let now = 1_000_000, called = false
    for (let i = 0; i < 4000 && !called; i++) {
      const v = await merged.handle(db, me, { op: 'view' }, now, rand)
      if (v.stage === 'game_over' || v.stage === 'round_over') break
      if (v.stage === 'hand_over') await merged.handle(db, me, { op: 'next' }, now, rand)
      else if (v.stage === 'playing' && v.table && v.table.options) {
        const o = v.table.options
        const a = o.claim ? { type: 'pass' } : o.discard ? { type: 'discard', tile: v.table.drawn || v.table.players[v.table.seat].hand.slice(-1)[0] } : o.baozi ? { type: 'baozi', mult: 1 } : null
        if (a) await merged.handle(db, me, { op: 'act', version: v.hand.version, action: a }, now, rand)
      }
      const bots = D.players.filter((p) => p.is_bot).map((p) => p.seat)
      called = D.actions.some((x) => bots.includes(x.seat) && ['pong', 'chi', 'kong', 'hu', 'tsumo'].includes(x.action.type))
      now += 700
    }
    if (!called) throw new Error('build.mjs：合好的檔案裡電腦沒有用到牌理（一次吃碰槓胡都沒有）—— 多半是流程拿不到引擎的某一支函式')
    console.log('✅ 合好的檔案載得起來，電腦有用到牌理（看到吃碰槓或胡）')
  } finally {
    try { unlinkSync(probe) } catch (e) { /* 留著也只是一個暫存檔 */ }
  }
}
