/* ============================================================
   驗 POS 看四台平板畫面（行為測試，整段在交易裡跑完回滾，不留任何東西）· 2026-10-02
   配合 sql/applied/2026-10-02_POS看四台平板畫面.sql（先跑那一份）

   ⓐ 平板入口拆開之後回的，跟核心一模一樣（拿一台真的平板，暫時換一組測試憑證來叫）
   ⓑ 沒登入叫 POS 入口 ⇒ not_staff
   ⓒ 一般會員（不是店員）叫 POS 入口 ⇒ not_staff
   ⓓ 店員（老闆）叫 POS 入口 ⇒ 這張桌每一台平板都有，而且每一台的畫面資料跟那台平板自己讀到的一模一樣
   ⓔ 不存在的桌 ⇒ not_found
   ⚠ 訊息一律寫在 exception 處理器裡（硬規則 3.9）；最後故意 raise 讓整段回滾（硬規則 1.8：這份不要留下東西）
   ============================================================ */
do $$
declare
  v_msg text := ''; v_tok text := repeat('migiwatchtest', 4);
  d public.table_devices; v_tbl uuid; v_a jsonb; v_b jsonb; v_r jsonb;
  v_owner_line text; v_member_line text; v_n int; v_bad int;
begin
  -- 樣本：一張有開著場次、而且有綁平板的桌（找不到就出聲，不安靜跳過）
  select dv.* into d from table_devices dv
   where dv.is_active and exists (select 1 from table_sessions s where s.table_id = dv.table_id and s.status = 'open' and s.deleted_at is null)
     and exists (select 1 from session_players sp join table_sessions s on s.id = sp.session_id
                  where sp.device_id = dv.id and s.status = 'open' and s.deleted_at is null)
   order by dv.label limit 1;
  if d.id is null then
    v_msg := '⚪ 找不到「開著場次又綁了平板」的桌，ⓐⓓ 測不了';
  else
    v_tbl := d.table_id;
    -- ⓐ 暫時把這台平板的憑證換成測試用的（交易結束就回滾）
    update table_devices set token_hash = public._tbl_hash(v_tok) where id = d.id;
    v_a := public.tbl_state_tx(v_tok);
    select * into d from table_devices where id = d.id;
    v_b := public._tbl_state_for_device(d);
    v_msg := v_msg || case when v_a = v_b and v_a ->> 'session' is not null
      then '✅ ⓐ 平板入口回的跟核心一模一樣（' || d.label || '，有場次）'
      else '🔴 ⓐ 平板入口跟核心不一樣，或沒有場次' end;
  end if;

  -- ⓑ 沒登入
  perform set_config('request.jwt.claims', '', true);
  v_r := public.pos_tbl_watch_tx(coalesce(v_tbl, gen_random_uuid()));
  v_msg := v_msg || E'\n' || case when v_r ->> 'reason' = 'not_staff' then '✅ ⓑ 沒登入 ⇒ not_staff' else '🔴 ⓑ 沒登入卻得到：' || coalesce(v_r ->> 'reason', v_r::text) end;

  -- ⓒ 一般會員：有 LINE 身分、但不是任何一間店的店員
  select m.line_user_id into v_member_line from members m
   where m.is_test and m.line_user_id is not null and m.deleted_at is null
     and not exists (select 1 from staff s where s.member_id = m.id and s.deleted_at is null) limit 1;
  if v_member_line is null then
    v_msg := v_msg || E'\n⚪ ⓒ 找不到不是店員的測試會員，這一格測不了';
  else
    perform set_config('request.jwt.claims', jsonb_build_object('role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', v_member_line))::text, true);
    v_r := public.pos_tbl_watch_tx(coalesce(v_tbl, gen_random_uuid()));
    v_msg := v_msg || E'\n' || case when v_r ->> 'reason' = 'not_staff' then '✅ ⓒ 一般會員 ⇒ not_staff' else '🔴 ⓒ 一般會員卻得到：' || coalesce(v_r ->> 'reason', v_r::text) end;
  end if;

  -- ⓓ 店員（老闆：owner／hq，看得到每一間店）
  select m.line_user_id into v_owner_line from staff s join members m on m.id = s.member_id
   where s.deleted_at is null and s.role in ('owner', 'hq') and m.line_user_id is not null limit 1;
  if v_owner_line is null or v_tbl is null then
    v_msg := v_msg || E'\n⚪ ⓓ 找不到有 LINE 的老闆帳號或樣本桌，這一格測不了';
  else
    perform set_config('request.jwt.claims', jsonb_build_object('role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', v_owner_line))::text, true);
    v_r := public.pos_tbl_watch_tx(v_tbl);
    select count(*) into v_n from table_devices where table_id = v_tbl and is_active;
    select count(*) into v_bad from jsonb_array_elements(coalesce(v_r -> 'devices', '[]'::jsonb)) x
     where (x -> 'state') is distinct from public._tbl_state_for_device((select dv from table_devices dv where dv.id = (x ->> 'device_id')::uuid));
    v_msg := v_msg || E'\n' || case
      when coalesce((v_r ->> 'ok')::boolean, false) is false then '🔴 ⓓ 老闆叫不到：' || coalesce(v_r ->> 'reason', v_r::text)
      when jsonb_array_length(v_r -> 'devices') <> v_n then '🔴 ⓓ 平板數對不上：回 ' || jsonb_array_length(v_r -> 'devices') || '、應為 ' || v_n
      when v_bad > 0 then '🔴 ⓓ 有 ' || v_bad || ' 台的畫面資料跟平板自己讀到的不一樣'
      else '✅ ⓓ 老闆看得到這張桌 ' || v_n || ' 台平板，每一台都跟平板自己讀到的一模一樣' end;

    -- ⓔ 不存在的桌
    v_r := public.pos_tbl_watch_tx(gen_random_uuid());
    v_msg := v_msg || E'\n' || case when v_r ->> 'reason' = 'not_found' then '✅ ⓔ 不存在的桌 ⇒ not_found' else '🔴 ⓔ 不存在的桌卻得到：' || coalesce(v_r ->> 'reason', v_r::text) end;
  end if;

  raise exception 'migi_rollback';
exception when others then
  perform set_config('migi.watch_test', v_msg || case when sqlerrm = 'migi_rollback' then '' else E'\n🔴 中途出錯：' || sqlerrm end, true);
end $$;

select coalesce(nullif(current_setting('migi.watch_test', true), ''), '🔴 沒有測試訊息') as "POS 看四台平板畫面（已回滾）";
