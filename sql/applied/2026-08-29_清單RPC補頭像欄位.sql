/* ============================================================
   五支清單／個人 RPC 補齊頭像欄位（順便 expand 待辦 35）
   2026-08-29

   ── 問題 ────────────────────────────────────────────
   頭像有三個來源，前端的 `avatarSrc()` 需要**三個欄位**才畫得出來：
   ```
   avatar_source = 'line'  → avatar_url
   avatar_source = 'photo' → avatar_photo_path
   avatar_source = 'bear'  → avatar_bear（null = 通用預設熊）
   ```
   但清單 RPC 回傳的欄位不一致 —— 有的三個、有的只有一個：

   | 函式 | avatar_url | avatar_source | avatar_photo_path | avatar_bear |
   |---|---|---|---|---|
   | `list_buddies_tx` | ✅ | ✅ | ✅ | 🔴 缺 |
   | `get_my_active_queue_tx` | ✅ | ✅ | ✅ | 🔴 缺 |
   | `get_my_profile_tx` | ✅ | 🔴 缺 | 🔴 缺 | 🔴 缺 |
   | `list_blocks_tx` | ✅ | 🔴 缺 | 🔴 缺 | 🔴 缺 |

   🔴 **缺欄位的症狀是「畫出來但畫錯」**：前端拿不到 `avatar_source`
     就會走 `avatarSrc()` 最後那條 fallback（依 `rank` 回段位熊）——
     一個把頭像換成自己照片的客人，在牌咖清單裡還是一隻熊。
     **不會報錯，也不會空白**，所以沒有人會回報。

   ── 順便做待辦 35 的 expand ─────────────────────────
   `list_match_queues_tx` 的 `'players'` 是**數字**（`count(*)`），
   而 `get_my_active_queue_tx` / `get_my_games_tx` 的 `'players'` 是**陣列**。
   🔴 已經真的炸過：`(t.players || []).map is not a function` ×5（2026-08-22）——
     `|| []` 擋得住 null，擋不住「是數字」這種真值。

   ✅ `get_my_active_queue_tx` **已經同時回 `player_count`**（之前就補了）。
   → 這次把 `list_match_queues_tx` 也補上 `player_count`（**`players` 保留**），
     完成 expand。前端改讀新 key 之後，contract 再拿掉舊的。
   ⚠ 不要在這一份就拿掉 `players` —— 那會讓還沒部署的前端立刻壞掉。

   ── 五支簽名都沒變 ⇒ `CREATE OR REPLACE` ────────────
   不用 DROP、不會掉 GRANT（硬規則 2）。
   ⚠ 每一支都是從 `pg_get_functiondef` 撈線上版改的，不是拿 applied/ 當基準（硬規則 3）。
   ============================================================ */

-- ── ① get_my_profile_tx：補三個欄位 ─────────────────
create or replace function public.get_my_profile_tx(p_org_id uuid, p_member_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v jsonb;
begin
  select jsonb_build_object(
    'id', m.id, 'nickname', m.display_name,
    'rank', m.rank, 'title', m.title,
    'likes_count', m.likes_count, 'avatar_url', m.avatar_url,
    -- ★ 2026-08-29：頭像有三個來源，只回 avatar_url 的話
    --   個人檔案永遠畫段位熊（而且不會報錯）。
    'avatar_source', m.avatar_source,
    'avatar_photo_path', m.avatar_photo_path,
    'avatar_bear', m.avatar_bear,
    'tier', m.tier,
    'app_state', coalesce(s.bear, '{}'::jsonb),
    'titles_unlocked', coalesce(s.titles, '[]'::jsonb),
    'about', m.about,
    'sched', m.sched,
    'style', m.style,
    -- ★ 2026-08-26 新增。生日招待是已承諾的權益，
    --   而在這之前前端讀不到現值，填完看起來像沒存成功。
    'birthday', m.birthday, 'gender', m.gender,
    'see_score', m.see_score,
    'baby_tile', m.baby_tile,
    'home_store_id', m.home_store_id,
    'home_store_name', st.name
  ) into v
  from members m
  left join member_app_state s on s.member_id = m.id
  left join stores st on st.id = m.home_store_id
  where m.id = p_member_id and m.org_id = p_org_id and m.deleted_at is null;
  if v is null then raise exception '會員不存在'; end if;
  return v;
end $function$;

/* ⚠ 刻意**還是不回傳 `phone`**（待辦 36 的 PII 決定）——
   `p_member_id` 現在是前端傳的，多回一個可聯絡的個資等於擴大暴露面。
   要顯示真值，等待辦 14 的 JWT。 */


-- ── ② list_blocks_tx：補三個欄位 ────────────────────
create or replace function public.list_blocks_tx(p_org_id uuid, p_member uuid)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id, 'nickname', m.display_name, 'rank', m.rank,
      'avatar_url', m.avatar_url,
      'avatar_source', m.avatar_source,
      'avatar_photo_path', m.avatar_photo_path,
      'avatar_bear', m.avatar_bear,
      'blocked_at', b.created_at
    ) order by b.created_at desc)
    from member_blocks b
    join members m on m.id = b.blocked_id and m.deleted_at is null
    where b.org_id=p_org_id and b.blocker_id=p_member
  ), '[]'::jsonb);
