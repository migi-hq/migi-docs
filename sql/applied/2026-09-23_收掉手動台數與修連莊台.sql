/* ============================================================
   收掉「直接輸台數」＋ 修正連莊台（2026-09-23）

   ⚠ **一份 SQL 做兩件事**，因為兩件都在 `tbl_submit_hand_tx` 同一次重建裡 ——
     分開跑要把同一支函式重建兩次，那比合併更容易出錯。

   ── 🔴 二、連莊台算錯了（同日使用者指出）────────────
   線上寫的是 `v_extra := 1 + v_ren`，正確是 **`1 + 2 × 連莊`**（連 N 拉 N）：
   ```
   連莊 0 → 1 台      連莊 1 → 3 台（線上只算 2）
   連莊 2 → 5 台（線上只算 3）    連莊 3 → 7 台（線上只算 4）
   ```
   ⇒ **連莊越久少算越多**，而且它少算的是「每一家每一把」。
   🟢 今天零損害（`hands` 0 筆，一把都還沒記過），但上線後才發現就是要退錢。
   📌 掃過全庫：計分用到連莊的**只有這一處**，其餘（`_score_settle_tx` 的成就事件、
     `_tbl_round_state` 的累計、`tbl_state_tx` 的回傳）都只是記錄。

   ── 一、收掉「直接輸台數」───────────────────
   使用者拍板：「不能直接輸入台數，會影響日後數據統計與成就」。

   🔴 為什麼是今天做：**`hands` 目前 0 筆**，一把都還沒記過
     ⇒ 沒有歷史資料要處理、沒有部署順序問題。上線之後再收就完全是另一回事。
     （同待辦 22「趁還沒有東西呼叫它時改簽名是免費的」。）

   🔴 它輸掉的是什麼（為什麼這個決定是對的）：
     · 牌型收藏那 31 枚成就沒有東西可以解鎖
     · 「你最常胡什麼牌」「這間店最常出現什麼牌型」永遠答不出來
     · 而**那份資料事後補不回來**（硬規則 5.6：行為資料不可回溯）
     設計文件 §4 原本把它「藏一層」，現在是**完全不給**。

   ── 改四個地方 ───────────────────────────
   ① tbl_submit_hand_tx   改簽名 ⇒ DROP 重建 ⇒ **結尾要補 GRANT**（硬規則 2）
   ② tbl_state_tx         回傳拿掉 manual_tai（兩處，簽名不變）
   ③ _score_settle_tx     咪幾判斷 `not manual_tai and tai>=8` → `tai>=8`
   ④ hands.manual_tai     DROP COLUMN（boolean，0 筆資料）
      ⚠ 查證過零依賴：view 0／trigger 0／index 0／check 0

   ── 🔴 一個刻意「不加」的擋牆 ─────────────────
   收掉之後最明顯的下一步是加「胡牌一定要選至少一個牌型」。**不要加。**
   台麻放槍胡一手沒有任何台的雜牌是合法的（只收底），
   那一把的 `patterns = []` 是**忠實的紀錄**不是漏填。
   ⇒ 真正要防的是「用台數繞過牌型」，那個入口這份已經拆掉了。

   ⚠ 仍然沒有解決的缺口（等使用者核牌型主檔）：
     主檔 26 個牌型裡**有天胡沒有地胡、有海底撈月沒有河底撈魚**，
     也沒有混老頭／清老頭。沒有逃生門之後，第一個遇到地胡的客人會卡住。
     → 補主檔是另一份 SQL，那是店規不是程式問題。
   ============================================================ */

-- ══ ① tbl_submit_hand_tx：全文重建 ═════════════════════
-- 🔴 改三處以上（簽名／manual 分支／insert 欄位）⇒ 撈全文重建，不堆 DO 區塊。
drop function if exists public.tbl_submit_hand_tx(text, text, smallint, jsonb, integer);

