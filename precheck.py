# -*- coding: utf-8 -*-
"""
push 之前的自動檢查 —— 由各 repo 的 `.git/hooks/pre-push` 呼叫。

════════════════════════════════════════════════════════════
🔴 這支存在的理由（2026-09-09 使用者指出）
    在此之前，這個專案**沒有任何一件事會自己發生**：
        git hook   migi-web 0 · migi-pos 0 · migi-admin 0
        CI 設定檔  0
    每一個檢查都掛在「Claude 記得要做」上面，而 CLAUDE.md 已經是
    兩千多行的「記得要做 X」。**那條路的天花板已經撞到很多次**
    （硬規則 3.5 犯過四次、1.8 是當天寫完規則又踩）。

🎯 所以這支的工作不是「多一個檢查」，是**把記性換成機制**。
    判準：一個檢查如果需要有人記得跑它，它遲早等於不存在。
════════════════════════════════════════════════════════════

用法：python precheck.py <repo 的絕對路徑>
離開碼：0 = 可以推　1 = 擋下

────────────────────────────────────────────────────────────
🔴 五項檢查**性質不同，不可以一律當閘門**（這是設計，不是偷懶）

  ① npm run build          ✅ 閘門　成敗明確
  ② jsxcomment.py          ✅ 閘門　有命中就 exit 1
  ③ jsxcomment2.py         ✅ 閘門　同上
  ④ tokencheck.py          ⚠ **棘輪**，不是閘門　見下
  ⑤ tests/pure.test.mjs    ✅ 閘門　零相依，node 直接跑（沒有這個檔就跳過）
  ⑥ 兩份 discount.js 一致  ✅ 閘門　跨 repo，擋「漂」不是擋「錯」
  ⑦ pillcheck.py           ⚪ **只印給人看**，永遠不擋　見下

  🎯 ⑤ 與 ⑥ 是**兩種不同的保護，缺一不可**：
    2026-09-08 的 9.5 折是**兩個 repo 同時錯** ⇒ 兩邊各自的測試都會過，
    只有「兩份必須一樣」擋得住**只改一邊**；
    而「兩份一樣但一起錯」只有測試擋得住。

  ④ 為什麼不能直接當閘門：實測今天三個 repo 分別是 32 / 11 / 5 處寫死值，
    而它只要有一處就 exit 1 ⇒ **每一次 push 都會被擋**。
    而 CLAUDE.md 硬規則 13 明寫「遷移舊的寫死值是固定利息，可以慢慢來；
    **新寫的程式碼繼續寫死才是複利**」。
    ⇒ 正確的形狀是**棘輪**：只擋「變多」，變少就自動把基準線往下鎖，
      讓它回不去。這樣既不擋住今天的 push，又讓債只能減不能增。
    🔴 而「自動往下鎖」是刻意的 —— 要人記得去改基準線，
      就又變成一條記性規則。

  ⑤ 為什麼永遠不擋：`pillcheck.py` **沒有 sys.exit**，它是
    「逐行印出來讓人判讀」（硬規則 3.5 刻意的設計，不回是非題）。
    把它接成閘門等於接了一個永遠通過的東西 —— 那比沒接更糟，
    因為它看起來像有檢查（硬規則 3.58）。
    ⚠ 它的 ROOT 還寫死指向 migi-web，所以也只對那一個 repo 有意義。
────────────────────────────────────────────────────────────
"""
import json
import os
import subprocess
import sys

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, 'docs', '_資產')
BASELINE = os.path.join(HERE, 'precheck-baseline.json')

# 🔴 子行程也要 UTF-8：Windows 主控台預設 cp950，
#   而檢查器印中文與 emoji。少了這一行，它們會在「找到問題正要印出來」
#   的那一刻拋 UnicodeEncodeError —— 對的結果配上錯的原因。
ENV = dict(os.environ, PYTHONIOENCODING='utf-8')


