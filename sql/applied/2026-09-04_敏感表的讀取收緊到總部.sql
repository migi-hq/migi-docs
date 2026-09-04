/* ============================================================
   把敏感表的「讀取」收緊到總部
   2026-09-04 · MIGI · 待辦 21 的第 ③ 步（第 ①② 步已於同日完成）

   ── 這一份在做什麼 ──────────────────────────────────
   把 22 條 `SELECT` ＋ org 的 policy 逐條看過並做決定：
   · **17 條**收緊成「總部才讀得到」
   · **5 條**維持 org 級（那是刻意的，理由逐條寫在下面）

   ⚠ CLAUDE.md 待辦 21 ①：**「要的是每一條都被看過並做了決定」，
     不是「一律加嚴」。** 所以下面 5 條「不動」跟 17 條「收緊」
     一樣是決定，不是漏掉。

   ============================================================
   🎯 為什麼這件事今天做起來幾乎沒有風險
   ============================================================
   2026-09-04 掃過三個 repo 的 `.from(`：

   ```
   migi-admin/src/lib/products.js   .from('products')  ×5   ← 唯一一個
   其餘全部是 Array.from(...) 或 supabase.storage.from(bucket)
   ```
   🔴 **Storage 不算** —— 它的 policy 在 `storage` schema，與這 22 條無關。

   📌 順帶挖到兩處註解，是這條規則留下的疤：
   · `migi-web/src/lib/avatar.js:187`
     「這裡以前是 `supabase.from('members').select(...)`，**而它從來沒有運作過**」
   · `migi-web/src/lib/social.js:375`
     「兩份都是 `supabase.from('members').select(...)`，**兩份都是死的**」
   ⇒ 那正是硬規則 4：**RLS 會濾成空陣列而且不報錯。**

   ⇒ **22 條裡只有 `products_org` 是承重的**，其餘 21 條沒有任何前端在用。

   ============================================================
   ⚠ 三件動手前查證過的事（不是推論）
   ============================================================
   **① migi-admin 的身分就是總部。**
   `staff` 只有 1 列：`role='hq'`、`auth_uid` 有值、`member_id` 為 null
   （總部走 Email 那條路，`member_id` 是 null 是**對的狀態**，見待辦 20）。
   ⇒ 收成 `can()` 對 migi-admin **完全沒有影響**，它本來就是 hq。
   ⇒ 日後 migi-admin 做報表要讀 `orders` / `v_real_*` 也照樣讀得到。

   **② `anon` 本來就讀不到。**
   POS 用 anon、沒有 auth session ⇒ `current_org_id()` 回 null
   ⇒ `org_id = null` 恆為 null ⇒ 一列都不通過。
   **所以收緊對 POS 是零影響**，它的每一支查詢本來就走 DEFINER RPC（硬規則 4）。

   **③ DEFINER 函式不受 RLS 影響。**
   那 165 支函式的 owner 是 `postgres`（表的 owner）⇒ 預設繞過 RLS。
   ⚠ **但這是要驗的，不是推論的**（硬規則 7）——
     驗證段第 ⑦ 格就是拿一個**非總部**身分去呼叫 `get_wallet_tx`，
     確認它照常回得出錢包。**那一格如果紅了，會員 App 整個垮掉。**

   ============================================================
   🔴 已知代價（寫在這裡，因為它沒有症狀）
   ============================================================
   收緊之後，如果有人**新加了直接查表的程式碼**，那段會**回空陣列而且不報錯**
   —— 就是 `avatar.js` 與 `social.js` 那兩處註解描述的形狀。
   ⚠ 而在此之前，**開了 JWT 的會員反而會讓那種寫法「看起來會動」**
     （因為他有 org）—— 那才是更糟的：**一個只在某些身分下才會動的查詢。**
   → 通則不變：**三端一律走 DEFINER RPC，不要直接查表**（硬規則 4）。

   ============================================================
   📌 順帶更正一句 CLAUDE.md 的錯誤敘述
   ============================================================
   待辦 23.5 寫：
   > 「`app_events` 的 RLS 是 `org_id = current_org_id()`；
   >   POS 用 anon 沒有 auth session → 讀不到。
   >   ⚠ 待辦 14／20 上線那天這個保護就破。」

   🔴 **後半段是錯的。** 2026-09-04 實查：`app_events` **開了 RLS 但 0 條 policy**
     ⇒ 那不是「靠沒有 session」，是**真的鎖死** —— 開 JWT 之後照樣讀不到。
   ✅ 而且它不孤單：**46 張表全部開了 RLS，其中 20 張是 0 policy**
     （`app_events`／`app_notifications`／`member_blocks`／`member_likes`／
      `phone_otps`／`invoices`／`match_queues`／`season_standings`… 等）。
   🎯 **0 policy 是這個系統裡最安全的狀態**，而不是漏掉的意思。
   ============================================================ */


