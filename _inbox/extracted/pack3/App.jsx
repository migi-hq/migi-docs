import React, { useState, useMemo, useEffect } from "react";
import TablePage from "./TablePage.jsx";
import OpenSetupPage from "./OpenSetupPage.jsx";
import OpenCheckoutPage from "./OpenCheckoutPage.jsx";
import { listTables, listStores, setTableActive } from "./lib/api.js";
import { getStoreId, setStoreId } from "./lib/supabase.js";

/* ============================================================
   MIGI 店員 POS · pos.migi.tw
   第二階段:即時桌況 → 開桌結帳 → 帶桌 真頁面互通 + 狀態流轉
   純前端假資料。視覺忠實套用 MIGI CIS。
   ============================================================ */

const C = {
  peach: "#FAD6DC", sakura: "#FFE7EE", rose: "#C2607A", ink: "#2E2B2C",
  gray1: "#7A7572", gray2: "#9A9491", gray3: "#B4AEA9",
  milk: "#EFE3DA", card: "#F8F7F6", white: "#FFFFFF",
  line: "#ECEAE9", idle: "#F2F0EE", clean: "#EAE5E0",
  green: "#4CA576",
};

// 離線預覽用的假資料；連上後端後由 list_tables_tx 取代
const SEED_TABLES_DEMO = [
  { no: "T1", status: "use", people: 4, dur: "01:32", round: "第 2 將", resvCount: 2 },
  { no: "T2", status: "use", people: 4, dur: "00:48", round: "進行中", resvCount: 0 },
  { no: "T3", status: "idle", resvCount: 1 },
  { no: "T4", status: "resv", resvTime: "19:30", resvWho: "小美 4 人", resvKind: "包桌" },
  { no: "T5", status: "use", people: 3, dur: "02:15", round: "待補位", short: true, resvCount: 1 },
  { no: "T6", status: "clean", cleanIn: "約 5 分後可用" },
  { no: "T7", status: "off", offText: "🔧 維修中" },
  { no: "T8", status: "idle", resvCount: 0 },
];

const MEMBERS = [
  { nick: "小明", rank: "金牌熊 II", title: "常勝軍", bal: 1200 },
  { nick: "阿華", rank: "白金熊 I", title: "雀神候補", bal: 800 },
  { nick: "美美", rank: "銅牌熊 III", title: "新星", bal: 450 },
  { nick: "阿強", rank: "金牌熊 I", title: "快手", bal: 900 },
  { nick: "小娟", rank: "鑽石熊 II", title: "大殺四方", bal: 2000 },
  { nick: "志豪", rank: "白金熊 III", title: "穩健派", bal: 600 },
];

