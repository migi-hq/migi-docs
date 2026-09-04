/* ============================================================
   補驗：讀取收緊有沒有誤傷（⑤⑥⑦ 三格）
   2026-09-04 · MIGI · 唯讀，一列都不寫

   ── 為什麼有這一份 ──────────────────────────────────
   `2026-09-04_敏感表的讀取收緊到總部.sql` 跑完 8 格裡有 3 格紅的，
   而**三格全部是驗證段自己寫錯，policy 是對的**：

   | | 我寫的 | 為什麼錯 |
   |---|---|---|
   | ⑤⑥ | 用 `99999999-…` 讀 products／stores | 那是**不存在的身分** ⇒ `current_org_id()` 回 null ⇒ `org_id = null` ⇒ 0 列。**那正是 org 級 policy 正常運作的樣子** |
   | ⑦ | `get_wallet_tx(v_org, v_mid)` | 實際簽名是 **`(p_member_id uuid, p_txn_limit integer)`** —— 沒有 org 參數。⇒ 找不到匹配的函式 ⇒ 拋錯 |

   🔴 **⑦ 最危險**：「函式簽名不對」的症狀跟「RLS 打壞了 DEFINER」
     **看起來一模一樣**，而後者代表會員 App 垮掉。
     差一點就去改一個完全正確的 policy（同硬規則 3.56）。
   🎯 根因是硬規則 3：**我猜了函式簽名。** 系統裡很多 RPC 是
     `(p_org_id, p_member_id)` 的形狀，我就照那個形狀補了一個 org 進去 ——
     **「其他函式長這樣」不是證據。**

   ── ⚠ 這一支要在 Dashboard 跑，不能走 MCP ──────────────
   它需要 `set local role authenticated`，而 MCP 的
   `supabase_read_only_user` **沒有權限 set role**
   （`42501: permission denied to set role "authenticated"`）。
   ⚠ 但它**仍然是唯讀的** —— 只有 SELECT 與函式呼叫，一列都不寫。
   ============================================================ */

do $$
declare
  v_out text := ''; v_admin uuid; v_mid uuid; v_n int; v_bal int;
  v_org uuid := '11111111-1111-1111-1111-111111111111';
begin
  select auth_uid into v_admin from staff
   where auth_uid is not null and deleted_at is null limit 1;
  select id into v_mid from members
   where org_id = v_org and deleted_at is null limit 1;

  /* ⑤⑥ 用**總部**身分讀那兩張刻意不動的表。
     🔴 上一版用不存在的身分，所以量到的是「沒有 org 的人讀不到」——
       那跟「products 有沒有被誤傷」根本是兩件事。 */
  perform set_config('request.jwt.claims',
    '{"sub":' || to_json(v_admin::text)::text || ',"role":"authenticated"}', true);

  set local role authenticated;
  begin select count(*) into v_n from products; exception when others then v_n := -1; end;
  reset role;
  v_out := v_out || E'\n' || '⑤ 🎯 商品沒被誤傷（migi-admin 直接查它）' || E'\t' ||
    case when v_n > 0 then '✅ ' || v_n || ' 列' else '🔴 ' || v_n || ' —— migi-admin 會壞' end;

  set local role authenticated;
  begin select count(*) into v_n from stores; exception when others then v_n := -1; end;
  reset role;
  v_out := v_out || E'\n' || '⑥ 🎯 門市沒被誤傷' || E'\t' ||
    case when v_n > 0 then '✅ ' || v_n || ' 列' else '🔴 ' || v_n end;

  /* ⑦ 🔴 **這一格紅了 = 會員 App 整個垮掉。**
     DEFINER 的 owner 是 postgres（表的 owner）⇒ 理論上繞過 RLS，
     但理論不算數（硬規則 7）—— 拿**非總部**身分實際叫一次。
     ⚠ 簽名這次是撈出來的不是猜的：`(p_member_id uuid, p_txn_limit integer)`。 */
  perform set_config('request.jwt.claims',
    '{"sub":"99999999-9999-9999-9999-999999999999","role":"authenticated"}', true);
  set local role authenticated;
  begin
    select coalesce((public.get_wallet_tx(v_mid, 3) ->> 'balance')::int, -1) into v_bal;
  exception when others then v_bal := -2; end;
  reset role;
  v_out := v_out || E'\n' || '⑦ 🔴 非總部身分呼叫 get_wallet_tx（DEFINER）' || E'\t' ||
    case when v_bal >= 0 then '✅ 回得出餘額 ' || v_bal || ' —— DEFINER 不受 RLS 影響'
         when v_bal = -1 then '🔴 回了 null —— 會員 App 的錢包會空白'
         else '🔴 拋錯 —— 會員 App 垮掉' end;

  /* ⑧ 🎯 **正對照，補上一版沒有的那一半**：
     同一個非總部身分**直接查表**要讀不到 ——
     這樣 ⑦ 的「✅」才證明得了「是 DEFINER 繞過了 RLS」，
     而不是「RLS 根本沒擋」。
     🔴 少了這一格，⑦ 綠掉的原因有兩種而你分不出來。 */
  set local role authenticated;
  begin select count(*) into v_n from wallets; exception when others then v_n := -1; end;
  reset role;
  v_out := v_out || E'\n' || '⑧ 🎯 正對照：同一個身分**直接查** wallets 讀不到' || E'\t' ||
    case when v_n = 0 then '✅ 0 列 ⇒ ⑦ 的成功確實來自 DEFINER'
         when v_n = -1 then '⚠ 拋錯（也擋住了）'
         else '🔴 讀到 ' || v_n || ' 列 —— 那 ⑦ 根本沒證明到 DEFINER' end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.chk', v_out, true);
exception when others then
  begin reset role; exception when others then end;
  perform set_config('migi.chk', v_out || E'\n🔴 測試自己炸了\t' || sqlerrm, true);
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.chk', true), E'\n')) as x
 where coalesce(x,'') <> '';
