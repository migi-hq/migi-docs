/* ============================================================
   消費明細拆兩支：會員看自己的、店員查客人的
   2026-09-09 · 待辦 14 最後一支函式的第 ① 步（expand）
   ============================================================

   ── 問題 ────────────────────────────────────────────────
   `get_my_orders_tx` 是**最後一支** anon 叫得動、而且只信前端送的
   `p_member_id` 的會員端函式（另一支 `log_app_event_tx` 是刻意留的）。
   其餘 21 支早就是 `p_member_id := coalesce(current_member_id(), p_member_id)`。
   🔴 今天：**知道一個 member uuid 就看得到別人買了什麼、花多少、
     什麼時間在店裡** —— 比餘額更敏感。

   ── 為什麼不能直接套那一行 ──────────────────────────────
   **POS 也在叫它**（店員查客人的最近消費）。而店員本人也是會員
   ⇒ `current_member_id()` 會回**他自己**
   ⇒ 店員查客人時看到的是自己的帳。**而且不會報錯。**

   ── 做法：抽 core，兩支各自解身分 ────────────────────────
   🔴 **不可以讓 `pos_member_orders_tx` 去呼叫 `get_my_orders_tx`** ——
     第 ③ 步把後者綁 JWT 之後，店員的身分會蓋掉他要查的客人。
   ✅ 所以把查詢本體**搬**進 `_member_orders_core`（同專案既有的
     `_charge_core` 形狀），兩支包裝各自負責「這個 p_member_id 從哪來」：
   ```
   _member_orders_core(member, limit, before)   ← 不解身分，只查資料
     ├─ get_my_orders_tx      會員：⏳ 第 ③ 步改成從 JWT 取
     └─ pos_member_orders_tx  店員：can('member.lookup') ＋ 同 org
   ```
   ⚠ 是**搬**不是**抄** —— 抄一份就是「同一件事兩份定義」，
     而這個專案已經記過六次那個病（`--gray-4`／`paid_count`／…）。

   ── 三步，中間跨一次部署（順序反了 POS 會當場空掉）──────
   ```
   ① 本份：建 core ＋ 建 pos_member_orders_tx ＋ get_my_orders_tx 改成薄殼
      ⚠ **行為完全不變**（簽名不變、仍然信 p_member_id）⇒ 零風險
   ② POS 改叫 pos_member_orders_tx → 部署 → 確認會員查詢正常
   ③ 才把 get_my_orders_tx 綁 JWT ＋ 收 anon
   ```

   ── 🔴 順帶加 `can()` 的第一個權限碼分岔，而那不是順手改 ──────
   `can()` 今天是一行 `role in ('hq','owner')`，**沒有 `case p_perm`** ——
   它自己的註解寫著「等真的出現『店長可以但店員不行』的碼再分岔」。
   🎯 **這裡就是那一刻，只是方向相反**：`member.read` 那一族是總部限定
     （報表、匯出），而**查客人的餘額與最近消費是前場每天在做的事**。
   ⇒ 用 `can('member.read')` 擋 POS 的話，**真的店員登入那天前台就查不到客人**
     —— 而今天不會發現，因為唯一的店員是老闆（`role = 'owner'`）。
   ✅ 新增 `member.lookup`：**任何有 staff 列的人**都通過。
   ⚠ 這樣分岔**不影響任何既有權限碼**（其餘全部走 else 那一支，
     行為逐字不變）—— 驗證段第 ④ 格就是在盯這件事，
     因為 `can()` 被 **20 條 policy** 呼叫，改壞了是整個後台癱掉。

   ⚠ 仍然走 `can()` 而不是自己寫一句「有沒有 staff 列」（待辦 29 ①）——
     `has_store_access()` 就是自己寫了第二份 `role='hq'`，
     結果與 `can()` 對「誰是最高權限」的定義不一致（2026-09-04 修過）。

   ── 事前查證 ────────────────────────────────────────────
   · `get_my_orders_tx` 全文撈自 `pg_proc`，body 逐字搬過去
   · `can()` 與 `current_staff()` 全文撈過，確認今天沒有 `case p_perm`
   · POS 呼叫點：`migi-pos/src/lib/api.js` 的 `getMyOrders()` 一處
   ============================================================ */