create or replace function public.tbl_submit_hand_tx(
  p_token text,
  p_result text,
  p_deal_in_seat smallint default null::smallint,
  p_patterns jsonb default '[]'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  d public.table_devices; s public.table_sessions; v_me smallint; v_round public.session_rounds;
  v_st jsonb; v_dealer smallint; v_ren smallint; v_base int; v_unit int;
  v_pats jsonb := '[]'::jsonb; v_codes text[] := '{}'; e jsonb; p public.scoring_patterns;
  v_n int; v_tai int := 0; v_extra int;
  v_delta jsonb; v_win int := 0; v_pay int; v_payers smallint[]; i smallint;
  v_need smallint[] := '{}'; v_hand uuid; v_winner smallint;
begin
  d := public._tbl_device(p_token);
  select * into s from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  if coalesce(s.game_type, '台麻') <> '台麻' then
    return jsonb_build_object('ok', false, 'reason', 'unsupported_game_type', 'message', '記分板目前只支援台麻');
  end if;

  select seat into v_me from session_players
   where session_id = s.id and device_id = d.id and left_at is null;
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'no_seat', 'message', '請先選「我是誰」並定好座位');
  end if;

  select * into v_round from session_rounds where session_id = s.id and status = 'playing';
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_round', 'message', '這一將已經結束，請先開始下一將');
  end if;
  if exists (select 1 from hands where round_id = v_round.id and status = 'pending') then
    return jsonb_build_object('ok', false, 'reason', 'pending_exists', 'message', '上一把還在等確認');
  end if;

  if p_result not in ('tsumo', 'ron', 'draw') then
    return jsonb_build_object('ok', false, 'reason', 'bad_result', 'message', '胡牌方式不對');
  end if;

  v_st := public._tbl_round_state(v_round.id);
  v_dealer := (v_st ->> 'dealer_seat')::smallint;
  v_ren := (v_st ->> 'renzhuang')::smallint;

  select sl.base, sl.tai into v_base, v_unit
    from stake_levels sl where sl.id = s.stake_level_id;
  if v_base is null or v_unit is null then
    return jsonb_build_object('ok', false, 'reason', 'no_stake', 'message', '這桌沒有設定積分級距，請找店員');
  end if;

  -- ── 流局：不用確認，直接生效 ──
  if p_result = 'draw' then
    insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, renzhuang,
                       result, base, tai_unit, score_delta, status, need_confirm,
                       submitted_seat, submitted_device_id, confirmed_at)
    values (s.org_id, s.id, v_round.id, (v_st ->> 'hand_no')::int, (v_st ->> 'wind')::smallint,
            v_dealer, v_ren, 'draw', v_base, v_unit,
            '{"1":0,"2":0,"3":0,"4":0}'::jsonb, 'confirmed', '{}', v_me, d.id, now())
    returning id into v_hand;
    if (public._tbl_round_state(v_round.id) ->> 'finished')::boolean then
      update session_rounds set status = 'finished', finished_at = now() where id = v_round.id;
    end if;
    perform public._tbl_ping(s.id);
    return jsonb_build_object('ok', true, 'hand_id', v_hand, 'status', 'confirmed');
  end if;

  -- ── 胡：贏家一律是這台平板的座位 ──
  v_winner := v_me;
  if p_result = 'ron' then
    if p_deal_in_seat is null or p_deal_in_seat not between 1 and 4 or p_deal_in_seat = v_winner then
      return jsonb_build_object('ok', false, 'reason', 'bad_deal_in', 'message', '請選是誰放槍');
    end if;
  end if;

  /* 🔴 台數**只能**從牌型換算（2026-09-23 起沒有第二條路）。
     ⚠ 空陣列是合法的：放槍胡一手沒有任何台的雜牌只收底，那一把 patterns = [] 是事實。 */
  for e in select * from jsonb_array_elements(coalesce(p_patterns, '[]'::jsonb)) loop
    select * into p from scoring_patterns where code = e ->> 'code' and is_active;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'unknown_pattern', 'message', '沒有這個牌型', 'code', e ->> 'code');
    end if;
    if p.code = any(v_codes) then
      return jsonb_build_object('ok', false, 'reason', 'duplicate_pattern', 'message', p.label || ' 選了兩次');
    end if;
    v_n := coalesce(nullif(e ->> 'n', '')::int, 1);
    if v_n < 1 or v_n > p.max_count then
      return jsonb_build_object('ok', false, 'reason', 'bad_count', 'message', p.label || ' 最多 ' || p.max_count);
    end if;
    if p.needs_flower and coalesce(s.flower, '無花') <> '有花' then
      return jsonb_build_object('ok', false, 'reason', 'no_flower', 'message', '這桌是無花，不能選 ' || p.label);
    end if;
    if p.result_only is not null and p.result_only <> p_result then
      return jsonb_build_object('ok', false, 'reason', 'wrong_result',
        'message', p.label || (case when p.result_only = 'tsumo' then ' 只有自摸才有' else ' 只有放槍才有' end));
    end if;
    if p.dealer_only and v_winner <> v_dealer then
      return jsonb_build_object('ok', false, 'reason', 'dealer_only', 'message', p.label || ' 只有莊家才有');
    end if;
    v_codes := v_codes || p.code;
    v_pats := v_pats || jsonb_build_array(jsonb_build_object('code', p.code, 'n', v_n));
    v_tai := v_tai + p.tai * v_n;
  end loop;

  -- 自摸：沒選門清自摸就自動帶自摸 1 台
  if p_result = 'tsumo' and not ('zimo' = any(v_codes)) and not ('menqing_tsumo' = any(v_codes)) then
    select * into p from scoring_patterns where code = 'zimo' and is_active;
    if found then
      v_codes := v_codes || p.code;
      v_pats := v_pats || jsonb_build_array(jsonb_build_object('code', p.code, 'n', 1));
      v_tai := v_tai + p.tai;
    end if;
  end if;

  -- 互斥（雙向）
  if exists (select 1 from scoring_patterns a, unnest(a.conflicts) c
              where a.code = any(v_codes) and c = any(v_codes)) then
    return jsonb_build_object('ok', false, 'reason', 'conflicting_patterns',
      'message', '有兩個牌型不能同時算：' ||
        (select string_agg(a.label || '／' || b.label, '、')
           from scoring_patterns a, unnest(a.conflicts) c, scoring_patterns b
          where a.code = any(v_codes) and c = any(v_codes) and b.code = c));
  end if;

  /* 計分（MIGI ruleset，設計文件 §4）
     每個付款人付：底 ＋ 台 ×（牌型台數 ＋ 莊家附加台）
     🔴 莊家附加台 ＝ **1 ＋ 2 × 連莊**（連 N 拉 N，2026-09-23 使用者指定）。
       只有「胡牌者是莊家」或「付款人是莊家」時才加。
     ⚠ 改之前是 `1 + v_ren` —— 少算一半，而且**連莊越久少算越多**。 */
  v_extra := 1 + 2 * v_ren;
  if p_result = 'ron' then
    v_payers := array[p_deal_in_seat];
    v_need := array[p_deal_in_seat];
  else
    v_payers := array(select g::smallint from generate_series(1, 4) g where g <> v_winner);
    v_need := v_payers;
  end if;
  v_delta := '{"1":0,"2":0,"3":0,"4":0}'::jsonb;
  foreach i in array v_payers loop
    v_pay := v_base + v_unit * (v_tai + case when v_winner = v_dealer or i = v_dealer then v_extra else 0 end);
    v_delta := jsonb_set(v_delta, array[i::text], to_jsonb(-v_pay));
    v_win := v_win + v_pay;
  end loop;
  v_delta := jsonb_set(v_delta, array[v_winner::text], to_jsonb(v_win));

  insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, renzhuang,
                     result, winner_seat, deal_in_seat, patterns, tai_pattern,
                     base, tai_unit, score_delta, status, need_confirm, submitted_seat, submitted_device_id)
  values (s.org_id, s.id, v_round.id, (v_st ->> 'hand_no')::int, (v_st ->> 'wind')::smallint,
          v_dealer, v_ren, p_result, v_winner, case when p_result = 'ron' then p_deal_in_seat end,
          v_pats, v_tai, v_base, v_unit, v_delta, 'pending', v_need, v_me, d.id)
  returning id into v_hand;

  perform public._tbl_ping(s.id);
  return jsonb_build_object('ok', true, 'hand_id', v_hand, 'status', 'pending',
                            'tai_pattern', v_tai, 'score_delta', v_delta, 'need_confirm', to_jsonb(v_need));
