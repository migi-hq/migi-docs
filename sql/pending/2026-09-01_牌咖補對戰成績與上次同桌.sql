/* ============================================================
   `list_buddies_tx` 補「對戰成績」與「上次同桌」　2026-09-01 · MIGI

   ── 使用者拍板 ──────────────────────────────────────
   · **「贏」的定義：分數比對方高就是勝**（例：+20 對 +10，+20 記一勝）
   · 牌咖卡「同桌次數」右邊新增「**上次同桌**」

   ── 🎯 這個定義解決了什麼 ──────────────────────────
   在此之前 `win` 是**寫死的 0**，牌咖卡永遠顯示「0 勝 N 負」——
   對另一個真實會員的捏造。今天它有定義了，所以可以真的算。

   🔴 **注意這是「對戰成績」不是「勝率」** —— 兩個人比大小，
     跟「這一場我第幾名」是不同的問題。
     ⚠ 所以它**不能拿來填成績頁的「各級距勝率」** ——
       那一格問的是「我在 50/20 打得好不好」，沒有對手可以比。
       那一格仍然沒有定義（見 CLAUDE.md 待辦 33）。

   ── ⚠ 平手不算勝也不算負 ────────────────────────────
   `勝 + 負 ≤ 同桌次數`。用 `同桌次數 − 勝` 當負數是錯的
   —— 那會把平手與未結算的場次都算成輸。
   → 兩個數字**各自數**，前端不要自己相減。

   ── ✅ 不加欄位，從事實表即時算 ──────────────────────
   `mahjong_buddies` 沒有 `last_played_at`，而**也不該加** ——
   同待辦 1 的 B 案：存計數欄位會出現「欄位與事實對不上而且無從得知
   哪邊才對」，退款／作廢／補登任何一次漏回沖就永久偏差。
   `session_players` 是事實表，算出來的永遠一致。
   ⚠ 慢了再加物化檢視表，不要一開始就存。

   ✅ 簽名不變 → `CREATE OR REPLACE`，不用 DROP、不掉 GRANT。
   ⚠ M4／電子計分之前 `score_points` 全是 null ⇒
     **勝負都是 0、上次同桌仍然有值**（同桌是事實，輸贏才需要結算）。
   ============================================================ */

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
      'linked_at', b.linked_at,
      /* ★ 2026-09-01 新增三個，全部從 `session_players` 即時算。
         🔴 三個都用**同一個 join**（我坐過 ∩ 他坐過 ∩ 場次已收桌），
           分開寫三份條件就會有一份寫歪而且不報錯。 */
      'last_played_at', x.last_at,
      'win_count',      x.wins,
      'loss_count',     x.losses
    ) order by b.linked_at desc)
    from mahjong_buddies b
    join members m on m.id = b.buddy_id and m.deleted_at is null
    left join lateral (
      select
        max(coalesce(s.ended_at, s.activated_at, s.started_at))        as last_at,
        /* 「分數比對方高就是勝」（使用者 2026-09-01 拍板）。
           ⚠ 任一邊 `score_points` 是 null（還沒結算）→ 比較結果是 null
             → `count(*) filter` 不計入。**那是對的**：沒結算就沒有輸贏。
           ⚠ 平手兩邊都不計 ⇒ `wins + losses ≤ 同桌次數`。 */
        count(*) filter (where me.score_points > op.score_points)      as wins,
        count(*) filter (where me.score_points < op.score_points)      as losses
      from session_players me
      join session_players op
        on op.session_id = me.session_id and op.member_id = b.buddy_id
      join table_sessions s
        on s.id = me.session_id and s.deleted_at is null and s.status = 'completed'
     where me.member_id = p_member and me.org_id = p_org_id
    ) x on true
    where b.member_id = p_member and b.org_id = p_org_id and b.deleted_at is null
  ), '[]'::jsonb);
end $function$;


-- ── 驗證 ───────────────────────────────────────────────
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_out text := ''; v_store uuid; v_tbl uuid;
  me uuid; bud uuid; c uuid; d uuid; s1 uuid; s2 uuid; s3 uuid; one jsonb;