-- ══════════════════════════════════════════════════════
-- A. 維持 org 級（5 條）—— 這是決定，不是漏掉
-- ══════════════════════════════════════════════════════
/* · `products`  🔴 **承重** —— migi-admin 5 處直接查；
                 而且商品清單本來就該讓店端讀得到
   · `stores` / `tables` / `stake_levels`
                 店家的**公開**資訊（門市、桌、級距）。
                 會員 App 的配桌頁本來就在顯示它們，
                 日後真的要讓前端直接查也不該擋。
   · `orgs`      條件是 `id = current_org_id()` —— 只看得到自己的 org，
                 那已經是最緊的形狀了。
   ⚠ 一條都不動，連 `to authenticated` 都不改 ——
     **沒有理由的改動也是風險**（每一次 drop/create 都是一次手滑的機會）。 */


-- ══════════════════════════════════════════════════════
-- B. 收緊到總部（17 條）
-- ══════════════════════════════════════════════════════
/* 三個權限碼，對應三種「為什麼不能給」：
     `member.read`   個資（手機、生日、性別、店員備註、牌咖關係）
     `finance.read`  錢（餘額、流水、訂單、付款、儲值）
     `ops.read`      營運（誰在哪桌、誰是店員、券與定價規則）

   ⚠ **今天這三個碼的答案完全一樣**（`can()` 一律看 hq/owner）——
     那是刻意的，不是沒寫完。分成三個是因為
     「**店長能看自己店的訂單，但不能看全部會員的手機**」
     是必然會出現的區分，而到那天**只要改 `can()` 一支**（待辦 29 ①）。
   ⚠ 權限碼用**動詞**不用頁面名（待辦 29 ④）——
     頁面會改名、會合併、會拆開；動作不會。
   📌 加上已有的 `product.write` / `order.write`，目前共 **5 個碼**，
     離「10–15 個」的收斂上限還很遠。 */

-- ── 個資 ────────────────────────────────────────────
drop policy if exists members_org on public.members;
create policy members_org on public.members
  for select to authenticated
  using (org_id = public.current_org_id() and public.can('member.read'));

drop policy if exists avail_org on public.member_availability;
create policy avail_org on public.member_availability
  for select to authenticated
  using (org_id = public.current_org_id() and public.can('member.read'));

/* ⚠ `member_interactions` 裡有**店員寫的備註** —— 那是給店員看的，
     不是給客人看的（「這位客人上次抱怨冷氣太冷」）。 */
drop policy if exists interactions_org on public.member_interactions;
create policy interactions_org on public.member_interactions
  for select to authenticated
  using (org_id = public.current_org_id() and public.can('member.read'));

drop policy if exists buddies_org on public.mahjong_buddies;
create policy buddies_org on public.mahjong_buddies
  for select to authenticated
  using (org_id = public.current_org_id() and public.can('member.read'));

drop policy if exists mc_org on public.member_coupons;
create policy mc_org on public.member_coupons
  for select to authenticated
  using (org_id = public.current_org_id() and public.can('member.read'));

-- ── 錢 ──────────────────────────────────────────────
drop policy if exists wallets_org on public.wallets;
create policy wallets_org on public.wallets
  for select to authenticated
  using (org_id = public.current_org_id() and public.can('finance.read'));

drop policy if exists txns_org on public.wallet_txns;
create policy txns_org on public.wallet_txns
  for select to authenticated
  using (org_id = public.current_org_id() and public.can('finance.read'));

drop policy if exists orders_org on public.orders;
create policy orders_org on public.orders
  for select to authenticated
  using (org_id = public.current_org_id() and public.can('finance.read'));

/* ⚠ `order_items` 的條件**不是** `org_id = …` —— 它經由 `orders` 判斷。
     那是原本就有的設計（過濾邏輯只有一份），**照抄不要改成 org_id**。 */
drop policy if exists oi_org on public.order_items;
create policy oi_org on public.order_items
  for select to authenticated
  using (exists (select 1 from orders o
                  where o.id = order_items.order_id
                    and o.org_id = public.current_org_id())
         and public.can('finance.read'));

