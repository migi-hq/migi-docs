/* ============================================================
   2026-11-19 · POS 報價自動套用優惠券（2026-11-16 使用者拍板）
   ------------------------------------------------------------
   規則（使用者原話整理）：
     · 每類各自動用一張
       生日  生日券（kind = birthday）：單上有當日暢打才用
       檯費  檯費券（kind = table_discount）：只在它比會員折扣／牌咖團優惠折得多時才用
             （三選一本來就由 _cart_pricing 決定；券輸了 _cart_pricing 會報錯 ⇒ 這裡就不挑它）
       餐飲  餐飲券（kind = fnb）：單上有它折得到的餐飲才用
     · 同一類有好幾張：挑「多省最多」的那一張；一樣多就用**最早到期**的
     · 其他種類（generic、ride、topup_bonus、unlimited_play）不自動用，店員要用自己選
     · 店員要改才按「更換」；全部取消就是送空的、不再自動

   做法：
     · 新函式 _auto_coupons：只負責「挑哪幾張」，每一張都用 _cart_pricing 實際試算
       ⇒ 計價規則仍然只有一份（_cart_pricing），這裡沒有重寫任何一條折扣規則
     · pos_quote_tx 多一個參數 p_auto_coupons（預設 false）
       true  ⇒ 不看 p_coupon_ids，改用自動挑的那幾張算
       false ⇒ 跟今天一模一樣（舊版 POS 沒送這個參數 ⇒ 不會突然出現畫面上有折、實收沒折）
     · 回傳多兩個鍵：
       applied_coupon_ids  這次報價實際用了哪幾張 —— POS 結帳時就送這一份，報價與實收才會一致
       auto_coupons        自動挑的明細（哪一類、多省多少）；p_auto_coupons = false 時是 null
   ⚠ 結帳（checkout_tx 那一族）完全不動：它照舊只認 POS 送來的券。
   ⚠ 改簽名 ⇒ 先 DROP 舊的再建，所以結尾補 grant（硬規則 2、2.7）。
   ============================================================ */

create or replace function public._auto_coupons(
  p_org uuid, p_member_id uuid, p_items jsonb, p_advisor_cut bigint default 0)
returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $$
/* 挑出要自動用的券。每一張候選都丟給 _cart_pricing 試算，看應付金額少了多少。
   回傳 {ids: [...], picks: [{member_coupon_id, slot, name, saves}]}。
   不寫入任何東西；任何一張試算失敗（不適用、要最低消費、輸給會員折扣…）就略過那一張。 */
declare
  v_ids uuid[] := '{}';
  v_picks jsonb := '[]'::jsonb;
  v_base bigint; v_try bigint;
  v_best_id uuid; v_best_save bigint; v_best_name text;
  v_slot text; c record;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    return jsonb_build_object('ids', '[]'::jsonb, 'picks', '[]'::jsonb);
  end if;

  begin
    v_base := (public._cart_pricing(p_org, p_member_id, p_items, null, p_advisor_cut) ->> 'payable')::bigint;
  exception when others then
    return jsonb_build_object('ids', '[]'::jsonb, 'picks', '[]'::jsonb);
  end;

  -- 順序有意義：生日券先放（它送的是暢打，不跟檯費三選一搶），再挑檯費、最後餐飲
  foreach v_slot in array array['birthday', 'fee', 'fnb'] loop
    v_best_id := null; v_best_save := 0; v_best_name := null;
    for c in
      select mc.id, cp.name
        from member_coupons mc
        join coupons cp on cp.id = mc.coupon_id
       where mc.member_id = p_member_id
         and mc.org_id = p_org
         and mc.status = 'active' and mc.used_at is null
         and (mc.expires_at is null or mc.expires_at > now())
         and (mc.valid_from is null or mc.valid_from <= now())
         and not (mc.id = any(v_ids))
         and cp.kind = case v_slot when 'birthday' then 'birthday'
                                   when 'fee'      then 'table_discount'
                                   else                 'fnb' end
       order by mc.expires_at nulls last, mc.granted_at, mc.id   -- 一樣多時留下最早到期的
       limit 30
    loop
      begin
        v_try := (public._cart_pricing(p_org, p_member_id, p_items, v_ids || c.id, p_advisor_cut) ->> 'payable')::bigint;
      exception when others then
        v_try := null;
      end;
      if v_try is not null and v_base - v_try > v_best_save then
        v_best_save := v_base - v_try; v_best_id := c.id; v_best_name := c.name;
      end if;
    end loop;

    if v_best_id is not null then
      v_ids := v_ids || v_best_id;
      v_base := v_base - v_best_save;
      v_picks := v_picks || jsonb_build_array(jsonb_build_object(
        'member_coupon_id', v_best_id, 'slot', v_slot, 'name', v_best_name, 'saves', v_best_save));
    end if;
  end loop;

  return jsonb_build_object('ids', to_jsonb(v_ids), 'picks', v_picks);
