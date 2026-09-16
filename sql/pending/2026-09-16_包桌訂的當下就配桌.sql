/* 包桌：訂的當下就配桌，牌規與積分也一起決定
   2026-09-16

   ── 為什麼 ─────────────────────────────────────────
   成功畫面的桌號那一列**不再寫「到店由櫃檯安排」**（使用者 2026-09-16）——
   要印真的桌號（A3）。而同一天定了第二件事：
   **牌規與積分在預約時就決定**，不是到店才喬。

   🔴 「訂的當下就配」是使用者選的（另一個選項是「開打前 30 分鐘才配」）。
     代價他知道：三個月後的預約從今天就綁住那張桌，店裡的彈性變小。

   ── 這一份做什麼 ───────────────────────────────────
   ① `bookings` 加三欄  `game_type` / `flower` / `stake_level_id`
   ② `_booking_pick_table`  那個時段還沒被別的預約佔住的桌，挑一張
   ③ `_booking_capacity`    改成**數桌**，不再是 `sum(table_count)`
   ④ `create_booking_tx`    改簽名（多三個參數）＋ 建立時就寫 `table_id`

   ── 🔴 刻意不做：與配桌的實體桌互斥 ───────────────
   今天兩套**各算各的**：
   ```
   包桌算「容量」   sum(bookings.table_count)
   配桌算「實體桌」 那張桌有沒有 open 的 table_sessions
   ```
   這一份只讓**包桌內部**一致（桌號與容量從此是同一件事），
   **沒有**讓配桌看見包桌佔的桌、也沒有讓包桌避開配桌正在用的桌。

   ⚠ 那不是漏掉，是**還缺一個決定**：配桌開的 `table_sessions` 沒有結束時間，
     所以「配桌的一桌算佔多久」今天答不出來。
     沒有那個答案，互斥會變成「晚上的預約永遠撞到現場的桌」。
   ⇒ 互斥單獨一份，決定了時長怎麼算再做。這一份不要一次改兩套。

   ── ⚠ 只有一桌的預約才自動配 ───────────────────────
   `bookings` 只有**一個** `table_id` 欄位，而 `table_count` 允許 1–10。
   ⇒ `table_count > 1` 時**不配桌**（`table_id` 留 null），畫面顯示
     「當天為你安排」。會員 App 固定訂一桌（`tables = 1`），
     所以實務上一定配得到；多桌是 POS 替客人訂的情況。
   🔴 要讓多桌也有桌號，正解是另開一張 `booking_tables`，不是把
     `table_id` 塞成陣列 —— 那會變成「一個欄位兩種形狀」
     （這個專案記過七次的病）。

   ── 資料 ───────────────────────────────────────────
   `bookings` 現在只有 1 筆而且是 `cancelled` ⇒ **不用回填**。
   （查過：booked 0 筆、seated 0 筆。） */

-- ① ────────────────────────────────────────────────
/* 三個新欄位。型別與 CHECK **逐字照抄 `match_queues`** ——
   同一件事（這局怎麼打）在兩張表要長得一樣，不然日後合併報表會踩到。
   ⚠ 全部可空：舊資料沒有值，而 POS 替客人訂時也可能先不填。 */
alter table public.bookings
  add column if not exists game_type      text,
  add column if not exists flower         text,
  add column if not exists stake_level_id uuid references public.stake_levels(id);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'bookings_game_type_chk') then
    alter table public.bookings add constraint bookings_game_type_chk
      check (game_type is null or game_type = any (array['台麻','美麻']));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'bookings_flower_chk') then
    alter table public.bookings add constraint bookings_flower_chk
      check (flower is null or flower = any (array['無花','有花']));
  end if;
end $$;

comment on column public.bookings.game_type      is '牌規：台麻／美麻。預約時就決定（2026-09-16），不是到店才喬。';
comment on column public.bookings.flower         is '花牌：無花／有花。同 game_type。';
comment on column public.bookings.stake_level_id is '積分級距。⚠ 級距是跟著門市走的（list_stakes_tx 吃 store_id）—— 換門市要重選。';

