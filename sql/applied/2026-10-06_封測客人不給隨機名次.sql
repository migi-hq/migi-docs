/* ============================================================================
   封測客人不給隨機名次（2026-10-06）

   起點：使用者要找 4 位真客人封測（會員 App 只開配桌、成績、獎勵的頭像與成就）。

   🔴 問題：上線前（orgs.live_from 還沒設）收桌時，只要那桌**沒用計分板打完一將**，
     settle_session_tx 就會叫 placeholder_ranks_tx 塞一份**隨機名次與隨機桌上積分**
     ⇒ 段位分、名次、成就全部照「假」的跑，而且寫進去就是真的段位分。
     那支是給開發期測試帳號用的假資料，**不該落在真客人身上**。

   ✅ 改法：placeholder_ranks_tx 多一道閘門 —— 桌上四人只要有一位**不是測試帳號**，
     就什麼都不做（回 real_players）。
     ⇒ 真客人的桌：有用計分板 → 照真成績；沒打完一將 → 沒有名次（同上線後的規則）。
     ⇒ 四位都是測試帳號的桌：照舊塞隨機名次，開發流程不變。

   ⚠ 其餘一行都沒改（逐字取自線上 pg_get_functiondef，2026-10-06）。
   ⚠ CREATE OR REPLACE、簽名不變 ⇒ 不 DROP、授權不變。
   ⚠ 驗證段只有一支 SELECT，不用 raise（硬規則 1.8）。跑完我會另外查一次線上。
   ============================================================================ */

