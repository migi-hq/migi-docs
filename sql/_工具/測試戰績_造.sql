/* ============================================================
   造測試戰績（成績頁看得到段位與走勢圖）　常駐工具 · MIGI
   ⚠ 清除用同一個資料夾的 `測試戰績_清.sql`。

   ── 🔴 2026-09-01 修過一次：不要寫死會員 id ──────────
   第一版把四個會員 id 直接抄自 CLAUDE.md 的
   「創辦人 = `d73fdac2…`」—— **那句話已經漂掉了**：
   ```
   d73fdac2…  測試測試測試測試測試測試  phone 0910000001  ← 測試01
   69016205…  山劍八舞澤               phone 0910768736  ← 🎯 創辦人在這裡
   ```
   結果那一版**造了三場給錯的人**，而畫面上什麼都沒變。
   🎯 教訓同硬規則 3：**文件不是線上鏡像，會員 id 更是**。
   → 現在只留一個參數，其餘三人**從資料庫撈**。

   ── 🔴 這支是真的寫進正式資料庫 ──────────────────────
   沒有 staging（硬規則 5.7 明講不做），所以：
   · **只挑 `is_test = true` 的帳號**，不可能碰到真實客人
   · 三張場次用**固定的 UUID**（`d0000000-…-0001/2/3`）——
     清除腳本靠這三個 id 認回來，**不會誤刪別的東西**
   · 可以重複跑：再跑一次會先清掉自己上次造的

   ── 造出什麼（v_my_place = 1 時）────────────────────
   ```
   第 1 場（🎓 定位賽）  +30 × 2 =  60  →  銅牌熊 II
   第 2 場（低段）       +30 × 2 = 120  →  銅牌熊 II
   第 3 場（低段）       +30 × 2 = 180  →  銀牌熊 IV   ← 跨大階，小熊會換
   ```
   🎯 **三場是刻意的**：
   · 1 場 → Hero 有段位了，但走勢圖會說「**再打一場就看得到走勢**」
   · 3 場 → 走勢圖畫得出來，而且**跨過銅→銀的橫帶**，看得到升階
   ⚠ 想看輸的樣子：`v_my_place` 改 4
     （定位賽 +5×2=10 → 銅牌熊 III；第二場開始第 4 名扣 20 → 被夾在 0）
   ============================================================ */

do $$
declare
  ---- 🔧 唯一要確認的參數：這是誰的帳號 ─────────────
  --    預設 = 綁了 LINE 的那個（App 登入的就是它）
  --    ⚠ 換人之前先用下面那句確認 id：
  --      select id, display_name, phone from members where is_test;
  v_me       uuid := '69016205-afde-4036-95a6-5893c9d0e5fe';  -- 山劍八舞澤
  v_games    int  := 3;    -- 造幾場（1～3）
  v_my_place int  := 1;    -- 我的名次（1～4）
  ---------------------------------------------------
  v_org   uuid := '11111111-1111-1111-1111-111111111111';
  v_sids  uuid[] := array['d0000000-0000-0000-0000-000000000001'::uuid,
                          'd0000000-0000-0000-0000-000000000002'::uuid,
                          'd0000000-0000-0000-0000-000000000003'::uuid];
  v_pool uuid[]; v_old uuid[]; v_reset uuid[];
  /* 🔴 2026-09-03 補：**每一場給不同的積分級距**。
     在此之前這支工具完全不寫 `stake_level_id` ⇒ 成績頁的
     「各積分級距勝率」只會出現一行「未設定」——
     `get_my_stats_tx` 那樣處理是對的（**場數對不起來比多一行更難查**），
     但那代表**這個功能永遠測不到真正要看的東西**。
   ⚠ 級距一樣從主檔撈不寫死（同對手池的理由）。不足三個就重複用，
     少於一個就留 null（那時「未設定」那條路正好被驗到）。 */
  v_stakes uuid[];
  v_store uuid; v_tbl uuid; v_sid uuid; g int;
  v_others uuid[]; v_rest int[]; v_row jsonb; r jsonb; v_name text;
