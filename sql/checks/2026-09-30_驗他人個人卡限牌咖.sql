/* ============================================================
   驗他人個人卡限牌咖（跑在 2026-09-30_他人個人卡限牌咖.sql 之後）
   交易內造樣本：兩個測試帳號、一組牌咖、一次封鎖、一次「只有自己」，
   用兩人的身分實際呼叫，最後 raise 'migi_rollback' 整筆退掉（硬規則 1：這份不留東西）。
   ⚠ 訊息設在 exception 處理器裡（硬規則 3.9），不然會跟著被回滾。
   ============================================================ */
do $$
declare
  v_msg text := '';
  ok text := '✅ '; bad text := '🔴 '; na text := '⚪ ';
  v_org uuid; a record; b record;
  c jsonb; c2 jsonb; s1 jsonb; s2 jsonb; lb jsonb; v_shared boolean; v_err text;
begin
  begin
    -- 樣本：兩個有綁 LINE 的測試帳號
    select m.id, m.org_id, m.line_user_id, m.display_name into a
      from members m where m.is_test and m.line_user_id is not null and m.deleted_at is null and m.hidden_at is null
     order by m.created_at limit 1;
    select m.id, m.org_id, m.line_user_id, m.display_name into b
      from members m where m.is_test and m.line_user_id is not null and m.deleted_at is null and m.hidden_at is null
       and m.id <> a.id and m.org_id = a.org_id
     order by m.created_at limit 1;
    if a.id is null or b.id is null then
      raise exception '找不到兩個可用的測試帳號，整份測不了';
    end if;
    v_org := a.org_id;
    v_msg := v_msg || '樣本：A＝' || a.display_name || '　B＝' || b.display_name || E'\n';

    -- 前提歸零：兩人不是牌咖、沒有封鎖、不同團、B 的成績設定是「牌咖」
    update mahjong_buddies set deleted_at = now()
     where deleted_at is null and ((member_id = a.id and buddy_id = b.id) or (member_id = b.id and buddy_id = a.id));
    delete from member_blocks where (blocker_id = a.id and blocked_id = b.id) or (blocker_id = b.id and blocked_id = a.id);
    update team_members set left_at = now()
     where left_at is null and member_id = b.id
       and team_id in (select team_id from team_members where member_id = a.id and left_at is null);
    update members set see_score = '牌咖' where id = b.id;
    v_shared := exists (select 1 from session_players me
                          join session_players op on op.session_id = me.session_id and op.member_id = b.id
                          join table_sessions s on s.id = me.session_id and s.deleted_at is null and s.status = 'completed'
                         where me.member_id = a.id);

    -- ⓪ 沒登入要被拒絕
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    begin
      c := public.get_member_card_tx(b.id);
      v_msg := v_msg || bad || '⓪ 沒登入竟然拿到了卡片' || E'\n';
    exception when others then
      v_msg := v_msg || case when sqlstate = '28000' then ok else bad end || '⓪ 沒登入被拒絕（' || sqlstate || '）' || E'\n';
    end;

    -- 以 A 的身分
    perform set_config('request.jwt.claims',
      json_build_object('sub', gen_random_uuid(), 'role', 'authenticated',
                        'app_metadata', json_build_object('line_user_id', a.line_user_id))::text, true);

    -- ① 不是牌咖：只有公開欄位
    c := public.get_member_card_tx(b.id);
    v_msg := v_msg || case when c->>'rel' = 'none' and (c->>'locked')::boolean
                             and c ? 'about' and c ? 'name' and c ? 'rank'
                             and not (c ? 'stats') and not (c ? 'together') and not (c ? 'style')
                             and not (c ? 'baby_tile') and not (c ? 'sched')
                        then ok else bad end
          || '① 不是牌咖：只回公開欄位，限牌咖的鍵一個都沒有（' || (select string_agg(k, ',' order by k) from jsonb_object_keys(c) k) || '）' || E'\n';
    v_msg := v_msg || case when (c->>'can_invite')::boolean = v_shared then ok else bad end
          || '① can_invite = ' || (c->>'can_invite') || '，跟「兩人同桌過」一致（' || v_shared || '）；而且沒有同桌次數' || E'\n';

    -- ② 加成牌咖：全部看得到
    insert into mahjong_buddies (org_id, member_id, buddy_id, origin) values (v_org, a.id, b.id, 'matched'), (v_org, b.id, a.id, 'matched');
    c := public.get_member_card_tx(b.id);
    v_msg := v_msg || case when c->>'rel' = 'buddy' and not (c->>'locked')::boolean
                             and c ? 'style' and c ? 'baby_tile' and c ? 'sched'
                             and (c->'together') ? 'n' and (c->'stats'->>'private')::boolean = false
                             and (c->'stats') ? 'min_games'
                        then ok else bad end
          || '② 牌咖：看得到標籤、寶貝牌、同桌紀錄（' || coalesce(c->'together'->>'n','?') || ' 場）、成績（' || coalesce(c->'stats'->>'games','?') || ' 場）' || E'\n';

    -- ③ 對方設「只有自己」：牌咖也看不到成績，其他照常
    update members set see_score = '只有自己' where id = b.id;
    c := public.get_member_card_tx(b.id);
    v_msg := v_msg || case when (c->'stats'->>'private')::boolean and not ((c->'stats') ? 'games') and c ? 'together' and c ? 'style'
                        then ok else bad end
          || '③ 對方「只有自己」：成績只剩 private=true，同桌紀錄與標籤照常' || E'\n';

    -- ④ 自己看自己：永遠看得到自己的成績
    c := public.get_member_card_tx(a.id);
    v_msg := v_msg || case when c->>'rel' = 'self' and (c->'stats'->>'private')::boolean = false then ok else bad end
          || '④ 看自己：rel=self、成績照常' || E'\n';

    -- ⑤ 成績頁跟個人卡是同一份算法
    s1 := public.get_my_stats_tx(v_org, null);
    s2 := public._member_stats_core(v_org, a.id);
    v_msg := v_msg || case when s1 = s2 then ok else bad end
          || '⑤ 成績頁（get_my_stats_tx）＝ core，逐字相同' || E'\n';

    -- ⑥ 牌咖清單改叫 _pair_history 之後，鍵沒少
    c2 := (select x from jsonb_array_elements(public.list_buddies_tx(v_org, null)) x where x->>'id' = b.id::text);
    v_msg := v_msg || case when c2 is not null and c2 ? 'play_pattern' and c2 ? 'last_played_at' and c2 ? 'co_play_count' then ok else bad end
          || '⑥ 牌咖清單照常有 B，而且 play_pattern／last_played_at 都在' || E'\n';

    -- ⑦ 成績設定：舊前端送「所有人」視同「牌咖」
    perform public.set_my_see_score_tx(v_org, null, '所有人');
    v_msg := v_msg || case when (select see_score from members where id = a.id) = '牌咖' then ok else bad end
          || '⑦ 送「所有人」存成「牌咖」，不報錯' || E'\n';
    begin
      perform public.set_my_see_score_tx(v_org, null, '隨便');
      v_msg := v_msg || bad || '⑦ 亂填的值竟然收了' || E'\n';
    exception when others then
      v_msg := v_msg || ok || '⑦ 亂填的值被擋' || E'\n';
    end;

    -- ⑧ 封鎖：雙方都看不到對方（不說是誰封鎖誰）
    insert into member_blocks (org_id, blocker_id, blocked_id) values (v_org, b.id, a.id);
    c := public.get_member_card_tx(b.id);
    v_msg := v_msg || case when c->>'reason' = 'blocked' and not (c ? 'name') then ok else bad end
          || '⑧ 被對方封鎖：拿不到卡片（' || coalesce(c->>'reason', '?') || '）' || E'\n';

    -- ⑨ 排行榜的每一列都有 id（上線前測試帳號被排除，可能是空的）
    lb := public.get_season_leaderboard_tx(v_org, 10);
    v_msg := v_msg || case when jsonb_array_length(coalesce(lb->'rows','[]')) = 0 then na || '⑨ 排行榜目前沒有任何一列（測試帳號本來就不上榜），測不了'
                           when not exists (select 1 from jsonb_array_elements(lb->'rows') x where not (x ? 'id')) then ok || '⑨ 排行榜每一列都有 id'
                           else bad || '⑨ 排行榜有列沒有 id' end;

    raise exception 'migi_rollback';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err = 'migi_rollback' then
      perform set_config('migi.t', v_msg || E'\n（整筆已回滾，一列都沒留）', true);
    else
      perform set_config('migi.t', v_msg || E'\n🔴 中途失敗：' || v_err, true);
    end if;
  end;
end $$;

select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有測試訊息') as "行為測試";
