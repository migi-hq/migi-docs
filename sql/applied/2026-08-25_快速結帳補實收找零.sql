/* ============================================================
   快速結帳補實收找零
   2026-08-25 · pos_quick_checkout_tx 改簽名（+2 參數）

   ✅ 已執行並驗證通過（2026-08-25）
      版本數 1（舊的 12 參數版已清掉）/ SECURITY DEFINER /
      cash_received 與 change_given 都在 / 簽名無 bonus /
      煙霧測試正確拋「沒有可結帳的品項，也沒有儲值」。
      ⚠ 第 ⑤ 項當時回報「🔴 竟然引用了桌次」是**假警報**，
        已逐行證實只有註解含 session_id，檢查條件已修正（見下方 ⑤ 的說明）。

   ── 為什麼要補 ────────────────────────────────────────
   建立時我少了 p_topup_cash_received / p_topup_change_given。
   當時的理由是「topup_tx 的簽名裡沒有這兩個，現行 topupMember() 也沒送」——
   🔴 **那個推論漏了一層**：topup_tx 確實沒有，但
      pos_checkout_with_topup_tx 是**自己 update topup_orders**：

          update topup_orders
             set session_id    = p_session_id,
                 cash_received = p_topup_cash_received,
                 change_given  = p_topup_change_given
           where id = (v_topup ->> 'topup_id')::uuid;

   ── 為什麼在快速結帳更嚴重 ────────────────────────────
   🔴 純儲值時 orderCash = 0 → 前端的 payments 是 null，
      **沒有任何一張 order_payments 可以承接實收與找零**。
      不補的話「收 2000 找 500」完全不落地，交班日結對不起來（待辦 18）。
      桌邊結帳至少常常有消費那張單可以記，純儲值一張都沒有。

   ── 為什麼現在改成本最低 ──────────────────────────────
   ✅ 這支函式**還沒有任何東西呼叫**（前端還沒做完）。
      現在 DROP 重建是零風險；上線之後改要「先推前端再跑 SQL」，
      順序反了已部署的 POS 會 404。

   ── 與現行寫法的兩個差異（刻意） ──────────────────────
   ⚠ 不回填 session_id —— 快速結帳沒有桌次，那正是它存在的理由。
   ⚠ topup_orders **沒有** order_payments 那種自洽約束
      （已查證：只有 amount_twd > 0 / points > 0 / bonus_points >= 0 /
        pay_method 白名單 / status 白名單）。
      → 不必滿足「找零 = 實收 − 金額」，前端怎麼拆就怎麼記。
   ============================================================ */

-- 硬規則 2：簽名要變，先 DROP 舊的（12 個參數那版），否則會建出多載
drop function if exists public.pos_quick_checkout_tx(
  uuid, uuid, jsonb, uuid[], bigint, jsonb, text, uuid, bigint, bigint, text, text);
-- 新簽名如果先前試跑過也一併清掉
drop function if exists public.pos_quick_checkout_tx(
  uuid, uuid, jsonb, uuid[], bigint, jsonb, text, uuid, bigint, bigint, text, bigint, bigint, text);

