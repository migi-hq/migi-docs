/* ============================================================
   刪掉死碼 ＋ 內部呼叫改具名參數
   2026-08-25

   ✅ **這支不用等部署，現在就能跑。**
      沒有任何簽名變動 → 沒有 DROP（除了那支死碼）→ 不會丟 GRANT →
      已部署的前端不受影響。

   ── 為什麼不是「拿掉贈點參數」（原訂的甲）──────────────
   原本要順便把 topup_tx 的 p_bonus_points 與
   pos_checkout_with_topup_tx 的 p_topup_bonus 從簽名裡刪掉。
   重新權衡後放棄，理由是**產出與風險不成比例**：

     產出：簽名少兩個參數。**使用者看不到任何差別。**
     代價：動三支金流函式、DROP 後要補 GRANT、部署順序不能錯
          （順序反了 → 桌邊含儲值的結帳 404，客人站在櫃檯前結不了帳）。

   而「拿掉參數」原本要防的事 —— 有人送了贈點值卻以為有效 ——
   **topup_tx 已經自己處理掉了**：它回傳 `bonus_ignored`，
   呼叫端送的值與實算不同時主動標出來。

   ⚠ 大廠的「內部 API 該走完 contract」是對的原則，
     但那是**在沒有其他事情在跑的時候**做的清理。
     2026-08-25 這天已經出過兩次事故（build 掛掉、topup_tx 權限），
     每動一次金流函式就是再開一次暴露窗口。
   → 參數留著的成本是「認知負擔」，那個可以等；
     而這支檔案裡**真正有價值的兩件事跟拿掉參數無關**，先做那兩件。

   📌 待辦：contract 第三步（真的拿掉兩個參數）延後，
      前端已經三個版本沒送了，隨時可以做，不急。
   ============================================================ */


/* ──────────────────────────────────────────────────────────
   一、刪掉 wallet_topup_tx（死碼）

   查證（2026-08-25）：
     · 三個前端的 rpc('...') 名單裡都沒有
     · 沒有任何函式呼叫它
     · 沒有觸發器、沒有 pg_cron 排程

   🔴 而且它的簽名讓人不安：
       wallet_topup_tx(p_member_id, p_amount, p_idempotency_key,
                       p_external_ref, p_store_id)   INVOKER，anon 可執行
     **沒有任何付款或授權參數** —— 給 member uuid 和金額就加點，
     而它內部呼叫 topup_tx（DEFINER），所以自己是 INVOKER 也擋不住實際寫入。
     裡面可能有守衛，但**既然是死碼，刪掉同時解決「要不要看懂它」這個問題**。

   ⚠ 這讓刪除從「整理」變成「該做的」。
   ⚠ 這是本檔唯一的 DROP，而它刪掉之後不重建，所以沒有 GRANT 要補。
   ────────────────────────────────────────────────────────── */

drop function if exists public.wallet_topup_tx(uuid, bigint, text, text, uuid);


/* ──────────────────────────────────────────────────────────
   二、pos_checkout_with_topup_tx：內部呼叫 topup_tx 改成具名參數

   🔴 這是修一個**還沒發生但遲早會發生**的坑。
   線上版是位置參數：

       topup_tx(p_member_id, v_s.store_id, p_topup_points, p_topup_amount,
                p_topup_method, v_base || ':topup', p_topup_bonus,
                null, p_staff_id, 'POS 結帳時儲值')

   topup_tx 的簽名是
       (member, store, points, amount_twd, pay_method, idempotency_key,
        bonus_points, external_ref, staff_id, note)

   哪天 topup_tx 少一個參數（例如真的拿掉 bonus_points），
   後面三個會**全部往前位移**：null 落到 staff_id、staff_id 落到 note。
   🔴 **而型別剛好相容時不會報錯** —— 只會靜靜地把資料寫到錯的欄位。

   改成具名之後這種錯永遠不可能發生。
   pos_quick_checkout_tx（2026-08-25 建立）從一開始就是具名的。

   ⚠ **簽名一個字都沒動**（含 p_topup_bonus），所以用 CREATE OR REPLACE：
     不 DROP → 不丟 GRANT → 前端不用先部署。
   ⚠ p_topup_bonus 仍然照樣傳給 topup_tx（它會忽略）——
     **維持行為完全一致**。這支檔案只改「怎麼呼叫」，不改「呼叫什麼」。
   ────────────────────────────────────────────────────────── */