drop policy if exists order_payments_read_org on public.order_payments;
create policy order_payments_read_org on public.order_payments
  for select to authenticated
  using (org_id = public.current_org_id() and public.can('finance.read'));

drop policy if exists topup_org on public.topup_orders;
create policy topup_org on public.topup_orders
  for select to authenticated
  using (org_id = public.current_org_id() and public.can('finance.read'));

-- ── 營運 ────────────────────────────────────────────
drop policy if exists sessions_org on public.table_sessions;
create policy sessions_org on public.table_sessions
  for select to authenticated
  using (org_id = public.current_org_id() and public.can('ops.read'));

/* ⚠ `session_players` 是「誰跟誰同桌打過牌」—— 那是社交關係，
     跟 `mahjong_buddies` 一樣敏感。 */
drop policy if exists sp_org on public.session_players;
create policy sp_org on public.session_players
  for select to authenticated
  using (org_id = public.current_org_id() and public.can('ops.read'));

drop policy if exists staff_org on public.staff;
create policy staff_org on public.staff
  for select to authenticated
  using (org_id = public.current_org_id() and public.can('ops.read'));

/* ⚠ `coupons` 是**券的定義**（含 `discount_value`），
     不是「我有哪些券」（那是 `member_coupons`）。
     讓人列舉全部的券等於公開所有優惠設計。 */
drop policy if exists coupons_org on public.coupons;
create policy coupons_org on public.coupons
  for select to authenticated
  using (org_id = public.current_org_id() and public.can('ops.read'));

/* ⚠ `pricing_tiers` / `bonus_rules` 是定價與贈點規則 —— 商業設定。 */
drop policy if exists pricing_org on public.pricing_tiers;
create policy pricing_org on public.pricing_tiers
  for select to authenticated
  using (org_id = public.current_org_id() and public.can('ops.read'));

drop policy if exists bonus_org on public.bonus_rules;
create policy bonus_org on public.bonus_rules
  for select to authenticated
  using (org_id = public.current_org_id() and public.can('ops.read'));


-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
do $$
declare
  v_out text := '';
  v_admin uuid; v_mid uuid; v_n int; v_bal int;
  v_org uuid := '11111111-1111-1111-1111-111111111111';
