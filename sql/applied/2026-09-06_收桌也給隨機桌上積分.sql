/* ============================================================
   收桌時除了隨機名次，也給隨機的「桌上積分」（零和）
   2026-09-06 · MIGI 咪吉麻將 · 使用者指定

   ── 為什麼 ────────────────────────────────────────────
   「勝負」的定義已經拍板：**桌上最終積分的正負**（見 CLAUDE.md）。
   但**桌上積分在資料庫裡沒有欄位** —— `session_players.score_points`
   裝的是段位分，不是桌上積分。
   ⇒ 平均勝率／最長連勝／單場最多積分／積分走勢**全部沒有原料**。

   ── 做什麼 ────────────────────────────────────────────
   ① `session_players` 加 **`final_score`**（這一場的桌上最終積分）
   ② `placeholder_ranks_tx` 一併產生隨機值，**四家加起來必定為 0**

   ⚠ **欄位名沿用 M4 設計稿的 `final_score`**
     （`sql/_設計稿未落地/牌譜資料庫schema.sql:39`），不要發明第三個字。
     📌 M4 的 `game_players.final_score` 是**一將**的，這裡是**一場**的
       —— 同一個概念不同粒度，由表名區分。這是刻意的。

   ── 🔴 純娛樂不給積分 ─────────────────────────────────
   `stake_levels.is_hygiene = true`（純娛樂，`base=0` `tai=0`）的桌
   **本來就不計積分** ⇒ `final_score` 留 **null**。
   🔴 **null 不是 0** —— null 是「沒有這回事」，0 是「打平」。
     給純娛樂的桌塞一個數字，畫面上就會出現
     「純娛樂 · 第 1 名 · +1200」這種自相矛盾的東西。
   ⚠ 已知後果：今天的測試場次多數是純娛樂 ⇒ **看不到效果**。
     要看的話開一間有級距的房（10/10、50/20…）。**那是誠實的空，不是壞掉。**

   ── 數值怎麼來 ────────────────────────────────────────
   **不是四個獨立亂數**，而是從「那一將的名次」推：
   ```
   每一將：w := 台底 × (1..4 隨機)
           得分 := w × (第1名 +3 / 第2名 +1 / 第3名 −1 / 第4名 −3)
   ```
   · 每一將四家相加 = w × (3+1−1−3) = **0** ⇒ 零和是**構造出來的**，
     不是靠事後修正（事後補差額會讓某一家的數字看起來很怪）
   · 倍率逐將隨機 ⇒ 「某一將贏得少、某一將輸得多」會自然發生
     ⇒ 🎯 **「第 1 名但總積分是負的」這種真實情況會出現** ——
       那正是勝負與名次分家的意義（第 2 名照樣可能是負的）。

   ── 🔴 它跟名次一樣會自己消失 ─────────────────────────
   整段在 `placeholder_ranks_tx` 裡，而那支只在 `orgs.live_from`
   還沒到時作用 ⇒ **上線那天自動停止**，不需要有人記得移除。

   ⚠ 用詞：一律「桌上積分」，不可以寫成贏錢／輸錢（硬規則 6.5）。
   ⚠ `placeholder_ranks_tx` 簽名沒變 → `CREATE OR REPLACE`。
   ============================================================ */

/* ── ① 欄位 ────────────────────────────────────────────── */
alter table public.session_players
  add column if not exists final_score integer;

comment on column public.session_players.final_score is
  '這一場的桌上最終積分（四家相加為 0）。null = 這桌不計積分（純娛樂）或還沒有資料。 ⚠ 與 score_points 不同：那一欄裝的是段位分（M4 會正名為 rating_delta）。';

