/* ============================================================
   ⏸ 暫緩 —— 測試世界與正式世界互不相見
   2026-09-05 · MIGI 咪吉麻將

   🔴 **這一份現在跑不動，而且那是刻意的。**
   第 ⓪ 段會檢查「有沒有至少一間正式門市」，沒有就整份拒絕執行。
   今天 7 間門市**全部**是 `is_test = true` ⇒ 現在跑會讓真客人的
   門市清單**變成空的**（硬規則 3.55：過度阻擋跟沒擋一樣糟，
   而且更難發現 —— 它不會報錯，只會什麼都沒有）。

   ⇒ **執行時機：上線當天，標好哪幾間是真門市之後**
     （`docs/09-環境流程/上線當天要設的東西.md` 的 ② → ②.5）。

   ── 為什麼需要它 ──────────────────────────────────────
   測試01～04 上線後**留著**（2026-09-05 決定）。而 2026-09-05 查證：
   ```
   排行榜 get_season_leaderboard_tx   ✅ 有濾 is_test
   season_rank_rows_tx                ✅ 有濾
   配桌房間 list_match_queues_tx      🔴 沒濾
   最近同桌 list_recent_players_tx    🔴 沒濾
   牌咖清單 list_buddies_tx           🔴 沒濾
   門市清單 list_stores_tx            🔴 沒濾
   _try_auto_seat_tx / sweep_auto_seat_tx / _finalize_queue_full_tx  🔴 沒濾
   ```
   ⚠ 報表那一側**是完整的**：12 支 `v_real_*` 有 10 支直接濾 `is_test`，
     `order_items` 與 `order_payments` 靠 `exists (… v_real_orders)` 繼承。
     **所以數據不會被污染，會出事的是客人看得到的畫面。**

   🔴 最貴的一種失敗不是「看到假房間」，是**真的桌子被佔走**：
   ```
   四個測試帳號湊滿一房 → pg_cron 每 5 分鐘的 auto-seat → 佔一張真桌
   ```
   `uq_sessions_open_table` 會把那張桌鎖住，店員在 POS 上看到
   「預留中」而沒有人會來。

   ── 🎯 規則不是「濾掉測試帳號」，是「兩個世界互不相見」──
   ```
   🔴 濾掉    →  測試帳號也看不到彼此  →  多人測試從此做不了
   ✅ 對稱    →  對方的 is_test = 我的 is_test
   ```
   那正是 Stripe test mode 的規則：**測試物件只跟測試物件互動**
   —— 測試卡刷不到正式客戶，但測試卡之間完全通。
   📌 MIGI 早就選了這個做法（`is_test` ＋ `v_real_*`），
     這一份只是把它補完；**不是引進 staging**（硬規則 5.7 明列不做）。

   ── 這一份改什麼 ──────────────────────────────────────
   ① `migi_test_world()`  —— **「我在哪個世界」只有這一份定義**
      🔴 這個專案一再犯的病是「同一個概念兩份定義」
        （`wallet_txns.type`／`staff.role`／`players`／
         `has_store_access()` 與 `can()` 對「誰是最高權限」不一致）。
        四支函式各寫一次 `is_test` 比對，就是第五次。
   ② 四支清單函式各加**一個述詞**（全文重建，簽名不變 ⇒ 不用 DROP）
   ③ `match_queues` 的 BEFORE INSERT 觸發器 —— **擋掉跨世界開房**

   ⚠ ③ **刻意用觸發器不改 `create_match_queue_tx`**：開房有三條路
     （會員 App／POS 登記現場客／`generate_recurring_instances_tx` 固定局），
     改函式要改三個地方而且會漏掉未來新增的第四條。
     觸發器一個地方涵蓋所有路徑，且完全不碰既有函式
     —— 同待辦 24 的判斷（觸發器掛在 `orders` 而不改 `checkout_tx`）。

   ⚠ **auto-seat 那三支不用改**：房間只能開在同世界的門市（③ 擋住了），
     而 `_try_auto_seat_tx` 是從**該房間的門市**挑桌
     ⇒ 測試房只配得到測試門市的桌。**根因擋掉，症狀自己消失。**
   ============================================================ */