end $$;

-- 只給報價函式內部用，前端叫不到（預設權限本來就全關，這裡寫明）
revoke execute on function public._auto_coupons(uuid, uuid, jsonb, bigint) from public;
revoke execute on function public._auto_coupons(uuid, uuid, jsonb, bigint) from anon, authenticated;


drop function if exists public.pos_quote_tx(uuid, uuid, text, uuid[], jsonb, uuid[], uuid[]);

create function public.pos_quote_tx(
  p_session_id uuid, p_member_id uuid,
  p_join_type text default 'opener'::text, p_pay_for uuid[] default null::uuid[],
  p_items jsonb default null::jsonb, p_coupon_ids uuid[] default null::uuid[],
  p_table_members uuid[] default null::uuid[],
  p_auto_coupons boolean default false)
returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $function$
/* 給 POS 結帳頁畫金額用。**不寫入任何東西**。
   模式跟實際結帳走的那一支判斷方式一樣（由資料庫判斷，不採信前端的推測）：
     quick  沒有桌次                 ⇒ 只有購物車
     join   有桌次、這個人還沒入座   ⇒ 檯費那一行（_join_plan）＋ 購物車
     addon  有桌次、已經入座          ⇒ 只有購物車
   金額一律由 _cart_pricing 算 —— checkout_tx 叫的是同一支。
   🆕 2026-11-01：p_table_members ＝ 這桌四位，商人熊的判斷與金額都在 _join_plan。
   🆕 2026-11-14：coupon_options ＝ 這位客人每一張券「這次單獨用能不能用、省多少、不能用的原因」，
     給 POS 把用不到的券反灰。選了券報價失敗時也照樣回，畫面才知道要灰掉哪一張。
   🆕 2026-11-19：p_auto_coupons = true ⇒ 不看 p_coupon_ids，改用系統自動挑的券（每類一張）。
     applied_coupon_ids ＝ 這次實際用了哪幾張，POS 結帳就送這一份。
   錯誤一律回 {ok:false, reason, message}，不拋例外：畫面要能把那句話原樣顯示。 */
declare
  v_mode text; v_org uuid; v_items jsonb; v_plan jsonb := null; v_price jsonb; v_s record; v_adv jsonb := null;
  v_adv_cut bigint; v_base jsonb; v_try jsonb; v_opts jsonb := '[]'::jsonb; oc record;
  v_auto jsonb := null; v_ids uuid[];
