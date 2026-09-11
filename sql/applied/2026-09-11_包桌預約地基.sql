/* ============================================================
   包桌預約：一張表 ＋ 容量判定的唯一定義
   2026-09-11 · 使用者：「牌咖團最重要的功能就是預約包桌，這是首要」

   ⚠ 這份只建結構與判定，RPC 在下一份。理由同牌咖團那三批：
     **先讓容量判定被實際跑過一次**，再把函式疊上去。
   ⚠ 要留下東西 ⇒ 整份不准 `raise`（硬規則 1.8）。
     行為測試在 `sql/checks/2026-09-11_驗包桌容量判定.sql`。

   ── 🔴 先更正我自己文件裡寫得不準的一句 ─────────────
   `牌咖團與包桌.md` 寫「接上 `list_tables_tx` 既有的 `is_hold`」。
   撈過那支之後，那句話**只對一半** —— 它的 `hold_kind` 只有兩個值
   （配桌佔的、店員開了還沒結帳），**兩個都是「現在就佔住這張桌」**。

   🔴 而預約**不可以一建立就綁死一張桌**：
   ```
   自動帶桌「湊滿就佔桌」已經會空等兩小時（待辦 34 記過）
   而預約可以提前好幾天 ⇒ 同一個問題乘以幾十倍
   ```
   ⇒ **預約先佔的是「容量」不是某一張桌。**
     當天客人到了，店員才指定桌 —— 餐廳訂位也是這樣，
     訂的是幾桌不是七號桌。
   📌 所以 `table_id` 可空，而 `hold_kind` 要不要多一個值，
     是**指定桌之後**的事，留給下一份。

   ── 🔴 `team_id` 可空，那是刻意的 ────────────────────
   沒有團的客人打電話來訂位**一定會發生**，而系統做不到的時候
   櫃檯就會另外發明一套（紙本、LINE 訊息、店長的腦袋）。
   ⇒ **一個預約機制，牌咖團只是它的入口之一。**
   ⚠ 反過來說也成立：這張表不叫 `team_bookings`。

   ── 🔴 容量判定刻意**不管現在有沒有人在打** ──────────
   它只回答「這個時段**還答應得起幾桌**」，算式是：
   ```
   店裡可用的桌數  −  同時段其他預約已經佔走的桌數
   ```
   ⚠ **不扣掉現在正在打的桌**，那是刻意的：
     現場客人幾點走沒有人知道，把一個猜測算進去會讓系統
     **用一個假的精確度拒絕真的預約**。
   🎯 這道牆要防的是「**同一個時段答應了兩組人**」，
     現場滿不滿是店員當下的判斷，不是這支函式的工作。
   📌 那個取捨要寫在畫面上（「已接受的預約」不是「保證有位」），
     不要讓客人以為系統替他保留了一張實體桌。
   ============================================================ */


/* ─────────────────────────────────────────────────────────
   ① bookings
   ───────────────────────────────────────────────────────── */
create table if not exists public.bookings (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.orgs(id),
  store_id      uuid not null references public.stores(id),

  /* 可空：沒有團的客人也要訂得到（見檔頭）。 */
  team_id       uuid references public.teams(id),
  /* 訂的人。⚠ 不是「團長」—— 任何團員都可以訂，
     而取消由**訂的人或團長**做（那道判斷在 RPC 裡）。 */
  member_id     uuid not null references public.members(id),

  play_at       timestamptz not null,
  /* 🔴 只收 2 / 5 / 24，對齊既有的三支包桌商品
     （`SVC-TBL-P02` 100 元／`P05` 150／`P24` 200，**單人計價**）。
     ⚠ 這裡存的是**時長級距不是價格** —— 價格一律結帳時查主檔
       （待辦 2：前端只送意圖不送事實）。 */
  planned_hours int  not null,
  table_count   int  not null default 1,
  /* 大約幾人。可空 —— 客人常常訂的時候還不確定。
     ⚠ 它是**給店家備料的參考**，不是計價依據，所以不設 NOT NULL。 */
  party_size    int,
  note          text,

  status        text not null default 'booked',

  /* 當天才填。🔴 建立時**不指定桌**，理由見檔頭。 */
  table_id          uuid references public.tables(id),
  seated_session_id uuid references public.table_sessions(id),

  cancelled_reason    text,
  /* 櫃檯代訂時記是誰接的。⚠ 值由 `current_staff()` 解析，
     **不接受前端指定**（同 2026-09-04 那批：身分不可以由呼叫端宣告）。 */
  created_by_staff_id uuid references public.staff(id),

  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'bookings_hours_check') then
    alter table public.bookings add constraint bookings_hours_check
      check (planned_hours in (2, 5, 24));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'bookings_table_count_check') then
    /* 上限 10 是防手滑不是產品規則 —— 最大的店只有 14 桌，
       而「訂 500 桌」應該在寫進去之前就被擋住。 */
    alter table public.bookings add constraint bookings_table_count_check
      check (table_count between 1 and 10);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'bookings_party_size_check') then
    alter table public.bookings add constraint bookings_party_size_check
      check (party_size is null or party_size between 1 and 80);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'bookings_status_check') then
    /* ⚠ 五個值講的是五件**不同**的事，不要合併：
       `cancelled` 是客人自己取消、`no_show` 是他沒出現、
       `expired` 是系統過了時間自動收掉。
       合成一個的話，日後想知道「爽約率」就永遠算不出來 ——
       而那正是要不要收訂金的依據。 */
    alter table public.bookings add constraint bookings_status_check
      check (status in ('booked', 'seated', 'cancelled', 'no_show', 'expired'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'bookings_seated_shape_check') then
    /* 帶到桌了就一定要有那張桌。少了這道，`seated` 而 `table_id` 是 null
       的列會長出來，而那種列在日後對帳時答不出「他坐哪」。 */
    alter table public.bookings add constraint bookings_seated_shape_check
      check (status <> 'seated' or table_id is not null);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'bookings_cancel_shape_check') then
    alter table public.bookings add constraint bookings_cancel_shape_check
      check (status <> 'cancelled' or cancelled_reason is not null);
  end if;
