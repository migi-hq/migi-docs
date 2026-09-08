/* ============================================================
   POS 營運函式收掉 anon（保留 authenticated）
   2026-09-08 · 待辦 14／待辦 20 的收尾
   ============================================================

   ── 🔴 為什麼現在可以做：一個過期的理由 ──────────────────
   CLAUDE.md 待辦 20 把這批歸類為：
   > 🟡 **現況的必然** —— POS 用 anon key，而在店員登入之前
   >   **沒有身分可以檢查**。**收了會當場打壞收銀機**。

   ✅ **店員登入 2026-09-04 就做完了**（實機登入成功、`PosApp` 只在
     登入後才 mount、`api.js` 用的就是持有 session 的那個 client
     ——`persistSession: true` ＋ `autoRefreshToken: true`）。
   ⇒ **每一支 POS 的 RPC 現在都帶著店員的 access token（role=authenticated）**，
     那個理由從那天起就不成立了。

   ── 今天暴露了什麼（不是理論）──────────────────────────
   這 14 支**全部 `anon` 叫得動、而且零權限檢查**。
   ⚠ 我第一次量的時候把「函式體有 `current_staff()`」讀成「有擋牆」——
     **錯的**：那多半是 2026-09-04 加的**稽核欄位覆寫**
     （`p_staff_id := (select staff_id from public.current_staff())`），
     它只決定 `updated_by` 寫誰，**不擋任何人**。
     🎯 用一個分不出「覆寫」與「擋牆」的儀器下結論，就是硬規則 3.5 那一族。
   ⇒ 重新量的結果：`topup_tx` / 三支結帳包裝 / `join_session_tx`
     **一道擋牆都沒有** —— 知道一個 member uuid 就能叫 `topup_tx` 加點數。
   📌 門檻只有「要知道 member uuid」，而那條路 2026-08-30 才剛收窄
     （`register_member_tx` 收回 anon、排行榜刻意不回 id）——
     **所以這是真的洞但不是失火**，而修它有收銀機的爆炸半徑。

   ── 這一份的範圍：只收 anon，不加擋牆 ────────────────────
   | | 收什麼 | 為什麼 |
   |---|---|---|
   | **A 群 11 支**（POS 專用） | `public` ＋ `anon`，**保留 `authenticated`** | POS 登入後就是 authenticated ⇒ 照常運作 |
   | **B 群 3 支**（沒有任何前端叫） | `public` ＋ `anon` ＋ `authenticated` | 只被 DEFINER 包裝內部呼叫，或是舊世代死碼 |

   ⚠ **這一份不擋「登入的會員自己叫」** —— 那要加店員擋牆，
     而那會把會員端未來的線上儲值也擋掉（那條路應該走 service_role），
     且 POS 的 session 一旦 refresh 失敗就整台 403。**留給下一份決定。**

   ── 🔴 刻意排除的兩支（收了會壞，而且症狀是靜默的）────────
   · **`log_app_event_tx`** —— 三端的埋點入口，而 migi-web 在**還沒登入時
     就要發事件**（`app_open` / `page_view`，以及 `member_session` 探針
     本身就是在 `no_login` ＝ 沒有 session ＝ anon 那一刻發的）。
     🎯 收了的話那些列會消失 ⇒ **探針看起來全綠，而那是假的**。
     ⚠ 那比沒有探針更糟：一個會說謊的儀器。
   · **`get_my_orders_tx`** —— web 與 POS 都在叫（會員看自己的、
     店員查客人的），要分「店員視角 vs 會員視角」才動得了。留給下一份。

   ── 事前查證（全部撈過，不是推測）──────────────────────
   · 三端呼叫點用「加引號的字串」比對，排除註解命中
   · `checkout_tx` 三端都沒有直接叫 —— 只被 `join_session_tx` /
     `pos_addon_checkout_tx` / `pos_quick_checkout_tx`（全部 DEFINER）呼叫。
     🎯 DEFINER 裡面呼叫時**呼叫端的權限不會被檢查**（硬規則 2.5 的反向），
       所以收掉 `checkout_tx` 的 anon 不會打壞任何一條結帳路徑。
   · `_charge_core` 被 `charge_fnb_tx` / `charge_matched_tx` /
     `charge_private_tx`（三支都是 INVOKER）呼叫，而**那三支都沒有前端在叫**，
     後兩支本來就不給 anon。三支一起收才不會留下「外層叫得動、內層失敗」。
   · `topup_tx` **沒有 PUBLIC**（只有明確授權）；其餘 13 支兩條都有
     ⇒ 兩個方向都要收（硬規則 2.6b）。
   ============================================================ */


