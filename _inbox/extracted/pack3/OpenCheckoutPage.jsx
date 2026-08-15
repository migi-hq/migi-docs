import React, { useState, useEffect, useMemo } from "react";
import { C, Bear } from "./shared.jsx";
import {
  listProducts, searchMembers, getMemberDetail,
  joinSession, checkBlocks, activateSession,
} from "./lib/api.js";

/* ============================================================
   開桌結帳 · 三欄工作台
   ------------------------------------------------------------
   左：座位（誰入座、收款狀態）
   中：檯費與商品加購
   右：該座位的消費明細與結帳
   ------------------------------------------------------------
   代付：一人可幫其他人付檯費，份數 = 自己 1 份 + 代付人數。
        被代付者仍建立入座記錄（牌局、CRM 需要），但消費金額與
        發票都歸付款人 —— 誰出錢，帳就是誰的。
   ============================================================ */

const PRIV_LABEL = { 120: "2小時內", 300: "2-5小時", 1440: "5小時以上" };
const PRIV_PRICE = { 120: 400, 300: 600, 1440: 800 };
const TOPUPS = [150, 500, 1000, 2000, 3000];

// 贈點級距：快捷與自訂共用同一套規則，3000 以上一律 300
function bonusOf(amt) {
  if (amt >= 3000) return 300;
  if (amt >= 2000) return 150;
  if (amt >= 1000) return 50;
  return 0;
}