-- ══════════════════════════════════════════════════════
-- ⓪ 🔴 執行前提：兩個世界都要有立足點
-- ══════════════════════════════════════════════════════
do $g$
declare v_real int; v_test int; v_msg text;
begin
  select count(*) into v_real from stores
   where not is_test and is_active and deleted_at is null;
  select count(*) into v_test from stores
   where is_test and is_active and deleted_at is null;

  /* 🔴 `raise` 的格式字串必須是**字面常值**，不是運算式：
     相鄰的 `'...' '...'` 不會自動接起來，`'...' || '...'` 直接
     `syntax error at or near "||"`（2026-09-05 兩種都踩過）。
     ⇒ 多行訊息一律**先組進變數**，再 `raise exception '%', v_msg`。 */
  if v_real = 0 then
    v_msg := '🔴 一間正式門市都沒有（'
          || (select count(*) from stores where is_active and deleted_at is null)
          || ' 間全是 is_test）'
          || E'\n→ 現在跑會讓真客人的門市清單變成空的，而且不報錯。'
          || E'\n→ 先做上線清單的 ②（標好哪幾間是真門市），再回來跑這一份。';
    raise exception '%', v_msg;
  end if;

  if v_test = 0 then
    v_msg := '🔴 一間測試門市都沒有 —— 測試世界會沒有立足點'
          || E'\n→ 上線清單 ② 明寫「至少留一間 is_test = true 的門市」。';
    raise exception '%', v_msg;
  end if;
end $g$;


-- ══════════════════════════════════════════════════════
-- ① 「我在哪個世界」—— 唯一的定義
-- ══════════════════════════════════════════════════════
/* 回傳 true ＝ 測試世界／false ＝ 正式世界／**null ＝ 不分**。

   🔴 null 是「不濾」不是「都看不到」—— 店員（POS 走 anon 或店員 session）
     與後台必須看得到全部，包括測試門市。
     ⚠ 這個方向是刻意的 **fail-open**：判斷不出來時維持現狀，
       而不是把畫面清空。清空是沒有症狀的失敗。

   🔴 **不收參數，只讀 JWT** —— 收 `p_member` 的話它就變成
     「給我一個 id，我告訴你他是不是測試帳號」，那是白白多一個查詢器
     （同 2026-08-30 拿掉 `check_phone` 的理由）。 */
/* 🔴 **店員一律回 null（看得到兩個世界）** —— 這一段不是可有可無的。
   同一個 LINE 帳號可以同時是店員與會員（創辦人就是），
   而 `current_member_id()` 對店員 session 也解析得出會員
   ⇒ 少了這一段，**POS 登入之後就看不到測試門市了**，
     而症狀是「桌況少了幾間店」，沒有人會聯想到這裡。

   🎯 判準用 `current_staff()` 而不是自己比對 role ——
     那支已經排除了 `migi_kind='member'` 的 session，
     所以同一個人「用 POS 登入」與「用 App 登入」會得到不同答案，
     **而那正是我們要的**。
   ⚠ 自己寫第二份「誰是店員」的定義，就是 `has_store_access()` 與
     `can()` 對「誰是最高權限」不一致的那個病（2026-09-04 修過一次）。 */
create or replace function public.migi_test_world()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select case
           when exists (select 1 from public.current_staff()) then null
           else (select m.is_test from members m
                  where m.id = public.current_member_id()
                    and m.deleted_at is null)
         end
$$;

/* ⚠ 這是內部輔助函式，只被 SECURITY DEFINER 函式從**內部**呼叫
   ⇒ 執行身分是擁有者，不需要授權給前端角色。
   🔴 兩個方向都要收（硬規則 2.6／2.6b）：
     · 舊函式的 anon 來自 **PUBLIC 繼承** → `revoke from public`
     · **新建**函式的 anon 是 default privileges **明確授權** → `revoke from anon`
   ⚠ 這裡沒有任何 RLS policy 呼叫它，所以收掉 `authenticated` 是安全的
     —— 不像 `can()`（policy 運算式用查詢者身分執行，收了會**壞掉**不是擋住）。 */
revoke execute on function public.migi_test_world() from public;
revoke execute on function public.migi_test_world() from anon, authenticated;
grant  execute on function public.migi_test_world() to service_role;


-- ══════════════════════════════════════════════════════
-- ② 門市清單 —— 🎯 這是基石
-- ══════════════════════════════════════════════════════
/* 🎯 **配桌整條路是門市範圍的**（房間屬於門市、桌屬於門市、
   auto-seat 從房間的門市挑桌）⇒ 門市這一層擋住，下游自然分開。
   ⚠ 簽名不變（`p_org_id`），所以 `CREATE OR REPLACE`：不用 DROP、不丟 GRANT。 */
