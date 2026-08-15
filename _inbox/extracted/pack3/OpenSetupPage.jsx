import React, { useState, useEffect } from "react";
import { C } from "./shared.jsx";
import { listStakeLevels, openSession } from "./lib/api.js";

/* ============================================================
   開桌前置 · 決定這桌怎麼收費
   ------------------------------------------------------------
   問完六題後呼叫 open_session_tx 建立場次，再進結帳頁逐一收費。
   包桌人數與付款方式不在此決定 —— 客人還沒登記，問了也沒對象可選，
   改到結帳頁由店員邊加人邊處理。
   ============================================================ */

const PRIV_LABEL = { 120: "2 小時內", 300: "2–5 小時", 1440: "5 小時以上" };
const PRIV_PRICE = { 120: 400, 300: 600, 1440: 800 };

export default function OpenSetupPage({ table, staffId, onDone, onBack, flash }) {
  const [mode, setMode] = useState(null);          // matched | private
  const [rounds, setRounds] = useState(null);      // 2 | 3
  const [minutes, setMinutes] = useState(null);    // 120 | 300 | 1440
  const [kind, setKind] = useState("台麻");
  const [flower, setFlower] = useState("無花");
  const [stakeId, setStakeId] = useState(null);
  const [stakes, setStakes] = useState([]);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    listStakeLevels(table?.store_id).then((list) => {
      setStakes(list);
      // 預設帶入排序最前的級距，減少店員一次點擊
      if (list.length && !stakeId) setStakeId(list[0].id);
    });
  }, [table?.store_id]);

  const ready = mode && stakeId &&
    ((mode === "matched" && rounds) || (mode === "private" && minutes));

  async function submit() {
    if (!ready || busy) return;
    setBusy(true);
    const res = await openSession({
      tableId: table.id,
      mode,
      stakeLevelId: stakeId,
      rounds: mode === "matched" ? rounds : null,
      minutes: mode === "private" ? minutes : null,
      staffId,
      openMethod: "manual",
      // 冪等鍵：同一桌同一次設定重複送出不會開出兩張桌
      idempotencyKey: `open-${table.id}-${Date.now()}`,
    });
    setBusy(false);
    if (!res.ok) {
      flash?.(res.message || res.reason || "開桌失敗");
      return;
    }
    onDone({
      sessionId: res.session_id,
      table, mode, rounds, minutes, kind, flower,
      stakeLabel: stakes.find((s) => s.id === stakeId)?.label || "",
    });
  }

  const S = styles;

  return (
    <div style={S.wrap}>
      {/* 頂欄：左 logo + 桌號，右返回 */}
      <div style={S.top}>
        <div style={S.titlebar}>
          <span style={S.logo}>MIGI</span>
          <span style={S.no}>{table?.label}</span>
          <span style={S.sub}>開桌設定</span>
          <span style={S.back} onClick={onBack}>‹ 回到即時桌況</span>
        </div>
      </div>

      <div style={S.body}>
        <div style={S.inner}>
          <h2 style={S.h2}>這桌怎麼開</h2>
          <p style={S.lead}>選好之後進入結帳頁，逐一為客人收費</p>

          <Group label="模式">
            <div style={S.grid2}>
              <Opt on={mode === "matched"} onClick={() => { setMode("matched"); setMinutes(null); }}
                   title="配桌" desc="店家湊人 · 按將數收費" />
              <Opt on={mode === "private"} onClick={() => { setMode("private"); setRounds(null); }}
                   title="包桌" desc="客人自己揪團 · 按時段收費" />
            </div>
          </Group>

          {mode === "matched" && (
            <Group label="打幾將">
              <Chip on={rounds === 3} onClick={() => setRounds(3)}>3 將 · 每人 $150</Chip>
              <Chip on={rounds === 2} onClick={() => setRounds(2)}>2 將 · 每人 $100</Chip>
            </Group>
          )}

          {mode === "private" && (
            <Group label="預估時段">
              {[120, 300, 1440].map((m) => (
                <Chip key={m} on={minutes === m} onClick={() => setMinutes(m)}>
                  {PRIV_LABEL[m]} · ${PRIV_PRICE[m]}
                </Chip>
              ))}
            </Group>
          )}

          <Group label="遊戲規則">
            {["台麻", "美麻"].map((k) => (
              <Chip key={k} on={kind === k} onClick={() => setKind(k)}>{k}</Chip>
            ))}
          </Group>

          <Group label="花牌">
            {["無花", "有花"].map((f) => (
              <Chip key={f} on={flower === f} onClick={() => setFlower(f)}>{f}</Chip>
            ))}
          </Group>

          <Group label="想打多少積分">
            {stakes.map((s) => (
              <Chip key={s.id} on={stakeId === s.id} onClick={() => setStakeId(s.id)}>
                {s.label}
              </Chip>
            ))}
            {!stakes.length && <span style={S.empty}>載入中…</span>}
          </Group>

          {mode === "private" && minutes && (
            <div style={S.note}>
              整桌 <b>${PRIV_PRICE[minutes]}</b>
              <span style={{ color: C.gray2 }}>　人數與付款方式在結帳頁決定</span>
            </div>
          )}
        </div>
      </div>

      <div style={S.foot}>
        <button style={{ ...S.btn, ...(ready && !busy ? null : S.btnOff) }}
                disabled={!ready || busy} onClick={submit}>
          {busy ? "建立中…" : "開桌，開始收費"}
        </button>
      </div>
    </div>
  );
}