begin
  begin
    select id into v_store from stores where org_id = v_org limit 1;
    select id into v_tbl   from tables where org_id = v_org limit 1;
    insert into members (org_id, display_name) values (v_org,'測我')   returning id into me;
    insert into members (org_id, display_name) values (v_org,'測牌咖') returning id into bud;
    insert into members (org_id, display_name) values (v_org,'測丙')   returning id into c;
    insert into members (org_id, display_name) values (v_org,'測丁')   returning id into d;
    insert into mahjong_buddies (org_id, member_id, buddy_id, origin, co_play_count)
      values (v_org, me, bud, 'matched', 3);

    ---- 三場：我贏 / 我輸 / 平手 ------------------------
    -- ① 我 +60 他 +30 → 我勝
    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
      values (v_org, v_store, v_tbl, 'private','completed', now() - interval '9 days') returning id into s1;
    insert into session_players (org_id, session_id, member_id, finish_rank, score_points, settled_at)
      values (v_org,s1,me,1,60,now()), (v_org,s1,bud,2,30,now()),
             (v_org,s1,c,3,20,now()),  (v_org,s1,d,4,10,now());
    -- ② 我 +10 他 +60 → 我負
    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
      values (v_org, v_store, v_tbl, 'private','completed', now() - interval '6 days') returning id into s2;
    insert into session_players (org_id, session_id, member_id, finish_rank, score_points, settled_at)
      values (v_org,s2,me,4,10,now()), (v_org,s2,bud,1,60,now()),
             (v_org,s2,c,2,30,now()),  (v_org,s2,d,3,20,now());
    -- ③ 兩人同分 → 不計勝也不計負（🔴 這一場就是「不能用相減」的證據）
    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
      values (v_org, v_store, v_tbl, 'private','completed', now() - interval '2 days') returning id into s3;
    insert into session_players (org_id, session_id, member_id, finish_rank, score_points, settled_at)
      values (v_org,s3,me,1,30,now()), (v_org,s3,bud,2,30,now()),
             (v_org,s3,c,3,20,now()),  (v_org,s3,d,4,10,now());

    select (public.list_buddies_tx(v_org, me) -> 0) into one;

    v_out := v_out || E'\n' || '① 勝 = 1（我 +60 對他 +30）' || E'\t' ||
      case when (one->>'win_count')::int = 1 then '✅ 1'
           else '🔴 ' || coalesce(one->>'win_count','null') end;
    v_out := v_out || E'\n' || '② 負 = 1（我 +10 對他 +60）' || E'\t' ||
      case when (one->>'loss_count')::int = 1 then '✅ 1'
           else '🔴 ' || coalesce(one->>'loss_count','null') end;
    /* 🔴 **這一格是整份 SQL 的重點**：三場同桌但只有 1 勝 1 負。
       舊的前端寫法 `負 = 同桌次數 − 勝` 會算成 2 負 —— 把平手算成輸。 */
    v_out := v_out || E'\n' || '③ 🎯 三場同桌，1 勝 1 負（平手不算）' || E'\t' ||
      case when (one->>'win_count')::int + (one->>'loss_count')::int = 2
           then '✅ 勝+負 = 2 < 同桌 3　（相減會算成 2 負）'
           else '🔴 勝+負 = ' || ((one->>'win_count')::int + (one->>'loss_count')::int) end;
    v_out := v_out || E'\n' || '④ 上次同桌 = 2 天前那一場' || E'\t' ||
      case when (one->>'last_played_at')::timestamptz::date
                = (now() - interval '2 days')::date then '✅ 2 天前'
           else '🔴 ' || coalesce(one->>'last_played_at','null') end;

    ---- 正對照 ------------------------------------------
    v_out := v_out || E'\n' || '⑤ 正對照：原有欄位一個都沒少' || E'\t' ||
      case when one ?& array['id','nickname','rank','title','likes_count','avatar_url',
                             'co_play_count','avatar_source','avatar_photo_path',
                             'avatar_bear','linked_at']
           then '✅ 11 個原欄位都在' else '🔴 掉了' end;

    /* 🔴 **正對照：沒結算的場次不能算成輸。**
       少了這一格，一個把 null 當 0 比較的寫法會讓 M4 之前
       每一場都變成「平手或輸」，而且沒有人看得出來。 */
    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
      values (v_org, v_store, v_tbl, 'private','completed', now()) returning id into s1;
    insert into session_players (org_id, session_id, member_id)
      values (v_org,s1,me), (v_org,s1,bud);
    select (public.list_buddies_tx(v_org, me) -> 0) into one;
    v_out := v_out || E'\n' || '⑥ 正對照：未結算的場次不計勝負' || E'\t' ||
      case when (one->>'win_count')::int = 1 and (one->>'loss_count')::int = 1
           then '✅ 還是 1 勝 1 負' else '🔴 ' || (one->>'win_count') || ' / ' || (one->>'loss_count') end;
    v_out := v_out || E'\n' || '⑦ 正對照：但上次同桌要跟著更新成今天' || E'\t' ||
      case when (one->>'last_played_at')::timestamptz::date = now()::date
           then '✅ 今天（同桌是事實，輸贏才需要結算）'
           else '🔴 ' || coalesce(one->>'last_played_at','null') end;

    /* 🔴 正對照：別人的場次不能算進來。
       join 寫錯（例如漏掉 `op.member_id = b.buddy_id`）會讓
       「我跟丙打的那些」也算進「我對這個牌咖」的成績。 */
    insert into mahjong_buddies (org_id, member_id, buddy_id, origin, co_play_count)
      values (v_org, me, c, 'matched', 3);
    v_out := v_out || E'\n' || '⑧ 正對照：換一個牌咖，成績不一樣' || E'\t' ||
      (select case when count(distinct (y->>'win_count')) = 2 or
                        count(distinct (y->>'loss_count')) = 2
                   then '✅ 兩個牌咖的成績是分開算的'
                   else '🔴 兩個牌咖數字一樣 —— join 可能寫歪了' end
         from jsonb_array_elements(public.list_buddies_tx(v_org, me)) y);

    v_out := v_out || E'\n' || '⑨ 正對照：DEFINER 與 anon 授權沒被動到' || E'\t' ||
      (select case when p.prosecdef and exists (select 1 from aclexplode(p.proacl) a
                        where a.grantee = 'anon'::regrole::oid and a.privilege_type='EXECUTE')
                   then '✅ DEFINER ／ anon 有' else '🔴 有東西被改到' end
         from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='list_buddies_tx');

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.bud', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.bud', true), E'\n')) as x
 where coalesce(x,'') <> '';