/* 查「那個時段有哪些桌被佔」會用到。 */
create index if not exists ix_bookings_table_window
  on public.bookings (store_id, table_id, play_at)
  where status = 'booked' and table_id is not null;

-- ② ────────────────────────────────────────────────
/* 挑一張那個時段沒被別的預約佔住的桌。
   🔴 `for update ... skip locked` 是必要的：兩個人同時訂同一個時段時，
     少了它兩筆會拿到同一張桌，而**不會有任何錯誤**。
     （寫法照抄配桌的 `_try_auto_seat_tx`，不要發明第二種。）
   ⚠ 只挑 `auto_assign = true` 的桌 —— 留給現場客人的那些不能被預約吃掉。
   ⚠ `p_exclude` 給改期用：算自己的新時段時要把自己排除掉。 */
create or replace function public._booking_pick_table(
  p_store_id uuid,
  p_play_at  timestamptz,
  p_hours    int,
  p_exclude  uuid default null
) returns uuid
language sql
volatile
as $$
  select t.id
    from public.tables t
   where t.store_id = p_store_id
     and coalesce(t.is_active, true) = true
     and t.deleted_at is null
     and t.auto_assign = true
     and not exists (
       select 1 from public.bookings k
        where k.table_id = t.id
          and k.status = 'booked'
          and (p_exclude is null or k.id <> p_exclude)
          and p_play_at < k.play_at + make_interval(hours => k.planned_hours)
          and k.play_at < p_play_at + make_interval(hours => p_hours))
   order by t.sort_order nulls last, t.label
   limit 1
   for update of t skip locked;
$$;

comment on function public._booking_pick_table(uuid, timestamptz, int, uuid) is
  '包桌自動配桌：那個時段沒被別的預約佔住、且 auto_assign 的桌，挑一張。⚠ 今天不看配桌的 table_sessions，見 2026-09-16 那份 SQL 的檔頭。';

-- ③ ────────────────────────────────────────────────
/* 容量改成**數桌**。
   🔴 舊版是 `sum(table_count)` —— 那與「哪一張桌」完全脫鉤，
     於是同一件事有兩個答案（容量說還有 3 張、而桌號那一欄是空的）。
     現在配了桌之後，容量就是「有幾張桌被佔」，**同一件事一個答案**。
   ⚠ 但**還沒配到桌的預約也要算**（`table_count > 1` 那種，或日後
     改成開打前才配時的空窗）⇒ 兩段相加：
     · 配了桌的 → 數 distinct table_id
     · 沒配桌的 → 照舊 sum(table_count)
   🔴 少了第二段，多桌的預約會完全不佔容量，而那是超賣。 */
create or replace function public._booking_capacity(
  p_store_id uuid,
  p_play_at  timestamptz,
  p_hours    int,
  p_exclude  uuid default null
) returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'total',  t.total,
    'booked', b.seated + b.loose,
    'free',   greatest(0, t.total - b.seated - b.loose))
  from (
    select count(*)::int as total
      from public.tables
     where store_id = p_store_id and is_active and deleted_at is null
  ) t,
  (
    select
      count(distinct k.table_id) filter (where k.table_id is not null)::int as seated,
      coalesce(sum(k.table_count) filter (where k.table_id is null), 0)::int as loose
      from public.bookings k
     where k.store_id = p_store_id
       and k.status = 'booked'
       and (p_exclude is null or k.id <> p_exclude)
       and p_play_at < k.play_at + make_interval(hours => k.planned_hours)
       and k.play_at < p_play_at + make_interval(hours => p_hours)
  ) b;
$$;

-- ④ ────────────────────────────────────────────────
/* 改簽名 ⇒ **先 DROP**（硬規則 2），而 DROP 會把 GRANT 一起帶走
   ⇒ 檔尾一定要補回去。 */
drop function if exists public.create_booking_tx(uuid, timestamptz, integer, integer, uuid, integer, text);

