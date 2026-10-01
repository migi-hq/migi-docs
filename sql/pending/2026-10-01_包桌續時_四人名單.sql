/* ============================================================
   包桌續時：鎖定畫面直接列出桌上 4 位 · 2026-10-01（同日第二版）
   📄 使用者 2026-10-01：「含代付 2 份的那位 —— 這邊要直接顯示 4 位」

   在此之前 _pkg_time 只回「付款人」名單（payers：A 要補 2 份、D 要補 1 份），
   計分板只能寫「還沒補：A（2 份）」—— 被代付的 B、持暢打的 C 都不會出現。
   ⇒ 多回一份 players：桌上每一位客人各一列，依座位排
       status   owed     他那一份還沒補（付款人還沒補完）
                paid     付款人已經補完
                daypass  入座時持當日暢打，不用補
       payer_name  有人替他代付時，是誰（計分板寫「由 某某 代付」）
   ⚠ payers 照舊保留（POS 收款要用它：誰要付、付幾份）。
   ⚠ 改的是線上全文，錨點必須剛好出現一次；同一支函式的改動全部做完才重建一次（可重跑）。
   ============================================================ */

create or replace function pg_temp.patch_many(p_fn regprocedure, p_marker text, p_anchors text[], p_news text[])
returns text language plpgsql as $$
declare v_def text; v_n int; i int;
begin
  v_def := pg_get_functiondef(p_fn);
  if position(p_marker in v_def) > 0 then return p_fn::text || ' 已經改過'; end if;
  for i in 1 .. array_length(p_anchors, 1) loop
    v_n := (length(v_def) - length(replace(v_def, p_anchors[i], ''))) / length(p_anchors[i]);
    if v_n <> 1 then
      raise exception '% 的第 % 個錨點出現 % 次（要剛好 1 次），整份不執行：%', p_fn, i, v_n, left(p_anchors[i], 40);
    end if;
    v_def := replace(v_def, p_anchors[i], p_news[i]);
  end loop;
  execute v_def;
  return p_fn::text || ' 已改 ' || array_length(p_anchors, 1) || ' 處';
end $$;

select pg_temp.patch_many('public._pkg_time(uuid,boolean)'::regprocedure,
  'v_players',
  array[
    $a$v_phase text; v_payers jsonb;$a$,
    $a$  select min(r.started_at) into v_start$a$,
    $a$    'payers',       coalesce(v_payers, '[]'::jsonb),$a$],
  array[
    $b$v_phase text; v_payers jsonb; v_players jsonb;$b$,
    $b$  /* 🆕 2026-10-01（第二版）：桌上每一位客人各一列，依座位排（使用者：「這邊要直接顯示 4 位」）。
     狀態看「他那一份由誰付、那位付款人補完了沒」；已經封頂（24 小時那一檔）時一律算已補 */
  select jsonb_agg(jsonb_build_object(
           'seat',       sp.seat,
           'name',       coalesce(m.display_name, '會員'),
           'status',     case when coalesce(sp.fee_waived_reason, '') = 'daypass' then 'daypass'
                              when v_sku is null then 'paid'
                              when coalesce(pd.qty, 0) >= coalesce(sh.shares, 0) then 'paid'
                              else 'owed' end,
           'payer_name', case when sp.paid_by is not null then coalesce(pm.display_name, '會員') end)
         order by sp.seat nulls last, m.display_name)
    into v_players
    from session_players sp
    left join members m  on m.id  = sp.member_id
    left join members pm on pm.id = sp.paid_by
    left join public._pkg_shares(s.id) sh on sh.payer = coalesce(sp.paid_by, sp.member_id)
    left join lateral (
      select sum(oi.qty)::int as qty
        from orders o
        join order_items oi on oi.order_id = o.id
        join products p     on p.id = oi.product_id
       where o.session_id = s.id and o.status = 'paid'
         and o.member_id = coalesce(sp.paid_by, sp.member_id) and p.sku = v_sku) pd on true
   where sp.session_id = s.id and sp.member_id is not null and sp.left_at is null;

  select min(r.started_at) into v_start$b$,
    $b$    'players',      coalesce(v_players, '[]'::jsonb),
    'payers',       coalesce(v_payers, '[]'::jsonb),$b$]);

-- 驗證（只讀狀態、不寫東西，不用 raise —— 硬規則 1.8）
do $$
declare v_msg text := ''; v_d text; v_n int;
begin
  v_d := pg_get_functiondef('public._pkg_time(uuid,boolean)'::regprocedure);
  v_msg := v_msg || case when v_d ~ '''players'',\s+coalesce\(v_players' and v_d ~ 'into v_players' then '✅' else '🔴' end
        || ' ① 計時函式多回 players（四人名單）' || E'\n';
  v_msg := v_msg || case when v_d ~ '''payers'',\s+coalesce\(v_payers' then '✅' else '🔴' end
        || ' ② payers 照舊保留（POS 收款要用）' || E'\n';
  select count(*) into v_n from pg_proc where pronamespace = 'public'::regnamespace and proname = '_pkg_time';
  v_msg := v_msg || case when v_n = 1 then '✅' else '🔴' end || ' ③ 版本數 ' || v_n || '（應為 1）' || E'\n';
  v_msg := v_msg || case when not has_function_privilege('authenticated', 'public._pkg_time(uuid,boolean)', 'execute')
                          and not has_function_privilege('anon', 'public._pkg_time(uuid,boolean)', 'execute')
                     then '✅' else '🔴' end || ' ④ 計時函式仍然只有後端叫得到';
  perform set_config('migi.pkg4', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.pkg4', true), ''), '🔴 沒有驗證訊息') as "驗證";
