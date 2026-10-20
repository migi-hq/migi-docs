-- ════════════════════════════════════════════════════════════════
-- 行為測試：POS 店員代客人加入／移出黑名單（配合 sql/applied/2026-10-21_POS店員代客人管理黑名單.sql）
-- 在交易裡換成真的身分去叫，最後 raise 'migi_rollback' 整段回滾 ⇒ 一筆都不留。
-- ⚠ 要在 Supabase SQL Editor 跑（唯讀 MCP 不能切換角色）。
-- ⚠ 只有「叫函式」那一行切成登入身分；清前提、查結果都用原本的身分（登入身分沒有直接讀寫這張表的權限）。
--   ⓐ 店員替客人 A 封鎖 B ⇒ 有那一列、blocker 是 A、記下店員
--   ⓑ 店員替 A 移出 B ⇒ 那一列不見
--   ⓒ 會員本人（不是店員）送別人的 id 當 p_blocker ⇒ 被改成他自己、不記店員
--   ⓓ 沒登入 ⇒ 被拒絕（28000）
-- ════════════════════════════════════════════════════════════════
do $$
declare
  v_msg text := '';
  v_staff record; v_a uuid; v_b uuid; v_m record;
  v_n int; v_row record;
  v_staff_claims text; v_member_claims text;
begin
  select s.id, s.auth_uid, s.org_id into v_staff
    from staff s where s.deleted_at is null and s.auth_uid is not null
    order by s.created_at limit 1;
  select m.id into v_a from members m
   where m.org_id = v_staff.org_id and m.is_test and m.deleted_at is null and m.hidden_at is null
   order by m.created_at limit 1;
  select m.id into v_b from members m
   where m.org_id = v_staff.org_id and m.is_test and m.deleted_at is null and m.hidden_at is null and m.id <> v_a
   order by m.created_at limit 1;
  -- 會員本人那一條：有 LINE、不是店員的測試會員
  select m.id, m.line_user_id into v_m from members m
   where m.org_id = v_staff.org_id and m.is_test and m.deleted_at is null and m.hidden_at is null
     and m.line_user_id is not null and m.id not in (v_a, v_b)
     and not exists (select 1 from staff s where s.member_id = m.id and s.deleted_at is null)
   order by m.created_at limit 1;
  if v_staff.id is null or v_a is null or v_b is null then
    v_msg := '⚪ 找不到店員或兩位測試會員，測不了';
    raise exception 'migi_rollback';
  end if;
  v_staff_claims := json_build_object('sub', v_staff.auth_uid, 'role', 'authenticated')::text;

  -- ⓐ 店員替客人封鎖
  delete from member_blocks where blocked_id = v_b and blocker_id in (v_a, coalesce(v_m.id, v_a));   -- 前提（回滾會還原）
  perform set_config('request.jwt.claims', v_staff_claims, true);
  set local role authenticated;
  perform public.block_member_tx(null, v_a, v_b);
  reset role;
  select * into v_row from member_blocks where blocker_id = v_a and blocked_id = v_b;
  v_msg := v_msg || case when v_row.id is not null and v_row.created_by_staff_id = v_staff.id
                         then '✅ ⓐ 店員替客人封鎖：有那一列、記下是哪位店員'
                         else '🔴 ⓐ 店員封鎖沒成功或沒記店員' end;

  -- ⓑ 店員替客人移出
  set local role authenticated;
  perform public.unblock_member_tx(null, v_a, v_b);
  reset role;
  select count(*) into v_n from member_blocks where blocker_id = v_a and blocked_id = v_b;
  v_msg := v_msg || E'\n' || case when v_n = 0 then '✅ ⓑ 店員替客人移出：那一列不見了' else '🔴 ⓑ 移出沒成功' end;

  -- ⓒ 會員本人（不是店員）送別人的 id 當 blocker
  if v_m.id is null then
    v_msg := v_msg || E'\n⚪ ⓒ 找不到有 LINE 又不是店員的測試會員，這一格測不了';
  else
    v_member_claims := json_build_object('sub', gen_random_uuid(), 'role', 'authenticated',
                         'app_metadata', json_build_object('line_user_id', v_m.line_user_id))::text;
    perform set_config('request.jwt.claims', v_member_claims, true);
    set local role authenticated;
    -- 會員那條路照舊用前端送的機構（App 一律送 MIGI_ORG_ID）；第一版這裡傳 null ⇒ 撞 org_id 非空，是測試寫錯
    perform public.block_member_tx(v_staff.org_id, v_a, v_b);
    reset role;
    select * into v_row from member_blocks where blocked_id = v_b and blocker_id in (v_m.id, v_a) limit 1;
    v_msg := v_msg || E'\n' || case when v_row.blocker_id = v_m.id and v_row.created_by_staff_id is null
                                    then '✅ ⓒ 會員送別人的 id 也只會封鎖到自己、不記店員'
                                    when v_row.blocker_id = v_a then '🔴 ⓒ 會員冒用別人封鎖成功了'
                                    else '🔴 ⓒ 會員封鎖沒有寫進去' end;
  end if;

  -- ⓓ 沒登入
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  begin
    set local role authenticated;
    perform public.block_member_tx(null, v_a, v_b);
    reset role;
    v_msg := v_msg || E'\n🔴 ⓓ 沒登入也封鎖成功了';
  exception when others then
    v_msg := v_msg || E'\n' || case when sqlstate = '28000' then '✅ ⓓ 沒登入被拒絕（28000）'
                                    else '🔴 ⓓ 被拒絕但原因不對：' || sqlerrm end;
  end;

  raise exception 'migi_rollback';
exception when others then
  -- 訊息一律在這裡設（硬規則 3.9）；變數不會被回滾，set_config 會
  perform set_config('migi.t',
    case when sqlerrm = 'migi_rollback' then v_msg
         else coalesce(nullif(v_msg, ''), '') || E'\n🔴 中途出錯：' || sqlerrm end, true);
end $$;
select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有訊息') as "行為測試";