begin
  begin
    select auth_uid into v_admin from staff
     where auth_uid is not null and deleted_at is null limit 1;
    select id into v_mid from members
     where org_id = v_org and deleted_at is null limit 1;

    ---- ① policy 的形狀 --------------------------------
    v_out := v_out || E'\n' || '① 17 條敏感讀取都帶 can() 且限 authenticated' || E'\t' ||
      (select case when count(*) = 17 then '✅'
                   else '🔴 只有 ' || count(*) || ' 條' end
         from pg_policies
        where schemaname='public' and cmd='SELECT'
          and roles::text='{authenticated}' and coalesce(qual,'') like '%can(%');

    /* 🔴 **正對照**：那 5 條刻意不動的要**還在而且還是 org 級**。
       只驗「收緊了幾條」的話，把它們一起收掉也會讓 ① 變綠 ——
       而那會打壞 migi-admin。 */
    v_out := v_out || E'\n' || '② 🎯 正對照：5 條刻意不動的仍是 org 級' || E'\t' ||
      (select case when count(*) = 5 then '✅ products／stores／tables／stake_levels／orgs'
                   else '🔴 只剩 ' || count(*) || ' 條 —— 誤傷了' end
         from pg_policies
        where schemaname='public' and cmd='SELECT'
          and tablename in ('products','stores','tables','stake_levels','orgs')
          and coalesce(qual,'') not like '%can(%');

    ---- ③④ 真的換身分讀一次 ---------------------------
    if v_admin is not null then
      perform set_config('request.jwt.claims',
        '{"sub":' || to_json(v_admin::text)::text || ',"role":"authenticated"}', true);
      set local role authenticated;
      begin select count(*) into v_n from members; exception when others then v_n := -1; end;
      reset role;
      v_out := v_out || E'\n' || '③ 🎯 總部身分**仍然讀得到**會員' || E'\t' ||
        case when v_n > 0 then '✅ ' || v_n || ' 列（migi-admin 日後做報表靠這個）'
             when v_n = 0 then '🔴 0 列 —— 總部被自己擋住了'
             else '🔴 拋錯' end;

      /* 🔴 **正對照**：非總部的 authenticated 要讀不到。
         只驗「總部讀得到」的話，一條**沒收緊**的 policy 也會讓 ③ 變綠。 */
      perform set_config('request.jwt.claims',
        '{"sub":"99999999-9999-9999-9999-999999999999","role":"authenticated"}', true);
      set local role authenticated;
      begin select count(*) into v_n from members; exception when others then v_n := -1; end;
      reset role;
      v_out := v_out || E'\n' || '④ 🎯 正對照：非總部身分讀不到會員' || E'\t' ||
        case when v_n = 0 then '✅ 0 列（沒收緊的話這裡會有資料）'
             when v_n = -1 then '⚠ 拋錯（也擋住了，但訊息會很難懂）'
             else '🔴 竟然讀到 ' || v_n || ' 列' end;

      ---- ⑤⑥ 沒被誤傷的那一半 -------------------------
      /* 🔴 **2026-09-04 第一次跑的時候這兩格是紅的，而錯的是驗證段不是 policy。**
         原本用 `99999999-…`（一個**不存在的身分**）去讀 `products` ——
         那個身分沒有 staff 列也不是會員 ⇒ `current_org_id()` 回 **null**
         ⇒ `org_id = null` ⇒ **0 列**。
         🎯 而那正是 org 級 policy **正常運作**的樣子，我卻拿它當
           「products 被誤傷了」的證據。
         → 要驗「沒被誤傷」就得用一個**真的有 org 的身分**（總部）。
         ⚠ 同硬規則 3.56：**驗證段紅了，先懷疑期望值，再懷疑函式。** */
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

      ---- ⑦ 🔴 最重要的一格：DEFINER RPC 有沒有被打壞 ----
      /* 🔴 **這一格紅了 = 會員 App 整個垮掉。**
         DEFINER 函式的 owner 是 postgres（表的 owner）⇒ 理論上繞過 RLS，
         但**理論不算數**（硬規則 7）—— 拿一個**非總部**身分實際叫一次。

         🔴 **2026-09-04 這一格也紅了，而它也是驗證段的錯** ——
           我寫 `get_wallet_tx(v_org, v_mid)`，而實際簽名是
           **`get_wallet_tx(p_member_id uuid, p_txn_limit integer)`** ——
           沒有 org 參數，第二個要 integer。
           ⇒ 找不到匹配的函式 ⇒ 拋錯，而症狀看起來**跟「RLS 打壞了 DEFINER」
             一模一樣**。
         🎯 根因是硬規則 3：**我猜了函式簽名。**
           系統裡很多 RPC 是 `(p_org_id, p_member_id)` 的形狀，
           我就照那個形狀補了一個 org 進去 —— **而「其他函式長這樣」不是證據。**
         → 要在驗證段呼叫任何既有函式之前，先
           `pg_get_function_identity_arguments(oid)` 撈一次。一句話的事。 */
      if v_mid is not null then
        perform set_config('request.jwt.claims',
          '{"sub":"99999999-9999-9999-9999-999999999999","role":"authenticated"}', true);
        set local role authenticated;
        begin
          select coalesce((public.get_wallet_tx(v_mid, 3) ->> 'balance')::int, -1)
            into v_bal;
        exception when others then v_bal := -2; end;
        reset role;
        v_out := v_out || E'\n' || '⑦ 🔴 非總部身分呼叫 get_wallet_tx（DEFINER）' || E'\t' ||
          case when v_bal >= 0 then '✅ 回得出餘額 ' || v_bal || ' —— DEFINER 不受 RLS 影響'
               when v_bal = -1 then '🔴 回了 null —— 會員 App 的錢包會空白'
               else '🔴 拋錯 —— 會員 App 垮掉' end;
      end if;

      ---- ⑧ anon 本來就讀不到（沒有變差）----------------
      perform set_config('request.jwt.claims', '', true);
      set local role anon;
      begin select count(*) into v_n from members; exception when others then v_n := -1; end;
      reset role;
      v_out := v_out || E'\n' || '⑧ anon 讀不到會員（本來就是，確認沒變差）' || E'\t' ||
        case when v_n = 0 then '✅ 0 列'
             when v_n = -1 then '⚠ 拋錯'
             else '🔴 讀到 ' || v_n || ' 列' end;
    else
      v_out := v_out || E'\n' || '③–⑧ 實際身分測試' || E'\t' || '⚠ 找不到 staff.auth_uid，跳過';
    end if;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'migi_rollback';
  exception when others then
    begin reset role; exception when others then end;
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.pol3', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.pol3', true), E'\n')) as x
 where coalesce(x,'') <> '';
