/* ============================================================
   `list_buddies_tx` 補「常一起打」　2026-09-01 · MIGI

   ── 為什麼換掉「段位」那一格 ────────────────────────
   🔴 「你和小雲」這個區塊講的是**你們兩個的關係**，
     而「她的段位」是**她的屬性** —— 那是分類錯誤，不只是重複
     （上面那張粉色卡已經寫了 `段位: 銅牌熊 III`）。

   📌 世界級競技手遊在這個位置放的**全部是「一起做過什麼」**：
     王者榮耀（親密度／常一起玩的時段）、LoL（雙排勝率）、
     Apex（最近一起玩過＋一鍵邀請）。**沒有一個放對方的屬性。**

   🎯 「常一起打」回答的是這張卡真正的下一個問題：**約什麼時候。**
     而它旁邊就是「邀請一起開桌」——「週五晚上」放在邀請鍵旁邊
     是一句行動呼籲，不是一個裝飾數字。

   ── 🔴 隱私：它只用「你也在場」的場次算 ──────────────
   硬規則 26 明訂**行為推斷只有系統與總部看得到**
   （「他通常等 12 分鐘就走」對他本人都不該顯示）。
   這一格不違反那條，因為它**只統計你自己也坐在那張桌的場次** ——
   那是**你們共同的事實**，不是對她的側寫。
   ⚠ 這個界線要守住：日後想加「她通常幾點來」就越線了。

   ── 🔴 時段的定義只能有一份 ──────────────────────────
   `member_availability.slot ∈ morning | afternoon | evening | late`
   已經存在（M3 的推斷引擎會用），但**沒有人定義過幾點到幾點**。
   → 這份建 **`migi_slot_of(ts)`**，M3 直接用同一支。
     兩邊各寫一份「晚上是幾點」就是同一個名字兩種意思
     （同 CLAUDE.md 待辦 35 那個病）。

   ── ⚠ 「常」需要門檻，否則就是說謊 ──────────────────
   ```
   總同桌 ≥ 3 場，且眾數出現 ≥ 2 次
   ```
   打過一次就說「常一起打 週五晚上」是假的。
   達不到門檻回 **null**，前端顯示 `—`。
   ⚠ 兩層退化：`(星期,時段)` 湊不到 2 次時退成**只有時段** ——
     一對固定週末打的人可能週六週日各半，星期永遠湊不到眾數，
     但「晚上」是真的。

   ✅ `list_buddies_tx` 簽名不變 → `CREATE OR REPLACE`。
   ⚠ **不加欄位** —— 同 `last_played_at`，從 `session_players` 即時算。
   ============================================================ */

-- ① 時段：全系統唯一的定義 ────────────────────────────
create or replace function public.migi_slot_of(p_at timestamptz)
returns text language sql stable security definer set search_path to 'public'
as $$
  /* 以**台北時間**的小時決定。⚠ 不要用 UTC ——
     台灣晚上 8 點是 UTC 中午，會被歸成「下午」。
     ⚠ 值必須與 `member_availability_source_check` 那組一致：
       morning / afternoon / evening / late。 */
  select case
    when h >= 6  and h < 12 then 'morning'
    when h >= 12 and h < 18 then 'afternoon'
    when h >= 18            then 'evening'
    else 'late'                       -- 00:00–05:59 深夜
  end
  from (select extract(hour from (p_at at time zone 'Asia/Taipei'))::int as h) x
$$;

/* 🔴 內部用，收 anon 與 PUBLIC **兩個方向**（硬規則 2.6／2.6b）。
   ⚠ DEFINER 函式從內部呼叫不受影響（呼叫端權限不會被檢查）。 */
revoke execute on function public.migi_slot_of(timestamptz) from public;
revoke execute on function public.migi_slot_of(timestamptz) from anon, authenticated;
grant  execute on function public.migi_slot_of(timestamptz) to service_role;


