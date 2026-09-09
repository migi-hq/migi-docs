/* ============================================================
   拿真的身分實際查一次那 17 條讀取 policy
   2026-09-09 · 待辦 21-⑤ 的驗證缺口
   ============================================================

   ── 為什麼要這一份 ──────────────────────────────────────
   待辦 21-⑤ 明寫：
   > 🔴 **不可以只讀 policy 定義就宣告安全** —— RLS 的實際效果取決於
   >   policy 組合、`current_org_id()` 的回傳、以及 SECURITY DEFINER
   >   函式繞過的路徑。**只有真的用那個身分查一次算數**（同硬規則 7）。

   2026-09-04 對**三條寫入** policy 做過，**17 條讀取的一條都沒驗過**。
   而它們管的是：個資 5 張 ＋ 錢 6 張 ＋ 營運 6 張。

   🎯 **現在才做得到**：會員 JWT 2026-09-09 在正式環境確認可用
   （`member_session` 探針回 `prod · liff · ok`），
   在此之前「會員登入之後看得到什麼」只能用讀 policy 定義去推。

   ── 三種身分，兩個方向 ──────────────────────────────────
   ```
   A 總部   staff.auth_uid            → 該讀得到（正對照）
   B 會員   members.line_user_id      → 🔴 不該讀得到（擋牆）
   C anon   完全沒有 claims           → 🔴 不該讀得到
   ```
   🔴 **只驗 B/C 讀不到的話，「整條 policy 刪掉」也會全綠**（硬規則 3.55）。
     所以 A 那一格是必要的，不是裝飾。

   ── ⚠ 空表測不出東西，要出聲 ────────────────────────────
   `mahjong_buddies` / `member_availability` / `bonus_rules` / `pricing_tiers`
   目前是 0 列 ⇒ 三種身分都回 0 ⇒ **那一格分不出「擋住了」與「表是空的」**。
   不標出來的話它會被當成通過（同硬規則 3.55 的形狀）。

   ── 🔴 這一份**不能走 MCP**，必須從 Dashboard 跑 ─────────────
   它是唯讀的，照硬規則 1.5 本來該由 Claude 自己跑。**但跑不動**：
   ```
   set local role authenticated  →  42501 permission denied to set role
   當下身分 supabase_read_only_user，只是 pg_monitor 與 pg_read_all_data 的成員
   ```
   🎯 **唯讀 MCP 那個身分沒有權限切換成任何角色** ——
     那正是硬規則 1.5 把它的權限鎖到最小的設計，**它擋住了我，那是它在做對的事**。
   ⚠ 而第一次跑的時候我把例外吞掉了，20 張表 × 3 種身分**全部印「拒絕」**
     ⇒ 看起來像「總部也讀不到，後台會壞」。
     **先懷疑儀器**（硬規則 3.5）—— 把 `sqlerrm` 印出來才看到真正的原因。
   📌 教訓：**驗證段的 exception handler 不要只記「失敗了」，要記「為什麼」。**

   ⇒ 從 Supabase Dashboard 執行（那裡是 `postgres`）。
   ✅ 它**不改任何東西**：只有 SELECT 與 `set local role`，
     交易結束就全部復原，可以放心重跑。
   ============================================================ */

do $$
declare
  v_hq   text;   -- 總部 staff 的 auth_uid
  v_line text;   -- 一個**不是店員**的會員的 line_user_id
  v_out  text := '';
  t      text;
  n_hq   int; n_mb int; n_an int;
  v_note text;
  v_why  text := '';   -- 第一個例外的原因（見下面 A 那一格的註解）
  -- 17 條讀取 policy 的表 ＋ 3 張負對照（店家資訊，會員本來就該看得到）
  tabs text[] := array[
    'orders','order_items','order_payments','topup_orders','wallets','wallet_txns',
    'members','mahjong_buddies','member_availability','member_coupons','member_interactions',
    'staff','table_sessions','session_players','coupons','bonus_rules','pricing_tiers',
    'stores','tables','products'];
