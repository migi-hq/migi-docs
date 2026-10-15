-- ════════════════════════════════════════════════════════════════════
-- 2026-10-15 配桌開放「1 將」，而且打完 1 將也算段位分（使用者）
--
-- 拍板（同日使用者回答四題）：
--   ① 1 將的檯費：**封測期間跟 2 將一樣收 100**（新商品 SVC-TBL-M1，之後在管理後台商品頁改價就立刻生效）
--   ② 新客人第一場只打 1 將：**那一將的定位賽加倍**（+60／+30／+20／+10）⇒ 第 4 名照樣 +10 升到銅牌熊 III
--      （原本「至少 2 將」就是為了保證這件事 —— 決策紀錄第二十三節）
--   ③ 約好 2、3 將卻只打完 1 將就收桌：**維持不算段位分**（10-01 拍板不動）；只有「本來就約 1 將」的打完才算
--   ④ 會員 App 自己開一桌、POS 現場開桌、配桌湊滿帶到桌，都要能是 1 將
--
-- 改的地方（每一處都是撈線上全文、只換指定那一段、檢查剛好出現一次再重建；任何一處對不上整份不提交）：
--   open_session_tx          配桌將數允許 1
--   calc_session_fee_tx      1 將 → SVC-TBL-M1
--   pos_seat_queue_tx        配桌房寫「1 將」帶到桌時看得懂
--   trg_session_rounds_auto_score  約 1 將的打完也自動結算
--   tbl_bust_decide_tx       爆卡提早結束時，約 1 將的也結算
--   _score_settle_tx         打完 1 將、而且本來就約 1 將 ⇒ 算段位分
--   apply_session_rounds_tx  同上，並且只打 1 將的定位賽加倍
--   _push_settle_fields      LINE 牌局結束卡片：約 1 將的不寫「未滿 2 將，不計段位分」
-- ════════════════════════════════════════════════════════════════════

-- ① 1 將的檯費（照抄 2 將那一筆，只改貨號、名稱；價格封測期間同 2 將）
insert into public.products (org_id, sku, name, category, unit_price, unit_cost, is_active, stock_qty, is_available,
                             revenue_type, subcategory, tracks_stock, is_system, discountable, spec)
select org_id, 'SVC-TBL-M1', '配桌檯費 · 1 將', category, unit_price, unit_cost, is_active, stock_qty, is_available,
       revenue_type, subcategory, tracks_stock, is_system, discountable, spec
  from public.products p
 where p.sku = 'SVC-TBL-M2' and p.deleted_at is null
   and not exists (select 1 from public.products x where x.org_id = p.org_id and x.sku = 'SVC-TBL-M1' and x.deleted_at is null);

-- ② 九處函式內文替換
do $$
declare
  c record; d text; n int;