const FEE = 150;
const BEAR_SVG = "<svg preserveAspectRatio=\"xMidYMid meet\" xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"97 88 1058 1058\"><path fill=\"#fcf1e8\" d=\"M747.5 153q4 1.1 8 2.1a324 324 0 0 1 38.3 12.2q10.7 3.8 21 8.7 4.6 2.3 9.4 4.3A439 439 0 0 1 950.5 264q8 7.1 15.4 14.8l5 5A279 279 0 0 1 987 301l2.6 3a441 441 0 0 1 54.9 80.7c11 20.2 20.8 41 28 62.9q1.5 4.7 3.5 9.3a392 392 0 0 1 23.7 94.4c16.3 103.7-4.5 209-83.4 347q-5 7-10.3 13.7l-2.1 2.8a507 507 0 0 1-30.4 35c-8 9-16.7 17-25.5 25.2l-2.8 2.6a297 297 0 0 1-19.6 16.1l-6.4 5.2a415 415 0 0 1-66.4 42.6l-7.6 4.1A443 443 0 0 1 759 1080a431 431 0 0 1-83 16.1l-2.7.3q-23.4 2.2-46.9 2H615a275 275 0 0 1-46.7-3.3 625 625 0 0 1-39.3-6l-2.2-.4c-70.1-13.2-137.6-46.2-193.8-89.6l-1.9-1.4a325 325 0 0 1-26-22c-12-10.5-24-21.4-34.4-33.6q-3.1-3.6-6.4-7.1-7.8-8.7-14.8-18l-4.9-6.2A456 456 0 0 1 202 845l-1.3-2.4a439 439 0 0 1-31-72.1C140.5 684.4 139.5 590 161 502l1.3-5.5A439 439 0 0 1 190 417l1.5-3.2a413 413 0 0 1 48.2-82.1l5.7-7.6A413 413 0 0 1 286 278l10.8-10.9 1.5-1.5c49.2-49.5 117.1-86.7 183.6-107l4.3-1.3A464 464 0 0 1 590 138l2.1-.2c51.6-4 105.6 1.1 155.4 15.2\"/><path fill=\"#f8c7c5\" d=\"M747.5 153q4 1.1 8 2.1a324 324 0 0 1 38.3 12.2q10.7 3.8 21 8.7 4.6 2.3 9.4 4.3A439 439 0 0 1 950.5 264q8 7.1 15.4 14.8l5 5A279 279 0 0 1 987 301l2.6 3a441 441 0 0 1 54.9 80.7c11 20.2 20.8 41 28 62.9q1.5 4.7 3.5 9.3a392 392 0 0 1 23.7 94.4c16.3 103.7-4.5 209-83.4 347q-5 7-10.3 13.7l-2.1 2.8a507 507 0 0 1-30.4 35c-8 9-16.7 17-25.5 25.2l-2.8 2.6a297 297 0 0 1-19.6 16.1l-6.4 5.2a381 381 0 0 1-33.7 24l-2.5 1.5-2.3 1.4-2 1.3c-1.7.9-1.7.9-3.7.9q-1.3-6-1.5-12.1A299 299 0 0 0 852 920l-.8-1.9a255 255 0 0 0-48.6-76.3q-4.4-4.8-8.6-9.8l2-.9c19.4-8.2 19.4-8.2 38-18.1l2.2-1.3q17.5-10.3 32.8-23.7l1.7-1.4c30.7-26.8 48.3-60.2 57.3-99.6l.5-2.3C932 670 931.4 655 931 640v-2.4c-.8-32.9-12.5-65-26-94.6q4.8-5.7 9.8-11c19.8-22.3 29-51.8 27.4-81.2l-.2-2.8-.1-2.3c-1.7-25.5-16.3-50.2-34.4-67.6a118 118 0 0 0-45-24.7l-2.6-.8A101 101 0 0 0 766 380l-2.2 2a72 72 0 0 0-11.8 15l-4.6-1.3-2.5-.8c-2.9-.9-2.9-.9-6-2.3q-7.7-3.1-15.8-5l-3.4-1-13.8-3.8q-13.5-3.4-27-5.5l-3.8-.6a309 309 0 0 0-101.1.3l-3.6.6c-24 4.2-46.7 10.7-69.4 19.4l-3 1-1.8-2.5A109 109 0 0 0 467 367l-2.4-1.5a103 103 0 0 0-76.5-12.7 110.2 110.2 0 0 0-78.8 134.6c2.1 7.5 5.3 14.6 8.7 21.6l1.4 3a86 86 0 0 0 22.5 28.1c3 2.6 3 2.6 3.4 5.6l-4.9 11.1c-2.6 6-4.4 12-6.4 18.2l-1.5 4.3Q330 587 328 595l-.8 3c-12.7 49.6-8 101.4 17.8 146a190 190 0 0 0 56 58.3c9.1 6.4 18.8 11.8 28.8 17l3.3 1.7q11.1 5.7 22.9 9.9c0 3 0 3-2.3 5.3l-3.1 2.7a119 119 0 0 0-15.6 17l-2.4 3a250 250 0 0 0-37.6 69l-1 2.5q-4.2 11.6-7 23.4l-.5 2a353 353 0 0 0-9.5 51.1l-.3 2.6-1.7 17.4a45 45 0 0 1-9.5-4.8l-2.6-1.7-2.7-1.9-2.8-1.9A466 466 0 0 1 333 999l-1.9-1.4a325 325 0 0 1-26-22c-12-10.5-24-21.4-34.4-33.6q-3.1-3.6-6.4-7.1-7.8-8.7-14.8-18l-4.9-6.2A456 456 0 0 1 202 845l-1.3-2.4a439 439 0 0 1-31-72.1C140.5 684.4 139.5 590 161 502l1.3-5.5A439 439 0 0 1 190 417l1.5-3.2a413 413 0 0 1 48.2-82.1l5.7-7.6A413 413 0 0 1 286 278l10.8-10.9 1.5-1.5c49.2-49.5 117.1-86.7 183.6-107l4.3-1.3A464 464 0 0 1 590 138l2.1-.2c51.6-4 105.6 1.1 155.4 15.2\"/><path fill=\"#f6d7ca\" d=\"M406.3 403.6h2.7c14.8.4 25.8 6 37 15.4 3 3.5 3 3.5 3 6q-3.4 2.5-7 4.8a244 244 0 0 0-53.3 47.3l-2.3 2.8-9 11.7q-3.2 4.5-7.4 8.4a55 55 0 0 1-16.4-39c0-10 .4-18 5.4-27l1.6-3q11.4-19.4 33-26.4c4.2-1 8.3-1 12.6-1M840.3 403.7h2.6c13.2 0 25.5 5.2 35.1 14.1a64 64 0 0 1 16 29.6c4.4 17-1.9 32-10 46.6l-3 4c-4-1.3-4.9-3.3-7.4-6.6A243 243 0 0 0 827 443l-2.3-1.8C813 432.3 813 432.3 801 424c.7-5 4.2-7 8-10a52 52 0 0 1 31.3-10.3\"/><path fill=\"#5a3f34\" d=\"M651 647c3.6 2.8 5.7 5.3 6.6 9.8.3 6.4-.6 10.6-4.8 15.5L651 674l-1.6 1.7c-4.7 4.4-10.8 8.3-17.4 8.3.3 9.3.3 9.3 5 17 4.6 4 8.2 5.7 14.3 6.3 4.5-.4 8-1.7 11.7-4.3l2-3c3.1-.4 5.1-.5 7.9 1.1 1.8 3 1.8 4.5 1.1 7.9-5 5.9-10.8 9.6-18.5 10.3-11.8.4-18.5-2-27-10L627 708a37 37 0 0 0-7.8 5c-8.6 6.3-15.5 6.9-26.2 6a26 26 0 0 1-14-9c-1.1-3.7-1.1-3.7-1-7 1-2 1-2 3-3 3.3-.4 5.2-.6 7.9 1.4 1.1 1.6 1.1 1.6 1.1 3.6 4.6 2.4 9 2.8 14 2 6.3-2.2 11.7-5.1 15-11q1-6 1-12l-2.4-.1c-7.8-2-14.6-7.7-19.6-13.9a21 21 0 0 1-3-15c2.5-6.5 8-9 14-11.8a51 51 0 0 1 42 3.8\"/><path fill=\"#5c4035\" d=\"M744.2 598.7A26 26 0 0 1 756 612c.9 7.2.9 13.5-3.6 19.4-3.7 4.1-7.6 7.3-13.2 8-6.7 0-10.8-.2-16.2-4.4-5-5-7.3-9.2-7.4-16.2 0-6.3 1.1-10.2 5.4-14.8l1.7-1.8c6-5.5 13.9-6 21.5-3.5\"/><path fill=\"#5c4136\" d=\"M526 599.7c4.8 3 9.2 7.9 11 13.3.7 7 .7 12.6-3.5 18.3-4 4.6-8.3 8.3-14.6 9-6.5.2-10.5-1.3-15.5-5.5-5.8-6.7-7.1-11-6.8-19.8.9-6.8 5.6-10.3 10.5-14.6 5.4-4 13-3 18.9-.7\"/><path fill=\"#62493e\" d=\"M587 700c1.9 2 1.9 2 3 4l-9-1-1 7c-2-2-2-2-2.3-4.4.3-2.6.3-2.6 1.4-4.4 2.8-1.8 4.7-1.7 7.9-1.2\"/><path fill=\"#61473d\" d=\"M595 655h2l.1 2.1.3 2.8.2 2.7c.2 2.6.2 2.6 2.4 4.4-.4 2.1-.4 2.1-1 4a24 24 0 0 1-4-16\"/><path fill=\"#f1e9e2\" d=\"M656 666h1c.4 2.1.4 2.1 0 5a46 46 0 0 1-6 6l-3-1 1.5-1.7 2-2.2 1.9-2.2c1.7-1.8 1.7-1.8 2.6-3.9\"/><path fill=\"#6a5145\" d=\"m520 598 2 2-2 .2-2.8.2-2.7.3c-2.6.2-2.6.2-5.5 1.3l-2-2c4.5-2.3 8-2.3 13-2\"/><path fill=\"#63493f\" d=\"M662 707c-2.5 2.5-3.7 2.4-7.1 2.6l-2.8.3-2.1.1-1-2 4.3-1 2.3-.7c2.5-.3 4 0 6.4.7\"/><path fill=\"#6e5348\" d=\"m732 598-1 3c-3.6 1.7-3.6 1.7-7 3v-3c2.9-2.1 4.4-3 8-3\"/></svg>";