/* ── ① core：只查資料，不解身分 ────────────────────────────
   ⚠ 這是**搬**過來的，body 與原 `get_my_orders_tx` 逐字相同。
   ⚠ DEFINER：`orders` / `order_items` / `topup_orders` 都有 RLS，
     而它只被兩支 DEFINER 包裝呼叫（呼叫端權限不會被檢查，硬規則 2.5 反向）。 */
create or replace function public._member_orders_core(
  p_member_id uuid,
  p_limit     int default 10,
  p_before    timestamptz default null
) returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_limit int := greatest(1, least(coalesce(p_limit, 10), 100));
  v_list  jsonb;
begin
  if p_member_id is null then
    raise exception 'member_id required';
  end if;

  select coalesce(jsonb_agg(x order by x_at desc), '[]'::jsonb)
    into v_list
    from (
      select u.x_at, u.x
        from (
          -- ── 消費單（可能附帶同一次交易的儲值）──
          select o.paid_at as x_at,
                 jsonb_build_object(
                   'type', 'order',
                   'id', o.id,
                   'order_no', o.order_no,
                   'txn_no', o.txn_no,
                   'paid_at', o.paid_at,
                   'subtotal', o.subtotal,
                   'coupon_discount', o.coupon_discount,
                   'tier_discount', o.tier_discount,
                   'payable', o.payable,
                   'points_used', o.points_used,
                   'cash_due', o.cash_due,
                   'items', (
                     select coalesce(jsonb_agg(jsonb_build_object(
                       'name', i.name, 'revenue_type', i.revenue_type, 'qty', i.qty,
                       'unit_price', i.unit_price, 'line_total', i.line_total
                     ) order by case i.revenue_type
                                  when 'venue_fee' then 1
                                  when 'fnb'       then 2
                                  when 'retail'    then 3
                                  else 4 end, i.name), '[]'::jsonb)
                     from order_items i where i.order_id = o.id),
                   'payments', (
                     select coalesce(jsonb_agg(jsonb_build_object(
                       'method', pm.method, 'amount', pm.amount
                     )), '[]'::jsonb)
                     from order_payments pm where pm.order_id = o.id),

                   -- 同一次收款的儲值（冪等鍵前綴配對，與 POS 桌帳同一套）
                   'topup', (
                     select jsonb_build_object(
                              'topup_no',     t.topup_no,
                              'points',       t.points,
                              'bonus_points', t.bonus_points,
                              'credit',       t.points + t.bonus_points,
                              'amount_twd',   t.amount_twd)
                       from topup_orders t
                      where t.member_id = o.member_id
                        and t.status = 'paid'
                        and o.idempotency_key like 'pos-%'
                        and split_part(t.idempotency_key, ':', 1)
                          = split_part(o.idempotency_key, ':', 1)
                      limit 1),

                   'collected', o.payable + coalesce((
                     select t.amount_twd from topup_orders t
                      where t.member_id = o.member_id
                        and t.status = 'paid'
                        and o.idempotency_key like 'pos-%'
                        and split_part(t.idempotency_key, ':', 1)
                          = split_part(o.idempotency_key, ':', 1)
                      limit 1), 0)
                 ) as x
            from orders o
           where o.member_id = p_member_id
             and o.deleted_at is null
             and o.status = 'paid'

          union all

          -- ── 沒有配對到訂單的儲值單 ──
          select t.created_at as x_at,
                 jsonb_build_object(
                   'type', 'topup',
                   'id', t.id,
                   'order_no', t.topup_no,
                   'txn_no', t.txn_no,
                   'paid_at', t.created_at,
                   'subtotal', t.amount_twd,
                   'coupon_discount', 0,
                   'tier_discount', 0,
                   'payable', t.amount_twd,
                   'points_used', 0,
                   'cash_due', t.amount_twd,
                   'collected', t.amount_twd,
                   'points', t.points,
                   'bonus_points', t.bonus_points,
                   -- 儲值不是營收類別，用獨立旗標標記（與 POS 一致）
                   'items', jsonb_build_array(jsonb_build_object(
                     'name', '會員儲值 ' || (t.points + t.bonus_points)::text || ' 點',
                     'is_topup', true, 'qty', 1,
                     'unit_price', t.amount_twd, 'line_total', t.amount_twd)),
                   'payments', jsonb_build_array(jsonb_build_object(
                     'method', t.pay_method, 'amount', t.amount_twd))
                 ) as x
            from topup_orders t
           where t.member_id = p_member_id
             and t.status = 'paid'
             and not exists (
               select 1 from orders o
                where o.member_id = t.member_id
                  and o.deleted_at is null
                  and o.status = 'paid'
                  and o.idempotency_key like 'pos-%'
                  and split_part(o.idempotency_key, ':', 1)
                    = split_part(t.idempotency_key, ':', 1))
        ) u
       where p_before is null or u.x_at < p_before
       order by u.x_at desc
       limit v_limit
    ) z;

  return jsonb_build_object(
    'orders', v_list,
    -- 還有更多：前端據此決定要不要顯示「載入更多」。
    -- 回筆數等於上限就當作還有 —— 少一次查詢，代價是最後一頁可能多按一次。
    'has_more', jsonb_array_length(v_list) >= v_limit,
    'next_before', case when jsonb_array_length(v_list) > 0
                        then (v_list -> (jsonb_array_length(v_list) - 1) ->> 'paid_at')
                   end);
