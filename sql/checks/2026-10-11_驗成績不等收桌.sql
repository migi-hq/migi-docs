-- ============================================================
-- 行為測試：成績不等收桌（2026-10-11）
-- 前提：先跑完 sql/pending/2026-10-11_成績不等收桌.sql
-- 🔴 交易內把一場「已算完成績、已收桌」的場次改回「還沒收桌」，看成績還算不算它；最後故意 raise 'migi_rollback' 全部回滾，
--   不會在資料庫留下任何東西（硬規則 1.8：這份本來就不要留東西，所以可以 raise；訊息寫在 exception 處理器裡）。
-- 🔴 改回 open 會撞 uq_sessions_open_table（一張桌只能有一場開著），而有局數的舊場次全在同一張桌、那張桌現在正開著
--   （第一次跑就是這樣找不到樣本）⇒ 交易內先把樣本搬到同店一張現在沒開的桌，再改回還沒收桌（硬規則 3.57）。
-- ============================================================
do $$
declare
  v_s   uuid; v_org uuid; v_m uuid; v_store uuid; v_tbl uuid;
  g0 int; g1 int; h0 int; h1 int; old_rule int;
  v_msg text := '';
begin
  select s.id, s.org_id, sp.member_id, s.store_id into v_s, v_org, v_m, v_store
    from table_sessions s
    join session_players sp on sp.session_id = s.id and sp.finish_rank is not null and sp.settled_at is not null
   where s.status = 'completed' and s.deleted_at is null
     and exists (select 1 from hands h where h.session_id = s.id and h.status = 'confirmed')
   order by sp.settled_at desc
   limit 1;
  if v_s is null then
    v_msg := '⚪ 找不到可以拿來測的場次（要已收桌、有名次、有局數）';
    raise exception 'migi_rollback';
  end if;
  select t.id into v_tbl from tables t
   where t.store_id = v_store
     and not exists (select 1 from table_sessions o where o.table_id = t.id and o.status = 'open' and o.deleted_at is null)
   limit 1;
  if v_tbl is null then
    v_msg := '⚪ 同店找不到現在空著的桌可以借';
    raise exception 'migi_rollback';
  end if;

  g0 := (public._member_stats_core(v_org, v_m) -> 'all' ->> 'games')::int;
  h0 := coalesce((select c.hands from public._member_hand_counts(v_org, null, array[v_m]) c), 0);

  -- 改回「還沒收桌」（成績已經算過，只是店員還沒按收桌）
  update table_sessions set table_id = v_tbl, status = 'open', ended_at = null where id = v_s;

  g1 := (public._member_stats_core(v_org, v_m) -> 'all' ->> 'games')::int;
  h1 := coalesce((select c.hands from public._member_hand_counts(v_org, null, array[v_m]) c), 0);

  -- 正對照：照舊規則（只算已收桌）數，應該少一場 —— 證明這個測試真的造出了差別
  select count(*) into old_rule
    from session_players sp join table_sessions s on s.id = sp.session_id
   where sp.member_id = v_m and sp.org_id = v_org and s.deleted_at is null and s.status = 'completed'
     and sp.finish_rank is not null and sp.settled_at is not null;

  v_msg := case when g1 = g0 then '✅ ① 場次改回還沒收桌，成績頁的場數照算（' || g0 || ' 場）'
                else '🔴 ① 場數從 ' || g0 || ' 變 ' || g1 end
        || E'\n' || case when h1 = h0 and h0 > 0 then '✅ ② 每一局的統計照算（' || h0 || ' 局）'
                         else '🔴 ② 局數從 ' || h0 || ' 變 ' || h1 end
        || E'\n' || case when old_rule = g0 - 1 then '✅ ③ 正對照：照舊規則只剩 ' || old_rule || ' 場（少了這一場）—— 測試確實造出了差別'
                         else '🔴 ③ 正對照不對：舊規則數到 ' || old_rule || '，預期 ' || (g0 - 1) end;
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.x', v_msg, true);
  else
    perform set_config('migi.x', '🔴 中途出錯：' || sqlstate || ' ' || sqlerrm || E'\n已跑完的：\n' || v_msg, true);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.x', true), ''), '🔴 沒有訊息') as "行為測試（應為 3 行 ✅，全部回滾）";