/* —— 小元件 —— */
function Group({ label, children }) {
  return (
    <div style={{ padding: "15px 0 0" }}>
      <p style={{ margin: "0 0 9px", fontSize: 15, fontWeight: 700 }}>{label}</p>
      <div style={{ display: "flex", flexWrap: "wrap" }}>{children}</div>
    </div>
  );
}

function Chip({ on, onClick, children }) {
  return (
    <span onClick={onClick} style={{
      display: "inline-block", border: `1.5px solid ${on ? C.rose : C.line}`,
      background: on ? "#FFF6F8" : "#fff", borderRadius: 11,
      padding: "11px 17px", margin: "0 8px 8px 0", cursor: "pointer",
      fontSize: 13.5, fontWeight: on ? 800 : 600, transition: ".12s",
    }}>{children}</span>
  );
}

function Opt({ on, onClick, title, desc }) {
  return (
    <div onClick={onClick} style={{
      border: `1.5px solid ${on ? C.rose : C.line}`, background: on ? "#FFF6F8" : "#fff",
      borderRadius: 13, padding: 15, cursor: "pointer", transition: ".12s",
    }}>
      <b style={{ display: "block", fontSize: 15 }}>{title}</b>
      <span style={{ display: "block", fontSize: 12, color: C.gray1, marginTop: 4 }}>{desc}</span>
    </div>
  );
}

const styles = {
  wrap: { flex: 1, display: "flex", flexDirection: "column", overflow: "hidden" },
  top: { background: "#fff", borderBottom: `1px solid ${C.line}`, flexShrink: 0, padding: "0 24px" },
  titlebar: { display: "flex", alignItems: "center", gap: 10, height: 72 },
  logo: { fontSize: 22, fontWeight: 900, letterSpacing: ".08em", paddingRight: 14, marginRight: 10, borderRight: `1px solid ${C.line}` },
  no: { fontSize: 22, fontWeight: 900, letterSpacing: ".05em", marginRight: 8 },
  sub: { fontSize: 13, color: C.gray1, fontWeight: 500 },
  back: { marginLeft: "auto", fontSize: 14, fontWeight: 700, color: C.gray1, cursor: "pointer", whiteSpace: "nowrap" },
  body: { flex: 1, overflowY: "auto", padding: "24px 22px 40px" },
  inner: { maxWidth: 700, margin: "0 auto" },
  h2: { fontSize: 18, margin: "0 0 4px" },
  lead: { fontSize: 13, color: C.gray1, margin: "0 0 18px" },
  grid2: { display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10, width: "100%" },
  note: { background: C.card, borderRadius: 12, padding: "13px 15px", fontSize: 12.5, color: C.gray1, lineHeight: 1.7, marginTop: 14 },
  empty: { fontSize: 13, color: C.gray3 },
  foot: { borderTop: `1px solid ${C.line}`, padding: "14px 22px", background: "#fff", flexShrink: 0 },
  btn: { width: "100%", maxWidth: 700, margin: "0 auto", display: "block", background: C.ink, color: "#fff", border: "none", borderRadius: 99, padding: 15, fontSize: 15, fontWeight: 700, cursor: "pointer" },
  btnOff: { opacity: .3, cursor: "not-allowed" },
};
