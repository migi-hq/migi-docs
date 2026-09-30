/* ============================================================
   行為測試：段位熊頭像永久解鎖（交易內造樣本，**全部回滾**）
   2026-09-30 · 配 sql/pending/2026-09-30_段位熊頭像永久解鎖.sql（先跑那份）

   模擬「測試03 登入之後在換頭像」—— 在交易裡設 JWT，身分解析與真客人同一條路
   （app_metadata.line_user_id → current_member_id()）。
   ⚠ 這份**故意 raise 回滾**（硬規則 1.8 的例外：它不該留下任何東西）；
     訊息設在 exception handler 裡（硬規則 3.9）。
   ============================================================ */
do $$
declare
  v_me   uuid;
  v_org  uuid;
  v_msg  text := '';
  v_r    jsonb;
  v_ok   int := 0;
  v_all  int := 0;
begin
  select id, org_id into v_me, v_org from public.members
   where line_user_id = 'TEST-03' and deleted_at is null;
  if v_me is null then
    perform set_config('migi.t', '🔴 找不到測試03（line_user_id = TEST-03），這份測不了', true);
    return;
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated',
                      'app_metadata', json_build_object('line_user_id', 'TEST-03'))::text, true);

  -- ① 一開始只有銅牌熊（③ 回填的期望值）
  v_r := public.get_my_avatar_tx(null);
  v_all := v_all + 1;
  if v_r -> 'unlocked_bears' = '["bronze"]'::jsonb then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ① 起始解鎖 ' || coalesce(v_r ->> 'unlocked_bears', '∅') || '（期望 ["bronze"]）' || E'\n';

  -- ② 還沒升到的銀牌熊 → 擋下（正對照在 ③：銅牌熊要能選，否則一支永遠擋的實作也會讓這格綠）
  v_r := public.set_avatar_tx(null, 'bear', null, 'silver');
  v_all := v_all + 1;
  if v_r ->> 'reason' = 'bear_locked' then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ② 選還沒解鎖的銀牌熊 → ' || v_r::text || E'\n';

  -- ③ 已解鎖的銅牌熊 → 可以
  v_r := public.set_avatar_tx(null, 'bear', null, 'bronze');
  v_all := v_all + 1;
  if (v_r ->> 'ok')::boolean and (select avatar_bear from public.members where id = v_me) = 'bronze'
    then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ③ 選銅牌熊 → ' || v_r::text || E'\n';

  -- ④ 通用預設熊（null）→ 可以
  v_r := public.set_avatar_tx(null, 'bear', null, null);
  v_all := v_all + 1;
  if (v_r ->> 'ok')::boolean then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ④ 選通用預設熊 → ' || v_r::text || E'\n';

  -- ⑤ 不是段位熊的造型鍵 → 照舊不擋（原本「只擋長度不做白名單」的設計沒被誤傷）
  v_r := public.set_avatar_tx(null, 'bear', null, 'future_bear');
  v_all := v_all + 1;
  if (v_r ->> 'ok')::boolean then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ⑤ 非段位熊的造型鍵 → ' || v_r::text || E'\n';

  -- ⑥ 升到鑽石 → 最高段位跟著升、鑽石熊能選
  update public.members set rank = '鑽石熊 I' where id = v_me;
  v_r := public.set_avatar_tx(null, 'bear', null, 'diamond');
  v_all := v_all + 1;
  if (select best_rank_tier from public.members where id = v_me) = 'diamond' and (v_r ->> 'ok')::boolean
     and jsonb_array_length(public.get_my_avatar_tx(null) -> 'unlocked_bears') = 5
    then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ⑥ 升到鑽石熊 I：最高段位 ' || coalesce((select best_rank_tier from public.members where id = v_me), '∅')
        || '、解鎖 ' || coalesce(public.get_my_avatar_tx(null) ->> 'unlocked_bears', '∅') || '、選鑽石熊 ' || v_r::text || E'\n';

  -- ⑦ 換季降到銀牌 → 最高段位**不降**、鑽石熊照樣能選（這就是這一份的目的）
  update public.members set rank = '銀牌熊 I' where id = v_me;
  v_r := public.set_avatar_tx(null, 'bear', null, 'diamond');
  v_all := v_all + 1;
  if (select best_rank_tier from public.members where id = v_me) = 'diamond' and (v_r ->> 'ok')::boolean
     and jsonb_array_length(public.get_my_avatar_tx(null) -> 'unlocked_bears') = 5
    then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ⑦ 降回銀牌熊 I：最高段位仍是 ' || coalesce((select best_rank_tier from public.members where id = v_me), '∅')
        || '、選鑽石熊 ' || v_r::text || E'\n';

  -- ⑧ 沒當過冠軍 → 雀神熊擋下
  v_r := public.set_avatar_tx(null, 'bear', null, 'quegod');
  v_all := v_all + 1;
  if v_r ->> 'reason' = 'bear_locked' then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ⑧ 沒當過冠軍選雀神熊 → ' || v_r::text || E'\n';

  -- ⑨ 當過一季冠軍 → 雀神熊解鎖（假賽季放在 1990 年，避開不可重疊的約束）
  insert into public.rank_seasons (code, org_id, label, starts_at, ends_at)
  values ('TEST-1990', v_org, '測試用賽季', '1990-01-01', '1990-06-01');
  insert into public.season_champions (season, org_id, member_id, rating, awarded_at)
  values ('TEST-1990', v_org, v_me, 999, now());
  v_r := public.set_avatar_tx(null, 'bear', null, 'quegod');
  v_all := v_all + 1;
  if (v_r ->> 'ok')::boolean and (public.get_my_avatar_tx(null) -> 'unlocked_bears') ? 'quegod'
    then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ⑨ 當過冠軍選雀神熊 → ' || v_r::text || E'\n';

  -- ⑩ 沒登入 → 讀頭像被拒絕（不再退回前端送的 id）
  perform set_config('request.jwt.claims', '', true);
  v_all := v_all + 1;
  begin
    v_r := public.get_my_avatar_tx(v_me);
    v_msg := v_msg || '🔴 ⑩ 沒登入卻讀到了：' || coalesce(v_r::text, 'null') || E'\n';
  exception when others then
    if sqlstate = '28000' then v_ok := v_ok + 1; v_msg := v_msg || '✅ ⑩ 沒登入讀頭像 → 拒絕（28000）' || E'\n';
    else v_msg := v_msg || '🔴 ⑩ 沒登入讀頭像 → 別的錯 ' || sqlstate || ' ' || sqlerrm || E'\n'; end if;
  end;

  v_msg := '通過 ' || v_ok || ' / ' || v_all || E'\n' || v_msg;
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.t', v_msg, true);
  else
    perform set_config('migi.t', v_msg || '🔴 中途出錯：' || sqlstate || ' ' || sqlerrm, true);
  end if;
end $$;
select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有測試訊息') as "行為測試";
