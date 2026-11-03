/* ============================================================
   2026-11-03 · 行為測試：碎片帳本的觸發器（唯讀不了，會寫入，但整段回滾）
   先跑 sql/pending/2026-11-03_碎片改成帳本.sql，再跑這一份。
   在交易裡借一局真的牌來測，最後 raise 'migi_rollback' 整段退掉，一筆都不會留下（硬規則 1.8 的例外：故意不提交）

   ⓐ 撤銷一局 ⇒ 補記一筆負的，那個人的碎片少掉那一局的數
   ⓑ 再撤銷一次（狀態沒變）⇒ 不會收回第二次
   ⓒ 新的一局 pending → confirmed：花槓 ×2 ＋ 平胡 ⇒ 給 3 個（按幾次算幾個）
   ⓓ 新的一局直接以 confirmed 新增：平胡 ⇒ 給 1 個（新增時就入帳也要發）
   ⓔ 只有 1 台牌型（東南西北 ×3 ＋ 門清）⇒ 不給
   ⓕ 好友練習賽的局 ⇒ 不給
   ⓖ 帳本改不動（只加不改）
   ============================================================ */
do $$
declare
  h      hands%rowtype;
  v_m    uuid;
  v_q    int;
  v_b    int;
  v_a    int;
  v_n    int;
  v_id   uuid;
  v_mode text;
  v_msg  text := '';