export default function OpenCheckoutPage({ ctx, staffId, onCarried, onBack, flash }) {
  const { sessionId, table, mode, rounds, minutes, kind, flower, stakeLabel } = ctx;

  const [seats, setSeats] = useState([null, null, null, null]);
  const [curId, setCurId] = useState(null);
  const [products, setProducts] = useState([]);
  const [cat, setCat] = useState("檯費");
  const [payFor, setPayFor] = useState({});        // { 代付人id: [被代付人id...] }
  const [payForOpen, setPayForOpen] = useState(false);
  const [tableStarted, setTableStarted] = useState(false);
  const [busy, setBusy] = useState(false);

  // 結帳暫存（切換座位時重置）
  const [payWay, setPayWay] = useState("現金");
  const [ptManual, setPtManual] = useState(null);  // null = 全折（預設）
  const [ptEditing, setPtEditing] = useState(false);
  const [cashRecv, setCashRecv] = useState(null);
  const [couponSel, setCouponSel] = useState([]);

  const [addSeatIdx, setAddSeatIdx] = useState(-1);
  const [topupFor, setTopupFor] = useState(null);
  const [couponOpen, setCouponOpen] = useState(false);

  useEffect(() => { listProducts().then(setProducts); }, []);

  const cur = seats.find((s) => s && s.id === curId) || null;
  const seated = seats.filter(Boolean).length;

  /* —— 檯費 —— */
  // 包桌按實際入座人數分攤；配桌按將數，帶桌後才來的算中途加入
  const unitFee = useMemo(() => {
    if (mode === "private") return Math.ceil(PRIV_PRICE[minutes] / (seated || 1));
    if (tableStarted) return 100;
    return rounds === 3 ? 150 : 100;
  }, [mode, minutes, seated, tableStarted, rounds]);

  const feeName = mode === "private"
    ? `包桌檯費 · ${PRIV_LABEL[minutes]}`
    : tableStarted ? "配桌檯費 · 中途加入" : `配桌檯費 · ${rounds} 將`;

  function payerOf(id) {
    for (const k in payFor) {
      if (k === id) continue;
      if (payFor[k] && payFor[k].indexOf(id) >= 0) return k;
    }
    return null;
  }

  /* —— 金額計算 —— */
  function feeQty(s) {
    if (!s || payerOf(s.id)) return 0;             // 被代付者自己不收費
    return 1 + ((payFor[s.id] || []).length);
  }
  function itemsOf(s) {
    if (!s) return [];
    const list = [];
    const q = feeQty(s);
    if (q > 0) list.push({ name: feeName, price: unitFee, qty: q, kind: "fee" });
    (s.cart || []).forEach((it) => list.push(it));
    return list;
  }
  function sumOf(s, k) {
    return itemsOf(s).filter((i) => k ? i.kind === k : true)
      .reduce((a, i) => a + i.price * i.qty, 0);
  }
  const goodsSum = (s) => sumOf(s) - sumOf(s, "topup");   // 可折抵金額（排除儲值）
  const topupSum = (s) => sumOf(s, "topup");
  const topupCredit = (s) => itemsOf(s).filter((i) => i.kind === "topup")
    .reduce((a, i) => a + (i.credit || i.price) * i.qty, 0);

  function couponCut(s) {
    if (!s || !s.coupons || !couponSel.length) return 0;
    const feeR = sumOf(s, "fee"), fnbR = sumOf(s, "fnb");
    let cut = 0;
    couponSel.forEach((cid) => {
      const c = s.coupons.find((x) => x.id === cid); if (!c) return;
      const cap = c.applies_to === "table_fee" ? feeR
                : c.applies_to === "fnb" ? fnbR : feeR + fnbR;
      if (cap <= 0) return;
      cut += c.discount_type === "free" ? cap
           : c.discount_type === "percent" ? Math.round(cap * (c.discount_value || 0) / 100)
           : Math.min(c.discount_value || 0, cap);
    });
    return cut;
  }
  function tierCut(s) {
    if (!s) return 0;
    const after = Math.max(0, goodsSum(s) - couponCut(s));
    return Math.round(after * (1 - (s.tier_rate == null ? 1 : s.tier_rate)));
  }
  // 消費部分應付（點數只能折這裡，儲值不受折扣也不能用點數買）
  const consumePayable = (s) => Math.max(0, goodsSum(s) - couponCut(s) - tierCut(s));
  const payable = (s) => consumePayable(s) + topupSum(s);

  const ptMax = cur ? Math.min(cur.balance || 0, consumePayable(cur)) : 0;
  const ptUse = ptManual === null ? ptMax : Math.max(0, Math.min(ptManual, ptMax));
  const cashDue = cur ? payable(cur) - ptUse : 0;

  /* —— 操作 —— */
  function switchSeat(id) {
    setCurId(id);
    // 代付面板：有代付關係就保持展開，否則收起（避免延續到別人身上）
    setPayForOpen(((payFor[id] || []).length) > 0);
    setPayWay("現金"); setPtManual(null); setPtEditing(false);
    setCashRecv(null); setCouponSel([]);
  }

  async function addMember(m, idx) {
    const detail = await getMemberDetail(m.id);
    const next = seats.slice();
    next[idx] = Object.assign({}, m, detail || {}, { cart: [], paid: false });
    setSeats(next);
    setAddSeatIdx(-1);
    switchSeat(m.id);
    // 互黑警示：不阻擋，由店員判斷要不要分桌
    const blk = await checkBlocks(sessionId, m.id);
    if (blk && blk.has_conflict) {
      const names = (blk.conflicts || []).map((c) => c.nickname).join("、");
      flash && flash("⚠ " + m.nickname + " 與同桌的 " + names + " 互為封鎖，建議分桌");
    }
  }

  function removeSeat(i) {
    const was = seats[i];
    const next = seats.slice(); next[i] = null;
    if (was) {
      const pf = Object.assign({}, payFor);
      delete pf[was.id];
      Object.keys(pf).forEach((k) => {
        pf[k] = pf[k].filter((x) => x !== was.id);
        if (!pf[k].length) delete pf[k];
      });
      setPayFor(pf);
    }
    setSeats(next);
    if (was && was.id === curId) {
      const rest = next.filter(Boolean);
      setCurId(rest.length ? rest[0].id : null);
    }
  }

  function togglePayFor(payerId, targetId) {
    if (payerId === targetId) return;              // 不能代付自己
    const pf = Object.assign({}, payFor);
    const arr = (pf[payerId] || []).slice();
    const i = arr.indexOf(targetId);
    if (i >= 0) arr.splice(i, 1);
    else {
      const other = payerOf(targetId);
      if (other && other !== payerId) return;      // 已被他人代付
      arr.push(targetId);
    }
    if (arr.length) pf[payerId] = arr; else delete pf[payerId];
    setPayFor(pf);
  }

  function addItem(p) {
    if (!cur) { flash && flash("請先加入客人"); return; }
    setSeats(seats.map((s) => {
      if (!s || s.id !== curId) return s;
      const cart = s.cart.map((x) => Object.assign({}, x));
      const hit = cart.find((x) => x.name === p.name);
      if (hit) hit.qty += 1;
      else cart.push({ name: p.name, price: p.unit_price, qty: 1, kind: p.kind || "goods" });
      return Object.assign({}, s, { cart });
    }));
  }

  function setQty(name, q) {
    setSeats(seats.map((s) => {
      if (!s || s.id !== curId) return s;
      let cart = s.cart.map((x) => Object.assign({}, x));
      if (q <= 0) cart = cart.filter((x) => x.name !== name);
      else { const hit = cart.find((x) => x.name === name); if (hit) hit.qty = q; }
      return Object.assign({}, s, { cart });
    }));
  }

  function addTopup(amt) {
    const bonus = bonusOf(amt);
    setSeats(seats.map((s) => {
      if (!s || s.id !== topupFor) return s;
      const cart = s.cart.map((x) => Object.assign({}, x));
      cart.push({
        name: "會員儲值 $" + amt + (bonus ? "（+" + bonus + "贈）" : ""),
        price: amt, credit: amt + bonus, qty: 1, kind: "topup",
      });
      return Object.assign({}, s, { cart });
    }));
    setTopupFor(null);
  }

  async function doPay() {
    if (!cur || busy) return;
    const need = cashDue;
    if (need > 0 && payWay === "現金" && (cashRecv || 0) < need) {
      flash && flash("請輸入實收金額"); return;
    }
    setBusy(true);
    const payments = need > 0 ? [Object.assign({
      method: payWay === "現金" ? "cash" : payWay === "信用卡" ? "credit_card" : "line_pay",
      amount: need,
    }, payWay === "現金" ? {
      cash_received: cashRecv, change_given: (cashRecv || 0) - need,
    } : {})] : null;

    const res = await joinSession({
      sessionId, memberId: cur.id,
      joinType: tableStarted ? "mid_join" : "opener",
      couponIds: couponSel.length ? couponSel : null,
      pointsUsed: ptUse,
      payments, staffId,
      payFor: payFor[cur.id] || null,
    });
    setBusy(false);
    if (!res.ok) { flash && flash(res.message || res.reason || "結帳失敗"); return; }

    const receipt = {
      items: itemsOf(cur), payable: payable(cur),
      couponCut: couponCut(cur), tierCut: tierCut(cur),
      ptUse: ptUse, cashDue: need, way: payWay,
      change: payWay === "現金" ? Math.max(0, (cashRecv || 0) - need) : 0,
    };
    const paidIds = payFor[cur.id] || [];
    const credit = topupCredit(cur);
    setSeats(seats.map((s) => {
      if (!s) return s;
      if (s.id === cur.id) {
        return Object.assign({}, s, {
          paid: true, receipt, cart: [],
          balance: (s.balance || 0) - ptUse + credit,
        });
      }
      // 被代付者一併標記已結帳：費用已含在付款人那張單裡
      if (paidIds.indexOf(s.id) >= 0) {
        return Object.assign({}, s, { paid: true, paidByName: cur.nickname, cart: [] });
      }
      return s;
    }));
    setCouponSel([]); setPtManual(null); setCashRecv(null); setPayWay("現金");
  }

  async function carry() {
    const res = await activateSession(sessionId, staffId);
    if (!res.ok) { flash && flash(res.reason || "帶桌失敗"); return; }
    setTableStarted(true);
    onCarried && onCarried(table.label);
  }

  /* —— 商品分類 —— */
  const cats = useMemo(() => {
    const out = ["檯費"];
    products.forEach((p) => {
      if (p.sku === "SVC-TBL-DAY") return;
      const c = p.category === "fnb" ? "餐飲" : p.category === "merch" ? "周邊" : "服務";
      if (out.indexOf(c) < 0) out.push(c);
    });
    return out;
  }, [products]);

  const catItems = cat === "檯費"
    ? [{ name: feeName, unit_price: unitFee, kind: "fee" }]
        .concat(products.filter((p) => p.sku === "SVC-TBL-DAY"))
    : products.filter((p) => {
        if (p.sku === "SVC-TBL-DAY") return false;
        const c = p.category === "fnb" ? "餐飲" : p.category === "merch" ? "周邊" : "服務";
        return c === cat;
      });

  const seatedList = seats.filter(Boolean);
  const allPaid = seatedList.length > 0 && seatedList.every((s) => s.paid);

  return (
    <div style={S.wrap}>
      <div style={S.top}>
        <div style={S.titlebar}>
          <span style={S.logo}>MIGI</span>
          <span style={S.no}>{table && table.label}</span>
          <span style={S.sub}>
            {mode === "matched" ? "配桌 · " + rounds + "將" : "包桌 · " + PRIV_LABEL[minutes]}
            {" · " + kind + " · " + flower + " · " + stakeLabel}
          </span>
          <span style={S.back} onClick={onBack}>‹ 回到即時桌況</span>
        </div>
      </div>

      <div style={S.body}>
        {/* 左：座位 */}
        <div style={S.seatCol}>
          {seats.map((s, i) => s ? (
            <div key={i} style={Object.assign({}, S.seat, s.id === curId ? S.seatCur : null)}
                 onClick={() => switchSeat(s.id)}>
              {!s.paid && (
                <span style={S.rm} onClick={(e) => { e.stopPropagation(); removeSeat(i); }}>✕</span>
              )}
              <Bear size={40} />
              <div style={{ minWidth: 0, flex: 1 }}>
                <div style={S.seatNm}>{s.nickname}</div>
                <div style={S.seatBal}>{s.balance || 0} 點</div>
              </div>
              <span style={Object.assign({}, S.badge,
                s.paid ? S.badgePaid : payerOf(s.id) ? S.badgeProxy : S.badgeUnpaid)}>
                {s.paid ? "已結帳" : payerOf(s.id) ? "代付中" : "未結帳"}
              </span>
            </div>
          ) : (
            <div key={i} style={Object.assign({}, S.seat, S.seatEmpty)} onClick={() => setAddSeatIdx(i)}>
              <div style={S.addIc}>＋</div>
              <div style={Object.assign({}, S.seatNm, { color: C.gray2 })}>加入客人</div>
            </div>
          ))}
        </div>

        {/* 中：商品 */}
        <div style={S.midCol}>
          {!cur ? (
            <div style={S.midEmpty}>
              <b style={{ fontSize: 17, color: C.gray1 }}>尚未加入客人</b>
              <div style={{ fontSize: 13 }}>點左側 ＋ 加入客人開始開桌</div>
            </div>
          ) : (
            <React.Fragment>
              <div style={S.midTitle}>檯費 / 商品加購</div>
              <div style={S.cats}>
                {cats.map((c) => (
                  <span key={c} onClick={() => setCat(c)}
                        style={Object.assign({}, S.cat, cat === c ? S.catOn : null)}>{c}</span>
                ))}
              </div>
              <div style={S.items}>
                {catItems.map((p, i) => {
                  // 檯費份數由代付關係決定、明細區自動帶入，點了不再重複加入
                  const isFee = p.kind === "fee" && p.name === feeName;
                  const qty = isFee ? feeQty(cur)
                    : (cur.cart.find((x) => x.name === p.name) || {}).qty || 0;
                  return (
                    <div key={i} onClick={() => isFee ? null : addItem(p)}
                         style={Object.assign({}, S.item, qty > 0 ? S.itemHas : null,
                                              isFee ? { cursor: "default" } : null)}>
                      {qty > 0 ? <div style={S.qtyBadge}>{qty}</div>
                               : <div style={S.plus}>＋</div>}
                      <div style={S.itemNm}>{p.name}</div>
                      <div style={S.itemPr}>{p.unit_price} 點</div>
                    </div>
                  );
                })}
              </div>
            </React.Fragment>
          )}
        </div>

        {/* 右：結帳 */}
        <div style={S.rCol}>
          {!cur ? (
            <div style={{ padding: 24, color: C.gray3, fontSize: 14 }}>請先加入客人</div>
          ) : cur.paid ? (
            <Receipt p={cur} onAddon={() => setSeats(seats.map((s) =>
              s && s.id === cur.id ? Object.assign({}, s, { paid: false, receipt: null }) : s))} />
          ) : (
            <CheckoutBody
              p={cur} seats={seats} payFor={payFor} payerOf={payerOf}
              payForOpen={payForOpen} setPayForOpen={setPayForOpen}
              togglePayFor={togglePayFor} unitFee={unitFee}
              items={itemsOf(cur)} setQty={setQty}
              goodsSumV={goodsSum(cur)} couponCutV={couponCut(cur)} tierCutV={tierCut(cur)}
              consumePayableV={consumePayable(cur)}
              ptUse={ptUse} ptMax={ptMax} ptEditing={ptEditing}
              setPtEditing={setPtEditing} setPtManual={setPtManual}
              cashDue={cashDue} payWay={payWay} setPayWay={setPayWay}
              cashRecv={cashRecv} setCashRecv={setCashRecv}
              couponCount={(cur.coupons || []).length}
              openCoupon={() => setCouponOpen(true)}
              onTopup={() => setTopupFor(cur.id)}
              onPay={doPay} busy={busy} />
          )}
        </div>
      </div>

      <div style={S.foot}>
        <span style={{ fontSize: 15, color: C.gray1 }}>
          已結帳 <b style={{ color: C.ink }}>{seatedList.filter((s) => s.paid).length}</b> / {seatedList.length} 人
        </span>
        <button style={Object.assign({}, S.carryBtn, allPaid ? null : S.btnOff)}
                disabled={!allPaid} onClick={carry}>帶桌 →</button>
      </div>

      {addSeatIdx >= 0 && (
        <AddMemberModal exclude={seats.filter(Boolean).map((s) => s.id)}
          onPick={(m) => addMember(m, addSeatIdx)} onClose={() => setAddSeatIdx(-1)} />
      )}
      {topupFor && <TopupModal onPick={addTopup} onClose={() => setTopupFor(null)} />}
      {couponOpen && cur && (
        <CouponModal coupons={cur.coupons || []} sel={couponSel}
          onApply={(x) => { setCouponSel(x); setCouponOpen(false); }}
          onClose={() => setCouponOpen(false)} />
      )}
    </div>
  );
}