end $function$;

/* 🔴 DROP 帶走 GRANT，一定要補回來（硬規則 2）。
   授權與改之前一致：anon／authenticated／service_role（平板用 anon key）。 */
grant execute on function public.tbl_submit_hand_tx(text, text, smallint, jsonb) to anon, authenticated, service_role;


-- ══ ② tbl_state_tx：回傳拿掉 manual_tai（兩處）═══════════
/* 🔴 這裡的 `raise` 是 **guard 不是驗證段**：改不到就整份回滾，
   正是硬規則 1.8 留給 raise 的那一種用途（「故意不要提交」）。 */
do $$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'tbl_state_tx';
  v_new := replace(v_def, ', ''manual_tai'', h.manual_tai', '');
  if v_new = v_def then
    raise exception '🔴 tbl_state_tx 沒有命中要取代的字串 —— 線上版本跟預期不同，整份回滾';
  end if;
  if v_new ~ 'manual_tai' then
    raise exception '🔴 tbl_state_tx 改完還有 manual_tai 殘留，整份回滾';
  end if;
  execute v_new;
end $$;


-- ══ ③ _score_settle_tx：咪幾判斷不再看 manual ══════════
/* 改之前：if not h.manual_tai and h.tai_pattern >= 8
   改之後：if h.tai_pattern >= 8
   ⚠ 語意不變 —— 收掉手動之後每一把的 tai_pattern 都來自牌型，那個條件恆真。 */