end $$;

/* 容量判定會一直查「某店某時段還活著的預約」，這是它的索引。 */
create index if not exists ix_bookings_store_time
  on public.bookings (store_id, play_at) where status = 'booked';
create index if not exists ix_bookings_member
  on public.bookings (member_id, play_at desc);
create index if not exists ix_bookings_team
  on public.bookings (team_id, play_at desc) where team_id is not null;

/* 🎯 RLS 開啟、0 條 policy —— 這個系統裡最安全的狀態。
   所有存取走 SECURITY DEFINER 的 RPC，前端永遠不直接查這張表。 */
alter table public.bookings enable row level security;


/* ─────────────────────────────────────────────────────────
   ② 🔴 容量判定：整個系統只有這一份
   ───────────────────────────────────────────────────────── */
/* 回 `{ total, booked, free }`。
   ```
   total   這間店現在可用的桌數（is_active 且未刪除）
   booked  同時段其他「還活著的預約」已經佔走的桌數
   free    兩者相減，可以再答應幾桌
   ```

   ⚠ **區間重疊的判準只有一種寫法**，而它很容易寫錯：
   ```
   [a, a+ha) 與 [b, b+hb) 重疊  ⇔  a < b+hb  且  b < a+ha
   ```
   🔴 寫成「開始時間在區間內」會漏掉**包住**的那一種
     （別人 10:00 訂 24 小時，你 14:00 訂 2 小時 —— 開始時間不在
      任何人的「開始」附近，但它整段都被包著）。

   ⚠ `p_exclude` 是給「改自己的預約」用的：算容量時要把自己那一筆
     扣掉，否則他會跟自己撞而且看不出原因。 */
create or replace function public._booking_capacity(p_store_id uuid,
                                                    p_play_at  timestamptz,
                                                    p_hours    int,
                                                    p_exclude  uuid default null)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'total',  t.total,
    'booked', b.taken,
    'free',   greatest(0, t.total - b.taken))
  from (
    select count(*)::int as total
      from public.tables
     where store_id = p_store_id and is_active and deleted_at is null
  ) t,
  (
    select coalesce(sum(k.table_count), 0)::int as taken
      from public.bookings k
     where k.store_id = p_store_id
       and k.status = 'booked'
       and (p_exclude is null or k.id <> p_exclude)
       and p_play_at < k.play_at + make_interval(hours => k.planned_hours)
       and k.play_at < p_play_at + make_interval(hours => p_hours)
  ) b;
$$;

revoke execute on function public._booking_capacity(uuid, timestamptz, int, uuid) from public;
revoke execute on function public._booking_capacity(uuid, timestamptz, int, uuid) from anon, authenticated;


/* ============================================================
   驗證（唯讀，不准 raise）
   ⚠ 行為測試（真的建幾筆預約、看容量掉下來）在
     `sql/checks/2026-09-11_驗包桌容量判定.sql`。
   ============================================================ */
do $$
declare
  v_msg   text := '';
  v_n     int;
  v_store uuid;
  v_name  text;
  v_r     jsonb;
  v_ok    int;
