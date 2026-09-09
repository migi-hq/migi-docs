/* ============================================================
   🔴 所有 `pos_*` 函式收掉 anon ＋ 會員搜尋加店員擋牆
   2026-09-09 · 授權收斂第五批（前四批全部漏掉的一族）
   ============================================================

   ── 🔴 這一批裡有一個今天就成立的洞 ────────────────────
   ```
   pos_search_members_tx(p_org_id, p_keyword)   anon 叫得動 · 零權限檢查
   回傳：id · nickname · **phone** · tier · rank · title · avatar · **balance** · is_test
   比對：display_name ilike '%kw%'  OR  phone like '%kw%'      一次回 20 筆
   ```
   而 `p_org_id` 是**寫死在前端 bundle 裡的公開值**
   ⇒ 送 `keyword = '0'` 就能撈回 20 位會員的**手機號碼、餘額、member_id**。

   🎯 **那正是 2026-08-30 收掉 `register_member_tx` 想關的洞**
     （待辦 36：「只要知道一支手機號碼就能拿到別人的 `member_id`」）——
     **它從另一扇門整個敞開，而且方向相反：那次要先知道號碼，這次是列舉。**
   ⚠ 而 `member_id` 一旦外流，**剩下那兩支只信參數的函式也跟著被打開**
     （`get_my_orders_tx` 的 `p_member_id` 退回還在，第 ③c 步才會收）。

   ── 🔴 為什麼前四批全部漏掉：三個判準都是「猜形狀」──────
   | 批次 | 判準 | 為什麼抓不到 |
   |---|---|---|
   | 1／2 | 簽名含 `p_member_id` | 這些用 `p_queue`／`p_keyword`／`p_store` |
   | 3／4 | 函式名含動錢的動詞 | `search`／`list`／`queue` 都不在名單裡 |

   🎯 **而真正的判準一直擺在眼前：`pos_` 這個前綴本身。**
     一支叫 `pos_*` 的函式，**照定義就是店員操作** ——
     那是**結構性的**，不用維護一份清單（同 `analytics.js` 用前綴分辨
     三端錯誤、同錯誤儀表改用 `event like '%\_error'` 的理由）。
   📌 **教訓：判準要用「這個東西是什麼」，不要用「它長什麼樣子」。**
     前四批用簽名、用動詞，都是在描述長相；而前綴描述的是身分。

   ── 事前查證 ────────────────────────────────────────────
   · `pos_*` 共 **19 支**，其中 **13 支還有 anon ＋ PUBLIC**
   · **0 支缺 `authenticated`** ⇒ 收 anon 之後 POS 照常運作
   · **migi-web 與 migi-admin 呼叫 `pos_*` 的次數：各 0 支**（加引號比對）
     ⚠ POS 前端出現的 `pos_carry`／`pos_nav`／`pos_error` 是**埋點事件名**
       不是函式，不受影響
   ============================================================ */


/* ── ① 收掉所有 `pos_*` 的 anon 與 PUBLIC ───────────────────
   🔴 **用迴圈不是列 13 行**，理由不是省事：
     那 13 支的簽名很長（`pos_create_recurring_tx` 有 12 個參數），
     **逐字抄錯一個型別就會 revoke 到不存在的多載而且報錯**。
     迴圈直接從 `pg_proc` 取真實簽名，抄不錯。
   ⚠ 兩個方向都收（硬規則 2.6b）：舊的走 PUBLIC、新建的走明確授權。
   ⚠ `authenticated` **一個都不收** —— POS 靠它。 */
do $$
declare r record; n int := 0;
begin
  for r in
    select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
       and p.proname like 'pos\_%'
  loop
    execute format('revoke execute on function public.%I(%s) from public', r.proname, r.args);
    execute format('revoke execute on function public.%I(%s) from anon',   r.proname, r.args);
    execute format('grant  execute on function public.%I(%s) to authenticated, service_role', r.proname, r.args);
    n := n + 1;
  end loop;
  if n <> 19 then
    raise exception '掃到 % 支 pos_ 函式，期望 19 —— 先撈 pg_proc 確認再跑', n;
  end if;
end $$;