function Bear({ size = 40, ring = true }) {
  return (
    <div style={{ width: size, height: size, borderRadius: "50%", background: ring ? "#EAD7CC" : "transparent", overflow: "hidden", flexShrink: 0, display: "flex", alignItems: "center", justifyContent: "center" }}
      dangerouslySetInnerHTML={{ __html: BEAR_SVG }} />
  );
}

const NAV = [
  { grp: "現場", items: [ { key: "board", label: "即時桌況" }, { key: "queue", label: "配桌列表" } ]},
  { grp: "服務", items: [ { key: "fnb", label: "點餐出餐" }, { key: "coupon", label: "券核銷" }, { key: "resv", label: "預約" } ]},
  { grp: "管理", items: [ { key: "stock", label: "庫存" }, { key: "report", label: "報表" }, { key: "close", label: "交班日結" } ]},
];

const STAFF = "小美";   // 之後由 staff 記錄帶入

function Sidebar({ page, setPage }) {
  return (
    <div style={{ width: 168, flexShrink: 0, background: C.white, display: "flex", flexDirection: "column", padding: "20px 14px", borderRight: `1px solid ${C.line}` }}>
      <div style={{ fontSize: 21, fontWeight: 800, letterSpacing: 2, padding: "0 10px 30px" }}>MIGI</div>
      {NAV.map((g, gi) => (
        <div key={g.grp} style={gi === 0 ? { marginTop: 4 } : { marginTop: 10, paddingTop: 10, borderTop: `1px solid ${C.line}` }}>
          {g.items.map((it) => {
            const on = page === it.key;
            return (
              <div key={it.key} onClick={() => setPage(it.key)}
                style={{ padding: "9px 12px", borderRadius: 9, cursor: "pointer", fontSize: 16, fontWeight: on ? 600 : 500, marginBottom: 1, color: C.ink, background: on ? C.peach : "transparent" }}
                onMouseEnter={(e) => { if (!on) e.currentTarget.style.background = "#F7F5F3"; }}
                onMouseLeave={(e) => { if (!on) e.currentTarget.style.background = "transparent"; }}
              >{it.label}</div>
            );
          })}
        </div>
      ))}
      <div style={{ marginTop: "auto", paddingTop: 12, borderTop: `1px solid #F0EEEC`, fontSize: 15, color: C.gray1 }}>
        店員：<b style={{ color: C.ink }}>{STAFF}</b>
        <div style={{ fontSize: 14, color: C.rose, cursor: "pointer", marginTop: 4 }}>交班登出 ›</div>
      </div>
    </div>
  );
}