-- ② list_buddies_tx 補 play_pattern ───────────────────
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
      'last_played_at', x.last_at,
      /* ★ 2026-09-01：常一起打。
         🔴 回**結構**不回句子（`{weekday, slot, n}`）——
           「週五晚上」怎麼組字是顯示規則，不該住在資料庫裡
           （同 `get_my_games_tx` 的 `rounds` 回整數不回「2 將」）。 */
      'play_pattern', x.pattern
    ) order by b.linked_at desc)
    from mahjong_buddies b
    join members m on m.id = b.buddy_id and m.deleted_at is null
    left join lateral (
      with shared as (
        /* 你們兩個都坐過、而且已收桌的場次。
           ⚠ 用開打時間（`activated_at`）不是收桌時間 ——
             凌晨兩點收桌的晚場，問的是「幾點開始打」。 */
        select coalesce(s.activated_at, s.started_at, s.ended_at) as at
        from session_players me
        join session_players op
          on op.session_id = me.session_id and op.member_id = b.buddy_id
        join table_sessions s
          on s.id = me.session_id and s.deleted_at is null and s.status = 'completed'
       where me.member_id = p_member and me.org_id = p_org_id
      ), tagged as (
        select extract(dow from (at at time zone 'Asia/Taipei'))::int as wd,
               public.migi_slot_of(at) as slot
          from shared where at is not null
      ), tot as (select count(*) as n from tagged),
      /* 第一層：星期＋時段的眾數 */
      best_ws as (
        select wd, slot, count(*) as n from tagged
         group by wd, slot order by count(*) desc, slot, wd limit 1
      ),
      /* 第二層：只有時段的眾數（星期湊不到 2 次時用） */
      best_s as (
        select slot, count(*) as n from tagged
         group by slot order by count(*) desc, slot limit 1
      )
      select
        (select max(at) from shared) as last_at,
        case
          /* 🔴 「常」的兩個門檻，缺一不可：
             ① **總同桌 ≥ 3 場** —— 打過一次就說「常」是假的
             ② **眾數要過半**（`n × 2 > 總數`）—— 不是「出現 ≥2 次」

             ⚠ 我第一版寫 `>= 2`，它會讓「週六 2 次／週日 2 次」
               宣稱「常一起打 **週六**晚上」—— 一半的場次不是週六。
               **「最多的那一個」不等於「常」**，那是這一格最容易寫錯的地方。 */
          when (select n from tot) < 3 then null
          when (select n from best_ws) * 2 > (select n from tot) then
            jsonb_build_object('weekday', (select wd from best_ws),
                               'slot',    (select slot from best_ws),
                               'n',       (select n from best_ws))
          when (select n from best_s) * 2 > (select n from tot) then
            /* 退化：星期分散但時段集中 → 只講時段。
               🎯 一對固定週末打的人週六週日各半，星期永遠過不了半，
                 但「晚上」是真的 —— 少了這一層他們永遠看到 `—`。 */
            jsonb_build_object('weekday', null,
                               'slot', (select slot from best_s),
                               'n',    (select n from best_s))
          else null      -- 兩層都過不了半 ⇒ 真的沒有規律
        end as pattern
    ) x on true
    where b.member_id = p_member and b.org_id = p_org_id and b.deleted_at is null
  ), '[]'::jsonb);
end $function$;


-- ── 驗證 ───────────────────────────────────────────────
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_out text := ''; v_store uuid; v_tbl uuid;
  me uuid; bud uuid; other uuid; s uuid; one jsonb; i int;
  -- 2026-09-04 是星期五
  fri timestamptz := '2026-09-04 20:00+08';
