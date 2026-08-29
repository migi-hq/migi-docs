/* ============================================================
   get_my_games_tx 的 players 補上四個頭像欄位
   2026-08-30

   ── 問題 ────────────────────────────────────────────
   成績頁的對局紀錄（`get_my_games_tx`）是**最後一支還沒補頭像的清單 RPC**。
   它的 `players` 只回 `nickname` / `rank` / `title`，沒有 `avatar_*`。

   🔴 症狀是「**畫出來但畫錯**」：前端的 `avatarSrc()` 拿不到 `avatar_source`
     就走最後那條 fallback（依 `rank` 回段位熊）——
     一個把頭像換成自己照片的客人，在對局紀錄裡還是一隻熊。
     **不報錯、不空白**，所以沒有人會回報。

   ✅ 前端**已經就緒**：`lib/game.jsx` 的 `SeatRow` 早就把整個 `p` 傳給
     `SeatAvatar`（2026-08-29 改的），所以後端補上就會自動顯示，前端不用動。

   ── 三個來源要四個欄位 ──────────────────────────────
   ```
   avatar_source = 'line'  → avatar_url
   avatar_source = 'photo' → avatar_photo_path
   avatar_source = 'bear'  → avatar_bear（null = 通用預設熊）
   ```

   ── 簽名沒變 ⇒ `CREATE OR REPLACE` ──────────────────
   不用 DROP、不會掉 GRANT（硬規則 2）。
   ⚠ 從 `pg_get_functiondef` 撈線上版做定點插入（硬規則 3）——
     這支只改一處，且 `'rank', mem.rank` 只出現一次，錨點沒有歧義。
   ⚠ 它是 `LANGUAGE sql` ＋ `STABLE`（不是 plpgsql），
     重建時那兩個屬性都要保留 —— 下面用 `pg_get_functiondef` 原樣改，
     不是手打，所以不會掉。
   ============================================================ */

do $$
declare
  v_old text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_old
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prokind = 'f' and p.proname = 'get_my_games_tx';
  if v_old is null then
    raise exception '找不到 get_my_games_tx';
  end if;

  /* 在 `'rank', mem.rank,` 後面插入四個頭像欄位。
     ⚠ 別名用 \1 帶出來，不要寫死 `mem.` —— 這支剛好是 mem，
       但同一套做法在 list_recent_players_tx 上是 mm，寫死會產生
       一個不存在的別名而 CREATE 直接失敗。 */
  v_new := regexp_replace(
    v_old,
    '''rank'',(\s*)([a-zA-Z_]+)\.rank,',
    '''rank'',\1\2.rank,' ||
    E'\n                 ''avatar_url'',        \\2.avatar_url,' ||
    E'\n                 ''avatar_source'',     \\2.avatar_source,' ||
    E'\n                 ''avatar_photo_path'', \\2.avatar_photo_path,' ||
    E'\n                 ''avatar_bear'',       \\2.avatar_bear,'
  );

  /* 🔴 guard：`regexp_replace` 找不到樣式時**不報錯，原樣回傳** ——
     那正是「跑完沒報錯但什麼都沒發生」的形狀。 */
  if v_new = v_old then
    raise exception '錨點沒對上，一個字都沒改';
  end if;
  if v_new not like '%''avatar_bear''%' or v_new not like '%''avatar_url''%' then
    raise exception '改完之後少了新欄位';
  end if;

  execute v_new;
end $$;


/* ============================================================
   驗證（單一 SELECT）

   🔴 **不能只看定義有沒有那個字串** —— 插進註解裡也會是「有」。
     要真的呼叫，而且要呼叫到**有資料**的那一條路徑（硬規則 3.55）。
   ⚠ 創辦人是新帳號、沒有已完成的場次，所以拿**有 completed 場次的**
     那個會員去問；真的一個都沒有時誠實說「沒驗到」，不要假裝過關。
   ============================================================ */
select 序, 項目, 內容 from (

  select 1 as 序, '① 定義裡有沒有那四個欄位' as 項目,
         (select 'url=' || case when d like '%''avatar_url''%' then '✅' else '🔴' end
              || '　source=' || case when d like '%''avatar_source''%' then '✅' else '🔴' end
              || '　photo=' || case when d like '%''avatar_photo_path''%' then '✅' else '🔴' end
              || '　bear=' || case when d like '%''avatar_bear''%' then '✅' else '🔴' end
            from (select pg_get_functiondef(p.oid) d from pg_proc p
                   where p.pronamespace='public'::regnamespace and p.proname='get_my_games_tx') t) as 內容

  union all
  select 2, '② 🎯 真的呼叫一次（players[0] 要有四個頭像欄位）',
         coalesce((
           select case when j is null then '🔴 這個人沒有對局紀錄'
                       when (select count(*) from jsonb_object_keys(j) k
                              where k in ('avatar_url','avatar_source','avatar_photo_path','avatar_bear')) = 4
                       then '✅ 四個都在　（players[0] 共 '
                            || (select count(*) from jsonb_object_keys(j))::text || ' 個 key）'
                       else '🔴 缺：' || coalesce((select string_agg(k,'、') from unnest(array[
                              'avatar_url','avatar_source','avatar_photo_path','avatar_bear']) k
                              where not j ? k),'(判讀不出)') end
             from (select get_my_games_tx('11111111-1111-1111-1111-111111111111', mid, 1)
                          -> 0 -> 'players' -> 0 as j
                     from (select sp.member_id as mid
                             from session_players sp
                             join table_sessions s on s.id = sp.session_id
                            where s.status='completed' and s.deleted_at is null
                            limit 1) x) t),
           '🔴 全庫沒有 completed 的場次 —— 這一格沒驗到')

  union all
  select 3, '③ 🎯 正對照：其他欄位一個都沒少',
         coalesce((
           select case when (select count(*) from unnest(array[
                        'member_id','nickname','rank','title','seat',
                        'finish_rank','score_points','is_me']) k where not j ? k) = 0
                       then '✅ 原本的 8 個都還在'
                       else '🔴 少了：' || (select string_agg(k,'、') from unnest(array[
                        'member_id','nickname','rank','title','seat',
                        'finish_rank','score_points','is_me']) k where not j ? k) end
             from (select get_my_games_tx('11111111-1111-1111-1111-111111111111', mid, 1)
                          -> 0 -> 'players' -> 0 as j
                     from (select sp.member_id as mid
                             from session_players sp
                             join table_sessions s on s.id = sp.session_id
                            where s.status='completed' and s.deleted_at is null
                            limit 1) x) t),
           '（沒驗到）')

  union all
  select 4, '④ 🎯 正對照：模式、揮發性與授權都沒被動到',
         (select proname || '　' || case when prosecdef then 'DEFINER' else '🔴 INVOKER' end
              || case when provolatile='s' then '／STABLE' else '　🔴 不是 STABLE' end
              || '　語言=' || (select lanname from pg_language where oid = prolang)
              || '　anon=' || case when has_function_privilege('anon', oid, 'execute') then '✅' else '🔴 無' end
            from pg_proc where pronamespace='public'::regnamespace and proname='get_my_games_tx')

) x order by 序;
