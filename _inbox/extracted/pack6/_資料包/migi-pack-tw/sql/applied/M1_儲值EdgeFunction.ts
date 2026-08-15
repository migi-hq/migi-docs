// ============================================================
// MIGI M1 — 錢包 Edge Function: 儲值 (wallet-topup)
// 部署：Supabase Dashboard → Edge Functions → 新增 wallet-topup → 貼上
// 基石：⑦ 並發鎖(FOR UPDATE) ⑧ 冪等 ⑨ 雙邊錢流 ⑩ 狀態 ⑬ 金額方向
// 做法三：wallet_txns 為真相，wallets.balance 為快取，同一交易內一起更新
// ============================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req) => {
  try {
    const { member_id, amount, idempotency_key, external_ref, store_id } = await req.json();

    // 參數檢查
    if (!member_id || !amount || amount <= 0 || !idempotency_key) {
      return json({ error: "member_id / amount(>0) / idempotency_key 必填" }, 400);
    }

    // service_role client（繞過 RLS，改錢只能後端，基石⑱）
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // 用 RPC 在單一交易內完成（並發鎖 + 冪等 + 雙邊更新）
    const { data, error } = await supabase.rpc("wallet_topup_tx", {
      p_member_id: member_id,
      p_amount: amount,
      p_idempotency_key: idempotency_key,
      p_external_ref: external_ref ?? null,
      p_store_id: store_id ?? null,
    });

    if (error) return json({ error: error.message }, 400);
    return json({ ok: true, ...data });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status, headers: { "Content-Type": "application/json" },
  });
}
