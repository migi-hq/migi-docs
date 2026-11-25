"""計分板網頁改了畫面 → 自動在 ESP32 版的待辦記一筆（2026-11-25 建立）。

為什麼要有：ESP32 版（migi-table-esp32）的畫面是用 C 另外寫的一份，網頁版改了畫面，
ESP32 不會跟著變，而且**不會報錯**。靠「記得要同步」一定會漏（同硬規則 11.1：規則擋不住會忘的人）。
⇒ 綁在 migi-table 的 push 上（precheck.py ⑨）：每次推，把上次記到之後、改到 src/ 的提交
  逐筆寫進 migi-table-esp32/待同步.md。

· 只記錄，**永遠不擋 push**（exit 0）。要不要搬到 ESP32、怎麼搬，是人判斷的事。
· 記到哪一個提交存在 migi-table-esp32/.esp32sync_last；第一次跑只設起點，不回填。
· ESP32 版本來就沒有的功能（教學、背景皮膚、全國第一、手機專屬、預覽頁）不記，免得清單變成雜訊 ——
  那些功能哪天要做進 ESP32，把它們從 SKIP 拿掉。
· 用附加（'a'）寫待辦、記號檔先寫暫存再換名字：不會因為寫到一半中斷而把舊內容清掉。

用法：python esp32sync.py　（不用參數；precheck.py 會在推 migi-table 時叫它）
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
TABLE = os.path.join(ROOT, 'migi-table')
ESP = os.path.join(ROOT, 'migi-table-esp32')
TODO = os.path.join(ESP, '待同步.md')
MARK = os.path.join(ESP, '.esp32sync_last')

# ESP32 版沒有這些功能（見 migi-table-esp32/README.md「平板有、ESP32 版還沒有的」）
SKIP = {
    'src/preview.jsx',        # 本機預覽頁
    'src/bg.jsx',             # 背景皮膚
    'src/no1.jsx',            # 全國第一登場
    'src/phone.jsx',          # 手機配對與手機專屬畫面
    'src/lib/practice.js',    # 教學模式
    'src/lib/engine.js',      # 教學模式的計分引擎
    'src/lib/seatlock.js',    # 選位置的即時鎖
    'src/lib/wakelock.js', 'src/lib/battery.js', 'src/lib/version.js', 'src/lib/health.js',
}


def git(*args):
    r = subprocess.run(['git', '-C', TABLE, *args], capture_output=True, text=True, encoding='utf-8', errors='replace')
    return r.returncode, r.stdout.strip()


def write_mark(h):
    tmp = MARK + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(h + '\n')
    os.replace(tmp, MARK)


def main():
    print('\n⑨ ESP32 版待同步（⚪ 只記錄，不擋 push）')
    if not os.path.isdir(ESP):
        print('   ⚪ 找不到 migi-table-esp32，略過')
        return 0
    code, head = git('rev-parse', 'HEAD')
    if code:
        print('   ⚪ 讀不到 migi-table 的 git，略過')
        return 0
    if not os.path.isfile(MARK):
        write_mark(head)
        print('   ⚪ 第一次跑：從 %s 開始記（之前的不回填）' % head[:7])
        return 0
    with open(MARK, encoding='utf-8') as f:
        last = f.read().strip()
    if last == head:
        print('   ✅ 沒有新的提交')
        return 0
    # 上次記到的那個提交不在這條歷史上（例如被改寫過）⇒ 只看最近 20 筆，並在清單上講清楚
    ok, _ = git('merge-base', '--is-ancestor', last, head)
    rng = ['%s..%s' % (last, head)] if ok == 0 else ['-n', '20', head]
    code, out = git('log', '--reverse', '--date=short', '--format=%H\t%ad\t%s', *rng, '--', 'src')
    lines = []
    for row in filter(None, out.splitlines()):
        h, d, subj = (row.split('\t', 2) + ['', ''])[:3]
        _, files = git('diff-tree', '--no-commit-id', '--name-only', '-r', h, '--', 'src')
        keep = [p for p in files.splitlines() if p and p not in SKIP]
        if not keep:
            continue
        lines.append('- [ ] %s `%s` %s（改了：%s）\n' % (d, h[:7], subj, '、'.join(p.replace('src/', '') for p in keep)))
    if lines:
        with open(TODO, 'a', encoding='utf-8') as f:
            if ok != 0:
                f.write('\n> ⚠ 上次記到的提交 %s 不在目前的歷史上，下面是最近 20 筆，可能有重複\n' % last[:7])
            f.writelines(lines)
        print('   📝 計分板畫面改了 %d 筆，已記到 migi-table-esp32/待同步.md：' % len(lines))
        for l in lines:
            print('      ' + l.strip()[6:])
    else:
        print('   ✅ 這次推的提交沒有改到 ESP32 版有的畫面')
    write_mark(head)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as e:      # 記錄工具壞了也不可以擋 push，但要講出來
        print('   ⚠ esp32sync 出錯（沒有擋 push）：%s' % e)
        sys.exit(0)
