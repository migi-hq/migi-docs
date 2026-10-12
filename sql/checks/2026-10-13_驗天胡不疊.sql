-- ============================================================================
-- 2026-10-13 行為測試：天胡不疊（先跑 sql/pending/2026-10-13_天胡不疊.sql 再跑這份）
-- 自己造樣本：一張沒有牌局的桌、一場牌局、四位測試會員、一台測試平板（選莊家），定座位開第一將；
-- 每一格在自己的存檔點裡送出、看完就退回（不留待確認的那一局擋下一格），最後整段 raise 回滾。
-- ① 莊家天胡自摸：送得出去、沒有被補自摸、牌型 24 台、每家付 底 ＋ 台 ×（24 ＋ 莊家 1）
-- ② 天胡 ＋ 門清自摸：擋下
-- ③ 一般自摸（混一色）：照樣自動補自摸 1 台（4 ＋ 1 ＝ 5）
-- ④ 門清自摸：照樣不補（負對照，3 台）
-- ============================================================================
do $$
declare
  v_msg text := '';
  v_org uuid; v_store uuid; v_table uuid; v_stake uuid; v_base int; v_unit int; v_sess uuid;
  v_m uuid[]; v_p uuid[] := '{}'; v_pid uuid; i int;
  v_tok text := repeat('cd', 32); r jsonb; ck text; v_codes text;