/* ============================================================
   右欄：結帳明細
   ============================================================ */
function CheckoutBody(props) {
  const {
    p, seats, payFor, payerOf, payForOpen, setPayForOpen, togglePayFor, unitFee,
    items, setQty, goodsSumV, couponCutV, tierCutV, consumePayableV,
    ptUse, ptMax, ptEditing, setPtEditing, setPtManual,
    cashDue, payWay, setPayWay, cashRecv, setCashRecv,
    couponCount, openCoupon, onTopup, onPay, busy,
  } = props;

  const feeItems = items.filter((i) => i.kind === "fee");
  const goodsItems = items.filter((i) => i.kind !== "fee" && i.kind !== "topup");
  const topupItems = items.filter((i) => i.kind === "topup");
  const others = seats.filter((x) => x && x.id !== p.id && !x.paid);
  const myPayFor = payFor[p.id] || [];
  const canPayFor = others.length > 0 && !payerOf(p.id);
  const tierPct = Math.round((1 - (p.tier_rate == null ? 1 : p.tier_rate)) * 100);
  const cashShort = cashDue > 0 && payWay === "現金" && (cashRecv || 0) < cashDue;

  return (
    <React.Fragment>
      <div style={S.pbar}>
        <Bear size={42} />
        <div style={{ minWidth: 0, flex: 1 }}>
          <div style={S.pbarNm}>{p.nickname}</div>
          <span style={S.pbarLv}>會員：{p.tier || "—"}</span>
        </div>
      </div>

      <div style={S.balBox}>
        <span style={{ fontSize: 13, fontWeight: 600 }}>目前餘額</span>
        <span style={{ fontSize: 20, fontWeight: 700, marginLeft: 10 }}>{p.balance || 0} 點</span>
        <button style={S.topupBtn} onClick={onTopup}>儲值</button>
      </div>

      {/* 檯費固定在最上；份數由代付決定，不開放手動增減 */}
      {feeItems.length > 0 && (
        <div style={{ padding: "6px 18px 0", flexShrink: 0 }}>
          {feeItems.map((it, i) => (
            <div key={i} style={S.lineitem}>
              <div style={{ flex: 1, minWidth: 0 }}><div style={S.lineNm}>{it.name}</div></div>
              <div style={S.qtyLock}>×{it.qty}</div>
              <div style={S.lineAmt}>${it.price * it.qty}</div>
            </div>
          ))}
        </div>
      )}

      {/* 代付 */}
      {canPayFor && (
        <div style={{ padding: "8px 18px 0", flexShrink: 0 }}>
          <button style={S.payforBtn} onClick={() => setPayForOpen(!payForOpen)}>
            代付其他人{myPayFor.length ? "（" + myPayFor.length + "）" : ""}
            <span style={Object.assign({}, S.caret, payForOpen ? S.caretOpen : null)}>›</span>
          </button>
          {payForOpen && (
            <div style={S.payforList}>
              {others.map((o) => {
                const on = myPayFor.indexOf(o.id) >= 0;
                const lockedBy = payerOf(o.id);
                const disabled = lockedBy && lockedBy !== p.id;
                return (
                  <div key={o.id} onClick={() => !disabled && togglePayFor(p.id, o.id)}
                       style={Object.assign({}, S.payforItem,
                         on ? S.payforOn : null, disabled ? S.payforOff : null)}>
                    <span style={Object.assign({}, S.pfCk, on ? S.pfCkOn : null)}>{on ? "✓" : ""}</span>
                    <span style={{ fontWeight: 700, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                      {o.nickname}</span>
                    <span style={S.pfAmt}>{disabled ? "已由他人代付" : "+$" + unitFee}</span>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      )}

      {/* 商品（可捲動） */}
      <div style={S.lines}>
        {items.length === 0
          ? <div style={S.linesEmpty}>請從左側選擇檯費或商品</div>
          : goodsItems.map((it, i) => (
            <div key={i} style={S.lineitem}>
              <div style={{ flex: 1, minWidth: 0 }}><div style={S.lineNm}>{it.name}</div></div>
              <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                <button style={S.stepBtn} onClick={() => setQty(it.name, it.qty - 1)}>-</button>
                <span style={{ fontWeight: 800, minWidth: 18, textAlign: "center" }}>{it.qty}</span>
                <button style={S.stepBtn} onClick={() => setQty(it.name, it.qty + 1)}>+</button>
              </div>
              <div style={S.lineAmt}>${it.price * it.qty}</div>
            </div>
          ))}
      </div>

      {items.length > 0 && (
        <div style={S.checkoutbar}>
          {couponCount > 0 && couponCutV === 0 && (
            <button style={S.couponBtn} onClick={openCoupon}>使用優惠券</button>
          )}
          <div style={S.row}><span>小計</span><span style={S.rowV}>${goodsSumV}</span></div>

          {tierCutV > 0 && (
            <div style={S.row}>
              <span>會員折扣 <span style={S.tierTag}>{tierPct}%</span></span>
              <span style={Object.assign({}, S.rowV, { color: C.rose })}>-${tierCutV}</span>
            </div>
          )}
          {couponCutV > 0 && (
            <div style={S.row}>
              <span>優惠券折抵 <span style={S.changeLink} onClick={openCoupon}>更換</span></span>
              <span style={Object.assign({}, S.rowV, { color: C.rose })}>-${couponCutV}</span>
            </div>
          )}

          {p.balance > 0 && consumePayableV > 0 && (
            <div style={S.ptRow}>
              <span style={{ fontSize: 14.5, color: C.gray1, fontWeight: 600 }}>點數折抵</span>
              <span style={{ marginLeft: "auto", display: "flex", alignItems: "center", gap: 9 }}>
                {ptUse < ptMax && !ptEditing && (
                  <button style={S.fullPt} onClick={() => setPtManual(null)}>全折</button>
                )}
                {ptEditing ? (
                  <input autoFocus type="number" defaultValue={ptUse} style={S.ptInput}
                    onChange={(e) => {
                      let n = parseInt(e.target.value, 10);
                      if (isNaN(n) || n < 0) n = 0;
                      if (n > ptMax) n = ptMax;
                      setPtManual(n);
                    }}
                    onBlur={() => setPtEditing(false)} />
                ) : (
                  <span style={Object.assign({}, S.ptVal, ptUse === 0 ? S.ptValOff : null)}
                        onClick={() => setPtEditing(true)}>
                    {ptUse > 0 ? "-" + ptUse : "0"} 點</span>
                )}
              </span>
            </div>
          )}

          {/* 儲值列在點數折抵下方：位置本身說明它不受上面的折扣影響 */}
          {topupItems.length > 0 && <div style={S.topupSep} />}
          {topupItems.map((it, i) => (
            <div key={i} style={S.row}>
              <span>會員儲值 {(it.credit || it.price) * it.qty} 點
                <span style={S.rmTopup} onClick={() => setQty(it.name, 0)}>移除</span>
              </span>
              <span style={S.rowV}>${it.price * it.qty}</span>
            </div>
          ))}

          <div style={S.due}>
            <span style={{ fontSize: 16, fontWeight: 800 }}>尚需支付</span>
            <span style={S.dueV}>${cashDue}</span>
          </div>

          {cashDue > 0 && (
            <div style={S.wayRow}>
              {["現金", "信用卡", "LINE Pay"].map((w) => (
                <span key={w} onClick={() => { setPayWay(w); setCashRecv(null); }}
                      style={Object.assign({}, S.way, payWay === w ? S.wayOn : null)}>{w}</span>
              ))}
            </div>
          )}

          {cashDue > 0 && payWay === "現金" && (
            <React.Fragment>
              <div style={S.cashField}>
                <label style={{ fontSize: 12, color: C.gray1, width: 70, flexShrink: 0 }}>實收現金</label>
                <input type="number" placeholder="0" value={cashRecv == null ? "" : cashRecv}
                       onChange={(e) => setCashRecv(Math.max(0, parseInt(e.target.value, 10) || 0))}
                       style={S.cashInput} />
              </div>
              <div style={S.quickCash}>
                {[100, 200, 500, 1000].map((q) => (
                  <button key={q} style={S.quickBtn} onClick={() => setCashRecv(q)}>{q}</button>
                ))}
                <button style={S.quickBtn} onClick={() => setCashRecv(cashDue)}>剛好</button>
              </div>
              <div style={S.changeRow}>
                <span>找零</span>
                <b style={S.changeV}>${Math.max(0, (cashRecv || 0) - cashDue)}</b>
              </div>
            </React.Fragment>
          )}

          <button style={Object.assign({}, S.payBtn, busy || cashShort ? S.btnOff : null)}
                  disabled={busy || cashShort} onClick={onPay}>
            {busy ? "處理中…"
              : cashDue === 0 ? "確認結帳 · 扣 " + ptUse + " 點"
              : "確認結帳 · 扣 " + ptUse + " ＋ 收 $" + cashDue}
          </button>
        </div>
      )}
    </React.Fragment>
  );
}

/* ============================================================
   收據（結帳後停留在右欄）
   ============================================================ */
function Receipt({ p, onAddon }) {
  const r = p.receipt;

  // 被他人代付且已結帳：沒有自己的收據，顯示由誰支付
  if (!r) {
    return (
      <React.Fragment>
        <div style={S.pbar}>
          <Bear size={42} />
          <div style={{ minWidth: 0, flex: 1 }}>
            <div style={S.pbarNm}>{p.nickname}</div>
            <span style={S.pbarLv}>會員：{p.tier || "—"}</span>
          </div>
        </div>
        <div style={S.badgeDone}><span style={S.badgeCk}>✓</span>已完成收費</div>
        <div style={S.rsec}>
          <div style={S.paidbyNote}>
            此位檯費已由 <b>{p.paidByName}</b> 代付<br />
            <span>費用含在對方的帳單中，無須另外收款</span>
          </div>
        </div>
      </React.Fragment>
    );
  }

  const gross = r.items.reduce((a, i) => a + i.price * i.qty, 0);
  const hasDisc = r.couponCut > 0 || r.tierCut > 0;

  return (
    <React.Fragment>
      <div style={S.pbar}>
        <Bear size={42} />
        <div style={{ minWidth: 0, flex: 1 }}>
          <div style={S.pbarNm}>{p.nickname}</div>
          <span style={S.pbarLv}>會員：{p.tier || "—"}</span>
        </div>
      </div>

      <div style={S.badgeDone}><span style={S.badgeCk}>✓</span>已完成收費</div>

      {/* 買了什麼 */}
      <div style={S.rsec}>
        <div style={S.rsecLbl}>消費明細</div>
        {r.items.map((it, i) => (
          <div key={i} style={S.rItem}>
            <span>{it.name}{it.qty > 1 && <span style={S.rQty}>×{it.qty}</span>}</span>
            <span style={S.rItemV}>${it.price * it.qty}</span>
          </div>
        ))}
      </div>

      {/* 折扣後要付多少 */}
      <div style={Object.assign({}, S.rsec, S.rsecTop)}>
        {hasDisc && (
          <div style={S.rRow}><span>小計</span><span style={S.rRowV}>${gross}</span></div>
        )}
        {r.couponCut > 0 && (
          <div style={S.rRow}><span>優惠券折抵</span>
            <span style={Object.assign({}, S.rRowV, { color: C.rose })}>-${r.couponCut}</span></div>
        )}
        {r.tierCut > 0 && (
          <div style={S.rRow}><span>會員折扣</span>
            <span style={Object.assign({}, S.rRowV, { color: C.rose })}>-${r.tierCut}</span></div>
        )}
        <div style={S.rTotal}>
          <span style={{ fontSize: 15, fontWeight: 800 }}>應付金額</span>
          <span style={S.rTotalV}>${r.payable}</span>
        </div>
      </div>

      {/* 用什麼付清：各項相加＝應付金額，可直接驗算 */}
      {(r.ptUse > 0 || r.cashDue > 0) && (
        <div style={Object.assign({}, S.rsec, S.rsecTop)}>
          <div style={S.rsecLbl}>收款方式</div>
          {r.ptUse > 0 && (
            <div style={S.rChange}><span>點數</span><b>{r.ptUse}</b></div>
          )}
          {r.cashDue > 0 && (
            <div style={S.rChange}><span>{r.way}</span><b>${r.cashDue}</b></div>
          )}
          {r.way === "現金" && r.change > 0 && (
            <React.Fragment>
              <div style={S.rDivide} />
              <div style={S.rChange}><span>實收現金</span><b>${r.cashDue + r.change}</b></div>
              <div style={S.rChange}>
                <span style={{ color: C.ink, fontWeight: 700 }}>找零</span>
                <b style={S.rChangeHl}>${r.change}</b>
              </div>
            </React.Fragment>
          )}
        </div>
      )}

      <button style={S.addonBtn} onClick={onAddon}>＋ 加購新項目</button>
    </React.Fragment>
  );
}

/* ============================================================
   Modals
   ============================================================ */
function Modal({ title, children, onClose }) {
  return (
    <div style={S.mask} onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div style={S.modal}>
        <span style={S.modalX} onClick={onClose}>✕</span>
        <h3 style={{ fontSize: 18, fontWeight: 800, margin: "0 0 14px" }}>{title}</h3>
        {children}
      </div>
    </div>
  );
}

function AddMemberModal({ exclude, onPick, onClose }) {
  const [q, setQ] = useState("");
  const [list, setList] = useState([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (q.trim().length < 1) { setList([]); return; }
    setLoading(true);
    const t = setTimeout(() => {
      searchMembers(q).then((r) => { setList(r); setLoading(false); });
    }, 250);
    return () => clearTimeout(t);
  }, [q]);

  return (
    <Modal title="加入客人" onClose={onClose}>
      <input autoFocus placeholder="搜尋姓名或手機號碼" value={q}
             onChange={(e) => setQ(e.target.value)} style={S.searchBox} />
      {list.map((m) => {
        const used = exclude.indexOf(m.id) >= 0;
        return (
          <div key={m.id} onClick={() => !used && onPick(m)}
               style={Object.assign({}, S.mRow, {
                 opacity: used ? 0.4 : 1, cursor: used ? "not-allowed" : "pointer",
               })}>
            <Bear size={40} />
            <div style={{ minWidth: 0, flex: 1 }}>
              <div style={S.mNm}>{m.nickname}</div>
              <div style={S.mSub}>{m.tier} · {m.phone}</div>
            </div>
            <div style={{ fontSize: 13, fontWeight: 800, flexShrink: 0 }}>
              {used ? "已入座" : (m.balance || 0) + " 點"}
            </div>
          </div>
        );
      })}
      {q.trim() && !loading && !list.length && <div style={S.linesEmpty}>查無會員</div>}
      {loading && <div style={S.linesEmpty}>搜尋中…</div>}
    </Modal>
  );
}

function TopupModal({ onPick, onClose }) {
  const [amt, setAmt] = useState(0);
  const [custom, setCustom] = useState(false);
  const [customOpen, setCustomOpen] = useState(false);
  const [customVal, setCustomVal] = useState("");

  return (
    <Modal title="儲值點數" onClose={onClose}>
      <div style={S.topupNote}>選擇金額後將加入本次消費明細，一起結帳</div>
      <div style={S.topupGrid}>
        {TOPUPS.map((t) => (
          <div key={t} onClick={() => { setAmt(t); setCustom(false); }}
               style={Object.assign({}, S.topupOpt, !custom && amt === t ? S.topupOptOn : null)}>
            <div style={S.topupNum}>{t.toLocaleString()}</div>
            <div style={S.topupBonus}>{bonusOf(t) ? "+" + bonusOf(t) + " 贈點" : "\u00A0"}</div>
          </div>
        ))}
        <div onClick={() => setCustomOpen(true)}
             style={Object.assign({}, S.topupOpt,
               { background: custom ? "#FFF6F8" : C.card },
               custom ? S.topupOptOn : null)}>
          <div style={Object.assign({}, S.topupNum, { color: custom ? C.ink : C.gray2 })}>
            {custom ? amt.toLocaleString() : "自訂"}
          </div>
          <div style={S.topupBonus}>{custom ? "點此修改" : "\u00A0"}</div>
        </div>
      </div>
      <button style={Object.assign({}, S.payBtn, amt > 0 ? null : S.btnOff)}
              disabled={amt <= 0} onClick={() => onPick(amt)}>
        {amt > 0 ? "加入本次結帳" : "請選擇儲值金額"}
      </button>

      {customOpen && (
        <div style={S.customMask}
             onClick={(e) => e.target === e.currentTarget && setCustomOpen(false)}>
          <div style={S.customCard}>
            <p style={{ margin: "0 0 4px", fontSize: 15, fontWeight: 700 }}>自訂儲值金額</p>
            <p style={{ margin: "0 0 14px", fontSize: 12, color: C.gray2 }}>輸入想儲值的金額</p>
            <input autoFocus inputMode="numeric" placeholder="例如 700" value={customVal}
                   onChange={(e) => setCustomVal(e.target.value.replace(/[^0-9]/g, ""))}
                   style={S.customInput} />
            <div style={{ display: "flex", gap: 9, marginTop: 15 }}>
              <button style={Object.assign({}, S.customBtn, { background: C.idle, color: C.gray1 })}
                      onClick={() => setCustomOpen(false)}>取消</button>
              <button style={Object.assign({}, S.customBtn, { background: C.ink, color: "#fff" })}
                      onClick={() => {
                        const n = parseInt(customVal, 10);
                        if (n > 0) { setAmt(n); setCustom(true); }
                        setCustomOpen(false);
                      }}>確定</button>
            </div>
          </div>
        </div>
      )}
    </Modal>
  );
}

function CouponModal({ coupons, sel, onApply, onClose }) {
  const [pick, setPick] = useState(sel.slice());
  return (
    <Modal title="選擇優惠券" onClose={onClose}>
      {/* 券為單選互斥，並提供「不使用」選項 */}
      <div onClick={() => setPick([])}
           style={Object.assign({}, S.couponItem, pick.length === 0 ? S.couponOn : null)}>
        <div style={Object.assign({}, S.pfCk, pick.length === 0 ? S.pfCkOn : null)}>
          {pick.length === 0 ? "✓" : ""}
        </div>
        <div style={{ fontWeight: 800, fontSize: 15, color: C.gray1 }}>不使用優惠券</div>
      </div>
      {coupons.map((c) => {
        const on = pick.indexOf(c.id) >= 0;
        return (
          <div key={c.id} onClick={() => setPick(on ? [] : [c.id])}
               style={Object.assign({}, S.couponItem, on ? S.couponOn : null)}>
            <div style={Object.assign({}, S.pfCk, on ? S.pfCkOn : null)}>{on ? "✓" : ""}</div>
            <div>
              <div style={{ fontWeight: 800, fontSize: 15 }}>{c.name}</div>
              <div style={{ fontSize: 12, color: C.gray2, marginTop: 2 }}>
                {c.discount_type === "free" ? "整項免費"
                  : c.discount_type === "percent" ? c.discount_value + "% 折抵"
                  : "折抵 $" + c.discount_value}
                {" · "}
                {c.applies_to === "table_fee" ? "限檯費"
                  : c.applies_to === "fnb" ? "限餐飲" : "全品項"}
              </div>
            </div>
          </div>
        );
      })}
      <button style={S.payBtn} onClick={() => onApply(pick)}>套用</button>
    </Modal>
  );
}

/* ============================================================
   樣式
   ============================================================ */
const S = {
  wrap: { flex: 1, display: "flex", flexDirection: "column", overflow: "hidden" },
  top: { background: "#fff", borderBottom: "1px solid " + C.line, flexShrink: 0, padding: "0 24px" },
  titlebar: { display: "flex", alignItems: "center", gap: 10, height: 72 },
  logo: { fontSize: 22, fontWeight: 900, letterSpacing: ".08em", paddingRight: 14, marginRight: 10, borderRight: "1px solid " + C.line },
  no: { fontSize: 22, fontWeight: 900, letterSpacing: ".05em", marginRight: 8 },
  sub: { fontSize: 13, color: C.gray1, fontWeight: 500 },
  back: { marginLeft: "auto", fontSize: 14, fontWeight: 700, color: C.gray1, cursor: "pointer", whiteSpace: "nowrap" },
  body: { flex: 1, display: "flex", minHeight: 0 },

  seatCol: { width: 216, flexShrink: 0, borderRight: "1px solid " + C.line, background: C.card, display: "flex", flexDirection: "column", gap: 9, padding: "12px 10px", overflowY: "auto" },
  seat: { display: "flex", alignItems: "center", gap: 8, padding: "13px 10px", background: "#fff", border: "1.5px solid " + C.line, borderRadius: 12, cursor: "pointer", position: "relative" },
  seatCur: { border: "2px solid " + C.rose, padding: "12.5px 9.5px" },
  seatEmpty: { borderStyle: "dashed", borderColor: "#DED9D5", color: C.gray2 },
  seatNm: { fontSize: 15, fontWeight: 800, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" },
  seatBal: { fontSize: 12, fontWeight: 700, color: C.gray1, marginTop: 3 },
  addIc: { width: 40, height: 40, borderRadius: "50%", background: C.idle, color: C.gray1, display: "flex", alignItems: "center", justifyContent: "center", fontSize: 17, fontWeight: 700, flexShrink: 0 },
  rm: { position: "absolute", top: -7, right: -7, width: 22, height: 22, borderRadius: "50%", background: "#fff", border: "1.5px solid " + C.line, color: C.gray1, display: "flex", alignItems: "center", justifyContent: "center", fontSize: 12, cursor: "pointer", zIndex: 2 },
  badge: { marginLeft: "auto", fontSize: 10.5, fontWeight: 800, padding: "5px 9px", borderRadius: 99, whiteSpace: "nowrap", flexShrink: 0 },
  badgeUnpaid: { background: C.rose, color: "#fff" },
  badgeProxy: { background: C.peach, color: C.ink },
  badgePaid: { background: C.idle, color: C.gray2 },

  midCol: { flex: 1, display: "flex", flexDirection: "column", minWidth: 0 },
  midEmpty: { flex: 1, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 10, color: C.gray3 },
  midTitle: { padding: "16px 22px 0", fontSize: 18, fontWeight: 800 },
  cats: { display: "flex", gap: 8, padding: "12px 22px 0", flexWrap: "wrap" },
  cat: { border: "1.5px solid #E8E4E1", borderRadius: 99, padding: "6px 15px", fontSize: 13, fontWeight: 700, cursor: "pointer", background: "#fff", color: "#8A857F" },
  catOn: { borderColor: C.peach, background: C.peach, color: C.ink },
  items: { flex: 1, overflowY: "auto", padding: "14px 22px", display: "grid", gridTemplateColumns: "repeat(3,1fr)", gap: 12, alignContent: "start" },
  item: { position: "relative", border: "1.5px solid " + C.line, background: "#fff", borderRadius: 14, padding: 13, cursor: "pointer", minHeight: 70 },
  itemHas: { borderColor: C.rose, background: "#FFF6F8" },
  itemNm: { fontSize: 13, fontWeight: 700, paddingRight: 32 },
  itemPr: { fontSize: 14, fontWeight: 800, marginTop: 6, fontFamily: "'Segoe UI',sans-serif" },
  qtyBadge: { position: "absolute", top: 10, right: 10, minWidth: 26, height: 26, borderRadius: 99, background: C.rose, color: "#fff", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 13, fontWeight: 800, padding: "0 8px" },
  plus: { position: "absolute", top: 10, right: 10, width: 26, height: 26, borderRadius: "50%", background: C.idle, color: C.gray1, display: "flex", alignItems: "center", justifyContent: "center", fontSize: 15, fontWeight: 700 },

  rCol: { width: 420, flexShrink: 0, borderLeft: "1px solid " + C.line, background: "#fff", display: "flex", flexDirection: "column", overflowY: "auto" },
  pbar: { padding: "14px 18px", background: C.peach, display: "flex", alignItems: "center", gap: 11, flexShrink: 0 },
  pbarNm: { fontSize: 17, fontWeight: 800, marginBottom: 4, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" },
  pbarLv: { fontSize: 11, fontWeight: 700, padding: "3px 11px", borderRadius: 99, background: "rgba(255,255,255,.62)" },
  balBox: { display: "flex", alignItems: "center", margin: "12px 18px 4px", background: C.card, borderRadius: 14, padding: "11px 13px", flexShrink: 0 },
  topupBtn: { marginLeft: "auto", background: C.ink, color: "#fff", border: "none", borderRadius: 99, padding: "7px 15px", fontSize: 11, fontWeight: 700, cursor: "pointer" },

  lines: { flex: "1 0 auto", padding: "0 18px", minHeight: 0 },
  linesEmpty: { color: C.gray3, fontSize: 13, textAlign: "center", padding: "20px 0" },
  lineitem: { display: "flex", alignItems: "center", gap: 8, padding: "9px 0" },
  lineNm: { fontSize: 15.5, fontWeight: 700, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" },
  lineAmt: { width: 62, textAlign: "right", fontWeight: 800, fontFamily: "'Segoe UI',sans-serif", flexShrink: 0 },
  qtyLock: { fontSize: 14, fontWeight: 800, color: C.gray2, minWidth: 56, textAlign: "center", flexShrink: 0 },
  stepBtn: { width: 26, height: 26, borderRadius: "50%", border: "none", background: "transparent", color: C.gray1, fontSize: 18, fontWeight: 700, lineHeight: 1, cursor: "pointer", display: "inline-flex", alignItems: "center", justifyContent: "center", fontFamily: "'Segoe UI',Arial,sans-serif", padding: 0 },

  payforBtn: { position: "relative", width: "100%", margin: "0 0 8px", border: "1.5px dashed #E3C9D2", background: "#fff", color: C.rose, borderRadius: 10, padding: 11, fontSize: 14, fontWeight: 700, cursor: "pointer", textAlign: "center" },
  caret: { position: "absolute", right: 13, top: "50%", transform: "translateY(-50%)", fontSize: 17, lineHeight: 1, transition: "transform .18s", display: "inline-block" },
  caretOpen: { transform: "translateY(-50%) rotate(90deg)" },
  payforList: { border: "1.5px solid #F0E0E5", borderRadius: 10, padding: 4, margin: "0 0 12px", background: "#FFFBFC" },
  payforItem: { display: "flex", alignItems: "center", gap: 9, padding: "9px 10px", borderRadius: 8, cursor: "pointer", fontSize: 13.5 },
  payforOn: { background: "#fff" },
  payforOff: { opacity: 0.45, cursor: "not-allowed" },
  pfCk: { width: 19, height: 19, borderRadius: "50%", border: "1.5px solid " + C.gray3, display: "flex", alignItems: "center", justifyContent: "center", fontSize: 11, color: "#fff", flexShrink: 0 },
  pfCkOn: { background: C.rose, borderColor: C.rose },
  pfAmt: { marginLeft: "auto", fontSize: 12, color: C.rose, fontWeight: 700, fontFamily: "'Segoe UI',sans-serif", flexShrink: 0 },

  checkoutbar: { padding: "14px 18px", flexShrink: 0, borderTop: "1px solid " + C.line },
  couponBtn: { width: "100%", margin: "0 0 12px", border: "1.5px dashed #E3C9D2", background: "transparent", color: C.rose, borderRadius: 10, padding: 11, fontSize: 14, fontWeight: 700, cursor: "pointer" },
  row: { display: "flex", alignItems: "center", fontSize: 14.5, color: C.gray1, fontWeight: 600, padding: "6px 0" },
  rowV: { marginLeft: "auto", fontWeight: 800, fontSize: 15.5, color: C.ink, fontFamily: "'Segoe UI',sans-serif" },
  tierTag: { display: "inline-block", marginLeft: 7, fontSize: 10.5, fontWeight: 800, color: C.ink, background: C.peach, borderRadius: 99, padding: "2px 8px" },
  changeLink: { color: C.rose, fontWeight: 700, fontSize: 11, marginLeft: 7, cursor: "pointer" },
  ptRow: { display: "flex", alignItems: "center", padding: "6px 0", minHeight: 32 },
  ptVal: { fontSize: 16, fontWeight: 800, color: C.rose, cursor: "pointer", borderBottom: "1.5px dashed " + C.rose, fontFamily: "'Segoe UI',sans-serif" },
  ptValOff: { color: C.gray2, borderBottomColor: C.gray3 },
  ptInput: { width: 86, border: "1.5px solid " + C.rose, borderRadius: 8, padding: "5px 8px", fontSize: 16, fontWeight: 800, textAlign: "right", fontFamily: "'Segoe UI',sans-serif", color: C.rose, outline: "none" },
  fullPt: { border: "none", background: C.peach, color: C.ink, borderRadius: 99, padding: "5px 12px", fontSize: 11.5, fontWeight: 800, cursor: "pointer" },
  topupSep: { borderTop: "1px solid " + C.line, margin: "8px 0 6px" },
  rmTopup: { marginLeft: 8, color: C.rose, fontSize: 11, cursor: "pointer", fontWeight: 700 },
  due: { display: "flex", alignItems: "center", margin: "10px 0" },
  dueV: { marginLeft: "auto", fontSize: 34, fontWeight: 900, letterSpacing: "-.5px", fontFamily: "'Segoe UI',sans-serif" },
  wayRow: { display: "flex", gap: 7, marginBottom: 10 },
  way: { flex: 1, textAlign: "center", border: "1.5px solid " + C.line, borderRadius: 10, padding: "9px 4px", fontSize: 13, fontWeight: 700, cursor: "pointer", background: "#fff" },
  wayOn: { borderColor: C.ink, background: C.ink, color: "#fff" },
  cashField: { display: "flex", alignItems: "center", gap: 10, marginBottom: 8 },
  cashInput: { flex: 1, border: "1.5px solid " + C.line, borderRadius: 10, padding: "10px 12px", fontSize: 17, textAlign: "right", fontWeight: 800, fontFamily: "'Segoe UI',sans-serif", minWidth: 0 },
  quickCash: { display: "flex", gap: 6, marginBottom: 8, flexWrap: "wrap" },
  quickBtn: { flex: 1, minWidth: 52, border: "1.5px solid " + C.line, background: "#fff", borderRadius: 9, padding: "8px 4px", fontSize: 13, fontWeight: 700, color: C.ink, cursor: "pointer" },
  changeRow: { display: "flex", justifyContent: "space-between", alignItems: "center", padding: "6px 0 10px", fontSize: 14, color: C.gray1, fontWeight: 600 },
  changeV: { fontSize: 19, color: C.rose, fontWeight: 900, fontFamily: "'Segoe UI',sans-serif" },
  payBtn: { width: "100%", background: C.ink, color: "#fff", border: "none", borderRadius: 12, padding: 14, fontSize: 15, fontWeight: 700, cursor: "pointer" },
  btnOff: { background: C.gray3, cursor: "not-allowed", opacity: 0.6 },

  badgeDone: { display: "flex", alignItems: "center", justifyContent: "center", gap: 10, padding: "24px 18px 22px", fontSize: 18, fontWeight: 900, color: C.ink },
  badgeCk: { width: 26, height: 26, borderRadius: "50%", background: C.rose, color: "#fff", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 15, fontWeight: 900, flexShrink: 0 },
  rsec: { padding: "0 18px" },
  rsecTop: { borderTop: "1px solid " + C.line, marginTop: 12, paddingTop: 12 },
  rsecLbl: { fontSize: 11, fontWeight: 800, color: C.gray2, letterSpacing: ".05em", marginBottom: 8 },
  rItem: { display: "flex", alignItems: "flex-start", padding: "7px 0", fontSize: 14.5, fontWeight: 700, color: C.ink },
  rQty: { color: C.gray2, fontWeight: 500, marginLeft: 5, fontSize: 13 },
  rItemV: { marginLeft: "auto", fontFamily: "'Segoe UI',sans-serif", fontWeight: 800 },
  rRow: { display: "flex", alignItems: "center", fontSize: 13.5, color: C.gray1, fontWeight: 500, padding: "5px 0" },
  rRowV: { marginLeft: "auto", fontWeight: 700, fontSize: 14, color: C.gray1, fontFamily: "'Segoe UI',sans-serif" },
  rTotal: { display: "flex", alignItems: "baseline", margin: "12px 0 2px" },
  rTotalV: { marginLeft: "auto", fontSize: 30, fontWeight: 900, letterSpacing: "-.5px", fontFamily: "'Segoe UI',sans-serif" },
  rChange: { display: "flex", justifyContent: "space-between", alignItems: "center", padding: "5px 0", fontSize: 13.5, color: C.gray1, fontWeight: 500 },
  rChangeHl: { fontSize: 20, color: C.rose, fontWeight: 900, fontFamily: "'Segoe UI',sans-serif" },
  rDivide: { borderTop: "1px dashed " + C.line, margin: "8px 0 6px" },
  paidbyNote: { background: C.card, borderRadius: 12, padding: 16, fontSize: 13.5, color: C.gray1, lineHeight: 1.8, textAlign: "center" },
  addonBtn: { width: "calc(100% - 36px)", margin: "14px 18px", background: C.ink, color: "#fff", border: "none", borderRadius: 12, padding: 13, fontSize: 14, fontWeight: 700, cursor: "pointer" },

  foot: { background: "#fff", borderTop: "1px solid " + C.line, padding: "12px 24px", display: "flex", alignItems: "center", flexShrink: 0 },
  carryBtn: { marginLeft: "auto", background: C.ink, color: "#fff", border: "none", borderRadius: 99, padding: "12px 28px", fontSize: 16, fontWeight: 500, cursor: "pointer" },

  mask: { position: "fixed", inset: 0, background: "rgba(46,43,44,.4)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 60 },
  modal: { width: 480, maxWidth: "92%", maxHeight: "86%", background: "#fff", borderRadius: 20, padding: "22px 24px", overflow: "auto", position: "relative" },
  modalX: { position: "absolute", top: 18, right: 20, width: 30, height: 30, borderRadius: "50%", background: C.idle, color: C.gray1, display: "flex", alignItems: "center", justifyContent: "center", cursor: "pointer" },
  searchBox: { width: "100%", border: "1.5px solid #E0DCD8", borderRadius: 12, padding: "10px 13px", fontSize: 15, fontWeight: 600, marginBottom: 12, boxSizing: "border-box" },
  mRow: { display: "flex", alignItems: "center", gap: 11, padding: "12px 10px", borderRadius: 12 },
  mNm: { fontSize: 15, fontWeight: 800, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" },
  mSub: { fontSize: 12, color: C.gray2, marginTop: 2 },

  topupNote: { fontSize: 12, color: C.gray1, margin: "-4px 0 16px", lineHeight: 1.6 },
  topupGrid: { display: "grid", gridTemplateColumns: "repeat(3,1fr)", gap: 9, marginBottom: 18 },
  topupOpt: { border: "1.5px solid " + C.line, borderRadius: 13, padding: "13px 0", textAlign: "center", cursor: "pointer" },
  topupOptOn: { borderColor: C.rose, background: "#FFF6F8" },
  topupNum: { fontSize: 17, fontWeight: 800, color: C.ink },
  topupBonus: { fontSize: 10, color: C.rose, marginTop: 3 },
  customMask: { position: "fixed", inset: 0, background: "rgba(46,43,44,.45)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 80, padding: 24 },
  customCard: { background: "#fff", borderRadius: 20, width: "100%", maxWidth: 300, padding: "22px 20px" },
  customInput: { width: "100%", fontSize: 18, fontWeight: 700, padding: "12px 14px", border: "1.5px solid " + C.line, borderRadius: 12, background: C.card, textAlign: "center", boxSizing: "border-box" },
  customBtn: { flex: 1, border: "none", borderRadius: 12, padding: 12, fontSize: 14, fontWeight: 700, cursor: "pointer" },
  couponItem: { display: "flex", alignItems: "center", gap: 11, padding: "13px 12px", border: "1.5px solid " + C.line, background: "#fff", borderRadius: 12, marginBottom: 8, cursor: "pointer" },
  couponOn: { borderColor: C.rose, background: "#FFF6F8" },
};
