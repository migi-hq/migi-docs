/* ============================================================
   `list_buddies_tx` 補「上次同桌」　2026-09-01 · MIGI

   ── 使用者拍板 ──────────────────────────────────────
   · 牌咖卡「同桌次數」右邊新增「**上次同桌**」
   · **「勝 / 負」那一格拿掉**

   ── 🔴 為什麼「勝 / 負」拿掉了 ──────────────────────
   它在此之前是**寫死的 `0 / N`** —— 對另一個真實會員宣稱
   「跟你打過 N 次一次都沒贏」。那是捏造，不是佔位圖。

   ✅ 定義當天有拍板：**分數比對方高就是勝**（+20 對 +10 記一勝）。
   ⚠ **但電子計分之前每一格都會是 `0 / 0`** ——
     一個永遠是 0/0 的格子佔掉四分之一的寬度，什麼都沒說。
   → 所以這一版**不回傳 `win_count` / `loss_count`**：
     沒有人讀的欄位就是「建了沒人讀」，而且它會讓人以為那件事做完了。

   📌 **要加回來時，這兩件事先記著：**
   ① `loss` 一定要**後端各自數**，不可以用「同桌次數 − 勝」——
      那會把**平手**（兩人同分）與**還沒結算**的場次全部算成輸，
      所以 `勝 + 負 ≤ 同桌次數`。
   ② 這是**對戰成績**不是勝率（兩個人比大小）。
      成績頁的「各級距勝率」沒有對手可以比，**那一格仍然沒有定義**。

   ── ✅ 不加欄位，從事實表即時算 ──────────────────────
   `mahjong_buddies` 沒有 `last_played_at`，而**也不該加** ——
   同待辦 1 的 B 案：存計數欄位會出現「欄位與事實對不上而且無從得知
   哪邊才對」，退款／作廢／補登任何一次漏回沖就永久偏差。
   `session_players` 是事實表，算出來的永遠一致。
   ⚠ 慢了再加物化檢視表，不要一開始就存。

   ✅ 簽名不變 → `CREATE OR REPLACE`，不用 DROP、不掉 GRANT。
   ⚠ 「上次同桌」**不需要結算** —— 同桌是事實，輸贏才需要結算。
     所以 M4 之前它就有值。
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
      /* ★ 2026-09-01 新增：上次跟這個人同桌是什麼時候。
         ⚠ 用 `ended_at`，沒有才退回 `activated_at` / `started_at` ——
           跟 `get_my_games_tx` 的時間來源保持一致。 */
      'last_played_at', x.last_at
    ) order by b.linked_at desc)
    from mahjong_buddies b
    join members m on m.id = b.buddy_id and m.deleted_at is null
    left join lateral (
      select max(coalesce(s.ended_at, s.activated_at, s.started_at)) as last_at
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
  me uuid; bud uuid; other uuid; s1 uuid; one jsonb; arr jsonb;
begin
  begin
    select id into v_store from stores where org_id = v_org limit 1;
    select id into v_tbl   from tables where org_id = v_org limit 1;
    insert into members (org_id, display_name) values (v_org,'測我')   returning id into me;
    insert into members (org_id, display_name) values (v_org,'測牌咖') returning id into bud;
    insert into members (org_id, display_name) values (v_org,'測路人') returning id into other;
    insert into mahjong_buddies (org_id, member_id, buddy_id, origin, co_play_count)
      values (v_org, me, bud, 'matched', 2);

    ---- ① 還沒同桌過 -----------------------------------
    /* 🔴 先驗「還沒同桌」那一格：**鍵要在、值要是 null**。
       少了它，「函式根本沒回這個鍵」跟「回了但是 null」分不出來。 */
    one := public.list_buddies_tx(v_org, me) -> 0;
    v_out := v_out || E'\n' || '① 還沒同桌過：鍵在但值是 null' || E'\t' ||
      case when (one ? 'last_played_at') and one->>'last_played_at' is null
           then '✅ 鍵在、值 null（前端顯示「—」）'
           else '🔴 ' || coalesce(one->>'last_played_at','(沒有這個鍵)') end;

    ---- ② 同桌兩場，要取比較晚的那一場 -----------------
    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
      values (v_org, v_store, v_tbl, 'private','completed', now() - interval '9 days') returning id into s1;
    insert into session_players (org_id, session_id, member_id)
      values (v_org,s1,me), (v_org,s1,bud);
    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
      values (v_org, v_store, v_tbl, 'private','completed', now() - interval '6 days') returning id into s1;
    insert into session_players (org_id, session_id, member_id)
      values (v_org,s1,me), (v_org,s1,bud);

    one := public.list_buddies_tx(v_org, me) -> 0;
    v_out := v_out || E'\n' || '② 同桌兩場 → 取比較晚的（6 天前）' || E'\t' ||
      case when (one->>'last_played_at')::timestamptz::date = (now() - interval '6 days')::date
           then '✅ 6 天前'
           else '🔴 ' || coalesce(one->>'last_played_at','null') end;

    /* 🔴 **正對照：不需要結算。** 上面兩場都沒有 finish_rank，
       而「同桌」是事實不是戰績 —— M4 之前這一格就該有值。
       少了這一格，一個誤加 `finish_rank is not null` 的寫法會讓
       這一格在上線後好幾個月都是空的，而且沒有人看得出來。 */
    v_out := v_out || E'\n' || '③ 🎯 正對照：兩場都沒結算，仍然有值' || E'\t' ||
      case when one->>'last_played_at' is not null
           then '✅ 有值（同桌是事實，輸贏才需要結算）'
           else '🔴 null —— 大概誤加了 finish_rank 的條件' end;

    ---- ④ 正對照：別人的場次不能算進來 -----------------
    /* join 寫錯（例如漏掉 `op.member_id = b.buddy_id`）的話，
       「我跟路人打的那一場」也會被算成「我跟這個牌咖的上次同桌」。 */
    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
      values (v_org, v_store, v_tbl, 'private','completed', now()) returning id into s1;
    insert into session_players (org_id, session_id, member_id)
      values (v_org,s1,me), (v_org,s1,other);
    one := public.list_buddies_tx(v_org, me) -> 0;
    v_out := v_out || E'\n' || '④ 正對照：跟路人打的今天那場不算' || E'\t' ||
      case when (one->>'last_played_at')::timestamptz::date = (now() - interval '6 days')::date
           then '✅ 還是 6 天前'
           else '🔴 ' || coalesce(one->>'last_played_at','null') || ' —— join 寫歪了' end;

    ---- ⑤ 正對照：原有欄位一個都沒少 -------------------
    v_out := v_out || E'\n' || '⑤ 正對照：原有 11 個欄位都在' || E'\t' ||
      case when one ?& array['id','nickname','rank','title','likes_count','avatar_url',
                             'co_play_count','avatar_source','avatar_photo_path',
                             'avatar_bear','linked_at']
           then '✅ 都在' else '🔴 掉了' end;
    /* 🔴 **確認沒有回傳沒人讀的欄位。**
       這一版刻意不做勝負 —— 回了就是「建了沒人讀」。 */
    v_out := v_out || E'\n' || '⑥ 沒有回傳 win_count / loss_count' || E'\t' ||
      case when not (one ? 'win_count') and not (one ? 'loss_count')
           then '✅ 沒有（這一版刻意不做）'
           else '🔴 回了沒人讀的欄位' end;

    v_out := v_out || E'\n' || '⑦ 正對照：DEFINER 與 anon 授權沒被動到' || E'\t' ||
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
