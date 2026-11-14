/* ============================================================================
   2026-11-14 桌況回傳在座客人的名字（player_names）
   ----------------------------------------------------------------------------
   使用者定案（2026-11-14，整合 POS 版本第 6 題）：桌卡印名字，後端一起做。
   在此之前 list_tables_tx 對「正在打」的桌只回人數（player_count），
   名字只有「配桌預留、還沒有人到」那種桌有（queue_members，來自配桌名單）。

   這份只多回一個鍵：
     player_names  在座的人（沒離座的），照座位、再照入座時間排；被隱藏的會員本來就是「隱藏的會員」
   🔴 名字叫 player_names 不叫 players —— players 這個名字在別的函式是陣列、在這裡曾經是數字，
      混用已經炸過（CLAUDE.md 待辦 35），這支函式自己的註解也寫著「要回有哪些人就叫 player_names」。
   ⚠ POS 畫面還沒讀它（等整合版外觀定案），舊版 POS 看到多一個鍵不會有任何影響。

   做法：用字串取代只改兩處（在座人數那一段多算名字、回傳多一個鍵），其餘一字不動；
         找不到唯一一處就整份不跑。簽名不變，授權不會掉。
   ============================================================================ */

do $$
declare v_def text; v_new text;
  a1 text := 'select count(*)::int as n';
  b1 text := 'select count(*)::int as n,'
          || ' coalesce(jsonb_agg(m.display_name order by sp.seat nulls last, sp.joined_at), ''[]''::jsonb) as names';
  a2 text := '''player_count'', coalesce(pl.n, 0),';
  b2 text := '''player_count'', coalesce(pl.n, 0),'
          || ' ''player_names'', coalesce(pl.names, ''[]''::jsonb),   /* 🆕 2026-11-14 在座的人，桌卡印名字 */';
  a3 text := 'from session_players sp' || chr(13) || chr(10) || '       where sp.session_id = ts.id';
  b3 text := 'from session_players sp join members m on m.id = sp.member_id' || chr(13) || chr(10) || '       where sp.session_id = ts.id';
begin
  v_def := pg_get_functiondef('public.list_tables_tx(uuid,uuid)'::regprocedure);
  if (length(v_def) - length(replace(v_def, a1, ''))) / length(a1) <> 1
     or (length(v_def) - length(replace(v_def, a2, ''))) / length(a2) <> 1
     or (length(v_def) - length(replace(v_def, a3, ''))) / length(a3) <> 1 then
    raise exception 'list_tables_tx：要改的三處不是剛好各一處，整份不跑（線上版本跟預期不同）';
  end if;
  v_new := replace(replace(replace(v_def, a1, b1), a2, b2), a3, b3);
  execute v_new;
end $$;

/* ── 驗證（單一 SELECT，不 raise）──────────────────────────────────────────
   ③ 真的叫一次：用總部身分讀一間有桌的門市，看每一張桌都有 player_names、
     而且名字數 ＝ 人數（正在打的桌名字不會是空的）。 */
select
  (select case when count(*) = 1 then '✅' else '🔴' end || ' ① list_tables_tx 版本數 ' || count(*)
     from pg_proc where pronamespace = 'public'::regnamespace and proname = 'list_tables_tx') || E'\n' ||
  (select case when pg_get_functiondef(p.oid) like '%''player_names''%' then '✅ ② 回傳多了 player_names' else '🔴 ② 沒有 player_names' end
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'list_tables_tx') || E'\n' ||
  (select case when count(*) = 0 then '⚪ ③ 沒有桌可以讀'
               when count(*) filter (where t ? 'player_names'
                                       and jsonb_array_length(t->'player_names') = (t->>'player_count')::int) = count(*)
               then '✅ ③ 真的讀一次：' || count(*) || ' 張桌都有名字欄，名字數 ＝ 人數（正在打的 '
                    || count(*) filter (where (t->>'player_count')::int > 0) || ' 張）'
               else '🔴 ③ 名字數跟人數對不上' end
     from (select s.org_id, s.id from stores s
            where exists (select 1 from tables tb where tb.store_id = s.id and tb.deleted_at is null)
            order by (select count(*) from table_sessions x where x.store_id = s.id and x.status = 'open') desc
            limit 1) st,
          jsonb_array_elements(public.list_tables_tx(st.org_id, st.id)) t) || E'\n' ||
  (select case when has_function_privilege('authenticated', 'public.list_tables_tx(uuid,uuid)', 'execute')
                and not has_function_privilege('anon', 'public.list_tables_tx(uuid,uuid)', 'execute')
               then '✅' else '🔴' end || ' ④ 授權沒變（店員叫得到、沒登入叫不到）')
  as "驗證";