/* ── ② `pos_search_members_tx` 加店員擋牆 ────────────────────
   🔴 **只收 anon 不夠**：收完之後**登入的一般會員仍然叫得動它**
     （他也是 `authenticated`）—— 同一個洞，只是多一步登入。
     而這一支回的是手機與餘額，那是最不能將就的一支。
   ⚠ 用 `can('member.lookup')` 不自己比對 role（待辦 29 ①）——
     那個權限碼 2026-09-09 才建立，語意就是「任何有 staff 列的人」，
     所以 `floor` 店員照樣搜得到客人。
   ⚠ **org 從 `current_org_id()` 取，不採信參數**（身分不可以由呼叫端宣告）。
     📌 簽名保留 `p_org_id` 讓前端不用改，函式忽略它 ——
       同那 21 支會員端函式「照樣送、函式忽略」的做法。 */
create or replace function public.pos_search_members_tx(p_org_id uuid, p_keyword text)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_kw text;
begin
  if not public.can('member.lookup') then
    raise exception 'forbidden: 需要店員身分';
  end if;

  /* ⚠ 覆寫而不是驗證相等 —— 驗證相等會讓「送錯 org」變成一個
     可以用來試探「哪個 org 存在」的訊號。直接用自己的就沒有那個面。 */
  p_org_id := public.current_org_id();

  v_kw := trim(coalesce(p_keyword, ''));
  if length(v_kw) = 0 then return '[]'::jsonb; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id, 'nickname', m.display_name, 'phone', m.phone,
      'tier', coalesce(m.tier_override, m.tier), 'rank', m.rank, 'title', m.title,
      'avatar_url', m.avatar_url, 'avatar_bear', m.avatar_bear, 'avatar_source', m.avatar_source, 'avatar_photo_path', m.avatar_photo_path,
      'balance', coalesce(w.balance, 0),
      'is_test', m.is_test
    ) order by m.display_name)
    from members m
    left join wallets w on w.member_id = m.id
    where m.org_id = p_org_id and m.deleted_at is null
      and (m.display_name ilike '%' || v_kw || '%' or m.phone like '%' || v_kw || '%')
    limit 20
  ), '[]'::jsonb);
end $function$;


/* ============================================================
   驗證段
   🎯 這一份最容易自欺的是「擋住了」那一半 ——
     一支永遠回 forbidden 的實作也會讓它全綠，而那會**打壞收銀機**。
   ============================================================ */
do $$
declare
  v_hq text; v_line text; v1 text; v2 text; v3 text; r jsonb;
begin
  select s.auth_uid::text into v_hq from staff s
   where s.deleted_at is null and s.auth_uid is not null
   order by case s.role when 'hq' then 1 else 2 end limit 1;
  /* 🔴 取樣要**不是店員**的會員 —— 拿老闆的 LINE 來測，`can()` 會回 true，
     整個擋牆測試就變成「總部 vs 總部」（2026-09-09 的 21-⑤ 也是這樣取樣的）。 */
  select m.line_user_id into v_line from members m
   where m.deleted_at is null and m.line_user_id is not null
     and not exists (select 1 from staff s where s.member_id = m.id and s.deleted_at is null)
   order by m.created_at limit 1;

  if v_hq is null or v_line is null then
    perform set_config('migi.v1', '⚪ 取樣失敗，三格都測不了', true);
    perform set_config('migi.v2', '⚪ 同上', true);
    perform set_config('migi.v3', '⚪ 同上', true);
    return;
  end if;

  /* ── ⑤ 🎯 正對照：店員搜得到（這一格才是「收銀機沒壞」的證據）── */
  begin
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_hq, 'role', 'authenticated')::text, true);
    set local role authenticated;
    r := public.pos_search_members_tx(null, '0');   -- 參數故意送 null，證明 org 是自己取的
    reset role;
    v1 := case when jsonb_array_length(coalesce(r,'[]'::jsonb)) > 0
               then '✅ 店員搜得到 ' || jsonb_array_length(r) || ' 位（而且 p_org_id 送 null 也照樣work ⇒ org 真的是從身分取的）'
               else '🔴 店員搜不到 —— 會員查詢會壞' end;
  exception when others then reset role; v1 := '🔴 ' || left(coalesce(sqlerrm,'?'), 70); end;

  /* ── ⑥ 擋牆：登入但不是店員 ── */
  begin
    perform set_config('request.jwt.claims',
      json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated',
                        'app_metadata', json_build_object('line_user_id', v_line))::text, true);
    set local role authenticated;
    perform public.pos_search_members_tx(null, '0');
    reset role;
    v2 := '🔴 一般會員仍然搜得到 —— 擋牆沒作用';
  exception when others then reset role;
    v2 := case when sqlerrm like 'forbidden%' then '✅ 一般會員被擋（' || sqlerrm || '）'
               else '⚠ 擋住了但不是預期的原因：' || left(coalesce(sqlerrm,'?'), 55) end; end;

  /* ── ⑦ anon 連叫都叫不動（授權層，不是函式層）── */
  begin
    perform set_config('request.jwt.claims', '', true);
    set local role anon;
    perform public.pos_search_members_tx(null, '0');
    reset role;
    v3 := '🔴 anon 仍然叫得動';
  exception when others then reset role;
    v3 := case when sqlstate = '42501' or sqlerrm ~* 'permission denied'
               then '✅ anon 被授權層擋掉（permission denied，連函式體都沒進去）'
               else '⚠ ' || left(coalesce(sqlerrm,'?'), 55) end; end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.v1', v1, true);
  perform set_config('migi.v2', v2, true);
  perform set_config('migi.v3', v3, true);
