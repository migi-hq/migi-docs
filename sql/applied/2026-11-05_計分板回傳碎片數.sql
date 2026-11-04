/* ============================================================
   計分板回傳碎片數（2026-11-05 使用者：「做到記分板」）
   預覽定案：https://claude.ai/artifact/2ds8JGcEJUcJTJsz6v1JeN

   計分板要畫兩個地方：
   ① 胡牌那一台的「確認中」彈窗最下面「這局獲得 N 個碎片」
   ② 將結束卡、牌局結束卡「第 X 將你拿到 N 個碎片」

   _tbl_state_for_device 多回兩個數字，平板只畫、不自己算：
   · pending.shards  ＝ 這一局入帳後胡的人會拿幾個（叫既有的 _hand_shards，跟發碎片的觸發器同一份規則）
                       不是胡牌／自摸、或好友練習賽 ⇒ 0
   · my_shards       ＝ { "將號": 個數 }，這一台坐的那個人這一場每一將實際拿到幾個
                       直接加總碎片帳本 shard_grants（撤銷的局有一筆負的，會自己扣回）；0 個的將不列

   做法：撈線上全文，只換兩個錨點，其餘一字不改（CREATE OR REPLACE、簽名不變、不掉授權）。
   錨點找不到或不只一處 ⇒ 整份中止、什麼都不改（這是故意的 raise，不是驗證段）。
   ============================================================ */

do $$
declare
  v_def text := pg_get_functiondef('public._tbl_state_for_device'::regproc);
  v_a1  text := '''hand_id'', h.id, ''result'', h.result,';
  v_a2  text := '''rating_delta'', (select jsonb_object_agg';
begin
  if v_def like '%''my_shards''%' then
    raise exception '已經改過了（找到 my_shards），不要重跑';
  end if;
  if (length(v_def) - length(replace(v_def, v_a1, ''))) / length(v_a1) <> 1 then
    raise exception '錨點 ① 不是剛好一處，線上版本跟預期不同，先撈全文看';
  end if;
  if (length(v_def) - length(replace(v_def, v_a2, ''))) / length(v_a2) <> 1 then
    raise exception '錨點 ② 不是剛好一處，線上版本跟預期不同，先撈全文看';
  end if;

  -- ① 待確認那一局：這一局胡的人會拿幾個碎片
  v_def := replace(v_def, v_a1,
    '''hand_id'', h.id, ''shards'', case when h.result in (''ron'', ''tsumo'') and coalesce(s.mode, '''') <> ''friendly'''
    || ' then public._hand_shards(h.patterns) else 0 end, ''result'', h.result,');

  -- ② 這一台坐的那個人，這一場每一將拿到幾個（讀帳本，含撤銷扣回）
  v_def := replace(v_def, v_a2,
       '''my_shards'', (select coalesce(jsonb_object_agg(x.rn::text, x.q), ''{}''::jsonb)' || E'\n'
    || '                    from (select r.round_no as rn, sum(g.qty)::int as q' || E'\n'
    || '                            from public.shard_grants g' || E'\n'
    || '                            join public.hands h on h.id = g.ref_id' || E'\n'
    || '                            join public.session_rounds r on r.id = h.round_id' || E'\n'
    || '                           where h.session_id = s.id and g.reason in (''hand'', ''hand_undo'')' || E'\n'
    || '                             and g.member_id = (select sp.member_id from public.session_players sp where sp.id = v_my_player)' || E'\n'
    || '                           group by r.round_no having sum(g.qty) > 0) x),   -- 💎 碎片（2026-11-05）' || E'\n'
    || '    ' || v_a2);

  execute v_def;
end $$;

/* ── 驗證（單一 SELECT）──
   ⚠ 這裡看到的是交易內的狀態；跑完之後我會另外查一次線上（硬規則 1.8） */
select string_agg(項, E'\n' order by n) as "驗證" from (
  select 1 as n, case when (select count(*) from pg_proc where proname = '_tbl_state_for_device' and pronamespace = 'public'::regnamespace) = 1
                      then '✅ ① 只有一個版本' else '🔴 ① 版本數不是 1' end as 項
  union all
  select 2, case when pg_get_functiondef('public._tbl_state_for_device'::regproc) ~ '''shards'', case when h\.result in'
                 then '✅ ② 待確認那一局有 shards' else '🔴 ② 沒有 shards' end
  union all
  select 3, case when pg_get_functiondef('public._tbl_state_for_device'::regproc) ~ '''my_shards'', \(select'
                 then '✅ ③ 有 my_shards' else '🔴 ③ 沒有 my_shards' end
  union all
  select 4, case when pg_get_functiondef('public._tbl_state_for_device'::regproc) ~ '''rating_delta'', \(select jsonb_object_agg'
                  and pg_get_functiondef('public._tbl_state_for_device'::regproc) ~ '''practice_cfg'', public\._tbl_practice_cfg\(d, v_my_seat\)'
                 then '✅ ④ 原本的 rating_delta、practice_cfg 都還在' else '🔴 ④ 原本的鍵不見了' end
  union all
  /* 正對照：帳本裡有碎片的那幾場，用同一段加總算得出數字（證明 join 的路接得通，不是永遠空的） */
  select 5, coalesce((select '✅ ⑤ 帳本加總接得通：' || count(*) || ' 個（人、將）有碎片，例 ' || min(q) || '～' || max(q) || ' 個'
                        from (select g.member_id, h.session_id, r.round_no, sum(g.qty) q
                                from public.shard_grants g join public.hands h on h.id = g.ref_id
                                join public.session_rounds r on r.id = h.round_id
                               where g.reason in ('hand', 'hand_undo') group by 1, 2, 3 having sum(g.qty) > 0) z
                      having count(*) > 0), '⚪ ⑤ 帳本裡還沒有牌局發的碎片，這一格測不了')
  union all
  select 6, case when has_function_privilege('anon', 'public.tbl_state_tx(text)', 'EXECUTE')
                 then '✅ ⑥ 平板讀狀態的 tbl_state_tx 授權沒動' else '⚠ ⑥ tbl_state_tx 的 anon 授權不在（原本就這樣的話忽略）' end
) v;