/* ── ⓪ guard：14 支的簽名要逐字對得上 ─────────────────────
   ⚠ `revoke` 對不存在的簽名會報錯（那算好事），
     但**對「存在卻是別的多載」不會** —— 所以先擋。 */
do $$
declare v_n int;
begin
  select count(*) into v_n
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
    and (p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')') in (
      'calc_session_fee_tx(p_session_id uuid, p_join_type text, p_member_id uuid)',
      'check_session_blocks_tx(p_session_id uuid, p_member_id uuid)',
      'get_session_member_orders_tx(p_session_id uuid, p_member_id uuid)',
      'has_daypass_tx(p_org_id uuid, p_member_id uuid, p_store_id uuid)',
      'join_session_tx(p_session_id uuid, p_member_id uuid, p_join_type text, p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_staff_id uuid, p_idempotency_key text, p_pay_for uuid[], p_items jsonb)',
      'pos_add_member_note_tx(p_org_id uuid, p_member_id uuid, p_note text, p_staff_id uuid)',
      'pos_addon_checkout_tx(p_session_id uuid, p_member_id uuid, p_items jsonb, p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_idempotency_key text, p_staff_id uuid)',
      'pos_checkout_with_topup_tx(p_session_id uuid, p_member_id uuid, p_join_type text, p_items jsonb, p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_pay_for uuid[], p_staff_id uuid, p_idempotency_key text, p_topup_points bigint, p_topup_bonus bigint, p_topup_amount bigint, p_topup_method text, p_topup_cash_received bigint, p_topup_change_given bigint)',
      'pos_member_detail_tx(p_org_id uuid, p_member_id uuid)',
      'pos_quick_checkout_tx(p_member_id uuid, p_store_id uuid, p_items jsonb, p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_idempotency_key text, p_staff_id uuid, p_topup_points bigint, p_topup_amount bigint, p_topup_method text, p_topup_cash_received bigint, p_topup_change_given bigint, p_note text)',
      'topup_tx(p_member_id uuid, p_store_id uuid, p_points bigint, p_amount_twd bigint, p_pay_method text, p_idempotency_key text, p_bonus_points bigint, p_external_ref text, p_staff_id uuid, p_note text)',
      'checkout_tx(p_member_id uuid, p_store_id uuid, p_items jsonb, p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_idempotency_key text, p_staff_id uuid)',
      'charge_fnb_tx(p_member_id uuid, p_order_id uuid, p_points bigint, p_idempotency_key text, p_store_id uuid)',
      '_charge_core(p_member_id uuid, p_amount bigint, p_type txn_type, p_idempotency_key text, p_store_id uuid, p_served_store_id uuid, p_staff_id uuid, p_ref_table text, p_ref_id uuid, p_counter text)'
    );
  if v_n <> 14 then
    raise exception '簽名對不上（找到 % 支，期望 14）—— 先撈 pg_proc 確認再跑', v_n;
  end if;
end $$;


/* ============================================================
   A 群：POS 專用的 11 支
   收 public ＋ anon，🔴 **保留 authenticated**（POS 靠它）
   ============================================================ */

-- 檯費試算（join_session_tx 內部也會叫）
revoke execute on function public.calc_session_fee_tx(uuid, text, uuid) from public;
revoke execute on function public.calc_session_fee_tx(uuid, text, uuid) from anon;

-- 入座前的封鎖檢查
revoke execute on function public.check_session_blocks_tx(uuid, uuid) from public;
revoke execute on function public.check_session_blocks_tx(uuid, uuid) from anon;

-- 桌帳：某位客人在這一桌的消費
revoke execute on function public.get_session_member_orders_tx(uuid, uuid) from public;
revoke execute on function public.get_session_member_orders_tx(uuid, uuid) from anon;

-- 當日暢打
revoke execute on function public.has_daypass_tx(uuid, uuid, uuid) from public;
revoke execute on function public.has_daypass_tx(uuid, uuid, uuid) from anon;

-- 🔴 入座並收檯費（會收錢）
revoke execute on function public.join_session_tx(uuid, uuid, text, uuid[], bigint, jsonb, uuid, text, uuid[], jsonb) from public;
revoke execute on function public.join_session_tx(uuid, uuid, text, uuid[], bigint, jsonb, uuid, text, uuid[], jsonb) from anon;