/* ── ② 隨機名次的同時，給隨機的桌上積分 ─────────────────── */
create or replace function public.placeholder_ranks_tx(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
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
end $fn$;

revoke execute on function public.placeholder_ranks_tx(uuid) from public;
revoke execute on function public.placeholder_ranks_tx(uuid) from anon, authenticated;
grant  execute on function public.placeholder_ranks_tx(uuid) to service_role;

/* ── 驗證 ────────────────────────────────────────────────
   🎯 樣本在交易內自己造（硬規則 3.57），最後整段回滾。
   ⚠ 訊息設在 exception 處理器裡（硬規則 3.9）。 */
do $v$
declare
  v_org uuid; v_store uuid; v_tbl uuid; v_stake uuid;
  v_sid uuid; v_sid2 uuid;
  v_ids uuid[];
  v_sum int; v_cnt int; v_pos int; v_null2 int;
  v_base int;
  v_msg text := '';
begin
  select o.id into v_org from orgs o limit 1;
  select s.id into v_store from stores s
   where s.org_id = v_org and exists (select 1 from tables t where t.store_id = s.id) limit 1;
  select array_agg(m.id) into v_ids
    from (select id from members where org_id = v_org and deleted_at is null and is_test
           order by created_at limit 4) m;
  /* 🎯 挑一個**真的有級距**的（不是純娛樂）—— 這一份的主角就是它。 */
  select sl.id, sl.base into v_stake, v_base
    from stake_levels sl
   where sl.org_id = v_org and sl.deleted_at is null
     and sl.is_hygiene = false and coalesce(sl.base,0) > 0
   order by sl.sort_order limit 1;

  select t.id into v_tbl from tables t
   where t.store_id = v_store and t.deleted_at is null
     and not exists (select 1 from table_sessions x
                      where x.table_id = t.id and x.status='open' and x.deleted_at is null)
   limit 1;

  if v_tbl is null or v_stake is null or coalesce(array_length(v_ids,1),0) <> 4 then
    v_msg := '🔴 ⓪ 造不出樣本（空桌 ' || coalesce(v_tbl::text,'無')
          || '／有級距的 stake ' || coalesce(v_stake::text,'無')
          || '／測試會員 ' || coalesce(array_length(v_ids,1),0) || '）'
          || ' —— 這份驗證等於沒跑，不要當成通過';
    raise exception 'migi_rollback';
  end if;

  -- A. 有級距的場次
  insert into table_sessions (org_id, store_id, table_id, mode, planned_rounds, status, stake_level_id)
  values (v_org, v_store, v_tbl, 'matched', 2, 'open', v_stake) returning id into v_sid;
  insert into session_players (org_id, session_id, member_id)
  select v_org, v_sid, unnest(v_ids);
  perform settle_session_tx(v_sid, null, false);

  select sum(final_score), count(final_score), count(*) filter (where final_score > 0)
    into v_sum, v_cnt, v_pos
    from session_players where session_id = v_sid;

  v_msg :=
       '⓪ 樣本級距台底 = ' || v_base
    || E'\n① 四家都有積分：' || coalesce(v_cnt::text,'0') || ' / 4'
    || case when v_cnt = 4 then '　✅' else '　🔴 沒寫進去' end
    /* ② 🔴 這一份的核心：**零和**。 */
    || E'\n② 四家相加 = ' || coalesce(v_sum::text,'null')
    || case when v_sum = 0 then '　✅ 零和'
            else '　🔴 不是 0 —— 有人多拿或少拿了' end
    /* ③ 🎯 正對照：**不可以全部是 0**。
         只驗②的話，一支「四家都寫 0」的實作也會過。 */
    || E'\n③ 有幾家是正的：' || coalesce(v_pos::text,'0')
    || case when v_pos between 1 and 3 then '　✅ 有輸有贏'
            else '　🔴 全 0 或全正 —— 那不是牌局' end;

  -- B. 🎯 正對照：純娛樂的桌不可以有積分
  select t.id into v_tbl from tables t
   where t.store_id = v_store and t.deleted_at is null
     and not exists (select 1 from table_sessions x
                      where x.table_id = t.id and x.status='open' and x.deleted_at is null)
   limit 1;
  insert into table_sessions (org_id, store_id, table_id, mode, planned_rounds, status, stake_level_id)
  values (v_org, v_store, v_tbl, 'matched', 2, 'open',
          (select id from stake_levels where org_id = v_org and is_hygiene and deleted_at is null limit 1))
  returning id into v_sid2;
  insert into session_players (org_id, session_id, member_id)
  select v_org, v_sid2, unnest(v_ids);
  perform settle_session_tx(v_sid2, null, false);

  select count(*) filter (where final_score is null), count(finish_rank)
    into v_null2, v_cnt
    from session_players where session_id = v_sid2;

  v_msg := v_msg
    || E'\n④ 純娛樂的桌：final_score 是 null 的有 ' || v_null2 || ' / 4'
    || case when v_null2 = 4 then '　✅ 沒有塞積分（null ≠ 0）'
            else '　🔴 純娛樂不該有積分' end
    /* ⑤ 🎯 正對照：純娛樂**仍然要有名次** ——
         只驗④的話，一支「純娛樂整個跳過」的實作也會過。 */
    || E'\n⑤ 純娛樂的桌有名次的：' || v_cnt || ' / 4'
    || case when v_cnt = 4 then '　✅ 名次照給（積分才是那桌沒有的東西）'
            else '　🔴 名次也被跳過了' end
    /* ⑥ 授權：anon 兩個來源都不可以有（它會改段位分與積分） */
    || E'\n⑥ 授權：'
    || (select case when not exists (select 1 from aclexplode(p.proacl) a
                                      where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE')
                    and not exists (select 1 from aclexplode(p.proacl) a
                                      where a.grantee=0 and a.privilege_type='EXECUTE')
                 then '✅ anon 沒有明確授權，PUBLIC 也沒有'
                 else '🔴 前端叫得動' end
          from pg_proc p
         where p.pronamespace='public'::regnamespace and p.proname='placeholder_ranks_tx');

  raise exception 'migi_rollback';

exception when others then
  perform set_config('migi.v',
    v_msg || case when sqlerrm = 'migi_rollback' then ''
                  else E'\n🔴 驗證途中拋錯：' || sqlerrm end, true);
end $v$;

select current_setting('migi.v', true) as 驗證結果;
