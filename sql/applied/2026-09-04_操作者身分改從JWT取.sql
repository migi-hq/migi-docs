/* ============================================================
   🔴🔴 **這一份是一次性的，不要重跑** 🔴🔴
   ============================================================
   DDL 已於 2026-09-04 生效（14 支都插入了那一行）。
   **重跑會在同一個 `begin` 之後再插一行**，而 guard ②「只能插一次」
   會擋下並整份回滾 —— 那是它正確運作，但也表示這份不冪等。
   ✅ 要驗證請跑 `sql/checks/2026-09-04_補驗操作者身分.sql`。

   ⚠ **下面那個驗證段的 ④⑤ 當初是紅的，而錯的是驗證段不是 DDL** ——
     它查 `updated_by`，而 `open_session_tx` 寫的是 **`opened_by_staff_id`**
     （那個欄位它從來不寫）。詳見補驗檔的檔頭。
   ============================================================

   14 支營運函式：操作者身分改從 JWT 取，不再信呼叫端送的 `p_staff_id`
   2026-09-04 · MIGI · 店員登入的最後一塊

   ── 這一份要解決什麼 ──────────────────────────────────
   店員登入今天上線了，但 `updated_by` 記的**還是前端說的值**：
   ```
   POS 送 staffId ← localStorage.migi_pos_staff
   ⇒ 🔴 店員可以改那個值，把自己的操作記成別人做的
   ```
   ⚠ 那比沒有稽核更糟 —— **它看起來有稽核，而稽核是錯的**。
   🎯 這是硬規則 5.6 說的「身分靠前端宣告」那個**複利**捷徑：
     每多一個店員、每多一筆訂單，風險就複利一次。

   ── 做法：覆寫參數，函式體一行都不動 ────────────────
   14 支**全部是 plpgsql**，所以可以在 `begin` 之後加一行：
   ```sql
   p_staff_id := (select staff_id from public.current_staff());
   ```
   ⇒ 函式體其餘部分照舊使用 `p_staff_id`，**完全不用改**。

   ⚠ CLAUDE.md 記過「同一支函式要改三處以上就撈全文重建，不要堆 DO 區塊」
     （2026-08-19 在 `join_session_tx` 上連續判斷錯兩次）——
     **這裡是改一處，而且 14 支都是同一處**，所以 DO 區塊是合適的。
   ✅ 但 guard 照樣要有：那一次「改到一半就整支失敗」的 guard **救了兩次**。

   ── 🔴 最關鍵的一行：解析不到要 null，不是報錯 ────────
   那 14 支裡**有些會員 App 也會叫**（`topup_tx`、`checkout_tx` 這一族）。
   如果改成「必須是店員」，**會員儲值會當場壞掉**。
   正確語意是：
   ```
   有 staff 身分 → 真實的 staff_id      （POS）
   沒有          → null                  （會員 App，跟現在一模一樣）
   ```
   🎯 `(select staff_id from current_staff())` 查不到就回 null，天然符合。

   ── ⚠ 前端一行都不用改 ──────────────────────────────
   POS 照樣送 `p_staff_id`，函式**忽略它**。
   ⇒ 假造立刻失效，而且**不需要部署順序**。
   ⏳ 之後把參數整個拿掉是純整理（要 DROP ＋ 補 GRANT，那時再說）。

   ── 為什麼 `auth.jwt()` 在 DEFINER 函式裡讀得到 ──────
   `current_staff()` 讀的是 `request.jwt.claims` 這個 GUC，
   而它是**連線層**設定的 —— SECURITY DEFINER 換的是**執行權限**，
   不是連線身分。⇒ DEFINER 裡照樣讀得到呼叫者的 JWT。
   ✅ 今天已經實測過同一件事：`can()` 是 DEFINER，在 RLS policy 裡正常運作。
   ============================================================ */

do $$
declare
  r record;
  v_def text; v_new text; v_n int := 0; v_names text := '';
  /* 插入的那一行。⚠ 註解寫在裡面 —— 日後有人 `pg_get_functiondef`
     撈出來時，會直接看到「為什麼這裡覆寫參數」。

     🔴 **一定要用 `||` 明確連接**（2026-09-04 踩到）：
       相鄰的 `E'...'` 字串常數**不會自動接起來**，
       而錯誤訊息只說「syntax error at or near」指向第二行 ——
       看起來像那一行有問題，實際上是**上一行結束了而沒有運算子**。 */
  v_line constant text :=
       E'  /* 🔴 操作者身分從 JWT 取，**不採信呼叫端送的 p_staff_id**（2026-09-04）。\n'
    || E'     在此之前 POS 送的值來自 localStorage，店員可以改成別人 ——\n'
    || E'     而那比沒有稽核更糟（看起來有，卻指向錯的人）。\n'
    || E'   ⚠ 查不到就是 null（會員 App 那條路沒有 staff 身分），**不可以報錯**。 */\n'
    || E'  p_staff_id := (select staff_id from public.current_staff());\n';