begin
  -- 借一局：已入帳、有碎片、不是好友練習賽、那一將現在沒有等確認的局
  select x.* into h
    from hands x join table_sessions s on s.id = x.session_id
   where x.status = 'confirmed' and x.result in ('ron', 'tsumo')
     and public._hand_shards(x.patterns) > 0
     and s.deleted_at is null and s.status <> 'voided' and coalesce(s.mode, '') <> 'friendly'
     and not exists (select 1 from hands p where p.round_id = x.round_id and p.status = 'pending')
     and exists (select 1 from shard_grants g where g.idem_key = 'hand:' || x.id)
   order by x.confirmed_at desc
   limit 1;
  if h.id is null then
    v_msg := '⚪ 找不到可以借的局（沒有樣本，整份測不了）';
    raise exception 'migi_rollback';
  end if;
  select member_id into v_m from shard_grants where idem_key = 'hand:' || h.id;
  v_q := public._hand_shards(h.patterns);
  select mode into v_mode from table_sessions where id = h.session_id;

  -- ⓐ 撤銷
  select coalesce(sum(qty), 0) into v_b from shard_grants where member_id = v_m;
  update hands set status = 'undone', undone_at = now() where id = h.id;
  select coalesce(sum(qty), 0) into v_a from shard_grants where member_id = v_m;
  v_msg := v_msg || case when v_a = v_b - v_q
    then '✅ ⓐ 撤銷一局 ⇒ 收回 ' || v_q || ' 個（' || v_b || ' → ' || v_a || '）'
    else '🔴 ⓐ 撤銷後 ' || v_b || ' → ' || v_a || '，應該少 ' || v_q end;

  -- ⓑ 再撤銷一次
  update hands set status = 'undone' where id = h.id;
  select count(*) into v_n from shard_grants where idem_key like 'hand_undo:' || h.id;
  v_msg := v_msg || E'\n' || case when v_n = 1 then '✅ ⓑ 再撤銷一次不會收回第二次' else '🔴 ⓑ 收回了 ' || v_n || ' 次' end;

  -- ⓒ pending → confirmed：花槓 ×2 ＋ 平胡 ⇒ 3 個
  v_id := gen_random_uuid();
  insert into hands select (jsonb_populate_record(null::hands, to_jsonb(h) || jsonb_build_object(
    'id', v_id, 'hand_no', h.hand_no + 10000, 'status', 'pending', 'confirmed_at', null, 'undone_at', null,
    'patterns', '[{"n":2,"code":"huagang"},{"n":1,"code":"pinghu"}]'::jsonb))).*;
  update hands set status = 'confirmed', confirmed_at = now() where id = v_id;
  select coalesce(sum(qty), 0) into v_n from shard_grants where idem_key = 'hand:' || v_id and member_id = v_m;
  v_msg := v_msg || E'\n' || case when v_n = 3 then '✅ ⓒ 花槓 ×2 ＋ 平胡 ⇒ 給 3 個（給胡牌位置當下的人）' else '🔴 ⓒ 給了 ' || v_n || ' 個，應該 3 個' end;

  -- ⓓ 直接以 confirmed 新增：平胡 ⇒ 1 個
  v_id := gen_random_uuid();
  insert into hands select (jsonb_populate_record(null::hands, to_jsonb(h) || jsonb_build_object(
    'id', v_id, 'hand_no', h.hand_no + 20000, 'status', 'confirmed', 'confirmed_at', now(), 'undone_at', null,
    'patterns', '[{"n":1,"code":"pinghu"}]'::jsonb))).*;
  select coalesce(sum(qty), 0) into v_n from shard_grants where idem_key = 'hand:' || v_id;
  v_msg := v_msg || E'\n' || case when v_n = 1 then '✅ ⓓ 新增時就入帳 ⇒ 給 1 個' else '🔴 ⓓ 給了 ' || v_n || ' 個，應該 1 個' end;

  -- ⓔ 只有 1 台牌型 ⇒ 不給
  v_id := gen_random_uuid();
  insert into hands select (jsonb_populate_record(null::hands, to_jsonb(h) || jsonb_build_object(
    'id', v_id, 'hand_no', h.hand_no + 30000, 'status', 'confirmed', 'confirmed_at', now(), 'undone_at', null,
    'patterns', '[{"n":3,"code":"triplet_wind"},{"n":1,"code":"menqing"}]'::jsonb))).*;
  select count(*) into v_n from shard_grants where idem_key = 'hand:' || v_id;
  v_msg := v_msg || E'\n' || case when v_n = 0 then '✅ ⓔ 只有 1 台牌型（東南西北 ×3 ＋ 門清）⇒ 不給' else '🔴 ⓔ 1 台牌型也給了' end;

  -- ⓕ 好友練習賽 ⇒ 不給
  update table_sessions set mode = 'friendly' where id = h.session_id;
  v_id := gen_random_uuid();
  insert into hands select (jsonb_populate_record(null::hands, to_jsonb(h) || jsonb_build_object(
    'id', v_id, 'hand_no', h.hand_no + 40000, 'status', 'confirmed', 'confirmed_at', now(), 'undone_at', null,
    'patterns', '[{"n":1,"code":"pinghu"}]'::jsonb))).*;
  select count(*) into v_n from shard_grants where idem_key = 'hand:' || v_id;
  v_msg := v_msg || E'\n' || case when v_n = 0 then '✅ ⓕ 好友練習賽 ⇒ 不給（同一局在 ⓓ 一般牌局會給，正對照）' else '🔴 ⓕ 好友練習賽也給了' end;
  update table_sessions set mode = v_mode where id = h.session_id;

  -- ⓖ 帳本改不動
  begin
    update shard_grants set qty = qty where idem_key = 'hand:' || h.id;
    v_msg := v_msg || E'\n' || '🔴 ⓖ 帳本被改了（應該擋下）';
  exception when others then
    v_msg := v_msg || E'\n' || case when sqlstate = '55000' then '✅ ⓖ 帳本改不動（只加不改）' else '🔴 ⓖ 擋下了但原因不對：' || sqlerrm end;
  end;

  raise exception 'migi_rollback';
exception when others then
  perform set_config('migi.shard_test',
    v_msg || case when sqlerrm = 'migi_rollback' then E'\n（整段已回滾，一筆都沒留下）'
                  else E'\n🔴 中途出錯：' || sqlerrm end, true);
end $$;

select coalesce(nullif(current_setting('migi.shard_test', true), ''), '🔴 沒有訊息') as "行為測試";
