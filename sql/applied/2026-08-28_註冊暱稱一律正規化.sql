/* ============================================================
   register_member_tx：暱稱一律先正規化，禁字給明確的錯誤
   2026-08-28

   ── 為什麼 ──────────────────────────────────────────
   🔴 `register_member_tx` 目前只做 `trim`：

       v_name := trim(coalesce(p_display_name, ''));

     但 `members_display_name_chk` 要求的是

       display_name = migi_norm_nickname(display_name)

     **兩者不相等。** 客人的暱稱只要有「連續兩個空格」「全形空格」
     「零寬字元」，trim 收不掉，INSERT 就撞 CHECK 拋 23514。

   ⚠ 而 23514 的錯誤訊息**只給約束名字不給定義**（硬規則 3.8）——
     前端 `rpc.js` 把 23xxx 歸類成 BAD_REQUEST，
     客人看到的是「資料有誤，請重新操作一次」。
     **他重打一次還是同樣的兩個空格，於是永遠註冊不了而且不知道為什麼。**

   📌 這跟 2026-08-28 早上修的手機是**同一個病**：
     查詢／寫入前沒有先正規化，把「格式整理」丟給 CHECK 去炸。
     手機那次補了 `migi_norm_phone`，暱稱這次補 `migi_norm_nickname`。

   ── 順帶：禁字改成明確的 raise ──────────────────────
   CHECK 裡的 `!~* '(migi|官方|客服|店長|管理員|系統|admin)'` 一樣只會拋 23514。
   → 改成在函式裡先擋並 raise `display_name_reserved`，
     前端才翻得出「這個暱稱不能使用，請換一個」。
   ⚠ 允許值與正則**逐字抄自 `pg_get_constraintdef`**（含 `~*` 不分大小寫），
     不是憑印象寫的（硬規則 3.8.5）。

   ── 做法 ────────────────────────────────────────────
   撈線上定義 → 字串取代 → execute（硬規則 3：只有線上版算數）。
   ⚠ 簽名不變 → `CREATE OR REPLACE`，**不用 DROP、不會掉 GRANT**。
   ⚠ 每一步後面都有 guard：沒取代成功就整支 raise，
     Supabase SQL Editor 是單一交易，會整個回滾 ——
     不會留下「改到一半」的函式。
   ============================================================ */

do $$
declare
  v_old text;
  v_new text;
  v_a   text;
  v_b   text;
begin
  select pg_get_functiondef(p.oid) into v_old
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prokind = 'f'
     and p.proname = 'register_member_tx';

  if v_old is null then
    raise exception '找不到 register_member_tx';
  end if;

  /* ── ① trim → migi_norm_nickname ── */
  v_a := 'v_name := trim(coalesce(p_display_name, ''''));';
  v_b := 'v_name := public.migi_norm_nickname(coalesce(p_display_name, ''''));';

  if position(v_a in v_old) = 0 then
    raise exception '① 找不到要取代的那一行 —— 線上版本可能已經改過，先撈出來看';
  end if;
  v_new := replace(v_old, v_a, v_b);

  /* ── ② 禁字檢查插在長度檢查之前 ──
     錨點只用一行，避免踩到 \r\n 換行差異。 */
  v_a := 'if char_length(v_name) > 12 then';
  v_b := 'if v_name ~* ''(migi|官方|客服|店長|管理員|系統|admin)'' then'
      || E'\n    raise exception ''display_name_reserved'';'
      || E'\n  end if;'
      || E'\n\n  if char_length(v_name) > 12 then';

  if position(v_a in v_new) = 0 then
    raise exception '② 找不到長度檢查那一行';
  end if;
  v_new := replace(v_new, v_a, v_b);

  /* ── guard：確認兩處都真的換掉了 ── */
  if position('migi_norm_nickname(coalesce(p_display_name' in v_new) = 0 then
    raise exception 'guard 失敗：① 沒換到';
  end if;
  if position('display_name_reserved' in v_new) = 0 then
    raise exception 'guard 失敗：② 沒插進去';
  end if;
  if position('trim(coalesce(p_display_name' in v_new) > 0 then
    raise exception 'guard 失敗：舊的 trim 寫法還在';
  end if;

  execute v_new;
end $$;


/* ============================================================
   驗證（單一 SELECT）

   ── 該看到什麼 ──────────────────────────────────────
   ① 版本數 = 1（沒有建出多載）
   ② anon 與 authenticated 都還在（CREATE OR REPLACE 不該掉 GRANT）
   ③ 定義已含正規化、已無舊寫法
   ④ 三個子測試：
      · 雙空格暱稱 **現在存得進去**，而且存的是收斂後的值
      · 全形空格同上
      · 禁字回 `display_name_reserved`（**不是** 23514）
   ⑤ 回滾乾淨：會員數與跑之前一樣

   🔴 ④ 是**正對照**（硬規則 3.55）：
     只驗「禁字被擋」那一半沒有意義 —— 那在改之前就會被擋（只是錯得很難懂）。
     一定要同時驗「本來會失敗的雙空格現在會成功」，
     否則「全部都被擋下」與「改對了」長得一模一樣。
   ============================================================ */

do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_msg text := '';
  r     jsonb;
  v_nm  text;