do $$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = '_score_settle_tx';
  v_new := replace(v_def, 'if not h.manual_tai and h.tai_pattern >= 8 then', 'if h.tai_pattern >= 8 then');
  if v_new = v_def then
    raise exception '🔴 _score_settle_tx 沒有命中要取代的字串 —— 線上版本跟預期不同，整份回滾';
  end if;
  if v_new ~ 'manual_tai' then
    raise exception '🔴 _score_settle_tx 改完還有 manual_tai 殘留，整份回滾';
  end if;
  execute v_new;
end $$;


-- ══ ④ 欄位：最後才刪（前面三支已經不引用它）═════════════
alter table public.hands drop column if exists manual_tai;


-- ══ 驗證段 ═══════════════════════════════════════════
/* 🔴 不可以用 raise 印訊息 —— 那會把上面的 DDL 一起回滾（硬規則 1.8）。
   一律 set_config ＋ 最後一支 SELECT 讀回來。 */
do $$
declare
  v_msg text := '';
  v_n int; v_args text; v_anon boolean; v_hits text;
begin
  -- ① 簽名：只剩一個版本，而且參數裡沒有 manual
  select count(*), max(pg_get_function_identity_arguments(p.oid)) into v_n, v_args
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'tbl_submit_hand_tx';
  v_msg := v_msg || case when v_n = 1 and v_args !~ 'manual' then '✅ ① ' else '🔴 ① ' end
        || 'tbl_submit_hand_tx 版本數 ' || v_n || '　參數：' || coalesce(v_args, '（查不到）');

  -- ② GRANT 補回來了嗎（DROP 會帶走，這一格是硬規則 2 的守衛）
  select exists (select 1 from aclexplode(p.proacl) a
                  where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
    into v_anon
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'tbl_submit_hand_tx';
  v_msg := v_msg || E'\n' || case when v_anon then '✅ ② ' else '🔴 ② ' end
        || 'anon 仍然叫得動 tbl_submit_hand_tx（平板用 anon key，沒補 GRANT 的話會當場壞掉）';

  -- ③ 欄位刪掉了
  select count(*) into v_n from information_schema.columns
   where table_schema = 'public' and table_name = 'hands' and column_name = 'manual_tai';
  v_msg := v_msg || E'\n' || case when v_n = 0 then '✅ ③ ' else '🔴 ③ ' end
        || 'hands.manual_tai 欄位數 ' || v_n || '（期望 0）';

  -- ④ 結構性掃描：全庫還有沒有函式提到它
  --    ⚠ 期望值 0 不是猜的：改之前查過正好 3 支（tbl_submit_hand_tx／tbl_state_tx／_score_settle_tx）
  select count(*), coalesce(string_agg(p.proname, '、'), '（沒有）') into v_n, v_hits
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and pg_get_functiondef(p.oid) ilike '%manual_tai%';
  v_msg := v_msg || E'\n' || case when v_n = 0 then '✅ ④ ' else '🔴 ④ ' end
        || '全庫還提到 manual_tai 的函式：' || v_n || ' 支　' || v_hits;

  -- ⑤ 正對照：咪幾判斷還在（只驗「拿掉了」的話，整段刪掉也會全綠）
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = '_score_settle_tx'
     and pg_get_functiondef(p.oid) ~ 'h\.tai_pattern >= 8';
  v_msg := v_msg || E'\n' || case when v_n = 1 then '✅ ⑤ ' else '🔴 ⑤ ' end
        || '_score_settle_tx 的咪幾判斷（tai_pattern >= 8）還在：' || v_n;

  -- ⑥ 正對照：tbl_state_tx 仍然回傳 tai_pattern（只是不回 manual_tai）
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'tbl_state_tx'
     and pg_get_functiondef(p.oid) ~ '''tai_pattern''';
  v_msg := v_msg || E'\n' || case when v_n = 1 then '✅ ⑥ ' else '🔴 ⑥ ' end
        || 'tbl_state_tx 仍然回傳 tai_pattern：' || v_n;

  -- ⑦ 正對照：牌型主檔沒有被波及
  select count(*) into v_n from scoring_patterns where is_active;
  v_msg := v_msg || E'\n' || case when v_n = 27 then '✅ ⑦ ' else '🔴 ⑦ ' end
        || 'scoring_patterns 啟用中 ' || v_n || ' 筆（期望 27 ＝ 畫面上的 26 ＋ 後端自動帶的自摸）';

  -- ⑧ 連莊台：新的算式在、舊的算式不在
  --    ⚠ 兩格都要驗 —— 只驗「新的在」的話，舊那行沒刪掉也會變綠
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'tbl_submit_hand_tx'
     and pg_get_functiondef(p.oid) ~ 'v_extra\s*:=\s*1\s*\+\s*2\s*\*\s*v_ren';
  v_msg := v_msg || E'\n' || case when v_n = 1 then '✅ ⑧ ' else '🔴 ⑧ ' end
        || '連莊台改成 1 ＋ 2×連莊：' || v_n;

  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'tbl_submit_hand_tx'
     and pg_get_functiondef(p.oid) ~ 'v_extra\s*:=\s*1\s*\+\s*v_ren\s*;';
  v_msg := v_msg || E'\n' || case when v_n = 0 then '✅ ⑨ ' else '🔴 ⑨ ' end
        || '舊的算式（1 ＋ 連莊）還在嗎：' || v_n || ' 支（期望 0）';

  perform set_config('migi.check', v_msg, true);
exception when others then
  perform set_config('migi.check', '🔴 驗證段自己炸了：' || sqlstate || ' ' || sqlerrm, true);
end $$;

select coalesce(nullif(current_setting('migi.check', true), ''), '🔴 沒有訊息') as "驗證";