-- 店員備註
revoke execute on function public.pos_add_member_note_tx(uuid, uuid, text, uuid) from public;
revoke execute on function public.pos_add_member_note_tx(uuid, uuid, text, uuid) from anon;

-- 🔴 加購結帳（會收錢）
revoke execute on function public.pos_addon_checkout_tx(uuid, uuid, jsonb, uuid[], bigint, jsonb, text, uuid) from public;
revoke execute on function public.pos_addon_checkout_tx(uuid, uuid, jsonb, uuid[], bigint, jsonb, text, uuid) from anon;

-- 🔴 桌邊結帳含儲值（會收錢、會加點數）
revoke execute on function public.pos_checkout_with_topup_tx(uuid, uuid, text, jsonb, uuid[], bigint, jsonb, uuid[], uuid, text, bigint, bigint, bigint, text, bigint, bigint) from public;
revoke execute on function public.pos_checkout_with_topup_tx(uuid, uuid, text, jsonb, uuid[], bigint, jsonb, uuid[], uuid, text, bigint, bigint, bigint, text, bigint, bigint) from anon;

-- 會員查詢（餘額、等級、最近消費、手機）
revoke execute on function public.pos_member_detail_tx(uuid, uuid) from public;
revoke execute on function public.pos_member_detail_tx(uuid, uuid) from anon;

-- 🔴 快速結帳（會收錢、會加點數）
revoke execute on function public.pos_quick_checkout_tx(uuid, uuid, jsonb, uuid[], bigint, jsonb, text, uuid, bigint, bigint, text, bigint, bigint, text) from public;
revoke execute on function public.pos_quick_checkout_tx(uuid, uuid, jsonb, uuid[], bigint, jsonb, text, uuid, bigint, bigint, text, bigint, bigint, text) from anon;

/* 🔴 儲值 —— 這一支是這批裡最嚴重的：它直接加 wallets.balance，
   而且**沒有 PUBLIC**（所以只要收 anon 這一行；下面那行 public 是空操作，
   刻意留著讓兩個方向一眼看得到，同硬規則 2.6b）。 */
revoke execute on function public.topup_tx(uuid, uuid, bigint, bigint, text, text, bigint, text, uuid, text) from public;
revoke execute on function public.topup_tx(uuid, uuid, bigint, bigint, text, text, bigint, text, uuid, text) from anon;


/* ============================================================
   B 群：三端都沒有前端在叫的 3 支
   連 authenticated 一起收，只留 service_role
   ============================================================ */

/* `checkout_tx` —— CLAUDE.md 明寫「**前端永遠不可以直接呼叫**」
   （它是 SECURITY INVOKER，POS 用 anon 直接叫會被 RLS 濾成
     「什麼都沒發生而且不報錯」）。
   ✅ 實際查證：三端 0 個呼叫點，只被三支 DEFINER 包裝內部呼叫。 */
revoke execute on function public.checkout_tx(uuid, uuid, jsonb, uuid[], bigint, jsonb, text, uuid) from public;
revoke execute on function public.checkout_tx(uuid, uuid, jsonb, uuid[], bigint, jsonb, text, uuid) from anon, authenticated;
grant  execute on function public.checkout_tx(uuid, uuid, jsonb, uuid[], bigint, jsonb, text, uuid) to service_role;

/* 舊世代（`wallet_txns.type` 那一代的 `_charge_core` 家族，待辦 12／28）。
   ⚠ 兩支一起收：`charge_fnb_tx` 呼叫 `_charge_core`，而兩支**都是 INVOKER**
     ⇒ 只收內層的話會變成「外層叫得動、內層失敗」，那比兩層都通更難查。 */
revoke execute on function public.charge_fnb_tx(uuid, uuid, bigint, text, uuid) from public;
revoke execute on function public.charge_fnb_tx(uuid, uuid, bigint, text, uuid) from anon, authenticated;
grant  execute on function public.charge_fnb_tx(uuid, uuid, bigint, text, uuid) to service_role;

revoke execute on function public._charge_core(uuid, bigint, txn_type, text, uuid, uuid, uuid, text, uuid, text) from public;
revoke execute on function public._charge_core(uuid, bigint, txn_type, text, uuid, uuid, uuid, text, uuid, text) from anon, authenticated;
grant  execute on function public._charge_core(uuid, bigint, txn_type, text, uuid, uuid, uuid, text, uuid, text) to service_role;


