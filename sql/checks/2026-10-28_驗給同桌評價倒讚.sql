-- ============================================================
-- 2026-10-28 行為測試：給同桌評價的倒讚（dislike_player_tx ＋ like_player_tx 二選一）
-- 用測試帳號的真實身分（request.jwt.claims 的 sub ＝ 他的 LINE id）走一遍，最後整段退回、一筆都不留
--   樣本：兩個測試帳號一起坐過的一場（現成的，不新造）
--   A 倒讚 B → 讚 B（倒讚被撤掉）→ 倒讚 B（讚被撤掉、讚數扣回）→ 取消倒讚
--   → 倒讚自己（擋）→ 倒讚沒同桌過的人（擋）→ 沒登入（擋）→ 牌局詳情回 disliked_by_me
-- 跑法：先跑 sql/pending/2026-10-28_給同桌評價倒讚.sql，再在 Supabase SQL Editor 整份執行這份，看最後那一格
-- ============================================================
do $$
declare
  v_msg text := '';
  s uuid; org uuid; ma uuid; mb uuid; la text; mo uuid;
  r jsonb; n int; lk0 int; lk int; g jsonb;
begin
  select a.session_id, a.member_id, b.member_id, ma_.line_user_id, ts.org_id
    into s, ma, mb, la, org
    from session_players a
    join session_players b on b.session_id = a.session_id and b.member_id <> a.member_id
    join members ma_ on ma_.id = a.member_id
    join members mb_ on mb_.id = b.member_id
    join table_sessions ts on ts.id = a.session_id
   where ma_.is_test and mb_.is_test and ma_.line_user_id is not null and ma_.deleted_at is null and mb_.deleted_at is null
   limit 1;
  if s is null then
    perform set_config('migi.x', '⚪ 找不到兩個測試帳號一起坐過的場次，測不了', true); return;
  end if;
  -- 沒跟 A 同桌過的某位會員（給「不是同桌」那一格用）
  select m.id into mo from members m
   where m.deleted_at is null and m.id <> ma
     and not exists (select 1 from session_players sp where sp.session_id = s and sp.member_id = m.id)
   limit 1;

  begin
    perform set_config('request.jwt.claims', json_build_object('sub', la, 'role', 'authenticated')::text, true);
    delete from member_likes where liker_id = ma and target_id = mb and session_id = s;   -- 從乾淨的狀態開始
    select likes_count into lk0 from members where id = mb;

    -- ① 倒讚
    r := public.dislike_player_tx(mb, true, s);
    select count(*) into n from member_dislikes where rater_id = ma and target_id = mb and session_id = s;
    v_msg := v_msg || case when (r ->> 'ok')::boolean and n = 1 then '✅' else '🔴 ' || r::text end || ' ① 倒讚寫進去' || E'\n';
    -- ② 重按一次不重複
    r := public.dislike_player_tx(mb, true, s);
    select count(*) into n from member_dislikes where rater_id = ma and target_id = mb and session_id = s;
    v_msg := v_msg || case when n = 1 then '✅' else '🔴 ' || n end || ' ② 重按不會多一筆' || E'\n';
    -- ③ 改按讚 ⇒ 倒讚被撤掉
    perform public.like_player_tx(org, ma, mb, true, s);
    select count(*) into n from member_dislikes where rater_id = ma and target_id = mb and session_id = s;
    select likes_count into lk from members where id = mb;
    v_msg := v_msg || case when n = 0 and lk = lk0 + 1 then '✅' else '🔴 倒讚 ' || n || ' 讚數 ' || lk0 || '→' || lk end || ' ③ 按讚撤掉倒讚、讚數 +1' || E'\n';
    -- ④ 再按倒讚 ⇒ 讚被撤掉、讚數扣回
    r := public.dislike_player_tx(mb, true, s);
    select count(*) into n from member_likes where liker_id = ma and target_id = mb and session_id = s;
    select likes_count into lk from members where id = mb;
    v_msg := v_msg || case when n = 0 and lk = lk0 then '✅' else '🔴 讚 ' || n || ' 讚數 ' || lk0 || '→' || lk end || ' ④ 按倒讚撤掉讚、讚數扣回' || E'\n';
    -- ⑤ 牌局詳情回 disliked_by_me
    g := public._game_row(org, s, ma);
    v_msg := v_msg || case when exists (select 1 from jsonb_array_elements(g -> 'players') p
                                         where (p ->> 'member_id')::uuid = mb and (p ->> 'disliked_by_me')::boolean)
                      then '✅' else '🔴' end || ' ⑤ 牌局詳情看得到「我倒讚過他」' || E'\n';
    -- ⑥ 取消倒讚
    r := public.dislike_player_tx(mb, false, s);
    select count(*) into n from member_dislikes where rater_id = ma and target_id = mb and session_id = s;
    v_msg := v_msg || case when (r ->> 'ok')::boolean and n = 0 then '✅' else '🔴 ' || r::text end || ' ⑥ 取消倒讚' || E'\n';
    -- ⑦ 倒讚自己
    r := public.dislike_player_tx(ma, true, s);
    v_msg := v_msg || case when r ->> 'reason' = 'self' then '✅' else '🔴 ' || r::text end || ' ⑦ 不能倒讚自己' || E'\n';
    -- ⑧ 倒讚沒同桌的人
    r := public.dislike_player_tx(mo, true, s);
    v_msg := v_msg || case when mo is null then '⚪ 找不到沒同桌的會員，這一格測不了'
                           when r ->> 'reason' = 'not_tablemates' then '✅' else '🔴 ' || r::text end || ' ⑧ 不能倒讚沒同桌的人' || E'\n';
    -- ⑨ 沒登入
    perform set_config('request.jwt.claims', '{}', true);
    begin
      perform public.dislike_player_tx(mb, true, s);
      v_msg := v_msg || '🔴 ⑨ 沒登入竟然叫得動';
    exception when others then
      v_msg := v_msg || case when sqlstate = '28000' then '✅' else '🔴 ' || sqlerrm end || ' ⑨ 沒登入叫不動';
    end;
    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm = 'migi_rollback' then
      perform set_config('migi.x', v_msg || E'\n（以上全部退回，資料庫沒有留下任何一筆）', true);
    else
      perform set_config('migi.x', v_msg || E'\n🔴 中途出錯：' || sqlerrm, true);
    end if;
  end;
end $$;
select coalesce(nullif(current_setting('migi.x', true), ''), '🔴 沒有訊息') as "給同桌評價倒讚 · 行為測試";
