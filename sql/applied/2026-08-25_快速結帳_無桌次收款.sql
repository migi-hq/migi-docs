/* ============================================================
   快速結帳：沒有桌次也能收錢
   2026-08-25 · 新增 pos_quick_checkout_tx

   ✅ 已執行並驗證通過（2026-08-25）
      版本數 1 / SECURITY DEFINER / 簽名無 bonus / 內文不碰桌次 /
      煙霧測試正確拋「沒有可結帳的品項，也沒有儲值」。

   📌 驗證順便查出來的事實：
      **orders.channel 是 NOT NULL DEFAULT 'counter'，而且 150 筆全是 counter**
      —— 包含桌邊結帳。也就是這個欄位目前**沒有分辨力**，
      「櫃檯 vs 桌邊」只能靠 session_id 是不是 null。
      → 所以本函式刻意不寫 channel 是對的：只補一邊會讓兩條路的資料
        長得不一樣，而分辨的工作本來就有別人在做。
        等真的有客人掃桌邊 QR 點餐，'table_qr' 才會讓這欄有意義。

   ── 為什麼這支很短 ────────────────────────────────────
   2026-08-25 撈線上版查出：**checkout_tx 本來就不碰桌次**。
     · 簽名裡沒有 p_session_id
     · INSERT orders 也沒有寫 session_id / table_id
       （桌邊訂單的 session_id 是外層包裝事後回填的）
   綁桌次的是外面那三支包裝（join_session_tx / pos_addon_checkout_tx /
   pos_checkout_with_topup_tx），不是結帳核心。

   ⚠ 我一開始從 api.js 看到「每支都送 p_session_id」就推論
     「後端非有桌不可」——**那是看前端推後端，結論反了**。
     只有 pg_proc 算數（硬規則 3）。

   ── 那為什麼還需要這一支 ──────────────────────────────
   🔴 checkout_tx 是 **SECURITY INVOKER**。
   POS 用 anon 沒有 auth session，直接呼叫它 RLS 會把它濾成
   「什麼都沒發生而且不報錯」—— 跟 settle_session_tx 那個洞
   （待辦 3）同一個形狀，也正是硬規則 4 要防的。
   → 前端**永遠不可以直接呼叫 checkout_tx**，一定要走 DEFINER 包裝。

   ── 三種模式 ──────────────────────────────────────────
   checkout_tx 開頭就擋「沒有品項」：
       if p_items is null or jsonb_array_length(p_items) = 0 then raise
   所以純儲值不能走它。本函式分流：
     · topup_only        只叫 topup_tx
     · items_only        只叫 checkout_tx
     · topup_and_items   先儲值再結帳（同一交易）

   ── 回滾 ──────────────────────────────────────────────
   ✅ topup_tx 與 checkout_tx **失敗都是 raise exception**
      （不是 join_session_tx 那種回 { ok:false }）。
      所以這裡**不需要**像 pos_checkout_with_topup_tx 那樣
      自己接住再主動 raise —— 例外自然往上拋，整筆交易回滾。
      「儲值成功但商品沒賣成」的半筆帳不會發生。

   ── 刻意沒有的東西 ────────────────────────────────────
   ⚠ 沒有 p_topup_bonus：2026-08-24 起 topup_tx 自己查 topup_plans 算贈點，
     呼叫端送什麼都不採信。這裡連參數都不開，免得下一個人以為它有用。
   ⚠ 沒有匿名結帳：checkout_tx 有一段
       select balance into v_bal from wallets where member_id = p_member_id for update;
       if v_bal is null then raise exception 'member % 沒有錢包'
     **即使 points_used = 0 也會查**。所以 member_id 必填。
     orders.member_id 欄位雖然可為 null，但**欄位可為 null ≠ 函式接受 null**。
     要做匿名（外帶一杯奶茶）得改 checkout_tx 本身 —— 那是動金流函式，另一批。
   ⚠ 儲值那一半沒有 cash_received / change_given：topup_tx 的簽名裡沒有這兩個，
     現行 topupMember() 也沒送。維持一致，不在這裡發明新行為。
     （商品那一半有 —— 它們在 p_payments 的 JSON 裡，checkout_tx 會讀。）
   ⚠ 不寫 orders.channel：checkout_tx 從頭到尾沒寫過它，
     桌邊結帳也一樣走預設值。在這裡單獨補會讓兩條路的資料長得不一樣。
     驗證段會回報 channel 的預設與現況分佈，看完再決定要不要兩條路一起補。
   ============================================================ */

