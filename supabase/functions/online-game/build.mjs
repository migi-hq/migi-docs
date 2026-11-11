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

const out = `// @ts-nocheck
/* 🔴 這個檔案是產生出來的（node supabase/functions/online-game/build.mjs），不要手改。
   它是 engine.mjs ＋ core.mjs ＋ index.ts 三支合起來的樣子，只用來貼進 Supabase Dashboard。
   要改東西請改那三支，跑測試，再重跑 build.mjs。 */
${head}

/* ═══════════ 牌局規則（engine.mjs）═══════════ */
const ENGINE = (() => {
${indent(engine)}
  return { newGame, act, viewFor, autoAction }
})()

/* ═══════════ 流程（core.mjs）═══════════ */
const CORE = (() => {
  const { newGame, act, viewFor, autoAction } = ENGINE
${indent(core)}
  return { handle }
})()
const { handle } = CORE

/* ═══════════ 入口（index.ts）═══════════ */
${body.replace(/^\n+/, '')}`

const target = join(dir, '部署用_整支貼上.ts')
writeFileSync(target, out, 'utf8')
console.log('✅ 已產生 ' + target + '（' + out.split('\n').length + ' 行）')
