/* ============================================================
   🔴 註冊路徑：收回 anon 執行權 ＋ 停止把別人的 member_id 交出去
   2026-08-30

   ── 完整的攻擊路徑（查證過，不是推測）────────────────
   ```
   anon 直接叫 register_member_tx(org, '隨便一個暱稱', 對方的手機)
     → 手機對得上、沒送 line_user_id → action='existing_phone'
     → 回傳 member_id ＋ display_name ＋ phone
   anon 叫 get_wallet_tx(member_id)      → 餘額、優惠券、點數流水
   anon 叫 get_my_orders_tx(member_id)   → 完整消費明細
   ```
   🔴 **只要知道一支手機號碼就夠了，完全不需要 LINE。**

   ⚠ 而且 Edge Function 的設計被整個繞過：
     `line-login` 的重點是「`line_user_id` 由後端驗簽後取得，前端不能偽造」，
     但 `register_member_tx` 本身是 **anon ＋ PUBLIC 都有** ——
     攻擊者根本不用經過那道門。

   ⚠ 走 Edge Function 也漏：它一定會送 `line_user_id`，所以走到
     `line_conflict` 分支 —— 而那個分支**同樣回傳 member_id 與 display_name**。
     那段程式碼的註解寫著「不回傳對方的 line_user_id —— 那是別人的識別碼」，
     🔴 **但它回傳了 member_id，而 member_id 才是會員端的通行證**
     （待辦 14：身分靠前端傳 `p_member_id`）。
     → 防到了錯的東西。

   ── 這份做兩件事 ────────────────────────────────────
   ① `register_member_tx` 收回 anon／PUBLIC，只留 service_role
      ✅ 安全：三個 repo 掃過，**沒有任何前端直接呼叫**（全是註解），
        Edge Function 用的是 service_role。
   ② `line_conflict` 與 `existing_phone` **不再回傳 member_id／display_name／phone**
      ✅ 安全：Edge Function 只在 `action !== 'line_conflict'` 時用 member_id。

   ⚠ **這份不碰 `rebound`** —— 「手機對得上就自動綁進舊帳號」要不要保留
     是政策決定（簡訊 OTP vs 店員綁定），另案。
     ⚠ 但收回 anon 之後，那條路至少**必須經過 LINE 驗簽**，
       攻擊門檻從「知道一支手機」提高到「知道手機 ＋ 有一個 LINE 帳號」。

   ── 簽名沒變 ⇒ CREATE OR REPLACE，不用 DROP、不丟 GRANT ──
   ⚠ 用定點取代而不是手打全文：這支函式很長，
     從 `pg_get_functiondef` 撈線上版改（硬規則 3），抄錯的風險比較大。
   ============================================================ */