create or replace function public.pos_checkout_with_topup_tx(
  p_session_id          uuid,
  p_member_id           uuid,
  p_join_type           text   default 'opener',
  p_items               jsonb  default null,
  p_coupon_ids          uuid[] default null,
  p_points_used         bigint default 0,
  p_payments            jsonb  default null,
  p_pay_for             uuid[] default null,
  p_staff_id            uuid   default null,
  p_idempotency_key     text   default null,
  p_topup_points        bigint default 0,
  p_topup_bonus         bigint default 0,
  p_topup_amount        bigint default 0,
  p_topup_method        text   default 'cash',
  p_topup_cash_received bigint default null,
  p_topup_change_given  bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_s      record;
  v_topup  jsonb := null;
  v_join   jsonb := null;
  v_base   text;
  v_seated boolean;
  v_extra  int := 0;
  v_mode   text;
begin
  if p_topup_points > 0 and coalesce(p_idempotency_key, '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'idempotency_key_required',
      'message', '含儲值的結帳必須帶冪等鍵');
  end if;

  select * into v_s from table_sessions where id = p_session_id;
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found');
  end if;
  if v_s.status <> 'open' then
    return jsonb_build_object('ok', false, 'reason', 'session_closed',
      'message', '此場次已收桌或已作廢');
  end if;

  -- 由資料庫判斷是否已入座，不採信前端傳來的推測值
  select exists (
    select 1 from session_players sp
     where sp.session_id = p_session_id
       and sp.member_id  = p_member_id
       and sp.left_at is null) into v_seated;

  if p_items is not null and jsonb_typeof(p_items) = 'array' then
    v_extra := jsonb_array_length(p_items);
  end if;

  v_mode := case
              when not v_seated   then 'join'
              when v_extra > 0    then 'addon'
              else 'topup_only'
            end;

  if v_mode = 'topup_only' and p_topup_points <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'nothing_to_do',
      'message', '這位客人已入座，請選擇商品或儲值');
  end if;

  v_base := coalesce(p_idempotency_key,
                     p_session_id::text || ':' || p_member_id::text);

  -- ══ 原子區塊：任何一步 raise，整段回滾 ══
  begin

    if p_topup_points > 0 then
      /* ★ 2026-08-25 改成具名參數（唯一的改動）。
         原本是位置參數，topup_tx 哪天少一個參數就會整排位移，
         而型別相容時不會報錯，只會把值寫到錯的欄位。

         ⚠ p_bonus_points 照樣傳（值被 topup_tx 忽略，由
           calc_topup_bonus_tx 從 topup_plans 算）——
           **明著傳而不是靜靜省略**：省略的話，哪天有人把忽略邏輯拿掉，
           行為會無聲改變。傳過去則永遠是「送了但被忽略」這個明確狀態，
           而 topup_tx 的回傳有 bonus_ignored 會標出來。 */
      v_topup := topup_tx(
        p_member_id       => p_member_id,
        p_store_id        => v_s.store_id,
        p_points          => p_topup_points,
        p_amount_twd      => p_topup_amount,
        p_pay_method      => p_topup_method,
        p_idempotency_key => v_base || ':topup',
        p_bonus_points    => p_topup_bonus,
        p_external_ref    => null,
        p_staff_id        => p_staff_id,
        p_note            => 'POS 結帳時儲值');

      -- 回填桌次脈絡與實收找零。
      -- 實收找零只有在「現金全部歸儲值」時才會有值 ——
      -- 消費有現金要收時，前端會把它記在 order_payments 那邊，
      -- 兩邊不會同時有值（實體收款是一次事件，不該重複記錄）。
      update topup_orders
         set session_id    = p_session_id,
             cash_received = p_topup_cash_received,
             change_given  = p_topup_change_given
       where id = (v_topup ->> 'topup_id')::uuid;
    end if;

    if v_mode = 'join' then
      v_join := join_session_tx(
        p_session_id, p_member_id, p_join_type, p_coupon_ids,
        coalesce(p_points_used, 0), p_payments, p_staff_id,
        v_base || ':order', p_pay_for, p_items);

    elsif v_mode = 'addon' then
      v_join := pos_addon_checkout_tx(
        p_session_id, p_member_id, p_items, p_coupon_ids,
        coalesce(p_points_used, 0), p_payments,
        v_base || ':order', p_staff_id);
    end if;

    -- 兩支結帳函式的業務錯誤都是「回傳 ok:false」而不是拋例外。
    -- 不主動 raise 的話交易會照常提交 —— 儲值就留下來了。
    if v_join is not null
       and not coalesce((v_join ->> 'ok')::boolean, false) then
      raise exception 'checkout_failed:%',
        coalesce(v_join ->> 'reason', 'unknown') using errcode = 'P0001';
    end if;

  exception
    when others then
      if SQLERRM like 'checkout_failed:%' then
        return jsonb_build_object('ok', false,
          'reason', split_part(SQLERRM, ':', 2),
          'stage', 'checkout', 'mode', v_mode,
          'message', case when p_topup_points > 0
                          then '結帳失敗，儲值已一併取消'
                          else '結帳失敗' end);
      end if;
      return jsonb_build_object('ok', false, 'reason', 'topup_failed',
        'stage', case when v_topup is null then 'topup' else 'checkout' end,
        'mode', v_mode, 'message', SQLERRM);
  end;

  return jsonb_build_object(
    'ok', true, 'mode', v_mode,
    'topup', v_topup, 'checkout', v_join,
    'new_balance', v_topup ->> 'new_balance');