end $function$;


-- ── ③ list_buddies_tx：補 avatar_bear ───────────────
create or replace function public.list_buddies_tx(p_org_id uuid, p_member uuid)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', b.buddy_id, 'nickname', m.display_name,
      'rank', m.rank, 'title', m.title, 'likes_count', m.likes_count,
      'avatar_url', m.avatar_url, 'co_play_count', b.co_play_count,
      'avatar_source', m.avatar_source, 'avatar_photo_path', m.avatar_photo_path,
      'avatar_bear', m.avatar_bear,
      'linked_at', b.linked_at
    ) order by b.linked_at desc)
    from mahjong_buddies b
    join members m on m.id = b.buddy_id and m.deleted_at is null
    where b.member_id = p_member and b.org_id = p_org_id and b.deleted_at is null
  ), '[]'::jsonb);
end $function$;


-- ── ④ get_my_active_queue_tx：補 avatar_bear ────────
create or replace function public.get_my_active_queue_tx(p_org_id uuid, p_member uuid)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_qid uuid;
begin
  select q.id into v_qid
    from match_queue_players qp
    join match_queues q on q.id = qp.queue_id
   where qp.member_id = p_member and qp.left_at is null
     and q.org_id = p_org_id and q.status in ('waiting','matched')
   order by qp.joined_at desc
   limit 1;
  if v_qid is null then return null; end if;
  return (
    select jsonb_build_object(
      'id', q.id, 'status', q.status, 'source', q.source, 'tags', q.tags,
      'store_id', q.store_id, 'stake_level_id', q.stake_level_id,
      'game_type', q.game_type, 'flower', q.flower, 'rounds', q.rounds, 'seats', q.seats,
      'play_at', q.play_at, 'opened_by', q.opened_by,
      'is_host', (q.opened_by = p_member),
      'players', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'member_id', m.id, 'nickname', m.display_name, 'rank', m.rank,
          'avatar_url', m.avatar_url, 'joined_at', qp2.joined_at,
          'avatar_source', m.avatar_source, 'avatar_photo_path', m.avatar_photo_path,
          'avatar_bear', m.avatar_bear
        ) order by qp2.joined_at), '[]'::jsonb)
        from match_queue_players qp2
        join members m on m.id = qp2.member_id
        where qp2.queue_id = q.id and qp2.left_at is null
      ),
      'player_count', (
        select count(*) from match_queue_players
         where queue_id = q.id and left_at is null
      ),
      /* ★ 本桌動態：每人一筆加入 + 有離開者加一筆離開。
         **只取最近 10 筆**，再依時間由舊到新排回來。
         舊版無條件全撈，開一天的房會累積十幾二十行把牌局資訊擠出畫面。 */
      'events', (
        select coalesce(jsonb_agg(ev.e order by ev.at_ts), '[]'::jsonb)
        from (
          select all_ev.e, all_ev.at_ts
          from (
            -- 加入事件
            select jsonb_build_object('type','join','nickname', m.display_name, 'at', qp3.joined_at) as e,
                   qp3.joined_at as at_ts
              from match_queue_players qp3 join members m on m.id = qp3.member_id
             where qp3.queue_id = q.id
            union all
            -- 離開事件（只取有 left_at 的）
            select jsonb_build_object('type','leave','nickname', m.display_name, 'at', qp3.left_at) as e,
                   qp3.left_at as at_ts
              from match_queue_players qp3 join members m on m.id = qp3.member_id
             where qp3.queue_id = q.id and qp3.left_at is not null
          ) all_ev
          order by all_ev.at_ts desc
          limit 10
        ) ev
      )
    )
    from match_queues q where q.id = v_qid
  );
end $function$;


