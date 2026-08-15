-- 【這是什麼】待執行：補 set_my_nickname_tx（改暱稱寫入後端，修正「換手機暱稱重置」的 bug）。
-- 【何時讀】下次進 SQL Editor 時第一個跑這支。前端已接好對應呼叫。
-- ============================================================
-- MA1-A 補充：改暱稱 RPC（A 塊漏掉的一支，可直接執行）
-- ============================================================
create or replace function set_my_nickname_tx(p_org_id uuid, p_member_id uuid, p_nickname text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_nickname is null or length(trim(p_nickname)) = 0 then
    raise exception '暱稱不可空白';
  end if;
  if length(p_nickname) > 20 then
    raise exception '暱稱過長';
  end if;
  update members set display_name = trim(p_nickname), updated_at = now()
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
end $$;

grant execute on function set_my_nickname_tx(uuid, uuid, text) to anon, authenticated;

-- 驗證（改測試01 暱稱）
-- select set_my_nickname_tx('11111111-1111-1111-1111-111111111111','d73fdac2-d6b9-4b8a-bcff-b19c2786056f','阿明測試');
-- select display_name from members where id='d73fdac2-d6b9-4b8a-bcff-b19c2786056f';
