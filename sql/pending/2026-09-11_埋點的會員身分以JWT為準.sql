/* ============================================================
   `log_app_event_tx` 的會員身分改以 JWT 為準
   2026-09-11 · 待辦 14

   ── 為什麼是這一支 ──────────────────────────────────
   實查（2026-09-11）簽名含 `p_member_id` 的 53 支函式：
   ```
   22 支  ✅ 已改 JWT 優先，而且全部只有 anon 叫得動（會員 App 的路徑）
   31 支  🔴 還信前端 —— 但其中 30 支 anon 叫不動（POS／後端路徑，
                指定客人是設計上必要的）
    1 支  🔴 **anon 叫得動而且信前端** ← 就是這一支
   ```
   ⇒ 它是「anon ＋ 前端說了算」的**最後一支**。

   ⚠ 危害不是洩漏（它是寫入不是讀取），是**汙染而且改不掉**：
     前端可以把事件掛到任何一個 member_id 上，
     而 `app_events` 有 `trg_app_events_no_mutate`（UPDATE 與 DELETE 都擋）
     ⇒ **蓋錯了就永遠是錯的**。

   ── 🔴 這裡有一個會出事的陷阱，不可以無條件 coalesce ──
   其他 22 支寫的是 `coalesce(current_member_id(), p_member_id)`，
   而**那個寫法搬到這一支會出事**：
   ```
   POS 的埋點       p_member_id 一律是 null（CLAUDE.md 記著）
   店員登入之後      POS 也有 JWT，而店員本身是會員
   current_member_id()  → 回**店員自己的 member_id**
   ⇒ 無條件 coalesce ＝ 每一筆 pos_error / pos_checkout
     都掛到店長的會員帳號上，而且跟著他的 is_test 被標成測試
   ```
   🎯 **null 在這一支是有意義的值**（「這件事沒有會員」），不是「沒填」。
   ✅ 所以只在**前端真的送了值**的時候才覆寫：
   ```
   前端送 null   → 維持 null      （POS、未登入的 App、註冊流程）
   前端送 id ＋ 有 JWT → 用 JWT 的（送別人的也會被改回自己）
   前端送 id ＋ 沒 JWT → 照舊       （還沒發 session 的那條路）
   ```

   ⚠ 簽名沒變 ⇒ `CREATE OR REPLACE`，不用 DROP、不掉 GRANT（硬規則 2）。
   ⚠ 只換一處，所以用 DO 區塊換字串而不是撈全文重建
     （CLAUDE.md：要改三處以上才撈全文）。
   ⚠ DDL 段的 guard 可以 raise（換不到就整份回滾）；
     驗證段一個字都不准（硬規則 1.8）。

   📌 **行為測試在另一份**：`sql/checks/2026-09-11_驗埋點身分不會蓋錯人.sql`
     —— 它要真的寫一筆 `app_events` 才驗得到，而那張表 append-only，
     所以只能在交易裡做完再回滾。**那份必須 raise，這份必須不 raise。**
   ============================================================ */

do $mig$
declare v_def text; v_new text; v_n int;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname = 'log_app_event_tx';

  if v_def is null then
    raise exception '🔴 找不到 log_app_event_tx';
  end if;

  /* 錨點唯一性事先查過：`if p_member_id is not null then` 在全文出現 1 次
     （第二個 if 判斷的是 p_store_id）。 */
  select count(*) into v_n from regexp_matches(v_def, 'if p_member_id is not null then', 'g');
  if v_n <> 1 then
    raise exception '🔴 錨點出現 % 次（預期 1）—— 線上版本與預期不同，先撈全文對照', v_n;
  end if;

  v_new := replace(v_def,
    'if p_member_id is not null then',
    '/* 🔴 有會員 session 時一律以 JWT 為準（2026-09-11，待辦 14）。'
    || E'\n     ⚠ **只在前端送了值的時候覆寫** —— null 在這一支是有意義的值'
    || E'\n       （「這件事沒有會員」），不是「沒填」。'
    || E'\n     🔴 無條件 coalesce 會把 POS 的事件全部掛到**登入中的店員**身上：'
    || E'\n       店員本身是會員，所以 current_member_id() 回得出他的 member_id，'
    || E'\n       而 POS 的埋點本來一律送 null。 */'
    || E'\n  p_member_id := case when p_member_id is null then null'
    || E'\n                      else coalesce(public.current_member_id(), p_member_id) end;'
    || E'\n\n  if p_member_id is not null then');

  if position('public.current_member_id()' in v_new) = 0 then
    raise exception '🔴 沒換到 —— 整份回滾';
  end if;

  execute v_new;