-- 硬規則 2：新函式也先 DROP，避免先前試跑留下的多載版本
drop function if exists public.pos_quick_checkout_tx(
  uuid, uuid, jsonb, uuid[], bigint, jsonb, text, uuid, bigint, bigint, text, text);

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

   ⚠ 煙霧測試放在 DO 區塊裡，因為 raise exception 在一般 SELECT
     裡會中止整個查詢、也接不住（SQL 沒有 try）。
     結果用 set_config(..., true) 存成**交易內**的設定值再讀回來。
   ⚠ 刻意不用 create temp table：Supabase SQL Editor 會對「建了沒開 RLS 的表」
     跳警告，而那是誤判（temp 表是連線私有、交易結束就消失）。
     與其讓人去判斷一個假警報，不如不要製造它。
   ⚠ 測試刻意用「既沒品項也沒儲值」那條路 ——
     它在碰任何資料表之前就拋錯，**不會動到任何一毛錢**。
   ============================================================ */

do $$
begin
  begin
    perform pos_quick_checkout_tx(
      p_member_id       => gen_random_uuid(),
      p_store_id        => gen_random_uuid(),
      p_idempotency_key => 'smoke-2026-08-25'
    );
    perform set_config('migi.smoke', '🔴 竟然沒拋錯 —— 擋牆失效', true);
  exception when others then
    perform set_config('migi.smoke', '✅ 正確拋錯：' || sqlerrm, true);
  end;
end $$;

select 序, 項目, 結果 from (

  select 0 as 序, '① 版本數' as 項目,
         (case when count(*) = 1 then '✅ 1 個（無多載）'
               else '🔴 ' || count(*)::text || ' 個 —— 有多載，要先 DROP' end) as 結果
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'pos_quick_checkout_tx'

  union all
  select 0, '② 權限模式',
         (case when bool_and(p.prosecdef) then '✅ SECURITY DEFINER'
               else '🔴 INVOKER —— POS 用 anon 會靜靜失敗' end)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'pos_quick_checkout_tx'

  union all
  select 0, '③ 沒有贈點參數',
         (case when count(*) = 0 then '✅ 簽名裡沒有 bonus'
               else '🔴 出現贈點參數 —— 贈點只由 topup_tx 決定' end)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'pos_quick_checkout_tx'
     and pg_get_function_arguments(p.oid) ilike '%bonus%'

  union all
  select 0, '④ 不碰桌次',
         (case when count(*) = 0 then '✅ 內文沒有 table_sessions / session_players'
               else '🔴 竟然引用了桌次' end)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'pos_quick_checkout_tx'
     and (pg_get_functiondef(p.oid) ilike '%table_sessions%'
       or pg_get_functiondef(p.oid) ilike '%session_players%')

  union all
  select 0, '⑤ 簽名',
         coalesce((select pg_get_function_arguments(p.oid)
                     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public' and p.proname = 'pos_quick_checkout_tx'
                    limit 1), '🔴 函式不存在')

  union all
  select 1, '⑥ 煙霧測試',
         coalesce(current_setting('migi.smoke', true), '🔴 沒跑到 —— DO 區塊沒執行')

  /* ⑦⑧ 順便回答一個還沒決定的問題：orders.channel 現在到底長怎樣。
        checkout_tx 從來沒寫過它，所以桌邊訂單也是走預設。
        看完再決定要不要「兩條路一起補」—— 不要只補一邊。 */
  union all
  select 9, '⑦ orders.channel 定義',
         coalesce((select (case when is_nullable = 'YES' then '可為 null' else 'NOT NULL' end)
                          || '　預設 ' || coalesce(column_default, '（無）')
                     from information_schema.columns
                    where table_schema = 'public' and table_name = 'orders'
                      and column_name = 'channel'), '🔴 沒有 channel 欄位')

  union all
  select 9, '⑧ orders.channel 現況',
         coalesce(string_agg(t.k || '：' || t.c::text, '　' order by t.c desc), '（沒有訂單）')
    from (select coalesce(channel, '(null)') as k, count(*) as c
            from orders group by 1) t

) x order by 序, 項目;
