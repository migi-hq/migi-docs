-- ============================================================
-- 行為測試：賽季自動建下一季（_ensure_next_seasons）
-- 搭配 sql/applied/2026-10-10_賽季自動建下一季.sql。
--
-- 🔴 這份會在交易裡真的建賽季，最後故意 raise 'migi_rollback' 全部退回 —— 跑完線上不會多任何一季。
--   （硬規則 1.8：這份本來就不要留下東西，所以才可以 raise；訊息在 exception 處理器裡設，見硬規則 3.9）
--
-- ⓐ 用預設的「現在＋60 天」：今天（2026-10-10）不該建任何一季（最後一季 2027-06-30 才結束）
-- ⓑ 建到 2028-12-31 中午：應該剛好補出 2027H2、2028H1、2028H2 三季
-- ⓑ2 期限正好卡在 2029-01-01 00:00（2028 秋季賽結束那一刻）：要再多建 2029H1
-- ⓒ 三季的名字、台北時間起訖（7/1、1/1）都對，而且頭尾相接（全部賽季沒有任何空檔）
-- ⓓ 再叫一次同樣的期限：一季都不多建（不會重複）
-- ⓔ 正對照：「現在有沒有進行中的賽季」這個判斷，在 2027-07-01 那一刻（春季賽剛結束）
--      建季之前是「沒有」、建季之後是「2027H2」—— 證明建季真的把空檔補上
-- ============================================================

do $$
declare
  v_org uuid;
  v_r   jsonb;
  v_msg text := '';
  v_n   int;
  v_t   timestamptz := '2027-07-01 00:00:00+08';
  v_before text; v_after text;
begin
  select rs.org_id into v_org from rank_seasons rs
   where now() >= rs.starts_at and now() < rs.ends_at limit 1;
  if v_org is null then
    v_msg := '⚪ 沒有進行中的賽季，找不到樣本機構，整份測不了';
    raise exception 'migi_rollback';
  end if;

  -- ⓐ
  v_r := public._ensure_next_seasons(v_org);
  v_msg := v_msg || case when jsonb_array_length(v_r -> 'created') = 0
                         then '✅ ⓐ 預設期限今天不建任何一季'
                         else '🔴 ⓐ 今天就建了：' || (v_r -> 'created')::text end;

  -- ⓔ 的「之前」：先記下 2027-07-01 那一刻有沒有賽季
  select coalesce(max(code), '沒有') into v_before from rank_seasons
   where org_id = v_org and v_t >= starts_at and v_t < ends_at;

  -- ⓑ 期限放在 2028 秋季賽中間 ⇒ 剛好三季
  v_r := public._ensure_next_seasons(v_org, '2028-12-31 12:00:00+08');
  v_msg := v_msg || E'\n' || case when v_r -> 'created' = '["2027H2", "2028H1", "2028H2"]'::jsonb
                                  then '✅ ⓑ 期限 2028-12-31 中午：補出 2027H2、2028H1、2028H2'
                                  else '🔴 ⓑ 補出來的是 ' || (v_r -> 'created')::text end;

  -- ⓑ2 邊界：期限正好是 2028 秋季賽結束那一刻。結束那一刻已經不屬於那一季（區間是「含開始、不含結束」），
  --    函式的規則是「那一刻一定要有一季在進行」⇒ 要再多建 2029H1。
  --    （2026-10-10 第一次跑時期望值沒想到這一層，把正確行為判成紅的 —— 硬規則 3.56）
  v_r := public._ensure_next_seasons(v_org, '2029-01-01 00:00:00+08');
  v_msg := v_msg || E'\n' || case when v_r -> 'created' = '["2029H1"]'::jsonb
                                  then '✅ ⓑ2 期限正好卡在季末那一刻：再多建 2029H1（那一刻要有一季在進行）'
                                  else '🔴 ⓑ2 補出來的是 ' || (v_r -> 'created')::text end;

  -- ⓒ 名字與起訖
  select count(*) into v_n from rank_seasons
   where org_id = v_org
     and ((code = '2027H2' and label = '2027 段位秋季賽'
           and starts_at = '2027-07-01 00:00:00+08' and ends_at = '2028-01-01 00:00:00+08')
       or (code = '2028H1' and label = '2028 段位春季賽'
           and starts_at = '2028-01-01 00:00:00+08' and ends_at = '2028-07-01 00:00:00+08')
       or (code = '2028H2' and label = '2028 段位秋季賽'
           and starts_at = '2028-07-01 00:00:00+08' and ends_at = '2029-01-01 00:00:00+08'));
  v_msg := v_msg || E'\n' || case when v_n = 3 then '✅ ⓒ 三季的名字與台北時間起訖都對'
                                  else '🔴 ⓒ 只有 ' || v_n || ' 季對得上' end;

  -- ⓒ 頭尾相接
  select count(*) into v_n from (
    select starts_at, lag(ends_at) over (order by starts_at) as prev_end
      from rank_seasons where org_id = v_org) t
   where prev_end is not null and prev_end <> starts_at;
  v_msg := v_msg || E'\n' || case when v_n = 0 then '✅ ⓒ 全部賽季頭尾相接，沒有空檔'
                                  else '🔴 ⓒ 有 ' || v_n || ' 處空檔或重疊' end;

  -- ⓓ
  v_r := public._ensure_next_seasons(v_org, '2029-01-01 00:00:00+08');
  v_msg := v_msg || E'\n' || case when jsonb_array_length(v_r -> 'created') = 0
                                  then '✅ ⓓ 再叫一次不會重複建'
                                  else '🔴 ⓓ 又建了：' || (v_r -> 'created')::text end;

  -- ⓔ
  select coalesce(max(code), '沒有') into v_after from rank_seasons
   where org_id = v_org and v_t >= starts_at and v_t < ends_at;
  v_msg := v_msg || E'\n' || case when v_before = '沒有' and v_after = '2027H2'
                                  then '✅ ⓔ 2027-07-01 那一刻：建季前「沒有賽季」→ 建季後「2027H2」'
                                  else '🔴 ⓔ 建季前 ' || v_before || '／建季後 ' || v_after end;

  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.season_test', v_msg, true);
  else
    perform set_config('migi.season_test', v_msg || E'\n🔴 中途出錯：' || sqlerrm, true);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.season_test', true), ''), '🔴 沒有訊息') as "行為測試";