begin
  /* ① 表建立了 */
  select count(*) into v_n from information_schema.tables
   where table_schema = 'public' and table_name = 'bookings';
  v_msg := v_msg || case when v_n = 1 then '① ✅ bookings 建好了' else '① 🔴 表沒有建出來' end;

  /* ② CHECK 六條
     算式：時長 ＋ 桌數 ＋ 人數 ＋ 狀態 ＋ 帶桌形狀 ＋ 取消形狀 ＝ 6 */
  select count(*) into v_n
    from pg_constraint c join pg_class r on r.oid = c.conrelid
   where c.contype = 'c' and r.relname = 'bookings';
  v_msg := v_msg || E'\n' || case when v_n = 6
    then '② ✅ CHECK 6 條（時長／桌數／人數／狀態／帶桌形狀／取消形狀）'
    else '② 🔴 CHECK ' || v_n || ' 條，預期 6' end;

  /* ③ RLS 開了且零 policy —— 兩件事要一起驗 */
  select count(*) into v_n from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname = 'public' and c.relname = 'bookings' and c.relrowsecurity;
  select count(*) into v_ok from pg_policies where schemaname = 'public' and tablename = 'bookings';
  v_msg := v_msg || E'\n' || case when v_n = 1 and v_ok = 0
    then '③ ✅ RLS 開著且 0 條 policy（完全鎖死，只有 DEFINER 進得去）'
    else '③ 🔴 RLS ' || v_n || '，policy ' || v_ok || ' 條（預期 1 與 0）' end;

  /* ④ 容量判定**實際跑一次**（硬規則 7），而且用真的門市。
     🔴 挑「有桌位的那一間」不要挑第一間 —— 七間裡有五間 0 桌，
       挑到那種的話這一格會印 total 0，看起來像函式壞了。 */
  select t.store_id, s.name into v_store, v_name
    from public.tables t join public.stores s on s.id = t.store_id
   where t.is_active and t.deleted_at is null
   group by t.store_id, s.name
   order by count(*) desc
   limit 1;

  if v_store is null then
    v_msg := v_msg || E'\n④ 🔴 找不到任何有桌位的門市 —— 這一格測不了，而測不了不等於通過';
  else
    v_r := public._booking_capacity(v_store, now() + interval '1 day', 5);
    v_msg := v_msg || E'\n④ ✅ 容量判定跑得動 · ' || v_name
          || '　總桌數 ' || (v_r->>'total')
          || '　已預約 ' || (v_r->>'booked')
          || '　可再接 ' || (v_r->>'free');
  end if;

  /* ⑤ 🔴 重疊判準的正對照 —— 這一格才是整份的重點。
     今天 bookings 是空的，所以 ④ 一定回「已預約 0」，
     而**「回 0」同時是「正確」與「判準寫壞了」的症狀**（硬規則 3.55）。
     ⇒ 用假資料把四種相對位置都跑一次，看它分不分得出來。 */
  select count(*) into v_ok
    from (values
      ('完全相同',        timestamptz '2026-10-01 19:00+08', 2, true),
      ('被整個包住',      timestamptz '2026-10-01 10:00+08', 24, true),
      ('尾巴碰到頭',      timestamptz '2026-10-01 17:00+08', 2, false),
      ('頭碰到尾巴',      timestamptz '2026-10-01 21:00+08', 2, false),
      ('差一分鐘重疊',    timestamptz '2026-10-01 17:01+08', 2, true),
      ('完全不相干',      timestamptz '2026-10-02 19:00+08', 2, false)
    ) as c(what, at, hrs, want)
   where (timestamptz '2026-10-01 19:00+08' < c.at + make_interval(hours => c.hrs)
          and c.at < timestamptz '2026-10-01 19:00+08' + make_interval(hours => 2)) = c.want;
  v_msg := v_msg || E'\n' || case when v_ok = 6
    then '⑤ ✅ 重疊判準六種相對位置全部判對（含「被整個包住」與「剛好碰到不算重疊」）'
    else '⑤ 🔴 六種裡只判對 ' || v_ok || ' 種 —— 重疊算錯會讓同一個時段答應兩組人' end;

  /* ⑥ 授權：容量判定是內部的，前端不可以叫得到 */
  select count(*) into v_n
    from pg_proc p left join lateral aclexplode(p.proacl) a on true
   where p.pronamespace = 'public'::regnamespace and p.proname = '_booking_capacity'
     and (a.grantee = 'anon'::regrole::oid or a.grantee = 0
          or a.grantee = 'authenticated'::regrole::oid)
     and a.privilege_type = 'EXECUTE';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '⑥ ✅ _booking_capacity 前端叫不到'
    else '⑥ 🔴 內部函式被授權出去了（' || v_n || ' 筆）' end;

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