-- ── ⑤ list_match_queues_tx：補 player_count（待辦 35 expand）──
create or replace function public.list_match_queues_tx(p_org_id uuid, p_member uuid, p_store uuid)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', q.id, 'store_id', q.store_id, 'stake_level_id', q.stake_level_id,
      'game_type', q.game_type, 'flower', q.flower, 'rounds', q.rounds, 'seats', q.seats,
      'play_at', q.play_at, 'prefs', q.prefs, 'source', q.source, 'tags', q.tags,
      'recurring_id', q.recurring_id, 'recurring_freq', q.recurring_freq,
      'opener', mo.display_name,
      /* 🔴 `players` 在這一支是**數字**，在另外兩支是**陣列** ——
         同一個 key 兩種形狀，已經真的炸過
         （`(t.players || []).map is not a function` ×5，2026-08-22）。
         ★ 2026-08-29 expand：補上 `player_count`，**`players` 先留著**。
         ⚠ 現在拿掉會讓還沒部署的前端立刻壞掉；
           等前端改讀 `player_count` 之後再 contract。 */
      'players', (select count(*) from match_queue_players qp where qp.queue_id=q.id and qp.left_at is null),
      'player_count', (select count(*) from match_queue_players qp where qp.queue_id=q.id and qp.left_at is null)
    ) order by (q.source='pos') desc, (q.source='recurring') desc, q.play_at asc)
    from match_queues q
    left join members mo on mo.id = q.opened_by
    where q.org_id=p_org_id and q.store_id=p_store and q.status='waiting'
      and (q.expires_at is null or q.expires_at > now())
      and (q.open_at is null or q.open_at <= now())
      and not exists (
        select 1 from match_queue_players qp
        where qp.queue_id=q.id and qp.left_at is null
          and _blocked_between(p_org_id, p_member, qp.member_id))
  ), '[]'::jsonb);
end $function$;


/* ============================================================
   驗證（單一 SELECT）

   🔴 **不能只驗「函式建起來了」**（硬規則 7）。而且這幾支的回傳是
     清單，而**現在 0 封鎖、0 牌咖、房裡 0 人** ——
     直接呼叫全部回空陣列，看起來一切正常而且什麼都沒驗到（硬規則 3.55）。

   → 所以在交易內**造出正對照資料**（封鎖一筆、牌咖一筆、把創辦人放進
     一個既有的 waiting 房），呼叫每一支、把**實際回傳的 key 列出來**，
     然後整段回滾。

   ⚠ 訊息設在 exception 處理器裡（硬規則 3.9）——
     `set_config(..., true)` 寫在 raise 之前會跟著被回滾，最後印出空白。
     PL/pgSQL 變數不受回滾影響，所以先存進變數再在處理器裡吐出來。
   ⚠ 測試的 raise 用 `BEGIN … EXCEPTION` 的隱含 savepoint 接住 ——
     拋出去會把上面整份 DDL 一起回滾掉（Supabase SQL Editor 是單一交易）。
   ============================================================ */
do $$
declare
  v_org  uuid := '11111111-1111-1111-1111-111111111111';
  v_me   uuid := '69016205-afde-4036-95a6-5893c9d0e5fe';   -- 創辦人 Jim
  v_他   uuid := '218378e1-fb6c-43fb-b642-99fdbf5c52b1';   -- 測試02
  v_q    uuid;
  v_msg  text := '';
  j      jsonb;
  ks     text;
  WANT   text[] := array['avatar_url','avatar_source','avatar_photo_path','avatar_bear'];