create or replace function public.placeholder_ranks_tx(p_session_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_org      uuid;
  v_rounds   int;
  v_n        int;
  v_live     timestamptz;
  v_unit     int;          -- 台底（純娛樂時為 null ⇒ 不給積分）
  v_w        int;
  v_payload  jsonb := '[]'::jsonb;
  v_ranks    jsonb;        -- 這一將的 [{member_id, finish_rank}]
  v_score    jsonb := '{}'::jsonb;   -- member_id → 桌上積分累計
  v_res      jsonb;
  r          record;
  i          int;
begin
  select ts.org_id, greatest(coalesce(ts.planned_rounds, 2), 2)
    into v_org, v_rounds
    from table_sessions ts
   where ts.id = p_session_id and ts.deleted_at is null;

  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found');
  end if;

  /* 🔴 自動失效的閘門：上線之後就不再產生任何假資料。 */
  select o.live_from into v_live from orgs o where o.id = v_org;
  if v_live is not null and v_live <= now() then
    return jsonb_build_object('ok', false, 'reason', 'already_live');
  end if;

  select count(*) into v_n
    from session_players sp where sp.session_id = p_session_id;
  if v_n <> 4 then
    return jsonb_build_object('ok', false, 'reason', 'need_four_players', 'n', v_n);
  end if;

  /* 🔴 封測（2026-10-06）：桌上有真客人就不塞假名次 ——
     隨機名次只給「四位都是測試帳號」的開發桌。真客人沒打完一將就是沒有名次。 */
  if exists (select 1 from session_players sp
               join members m on m.id = sp.member_id
              where sp.session_id = p_session_id
                and not coalesce(m.is_test, false)) then
    return jsonb_build_object('ok', false, 'reason', 'real_players');
  end if;

  /* 台底。⚠ 純娛樂（`is_hygiene`）與沒設級距的桌一律 null ——
     **不計積分的桌不可以有積分**，那會在畫面上自相矛盾。 */
  select case when sl.is_hygiene then null
              else nullif(coalesce(sl.base, 0), 0) end
    into v_unit
    from table_sessions ts
    left join stake_levels sl on sl.id = ts.stake_level_id
   where ts.id = p_session_id;

  for i in 1 .. v_rounds loop
    /* 這一將的名次：洗一次牌，拿到 1..4 的排列。 */
    select jsonb_agg(jsonb_build_object('member_id', x.member_id, 'finish_rank', x.rn))
      into v_ranks
      from (select sp.member_id, row_number() over (order by random()) as rn
              from session_players sp where sp.session_id = p_session_id) x;

    v_payload := v_payload || jsonb_build_array(v_ranks);

    /* 桌上積分：**由這一將的名次推**，不是另外抽四個亂數 ——
       獨立抽的話零和要事後修正，而修正過的那一家會很怪。
       ⚠ 倍率逐將隨機（1..4 倍台底）⇒ 「這將贏得少、那將輸得多」
         會自然發生，所以「第 1 名但總積分是負的」真的會出現。 */
    if v_unit is not null then
      v_w := v_unit * (1 + floor(random() * 4)::int);
      for r in select (e ->> 'member_id')::uuid as mid,
                      (e ->> 'finish_rank')::int as rk
                 from jsonb_array_elements(v_ranks) e
      loop
        v_score := jsonb_set(v_score, array[r.mid::text],
          to_jsonb(coalesce((v_score ->> r.mid::text)::int, 0)
                   + v_w * case r.rk when 1 then 3 when 2 then 1 when 3 then -1 else -3 end));
      end loop;
    end if;
  end loop;

  v_res := apply_session_rounds_tx(p_session_id, v_payload);

  /* 名次算失敗就不要寫積分 —— 兩者要嘛都有要嘛都沒有，
     不然會出現「有積分沒名次」的半套資料。 */
  if coalesce((v_res ->> 'ok')::boolean, false) and v_unit is not null then
    update session_players sp
       set final_score = (v_score ->> sp.member_id::text)::int
     where sp.session_id = p_session_id
       /* 🔴 **不要用 jsonb 的 `?` 運算子。** Supabase 的 SQL Editor
          （以及很多 PG client）把 `?` 當成**參數佔位符**，語句邊界會被
          弄亂 —— 2026-09-06 實際症狀是最後那句 `select ... as 驗證結果`
          被切成兩半，報 `syntax error at or near "驗證結果"`，
          而錯誤完全指不到真正的原因。
        ⚠ 語意相同：這個 jsonb 的值一定是整數，不會是 JSON null。 */
       and (v_score ->> sp.member_id::text) is not null;
  end if;

  return v_res;
end $function$;

/* ── 驗證（單一 SELECT）──────────────────────────────────────────
   ① 版本數 1（沒有長出多載）
   ② 新閘門真的在程式裡（比對 return 那一行，不比對註解）
   ③ 舊的三道閘門還在（上線、四人、找不到場次）—— 正對照，確認沒有整支換壞
   ④ 仍是 SECURITY DEFINER */
select concat_ws(E'\n',
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'placeholder_ranks_tx') = 1
       then '✅ ① 版本數 1' else '🔴 ① 版本數不是 1' end,
  case when (select pg_get_functiondef(p.oid) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'placeholder_ranks_tx')
            ~ 'return jsonb_build_object\(''ok'', false, ''reason'', ''real_players''\)'
       then '✅ ② 有「桌上有真客人就不塞」的閘門' else '🔴 ② 找不到新閘門' end,
  case when (select pg_get_functiondef(p.oid) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'placeholder_ranks_tx')
            ~ '''already_live''' and
            (select pg_get_functiondef(p.oid) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'placeholder_ranks_tx')
            ~ '''need_four_players''' and
            (select pg_get_functiondef(p.oid) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'placeholder_ranks_tx')
            ~ '''session_not_found'''
       then '✅ ③ 原本三道閘門都還在' else '🔴 ③ 原本的閘門不見了' end,
  case when (select prosecdef from pg_proc where pronamespace = 'public'::regnamespace and proname = 'placeholder_ranks_tx')
       then '✅ ④ 仍是 SECURITY DEFINER' else '🔴 ④ 變成 INVOKER 了' end
) as "驗證";