begin
  v_my_place := greatest(1, least(4, v_my_place));   -- 打錯數字不要炸，夾住就好

  select display_name into v_name from members
   where id = v_me and org_id = v_org and deleted_at is null;
  if v_name is null then
    raise exception '找不到這個會員（%）—— 先跑 select id, display_name, phone from members where is_test;', v_me;
  end if;

  /* 🔴 **只挑測試帳號當對手。** 寫死 id 會漂（見檔頭），
     而 `is_test` 是資料庫自己的事實。
     ⚠ **`order by created_at, id` —— 第二個欄位不能省。**
       測試03 與測試04 是同一秒建立的，只用 `created_at` 排序
       **每次跑可能挑到不同的三個人**（2026-09-01 真的發生了：
       第一次是測試04、第二次變測試03）。 */
  select array_agg(id order by created_at, id) into v_pool
    from members
   where org_id = v_org and deleted_at is null and is_test and id <> v_me;
  if coalesce(array_length(v_pool, 1), 0) < 3 then
    raise exception '測試帳號不夠三個對手（只有 %）', coalesce(array_length(v_pool,1),0);
  end if;

  /* 積分級距：照主檔 `sort_order` 取前三個，每一場一個。
     ⚠ 不要 `order by random()` —— 重跑會得到不一樣的級距，
       而這支工具的重點之一就是**重跑要得到同一個結果**。 */
  select array_agg(id order by sort_order, id) into v_stakes
    from (select id, sort_order from stake_levels
           where org_id = v_org and deleted_at is null and is_active
           order by sort_order, id limit 3) z;

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
  /* 🔴 **2026-09-01 修：刪場次不夠，分數也要歸零。**
     第一版只刪 session，但 `members.rating` 留著 ⇒
     `apply_session_rounds_tx` 從**現值**繼續加：
     ```
     第一次   60 → 120 → 180
     第二次  240 → 300 → 360   ← 從 180 接著加
     ```
     檔頭寫「可以重複跑」是假的。 */
  select array_agg(distinct member_id) into v_old
    from session_players where session_id = any(v_sids);

  delete from session_players where session_id = any(v_sids);
  delete from table_sessions   where id        = any(v_sids);

  /* 把「上次造的那些人」與「這次要造的這些人」一起歸零。
     ⚠ 兩組都要：換了 `v_me` 或對手池變了的話，
       只歸零其中一組會留下一個分數回不去的帳號。
     🔴 **但只在「他沒有別的已結算場次」時才歸零** ——
       同 `測試戰績_清.sql` 的守則：硬歸零是不可逆的。 */
  v_reset := coalesce(v_old, '{}'::uuid[]) || array[v_me] || v_pool[1:3];
  update members m
     set rating = 0, rating_games = 0, rank = null
   where m.id = any(v_reset)
     and not exists (select 1 from session_players sp
                      where sp.member_id = m.id and sp.finish_rank is not null);

  for g in 1 .. greatest(1, least(3, v_games)) loop
    v_sid := v_sids[g];

    /* ⚠ 直接建成 `completed` —— `uq_sessions_open_table` 是部分索引
       （`where status='open'`），所以不會鎖住那張桌。
       ⚠ `ended_at` 一場往前推幾天，走勢圖才有先後（它依 `ended_at` 排）。 */
    insert into table_sessions (id, org_id, store_id, table_id, mode, status,
                                game_type, flower, planned_rounds,
                                stake_level_id,
                                activated_at, ended_at)
    values (v_sid, v_org, v_store, v_tbl, 'matched', 'completed',
            '台麻', '無花', 2,
            /* 每場一個不同級距 —— 沒有級距主檔時是 null（走「未設定」那條）。
               ⚠ 用取模而不是 `v_stakes[g]`：只有 1～2 個級距時也不會變成 null。 */
            case when coalesce(array_length(v_stakes,1),0) = 0 then null
                 else v_stakes[((g - 1) % array_length(v_stakes,1)) + 1] end,
            now() - ((4 - g) || ' days')::interval - interval '2 hours',
            now() - ((4 - g) || ' days')::interval);

    insert into session_players (org_id, session_id, member_id)
      select v_org, v_sid, x from unnest(array[v_me] || v_pool[1:3]) x;

    -- 其餘三人依場次輪流，不要每一場都是同一個人墊底
    v_others := case g when 1 then array[v_pool[1], v_pool[2], v_pool[3]]
                       when 2 then array[v_pool[2], v_pool[3], v_pool[1]]
                       else        array[v_pool[3], v_pool[1], v_pool[2]] end;

    /* ⚠ 名次必須剛好是 1..4（不接受並列、跳號），否則回 `bad_ranks`。 */
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

  raise notice '✅ 已幫「%」造了 % 場', v_name, greatest(1, least(3, v_games));
end $$;

-- ── 結果（重新整理成績頁就看得到）──────────────────────
/* 🔴 這裡也不寫死 id —— 第一版寫死一組，印出來的四個人
   **跟實際造的那四個不是同一組**，而數字看起來完全正常。

   ⚠ **印「所有測試帳號」不是只印參加的那四個**，與 `測試戰績_清.sql` 一致 ——
     這樣才看得出「**誰沒被動到**」。
     📌 2026-09-01 使用者問「為什麼造是 4 筆清是 5 筆」，就是因為
       兩支的範圍不一樣。同一件事的兩支工具，輸出形狀要一樣。 */
select case when p.member_id is not null then '✅ 這次有打' else '—' end as 參與,
       m.display_name as 會員,
       m.phone        as 手機,
       m.rating       as 分數,
       coalesce(m.rank, '尚未定位') as 段位,
       m.rating_games as 打過幾將,
       (select string_agg(sp.rating_after::text, ' → ' order by s.ended_at)
          from session_players sp join table_sessions s on s.id = sp.session_id
         where sp.member_id = m.id and sp.rating_after is not null) as 走勢
  from members m
  left join (select distinct member_id from session_players
              where session_id in ('d0000000-0000-0000-0000-000000000001',
                                   'd0000000-0000-0000-0000-000000000002',
                                   'd0000000-0000-0000-0000-000000000003')) p
    on p.member_id = m.id
 where m.org_id = '11111111-1111-1111-1111-111111111111'
   and m.deleted_at is null and m.is_test
 order by m.rating desc, m.created_at;