def run(cmd, cwd=None, shell=False):
    """跑一個指令，把輸出原樣印出來，回傳離開碼。

    ⚠ 硬規則 3.58：**不要用「找得到某個字就算成功」的過濾器**。
      一律看離開碼，而且輸出完整印出來不 grep。
    """
    p = subprocess.run(cmd, cwd=cwd, shell=shell, env=ENV,
                       capture_output=True, text=True,
                       encoding='utf-8', errors='replace')
    out = (p.stdout or '') + (p.stderr or '')
    if out.strip():
        print(out.rstrip())
    return p.returncode


def load_baseline():
    try:
        with open(BASELINE, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return {}


def save_baseline(d):
    with open(BASELINE, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(d, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write('\n')


def token_count(src):
    """跑 tokencheck 並取回「幾處」。

    🔴 解析不出來就當作失敗（fail closed）——
      解析失敗與「零處」長得一樣，而把未知當成通過正是這個專案
      一再記錄的病（硬規則 3.55）。
    """
    p = subprocess.run([sys.executable, os.path.join(HERE, 'tokencheck.py'), src],
                       capture_output=True, text=True, env=ENV,
                       encoding='utf-8', errors='replace')
    out = (p.stdout or '') + (p.stderr or '')
    if '沒有「有 token 可用卻寫死」的地方' in out:
        return 0, out
    for line in out.split('\n'):
        if '共' in line and '處可以直接換成 token' in line:
            digits = ''.join(c for c in line.split('共')[1].split('處')[0] if c.isdigit())
            if digits:
                return int(digits), out
    return None, out


def key_count(src):
    """跑 keycheck 並取回「鍵盤到不了幾處」。同樣 fail closed。"""
    p = subprocess.run([sys.executable, os.path.join(ASSETS, 'keycheck.py'), src],
                       capture_output=True, text=True, env=ENV,
                       encoding='utf-8', errors='replace')
    out = (p.stdout or '') + (p.stderr or '')
    for line in out.split('\n'):
        if '鍵盤到不了：' in line:
            digits = ''.join(c for c in line.split('鍵盤到不了：')[1].split('處')[0] if c.isdigit())
            if digits != '':
                return int(digits), out
    return None, out


def ratchet(base, key, n, out, what, howto, fails):
    """棘輪：只擋「變多」，變少就自動把基準線鎖下來。

    🔴 **不是閘門。** 這兩項今天都不是 0，直接擋會讓每一次 push 都失敗，
      而一個永遠紅的檢查會讓人學會忽略紅色（硬規則 3.5 那個症狀）。
    🔴 **「往下鎖」是自動的**：要人記得去改基準線，就又變成一條記性規則，
      而這整套東西的重點就是不要再靠記性。
    """
    prev = base.get(key)
    if n is None:
        print(out.rstrip())
        print('   🔴 讀不出數量 —— 當作失敗（不把未知當成通過）')
        fails.append('%s 解析失敗' % what)
        return False
    if prev is None:
        base[key] = n
        save_baseline(base)
        print('   📌 第一次跑，基準線設為 %d 處' % n)
    elif n > prev:
        print('   🔴 %s 從 %d 變成 %d —— 新增的部分要處理掉' % (what, prev, n))
        print('   查看：%s' % howto)
        fails.append('%s 增加（%d → %d）' % (what, prev, n))
        return False
    elif n < prev:
        base[key] = n
        save_baseline(base)
        print('   ✅ %s 從 %d 降到 %d，基準線已自動鎖下來（回不去了）' % (what, prev, n))
    else:
        print('   ✅ %s 維持 %d 處，沒有變多' % (what, n))
    return True


def main():
    if len(sys.argv) < 2:
        print('用法：python precheck.py <repo 的絕對路徑>')
        return 1
    repo = os.path.abspath(sys.argv[1])
    name = os.path.basename(repo.rstrip('\\/'))
    src = os.path.join(repo, 'src')
    fails = []

    print('=' * 62)
    print('push 前檢查：%s' % name)
    print('=' * 62)

    # ── ① build（硬規則 11：推之前先 build）────────────────────
    print('\n① npm run build')
    if run('npm run build', cwd=repo, shell=True) != 0:
        fails.append('build 失敗')
    else:
        print('   ✅ build 過了')

    # ── ②③ JSX 註解兩支 ───────────────────────────────────────
    for f, why in (('jsxcomment.py', '屬性列表位置／註解被自己關掉'),
                   ('jsxcomment2.py', '運算式位置')):
        print('\n%s %s（%s）' % ('②' if f == 'jsxcomment.py' else '③', f, why))
        if run([sys.executable, os.path.join(ASSETS, f), src]) != 0:
            fails.append(f)

    base = load_baseline()

    # ── ④ 寫死值：棘輪 ────────────────────────────────────────
    print('\n④ tokencheck.py（寫死值棘輪）')
    n, out = token_count(src)
    ratchet(base, name, n, out, '寫死值',
            'python tokencheck.py %s' % src, fails)

    # ── ⑤ 鍵盤到不了的可點元素：棘輪 ───────────────────────────
    #   🔴 這對 POS 不只是無障礙，是**收銀速度**：一個 <div onClick>
    #     Tab 到不了、Enter 按不了，店員只能用滑鼠一個一個點過去。
    #     CLAUDE.md 待辦 10 自己寫著「鍵盤操作才是這台機器的效率來源」。
    print('\n⑤ keycheck.py（鍵盤到不了的可點元素，棘輪）')
    n, out = key_count(src)
    ratchet(base, name + '-鍵盤', n, out, '鍵盤到不了',
            'python "docs/_資產/keycheck.py" %s --list' % src, fails)

    # ── ⑥ 純函式測試（零相依，node 直接跑）────────────────────
    #   🔴 只測「手抄鏡射後端」那一類，不是要測全站。
    #     判準：這段邏輯在後端也有一份，而兩份漂掉時**畫面不會報錯**。
    test = os.path.join(repo, 'tests', 'pure.test.mjs')
    if os.path.isfile(test):
        print('\n⑥ 純函式測試')
        if run('node tests/pure.test.mjs', cwd=repo, shell=True) != 0:
            fails.append('純函式測試')
    else:
        print('\n⑥ 純函式測試　⚪ 這個 repo 還沒有（%s 不存在）' % os.path.relpath(test, repo))

    # ── ⑦ 跨 repo：兩份 discount.js 不可以漂 ───────────────────
    #   🎯 這一項比測試更直接命中 2026-09-08 那個 bug ——
    #     那次**兩邊都錯**，所以兩邊各自的測試都會通過，
    #     只有「兩份必須一樣」這個檢查會在**只改一邊**時擋下來。
    #   ⚠ 它擋的是「漂」不是「錯」。兩者都要有。
    print('\n⑦ 跨 repo：兩份 discount.js 是否一致')
    a = os.path.join(HERE, 'migi-web', 'src', 'lib', 'discount.js')
    b = os.path.join(HERE, 'migi-admin', 'src', 'lib', 'discount.js')
    if not (os.path.isfile(a) and os.path.isfile(b)):
        print('   🔴 有一份不見了 —— 擋下（檔案不見不等於沒問題）')
        fails.append('discount.js 缺一份')
    else:
        def body(p):
            # 兩份唯一容許的差異是互指對方路徑的那一行
            with open(p, encoding='utf-8') as f:
                return [l.rstrip() for l in f if '逐字相同' not in l]
        if body(a) == body(b):
            print('   ✅ 兩份一致（唯一差異是互指對方路徑的註解）')
        else:
            print('   🔴 兩份漂掉了 —— 折數換算在兩個 repo 不一樣')
            print('   比對：diff migi-web/src/lib/discount.js migi-admin/src/lib/discount.js')
            fails.append('discount.js 跨 repo 不一致')

    # ── ⑧ pillcheck：只印，不擋 ───────────────────────────────
    if name == 'migi-web':
        print('\n⑦ pillcheck.py（⚪ 只印給人看，不擋 push）')
        run([sys.executable, os.path.join(ASSETS, 'pillcheck.py')])

    print('\n' + '=' * 62)
    if fails:
        print('🔴 擋下這次 push：%s' % '　'.join(fails))
        print('   真的要硬推：git push --no-verify')
        print('=' * 62)
        return 1
    print('✅ 全部通過，可以推')
    print('=' * 62)
    return 0


if __name__ == '__main__':
    sys.exit(main())