end $function$;

/* 內部用，兩支包裝都是 DEFINER ⇒ 不需要給任何前端角色（硬規則 2.6b 兩個方向）。 */
revoke execute on function public._member_orders_core(uuid, int, timestamptz) from public;
revoke execute on function public._member_orders_core(uuid, int, timestamptz) from anon, authenticated;
grant  execute on function public._member_orders_core(uuid, int, timestamptz) to service_role;


/* ── ② `get_my_orders_tx` 變成薄殼 ─────────────────────────
   🔴 **簽名不變 ⇒ `CREATE OR REPLACE`，不 DROP、不掉 GRANT、前端不用改**（硬規則 2）。
   ⚠ **行為刻意完全不變**：這一步仍然信 `p_member_id`。
     綁 JWT 是第 ③ 步的事，要等 POS 先切走（順序反了 POS 會空掉）。
   📌 那一行未來會長這樣（現在**不要**加）：
        p_member_id := coalesce(public.current_member_id(), p_member_id); */
create or replace function public.get_my_orders_tx(
  p_member_id uuid,
  p_limit     int default 10,
  p_before    timestamptz default null
) returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  return public._member_orders_core(p_member_id, p_limit, p_before);
end $function$;


/* ── ③ `can()` 加第一個權限碼分岔 ──────────────────────────
   ⚠ 只新增 `member.lookup` 這一支，**其餘全部走 else，行為逐字不變**。
     `can()` 被 20 條 policy 呼叫，改壞了是整個後台癱掉 ——
     驗證段第 ④ 格用負對照盯著。 */
create or replace function public.can(p_perm text)
returns boolean
language sql stable security definer set search_path to 'public'
as $function$
  /* 🎯 **判斷點一律呼叫 `can('動詞.名詞')`，不要在 policy 裡比對 role 字串**
     （CLAUDE.md 待辦 29 ①）。重點是**「權限怎麼決定」與「誰有權限」分家**：
     日後換成查 `role_permissions` 表時，**所有呼叫點一行都不用改**。

   ⚠ 權限碼用**動詞**不用頁面名（待辦 29 ④）——
     頁面會改名、會合併、會拆開；動作不會。
   ⚠ 收斂判準：控制在 10–15 個以內。

   ── 🔴 2026-09-09：第一個分岔出現了 ──────────────────────
   在此之前所有碼的答案都一樣（總部才有），註解寫著
   「等真的出現『店長可以但店員不行』的碼再分岔」。
   🎯 **而它來了，只是方向相反**：
     · `member.read` 那一族是**總部限定**（報表、匯出、跨店查詢）
     · **`member.lookup` 是前場每天在做的事** —— 櫃檯查客人的餘額、
       等級、當日暢打、最近消費。用總部限定的碼擋它的話，
       **真的店員登入那天前台就查不到客人**，
       而今天不會發現：唯一的店員是老闆（`role = 'owner'`）。
   ⚠ `member.lookup` 只回答「這個人是不是店員」——
     它**不放寬任何既有的碼**。 */
  select case
    when p_perm = 'member.lookup'
      then exists (select 1 from public.current_staff())
    else exists (
      select 1 from public.current_staff() cs
       where cs.role in ('hq', 'owner')
    )
  end;