begin
  begin
    ---- ① 時段邊界 -------------------------------------
    v_out := v_out || E'\n' || '① 時段邊界（台北時間）' || E'\t' ||
      case when public.migi_slot_of('2026-09-04 05:59+08') = 'late'
            and public.migi_slot_of('2026-09-04 06:00+08') = 'morning'
            and public.migi_slot_of('2026-09-04 11:59+08') = 'morning'
            and public.migi_slot_of('2026-09-04 12:00+08') = 'afternoon'
            and public.migi_slot_of('2026-09-04 17:59+08') = 'afternoon'
            and public.migi_slot_of('2026-09-04 18:00+08') = 'evening'
            and public.migi_slot_of('2026-09-04 23:59+08') = 'evening'
            and public.migi_slot_of('2026-09-05 00:00+08') = 'late'
           then '✅ 八個邊界都對（late/morning/afternoon/evening）'
           else '🔴 ' || public.migi_slot_of('2026-09-04 05:59+08') || '/'
                || public.migi_slot_of('2026-09-04 18:00+08') end;
    /* 🔴 **正對照：一定要驗時區。** 台灣晚上 8 點的 UTC 是中午 ——
       忘了 `at time zone 'Asia/Taipei'` 的話它會被歸成「下午」，
       而上面那八格**全部照樣會過**（因為它們也都寫 +08）。 */
    v_out := v_out || E'\n' || '② 🎯 正對照：時區真的有換算' || E'\t' ||
      case when public.migi_slot_of('2026-09-04 12:00+00') = 'evening'
           then '✅ UTC 12:00 = 台北 20:00 = 晚上'
           else '🔴 ' || public.migi_slot_of('2026-09-04 12:00+00') || ' —— 大概沒換算時區' end;

    ---- 造資料 ------------------------------------------
    select id into v_store from stores where org_id = v_org limit 1;
    select id into v_tbl   from tables where org_id = v_org limit 1;
    insert into members (org_id, display_name) values (v_org,'測我')   returning id into me;
    insert into members (org_id, display_name) values (v_org,'測牌咖') returning id into bud;
    insert into members (org_id, display_name) values (v_org,'測路人') returning id into other;
    insert into mahjong_buddies (org_id, member_id, buddy_id, origin, co_play_count)
      values (v_org, me, bud, 'matched', 0);

    ---- ③ 只有 2 場 → 不夠「常」------------------------
    for i in 0..1 loop
      insert into table_sessions (org_id, store_id, table_id, mode, status, activated_at, ended_at)
        values (v_org, v_store, v_tbl, 'private','completed', fri - (i||' weeks')::interval, now())
        returning id into s;
      insert into session_players (org_id, session_id, member_id) values (v_org,s,me), (v_org,s,bud);
    end loop;
    one := public.list_buddies_tx(v_org, me) -> 0;
    v_out := v_out || E'\n' || '③ 只同桌 2 場 → 不算「常」' || E'\t' ||
      case when one->>'play_pattern' is null then '✅ null（前端顯示 —）'
           else '🔴 ' || (one->'play_pattern')::text || ' —— 2 場就說「常」是假的' end;

    ---- ④ 第 3 場（也是週五晚上）→ 成立 -----------------
    insert into table_sessions (org_id, store_id, table_id, mode, status, activated_at, ended_at)
      values (v_org, v_store, v_tbl, 'private','completed', fri - interval '2 weeks', now())
      returning id into s;
    insert into session_players (org_id, session_id, member_id) values (v_org,s,me), (v_org,s,bud);
    one := public.list_buddies_tx(v_org, me) -> 0;
    v_out := v_out || E'\n' || '④ 🎯 第 3 場 → 週五(5) 晚上 ×3' || E'\t' ||
      case when (one->'play_pattern'->>'weekday')::int = 5
                and one->'play_pattern'->>'slot' = 'evening'
                and (one->'play_pattern'->>'n')::int = 3
           then '✅ weekday=5 slot=evening n=3'
           else '🔴 ' || coalesce((one->'play_pattern')::text,'null') end;

    ---- ⑤ 星期分散但時段集中 → 退化成只講時段 -----------
    /* 🔴 **這一格是「過半」而不是「≥2」的證據。**
       週六 2 次、週日 2 次，全部晚上：
       · `(星期,時段)` 最多 2/4 —— **沒過半**，不可以說「常在週六」
       · `時段` 是 4/4 —— 過半，「晚上」是真的
       ⚠ 我第一版寫 `>= 2`，這一格會回「週六晚上」而且看起來很合理。 */
    insert into members (org_id, display_name) values (v_org,'測週末咖') returning id into other;
    insert into mahjong_buddies (org_id, member_id, buddy_id, origin, co_play_count)
      values (v_org, me, other, 'matched', 0);
    for i in 1..4 loop
      insert into table_sessions (org_id, store_id, table_id, mode, status, activated_at, ended_at)
        values (v_org, v_store, v_tbl, 'private','completed',
                (array[timestamptz '2026-09-05 21:00+08',   -- 週六
                       timestamptz '2026-09-06 21:00+08',   -- 週日
                       timestamptz '2026-09-12 21:00+08',   -- 週六
                       timestamptz '2026-09-13 21:00+08'])[i],
                now())
        returning id into s;
      insert into session_players (org_id, session_id, member_id) values (v_org,s,me), (v_org,s,other);
    end loop;
    select y into one from jsonb_array_elements(public.list_buddies_tx(v_org, me)) y
     where y->>'nickname' = '測週末咖';
    v_out := v_out || E'\n' || '⑤ 🎯 週六2／週日2 → 只給時段，不給星期' || E'\t' ||
      case when one->'play_pattern'->>'slot' = 'evening'
                and one->'play_pattern'->>'weekday' is null
           then '✅ evening／weekday=null（≥2 的寫法會誤報「週六」）'
           else '🔴 ' || coalesce((one->'play_pattern')::text,'null') end;

    ---- ⑥ 正對照：真的沒規律要回 null -------------------
    /* 🔴 少了這一格，一個「永遠給時段」的寫法會讓 ⑤ 變綠。
       晚上 2 次、早上 2 次 ⇒ 兩層都過不了半 ⇒ 沒有規律。 */
    insert into members (org_id, display_name) values (v_org,'測沒規律') returning id into other;
    insert into mahjong_buddies (org_id, member_id, buddy_id, origin, co_play_count)
      values (v_org, me, other, 'matched', 0);
    for i in 1..4 loop
      insert into table_sessions (org_id, store_id, table_id, mode, status, activated_at, ended_at)
        values (v_org, v_store, v_tbl, 'private','completed',
                (array[timestamptz '2026-09-05 21:00+08',      -- 週六 晚上
                       timestamptz '2026-09-07 09:00+08',      -- 週一 早上
                       timestamptz '2026-09-12 21:00+08',      -- 週六 晚上
                       timestamptz '2026-09-15 09:00+08'])[i], -- 週二 早上
                now())
        returning id into s;
      insert into session_players (org_id, session_id, member_id) values (v_org,s,me), (v_org,s,other);
    end loop;
    select y into one from jsonb_array_elements(public.list_buddies_tx(v_org, me)) y
     where y->>'nickname' = '測沒規律';
    v_out := v_out || E'\n' || '⑥ 正對照：晚上2／早上2 → 沒規律，回 null' || E'\t' ||
      case when one->>'play_pattern' is null then '✅ null（前端顯示 —）'
           else '🔴 ' || (one->'play_pattern')::text || ' —— 過半那一關沒擋住' end;

    ---- ⑦ 正對照：原有欄位一個都沒少 -------------------
    select y into one from jsonb_array_elements(public.list_buddies_tx(v_org, me)) y
     where y->>'nickname' = '測牌咖';
    v_out := v_out || E'\n' || '⑦ 正對照：原有 12 個欄位都在' || E'\t' ||
      case when one ?& array['id','nickname','rank','title','likes_count','avatar_url',
                             'co_play_count','avatar_source','avatar_photo_path',
                             'avatar_bear','linked_at','last_played_at']
           then '✅ 都在（含上次同桌）' else '🔴 掉了' end;

    ---- ⑧ 授權 -----------------------------------------
    v_out := v_out || E'\n' || '⑧ migi_slot_of：anon 與 PUBLIC 都收乾淨' || E'\t' ||
      (select case when count(*) = 0 then '✅ 兩個方向都沒有'
                   else '🔴 還有 ' || count(*) || ' 筆' end
         from pg_proc p, aclexplode(p.proacl) a
        where p.pronamespace='public'::regnamespace and p.proname='migi_slot_of'
          and a.privilege_type='EXECUTE'
          and (a.grantee = 0 or a.grantee = 'anon'::regrole::oid));
    v_out := v_out || E'\n' || '⑨ 正對照：list_buddies_tx 的 anon 還在' || E'\t' ||
      (select case when exists (select 1 from aclexplode(p.proacl) a
                        where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE')
                   then '✅ 還在' else '🔴 掉了' end
         from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='list_buddies_tx');

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.pat', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.pat', true), E'\n')) as x
 where coalesce(x,'') <> '';
