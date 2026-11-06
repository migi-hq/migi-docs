/* ============================================================
   2026-11-06 · 驗 feed_bear_tx（餵小熊）的行為 —— 唯讀：交易內造樣本，最後整筆回滾
   先跑 sql/pending/2026-11-06_餵小熊接帳本.sql 再跑這份
   用測試02（LINE id TEST-02）當身分；發給它的點心、餵食、等級最後都會回滾，一筆都不留
   ============================================================ */
do $$
declare
  v_me  uuid := (select id from members where line_user_id = 'TEST-02' and deleted_at is null);
  v_org uuid;
  r     jsonb;
  v_msg text := '';
  v_have int;
begin
  begin
    select org_id into v_org from members where id = v_me;
    perform set_config('request.jwt.claims', '{"sub":"TEST-02","role":"authenticated"}', true);
    if public.current_member_id() is distinct from v_me then
      raise exception '前提不成立：用 TEST-02 認不出測試02';
    end if;

    -- 每一格前先把前提擺好：Lv1、0%，再發 12 片小熊餅乾
    update member_app_state set bear = coalesce(bear, '{}'::jsonb) || '{"lv":1,"grow":0}' where member_id = v_me;
    perform public.grant_snack_tx(v_org, v_me, 'cookie', 12, 'admin', null, 'test-feed-' || gen_random_uuid());
    v_have := (public.get_my_snacks_tx() ->> 'cookie')::int;

    -- ① 餵 1 片：成長 +10，帳本少 1
    r := public.feed_bear_tx('cookie', 1, 'test-k1');
    v_msg := v_msg || case when (r->>'ok')::boolean and (r->>'grow')::int = 10 and (r->>'lv')::int = 1 and (r->>'total')::int = v_have - 1
      then '✅ ① 餵 1 片：成長 0 → 10、餅乾 ' || v_have || ' → ' || (r->>'total') else '🔴 ① ' || r::text end || E'\n';

    -- ② 同一把鑰匙重送（網路重試）：不再扣、不再加
    r := public.feed_bear_tx('cookie', 1, 'test-k1');
    v_msg := v_msg || case when (r->>'ok')::boolean and not (r->>'spent')::boolean and (r->>'grow')::int = 10 and (r->>'total')::int = v_have - 1
      then '✅ ② 同一把鑰匙重送：沒有再扣也沒有再長（成長仍 10、餅乾仍 ' || (r->>'total') || '）' else '🔴 ② ' || r::text end || E'\n';

    -- ③ 一次餵 10 片：+100 ⇒ 升到 Lv2、剩 10%
    r := public.feed_bear_tx('cookie', 10, 'test-k2');
    v_msg := v_msg || case when (r->>'ok')::boolean and (r->>'lv')::int = 2 and (r->>'grow')::int = 10 and (r->>'lv_up')::int = 1
      then '✅ ③ 一次餵 10 片：升到 Lv2、成長 10%（升了 1 級）' else '🔴 ③ ' || r::text end || E'\n';

    -- ④ 點心不夠：擋下，等級與帳本都不動
    r := public.feed_bear_tx('cookie', 99, 'test-k3');
    v_msg := v_msg || case when not (r->>'ok')::boolean and r->>'reason' = 'insufficient'
                             and (select (bear->>'lv')::int from member_app_state where member_id = v_me) = 2
      then '✅ ④ 點心不夠：擋下（' || coalesce(r->>'message', '') || '），還是 Lv2' else '🔴 ④ ' || r::text end || E'\n';

    -- ⑤ 不認得的點心、數量 0：擋下
    r := public.feed_bear_tx('donut', 1, null);
    v_msg := v_msg || case when not (r->>'ok')::boolean and r->>'reason' = 'bad_args' then '✅ ⑤ 不認得的點心擋下' else '🔴 ⑤ ' || r::text end || E'\n';

    -- ⑥ save_app_state_tx 送 lv 99 改不動等級，但名字照存（正對照：不是整支壞掉）
    perform public.save_app_state_tx(v_org, v_me, '{"lv":99,"grow":99,"name":"測試熊"}'::jsonb, null);
    v_msg := v_msg || case when (select (bear->>'lv')::int = 2 and (bear->>'grow')::int = 10 and bear->>'name' = '測試熊' from member_app_state where member_id = v_me)
      then '✅ ⑥ 前端送 Lv99 改不動（仍 Lv2、10%），名字照存' else '🔴 ⑥ ' || (select bear::text from member_app_state where member_id = v_me) end || E'\n';

    -- ⑦ 沒登入：擋下
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    begin
      r := public.feed_bear_tx('cookie', 1, null);
      v_msg := v_msg || '🔴 ⑦ 沒登入也餵得了：' || r::text;
    exception when others then
      v_msg := v_msg || case when sqlstate = '28000' then '✅ ⑦ 沒登入擋下' else '🔴 ⑦ 錯誤不對：' || sqlerrm end;
    end;

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm = 'migi_rollback' then perform set_config('migi.feed', v_msg, true);
    else perform set_config('migi.feed', v_msg || E'\n🔴 跑到一半出錯：' || sqlerrm, true); end if;
  end;
end $$;
select coalesce(nullif(current_setting('migi.feed', true), ''), '🔴 沒有訊息') as "驗證";