begin
  for c in
    select * from (values
      ('public.open_session_tx', 'coalesce(p_planned_rounds, 0) not in (2, 3)', 'coalesce(p_planned_rounds, 0) not in (1, 2, 3)'),
      ('public.open_session_tx', '''配桌需指定 2 或 3 將''', '''配桌需指定 1、2 或 3 將'''),
      ('public.calc_session_fee_tx', '(case when v_s.planned_rounds = 2 then ''SVC-TBL-M2'' else ''SVC-TBL-M3'' end)',
                                     '(case v_s.planned_rounds when 1 then ''SVC-TBL-M1'' when 2 then ''SVC-TBL-M2'' else ''SVC-TBL-M3'' end)'),
      ('public.pos_seat_queue_tx', 'when q.rounds ilike ''%二%'' or q.rounds like ''%2%'' then 2',
                                   'when q.rounds ilike ''%二%'' or q.rounds like ''%2%'' then 2
                      when q.rounds ilike ''%一%'' or q.rounds like ''%1%'' then 1'),
      ('public.trg_session_rounds_auto_score', 'coalesce(v_planned, 0) >= 2', 'coalesce(v_planned, 0) >= 1'),
      ('public.trg_session_rounds_auto_score', '約定 2 將以上才自動算（1 將沒有段位分）', '約定的將數打完就自動算（2026-10-15 起約 1 將的也算段位分）'),
      ('public.tbl_bust_decide_tx', 'coalesce(s.planned_rounds, 0) >= 2', 'coalesce(s.planned_rounds, 0) >= 1'),
      ('public._score_settle_tx', 'if v_nfin >= 2 then',
                                  'if v_nfin >= 2 or (v_nfin = 1 and (select planned_rounds from table_sessions where id = p_session_id) = 1) then'),
      ('public.apply_session_rounds_tx', 'if v_rounds < 2 then',
                                         'if v_rounds < 2 and not (v_rounds = 1 and (select planned_rounds from table_sessions where id = p_session_id) = 1) then'),
      ('public.apply_session_rounds_tx', 'where band = v_band and place = v_ranks[i];',
                                         'where band = v_band and place = v_ranks[i];
      -- 只打 1 將的定位賽加倍（2026-10-15 使用者）：第 4 名照樣 +10，第一場一定升到銅牌熊 III
      if v_band = ''placement'' and v_rounds = 1 then v_pts := v_pts * 2; end if;'),
      ('public._push_settle_fields', 'case when v_done < 2 then ''未滿 2 將，不計段位分''',
                                     'case when v_done < 2 and coalesce(s.planned_rounds, 2) <> 1 then ''未滿 2 將，不計段位分'''),
      ('public._push_settle_fields', 'case when v_done >= 2 and sp.score_points',
                                     'case when (v_done >= 2 or s.planned_rounds = 1) and sp.score_points')
    ) as t(fn, old_txt, new_txt)
  loop
    d := pg_get_functiondef(c.fn::regproc);   -- 同名兩個版本的話這裡就會失敗（不會改錯那一支）
    n := (length(d) - length(replace(d, c.old_txt, ''))) / length(c.old_txt);
    if n <> 1 then
      raise exception '% 裡「%」出現 % 次（要剛好 1 次），整份不提交', c.fn, left(c.old_txt, 40), n;
    end if;
    execute replace(d, c.old_txt, c.new_txt);
  end loop;
end $$;

-- ════════════ 驗證（單一 SELECT，不 raise）════════════
select string_agg(x, E'\n' order by n) as "驗證" from (
  select 1 n, coalesce((select '✅ ① 1 將檯費：' || name || ' ' || unit_price || ' 元（2 將是 '
                             || (select unit_price from products where sku = 'SVC-TBL-M2' and deleted_at is null limit 1) || '）'
                          from products where sku = 'SVC-TBL-M1' and deleted_at is null limit 1), '🔴 ① 沒有 1 將檯費') x
  union all
  select 2, case when pg_get_functiondef('public.open_session_tx'::regproc) ~ 'not in \(1, 2, 3\)' then '✅ ② 開桌收 1 將' else '🔴 ② 開桌' end
  union all
  select 3, case when pg_get_functiondef('public.calc_session_fee_tx'::regproc) ~ 'when 1 then ''SVC-TBL-M1''' then '✅ ③ 檯費試算認得 1 將' else '🔴 ③ 檯費試算' end
  union all
  select 4, case when pg_get_functiondef('public.pos_seat_queue_tx'::regproc) ~ 'then 1' then '✅ ④ 配桌房 1 將帶得到桌' else '🔴 ④ 帶到桌' end
  union all
  select 5, case when pg_get_functiondef('public.trg_session_rounds_auto_score'::regproc) ~ '>= 1'
                  and pg_get_functiondef('public.tbl_bust_decide_tx'::regproc) ~ 'planned_rounds, 0\) >= 1'
              then '✅ ⑤ 打完／爆卡提早結束，約 1 將的也自動結算' else '🔴 ⑤ 自動結算' end
  union all
  select 6, case when pg_get_functiondef('public._score_settle_tx'::regproc) ~ 'v_nfin = 1 and'
                  and pg_get_functiondef('public.apply_session_rounds_tx'::regproc) ~ 'v_rounds = 1 and'
                  and pg_get_functiondef('public.apply_session_rounds_tx'::regproc) ~ 'v_pts := v_pts \* 2'
              then '✅ ⑥ 約 1 將打完算段位分、定位賽加倍' else '🔴 ⑥ 段位分' end
  union all
  select 7, case when pg_get_functiondef('public._push_settle_fields'::regproc) ~ 'planned_rounds, 2\) <> 1' then '✅ ⑦ LINE 卡片不對約 1 將的寫「未滿 2 將」' else '🔴 ⑦ LINE 卡片' end
  union all
  -- ⑧ 改過的函式各只有一個版本（execute 的是 create or replace，不會長出多載）
  select 8, case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
                        and proname in ('open_session_tx','calc_session_fee_tx','pos_seat_queue_tx','trg_session_rounds_auto_score',
                                        'tbl_bust_decide_tx','_score_settle_tx','apply_session_rounds_tx','_push_settle_fields')) = 8
              then '✅ ⑧ 八支函式各一個版本' else '🔴 ⑧ 函式版本數不對' end
) t;