create or replace function public.pos_quick_checkout_tx(
  p_member_id           uuid,
  p_store_id            uuid,
  p_items               jsonb   default null,
  p_coupon_ids          uuid[]  default null,
  p_points_used         bigint  default 0,
  p_payments            jsonb   default null,
  p_idempotency_key     text    default null,
  p_staff_id            uuid    default null,
  p_topup_points        bigint  default 0,
  p_topup_amount        bigint  default 0,
  p_topup_method        text    default 'cash',
  p_topup_cash_received bigint  default null,
  p_topup_change_given  bigint  default null,
  p_note                text    default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_topup      jsonb;
  v_order      jsonb;
  v_has_topup  boolean;
  v_has_items  boolean;
  v_mode       text;
  v_balance    bigint;
begin
  /* 冪等鍵必填。店員在網路慢時按第二下是常態，
     沒有它就是收兩次錢 —— 這不是防呆是防帳。 */
  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    raise exception 'idempotency_key 必填';
  end if;

  if p_member_id is null then
    raise exception '快速結帳必須指定會員（checkout_tx 會查錢包，沒有會員一定拋錯）';
  end if;
  if p_store_id is null then
    raise exception 'store_id 必填';
  end if;

  v_has_topup := coalesce(p_topup_amount, 0) > 0 or coalesce(p_topup_points, 0) > 0;

  /* ⚠ 先判 jsonb_typeof。p_items 若被送成物件或字串，
     jsonb_array_length 會直接拋型別錯誤而不是回 0 ——
     那個錯誤訊息店員看不懂，不如在這裡講清楚。 */
  v_has_items := p_items is not null
                 and jsonb_typeof(p_items) = 'array'
                 and jsonb_array_length(p_items) > 0;

  if p_items is not null and jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items 必須是陣列，收到的是 %', jsonb_typeof(p_items);
  end if;

  if not v_has_topup and not v_has_items then
    raise exception '沒有可結帳的品項，也沒有儲值';
  end if;

  v_mode := case
              when v_has_topup and v_has_items then 'topup_and_items'
              when v_has_topup                 then 'topup_only'
              else                                  'items_only'
            end;

  /* ── 儲值 ─────────────────────────────────────────────
     一定在結帳之前：客人常常是「先儲值再用點數付」，
     順序反了 checkout_tx 讀到的餘額就是舊的，
     可折抵的點數會少算。

     冪等鍵加 ':topup' 後綴 —— 與 pos_checkout_with_topup_tx 同一套慣例，
     讓報表能靠前綴把同一次收款的兩張單併成一列。

     ⚠ p_points 用 coalesce(nullif(points,0), amount)：
       鏡射前端 topupMember() 的 `points ?? amountTwd`。
       目前 1 元 = 1 點，但兩者語意不同 ——
       日後出現「1000 元買 1200 點」的方案時，用錯就會算錯。 */
  if v_has_topup then
    select topup_tx(
             p_member_id       => p_member_id,
             p_store_id        => p_store_id,
             p_points          => coalesce(nullif(p_topup_points, 0), p_topup_amount),
             p_amount_twd      => p_topup_amount,
             p_pay_method      => p_topup_method,
             p_idempotency_key => p_idempotency_key || ':topup',
             p_staff_id        => p_staff_id,
             p_note            => p_note
           )
      into v_topup;

    /* 回填實收與找零。
       ⚠ 只回填這兩個，**不回填 session_id** ——
         快速結帳沒有桌次，那正是這支函式存在的理由。

       實收找零只有在「現金全部歸儲值」時才會有值：
       消費有現金要收時前端會記在 order_payments 那邊，
       兩邊不會同時有值（實體收款是一次事件，不該重複記錄）。

       ⚠ 認回的鑰匙是 topup_tx 回傳的 topup_id，不是冪等鍵 ——
         冪等重打時 topup_tx 回的是**上次那張單**的 topup_id，
         用它更新等於把同一張單的實收找零覆寫成同樣的值，無害。
       ⚠ v_topup 可能是冪等回傳（沒有 topup_id 的話這個 update 影響 0 列，
         不報錯也不該報錯 —— 那代表這筆先前就記過了）。 */
    if p_topup_cash_received is not null or p_topup_change_given is not null then
      update topup_orders
         set cash_received = p_topup_cash_received,
             change_given  = p_topup_change_given
       where id = nullif(v_topup ->> 'topup_id', '')::uuid;
    end if;
  end if;

  /* ── 商品結帳 ──────────────────────────────────────────
     checkout_tx 是 INVOKER，但在這支 DEFINER 函式裡呼叫時
     生效的角色是 definer，所以 RLS 過得去 ——
     pos_addon_checkout_tx 一直是這樣運作的。 */
  if v_has_items then
    select checkout_tx(
             p_member_id,
             p_store_id,
             p_items,
             p_coupon_ids,
             coalesce(p_points_used, 0),
             p_payments,
             p_idempotency_key || ':order',
             p_staff_id
           )
      into v_order;
  end if;

  /* 餘額以最後一個動作的回傳為準，不自己推算。
     有結帳時 checkout_tx 的 new_balance 已經是「儲值後再扣點」的結果
     （儲值在同一交易的前面跑完了）。 */
  v_balance := coalesce(
                 nullif(v_order ->> 'new_balance', '')::bigint,
                 nullif(v_topup ->> 'new_balance', '')::bigint
               );

  return jsonb_build_object(
    'ok',          true,
    'mode',        v_mode,
    'topup',       v_topup,
    'order',       v_order,
    'new_balance', v_balance
  );
end
$function$;


/* ============================================================
   驗證段（單一 SELECT）
   煙霧測試同前：走「既沒品項也沒儲值」那條路，
   在碰任何資料表之前就拋錯，不會動到一毛錢。
   ============================================================ */

do $$
begin
  begin
    perform pos_quick_checkout_tx(
      p_member_id       => gen_random_uuid(),
      p_store_id        => gen_random_uuid(),
      p_idempotency_key => 'smoke-2026-08-25b'
    );
    perform set_config('migi.smoke', '🔴 竟然沒拋錯 —— 擋牆失效', true);
  exception when others then
    perform set_config('migi.smoke', '✅ 正確拋錯：' || sqlerrm, true);
  end;
end $$;

select 序, 項目, 結果 from (

  select 0 as 序, '① 版本數' as 項目,
         (case when count(*) = 1 then '✅ 1 個（舊的 12 參數版已清掉）'
               else '🔴 ' || count(*)::text || ' 個 —— 有多載，DROP 沒清乾淨' end) as 結果
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'pos_quick_checkout_tx'

  union all
  select 0, '② 權限模式',
         (case when bool_and(p.prosecdef) then '✅ SECURITY DEFINER'
               else '🔴 INVOKER —— POS 用 anon 會靜靜失敗' end)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'pos_quick_checkout_tx'

  union all
  select 0, '③ 新參數到位',
         (case when count(*) = 1 then '✅ cash_received 與 change_given 都在'
               else '🔴 缺參數' end)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'pos_quick_checkout_tx'
     and pg_get_function_arguments(p.oid) like '%p_topup_cash_received%'
     and pg_get_function_arguments(p.oid) like '%p_topup_change_given%'

  union all
  select 0, '④ 仍然沒有贈點參數',
         (case when count(*) = 0 then '✅ 簽名裡沒有 bonus'
               else '🔴 出現贈點參數 —— 贈點只由 topup_tx 決定' end)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'pos_quick_checkout_tx'
     and pg_get_function_arguments(p.oid) ilike '%bonus%'

  union all
  /* ⚠ 2026-08-25 更正：這一項原本連 'session_id' 也列進禁字，
     結果被我自己寫在註解裡的「不回填 session_id」觸發，回報假警報。
     已逐行證實（sql/checks/2026-08-25_驗證快速結帳沒碰桌次.sql）：
     全函式只有第 77 行含 session_id，而那是註解。
     → 禁字只留**表名**。表名不會出現在正常的說明文字裡，欄位名會。
       這是第二次踩同一個形狀（2026-08-23 的 'clerk' 也是被自己的註解觸發）。 */
  select 0, '⑤ 仍然不碰桌次',
         (case when count(*) = 0 then '✅ 內文沒有 table_sessions / session_players'
               else '🔴 竟然引用了桌次' end)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'pos_quick_checkout_tx'
     and (pg_get_functiondef(p.oid) ilike '%table_sessions%'
       or pg_get_functiondef(p.oid) ilike '%session_players%')

  union all
  select 0, '⑥ 簽名',
         coalesce((select pg_get_function_arguments(p.oid)
                     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public' and p.proname = 'pos_quick_checkout_tx'
                    limit 1), '🔴 函式不存在')

  union all
  select 1, '⑦ 煙霧測試',
         coalesce(current_setting('migi.smoke', true), '🔴 沒跑到 —— DO 區塊沒執行')

) x order by 序, 項目;