end $$;

select
  /* ① 19 支 pos_ 全部：anon 沒了、PUBLIC 沒了、authenticated 還在 */
  (select case when count(*) filter (where bad) = 0
               then '✅ 19 支 pos_ 函式全部乾淨（anon 0 · PUBLIC 0 · authenticated 19）'
               else '🔴 有 ' || count(*) filter (where bad) || ' 支不對：'
                    || coalesce(string_agg(proname, '　') filter (where bad), '?') end
   from (
     select p.proname,
            (exists (select 1 from aclexplode(p.proacl) a where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE')
             or (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee=0 and a.privilege_type='EXECUTE'))
             or not exists (select 1 from aclexplode(p.proacl) a where a.grantee='authenticated'::regrole::oid and a.privilege_type='EXECUTE')
            ) as bad
       from pg_proc p
      where p.pronamespace='public'::regnamespace and p.prokind='f' and p.proname like 'pos\_%'
   ) z) as "① 19 支 pos_ 的授權",

  /* ② 全庫數量。期望值當場查出來的（硬規則 3.56）：
       anon 明確  108 − 13 = 95
       PUBLIC     106 − 13 = 93     （那 13 支兩邊都有）
       函式總數   183，不新增不刪除 ⇒ 不變 */
  (select '　anon 明確：' || count(*) filter (where exists (
        select 1 from aclexplode(p.proacl) a where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE'))
     || '（期望 95 ＝ 108 − 13）'
     || E'\n　PUBLIC　　：' || count(*) filter (where p.proacl is null or exists (
        select 1 from aclexplode(p.proacl) a where a.grantee=0 and a.privilege_type='EXECUTE'))
     || '（期望 93 ＝ 106 − 13）'
     || E'\n　函式總數　：' || count(*) || '（期望 183，不變）'
   from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind='f') as "② 全庫數量",

  /* ③ 🎯 負對照：刻意留 anon 的兩支不可以被掃到（它們不是 pos_ 開頭，
       但這一格是在確認迴圈沒有掃過頭）。 */
  coalesce((select string_agg(p.proname || '：' || case when exists (select 1 from aclexplode(p.proacl) a
      where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE') then '✅ anon 還在' else '🔴 被誤傷' end, '　' order by p.proname)
    from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind='f'
     and p.proname in ('log_app_event_tx','get_my_orders_tx','list_topup_plans_tx','list_tables_tx')
  ), '🔴 找不到') as "③ 負對照：非 pos_ 的沒被掃到",

  coalesce(nullif(current_setting('migi.v1', true), ''), '🔴 沒有訊息') as "④ 🎯 正對照：店員搜得到嗎",
  coalesce(nullif(current_setting('migi.v2', true), ''), '🔴 沒有訊息') as "⑤ 擋牆：一般會員",
  coalesce(nullif(current_setting('migi.v3', true), ''), '🔴 沒有訊息') as "⑥ 授權層：anon",

  /* ⑦ 參考清單：收完之後還有哪些函式 anon 叫得動而且零權限檢查。
       ⚠ **不是通過條件**，是給下一批看的。
       📌 這次用第四個判準：**看它讀不讀個資**（members / wallets / orders）。 */
  coalesce((
    select string_agg(p.proname, '　' order by p.proname)
    from pg_proc p
    where p.pronamespace='public'::regnamespace and p.prokind='f'
      and exists (select 1 from aclexplode(p.proacl) a where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE')
      and pg_get_functiondef(p.oid) ~ '\m(members|wallets|orders|topup_orders|wallet_txns)\M'
      and pg_get_functiondef(p.oid) !~ '(current_member_id|current_staff|can\()'
  ), '（沒有了）') as "⑦ 參考：還有哪些 anon 函式碰得到個資或錢";