create or replace function public.list_stores_tx(p_org_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_world boolean := public.migi_test_world();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'address', s.address,
      'city', s.city, 'district', s.district,
      'lat', s.lat, 'lng', s.lng,
      'open_time', s.open_time, 'close_time', s.close_time,
      'store_type', s.store_type,
      'phone', s.phone,
      -- 啟用中的桌數（總桌數）
      'tables_total', coalesce(tc.total, 0),
      -- 空桌數：啟用中且目前沒有進行中場次的桌
      -- 尚未建桌的門市回 null（而非 0），讓前端降級成地標圖示，
      -- 不會誤顯示成「滿桌」
      'tables_free', case when coalesce(tc.total, 0) = 0 then null
                          else coalesce(tc.total, 0) - coalesce(tc.busy, 0) end
    ) order by s.city, s.name)
    from stores s
    left join lateral (
      select count(*) as total,
             count(*) filter (
               where exists (
                 select 1 from table_sessions ts
                  where ts.table_id = t.id
                    and ts.status = 'open'
                    and ts.deleted_at is null)) as busy
        from tables t
       where t.store_id = s.id and t.deleted_at is null and t.is_active
    ) tc on true
    where s.org_id = p_org_id and s.is_active = true and s.deleted_at is null
      -- ★ 2026-09-05：只看同一個世界的門市（null ＝ 店員／後台，不濾）
      and (v_world is null or s.is_test = v_world)
  ), '[]'::jsonb);
end $function$;


-- ══════════════════════════════════════════════════════
-- ③ 配桌房間
-- ══════════════════════════════════════════════════════
/* ⚠ 這一層是**保險**不是主要防線 —— 主要防線是 ② ＋ ⑥。
   留著的理由：`p_store` 是參數，前端可以送任何門市 id。
   即使 UI 上看不到，RPC 仍然叫得動（硬規則 5.8：never trust the client）。 */
create or replace function public.list_match_queues_tx(p_org_id uuid, p_member uuid, p_store uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_world boolean := public.migi_test_world();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', q.id, 'store_id', q.store_id, 'stake_level_id', q.stake_level_id,
      'game_type', q.game_type, 'flower', q.flower, 'rounds', q.rounds, 'seats', q.seats,
      'play_at', q.play_at, 'prefs', q.prefs, 'source', q.source, 'tags', q.tags,
      'recurring_id', q.recurring_id, 'recurring_freq', q.recurring_freq,
      'opener', mo.display_name,
      /* ★ 2026-08-29 contract：`players`（數字）已拿掉，只剩 `player_count`。
         同一個 key 兩種形狀是待辦 35 的病，而它已經真的炸過一次。 */
      'player_count', (select count(*) from match_queue_players qp
                        where qp.queue_id = q.id and qp.left_at is null)
    ) order by (q.source='pos') desc, (q.source='recurring') desc, q.play_at asc)
    from match_queues q
    left join members mo on mo.id = q.opened_by
    where q.org_id=p_org_id and q.store_id=p_store and q.status='waiting'
      and (q.expires_at is null or q.expires_at > now())
      and (q.open_at is null or q.open_at <= now())
      -- ★ 2026-09-05：房間的世界由**門市**決定，不由開房的人決定。
      --   🔴 用 `mo.is_test` 會出事：`opened_by` 是 null 的 POS 房間
      --      在 LEFT JOIN 之後是 null，比較結果也是 null ⇒ 整批消失。
      and (v_world is null
           or exists (select 1 from stores s where s.id = q.store_id and s.is_test = v_world))
      and not exists (
        select 1 from match_queue_players qp
        where qp.queue_id=q.id and qp.left_at is null
          and _blocked_between(p_org_id, p_member, qp.member_id))
  ), '[]'::jsonb);
end $function$;