begin
  perform public._api_staff_only();
  if p_member_id is null then
    return jsonb_build_object('ok', false, 'reason', 'member_required', 'message', '請先選擇會員');
  end if;

  if p_session_id is null then
    v_mode := 'quick';
    select org_id into v_org from members where id = p_member_id and deleted_at is null;
    if v_org is null then
      return jsonb_build_object('ok', false, 'reason', 'member_required', 'message', '需先建立會員資料');
    end if;
    v_items := coalesce(p_items, '[]'::jsonb);
  else
    select id, org_id, status into v_s from table_sessions where id = p_session_id and deleted_at is null;
    if v_s.id is null then
      return jsonb_build_object('ok', false, 'reason', 'session_not_found', 'message', '場次不存在');
    end if;
    if exists (select 1 from session_players
                where session_id = p_session_id and member_id = p_member_id and left_at is null) then
      v_mode := 'addon';
      if v_s.status <> 'open' then
        return jsonb_build_object('ok', false, 'reason', 'session_closed', 'mode', v_mode, 'message', '此場次已結束，無法加購');
      end if;
      v_org := v_s.org_id;
      v_items := coalesce(p_items, '[]'::jsonb);
    else
      v_mode := 'join';
      v_plan := public._join_plan(p_session_id, p_member_id, coalesce(p_join_type, 'opener'), p_pay_for, p_items, p_table_members);
      if not coalesce((v_plan ->> 'ok')::boolean, false) then
        return v_plan || jsonb_build_object('mode', v_mode);
      end if;
      v_org := (v_plan ->> 'org_id')::uuid;
      v_items := v_plan -> 'items';
      if jsonb_typeof(v_plan -> 'advisor') = 'object' then v_adv := v_plan -> 'advisor'; end if;
    end if;
  end if;
  v_adv_cut := coalesce((v_adv ->> 'cut')::bigint, 0);

  -- 每一張券單獨試算一次（購物車是空的就不算：還沒有東西可折）
  if jsonb_array_length(v_items) > 0 then
    begin
      v_base := public._cart_pricing(v_org, p_member_id, v_items, null, v_adv_cut);
    exception when others then v_base := null;
    end;
    if v_base is not null then
      for oc in
        select mc.id, c.name, c.kind
          from member_coupons mc join coupons c on c.id = mc.coupon_id
         where mc.member_id = p_member_id and mc.used_at is null and coalesce(mc.status, '') <> 'used'
           and (mc.expires_at is null or mc.expires_at > now())
         order by mc.expires_at nulls last, mc.granted_at
         limit 30
      loop
        begin
          v_try := public._cart_pricing(v_org, p_member_id, v_items, array[oc.id], v_adv_cut);
          v_opts := v_opts || jsonb_build_array(jsonb_build_object(
            'member_coupon_id', oc.id, 'name', oc.name, 'kind', oc.kind, 'ok', true,
            'saves', (v_base ->> 'payable')::bigint - (v_try ->> 'payable')::bigint));
        exception when others then
          v_opts := v_opts || jsonb_build_array(jsonb_build_object(
            'member_coupon_id', oc.id, 'name', oc.name, 'kind', oc.kind, 'ok', false, 'message', sqlerrm));
        end;
      end loop;
    end if;
  end if;

  -- 這次要用哪幾張：自動挑，或照店員選的
  if p_auto_coupons then
    v_auto := public._auto_coupons(v_org, p_member_id, v_items, v_adv_cut);
    v_ids := array(select jsonb_array_elements_text(v_auto -> 'ids')::uuid);
  else
    v_ids := p_coupon_ids;
  end if;

  begin
    v_price := public._cart_pricing(v_org, p_member_id, v_items, v_ids, v_adv_cut);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'pricing', 'mode', v_mode, 'message', sqlerrm,
                              'coupon_options', v_opts);
  end;

  return v_price || jsonb_build_object('ok', true, 'mode', v_mode, 'coupon_options', v_opts,
    'applied_coupon_ids', coalesce(to_jsonb(v_ids), '[]'::jsonb),
    'auto_coupons', case when p_auto_coupons then v_auto -> 'picks' else null end,
    /* 畫面上那一行：「牌咖團專屬：檯費優惠 50 元」。金額以 advisor_discount 為準（_cart_pricing 挑過、夾過的） */
    'advisor', case when v_adv is null or coalesce((v_price ->> 'advisor_discount')::bigint, 0) = 0 then null
                    else jsonb_build_object('code', v_adv ->> 'code', 'team_name', v_adv ->> 'team_name',
                                            'count', jsonb_array_length(v_adv -> 'members'),
                                            'members', v_adv -> 'members',
                                            'amount', (v_price ->> 'advisor_discount')::bigint) end,
    'fee_line', case when v_plan is null then null else jsonb_build_object(
      'product_id', v_plan ->> 'fee_product_id', 'name', v_plan ->> 'fee_name',
      'unit', (v_plan ->> 'unit_fee')::bigint, 'qty', (v_plan ->> 'qty')::int,
      'amount', (v_plan ->> 'amount')::bigint,
      'daypass', (v_plan ->> 'daypass')::boolean, 'daypass_bought', (v_plan ->> 'daypass_bought')::boolean) end);
