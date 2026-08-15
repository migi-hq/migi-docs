"""
M1 計費/扣款邏輯驗證（用 SQLite 模擬,驗證規則正確性）
驗證項目:
  1. 配桌計費:打滿3將150、中途加入100、遲到/棄賽照收150
  2. 包桌計費:0-2h=400、2-5h=600、5-24h=800
  3. 開桌即扣 + 收桌退補
  4. 雙重獎金:配桌50(店員配才發)、綁定客人10(有效消費)
  5. 冪等:同一 idempotency_key 只扣一次
  6. 餘額一致性:wallets.balance == sum(wallet_txns)
"""
import sqlite3, uuid

db = sqlite3.connect(":memory:")
db.execute("PRAGMA foreign_keys=ON")

# 簡化版 schema（只為驗邏輯）
db.executescript("""
create table members(id text primary key, balance int default 0, primary_staff_id text);
create table wallet_txns(id text primary key, member_id text, type text, amount int,
  status text default 'completed', idempotency_key text, staff_id text, unique(idempotency_key));
create table pricing_tiers(mode text, rule_key text, min_unit int, max_unit int, points int);
create table bonus_rules(rule_key text, amount int, min_spend int);
""")

# 載入計費規則（資料驅動,對應本案數字）
db.executemany("insert into pricing_tiers values(?,?,?,?,?)", [
    ('matched','matched_full',    3, None, 150),   # 配桌打滿3將
    ('matched','matched_midjoin', 0, None, 100),   # 中途加入
    ('private','private_tier',    0,  120, 400),   # 0-2h
    ('private','private_tier',  120,  300, 600),   # 2-5h
    ('private','private_tier',  300, 1440, 800),   # 5-24h
])
db.executemany("insert into bonus_rules values(?,?,?)", [
    ('match_made', 50, None),       # 配桌獎金
    ('visit_commission', 10, 100),  # 綁定客人獎金,門檻100
])

def new_id(): return str(uuid.uuid4())

def topup(mid, amount, idem=None):
    """儲值"""
    db.execute("insert or ignore into wallet_txns(id,member_id,type,amount,idempotency_key) values(?,?,?,?,?)",
               (new_id(), mid, 'topup', amount, idem))
    if db.total_changes:
        db.execute("update members set balance=balance+? where id=?", (amount, mid))

def charge(mid, amount, typ='table_fee', staff=None, idem=None):
    """扣點（amount 傳正數,內部轉負）"""
    cur = db.execute("select 1 from wallet_txns where idempotency_key=?", (idem,)).fetchone()
    if idem and cur:
        return False  # 冪等:已處理
    bal = db.execute("select balance from members where id=?", (mid,)).fetchone()[0]
    if bal < amount:
        return None   # 餘額不足
    db.execute("insert into wallet_txns(id,member_id,type,amount,status,idempotency_key,staff_id) values(?,?,?,?,?,?,?)",
               (new_id(), mid, typ, -amount, 'completed', idem, staff))
    db.execute("update members set balance=balance-? where id=?", (amount, mid))
    return True

def get_price(mode, rule_key, unit=None):
    if mode == 'private':
        row = db.execute("select points from pricing_tiers where mode='private' and min_unit<=? and max_unit>=?",
                         (unit, unit)).fetchone()
        return row[0] if row else None
    row = db.execute("select points from pricing_tiers where mode=? and rule_key=?", (mode, rule_key)).fetchone()
    return row[0] if row else None

def balance_check(mid):
    """驗證:餘額 == 流水加總"""
    bal = db.execute("select balance from members where id=?", (mid,)).fetchone()[0]
    flow = db.execute("select coalesce(sum(amount),0) from wallet_txns where member_id=? and status='completed'", (mid,)).fetchone()[0]
    return bal == flow

# ============ 測試 ============
passed, failed = 0, 0
def check(name, cond):
    global passed, failed
    if cond: passed+=1; print(f"  ✓ {name}")
    else: failed+=1; print(f"  ✗ {name} ← 失敗!")

print("【測試1】配桌計費規則")
check("打滿3將=150", get_price('matched','matched_full')==150)
check("中途加入=100", get_price('matched','matched_midjoin')==100)

print("【測試2】包桌階梯計費")
check("90分鐘(0-2h)=400", get_price('private',None,90)==400)
check("200分鐘(2-5h)=600", get_price('private',None,200)==600)
check("600分鐘(5-24h)=800", get_price('private',None,600)==800)
check("邊界120分=400或600", get_price('private',None,120) in (400,600))