-- ══════════════════════════════════════════════════════
-- ④ 最近同桌
-- ══════════════════════════════════════════════════════
create or replace function public.list_recent_players_tx(p_org_id uuid, p_member uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_world boolean := public.migi_test_world();
begin
  return coalesce((
    select jsonb_agg(distinct jsonb_build_object(
      'id', other.member_id, 'nickname', mm.display_name, 'rank', mm.rank,
      'avatar_url', mm.avatar_url, 'avatar_bear', mm.avatar_bear, 'avatar_source', mm.avatar_source, 'avatar_photo_path', mm.avatar_photo_path
    ))
    from session_players sp
    join session_players other on other.session_id = sp.session_id and other.member_id <> sp.member_id
    join members mm on mm.id = other.member_id and mm.deleted_at is null
      -- ★ 2026-09-05：只看同一個世界的人
      and (v_world is null or mm.is_test = v_world)
    where sp.member_id = p_member and sp.org_id = p_org_id
      and sp.created_at > now() - interval '1 day'
      and not exists (select 1 from mahjong_buddies b
                      where b.member_id = p_member and b.buddy_id = other.member_id and b.deleted_at is null)
      and not exists (select 1 from buddy_invites i
                      where i.inviter_id = p_member and i.invitee_id = other.member_id and i.status = 'pending')
  ), '[]'::jsonb);
end $function$;


-- ══════════════════════════════════════════════════════
-- ⑤ 牌咖清單
-- ══════════════════════════════════════════════════════
create or replace function public.list_buddies_tx(p_org_id uuid, p_member uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_world boolean := public.migi_test_world();
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
      -- ★ 2026-09-05：只看同一個世界的人
      and (v_world is null or m.is_test = v_world)
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


-- ══════════════════════════════════════════════════════
-- ⑥ 🔴 寫入端：不准跨世界開房
-- ══════════════════════════════════════════════════════
/* 這一道才是「真的桌子被佔走」的根因防線。
   ⚠ `opened_by` 是 null（POS 開的房）就放行 —— 那是店員的行為，
     世界由門市決定，沒有人可以跨。
   ⚠ 也不擋「查不出來」的情況（member 或 store 撈不到）——
     那是資料問題不是跨世界，讓既有的外鍵去說話。 */
create or replace function public.trg_match_queues_same_world()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_m boolean; v_s boolean;
begin
  if new.opened_by is null then return new; end if;

  select is_test into v_m from members where id = new.opened_by;
  select is_test into v_s from stores  where id = new.store_id;

  if v_m is not null and v_s is not null and v_m is distinct from v_s then
    raise exception 'cross_world_queue'
      using errcode = '23514',
            detail  = format('會員 is_test=%s，門市 is_test=%s —— 測試世界與正式世界不可互開房', v_m, v_s),
            hint    = '測試帳號請選測試門市；正式客人不會看到測試門市（list_stores_tx 已濾）';
  end if;
  return new;
end $function$;

drop trigger if exists trg_match_queues_same_world on match_queues;
create trigger trg_match_queues_same_world
  before insert on match_queues
  for each row execute function public.trg_match_queues_same_world();


-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
/* ⚠ 整段包在一個會回滾的區塊裡（⑥⑦ 真的會插一列進 `match_queues`）。
   🔴 **`set_config(…, true)` 一律設在 exception 處理器裡**（硬規則 3.9）——
     設在成功路徑上再 `raise`，訊息會跟著被回滾掉，最後印出**空白**。
   📌 plpgsql 的變數不受回滾影響，所以 `v_out` 的內容留得住。 */
do $v$
declare
  v_out text := '';
  v_n int; v_test_line text; v_real_line text;
  v_test_m uuid; v_real_m uuid; v_test_store uuid; v_real_store uuid;
  v_org uuid; v_stake uuid; v_staff_uid uuid;
begin
  select id, line_user_id into v_test_m, v_test_line from members
   where is_test and line_user_id is not null and deleted_at is null
   order by line_user_id limit 1;
  select id, line_user_id into v_real_m, v_real_line from members
   where not is_test and line_user_id is not null and deleted_at is null
   order by created_at limit 1;
  select id into v_test_store from stores where is_test and is_active and deleted_at is null limit 1;
  select id into v_real_store from stores where not is_test and is_active and deleted_at is null limit 1;
  select org_id into v_org from members where id = coalesce(v_test_m, v_real_m);
  /* ⚠ `stake_level_id` 與 `play_at` **沒有預設值**（2026-09-05 查
     `information_schema` 確認）。漏掉的話 ⑥⑦ 會敗在 NOT NULL，
     然後顯示「🟡 被別的錯誤擋下」—— 看起來像有跑，其實什麼都沒驗到。 */
  select id into v_stake from stake_levels order by created_at limit 1;

  /* 🔴 取樣失敗要**出聲**，不要 `if … then` 安靜跳過 ——
     2026-09-04 就發生過「那兩格沒出現而我以為全過」。 */
  if v_test_m is null or v_real_m is null or v_stake is null then
    v_out := v_out || E'\n🔴 取樣失敗' || E'\t' ||
      '測試會員=' || coalesce(v_test_m::text,'無') ||
      '　正式會員=' || coalesce(v_real_m::text,'無') ||
      '　級距=' || coalesce(v_stake::text,'無') ||
      ' —— 下面每一格都不算數，不要當成通過';
    perform set_config('migi.v', v_out, true);
    return;      -- ⚠ 這條路徑沒有 raise，所以訊息留得住
  end if;

  ---- ① 測試身分：只看得到測試門市 ------------------------
  perform set_config('request.jwt.claims', json_build_object(
    'sub', gen_random_uuid()::text, 'role', 'authenticated',
    'app_metadata', json_build_object('line_user_id', v_test_line, 'migi_kind','member'))::text, true);

  select count(*) into v_n
    from jsonb_array_elements(public.list_stores_tx(
           (select org_id from members where id = v_test_m))) e
    join stores s on s.id = (e ->> 'id')::uuid
   where not s.is_test;
  v_out := v_out || E'\n① 測試身分看不到正式門市' || E'\t' ||
    case when v_n = 0 then '✅ 0 間' else '🔴 看到 ' || v_n || ' 間' end;

  ---- ② 🎯 正對照：測試身分**看得到**測試門市 --------------
  /* 🔴 只驗「看不到正式的」的話，一支回空陣列的實作也會綠。 */
  select jsonb_array_length(public.list_stores_tx(
           (select org_id from members where id = v_test_m))) into v_n;
  v_out := v_out || E'\n② 🎯 正對照：測試身分看得到測試門市' || E'\t' ||
    case when v_n > 0 then '✅ ' || v_n || ' 間' else '🔴 0 間 —— 被過度阻擋' end;

  ---- ③ 正式身分：看不到測試門市 --------------------------
  perform set_config('request.jwt.claims', json_build_object(
    'sub', gen_random_uuid()::text, 'role', 'authenticated',
    'app_metadata', json_build_object('line_user_id', v_real_line, 'migi_kind','member'))::text, true);

  select count(*) into v_n
    from jsonb_array_elements(public.list_stores_tx(
           (select org_id from members where id = v_real_m))) e
    join stores s on s.id = (e ->> 'id')::uuid
   where s.is_test;
  v_out := v_out || E'\n③ 正式身分看不到測試門市' || E'\t' ||
    case when v_n = 0 then '✅ 0 間' else '🔴 看到 ' || v_n || ' 間' end;

  ---- ④ 🎯 正對照：正式身分**看得到**正式門市 --------------
  select jsonb_array_length(public.list_stores_tx(
           (select org_id from members where id = v_real_m))) into v_n;
  v_out := v_out || E'\n④ 🎯 正對照：正式身分看得到正式門市' || E'\t' ||
    case when v_n > 0 then '✅ ' || v_n || ' 間' else '🔴 0 間 —— 真客人的門市清單是空的' end;

  ---- ⑤ 🎯 正對照：沒有身分（店員／POS）看得到全部 ---------
  /* fail-open 的方向對不對，只有這一格會說。 */
  perform set_config('request.jwt.claims', '', true);
  select jsonb_array_length(public.list_stores_tx(
           (select org_id from members where id = v_real_m))) into v_n;
  v_out := v_out || E'\n⑤ 🎯 正對照：無身分看得到全部' || E'\t' ||
    case when v_n = (select count(*) from stores where is_active and deleted_at is null and org_id = v_org)
         then '✅ ' || v_n || ' 間（今天的 POS 走 anon）'
         else '🔴 只看到 ' || v_n || ' 間 —— 被誤擋' end;

  ---- ⑤b 🎯 正對照：**店員 session** 也看得到全部 ----------
  /* 🔴 這一格才是真的會出事的那個：POS 登入之後不是 anon 了。
     同一個 LINE 帳號同時是店員與會員 ⇒ 少了 `current_staff()` 那道例外，
     店員會被關進正式世界，**桌況少幾間店而沒有人知道為什麼**。 */
  select u.id into v_staff_uid from auth.users u
   where u.email like 'line-%@staff.migi.invalid' limit 1;

  if v_staff_uid is null then
    v_out := v_out || E'\n⑤b 🎯 正對照：店員看得到全部' || E'\t' || '🔴 取樣失敗：找不到店員 auth user';
  else
    /* ⚠ 店員那條路是 `s.auth_uid = migi_jwt_uuid()`，所以 `sub` 要是
       真的 auth user id，而且**不能帶 `migi_kind: member`**
       —— 帶了就會被 `current_staff()` 排除掉。 */
    perform set_config('request.jwt.claims', json_build_object(
      'sub', v_staff_uid::text, 'role', 'authenticated')::text, true);
    select jsonb_array_length(public.list_stores_tx(v_org)) into v_n;
    v_out := v_out || E'\n⑤b 🎯 正對照：店員 session 看得到全部' || E'\t' ||
      case when v_n = (select count(*) from stores where is_active and deleted_at is null and org_id = v_org)
           then '✅ ' || v_n || ' 間'
           else '🔴 只看到 ' || v_n || ' 間 —— 店員被關進單一世界' end;
  end if;

  perform set_config('request.jwt.claims', '', true);

  ---- ⑥ 觸發器：跨世界開房會被擋 --------------------------
  begin
    insert into match_queues (org_id, store_id, stake_level_id, play_at, opened_by)
    values (v_org, v_real_store, v_stake, now() + interval '2 hours', v_test_m);
    v_out := v_out || E'\n⑥ 跨世界開房被擋' || E'\t' || '🔴 竟然插進去了';
  exception
    when sqlstate '23514' then
      v_out := v_out || E'\n⑥ 跨世界開房被擋' || E'\t' || '✅ 擋住了';
    when others then
      /* ⚠ 被別的錯誤擋下**不算通過** —— 那可能是欄位不足而不是觸發器。 */
      v_out := v_out || E'\n⑥ 跨世界開房被擋' || E'\t' || '🟡 被別的錯誤擋下：' || sqlerrm;
  end;

  ---- ⑦ 🎯 正對照：同世界開房**不被擋** -------------------
  /* 🔴 這一格最重要：只驗 ⑥ 的話，一個「什麼都擋」的觸發器也會全綠，
     而症狀是**所有人都開不了房**。 */
  begin
    insert into match_queues (org_id, store_id, stake_level_id, play_at, opened_by)
    values (v_org, v_test_store, v_stake, now() + interval '2 hours', v_test_m);
    v_out := v_out || E'\n⑦ 🎯 正對照：同世界開房不被擋' || E'\t' || '✅ 通過';
  exception
    when sqlstate '23514' then
      v_out := v_out || E'\n⑦ 🎯 正對照：同世界開房不被擋' || E'\t' || '🔴 被誤擋了';
    when others then
      v_out := v_out || E'\n⑦ 🎯 正對照：同世界開房不被擋' || E'\t' || '🟡 被別的錯誤擋下：' || sqlerrm;
  end;

  ---- ⑧ 輔助函式的授權（兩個方向都要收）------------------
  select count(*) into v_n from pg_proc p
   where p.oid = 'public.migi_test_world()'::regprocedure
     and (exists (select 1 from aclexplode(p.proacl) a
                   where a.grantee = 'anon'::regrole::oid and a.privilege_type='EXECUTE')
       or p.proacl is null
       or exists (select 1 from aclexplode(p.proacl) a
                   where a.grantee = 0 and a.privilege_type='EXECUTE'));
  v_out := v_out || E'\n⑧ migi_test_world 沒有 anon／PUBLIC' || E'\t' ||
    case when v_n = 0 then '✅ 兩個方向都收乾淨' else '🔴 還叫得動' end;

  /* 🔴 整段回滾：⑥⑦ 真的插了一列進 `match_queues`。
     沒有 staging（硬規則 5.7），驗證一律「交易內測試 ＋ 回滾」。 */
  raise exception 'migi_rollback';

exception when others then
  /* 🔴 訊息在這裡才設 —— 設在上面再 raise 的話會被一起回滾掉（硬規則 3.9）。 */
  perform set_config('migi.v',
    v_out || case when sqlerrm <> 'migi_rollback'
                  then E'\n🔴 驗證中斷' || E'\t' || sqlerrm
                  else '' end, true);
end $v$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(coalesce(current_setting('migi.v', true), ''), E'\n')) as x
 where coalesce(x, '') <> '';