$function$;

/* ⚠ `authenticated` 的 EXECUTE 必須留著 —— policy 運算式是用**查詢者的身分**
   執行的，收掉會讓那 20 條 policy 拋 permission denied（**不是擋住，是壞掉**）。 */
grant execute on function public.can(text) to authenticated, service_role;
revoke execute on function public.can(text) from public;
revoke execute on function public.can(text) from anon;


/* ── ④ POS 專用：店員查某位客人的消費 ──────────────────────
   ⚠ **不收 `p_org_id`** —— org 從 `current_org_id()` 取。
     收 org 參數等於讓呼叫端宣告自己屬於哪個機構，而**身分不可以由
     呼叫端宣告**（同 `set_member_phone_tx` 不收 `p_member_id` 的理由）。
   ⚠ 預設 `p_limit` 5：POS 的會員查詢只顯示最近 5 筆。 */
create or replace function public.pos_member_orders_tx(
  p_member_id uuid,
  p_limit     int default 5,
  p_before    timestamptz default null
) returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_org uuid;
begin
  if not public.can('member.lookup') then
    raise exception 'forbidden: 需要店員身分';
  end if;

  v_org := public.current_org_id();

  /* 🔴 **要驗那位客人屬不屬於這個機構** —— 今天只有一個 org 所以踩不到，
     **那是運氣不是設計**（同 2026-08-27 補 org 比對時的結論）。
     ⚠ 訊息不分「不存在」與「不同 org」—— 兩者都不該讓對方知道。 */
  if not exists (
    select 1 from members m
     where m.id = p_member_id and m.org_id = v_org and m.deleted_at is null
  ) then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  return public._member_orders_core(p_member_id, p_limit, p_before);
end $function$;

/* POS 登入後是 `authenticated`（店員登入 2026-09-04 起）⇒ 不需要 anon。 */
revoke execute on function public.pos_member_orders_tx(uuid, int, timestamptz) from public;
revoke execute on function public.pos_member_orders_tx(uuid, int, timestamptz) from anon;
grant  execute on function public.pos_member_orders_tx(uuid, int, timestamptz) to authenticated, service_role;


/* ============================================================
   驗證段
   🎯 這一份最危險的不是新函式，是**動了 `can()`** ——
     它被 20 條 policy 呼叫，改壞了是整個後台癱掉。
     第 ④ 格的負對照就是在盯那件事。
   ============================================================ */
do $$
declare
  v_mem uuid; v_sub text; v_org uuid;
  v1 text; v2 text; v3 text; v4 text;
  /* ⚠ 這些**一定要宣告在這裡**：plpgsql 的巢狀區塊是
     `DECLARE … BEGIN … END`，把 `declare` 寫在 `begin` 之後是語法錯。
     （第一版就是那樣寫的，整份跑不起來。） */
  r jsonb;
  a bool; b bool; c bool; d bool; e bool; f bool;