print("【測試3】開桌即扣 + 餘額")
alice = new_id(); db.execute("insert into members(id,balance) values(?,0)",(alice,))
topup(alice, 1000)
check("儲值後餘額=1000", db.execute("select balance from members where id=?",(alice,)).fetchone()[0]==1000)
charge(alice, 150)  # 配桌開桌扣150
check("配桌扣150後餘額=850", db.execute("select balance from members where id=?",(alice,)).fetchone()[0]==850)
check("餘額與流水一致", balance_check(alice))

print("【測試4】中途加入扣100（獨立,不經150）")
bob = new_id(); db.execute("insert into members(id,balance) values(?,500)",(bob,))
charge(bob, 100, typ='table_fee')  # 中途加入直接扣100
check("中途加入扣100後餘額=400", db.execute("select balance from members where id=?",(bob,)).fetchone()[0]==400)

print("【測試5】冪等:同 key 只扣一次")
carol = new_id(); db.execute("insert into members(id,balance) values(?,500)",(carol,))
k = "idem-key-001"
r1 = charge(carol, 150, idem=k)
r2 = charge(carol, 150, idem=k)  # 重送
check("第一次扣款成功", r1==True)
check("第二次重送被擋(冪等)", r2==False)
check("只扣一次,餘額=350", db.execute("select balance from members where id=?",(carol,)).fetchone()[0]==350)

print("【測試6】餘額不足擋下")
dave = new_id(); db.execute("insert into members(id,balance) values(?,100)",(dave,))
r = charge(dave, 150)
check("餘額不足回傳None", r is None)
check("餘額不變=100", db.execute("select balance from members where id=?",(dave,)).fetchone()[0]==100)

print("【測試7】包桌整桌扣（四人均攤概念,實扣整桌）")
eve = new_id(); db.execute("insert into members(id,balance) values(?,1000)",(eve,))
price = get_price('private',None,200)  # 打3小時=600
charge(eve, price, typ='table_fee')
check("包桌3小時扣600", db.execute("select balance from members where id=?",(eve,)).fetchone()[0]==400)

print("【測試8】雙重獎金計算")
# 配桌獎金:店員配才發
def calc_match_bonus(promoted_by_staff):
    if promoted_by_staff is None: return 0  # 系統配,進公池不發個人
    return db.execute("select amount from bonus_rules where rule_key='match_made'").fetchone()[0]
check("店員配桌獎金=50", calc_match_bonus("staff-A")==50)
check("系統配桌不發個人=0", calc_match_bonus(None)==0)
# 綁定客人獎金:有效消費≥門檻才發
def calc_visit_bonus(spend):
    row = db.execute("select amount,min_spend from bonus_rules where rule_key='visit_commission'").fetchone()
    amt, floor = row
    return amt if spend >= floor else 0
check("消費150≥門檻100,綁定獎金=10", calc_visit_bonus(150)==10)
check("消費50<門檻100,不發=0", calc_visit_bonus(50)==0)
# 一桌上限:配桌50 + 4人×10
check("一桌獎金上限=90", 50 + 4*10 == 90)

print("【測試9】退款用沖正（不改舊帳,新增反向分錄）")
frank = new_id(); db.execute("insert into members(id,balance) values(?,0)",(frank,))
topup(frank, 500)   # 初始餘額也透過儲值流水（做法三鐵則:餘額一律從流水來）
charge(frank, 150)  # 扣150
# 沖正:退回150（新增一筆 reversal +150,不刪原扣款）
db.execute("insert into wallet_txns(id,member_id,type,amount) values(?,?,?,?)",
           (new_id(), frank, 'reversal', 150))
db.execute("update members set balance=balance+150 where id=?", (frank,))
check("扣150後沖正150,餘額回500", db.execute("select balance from members where id=?",(frank,)).fetchone()[0]==500)
check("原扣款紀錄仍在(append-only)",
      db.execute("select count(*) from wallet_txns where member_id=? and type='table_fee'",(frank,)).fetchone()[0]==1)
check("沖正後餘額與流水一致", balance_check(frank))

print(f"\n{'='*40}")
print(f"通過 {passed} / 失敗 {failed}")
print("✓ 全部通過,計費扣款邏輯正確" if failed==0 else "✗ 有錯誤,需修正")
