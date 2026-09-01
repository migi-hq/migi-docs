/* ============================================================
   造測試戰績（成績頁看得到段位與走勢圖）　常駐工具 · MIGI
   ⚠ 清除用同一個資料夾的 `測試戰績_清.sql`。

   ── 🔴 這支是真的寫進正式資料庫 ──────────────────────
   沒有 staging（硬規則 5.7 明講不做），所以：
   · 只動**五個測試帳號**（全部 `is_test = true`），不碰任何真實客人
   · 三張場次用**固定的 UUID**（`d0000000-…-0001/2/3`）——
     清除腳本靠這三個 id 認回來，**不會誤刪別的東西**
   · 可以重複跑：再跑一次會先清掉自己上次造的

   ── 造出什麼 ────────────────────────────────────────
   三場 2 將的牌局，創辦人（測試01）三場都第 1：
   ```
   第 1 場（🎓 定位賽）  +30 × 2 =  60  →  銅牌熊 II
   第 2 場（低段）       +30 × 2 = 120  →  銅牌熊 II
   第 3 場（低段）       +30 × 2 = 180  →  銀牌熊 IV   ← 跨大階，小熊會換
   ```
   🎯 **三場是刻意的**：
   · 1 場 → Hero 有段位了，但走勢圖會說「**再打一場就看得到走勢**」
     （一個點不是一條線）
   · 3 場 → 走勢圖畫得出來，而且**跨過銅→銀的橫帶**，看得到升階那條線
   ⚠ 想只看一場的樣子：把下面的 `v_games` 改成 1。
   ⚠ 想看輸的樣子：把 `v_my_place` 改成 4（定位賽 +5×2=10 → 銅牌熊 III，
     第二場開始第 4 名扣 20 → 會掉回銅牌熊 IV 的下限 0）。
   ============================================================ */

do $$
declare
  ---- 🔧 可以改的兩個參數 ────────────────────────────
  v_games    int := 3;    -- 造幾場（1～3）
  v_my_place int := 1;    -- 創辦人的名次（1～4）
  ---------------------------------------------------
  v_org   uuid := '11111111-1111-1111-1111-111111111111';
  v_me    uuid := 'd73fdac2-d6b9-4b8a-bcff-b19c2786056f';  -- 測試01（創辦人）
  v_p2    uuid := '218378e1-fb6c-43fb-b642-99fdbf5c52b1';  -- 測試02
  v_p3    uuid := 'd0db928e-5a75-4535-90d4-93ede67790a8';  -- 測試03
  v_p4    uuid := '526aa8b9-cc93-4327-b878-6d21d399af8e';  -- 測試04
  v_sids  uuid[] := array['d0000000-0000-0000-0000-000000000001'::uuid,
                          'd0000000-0000-0000-0000-000000000002'::uuid,
                          'd0000000-0000-0000-0000-000000000003'::uuid];
  v_store uuid; v_tbl uuid; v_sid uuid; g int; v_others uuid[]; v_rest int[];
  v_row jsonb; r jsonb;
begin
  v_my_place := greatest(1, least(4, v_my_place));   -- 打錯數字不要炸，夾住就好
  select id into v_store from stores
   where org_id = v_org and name like '%高雄自由%' and deleted_at is null limit 1;
  if v_store is null then
    select id into v_store from stores where org_id = v_org and deleted_at is null limit 1;
  end if;
  select id into v_tbl from tables
   where org_id = v_org and store_id = v_store and deleted_at is null
   order by sort_order, label limit 1;
  if v_tbl is null then raise exception '這間門市沒有桌子，換一間'; end if;

  ---- 先清掉上次造的（讓這支可以重複跑）--------------
  delete from session_players where session_id = any(v_sids);
  delete from table_sessions   where id        = any(v_sids);

  for g in 1 .. greatest(1, least(3, v_games)) loop
    v_sid := v_sids[g];

    /* ⚠ 直接建成 `completed` —— `uq_sessions_open_table` 是部分索引
       （`where status='open'`），所以不會鎖住那張桌。
       ⚠ `ended_at` 一場往前推幾天，走勢圖才有先後順序（它依 `ended_at` 排）。 */
    insert into table_sessions (id, org_id, store_id, table_id, mode, status,
                                game_type, flower, planned_rounds,
                                activated_at, ended_at)
    values (v_sid, v_org, v_store, v_tbl, 'matched', 'completed',
            '台麻', '無花', 2,
            now() - ((4 - g) || ' days')::interval - interval '2 hours',
            now() - ((4 - g) || ' days')::interval);

    insert into session_players (org_id, session_id, member_id)
      select v_org, v_sid, x from unnest(array[v_me, v_p2, v_p3, v_p4]) x;

    /* 其餘三人依場次輪流，不要每一場都是同一個人墊底 */
    v_others := case g when 1 then array[v_p2, v_p3, v_p4]
                       when 2 then array[v_p3, v_p4, v_p2]
                       else        array[v_p4, v_p2, v_p3] end;

    /* 組出 2 將的名次陣列。⚠ 名次必須剛好是 1..4（不接受並列、跳號），
       否則 `apply_session_rounds_tx` 會回 `bad_ranks`。
       我固定在 `v_my_place`，其他三人依序補上剩下的名次。 */
    select array_agg(x order by x) into v_rest
      from unnest(array[1,2,3,4]) x where x <> v_my_place;

    v_row := jsonb_build_array(
      jsonb_build_object('member_id', v_me,        'finish_rank', v_my_place),
      jsonb_build_object('member_id', v_others[1], 'finish_rank', v_rest[1]),
      jsonb_build_object('member_id', v_others[2], 'finish_rank', v_rest[2]),
      jsonb_build_object('member_id', v_others[3], 'finish_rank', v_rest[3])
    );

    r := public.apply_session_rounds_tx(v_sid, jsonb_build_array(v_row, v_row));
    if (r->>'ok')::boolean is not true then
      raise exception '第 % 場結算失敗：%', g, r::text;
    end if;
  end loop;
end $$;

-- ── 結果（重新整理成績頁就看得到）──────────────────────
select m.display_name as 會員,
       m.rating       as 分數,
       coalesce(m.rank, '尚未定位') as 段位,
       m.rating_games as 打過幾將,
       (select count(*) from session_players sp
         where sp.member_id = m.id and sp.finish_rank is not null) as 已結算場次,
       (select string_agg(sp.rating_after::text, ' → ' order by s.ended_at)
          from session_players sp join table_sessions s on s.id = sp.session_id
         where sp.member_id = m.id and sp.rating_after is not null) as 走勢
  from members m
 where m.id in ('d73fdac2-d6b9-4b8a-bcff-b19c2786056f',
                '218378e1-fb6c-43fb-b642-99fdbf5c52b1',
                'd0db928e-5a75-4535-90d4-93ede67790a8',
                '526aa8b9-cc93-4327-b878-6d21d399af8e')
 order by m.rating desc;