begin
  begin
    -- 造正對照資料
    insert into member_blocks (org_id, blocker_id, blocked_id) values (v_org, v_me, v_他);
    insert into mahjong_buddies (org_id, member_id, buddy_id, origin)
      values (v_org, v_me, v_他, 'pre_existing');
    select id into v_q from match_queues
      where org_id = v_org and status = 'waiting' order by created_at desc limit 1;
    insert into match_queue_players (org_id, queue_id, member_id) values (v_org, v_q, v_me);

    -- ① get_my_profile_tx
    j := get_my_profile_tx(v_org, v_me);
    select string_agg(k, '') into ks from jsonb_object_keys(j) k where k = any(WANT);
    v_msg := '① get_my_profile_tx　'
          || case when (select count(*) from jsonb_object_keys(j) k where k = any(WANT)) = 4
                  then '✅ 四個頭像欄位都在' else '🔴 只有：' || coalesce(ks,'(無)') end
          || '　（總欄位 ' || (select count(*) from jsonb_object_keys(j))::text || ' 個）';

    -- ② list_blocks_tx
    j := (get_my_profile_tx(v_org, v_me)); -- 佔位避免未使用告警
    j := list_blocks_tx(v_org, v_me) -> 0;
    v_msg := v_msg || E'\n② list_blocks_tx　　'
          || case when j is null then '🔴 回空的 —— 正對照沒生效'
                  when (select count(*) from jsonb_object_keys(j) k where k = any(WANT)) = 4
                  then '✅ 四個頭像欄位都在'
                  else '🔴 缺欄位，實際有：' || (select string_agg(k, '、') from jsonb_object_keys(j) k) end;

    -- ③ list_buddies_tx
    j := list_buddies_tx(v_org, v_me) -> 0;
    v_msg := v_msg || E'\n③ list_buddies_tx　'
          || case when j is null then '🔴 回空的 —— 正對照沒生效'
                  when (select count(*) from jsonb_object_keys(j) k where k = any(WANT)) = 4
                  then '✅ 四個頭像欄位都在'
                  else '🔴 缺欄位，實際有：' || (select string_agg(k, '、') from jsonb_object_keys(j) k) end;

    -- ④ get_my_active_queue_tx（players 陣列裡的第一個人）
    j := get_my_active_queue_tx(v_org, v_me);
    v_msg := v_msg || E'\n④ get_my_active_queue_tx　'
          || case when j is null then '🔴 回 null —— 正對照沒生效'
                  when (select count(*) from jsonb_object_keys(j->'players'->0) k where k = any(WANT)) = 4
                  then '✅ players[0] 四個頭像欄位都在　player_count=' || coalesce(j->>'player_count','?')
                  else '🔴 缺欄位，players[0] 有：'
                       || coalesce((select string_agg(k,'、') from jsonb_object_keys(j->'players'->0) k),'(空)') end;

    -- ⑤ list_match_queues_tx（待辦 35 expand）
    j := (select list_match_queues_tx(v_org, v_me, q.store_id) -> 0
            from match_queues q where q.id = v_q);
    v_msg := v_msg || E'\n⑤ list_match_queues_tx　'
          || case when j is null then '🔴 回空的'
                  when j ? 'player_count' and j ? 'players'
                  then '✅ players=' || (j->>'players') || '　player_count=' || (j->>'player_count')
                       || '（兩個都在＝expand 正確，前端改完再 contract）'
                  else '🔴 player_count 沒補上' end;

    raise exception 'rollback_on_purpose';
  exception when others then
    if sqlerrm = 'rollback_on_purpose' then
      perform set_config('migi.rpc_test', v_msg, true);
    else
      perform set_config('migi.rpc_test', v_msg || E'\n🔴 測試中途拋錯：' || sqlerrm, true);
    end if;
  end;
end $$;

select 序, 項目, 內容 from (

  select 1 as 序, '① 🎯 行為測試（交易內造資料、呼叫、回滾）' as 項目,
         coalesce(nullif(current_setting('migi.rpc_test', true), ''), '🔴 沒有拿到測試結果') as 內容

  union all
  /* 🎯 正對照：`CREATE OR REPLACE` 不會掉 GRANT，但重寫時可能手滑改了別的。
     五支都該維持 DEFINER ＋ anon 叫得動。 */
  select 2, '② 🎯 正對照：五支的模式與授權都沒被動到',
         (select string_agg(p.proname
                 || '　' || case when p.prosecdef then 'DEFINER' else '🔴 INVOKER' end
                 || '　anon=' || case when has_function_privilege('anon', p.oid, 'execute') then '✅' else '🔴 無' end,
                 E'\n' order by p.proname)
            from pg_proc p
           where p.pronamespace='public'::regnamespace and p.prokind='f'
             and p.proname in ('get_my_profile_tx','list_blocks_tx','list_buddies_tx',
                               'get_my_active_queue_tx','list_match_queues_tx'))

  union all
  select 3, '③ 🎯 正對照：測試資料沒有留下來',
         (select '封鎖 ' || (select count(*) from member_blocks)::text
              || '　牌咖 ' || (select count(*) from mahjong_buddies)::text
              || '　在座 ' || (select count(*) from match_queue_players
                               where member_id = '69016205-afde-4036-95a6-5893c9d0e5fe'
                                 and left_at is null)::text
              || case when (select count(*) from member_blocks) = 0
                       and (select count(*) from mahjong_buddies) = 0
                      then '　✅ 都回滾了' else '　🔴 有殘留' end)

) x order by 序;