begin
  /* 取樣：一個有訂單的測試會員 ＋ 那位老闆的 auth_uid（拿來模擬 JWT）。 */
  select o.member_id into v_mem
    from orders o join members m on m.id = o.member_id
   where o.status = 'paid' and m.is_test and m.deleted_at is null
   group by o.member_id order by count(*) desc limit 1;

  select s.auth_uid::text into v_sub
    from staff s where s.deleted_at is null and s.auth_uid is not null
   order by case s.role when 'hq' then 1 when 'owner' then 1 else 2 end limit 1;

  select m.org_id into v_org from members m where m.id = v_mem;

  if v_mem is null or v_sub is null then
    /* ⚠ 找不到樣本要**出聲**，不要安靜跳過（2026-09-04 那次兩格沒出現而我以為全過）。 */
    perform set_config('migi.v1', '⚪ 取樣失敗（會員 ' || coalesce(v_mem::text,'無') ||
                                  '／staff sub ' || coalesce(v_sub,'無') || '）', true);
    perform set_config('migi.v2', '⚪ 同上', true);
    perform set_config('migi.v3', '⚪ 同上', true);
    perform set_config('migi.v4', '⚪ 同上', true);
    return;
  end if;

  /* ── ⑤ 薄殼之後 `get_my_orders_tx` 回傳要跟以前一樣（正對照）。
     ⚠ 只驗「有沒有結構」不夠 —— 要看**真的撈得到筆數**，
       不然 core 接錯參數也會回一個合法的空殼。 */
  begin
    r := public.get_my_orders_tx(v_mem, 5, null);
    v1 := case
      when r is null then '🔴 回 null'
      when not (r ? 'orders' and r ? 'has_more') then '🔴 少了鍵：' || left(r::text, 60)
      when jsonb_array_length(r->'orders') = 0 then '🔴 撈到 0 筆（這位會員應該有訂單）'
      else '✅ ' || jsonb_array_length(r->'orders') || ' 筆，鍵齊全' end;
  exception when others then v1 := '🔴 ' || left(coalesce(sqlerrm,'?'), 60);
  end;

  /* ── ⑥ 以總部身分叫 pos_member_orders_tx（正對照）→ 應該成功。 */
  begin
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_sub, 'role', 'authenticated')::text, true);
    set local role authenticated;
    r := public.pos_member_orders_tx(v_mem, 5, null);
    reset role;
    v2 := case
      when r ? 'ok' and not (r->>'ok')::boolean then '🔴 被擋：' || coalesce(r->>'reason','?')
      when jsonb_array_length(coalesce(r->'orders','[]'::jsonb)) > 0
        then '✅ ' || jsonb_array_length(r->'orders') || ' 筆（店員查得到客人）'
      else '🔴 回 0 筆' end;
  exception when others then reset role; v2 := '🔴 ' || left(coalesce(sqlerrm,'?'), 70);
  end;

  /* ── ⑦ 以「登入但不是店員」的身分叫 → 應該被擋。
     🔴 只驗「店員查得到」的話，一支**完全沒有擋牆**的實作也會全綠。 */
  begin
    perform set_config('request.jwt.claims',
      json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
    set local role authenticated;
    perform public.pos_member_orders_tx(v_mem, 5, null);
    reset role;
    v3 := '🔴 沒有店員身分也叫得動 —— 擋牆沒作用';
  exception when others then
    reset role;
    v3 := case when sqlerrm like 'forbidden%' then '✅ 被擋（' || sqlerrm || '）'
               else '⚠ 擋住了但不是預期的原因：' || left(coalesce(sqlerrm,'?'), 55) end;
  end;

  /* ── ⑧ 🎯 **最重要的一格：`can()` 的既有權限碼行為沒變**。
     總部身分 → 全部 true；非店員 → 全部 false（含 member.lookup）。 */
  begin
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_sub, 'role', 'authenticated')::text, true);
    set local role authenticated;
    a := public.can('product.write'); b := public.can('member.read');
    c := public.can('ops.read');      d := public.can('member.lookup');
    reset role;

    perform set_config('request.jwt.claims',
      json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
    set local role authenticated;
    e := public.can('product.write'); f := public.can('member.lookup');
    reset role;

    v4 := '總部：product.write=' || a || ' member.read=' || b || ' ops.read=' || c ||
          ' member.lookup=' || d || E'\n非店員：product.write=' || e || ' member.lookup=' || f ||
          E'\n' || case when a and b and c and d and not e and not f
                        then '✅ 既有權限碼行為沒變，新碼只對店員成立'
                        else '🔴 有一格不對 —— 20 條 policy 靠它' end;
  exception when others then reset role; v4 := '🔴 ' || left(coalesce(sqlerrm,'?'), 70);
  end;

  perform set_config('migi.v1', v1, true);
  perform set_config('migi.v2', v2, true);
  perform set_config('migi.v3', v3, true);
  perform set_config('migi.v4', v4, true);
end $$;

select
  /* ── ① 三支函式的模式與授權 ── */
  coalesce((
    select string_agg(
      rpad(p.proname, 24)
      || case when p.prosecdef then ' DEFINER' else ' 🔴 INVOKER' end
      || '　anon：'  || case when exists (select 1 from aclexplode(p.proacl) a where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE') then '有' else '沒' end
      || '　PUBLIC：' || case when (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee=0 and a.privilege_type='EXECUTE')) then '🔴 有' else '沒' end
      || '　auth：'  || case when exists (select 1 from aclexplode(p.proacl) a where a.grantee='authenticated'::regrole::oid and a.privilege_type='EXECUTE') then '有' else '沒' end
      || '　service_role：' || case when exists (select 1 from aclexplode(p.proacl) a where a.grantee='service_role'::regrole::oid and a.privilege_type='EXECUTE') then '✅' else '🔴' end,
      E'\n' order by p.proname)
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and p.proname in ('_member_orders_core', 'get_my_orders_tx', 'pos_member_orders_tx', 'can')
  ), '🔴 找不到') as "① 四支的模式與授權",

  /* ② 期望：core 與 pos_ 都沒有 anon／PUBLIC；
        `get_my_orders_tx` 的 anon **仍然在**（第 ③ 步才收，現在收 App 會壞）；
        `can` 只有 authenticated ＋ service_role。
     數量（當場查出來的，硬規則 3.56）：函式 181 → 183（新增 2 支）
        anon 明確 108 → 108（新增的兩支都收掉了）
        PUBLIC   106 → 106（同上） */
  (select '　函式總數：' || count(*) || '（期望 183 ＝ 181 ＋ 2）'
     || E'\n　anon 明確：' || count(*) filter (where exists (
          select 1 from aclexplode(p.proacl) a where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE'))
     || '（期望 108，不變）'
     || E'\n　PUBLIC　　：' || count(*) filter (where p.proacl is null or exists (
          select 1 from aclexplode(p.proacl) a where a.grantee=0 and a.privilege_type='EXECUTE'))
     || '（期望 106，不變）'
   from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind='f') as "② 全庫數量",

  /* ③ 🎯 沒有第二份查詢邏輯：`get_my_orders_tx` 應該只剩一行呼叫 core。
     ⚠ 掃的是**函式名**不是欄位名（硬規則 3.5：禁字只用會產生行為的東西）。 */
  (select case when pg_get_functiondef(p.oid) ~ '_member_orders_core'
                and pg_get_functiondef(p.oid) !~ 'topup_orders'
               then '✅ 已是薄殼（只呼叫 core，本體沒有留第二份）'
               else '🔴 本體還留著查詢邏輯 —— 那就是兩份定義' end
   from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind='f'
    and p.proname='get_my_orders_tx') as "③ 沒有留下第二份查詢",

  coalesce(nullif(current_setting('migi.v1', true), ''), '🔴 沒有訊息') as "④ get_my_orders_tx 行為沒變",
  coalesce(nullif(current_setting('migi.v2', true), ''), '🔴 沒有訊息') as "⑤ 🎯 正對照：店員查得到客人",
  coalesce(nullif(current_setting('migi.v3', true), ''), '🔴 沒有訊息') as "⑥ 🎯 擋牆：不是店員叫不動",
  coalesce(nullif(current_setting('migi.v4', true), ''), '🔴 沒有訊息') as "⑦ 🎯 最重要：can() 既有權限碼沒被改壞",

  /* ⑧ 參考：`can()` 現在有幾條 policy 在用（改它的爆炸半徑）。
     ⚠ 不是通過條件，是提醒下一個人「動這支要驗什麼」。 */
  (select '有 ' || count(*) || ' 條 RLS policy 呼叫 can() —— 動它之前先想這個數字'
     from pg_policies where schemaname='public'
      and coalesce(qual,'') || coalesce(with_check,'') like '%can(%') as "⑧ 參考：can() 的爆炸半徑";
