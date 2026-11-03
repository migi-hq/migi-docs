/* ============================================================
   報表每天的走勢補上「佔桌分鐘」與「來客」（2026-11-03，報表庫第一批）
   📄 docs/05-埋點分析/報表架構_世界級分法.md 第四節「第一批」

   報表拆成報表庫之後，每一份報表都有一張趨勢圖。原本 heat.by_day 只有場數與營收，
   畫不出上座率與來客的走勢。這一份只加欄位，原有的鍵一個都不動：
     heat.by_day[].minutes   那一天開打的場次的佔桌分鐘（跟上座率同一個定義）
     heat.by_day[].visits    那一天來店的人（入座過 ＋ 有付款訂單，一人一次）
     table.cap_day           範圍內所有門市「一天」的可用桌分鐘（前端算每天的上座率：minutes ÷ cap_day）

   做法跟上一份一樣：在線上函式原文上精準替換，兩處各只出現一次（2026-11-03 查過），對不上就整份不執行。
   ============================================================ */

do $$
declare d text;
begin
  d := pg_get_functiondef('public._ops_report_core(uuid, date, date, uuid)'::regprocedure);

  if regexp_count(d, '''sessions'', n, ''revenue'',') <> 1
     or regexp_count(d, '''active_tables'', \(') <> 1 then
    raise exception '報表函式的原文跟預期不同，沒有改（請先查線上版本）';
  end if;

  d := regexp_replace(d, '''sessions'', n, ''revenue'',',
         '''sessions'', n, '
         || '''minutes'', (select round(coalesce(sum(mins), 0)) from _ss where _ss.d = z.d), '
         || '''visits'', (select count(distinct _va.member_id) from _va where _va.d = z.d and _va.store_id in (select id from _rs)), '
         || '''revenue'',');
  d := regexp_replace(d, '''active_tables'', \(',
         '''cap_day'', (select round(coalesce(sum(cap_day), 0)) from _rs),' || E'\n    ' || '''active_tables'', (');

  execute d;
end $$;

-- ── 驗證（不 raise，硬規則 1.8）────────────────────────────────
do $$
declare v text := ''; j jsonb; v_uid uuid; n numeric; m numeric;
begin
  select auth_uid into v_uid from staff where role = 'hq' and auth_uid is not null and deleted_at is null limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  j := public.admin_ops_report_tx(public._biz_date(now()) - 29, public._biz_date(now()), null);

  -- ① 每天的佔桌分鐘加總 ＝ 整段的佔桌分鐘（同一份場次，只差四捨五入）
  select coalesce(sum((x->>'minutes')::numeric), 0) into n from jsonb_array_elements(j->'heat'->'by_day') x;
  m := (j->'table'->>'table_minutes')::numeric;
  v := v || case when jsonb_array_length(j->'heat'->'by_day') = 30 and abs(n - m) <= 30 then '✅' else '🔴' end
          || ' ① 每天的佔桌分鐘加總 ' || n || '，整段 ' || m || E'\n';

  -- ② 每天的來客加總 ＝ 整段的來客人次（一人一天一次，所以可以直接加）
  select coalesce(sum((x->>'visits')::int), 0) into n from jsonb_array_elements(j->'heat'->'by_day') x;
  v := v || case when n = (j->'profit'->>'visits')::int then '✅' else '🔴' end
          || ' ② 每天的來客加總 ' || n || '，整段來客 ' || (j->'profit'->>'visits') || ' 人次' || E'\n';

  -- ③ 一天的可用桌分鐘 × 天數 ＝ 整段的可用桌分鐘
  v := v || case when (j->'table'->>'cap_day')::numeric * 30 = (j->'table'->>'capacity_minutes')::numeric then '✅' else '⚠' end
          || ' ③ 一天可用 ' || (j->'table'->>'cap_day') || ' 分 × 30 天，整段 ' || (j->'table'->>'capacity_minutes') || E'\n';

  -- ④ 原有的鍵還在（負對照：沒有被替換壞）
  v := v || case when (j->>'ok')::boolean and j->'targets' is not null and j->'heat'->'grid' is not null
                      and (j->'heat'->'by_day'->0) ? 'revenue' and (j->'heat'->'by_day'->0) ? 'sessions' then '✅' else '🔴' end
          || ' ④ 原有的鍵都還在（場數 ' || (j->'table'->>'sessions') || '、營收 ' || (j->'table'->>'revenue') || '）';

  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.trend', v, true);
end $$;

select coalesce(nullif(current_setting('migi.trend', true), ''), '🔴 沒有訊息') as "驗證";