begin
  begin
    /* ── ① 雙空格：改之前必炸 23514，改之後應該成功且收斂成一個空格 ── */
    begin
      r := register_member_tx(v_org, '陳  美美', '0999000101');
      select display_name into v_nm from members where id = (r ->> 'member_id')::uuid;
      v_msg := v_msg || '① 雙空格「陳  美美」→ action=' || coalesce(r ->> 'action', '?')
            || '　存進去的是 ' || quote_literal(coalesce(v_nm, ''))
            || case when v_nm = '陳 美美' then '　✅ 收斂成一個空格'
                    else '　🔴 應為 ''陳 美美''' end;
    exception when others then
      v_msg := v_msg || '① 雙空格 → 🔴 ' || sqlstate || '　' || sqlerrm;
    end;

    /* ── ② 全形空格（U+3000）── */
    begin
      r := register_member_tx(v_org, '林　小明', '0999000102');
      select display_name into v_nm from members where id = (r ->> 'member_id')::uuid;
      v_msg := v_msg || E'\n② 全形空格「林　小明」→ 存進去的是 ' || quote_literal(coalesce(v_nm, ''))
            || case when v_nm = '林 小明' then '　✅ 換成半形'
                    else '　🔴 應為 ''林 小明''' end;
    exception when others then
      v_msg := v_msg || E'\n② 全形空格 → 🔴 ' || sqlstate || '　' || sqlerrm;
    end;

    /* ── ③ 禁字：要回明確的代碼，不要回 23514 ── */
    begin
      r := register_member_tx(v_org, 'MIGI客服', '0999000103');
      v_msg := v_msg || E'\n③ 禁字「MIGI客服」→ 🔴 竟然成功了，action=' || coalesce(r ->> 'action', '?');
    exception when others then
      v_msg := v_msg || E'\n③ 禁字「MIGI客服」→ ' || sqlstate || '　' || sqlerrm
            || case when sqlerrm = 'display_name_reserved' then '　✅ 明確代碼'
                    when sqlstate = '23514' then '　🔴 還是 CHECK 在擋（前端翻不出來）'
                    else '　⚠ 非預期' end;
    end;

    /* ── ④ 正常暱稱不可以被誤擋（過度阻擋跟沒擋一樣糟）── */
    begin
      r := register_member_tx(v_org, '陳美美', '0999000104');
      v_msg := v_msg || E'\n④ 正常「陳美美」→ action=' || coalesce(r ->> 'action', '?') || '　✅ 沒被誤擋';
    exception when others then
      v_msg := v_msg || E'\n④ 正常「陳美美」→ 🔴 被誤擋了：' || sqlstate || '　' || sqlerrm;
    end;

    raise exception 'rollback_on_purpose';
  exception
    when others then
      /* ⚠ 硬規則 3.9：set_config(..., true) 是交易內設定，
         寫在 raise 之前會跟著被回滾 —— 一律設在處理器裡。 */
      if sqlerrm = 'rollback_on_purpose' then
        perform set_config('migi.reg', v_msg, true);
      else
        perform set_config('migi.reg', v_msg || E'\n🔴 外層拋錯：' || sqlerrm, true);
      end if;
  end;
end $$;

select 序, 項目, 內容 from (

  select 1 as 序, '① 版本數（應為 1）' as 項目,
         (select count(*)::text from pg_proc p
           where p.pronamespace = 'public'::regnamespace
             and p.prokind = 'f' and p.proname = 'register_member_tx') as 內容

  union all
  select 2, '② 授權（anon 與 authenticated 都要有）',
         (select 'anon=' || case when has_function_privilege('anon', p.oid, 'execute') then '✅' else '🔴 掉了' end
              || '　auth=' || case when has_function_privilege('authenticated', p.oid, 'execute') then '✅' else '🔴 掉了' end
            from pg_proc p
           where p.pronamespace = 'public'::regnamespace
             and p.prokind = 'f' and p.proname = 'register_member_tx')

  union all
  select 3, '③ 定義檢查',
         (select case when pg_get_functiondef(p.oid) like '%migi_norm_nickname(coalesce(p_display_name%'
                      then '✅ 已正規化' else '🔴 沒換到' end
              || '　' || case when pg_get_functiondef(p.oid) like '%display_name_reserved%'
                      then '✅ 有禁字代碼' else '🔴 沒有禁字代碼' end
              || '　' || case when pg_get_functiondef(p.oid) like '%trim(coalesce(p_display_name%'
                      then '🔴 舊寫法還在' else '✅ 舊寫法已消失' end
            from pg_proc p
           where p.pronamespace = 'public'::regnamespace
             and p.prokind = 'f' and p.proname = 'register_member_tx')

  union all
  select 4, '④ 四個子測試（①② 是正對照，③④ 是擋牆兩面）',
         coalesce(current_setting('migi.reg', true), '🔴 測試區塊沒執行')

  union all
  select 5, '⑤ 確認回滾乾淨（會員數與手機）',
         (select count(*)::text || ' 位會員：'
              || string_agg(display_name || '／' || coalesce(phone, '無'), '　' order by created_at)
            from members where deleted_at is null)

) x order by 序;
