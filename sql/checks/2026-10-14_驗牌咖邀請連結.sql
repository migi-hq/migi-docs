-- ============================================================
-- 2026-10-14 行為測試：牌咖邀請連結（create_buddy_invite_link_tx／redeem_buddy_invite_tx）
-- 用測試帳號的真實身分（request.jwt.claims 的 sub ＝ 他的 LINE id）走一遍，最後整段退回、一筆都不留
--   測試03 發連結 → 自己點（不消耗）→ 測試04 點（成為牌咖）→ 測試02 再點同一條（已用過）
--   → 測試04 再點（已經是牌咖）→ 測試03 發第二條、測試02 封鎖測試03 → 測試02 點（擋下）
-- 跑法：Supabase SQL Editor 整份執行，看最後那一格
-- ============================================================
do $$
declare
  v_msg text := '';
  m2 uuid; m3 uuid; m4 uuid; l2 text; l3 text; l4 text; org uuid;
  r jsonb; tok text; tok2 text; n int;
  as_ text;
begin
  select id, line_user_id, org_id into m2, l2, org from members where display_name = '測試02' and is_test and deleted_at is null;
  select id, line_user_id into m3, l3 from members where display_name = '測試03' and is_test and deleted_at is null;
  select id, line_user_id into m4, l4 from members where display_name = '測試04' and is_test and deleted_at is null;
  if m2 is null or m3 is null or m4 is null or l2 is null or l3 is null or l4 is null then
    perform set_config('migi.x', '⚪ 找不到測試02／03／04 或他們沒有 LINE id，測不了', true); return;
  end if;
  begin
    -- ① 測試03 發一條
    perform set_config('request.jwt.claims', json_build_object('sub', l3, 'role', 'authenticated')::text, true);
    r := public.create_buddy_invite_link_tx(); tok := r ->> 'token';
    v_msg := v_msg || case when (r ->> 'ok')::boolean and tok ~ '^[0-9a-f]{32}$' then '✅' else '🔴 ' || r::text end || ' ① 發連結' || E'\n';
    -- ② 自己點：成功、不消耗
    r := public.redeem_buddy_invite_tx(tok);
    v_msg := v_msg || case when (r ->> 'self')::boolean and (select used_at from buddy_invite_links where token = tok) is null
                      then '✅' else '🔴 ' || r::text end || ' ② 點自己的連結：不加、不消耗' || E'\n';
    -- ③ 測試04 點：成為牌咖（兩筆互指）、連結用掉
    perform set_config('request.jwt.claims', json_build_object('sub', l4, 'role', 'authenticated')::text, true);
    r := public.redeem_buddy_invite_tx(tok);
    select count(*) into n from mahjong_buddies where deleted_at is null and ((member_id = m3 and buddy_id = m4) or (member_id = m4 and buddy_id = m3));
    v_msg := v_msg || case when (r ->> 'added')::boolean and n = 2 and (select used_by from buddy_invite_links where token = tok) = m4
                      then '✅' else '🔴 ' || r::text || ' 筆數 ' || n end || ' ③ 測試04 點了就成為測試03 的牌咖（兩筆互指、連結用掉）' || E'\n';
    v_msg := v_msg || case when exists (select 1 from app_notifications where member_id = m3 and type = 'buddy_ok' and ref_id = m4
                                         and payload ->> 'text' like '%用你的邀請連結成為牌咖了')
                      then '✅' else '🔴' end || ' ④ 測試03 收到通知' || E'\n';
    -- ⑤ 測試02 再點同一條：已用過
    perform set_config('request.jwt.claims', json_build_object('sub', l2, 'role', 'authenticated')::text, true);
    r := public.redeem_buddy_invite_tx(tok);
    v_msg := v_msg || case when r ->> 'reason' = 'used' then '✅' else '🔴 ' || r::text end || ' ⑤ 別人再點同一條：已用過' || E'\n';
    -- ⑥ 測試04 再點：已經是牌咖（成功、不重複加）
    perform set_config('request.jwt.claims', json_build_object('sub', l4, 'role', 'authenticated')::text, true);
    r := public.redeem_buddy_invite_tx(tok);
    select count(*) into n from mahjong_buddies where deleted_at is null and member_id = m4 and buddy_id = m3;
    v_msg := v_msg || case when (r ->> 'already')::boolean and n = 1 then '✅' else '🔴 ' || r::text end || ' ⑥ 已經是牌咖再點：不重複加' || E'\n';
    -- ⑦ 封鎖：測試02 封鎖測試03，測試03 發第二條給測試02 ⇒ 擋下
    insert into member_blocks (org_id, blocker_id, blocked_id) values (org, m2, m3);
    perform set_config('request.jwt.claims', json_build_object('sub', l3, 'role', 'authenticated')::text, true);
    tok2 := public.create_buddy_invite_link_tx() ->> 'token';
    perform set_config('request.jwt.claims', json_build_object('sub', l2, 'role', 'authenticated')::text, true);
    r := public.redeem_buddy_invite_tx(tok2);
    select count(*) into n from mahjong_buddies where deleted_at is null and member_id = m2 and buddy_id = m3;
    v_msg := v_msg || case when r ->> 'reason' = 'blocked' and n = 0 then '✅' else '🔴 ' || r::text end || ' ⑦ 有封鎖就不加' || E'\n';
    -- ⑧ 沒登入
    perform set_config('request.jwt.claims', '{}', true);
    r := public.redeem_buddy_invite_tx(tok2);
    v_msg := v_msg || case when r ->> 'reason' = 'not_logged_in' then '✅' else '🔴 ' || r::text end || ' ⑧ 沒登入叫不動';
    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm = 'migi_rollback' then
      perform set_config('migi.x', v_msg || E'\n（以上全部退回，資料庫沒有留下任何一筆）', true);
    else
      perform set_config('migi.x', v_msg || E'\n🔴 中途出錯：' || sqlerrm, true);
    end if;
  end;
end $$;
select coalesce(nullif(current_setting('migi.x', true), ''), '🔴 沒有訊息') as "牌咖邀請連結 · 行為測試";