create or replace function public.create_booking_tx(
  p_store_id uuid, p_play_at timestamptz, p_hours integer,
  p_table_count integer default 1, p_team_id uuid default null,
  p_party_size integer default null, p_note text default null,
  /* 🔴 新參數放**最後面**並給預設值 ⇒ expand-safe：
     前端還沒部署也叫得動，不會在部署順序上卡住。 */
  p_game_type text default null, p_flower text default null,
  p_stake_level_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_me    uuid := public.current_member_id();
  v_org   uuid := public.current_org_id();
  v_cap   jsonb;
  v_id    uuid;
  v_name  text;
  v_tbl   uuid;
  v_label text;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_hours not in (2, 5, 24) then
    return jsonb_build_object('ok', false, 'reason', 'bad_hours', 'message', '時長只能選 2、5 或 24 小時');
  end if;
  if coalesce(p_table_count, 1) < 1 or p_table_count > 10 then
    return jsonb_build_object('ok', false, 'reason', 'bad_count', 'message', '桌數請填 1 到 10');
  end if;
  /* ⚠ 兩個新值照 `match_queues` 的允許值擋，訊息講人話不講欄位名。 */
  if p_game_type is not null and p_game_type not in ('台麻', '美麻') then
    return jsonb_build_object('ok', false, 'reason', 'bad_game_type', 'message', '牌規只能選台麻或美麻');
  end if;
  if p_flower is not null and p_flower not in ('無花', '有花') then
    return jsonb_build_object('ok', false, 'reason', 'bad_flower', 'message', '花牌只能選無花或有花');
  end if;

  /* 🔴 兩道時間牆，兩個不同的理由：
     · 太近 —— 店員來不及看到那筆預約，客人到了櫃檯還是要現場處理，
       而畫面已經跟他說「預約成功」了。**那是一個做不到的承諾。**
     · 太遠 —— 三個月後的事誰都說不準，而它會一路佔著容量。 */
  if p_play_at is null or p_play_at < now() + interval '30 minutes' then
    return jsonb_build_object('ok', false, 'reason', 'too_soon',
                              'message', '請至少提前 30 分鐘預約，現在要用請直接到櫃檯');
  end if;
  if p_play_at > now() + interval '90 days' then
    return jsonb_build_object('ok', false, 'reason', 'too_far', 'message', '最多只能預約 90 天內');
  end if;

  select s.name into v_name from public.stores s
   where s.id = p_store_id and s.org_id = v_org and s.deleted_at is null;
  if v_name is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_store', 'message', '找不到那間門市');
  end if;

  /* ⚠ 積分級距**必須屬於這間門市** —— 少了這道，前端換了門市卻沒重選級距時，
     會訂出一個那間店根本沒有的積分。 */
  if p_stake_level_id is not null and not exists (
       select 1 from public.stake_levels sl
        where sl.id = p_stake_level_id and sl.store_id = p_store_id) then
    return jsonb_build_object('ok', false, 'reason', 'bad_stake',
                              'message', '那個積分級距不屬於這間門市');
  end if;

  /* 掛團的話，**我必須在那個團裡** —— 不然任何人都能用別人的團名訂位，
     而帳算在那個團頭上。 */
  if p_team_id is not null and not exists (
       select 1 from public.team_members tm
        join public.teams t on t.id = tm.team_id and t.deleted_at is null
       where tm.team_id = p_team_id and tm.member_id = v_me and tm.left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'not_member', 'message', '你不在那個牌咖團裡');
  end if;

  perform public._booking_expire(p_store_id);

  /* 🔴 同一組人同一個時段不要重複訂。
     判準是「同一個團」，沒有團就退回「同一個人」——
     而那正是 `team_id` 可空所帶來的兩種身分。 */
  if exists (
       select 1 from public.bookings k
        where k.store_id = p_store_id and k.status = 'booked'
          and (case when p_team_id is not null then k.team_id = p_team_id
                    else k.team_id is null and k.member_id = v_me end)
          and p_play_at < k.play_at + make_interval(hours => k.planned_hours)
          and k.play_at < p_play_at + make_interval(hours => p_hours)) then
    return jsonb_build_object('ok', false, 'reason', 'already_booked',
                              'message', '這個時段你已經有一筆預約了');
  end if;

  v_cap := public._booking_capacity(p_store_id, p_play_at, p_hours);
  if (v_cap->>'free')::int < p_table_count then
    return jsonb_build_object('ok', false, 'reason', 'no_capacity',
                              'message', '這個時段已經約滿了，換個時間試試');
  end if;

  /* 🔴 **訂的當下就配桌**（使用者 2026-09-16）。
     ⚠ 只有一桌才配 —— `bookings` 只有一個 `table_id` 欄位（見檔頭）。
     ⚠ 容量剛才已經確認夠了，所以正常情況一定挑得到；
       挑不到只會發生在「那一瞬間被別人拿走」，那時**不要失敗**，
       留 null 就好 —— 客人的預約仍然成立，桌號當天再安排。
       🎯 為了一個顯示用的欄位讓整筆預約失敗，是把次要的事當成主要的。 */
  if coalesce(p_table_count, 1) = 1 then
    v_tbl := public._booking_pick_table(p_store_id, p_play_at, p_hours);
  end if;

  insert into public.bookings (org_id, store_id, team_id, member_id,
                               play_at, planned_hours, table_count, party_size, note,
                               table_id, game_type, flower, stake_level_id)
  values (v_org, p_store_id, p_team_id, v_me,
          p_play_at, p_hours, coalesce(p_table_count, 1), p_party_size,
          nullif(btrim(coalesce(p_note, '')), ''),
          v_tbl, p_game_type, p_flower, p_stake_level_id)
  returning id into v_id;

  select tb.label into v_label from public.tables tb where tb.id = v_tbl;

  return jsonb_build_object('ok', true, 'booking_id', v_id, 'store_name', v_name,
                            'table_label', v_label,
                            'message', '已預約 ' || v_name);
end $$;

comment on function public.create_booking_tx(uuid, timestamptz, integer, integer, uuid, integer, text, text, text, uuid) is
  '建立包桌預約。2026-09-16：訂的當下就配桌（只有一桌時），並記下牌規／花牌／積分級距。';

/* 🔴 DROP 帶走了 GRANT，補回來。照同一族的三支：DEFINER ＋ 只給 authenticated。 */
revoke execute on function public.create_booking_tx(uuid, timestamptz, integer, integer, uuid, integer, text, text, text, uuid) from public;
revoke execute on function public.create_booking_tx(uuid, timestamptz, integer, integer, uuid, integer, text, text, text, uuid) from anon;
grant  execute on function public.create_booking_tx(uuid, timestamptz, integer, integer, uuid, integer, text, text, text, uuid) to authenticated;

revoke execute on function public._booking_pick_table(uuid, timestamptz, int, uuid) from public;
revoke execute on function public._booking_pick_table(uuid, timestamptz, int, uuid) from anon, authenticated;

/* ⑤ 讀回預約時要看得到新欄位。`list_my_bookings_tx` 與 `pos_list_bookings_tx`
   的簽名都沒變 ⇒ `CREATE OR REPLACE` 不會掉 GRANT。
   ⚠ 這一份**不改它們** —— 先把寫入端做好，讀取端等前端真的要顯示時一起改，
     那時才知道要回哪些鍵。硬規則：不要先建沒人讀的東西。 */

-- ── 驗證（硬規則 1.8：這一份要留下 DDL ⇒ 一個字都不准 raise）─────
do $$
declare
  v_msg   text := '';
  v_store uuid;
  v_n     int;
  v_cap   jsonb;
  v_tbl   uuid;
begin
  -- ① 三個欄位與兩道 CHECK
  select count(*) into v_n from information_schema.columns
   where table_schema='public' and table_name='bookings'
     and column_name in ('game_type','flower','stake_level_id');
  v_msg := v_msg || case when v_n = 3
    then '✅ ① 三個欄位都在' else '🔴 ① 只有 ' || v_n || ' 個欄位' end;
  select count(*) into v_n from pg_constraint
   where conname in ('bookings_game_type_chk','bookings_flower_chk');
  v_msg := v_msg || E'\n' || case when v_n = 2
    then '✅ ② 兩道 CHECK 都在（值與 match_queues 逐字相同）'
    else '🔴 ② 只有 ' || v_n || ' 道 CHECK' end;

  -- ③ create_booking_tx：版本數要是 1（改簽名最怕留下多載）
  select count(*) into v_n from pg_proc
   where pronamespace='public'::regnamespace and proname='create_booking_tx';
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '✅ ③ create_booking_tx 只有一個版本（沒有留下舊簽名）'
    else '🔴 ③ 有 ' || v_n || ' 個版本 —— 舊簽名沒被 DROP 掉' end;

  -- ④ GRANT 補回來了沒（DROP 會帶走）
  v_msg := v_msg || E'\n' || coalesce(
    (select case when authed and not anon_x and not pub
                 then '✅ ④ 授權 authenticated ✓ · anon ✗ · PUBLIC ✗'
                 else '🔴 ④ authenticated=' || authed || ' anon=' || anon_x || ' PUBLIC=' || pub end
       from (select
          exists (select 1 from aclexplode(p.proacl) a
                   where a.grantee='authenticated'::regrole::oid and a.privilege_type='EXECUTE') as authed,
          exists (select 1 from aclexplode(p.proacl) a
                   where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE') as anon_x,
          (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                   where a.grantee=0 and a.privilege_type='EXECUTE')) as pub
        from pg_proc p
       where p.pronamespace='public'::regnamespace and p.proname='create_booking_tx') q),
    '🔴 ④ 查不到授權');

  -- ⑤ 真的挑一張桌（走內部那一支，SQL Editor 沒有會員身分）
  select id into v_store from public.stores where code='S01' and deleted_at is null;
  v_tbl := public._booking_pick_table(v_store, now() + interval '2 days', 5);
  v_msg := v_msg || E'\n' || coalesce(
    '✅ ⑤ 高雄自由店 後天 打 5 小時 → 配到 '
      || (select tb.label from public.tables tb where tb.id = v_tbl),
    '🔴 ⑤ 挑不到桌（那間店 14 張桌應該都是空的）');

  -- ⑥ 容量：沒有任何預約時 free 要等於 total
  v_cap := public._booking_capacity(v_store, now() + interval '2 days', 5);
  v_msg := v_msg || E'\n' || case
    when (v_cap->>'free')::int = (v_cap->>'total')::int
    then '✅ ⑥ 沒有預約時 free = total = ' || (v_cap->>'total')
    else '🔴 ⑥ total=' || (v_cap->>'total') || ' free=' || (v_cap->>'free')
         || ' —— 沒有預約卻算出有人佔' end;

  -- ⑦ 🔴 正對照：0 桌的門市要挑不到桌，而且 total 是 0
  select id into v_store from public.stores where code='S03' and deleted_at is null;
  v_cap := public._booking_capacity(v_store, now() + interval '2 days', 5);
  v_msg := v_msg || E'\n' || case
    when public._booking_pick_table(v_store, now() + interval '2 days', 5) is null
     and (v_cap->>'total')::int = 0
    then '✅ ⑦ 0 桌的門市（MAYU 苓雅館）挑不到桌、total = 0'
    else '🔴 ⑦ 0 桌的門市竟然挑得到桌，或 total 不是 0' end;

  -- ⑧ 內部那兩支不可以被前端叫到
  v_msg := v_msg || E'\n' || coalesce(
    (select case when count(*) = 0
                 then '✅ ⑧ _booking_pick_table 沒有授權給 anon／authenticated／PUBLIC'
                 else '🔴 ⑧ 有 ' || count(*) || ' 個角色叫得動它' end
       from pg_proc p, aclexplode(p.proacl) a
      where p.pronamespace='public'::regnamespace and p.proname='_booking_pick_table'
        and a.privilege_type='EXECUTE'
        and (a.grantee = 0 or a.grantee in ('anon'::regrole::oid, 'authenticated'::regrole::oid))),
    '✅ ⑧ _booking_pick_table 沒有任何授權');

  -- ⑨ 還沒做的那一半（下一份）
  v_msg := v_msg || E'\n'
    || '⏳ ⑨ 與配桌的實體桌**還沒互斥** —— 包桌看不到 table_sessions，'
    || '配桌也看不到 bookings 佔的桌。要做之前先決定「配桌的一桌算佔多久」。';

  perform set_config('migi.booking_table', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.booking_table', true), ''), '🔴 沒有訊息') as "驗證";