function TopBar({ title, right, back, store }) {
  return (
    <div style={{ background: C.white, padding: "14px 24px", display: "flex", justifyContent: "space-between", alignItems: "center", borderBottom: `1px solid ${C.line}`, flexShrink: 0 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
        {back && <span onClick={back} style={{ fontSize: 15, fontWeight: 500, color: C.ink, cursor: "pointer" }}>‹ 即時桌況</span>}
        <div style={{ fontSize: 21, fontWeight: 700 }}>
          {title} <span style={{ fontSize: 16, fontWeight: 400, color: C.gray1 }}>{store ? " · " + store : ""}</span>
        </div>
      </div>
      <div>{right}</div>
    </div>
  );
}

function Pill({ bg, color, children }) {
  return <span style={{ background: bg, color, fontSize: 14, fontWeight: 500, padding: "6px 13px", borderRadius: 99, whiteSpace: "nowrap" }}>{children}</span>;
}

// 已進行時長：由 started_at 即時計算，不存在資料庫（避免每分鐘寫入）
function durOf(startedAt) {
  if (!startedAt) return "";
  const ms = Date.now() - new Date(startedAt).getTime();
  if (ms < 0) return "00:00";
  const m = Math.floor(ms / 60000);
  return String(Math.floor(m / 60)).padStart(2, "0") + ":" + String(m % 60).padStart(2, "0");
}

function BoardPage({ tables, openTable, enterTable, store, storeList, onStore, loading, onRefresh }) {
  const useCount = tables.filter((t) => t.status === "use").length;
  const idleCount = tables.filter((t) => t.status === "idle").length;
  const total = tables.length;

  // 依區分組，區內照 sort_order（RPC 已排序）
  const areas = useMemo(() => {
    const g = {};
    tables.forEach((t) => { const k = t.area || "其他"; (g[k] = g[k] || []).push(t); });
    return Object.keys(g).sort().map((k) => [k, g[k]]);
  }, [tables]);

  const right = (
    <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
      <Pill bg={C.peach} color={C.ink}>使用 {useCount}/{total}</Pill>
      <Pill bg={C.idle} color={C.gray1}>空桌 {idleCount}</Pill>
      <span onClick={onRefresh} style={{ fontSize: 14, color: C.rose, cursor: "pointer", fontWeight: 600 }}>
        {loading ? "更新中…" : "重新整理"}
      </span>
    </div>
  );

  return (
    <div style={{ flex: 1, display: "flex", flexDirection: "column", overflow: "hidden" }}>
      <TopBar title="即時桌況" right={right} store={store && store.name} />
      <div style={{ flex: 1, overflow: "auto", padding: "20px 24px" }}>
        {/* 門市選擇：Auth 接上後改由 staff.store_id 自動決定 */}
        {storeList.length > 1 && (
          <div style={{ display: "flex", gap: 8, marginBottom: 18, alignItems: "center" }}>
            <span style={{ fontSize: 14, color: C.gray1 }}>門市</span>
            {storeList.map((s) => (
              <span key={s.id} onClick={() => onStore(s)}
                style={{ padding: "6px 14px", borderRadius: 99, fontSize: 14, fontWeight: 600, cursor: "pointer",
                  background: store && store.id === s.id ? C.ink : C.white,
                  color: store && store.id === s.id ? "#fff" : C.gray1,
                  border: `1px solid ${store && store.id === s.id ? C.ink : C.line}` }}>{s.name}</span>
            ))}
          </div>
        )}

        {!tables.length && !loading && (
          <p style={{ textAlign: "center", color: C.gray2, fontSize: 15, padding: "60px 0" }}>
            {store ? "這間門市尚未建立桌位" : "請先選擇門市"}
          </p>
        )}

        {areas.map(([area, list]) => (
          <div key={area} style={{ marginBottom: 22 }}>
            <div style={{ fontSize: 15, fontWeight: 700, color: C.gray1, marginBottom: 10 }}>
              {area} 區 <span style={{ fontWeight: 400, color: C.gray2 }}>{list.length} 桌</span>
            </div>
            <div style={{ display: "grid", gridTemplateColumns: "repeat(5, 1fr)", gap: 12 }}>
              {list.map((t) => <TableCard key={t.id} t={t} openTable={openTable} enterTable={enterTable} />)}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function TableCard({ t, openTable, enterTable }) {
  const base = { borderRadius: 14, padding: "14px 16px", minHeight: 104, display: "flex", flexDirection: "column", cursor: "pointer" };
  const no = t.label;
  const stPill = (bg, color, txt) => (
    <span style={{ background: bg, color: color || C.ink, borderRadius: 99, padding: "3px 11px", fontSize: 13, fontWeight: 500, alignSelf: "flex-start", lineHeight: 1.4, whiteSpace: "nowrap" }}>{txt}</span>
  );
  const numStyle = { fontSize: 26, fontWeight: 800, color: C.ink, letterSpacing: 1 };

  if (t.status === "use") {
    const short = t.players > 0 && t.players < (t.seats || 4);
    return (
      <div style={{ ...base, background: C.peach }} onClick={() => enterTable(t)}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start" }}>
          <span style={numStyle}>{no}</span>
          {stPill("rgba(255,255,255,.6)", C.ink, "使用中")}
        </div>
        <div style={{ fontSize: 15, marginTop: 8, fontWeight: 500 }}>
          {t.players} 人{short && <span style={{ color: C.rose }}> · 差 {(t.seats || 4) - t.players} 位</span>}
        </div>
        <div style={{ fontSize: 13, marginTop: 3, color: C.gray1 }}>{durOf(t.started_at)}</div>
      </div>
    );
  }

  if (t.status === "idle") {
    return (
      <div style={{ ...base, background: C.white, border: `1.5px solid ${C.line}` }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start" }}>
          <span style={numStyle}>{no}</span>
          {stPill(C.idle, C.gray1, "空桌")}
        </div>
        <button onClick={(e) => { e.stopPropagation(); openTable(t); }}
          style={{ marginTop: "auto", background: C.ink, color: "#fff", border: "none", borderRadius: 99, padding: "8px 0", fontSize: 14, fontWeight: 700, cursor: "pointer" }}>＋ 開桌</button>
      </div>
    );
  }

  // 停用（維修中等）
  return (
    <div style={{ ...base, background: C.idle, opacity: 0.75 }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start" }}>
        <span style={{ ...numStyle, color: C.gray2 }}>{no}</span>
        {stPill("#E4E0DD", C.gray1, "停用")}
      </div>
      <div style={{ fontSize: 13, marginTop: 8, color: C.gray1 }}>{t.note || "暫停使用"}</div>
    </div>
  );
}

function QueuePage({ flash }) {
  const [queue, setQueue] = useState([
    { id: "q1", src: "off", staff: "小花", stake: "100/50", rule: "台麻無花", wait: "8 分鐘", assigned: null,
      seats: [{ n: "小明", real: true }, { n: "阿強", real: true }, { n: "客人 C", real: false }, null] },
    { id: "q2", src: "cus", by: "美美", stake: "100/50", rule: "台麻無花", wait: "3 分鐘", assigned: null,
      seats: [{ n: "美美", real: true }, { n: "小華", real: true }, null, null] },
    { id: "q3", src: "off", staff: "小花", stake: "300/100", rule: "台麻無花", wait: "12 分鐘", assigned: "T4",
      seats: [{ n: "阿華", real: true }, { n: "客人 A", real: false }, { n: "客人 B", real: false }, { n: "大雄", real: true }] },
    { id: "q4", src: "cus", by: "小娟", stake: "100/50", rule: "台麻無花", wait: "15 分鐘", assigned: null,
      seats: [{ n: "小娟", real: true }, { n: "阿明", real: true }, { n: "志豪", real: true }, { n: "客人 A", real: false }] },
  ]);
  const [filter, setFilter] = useState("ing");
  const FILTERS = [{ k: "all", label: "全部" }, { k: "ing", label: "配桌中" }, { k: "done", label: "已完成" }];

  const pass = (q) => {
    const filled = q.seats.filter(Boolean).length;
    const done = filled === 4;
    if (filter === "all") return true;
    if (filter === "ing") return !done;
    if (filter === "done") return done;
    return true;
  };
  const shown = queue.filter(pass);

  const right = (
    <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
      <Pill bg={C.rose} color="#fff">待成桌 3 桌</Pill>
      <button onClick={() => flash("開一筆官方配桌，進佇列等湊人")}
        style={{ border: "none", borderRadius: 99, padding: "8px 16px", fontSize: 13, fontWeight: 700, cursor: "pointer", background: C.ink, color: "#fff" }}>＋ 官方開桌</button>
    </div>
  );

  return (
    <div style={{ flex: 1, display: "flex", flexDirection: "column", overflow: "hidden" }}>
      <TopBar title="配桌列表" right={right} />
      {/* 篩選 pill */}
      <div style={{ padding: "14px 24px 0", display: "flex", gap: 8, flexShrink: 0 }}>
        {FILTERS.map((f) => {
          const on = filter === f.k;
          return (
            <div key={f.k} onClick={() => setFilter(f.k)}
              onMouseEnter={(e) => { if (!on) e.currentTarget.style.borderColor = C.peach; }}
              onMouseLeave={(e) => { if (!on) e.currentTarget.style.borderColor = "#E8E4E1"; }}
              style={{ borderRadius: 99, padding: "7px 18px", fontSize: 13, fontWeight: 700, cursor: "pointer", border: `1.5px solid ${on ? C.peach : "#E8E4E1"}`, background: on ? C.peach : "#fff", color: on ? C.ink : "#8A857F", transition: ".15s" }}>{f.label}</div>
          );
        })}
      </div>
      {/* 清單 */}
      <div style={{ flex: 1, overflow: "auto", padding: "14px 24px 40px" }}>
        {shown.length === 0
          ? <p style={{ textAlign: "center", color: C.gray3, fontSize: 13, padding: "40px 0" }}>目前沒有這類配桌</p>
          : shown.map((q) => <QueueCard key={q.id} q={q} flash={flash} />)}
      </div>
    </div>
  );
}

function QueueCard({ q, flash }) {
  const filled = q.seats.filter(Boolean).length;
  const done = filled === 4;
  const srcLabel = q.src === "off" ? "官方開桌" : "客人開桌";
  const byNote = q.src === "cus" ? `· 由 ${q.by} 在 App 建立` : `· 由 店員 ${q.staff || "小花"} 建立`;

  let statusNode;
  if (!done) statusNode = <span style={{ marginLeft: "auto", fontSize: 13, fontWeight: 700, color: C.rose }}>配桌中 · 還差 {4 - filled} 人</span>;
  else if (q.assigned) statusNode = <span style={{ marginLeft: "auto", fontSize: 13, fontWeight: 700, color: C.ink }}>已完成 · 座位 {q.assigned}</span>;
  else statusNode = <span style={{ marginLeft: "auto", fontSize: 13, fontWeight: 700, color: C.rose }}>目前客滿 · 等待空桌中</span>;

  return (
    <div style={{ background: "#fff", border: `1px solid ${C.line}`, borderRadius: 14, padding: "14px 16px", marginBottom: 12, position: "relative" }}>
      {/* head */}
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 12, flexWrap: "wrap" }}>
        <span style={{ borderRadius: 99, fontSize: 11, fontWeight: 700, padding: "3px 10px", background: q.src === "off" ? C.ink : C.peach, color: q.src === "off" ? "#fff" : C.ink }}>{srcLabel}</span>
        <span style={{ fontSize: 13, fontWeight: 700, color: C.ink }}>{q.stake}</span>
        <span style={{ fontSize: 12, color: C.gray2 }}>{q.rule}</span>
        <span style={{ fontSize: 12, color: C.gray2 }}>{byNote}</span>
        <span style={{ marginLeft: "auto", fontSize: 13, fontWeight: 700, color: C.rose }}>{filled}/4</span>
      </div>
      {/* 四座位 */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(4, 1fr)", gap: 8 }}>
        {[0, 1, 2, 3].map((i) => {
          const s = q.seats[i];
          if (!s) {
            return (
              <div key={i} onClick={() => flash("開抽屜：查會員 / 找候補 / 客人ABC佔位")}
                onMouseEnter={(e) => { e.currentTarget.style.borderColor = C.peach; }}
                onMouseLeave={(e) => { e.currentTarget.style.borderColor = "#D8D4D0"; }}
                style={{ border: "1.5px dashed #D8D4D0", borderRadius: 10, padding: 10, minHeight: 56, display: "flex", alignItems: "center", justifyContent: "center", fontSize: 13, color: C.gray3, cursor: "pointer", transition: ".15s" }}>＋ 加人</div>
            );
          }
          const real = s.real;
          return (
            <div key={i} style={{ border: `1.5px solid ${real ? C.peach : "#E8DFD6"}`, borderRadius: 10, padding: 10, minHeight: 56, display: "flex", flexDirection: "row", alignItems: "center", gap: 9, fontSize: 13, background: real ? "#FDF0F3" : "#FBF7F3", color: real ? C.ink : "#A88B6E" }}>
              {real
                ? <div style={{ width: 34, height: 34, borderRadius: "50%", background: "#EAD7CC", overflow: "hidden", flexShrink: 0, display: "flex", alignItems: "center", justifyContent: "center" }} dangerouslySetInnerHTML={{ __html: BEAR_SVG }} />
                : <div style={{ width: 34, height: 34, borderRadius: "50%", background: "#E8DFD6", display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0, fontSize: 16, color: "#A88B6E" }}>?</div>}
              <div style={{ fontWeight: 700, lineHeight: 1.2 }}>{s.n}</div>
            </div>
          );
        })}
      </div>
      {/* foot */}
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 12 }}>
        <span style={{ fontSize: 12, color: C.gray2 }}>已等 {q.wait}</span>
        {statusNode}
      </div>
    </div>
  );
}

function Placeholder({ label }) {
  return (
    <div style={{ flex: 1, display: "flex", flexDirection: "column", overflow: "hidden" }}>
      <TopBar title={label} right={null} />
      <div style={{ flex: 1, display: "flex", alignItems: "center", justifyContent: "center", color: C.gray2 }}>
        <div style={{ textAlign: "center" }}>
          <div style={{ fontSize: 17, fontWeight: 500, color: C.gray1 }}>{label}</div>
          <div style={{ fontSize: 15, marginTop: 6 }}>下一階段建置</div>
        </div>
      </div>
    </div>
  );
}

function Toast({ msg }) {
  if (!msg) return null;
  return <div style={{ position: "absolute", bottom: 26, left: "50%", transform: "translateX(-50%)", background: C.ink, color: "#fff", padding: "11px 22px", borderRadius: 99, fontSize: 16, fontWeight: 500, zIndex: 40, whiteSpace: "nowrap" }}>{msg}</div>;
}

export default function App() {
  const [page, setPage] = useState("board");
  const [openCtx, setOpenCtx] = useState(null);
  const [setupTable, setSetupTable] = useState(null);   // 開桌設定頁的目標桌
  const [detailNo, setDetailNo] = useState(null);
  const [tables, setTables] = useState([]);
  const [stores, setStores] = useState([]);
  const [store, setStore] = useState(null);
  const [loading, setLoading] = useState(false);
  const [toast, setToast] = useState("");
  const flash = (m) => { setToast(m); setTimeout(() => setToast(""), 2200); };

  // 載入門市清單，並還原上次選擇的門市
  useEffect(() => {
    listStores().then((list) => {
      setStores(list);
      const saved = getStoreId();
      const hit = list.find((s) => s.id === saved) || list[0] || null;
      if (hit) { setStore(hit); setStoreId(hit.id); }
    });
  }, []);

  const refresh = React.useCallback(async (sid) => {
    const id = sid || (store && store.id);
    if (!id) return;
    setLoading(true);
    try { setTables(await listTables(id)); } finally { setLoading(false); }
  }, [store]);

  // 切換門市或進入桌況頁時載入；桌況每 30 秒自動更新
  useEffect(() => {
    if (!store) return;
    refresh(store.id);
    const iv = setInterval(() => { if (page === "board") refresh(store.id); }, 30000);
    return () => clearInterval(iv);
  }, [store, page, refresh]);

  const pickStore = (s) => { setStore(s); setStoreId(s.id); };

  const labelOf = useMemo(() => {
    const map = {}; NAV.forEach((g) => g.items.forEach((it) => (map[it.key] = it.label))); return map;
  }, []);

  const DETAIL_PLAYERS = ["小明", "阿華", "美美", "阿強"].map((n) => { const m = MEMBERS.find((x) => x.nick === n); return { id: m.nick, nick: m.nick, rank: m.rank, title: m.title, bal: m.bal, tier: m.rank, rate: 1 }; });
  // 開桌流程：桌況 → 開桌設定（建立 session）→ 結帳頁（逐一收費）→ 帶桌
  const openTable = (t) => { setSetupTable(t); setPage("setup"); };
  const onSetupDone = (ctx) => { setOpenCtx(ctx); setSetupTable(null); setPage("open"); };
  const enterTable = (t) => { setDetailNo(t.label); setPage("detail"); };

  const onCarried = (no) => {
    setOpenCtx(null); setPage("board"); refresh();
    flash(`${no} 已帶桌`);
  };

  const backToBoard = () => { setOpenCtx(null); setSetupTable(null); setDetailNo(null); setPage("board"); };

  let body;
  if (page === "board") body = <BoardPage tables={tables} openTable={openTable} enterTable={enterTable}
    store={store} storeList={stores} onStore={pickStore} loading={loading} onRefresh={() => refresh()} />;
  else if (page === "setup" && setupTable) body = <OpenSetupPage table={setupTable} staffId={null}
    onDone={onSetupDone} onBack={backToBoard} flash={flash} />;
  else if (page === "open" && openCtx) body = <OpenCheckoutPage ctx={openCtx} staffId={null}
    onCarried={onCarried} onBack={backToBoard} flash={flash} />;
  else if (page === "detail" && detailNo) body = <TablePage ctx={{ table: detailNo, stage: "playing", players: DETAIL_PLAYERS }} back={backToBoard} flash={flash} />;
  else if (page === "queue") body = <QueuePage flash={flash} />;
  else body = <Placeholder label={labelOf[page] || page} />;

  return (
    <div style={{ height: "100vh", background: C.card, fontFamily: '-apple-system, "PingFang TC", "Noto Sans TC", "Microsoft JhengHei", sans-serif', color: C.ink, display: "flex", boxSizing: "border-box" }}>
      <div style={{ width: "100%", height: "100%", background: C.card, overflow: "hidden", display: "flex", position: "relative" }}>
        {!(page === "setup" || page === "open") && (
          <Sidebar page={page === "detail" ? "board" : page}
                   setPage={(p) => { setOpenCtx(null); setSetupTable(null); setPage(p); }} />
        )}
        {body}
        <Toast msg={toast} />
      </div>
    </div>
  );
}