begin
  select array_agg(id order by created_at) into v_m from (
    select m.id, m.created_at from members m
     where m.is_test and m.deleted_at is null and m.hidden_at is null
       and not exists (select 1 from session_players sp join table_sessions s on s.id = sp.session_id
                        where sp.member_id = m.id and sp.left_at is null and s.status = 'open' and s.deleted_at is null)
     order by m.created_at limit 4) x;
  select org_id into v_org from members where id = v_m[1];
  select t.id, t.store_id into v_table, v_store from tables t
   where t.org_id = v_org and t.deleted_at is null
     and not exists (select 1 from table_sessions s where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
   order by t.label limit 1;
  select id, base, tai into v_stake, v_base, v_unit from stake_levels
   where org_id = v_org and not coalesce(is_hygiene, false) and base > 0 order by base limit 1;
  if coalesce(array_length(v_m, 1), 0) < 4 or v_table is null or v_stake is null then
    raise exception '🔴 找不到樣本（要四位沒在打牌的測試會員、一張空桌、一個有積分的級距）';
  end if;

  insert into table_sessions (org_id, store_id, table_id, mode, status, is_test, game_type, flower, stake_level_id, planned_rounds)
  values (v_org, v_store, v_table, 'matched', 'open', true, '台麻', '無花', v_stake, 3) returning id into v_sess;
  for i in 1..4 loop
    insert into session_players (org_id, session_id, member_id, join_type, status)
    values (v_org, v_sess, v_m[i], 'opener', 'playing') returning id into v_pid;
    v_p := v_p || v_pid;
  end loop;
  insert into table_devices (org_id, store_id, table_id, label, token_hash, last_seen_at)
  values (v_org, v_store, v_table, '測試平板', public._tbl_hash(v_tok), now());
  r := public.tbl_claim_seat_tx(v_tok, v_p[1]);
  if not coalesce((r->>'ok')::boolean, false) then raise exception '🔴 選人失敗：%', r; end if;
  r := public.tbl_set_order_tx(v_tok, v_p[1], v_p[2], v_p[3]);   -- 這台平板的人當莊家（座位 1）
  if not coalesce((r->>'ok')::boolean, false) then raise exception '🔴 定座位失敗：%', r; end if;

  -- ① 莊家天胡自摸
  begin
    r := public.tbl_submit_hand_tx(v_tok, 'tsumo', null, '[{"code":"tianhu","n":1}]'::jsonb, null);
    select string_agg(p ->> 'code', ',' order by p ->> 'code') into v_codes
      from hands h, jsonb_array_elements(h.patterns) p where h.id = (r ->> 'hand_id')::uuid;
    ck := case when (r ->> 'ok')::boolean and v_codes = 'tianhu' and (r ->> 'tai_pattern')::int = 24
                and (r -> 'proposed_delta' ->> '2')::int = -(v_base + v_unit * (24 + 1))
               then '✅' else '🔴 ' || r::text || ' 牌型=' || coalesce(v_codes, '（無）') end;
    raise exception 'migi_step';
  exception when others then
    if sqlerrm <> 'migi_step' then ck := '🔴 出錯：' || sqlerrm; end if;
  end;
  v_msg := v_msg || E'\n① 莊家天胡自摸 → 送得出去、只有天胡（沒補自摸）、24 台、每家付 底＋台×25 ' || ck;

  -- ② 天胡 ＋ 門清自摸 → 擋下
  begin
    r := public.tbl_submit_hand_tx(v_tok, 'tsumo', null, '[{"code":"tianhu","n":1},{"code":"menqing_tsumo","n":1}]'::jsonb, null);
    ck := case when r ->> 'reason' = 'conflicting_patterns' then '✅（' || (r ->> 'message') || '）' else '🔴 ' || r::text end;
    raise exception 'migi_step';
  exception when others then
    if sqlerrm <> 'migi_step' then ck := '🔴 出錯：' || sqlerrm; end if;
  end;
  v_msg := v_msg || E'\n② 天胡 ＋ 門清自摸 → 擋下 ' || ck;

  -- ③ 一般自摸（混一色）→ 照樣補自摸
  begin
    r := public.tbl_submit_hand_tx(v_tok, 'tsumo', null, '[{"code":"hunyise","n":1}]'::jsonb, null);
    select string_agg(p ->> 'code', ',' order by p ->> 'code') into v_codes
      from hands h, jsonb_array_elements(h.patterns) p where h.id = (r ->> 'hand_id')::uuid;
    ck := case when (r ->> 'ok')::boolean and v_codes = 'hunyise,zimo' and (r ->> 'tai_pattern')::int = 5
               then '✅' else '🔴 ' || r::text || ' 牌型=' || coalesce(v_codes, '（無）') end;
    raise exception 'migi_step';
  exception when others then
    if sqlerrm <> 'migi_step' then ck := '🔴 出錯：' || sqlerrm; end if;
  end;
  v_msg := v_msg || E'\n③ 一般自摸（混一色）→ 照樣補自摸 1 台、共 5 台（正對照） ' || ck;

  -- ④ 門清自摸 → 照樣不補
  begin
    r := public.tbl_submit_hand_tx(v_tok, 'tsumo', null, '[{"code":"menqing_tsumo","n":1}]'::jsonb, null);
    select string_agg(p ->> 'code', ',' order by p ->> 'code') into v_codes
      from hands h, jsonb_array_elements(h.patterns) p where h.id = (r ->> 'hand_id')::uuid;
    ck := case when (r ->> 'ok')::boolean and v_codes = 'menqing_tsumo' and (r ->> 'tai_pattern')::int = 3
               then '✅' else '🔴 ' || r::text || ' 牌型=' || coalesce(v_codes, '（無）') end;
    raise exception 'migi_step';
  exception when others then
    if sqlerrm <> 'migi_step' then ck := '🔴 出錯：' || sqlerrm; end if;
  end;
  v_msg := v_msg || E'\n④ 門清自摸 → 照樣不補自摸、3 台（負對照） ' || ck;

  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.tianhu_test', ltrim(v_msg, E'\n'), true);
  else
    perform set_config('migi.tianhu_test', coalesce(nullif(ltrim(v_msg, E'\n'), ''), '') || E'\n🔴 中途出錯：' || sqlerrm, true);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.tianhu_test', true), ''), '🔴 沒有訊息') as "行為測試";