/* ============================================================
   驗證段
   🎯 這一份最重要的**不是「擋住了嗎」，是「收銀機還能用嗎」** ——
     只驗擋住那一半的話，「把 authenticated 也收掉」會全綠而店裡當機。
   ============================================================ */
do $$
declare
  v_org uuid; v_mem uuid;
  v_anon text; v_auth text; v_evt text;
begin
  select m.org_id, m.id into v_org, v_mem
  from public.members m
  where m.is_test and m.deleted_at is null
  order by m.created_at
  limit 1;

  /* ⚠ 找不到樣本要**出聲**，不要安靜跳過（2026-09-04 那次兩格沒出現，
     而我以為全過 —— 而沒出現的正好是「該通的有沒有通」）。 */
  if v_mem is null then
    perform set_config('migi.anon', '⚪ 找不到測試會員，⑥⑦⑧ 三格測不了', true);
    perform set_config('migi.auth', '⚪ 同上', true);
    perform set_config('migi.evt',  '⚪ 同上', true);
    return;
  end if;

  /* ── ⑥ anon 叫 POS 的會員查詢 → 應該被擋 ───────────────
     ⚠ 挑 `pos_member_detail_tx` 是因為它**唯讀** ——
       不可以拿 `topup_tx` 那一族來測，那會真的加點數。 */
  begin
    set local role anon;
    perform public.pos_member_detail_tx(v_org, v_mem);
    reset role;
    v_anon := '🔴 anon 仍然叫得動 —— 沒收到';
  exception when insufficient_privilege then
    reset role; v_anon := '✅ anon 被擋（permission denied）';
  when others then
    reset role; v_anon := '⚠ 被擋了但不是權限錯誤：' || coalesce(sqlerrm, '(無訊息)');
  end;

  /* ── ⑦ 🎯 正對照：authenticated（＝登入後的 POS）→ 應該成功。
     🔴 **這一格才是「收銀機沒壞」的證據。** 少了它，
       一份把 authenticated 也收掉的 SQL 會全綠而店裡當機。 */
  begin
    set local role authenticated;
    perform public.pos_member_detail_tx(v_org, v_mem);
    reset role;
    v_auth := '✅ authenticated 叫得動（POS 登入後照常運作）';
  exception when others then
    reset role; v_auth := '🔴 POS 會壞：' || coalesce(sqlerrm, '(無訊息)');
  end;

  /* ── ⑧ 🎯 負對照：埋點的 anon **必須還在**。
     🔴 收了的話 `member_session` 探針在 no_login 那一刻寫不進去
       ⇒ 探針看起來全綠，而那是假的。
     ⚠ 這一格會真的寫一列，所以整段包在會回滾的子交易裡
       （`raise` 讓子交易回滾，plpgsql 變數不受影響）。 */
  begin
    set local role anon;
    perform public.log_app_event_tx(
      p_org_id => v_org, p_member_id => null,
      p_event => 'migi_probe_grant', p_props => '{}'::jsonb,
      p_client_ts => now(), p_store_id => null);
    reset role;
    raise exception 'migi_rollback_ok';
  exception when others then
    reset role;
    v_evt := case
      when sqlerrm = 'migi_rollback_ok' then '✅ anon 仍然寫得進去（測試那一列已回滾）'
      when sqlerrm ~* 'permission denied' then '🔴 埋點被誤收了 —— 探針會開始說謊'
      else '⚠ ' || coalesce(sqlerrm, '(無訊息)') end;
  end;

  perform set_config('migi.anon', v_anon, true);
  perform set_config('migi.auth', v_auth, true);
  perform set_config('migi.evt',  v_evt,  true);
end $$;