begin
  select s.auth_uid::text into v_hq
    from staff s where s.deleted_at is null and s.auth_uid is not null
   order by case s.role when 'hq' then 1 else 2 end limit 1;

  /* 🔴 取樣要**不是店員**的會員 —— 拿老闆的 LINE 來測的話
     `can()` 會回 true，整份驗證會變成「總部 vs 總部」。 */
  select m.line_user_id into v_line
    from members m
   where m.deleted_at is null and m.line_user_id is not null
     and not exists (select 1 from staff s where s.member_id = m.id and s.deleted_at is null)
   order by m.created_at limit 1;

  if v_hq is null or v_line is null then
    raise exception '取樣失敗：hq=% line=%', coalesce(v_hq,'無'), coalesce(v_line,'無');
  end if;

  v_out := '取樣　總部 auth_uid=' || left(v_hq,8) || '…　會員 line=' || left(v_line,10) || '…' || E'\n';
  v_out := v_out || rpad('表', 22) || rpad('總部', 8) || rpad('會員', 8) || rpad('anon', 8) || '判定' || E'\n';
  v_out := v_out || repeat('─', 66) || E'\n';

  foreach t in array tabs loop
    /* ⚠ 例外要記下**原因**不要只記「失敗」——
       第一次跑時三種身分全部拋 `42501 permission denied to set role`，
       而我只存了 -1 ⇒ 畫面印出「總部讀不到，後台會壞」，
       那是一個**完全誤導的結論**（硬規則 3.5：先懷疑儀器）。 */
    -- A 總部
    begin
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_hq, 'role', 'authenticated')::text, true);
      set local role authenticated;
      execute format('select count(*) from public.%I', t) into n_hq;
      reset role;
    exception when others then reset role; n_hq := -1;
      if v_why = '' then v_why := sqlstate || ' ' || sqlerrm; end if; end;

    -- B 一般會員
    begin
      perform set_config('request.jwt.claims',
        json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated',
                          'app_metadata', json_build_object('line_user_id', v_line))::text, true);
      set local role authenticated;
      execute format('select count(*) from public.%I', t) into n_mb;
      reset role;
    exception when others then reset role; n_mb := -1; end;

    -- C anon
    begin
      perform set_config('request.jwt.claims', '', true);
      set local role anon;
      execute format('select count(*) from public.%I', t) into n_an;
      reset role;
    exception when others then reset role; n_an := -1; end;

    /* 判定。⚠ `-1` 代表拋錯（多半是連 SELECT 權限都沒有）——
       那也是「讀不到」，但**跟「RLS 濾成 0 列」是不同的機制**，要分開印。 */
    v_note := case
      when t in ('stores','tables','products') then
        case when n_hq > 0 and n_mb > 0 then '✅ 負對照：店家資訊，會員本來就該看得到'
             when n_mb = 0 then '🔴 會員看不到店家資訊 —— 過度阻擋'
             else '⚠ 總部 ' || n_hq || ' / 會員 ' || n_mb end
      when n_hq = 0 and n_mb = 0 and n_an = 0 then '⚪ 這張表是空的，測不出東西'
      when n_hq <= 0 then '🔴 總部讀不到 —— 後台會壞（' || n_hq || '）'
      when n_mb > 0 then '🔴 一般會員讀得到 ' || n_mb || ' 列'
      when n_an > 0 then '🔴 anon 讀得到 ' || n_an || ' 列'
      else '✅ 總部讀得到、會員與 anon 都是 0' end;

    v_out := v_out || rpad(t, 22)
          || rpad(case when n_hq < 0 then '拒絕' else n_hq::text end, 8)
          || rpad(case when n_mb < 0 then '拒絕' else n_mb::text end, 8)
          || rpad(case when n_an < 0 then '拒絕' else n_an::text end, 8)
          || v_note || E'\n';
  end loop;

  perform set_config('request.jwt.claims', '', true);

  /* 🔴 全部「拒絕」時要講出**為什麼** —— 不然它看起來像
     「連總部都讀不到，後台壞了」，而真正的原因多半是
     **執行這份 SQL 的身分沒有權限切換角色**（就像唯讀 MCP 那個 user）。 */
  if v_why <> '' then
    v_out := v_out || E'\n🔴 至少有一格拋了例外，第一個原因是：' || v_why
          || E'\n　 當下身分：' || current_user
          || E'\n　 ⚠ 若是 `42501 permission denied to set role`，代表**這份 SQL 跑錯地方了** ——'
          || E'\n　   它必須從 Supabase Dashboard（postgres）跑，唯讀 MCP 的身分切換不了角色。';
  end if;
  perform set_config('migi.out', v_out, true);
end $$;

select current_setting('migi.out', true) as "17 條讀取 policy · 三種身分實測";