end $function$;

-- DROP 重建 ＝ 新建 ⇒ 預設全關，POS（登入的店員）要明確給
revoke execute on function public.pos_quote_tx(uuid, uuid, text, uuid[], jsonb, uuid[], uuid[], boolean) from public;
revoke execute on function public.pos_quote_tx(uuid, uuid, text, uuid[], jsonb, uuid[], uuid[], boolean) from anon;
grant  execute on function public.pos_quote_tx(uuid, uuid, text, uuid[], jsonb, uuid[], uuid[], boolean) to authenticated;


/* ── 驗證（單一 SELECT，不 raise；行為另見 sql/checks/2026-11-19_驗報價自動套用優惠券.sql）── */
select concat_ws(E'\n',
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'pos_quote_tx') = 1
        and exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'pos_quote_tx'
                     and pg_get_function_identity_arguments(oid) like '%p_auto_coupons boolean')
       then '✅ ① pos_quote_tx 只有一個版本，而且有 p_auto_coupons'
       else '🔴 ① pos_quote_tx 版本不對（舊的沒刪掉，或新參數不在）' end,
  case when exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.pronamespace = 'public'::regnamespace and p.proname = 'pos_quote_tx'
                       and a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE')
       then '✅ ② POS（authenticated）叫得動 pos_quote_tx'
       else '🔴 ② authenticated 沒有 pos_quote_tx 的執行權 —— POS 結帳頁會整個讀不到金額' end,
  case when not exists (select 1 from pg_proc p
                         where p.pronamespace = 'public'::regnamespace and p.proname = 'pos_quote_tx'
                           and (p.proacl is null
                                or exists (select 1 from aclexplode(p.proacl) a
                                            where a.grantee in (0, 'anon'::regrole::oid) and a.privilege_type = 'EXECUTE')))
       then '✅ ③ anon／PUBLIC 叫不到 pos_quote_tx'
       else '🔴 ③ pos_quote_tx 開給了 anon 或 PUBLIC' end,
  case when exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = '_auto_coupons')
        and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                         where p.pronamespace = 'public'::regnamespace and p.proname = '_auto_coupons'
                           and a.grantee in (0, 'anon'::regrole::oid, 'authenticated'::regrole::oid)
                           and a.privilege_type = 'EXECUTE')
       then '✅ ④ _auto_coupons 在，前端叫不到'
       else '🔴 ④ _auto_coupons 不在，或前端叫得到' end,
  /* 用 pg_proc 撈而不是 ::regproc —— ① 失敗（兩個版本並存）時 ::regproc 會直接拋錯，整份驗證都看不到 */
  case when coalesce((select bool_and(pg_get_functiondef(oid) ~ 'v_auto\s*:=\s*public\._auto_coupons\(')
                        from pg_proc where pronamespace = 'public'::regnamespace and proname = 'pos_quote_tx' and prokind = 'f'), false)
        and coalesce((select bool_and(pg_get_functiondef(oid) ~ 'public\._cart_pricing\(')
                        from pg_proc where pronamespace = 'public'::regnamespace and proname = '_auto_coupons' and prokind = 'f'), false)
       then '✅ ⑤ 報價真的叫了挑券函式，挑券函式用的是同一支計價核心'
       else '🔴 ⑤ 報價沒有叫挑券函式，或挑券函式沒有用 _cart_pricing 試算' end
) as "驗證";
