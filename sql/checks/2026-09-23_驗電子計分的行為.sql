-- 2026-09-23 驗電子計分的行為（跑在 2026-09-23_電子計分_記分後端.sql 之後）
-- ⚠ 會在交易內造一桌、四台平板、四位測試會員，最後 raise 'migi_rollback' 整個退掉 —— 一列都不會留下。
-- ⚠ 訊息設在 exception 處理器裡（硬規則 3.9），不然會跟著被回滾。
-- 📌 期望值全部照《桌邊記分板設計》§4 的驗算表（級距 100/20）。

do $$
declare
  v_org uuid; v_store uuid; v_table uuid; v_stake uuid; v_sess uuid;
  v_mem uuid[]; v_tok text[]; v_dev uuid[]; v_pid uuid[];
  r jsonb; st jsonb; v_msg text := ''; v_hand uuid; i int; k int; v_dealer int; v_w int; v_ok boolean;
  ok text := '✅ '; bad text := '🔴 ';
begin
  -- ── 準備：一張現在沒有開桌的測試門市桌、100/20 級距、四位測試會員 ──
  select t.id, t.store_id, t.org_id into v_table, v_store, v_org
    from tables t join stores s on s.id = t.store_id
   where t.deleted_at is null and s.is_test
     and not exists (select 1 from table_sessions ts where ts.table_id = t.id and ts.status = 'open' and ts.deleted_at is null)
   order by t.label limit 1;
  if v_table is null then perform set_config('migi.t', '⚪ 找不到沒開桌的測試桌，這份測不了', false); return; end if;
  select id into v_stake from stake_levels where label = '100/20' and deleted_at is null limit 1;
  select array_agg(id order by created_at) into v_mem from (select id, created_at from members
   where deleted_at is null and is_test and org_id = v_org order by created_at limit 4) x;
  if coalesce(array_length(v_mem, 1), 0) < 4 or v_stake is null then
    perform set_config('migi.t', '⚪ 測試會員不足四位或找不到 100/20，這份測不了', false); return;
  end if;

  insert into table_sessions (org_id, store_id, table_id, mode, status, stake_level_id, game_type, flower)
  values (v_org, v_store, v_table, 'matched', 'open', v_stake, '台麻', '無花') returning id into v_sess;

  v_tok := array[repeat('a', 40), repeat('b', 40), repeat('c', 40), repeat('d', 40), repeat('e', 40)];
  v_dev := '{}'; v_pid := '{}';
  for i in 1..5 loop
    insert into table_devices (org_id, store_id, table_id, label, token_hash)
    values (v_org, v_store, v_table, 'T-' || i, public._tbl_hash(v_tok[i])) returning id into v_hand;
    v_dev := v_dev || v_hand;
  end loop;
  for i in 1..4 loop
    insert into session_players (org_id, session_id, member_id, join_type, status)
    values (v_org, v_sess, v_mem[i], 'opener', 'playing') returning id into v_hand;
    v_pid := v_pid || v_hand;
  end loop;

  -- ① 沒配對的憑證被拒絕
  begin
    perform public.tbl_state_tx(repeat('z', 40));
    v_msg := v_msg || bad || '① 假憑證竟然讀得到' || E'\n';
  exception when others then
    v_msg := v_msg || ok || '① 假憑證被拒絕（' || sqlerrm || '）' || E'\n';
  end;

  -- ② 「我是誰」：四台各選一個人；第五台選已被選走的人 ⇒ taken
  for i in 1..4 loop perform public.tbl_claim_seat_tx(v_tok[i], v_pid[i]); end loop;
  r := public.tbl_claim_seat_tx(v_tok[5], v_pid[1]);
  v_msg := v_msg || (case when r ->> 'reason' = 'taken' then ok else bad end) || '② 同一個人不能被兩台選：' || coalesce(r ->> 'reason', 'ok') || E'\n';

  -- ③ 座位：還沒定座位前送不出去
  r := public.tbl_submit_hand_tx(v_tok[2], 'draw');
  v_msg := v_msg || (case when r ->> 'reason' = 'no_seat' then ok else bad end) || '③ 還沒定座位不能記分：' || coalesce(r ->> 'reason', 'ok') || E'\n';

  -- ④ 三次點擊：莊家 A、下家 B、對家 C ⇒ D 自動是 4
  r := public.tbl_set_order_tx(v_tok[3], v_pid[1], v_pid[2], v_pid[3]);
  st := public.tbl_state_tx(v_tok[1]);
  v_msg := v_msg || (case when (r ->> 'ok')::boolean and (st ->> 'order_set')::boolean
                           and (st ->> 'my_seat')::int = 1 and (st -> 'round' ->> 'dealer_seat')::int = 1
                          then ok else bad end)
           || '④ 座位定好、莊家是 1：order_set=' || coalesce(st ->> 'order_set', '∅') || E'\n';

  -- ⑤ 閒家(2) 胡、莊家(1) 放槍，碰碰胡 4 ＋ 門清 1 ＝ 5 台 ⇒ 莊家付 100＋20×(5＋1)＝220
  r := public.tbl_submit_hand_tx(v_tok[2], 'ron', 1::smallint,
         '[{"code":"pengpenghu"},{"code":"menqing"}]'::jsonb);
  v_hand := (r ->> 'hand_id')::uuid;
  v_msg := v_msg || (case when (r -> 'score_delta' ->> '1')::int = -220 and (r -> 'score_delta' ->> '2')::int = 220
                          then ok else bad end)
           || '⑤ 閒家胡莊家放槍：' || coalesce((r -> 'score_delta')::text, r::text) || E'\n';
  -- 不是放槍的人不能確認
  r := public.tbl_confirm_hand_tx(v_tok[3], v_hand, true);
  v_msg := v_msg || (case when r ->> 'reason' = 'not_yours' then ok else bad end) || '⑤-1 旁人不能確認：' || coalesce(r ->> 'reason', 'ok') || E'\n';
  r := public.tbl_confirm_hand_tx(v_tok[1], v_hand, true);
  st := public.tbl_state_tx(v_tok[1]);
  v_msg := v_msg || (case when r ->> 'status' = 'confirmed' and (st -> 'round' ->> 'dealer_seat')::int = 2
                          then ok else bad end)
           || '⑤-2 確認後換莊：莊家 → ' || coalesce(st -> 'round' ->> 'dealer_seat', '∅') || E'\n';

  -- ⑥ 莊家(2) 自摸 碰碰胡 4（自動帶自摸 1）＝ 5 台 ⇒ 三家各 220，莊家 660；要三家都確認
  r := public.tbl_submit_hand_tx(v_tok[2], 'tsumo', null, '[{"code":"pengpenghu"}]'::jsonb);
  v_hand := (r ->> 'hand_id')::uuid;
  v_msg := v_msg || (case when (r -> 'score_delta' ->> '2')::int = 660 and (r ->> 'tai_pattern')::int = 5
                          then ok else bad end)
           || '⑥ 莊家自摸：' || coalesce((r -> 'score_delta')::text, r::text) || E'\n';
  perform public.tbl_confirm_hand_tx(v_tok[1], v_hand, true);
  perform public.tbl_confirm_hand_tx(v_tok[3], v_hand, true);
  st := public.tbl_state_tx(v_tok[2]);
  v_msg := v_msg || (case when st -> 'pending' ->> 'hand_id' = v_hand::text
                           and jsonb_array_length(st -> 'pending' -> 'confirmed_seats') = 2
                          then ok else bad end)
           || '⑥-1 兩家確認後仍在等第三家：' || coalesce((st -> 'pending' -> 'confirmed_seats')::text, '∅') || E'\n';
  perform public.tbl_confirm_hand_tx(v_tok[4], v_hand, true);
  st := public.tbl_state_tx(v_tok[2]);
  v_msg := v_msg || (case when (st -> 'round' ->> 'dealer_seat')::int = 2 and (st -> 'round' ->> 'renzhuang')::int = 1
                          then ok else bad end)
           || '⑥-2 莊家胡 ⇒ 連莊 1：' || coalesce(st -> 'round' ->> 'renzhuang', '∅') || E'\n';

  -- ⑦ 擋牆：放槍選自摸專屬的牌型／互斥／無花選花牌／贏家不能指定別人
  r := public.tbl_submit_hand_tx(v_tok[3], 'ron', 1::smallint, '[{"code":"zimo"}]'::jsonb);
  v_msg := v_msg || (case when r ->> 'reason' = 'wrong_result' then ok else bad end) || '⑦-1 放槍不能選自摸：' || coalesce(r ->> 'reason', 'ok') || E'\n';
  r := public.tbl_submit_hand_tx(v_tok[3], 'ron', 1::smallint, '[{"code":"pengpenghu"},{"code":"pinghu"}]'::jsonb);
  v_msg := v_msg || (case when r ->> 'reason' = 'conflicting_patterns' then ok else bad end) || '⑦-2 碰碰胡與平胡互斥：' || coalesce(r ->> 'message', 'ok') || E'\n';
  r := public.tbl_submit_hand_tx(v_tok[3], 'ron', 1::smallint, '[{"code":"zhenghua"}]'::jsonb);
  v_msg := v_msg || (case when r ->> 'reason' = 'no_flower' then ok else bad end) || '⑦-3 無花不能選正花：' || coalesce(r ->> 'reason', 'ok') || E'\n';
  r := public.tbl_submit_hand_tx(v_tok[3], 'ron', 3::smallint, '[]'::jsonb);
  v_msg := v_msg || (case when r ->> 'reason' = 'bad_deal_in' then ok else bad end) || '⑦-4 不能放槍給自己：' || coalesce(r ->> 'reason', 'ok') || E'\n';
  r := public.tbl_submit_hand_tx(v_tok[5], 'draw');
  v_msg := v_msg || (case when r ->> 'reason' = 'no_seat' then ok else bad end) || '⑦-5 沒選人的平板不能記分：' || coalesce(r ->> 'reason', 'ok') || E'\n';

  -- ⑧ 連莊 1、閒家(3) 自摸 5 台 ⇒ 閒家 1、4 各付 200；莊家 2 付 100＋20×(5＋1＋1)＝240；合計 640
  r := public.tbl_submit_hand_tx(v_tok[3], 'tsumo', null, '[{"code":"pengpenghu"}]'::jsonb);
  v_hand := (r ->> 'hand_id')::uuid;
  v_msg := v_msg || (case when (r -> 'score_delta' ->> '1')::int = -200 and (r -> 'score_delta' ->> '2')::int = -240
                           and (r -> 'score_delta' ->> '4')::int = -200 and (r -> 'score_delta' ->> '3')::int = 640
                          then ok else bad end)
           || '⑧ 連莊時閒家自摸，只有莊家多付：' || coalesce((r -> 'score_delta')::text, r::text) || E'\n';
  -- 同時只能有一把在等確認
  r := public.tbl_submit_hand_tx(v_tok[4], 'draw');
  v_msg := v_msg || (case when r ->> 'reason' = 'pending_exists' then ok else bad end) || '⑧-1 上一把沒確認不能記下一把：' || coalesce(r ->> 'reason', 'ok') || E'\n';
  -- 駁回
  r := public.tbl_confirm_hand_tx(v_tok[2], v_hand, false);
  st := public.tbl_state_tx(v_tok[3]);
  /* ⚠ 沒有待確認時 tbl_state_tx 回的是 JSON 的 null ⇒ `st -> 'pending'` 是一個
       「JSON null 值」不是 SQL 的 NULL，`is null` 永遠是假的（2026-09-23 第一次跑就紅在這裡，
       函式是對的、期望值寫錯了 —— 硬規則 3.56）。要用 jsonb_typeof 判斷。 */
  v_msg := v_msg || (case when r ->> 'status' = 'rejected' and (st -> 'last_reject' ->> 'rejected_seat')::int = 2
                           and coalesce(jsonb_typeof(st -> 'pending'), 'null') = 'null'
                           and (st -> 'round' ->> 'renzhuang')::int = 1
                          then ok else bad end)
           || '⑧-2 駁回後回到原狀、送出的人看得到被誰駁回：被 ' || coalesce(st -> 'last_reject' ->> 'rejected_seat', '∅')
           || ' 駁回／待確認 ' || coalesce(jsonb_typeof(st -> 'pending'), 'SQL null')
           || '／連莊 ' || coalesce(st -> 'round' ->> 'renzhuang', '∅') || E'\n';

  -- ⑨ 撤銷上一把（⑥ 那一把）⇒ 莊家回到 2、連莊回到 0；任何人都能按
  r := public.tbl_undo_last_tx(v_tok[4]);
  st := public.tbl_state_tx(v_tok[4]);
  v_msg := v_msg || (case when (r ->> 'ok')::boolean and (st -> 'round' ->> 'dealer_seat')::int = 2
                           and (st -> 'round' ->> 'renzhuang')::int = 0 and (st -> 'totals' ->> '2')::int = 220
                          then ok else bad end)
           || '⑨ 撤銷後分數與莊家都倒回去：總分 ' || coalesce((st -> 'totals')::text, '∅') || E'\n';

  -- ⑩ 每一把四家加總為 0（零和）
  select bool_and((select sum(e.value::int) from jsonb_each_text(h.score_delta) e) = 0) into v_ok
    from hands h where h.session_id = v_sess;
  v_msg := v_msg || (case when v_ok then ok else bad end) || '⑩ 每一把都是零和' || E'\n';

  -- ⑪ 流局：不用確認、莊家連莊
  r := public.tbl_submit_hand_tx(v_tok[1], 'draw');
  st := public.tbl_state_tx(v_tok[1]);
  v_msg := v_msg || (case when r ->> 'status' = 'confirmed' and (st -> 'round' ->> 'renzhuang')::int = 1
                          then ok else bad end)
           || '⑪ 流局直接生效並連莊：' || coalesce(st -> 'round' ->> 'renzhuang', '∅') || E'\n';

  -- ⑫ 一將打完：每把都讓莊家的下家胡、莊家放槍，直到結束（上限 30 把）
  -- ⚠ 不用迴圈變數 k 當計數：plpgsql 的 FOR 會另外宣告一個只活在迴圈裡的 k，
  --   迴圈外的 k 仍是 null，而「字串 || null」會吃掉整段訊息（硬規則 3.555）。
  k := 0;
  for i in 1..30 loop
    st := public.tbl_state_tx(v_tok[1]);
    exit when (st -> 'round' ->> 'status') = 'finished';
    k := k + 1;
    v_dealer := (st -> 'round' ->> 'dealer_seat')::int;
    v_w := (v_dealer % 4) + 1;
    r := public.tbl_submit_hand_tx(v_tok[v_w], 'ron', v_dealer::smallint, '[{"code":"pengpenghu"}]'::jsonb);
    perform public.tbl_confirm_hand_tx(v_tok[v_dealer], (r ->> 'hand_id')::uuid, true);
  end loop;
  st := public.tbl_state_tx(v_tok[1]);
  v_msg := v_msg || (case when (st -> 'round' ->> 'status') = 'finished' and (st -> 'round' ->> 'wind')::int = 4
                          then ok else bad end)
           || '⑫ 北風圈交完這一將就結束：又打了 ' || k || ' 把（預期 15），狀態 ' || coalesce(st -> 'round' ->> 'status', '∅') || E'\n';
  r := public.tbl_submit_hand_tx(v_tok[1], 'draw');
  v_msg := v_msg || (case when r ->> 'reason' = 'no_round' then ok else bad end) || '⑫-1 結束後不能再記：' || coalesce(r ->> 'reason', 'ok') || E'\n';

  -- ⑬ 開始下一將，再撤銷 ⇒ 空的第二將作廢、第一將重新打開
  r := public.tbl_start_round_tx(v_tok[2], 2::smallint);
  v_ok := (r ->> 'round_no')::int = 2;
  r := public.tbl_undo_last_tx(v_tok[2]);
  st := public.tbl_state_tx(v_tok[2]);
  v_msg := v_msg || (case when v_ok and (st -> 'round' ->> 'round_no')::int = 1 and (st -> 'round' ->> 'status') = 'playing'
                          then ok else bad end)
           || '⑬ 撤銷會把空的下一將作廢、上一將重開：現在第 ' || coalesce(st -> 'round' ->> 'round_no', '∅') || ' 將 ' || coalesce(st -> 'round' ->> 'status', '∅');

  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.t', v_msg, false);
  else
    perform set_config('migi.t', '🔴 中途失敗：' || sqlerrm || E'\n已經跑完的：\n' || coalesce(v_msg, ''), false);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有訊息') as "驗證";