begin
  for r in
    select p.oid, p.proname
      from pg_proc p join pg_language l on l.oid = p.prolang
     where p.pronamespace = 'public'::regnamespace
       and p.prokind = 'f'
       and l.lanname = 'plpgsql'
       and pg_get_function_identity_arguments(p.oid) like '%p_staff_id%'
       /* 只處理**前端叫得動**的那些 —— `charge_matched_tx` / `charge_private_tx`
          已經沒有任何角色能叫（死碼候選，待辦 28），不用動它們。 */
       and ((p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
         or exists (select 1 from aclexplode(coalesce(p.proacl,'{}')) a
                where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE'))
     order by p.proname
  loop
    v_def := pg_get_functiondef(r.oid);

    /* 在**第一個行首的 `begin`** 之後插入。
       ⚠ `regexp_replace` 沒有 'g' flag ⇒ **只換第一個**，而
         `pg_get_functiondef` 的輸出裡第一個行首 `begin` 一定是函式體開頭。 */
    v_new := regexp_replace(v_def, '(\n\s*begin\s*\r?\n)', '\1' || v_line);

    /* 🔴 **guard ①：一定要真的插進去。**
       沒插到而靜靜跳過，就會出現「有些函式改了有些沒改」而且不報錯 ——
       那正是 2026-08-19 那次靠 guard 才擋下的形狀。 */
    if v_new = v_def then
      raise exception '🔴 % 的 begin 沒有比對到，整份回滾', r.proname;
    end if;

    /* 🔴 **guard ②：只能插一次。**
       巢狀 `begin` 被誤中的話，同一支會出現兩行覆寫 ——
       行為雖然一樣，但那表示 regex 抓錯位置，下一支可能就錯得更嚴重。 */
    if (length(v_new) - length(replace(v_new, 'p_staff_id := (select staff_id', ''))) <> 30 then
      raise exception '🔴 % 插入了不只一次，整份回滾', r.proname;
    end if;

    execute v_new;
    v_n := v_n + 1;
    v_names := v_names || case when v_names = '' then '' else '、' end || r.proname;
  end loop;

  /* 🔴 **guard ③：支數要合理。**
     0 支代表 where 條件寫錯（而那會安靜地什麼都不做）。 */
  if v_n = 0 then
    raise exception '🔴 一支都沒改到 —— where 條件可能寫錯了';
  end if;
  raise notice '改了 % 支：%', v_n, v_names;
end $$;


-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
do $$
declare
  v_out text := '';
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_line text; v_store uuid; v_table uuid; v_table2 uuid; v_sess uuid; v_by uuid; v_r jsonb;
begin
  begin
    /* 🎯 用**真的登入過的那個 LINE 帳號**（創辦人）——
       他有 owner 的 staff 列，是唯一能走完這條路的身分。 */
    select m.line_user_id into v_line
      from members m join staff s on s.member_id = m.id
     where m.line_user_id is not null and s.deleted_at is null and m.deleted_at is null
     limit 1;

    ---- ① 14 支都改到了 --------------------------------
    v_out := v_out || E'\n' || '① 前端叫得動、且已改吃 current_staff() 的支數' || E'\t' ||
      (select count(*)::text || ' 支：' || string_agg(p.proname, '、' order by p.proname)
         from pg_proc p
        where p.pronamespace='public'::regnamespace and p.prokind='f'
          and pg_get_function_identity_arguments(p.oid) like '%p_staff_id%'
          and pg_get_functiondef(p.oid) like '%p_staff_id := (select staff_id%');

    /* 🔴 **正對照**：有沒有漏掉的？
       只數「改了幾支」的話，漏掉一支也看不出來。 */
    v_out := v_out || E'\n' || '② 🎯 正對照：還有幾支前端叫得動卻**沒改到**' || E'\t' ||
      (select case when count(*) = 0 then '✅ 0 支'
                   else '🔴 ' || count(*) || ' 支：' || string_agg(p.proname, '、') end
         from pg_proc p join pg_language l on l.oid=p.prolang
        where p.pronamespace='public'::regnamespace and p.prokind='f' and l.lanname='plpgsql'
          and pg_get_function_identity_arguments(p.oid) like '%p_staff_id%'
          and pg_get_functiondef(p.oid) not like '%p_staff_id := (select staff_id%'
          and ((p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                   where a.grantee=0 and a.privilege_type='EXECUTE'))
            or exists (select 1 from aclexplode(coalesce(p.proacl,'{}')) a
                   where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE')));

    ---- ③ 授權沒掉（`CREATE OR REPLACE` 不會丟 GRANT）----
    v_out := v_out || E'\n' || '③ 🎯 授權沒掉（POS 還叫得動）' || E'\t' ||
      (select case when count(*) = 4 then '✅ open/checkout/settle/void 都還是 anon 叫得動'
                   else '🔴 只剩 ' || count(*) || ' 支 —— POS 會壞' end
         from pg_proc p
        where p.pronamespace='public'::regnamespace
          and p.proname in ('open_session_tx','checkout_tx','settle_session_tx','void_session_tx')
          and ((p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                   where a.grantee=0 and a.privilege_type='EXECUTE'))
            or exists (select 1 from aclexplode(coalesce(p.proacl,'{}')) a
                   where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE')));

    ---- ④⑤ 🎯 真的開一張桌，看 updated_by 是誰 -----------
    /* 🔴 **這兩格是整份的重點**：不是「函式改了嗎」，是
       「**假造的值真的被忽略了嗎**」。
       ⚠ 刻意送一個**假的 staff_id**（全 9），如果它出現在 `updated_by`
         裡就代表覆寫沒有生效。 */
    /* 🔴 **要兩張不同的桌**：`uq_sessions_open_table` 是部分索引
       （`WHERE status='open' AND deleted_at IS NULL`）⇒ 同一張桌不能有
       兩個 open session。④ 與 ⑥ 各開一張，用同一張的話第二次會撞唯一鍵，
       而那個錯誤看起來會像「函式壞了」。
       ⚠ 只挑**目前沒有 open session** 的桌。 */
    select id into v_store from stores where org_id = v_org limit 1;
    select t.id into v_table from tables t
     where t.store_id = v_store
       and not exists (select 1 from table_sessions s
                        where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
     limit 1;
    select t.id into v_table2 from tables t
     where t.store_id = v_store and t.id <> v_table
       and not exists (select 1 from table_sessions s
                        where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
     limit 1;

    if v_line is not null and v_table is not null then
      /* ⚠ `mode` 與 `open_method` 的允許值是**撈出來的不是猜的**（硬規則 3）——
         我第一版寫 `'match'` 與 `'staff'`，**兩個都錯**：
         ```
         mode        ∈ matched | private
         open_method ∈ auto | manual（或 null）
         ```
         🎯 沒查的話會炸在驗證段，而第一眼會以為是函式改壞了。 */
      perform set_config('request.jwt.claims',
        '{"sub":' || to_json(v_line)::text || '}', true);
      v_r := public.open_session_tx(v_table, 'matched', null, 3, null,
              '99999999-9999-9999-9999-999999999999'::uuid, 'manual', null, '台麻', '無花');
      v_sess := (v_r ->> 'session_id')::uuid;
      select updated_by into v_by from table_sessions where id = v_sess;

      v_out := v_out || E'\n' || '④ 🎯 送假的 staff_id 會被忽略' || E'\t' ||
        case when v_by = '99999999-9999-9999-9999-999999999999'::uuid
               then '🔴 假的被寫進去了 —— 覆寫沒生效'
             when v_by is null then '🔴 變成 null —— 身分沒解析出來'
             else '✅ 忽略了' end;

      v_out := v_out || E'\n' || '⑤ 🎯 記到的是**解析出來的**那個人' || E'\t' ||
        coalesce((select '✅ ' || s.name || '（' || s.role || '）'
                    from staff s where s.id = v_by), '🔴 對不到 staff');

      ---- ⑥ 🔴 正對照：沒有身分時是 null 不是報錯 --------
      /* 那 14 支裡有些**會員 App 也會叫** —— 改成「必須是店員」的話
         會員儲值會當場壞掉。這一格就是那道守衛。 */
      perform set_config('request.jwt.claims', '{"sub":"U_not_a_staff_000000000000000"}', true);
      if v_table2 is null then
        /* ⚠ 找不到第二張空桌時**要出聲**，不要安靜跳過 ——
           那正是上一份 SQL 的 ⑦⑧ 出過的錯（取樣不足 → 那一格不出現）。 */
        v_out := v_out || E'\n' || '⑥ 🎯 正對照' || E'\t' ||
          '🔴 **沒驗到**：找不到第二張空桌。不要當成通過';
      else
      begin
        v_r := public.open_session_tx(v_table2, 'matched', null, 3, null,
                '99999999-9999-9999-9999-999999999999'::uuid, 'manual', null, '台麻', '無花');
        select updated_by into v_by from table_sessions where id = (v_r ->> 'session_id')::uuid;
        v_out := v_out || E'\n' || '⑥ 🎯 正對照：沒有 staff 身分 → null，不報錯' || E'\t' ||
          case when v_by is null then '✅ null（會員 App 那條路不會壞）'
               else '🔴 竟然有值：' || v_by::text end;
      exception when others then
        v_out := v_out || E'\n' || '⑥ 🎯 正對照：沒有 staff 身分' || E'\t' ||
          '🔴 **報錯了** —— 會員 App 會壞：' || sqlerrm;
      end;
      end if;
    else
      v_out := v_out || E'\n' || '④–⑥ 實際開桌測試' || E'\t' ||
        '🔴 **沒驗到**：找不到有 staff 的 LINE 會員或桌子。不要當成通過';
    end if;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.sf', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.sf', true), E'\n')) as x
 where coalesce(x,'') <> '';