end $mig$;

/* ── 驗證段（唯讀，一個字都不 raise）──────────────────── */
do $$
declare v_msg text := ''; v_n int; v_t text;
begin
  select count(*) into v_n from pg_proc p
   where p.pronamespace='public'::regnamespace and p.prokind='f'
     and p.proname='log_app_event_tx'
     and position('public.current_member_id()' in pg_get_functiondef(p.oid)) > 0;
  v_msg := v_msg || case when v_n=1
    then '① ✅ 會員身分改以 JWT 為準了'
    else '① 🔴 沒換到' end;

  /* ② 🔴 null 那一半要留著。少了它 POS 的事件會掛到店員身上，
        而 `app_events` 是 append-only ⇒ **蓋錯了永遠改不掉**。 */
  select count(*) into v_n from pg_proc p
   where p.pronamespace='public'::regnamespace and p.prokind='f'
     and p.proname='log_app_event_tx'
     and position('when p_member_id is null then null' in pg_get_functiondef(p.oid)) > 0;
  v_msg := v_msg || E'\n' || case when v_n=1
    then '② ✅ 前端送 null 時維持 null（POS 的事件不會被掛到店員身上）'
    else '② 🔴 少了 null 那一半 —— 這比沒改更糟' end;

  /* ③ 簽名沒變、沒有多載。 */
  select count(*) into v_n from pg_proc p
   where p.pronamespace='public'::regnamespace and p.prokind='f'
     and p.proname='log_app_event_tx';
  select coalesce((select pg_get_function_identity_arguments(p.oid) from pg_proc p
                    where p.pronamespace='public'::regnamespace and p.prokind='f'
                      and p.proname='log_app_event_tx' limit 1),'') into v_t;
  v_msg := v_msg || E'\n' || case
    when v_n=1 and v_t like 'p_org_id uuid, p_member_id uuid, p_event text%'
      then '③ ✅ 只有一個版本，簽名沒變（CREATE OR REPLACE，沒有多載）'
    when v_n<>1 then '③ 🔴 有 ' || v_n || ' 個版本'
    else '③ 🔴 簽名變了：' || v_t end;

  /* ④ 🔴 正對照：`anon` 必須留著。
        它是**未登入時也要能用**的 —— App 開機、註冊流程、POS 全部靠它。
        收掉的話埋點會靜默消失（那張表的寫入沒有人在看回傳）。 */
  select count(*) into v_n
    from pg_proc p, aclexplode(coalesce(p.proacl,'{}')) a
   where p.pronamespace='public'::regnamespace and p.proname='log_app_event_tx'
     and a.privilege_type='EXECUTE' and a.grantee='anon'::regrole::oid;
  v_msg := v_msg || E'\n' || case when v_n=1
    then '④ ✅ anon 的執行權還在（未登入時的埋點不會壞掉）'
    else '④ 🔴 anon 不見了 —— 開機與註冊流程的埋點會靜默消失' end;

  /* ⑤ 這一支改完之後，「anon 叫得動又信前端」的函式應該是 0 支。
        ⚠ 用結構性的掃描而不是列清單 —— 下一支出現時這一格會自己變紅。 */
  select count(*) into v_n from pg_proc p
   where p.pronamespace='public'::regnamespace and p.prokind='f'
     and pg_get_function_identity_arguments(p.oid) like '%p_member_id%'
     and position('current_member_id()' in pg_get_functiondef(p.oid)) = 0
     and exists (select 1 from aclexplode(coalesce(p.proacl,'{}')) a
                  where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE');
  v_msg := v_msg || E'\n' || case when v_n=0
    then '⑤ ✅ 「anon 叫得動又信前端 member_id」的函式現在是 0 支'
    else '⑤ 🔴 還有 ' || v_n || ' 支' end;

  /* ⑥ 負對照：掃描器是活的嗎。
        那 22 支已改的應該全部被掃到「有 current_member_id()」。 */
  select count(*) into v_n from pg_proc p
   where p.pronamespace='public'::regnamespace and p.prokind='f'
     and pg_get_function_identity_arguments(p.oid) like '%p_member_id%'
     and position('current_member_id()' in pg_get_functiondef(p.oid)) > 0;
  v_msg := v_msg || E'\n' || case when v_n >= 23
    then '⑥ ✅ 掃描器是活的：' || v_n || ' 支帶 p_member_id 的函式會看 JWT（22 支既有 ＋ 這一支）'
    else '⑥ 🔴 只掃到 ' || v_n || ' 支 —— 掃描條件可能寫錯了' end;

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