do $$
declare v_old text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_old from pg_proc p
   where p.pronamespace='public'::regnamespace and p.prokind='f'
     and p.proname='register_member_tx';
  if v_old is null then raise exception '找不到 register_member_tx'; end if;

  /* ── 改 ①：line_conflict 不再交出對方的身分 ── */
  v_new := regexp_replace(v_old,
    '''action'',''line_conflict'',\s*''member_id'',\s*v_member\.id,\s*''display_name'',\s*v_member\.display_name,\s*''phone'',\s*v_member\.phone,',
    '''action'',''line_conflict'',');
  if v_new = v_old then raise exception '改①的錨點沒對上'; end if;

  /* ── 改 ②：existing_phone 走自己的回傳，不落到共用那一行 ── */
  v_old := v_new;
  v_new := regexp_replace(v_old,
    '(\s*)select \* into v_member from members where id = v_existing;(\s*)return jsonb_build_object\(''action'',v_action,',
    E'\\1if v_action = ''existing_phone'' then' ||
    E'\\1  return jsonb_build_object(''action'',''existing_phone'',' ||
    E'\\1    ''message'',''這支手機已經是 MIGI 會員了，請用原本的 LINE 帳號登入，或洽櫃檯協助'');' ||
    E'\\1end if;' ||
    E'\\1select * into v_member from members where id = v_existing;\\2return jsonb_build_object(''action'',v_action,');
  if v_new = v_old then raise exception '改②的錨點沒對上'; end if;

  /* 🔴 guard：`regexp_replace` 找不到樣式時不報錯只是原樣回傳 ——
     那正是「跑完沒報錯但什麼都沒發生」的形狀。上面兩個 if 就是在擋這個。 */
  execute v_new;
end $$;

/* 硬規則 2.6 ＋ 2.6b：兩個方向都要收。
   PUBLIC 繼承與 default privileges 的明確授權是兩條不同的路，
   只收一邊是**不會報錯的空操作**。 */
revoke execute on function public.register_member_tx(uuid, text, text, text, uuid, uuid) from public;
revoke execute on function public.register_member_tx(uuid, text, text, text, uuid, uuid) from anon, authenticated;
grant  execute on function public.register_member_tx(uuid, text, text, text, uuid, uuid) to service_role;


/* ============================================================
   驗證（單一 SELECT）

   🎯 **不看 proacl，直接用 anon 的身分實際叫一次。**
     `has_function_privilege` 分不出「明確授權」與「PUBLIC 繼承」（硬規則 2.6），
     而且讀權限表證明不了「真的擋得住」。`set local role anon` 才算數
     （同硬規則 21-5：只有真的用那個身分查一次算數）。

   🎯 **正對照**：同一個 anon 身分要**還叫得動 `get_wallet_tx`** ——
     否則「全部都被擋」與「該擋的擋了」長得一模一樣（硬規則 3.55）。
   ============================================================ */
do $$
declare v_a text; v_b text; v_c text;
begin
  begin
    set local role anon;

    -- ① 該擋的：anon 直接叫註冊
    begin
      perform register_member_tx('11111111-1111-1111-1111-111111111111', '測試', '0910000001');
      v_a := '🔴 還是叫得動 —— 洞沒堵到';
    exception
      when insufficient_privilege then v_a := '✅ permission denied（擋住了）';
      when others then v_a := '⚠ 擋住了但錯誤不同：' || sqlerrm;
    end;

    -- ② 🎯 正對照：不該擋的
    begin
      perform get_wallet_tx('69016205-afde-4036-95a6-5893c9d0e5fe', 1);
      v_b := '✅ 還叫得動（正確 —— 沒有誤傷會員端）';
    exception
      when insufficient_privilege then v_b := '🔴 也被擋了 —— 我收過頭了，錢包會壞';
      when others then v_b := '✅ 叫得動（回傳有另外的錯：' || left(sqlerrm, 40) || '）';
    end;

    reset role;
  exception when others then
    reset role;
    v_c := '🔴 切換角色本身失敗：' || sqlerrm;
  end;

  perform set_config('migi.a', coalesce(v_c, v_a), true);
  perform set_config('migi.b', coalesce(v_b, '（沒驗到）'), true);
end $$;

select 序, 項目, 內容 from (
  select 1 as 序, '① 🎯 用 anon 的身分實際叫 register_member_tx（應該被擋）' as 項目,
         coalesce(current_setting('migi.a', true), '🔴 沒跑到') as 內容
  union all
  select 2, '② 🎯 正對照：同一個 anon 還叫得動 get_wallet_tx 嗎',
         coalesce(current_setting('migi.b', true), '🔴 沒跑到')
  union all
  select 3, '③ line_conflict 還會不會交出 member_id',
         (select case when pg_get_functiondef(oid) ~ '''action'',''line_conflict'',\s*''member_id'''
                      then '🔴 還會' else '✅ 不會了' end
            from pg_proc where pronamespace='public'::regnamespace and proname='register_member_tx')
      || '　existing_phone：'
      || (select case when pg_get_functiondef(oid) ~ 'v_action = ''existing_phone'''
                      then '✅ 走自己的回傳' else '🔴 還是落到共用那行' end
            from pg_proc where pronamespace='public'::regnamespace and proname='register_member_tx')
  union all
  select 4, '④ service_role 還在嗎（Edge Function 要用）',
         (select case when exists (select 1 from aclexplode(proacl) a
                    where a.grantee='service_role'::regrole::oid and a.privilege_type='EXECUTE')
                      then '✅ 在' else '🔴 沒了 —— 註冊會整個壞掉' end
            from pg_proc where pronamespace='public'::regnamespace and proname='register_member_tx')
) x order by 序;