select
  /* ── ① A 群 11 支：anon／PUBLIC 要沒了，**authenticated 要還在** ── */
  coalesce((
    select string_agg(
      case when exists (select 1 from aclexplode(p.proacl) a
                         where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
        or (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                         where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
      then '🔴 ' || p.proname || ' 還叫得動'
      when not exists (select 1 from aclexplode(p.proacl) a
                        where a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE')
      then '🔴 ' || p.proname || ' 的 authenticated 被誤收（POS 會壞）'
      else '✅ ' || p.proname end,
      E'\n' order by p.proname)
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and p.proname in ('calc_session_fee_tx','check_session_blocks_tx','get_session_member_orders_tx',
                        'has_daypass_tx','join_session_tx','pos_add_member_note_tx','pos_addon_checkout_tx',
                        'pos_checkout_with_topup_tx','pos_member_detail_tx','pos_quick_checkout_tx','topup_tx')
  ), '🔴 一支都找不到') as "① A 群：anon/PUBLIC 沒了、authenticated 還在",

  /* ── ② B 群 3 支：三個角色都要沒了，service_role 要在 ── */
  coalesce((
    select string_agg(
      p.proname
      || '　anon：'  || case when exists (select 1 from aclexplode(p.proacl) a where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE') then '🔴 還在' else '✅ 沒了' end
      || '　PUBLIC：' || case when (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee=0 and a.privilege_type='EXECUTE')) then '🔴 還在' else '✅ 沒了' end
      || '　auth：'  || case when exists (select 1 from aclexplode(p.proacl) a where a.grantee='authenticated'::regrole::oid and a.privilege_type='EXECUTE') then '🔴 還在' else '✅ 沒了' end
      || '　service_role：' || case when exists (select 1 from aclexplode(p.proacl) a where a.grantee='service_role'::regrole::oid and a.privilege_type='EXECUTE') then '✅ 有' else '🔴 沒有' end,
      E'\n' order by p.proname)
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and p.proname in ('checkout_tx','charge_fnb_tx','_charge_core')
  ), '🔴 一支都找不到') as "② B 群：三個角色都收掉",

  /* ── ③ 全庫數量。期望值當場查出來的（硬規則 3.56）：
       anon 明確  128 − 14 這批 = 114
       PUBLIC     124 − 13 = 111　（topup_tx 本來就沒有 PUBLIC，所以是 −13 不是 −14）
       函式總數   181，這一批不新增不刪除 ⇒ 不變 */
  (select
     '　anon 明確：' || count(*) filter (where exists (
        select 1 from aclexplode(p.proacl) a
         where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE'))
     || '（期望 114 ＝ 128 − 14）'
     || E'\n　PUBLIC　　：' || count(*) filter (where p.proacl is null or exists (
        select 1 from aclexplode(p.proacl) a
         where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
     || '（期望 111 ＝ 124 − 13）'
     || E'\n　函式總數　：' || count(*) || '（期望 181，不變）'
   from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
  ) as "③ 全庫數量",

  /* ── ④ 🎯 負對照：刻意排除的兩支 ＋ 會員端常用的，anon 都要還在。
       過度阻擋跟沒擋一樣糟，而且更難發現（硬規則 3.55）。 */
  coalesce((
    select string_agg(
      p.proname || '：' || case when exists (select 1 from aclexplode(p.proacl) a
        where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
      then '✅ anon 還在' else '🔴 被誤傷了' end, E'\n' order by p.proname)
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and p.proname in ('log_app_event_tx', 'get_my_orders_tx', 'get_wallet_tx',
                        'get_my_profile_tx', 'list_tables_tx', 'get_session_tx')
  ), '🔴 一支都找不到') as "④ 負對照：排除的與會員端沒被誤傷",

  coalesce(nullif(current_setting('migi.anon', true), ''), '🔴 沒有訊息') as "⑤ 實測：anon 叫 pos_member_detail_tx",
  coalesce(nullif(current_setting('migi.auth', true), ''), '🔴 沒有訊息') as "⑥ 🎯 正對照：登入後的 POS 還能用嗎",
  coalesce(nullif(current_setting('migi.evt',  true), ''), '🔴 沒有訊息') as "⑦ 🎯 負對照：埋點的 anon 還在嗎",

  /* ── ⑧ 收完之後還剩哪些「anon ＋ 只信參數」。
       ⚠ **不是通過條件**，是給下一份看的清單。
         期望剩下 2 支：`log_app_event_tx`（刻意留）與
         `get_my_orders_tx`（要先決定店員視角怎麼處理）。 */
  coalesce((
    select string_agg(p.proname, '　' order by p.proname)
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and pg_get_function_identity_arguments(p.oid) like '%p_member_id%'
      and exists (select 1 from aclexplode(p.proacl) a
                   where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
      and pg_get_functiondef(p.oid) !~ 'current_member_id\(\)'
  ), '（沒有了）') as "⑧ 參考：還剩哪些 anon＋只信參數";