end $function$;


/* ============================================================
   驗證段（單一 SELECT）

   ⚠ 煙霧測試走「場次不存在」那條路 ——
     它在 select from table_sessions 之後就回 ok:false，
     **不會建任何訂單或儲值單、不會動一毛錢**。
     ⚠ 這支的業務錯誤是**回傳 ok:false 不是拋例外**，
       所以不需要 DO 區塊接，直接在 SELECT 裡讀回傳值就好。
   ============================================================ */

select 序, 項目, 結果 from (

  select 0 as 序, '① 死碼刪掉了嗎' as 項目,
         (case when not exists (
                 select 1 from pg_proc
                  where pronamespace = 'public'::regnamespace
                    and prokind = 'f' and proname = 'wallet_topup_tx')
               then '✅ wallet_topup_tx 已不存在'
               else '🔴 還在' end) as 結果

  union all
  /* ② 版本數 —— CREATE OR REPLACE 不該產生多載，
        真的多出來代表簽名被我改到了（那就會需要 DROP 與部署順序）。 */
  select 0, '② pos_checkout_with_topup_tx 版本數',
         (case when count(*) = 1 then '✅ 1 個（簽名沒變）'
               else '🔴 ' || count(*)::text || ' 個 —— 簽名被改到了' end)
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname = 'pos_checkout_with_topup_tx'

  union all
  /* ③ 🔴 GRANT 有沒有還在。
        本檔沒有 DROP 它，所以權限應該原封不動 ——
        這一項是確認「我以為沒 DROP」這件事是真的。
        忘了的症狀是 permission denied，而且**只有前端會遇到**。 */
  select 0, '③ EXECUTE 授權還在嗎',
         string_agg(p.proname || '：anon ' ||
                    (case when has_function_privilege('anon', p.oid, 'EXECUTE') then '✅' else '🔴 沒了' end) ||
                    '／authenticated ' ||
                    (case when has_function_privilege('authenticated', p.oid, 'EXECUTE') then '✅' else '🔴 沒了' end),
                    '　│　' order by p.proname)
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname in ('topup_tx', 'pos_checkout_with_topup_tx')

  union all
  /* ④ 簽名一個字都沒動 —— 前端不用重新部署的前提 */
  select 0, '④ 簽名',
         coalesce((select pg_get_function_arguments(p.oid)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
                      and p.proname = 'pos_checkout_with_topup_tx' limit 1), '🔴 不存在')

  union all
  /* ⑤ 內部呼叫真的改成具名了 */
  select 0, '⑤ 內部呼叫是具名的嗎',
         (case when exists (
                 select 1 from pg_proc p
                  where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
                    and p.proname = 'pos_checkout_with_topup_tx'
                    and pg_get_functiondef(p.oid) ilike '%p_idempotency_key =>%')
               then '✅ 具名' else '🔴 還是位置參數' end)

  union all
  /* ⑥ 煙霧測試：真的呼叫一次（硬規則 7）。
        場次不存在 → 回 session_not_found，不碰任何錢。 */
  select 1, '⑥ 煙霧測試',
         coalesce((pos_checkout_with_topup_tx(
                     p_session_id => gen_random_uuid(),
                     p_member_id  => gen_random_uuid()) ->> 'reason'),
                  '🔴 沒有 reason')

) x order by 序, 項目;
