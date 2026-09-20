-- ============================================================
-- 階段 1 收尾：其餘 10 個成就事件 —— 7 個觸發器，不改任何既有函式
-- 2026-09-20
--
-- 🎯 **本來要改 8 支函式，查證之後改成觸發器。** 決定性的那一筆：
--    寫 `team_members` 的函式有 **4 支**
--    （apply_team_tx / create_team_tx / invite_to_team_tx / respond_team_request_tx）
--    而對照表只記了 respond_team_request_tx 一支
--    ⇒ 改函式的話，**另外三條入團路徑永遠不會發事件，而且不報錯**。
--    觸發器掛在表上，一次涵蓋全部入口（同 2026-09-20 餐飲與儲值那一批）。
--
-- | 事件 | 掛哪 | 成就 |
-- |---|---|---|
-- | member_registered ＋ title_granted | members AFTER INSERT      | 01 · 13 |
-- | rank_placed                        | members AFTER UPDATE rank | 26 |
-- | snack_granted / snack_consumed     | snack_grants              | 16 · 17 |
-- | team_created                       | teams                     | 21 |
-- | team_joined                        | team_members              | 22 |
-- | like_given ＋ like_received        | member_likes              | 23 · 24 |
-- | buddy_added                        | mahjong_buddies           | 25 |
--
-- 🔴 每一支都**自己吞例外** —— 觸發器沒有呼叫端能包它，
--    不吞的話「成就寫入失敗」會回滾掉註冊／按讚／入團本身。
-- 🔴 驗證段一個字都不准 raise（硬規則 1.8，這份要留下觸發器）。
--    造樣本測行為在 `sql/checks/2026-09-20_驗其餘10個成就事件.sql`。
-- ============================================================

-- ---------- ① members：註冊（member_registered ＋ title_granted）----------
-- ⚠ 只有 INSERT。`register_member_tx` 的 'rebound'／'existing_line' 兩條路
--   走的是 UPDATE ⇒ 天生排除，不用寫條件。
--   （2019 年的老客人在換 LINE 那天拿到「新手報到」正是要避免的。）
create or replace function public.trg_members_achievements()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  begin
    perform public.fire_event_tx(new.id, 'member_registered', 1, null,
                                 'reg:' || new.id::text);
    -- 🔴 稱號是**註冊預設就有**（2026-09-20 拍板，members.title NOT NULL
    --    DEFAULT '新手上路'）⇒ 與註冊是同一個時刻。
    --    條件寫出來不是多餘：日後若拿掉 DEFAULT，這裡會自己停下來。
    if coalesce(new.title, '') <> '' then
      perform public.fire_event_tx(new.id, 'title_granted', 1, null,
                                   'reg:' || new.id::text);
    end if;
  exception when others then null;
  end;
  return null;
end $$;

-- ---------- ② members：第一次拿到段位 ----------
-- 🎯 判準是**從 null 變成有值**，不是「rank 變了」——
--    升等（銅牌熊 III → II）不該再發一次「取得正式段位」。
-- 📌 members.rank 是 nullable 且**沒有預設** ⇒ 新會員一定是 null，
--    要等 apply_session_rounds_tx 跑完定位賽才第一次寫進去。
create or replace function public.trg_members_rank_achievements()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  begin
    perform public.fire_event_tx(new.id, 'rank_placed', 1, null,
                                 'rank:' || new.id::text);
  exception when others then null;
  end;
  return null;
end $$;

-- ---------- ③ snack_grants：一張表兩個事件，用正負號分 ----------
-- 📌 那張表有 CHECK (qty <> 0) ⇒ 兩個分支涵蓋全部，不會有漏網的第三種。
-- ⚠ 不綁 reason：'feed' 確實是餵小熊，但**正負號才是事實**
--   （日後多一種扣減理由時，綁 reason 會讓它安靜地不算）。
create or replace function public.trg_snack_achievements()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  begin
    if new.qty > 0 then
      perform public.fire_event_tx(new.member_id, 'snack_granted', 1, null,
                                   'snack:' || new.id::text);
    elsif new.qty < 0 then
      perform public.fire_event_tx(new.member_id, 'snack_consumed', 1, null,
                                   'snack:' || new.id::text);
    end if;
  exception when others then null;
  end;
  return null;
end $$;

-- ---------- ④ teams：建立牌咖團 ----------
create or replace function public.trg_teams_achievements()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  begin
    perform public.fire_event_tx(new.created_by, 'team_created', 1, null,
                                 'team:' || new.id::text);
  exception when others then null;
  end;
  return null;
end $$;

-- ---------- ⑤ team_members：團員報到 ----------
-- 🔴 **排除 role = 'leader'**，而這不是細節：
--    `create_team_tx` 會把團長自己也插一列（role='leader'）
--    ⇒ 不排除的話，建團的人同一秒拿到 21 與 22 兩枚，
--      而 22 的說明是「找到一起打牌的人了」—— 建自己的團不是那件事。
-- ⚠ 其餘三支入團函式都用預設 role='member'，所以這個條件只擋建團者。
create or replace function public.trg_team_members_achievements()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  begin
    perform public.fire_event_tx(new.member_id, 'team_joined', 1, null,
                                 'tmjoin:' || new.id::text);
  exception when others then null;
  end;
  return null;
end $$;

-- ---------- ⑥ member_likes：一列兩個事件，**對象不同** ----------
-- 🔴 `like_received` 的對象是 target_id（被按的人），不是呼叫者。
-- 🔴 兩個 perform **各包一層例外**（與其他五支不同，是刻意的）：
--    target 是**別人**，別人那邊寫入失敗不該讓按讚的人也拿不到成就。
create or replace function public.trg_member_likes_achievements()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  begin
    perform public.fire_event_tx(new.liker_id, 'like_given', 1, null,
                                 'like:' || new.id::text);
  exception when others then null;
  end;
  begin
    perform public.fire_event_tx(new.target_id, 'like_received', 1, null,
                                 'like:' || new.id::text);
  exception when others then null;
  end;
  return null;
end $$;

-- ---------- ⑦ mahjong_buddies：第一個牌咖 ----------
-- 🎯 **只對 member_id 發，兩個人自然都會拿到** ——
--    牌咖是雙向關係，`respond_buddy_invite_tx` 插的是 A→B 與 B→A **兩列**，
--    所以逐列觸發剛好一人一次。
--    （這裡若自作聰明對 buddy_id 也發一次，就會變成每人各兩次。）
create or replace function public.trg_buddies_achievements()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  begin
    perform public.fire_event_tx(new.member_id, 'buddy_added', 1, null,
                                 'buddy:' || new.id::text);
  exception when others then null;
  end;
  return null;
end $$;

-- ---------- 掛上去 ----------
drop trigger if exists trg_members_ach        on public.members;
drop trigger if exists trg_members_rank_ach   on public.members;
drop trigger if exists trg_snack_ach          on public.snack_grants;
drop trigger if exists trg_teams_ach          on public.teams;
drop trigger if exists trg_team_members_ach   on public.team_members;
drop trigger if exists trg_member_likes_ach   on public.member_likes;
drop trigger if exists trg_buddies_ach        on public.mahjong_buddies;

create trigger trg_members_ach
  after insert on public.members
  for each row when (new.deleted_at is null)
  execute function public.trg_members_achievements();

create trigger trg_members_rank_ach
  after update of rank on public.members
  for each row when (old.rank is null and new.rank is not null)
  execute function public.trg_members_rank_achievements();

create trigger trg_snack_ach
  after insert on public.snack_grants
  for each row
  execute function public.trg_snack_achievements();

create trigger trg_teams_ach
  after insert on public.teams
  for each row when (new.deleted_at is null)
  execute function public.trg_teams_achievements();

create trigger trg_team_members_ach
  after insert on public.team_members
  for each row when (new.role <> 'leader' and new.left_at is null)
  execute function public.trg_team_members_achievements();

create trigger trg_member_likes_ach
  after insert on public.member_likes
  for each row
  execute function public.trg_member_likes_achievements();

create trigger trg_buddies_ach
  after insert on public.mahjong_buddies
  for each row when (new.deleted_at is null)
  execute function public.trg_buddies_achievements();

-- ---------- 授權：照 2026-09-20 餐飲那批的形狀 ----------
-- 觸發器函式由系統呼叫，沒有人需要直接 EXECUTE 它。
-- 🔴 兩個方向都要收（硬規則 2.6／2.6b）：
--    · PUBLIC   —— 建立函式時 Postgres 預設就給
--    · anon 等  —— 這個專案的 default privileges 另外明確給了
revoke execute on function public.trg_members_achievements()        from public;
revoke execute on function public.trg_members_rank_achievements()   from public;
revoke execute on function public.trg_snack_achievements()          from public;
revoke execute on function public.trg_teams_achievements()          from public;
revoke execute on function public.trg_team_members_achievements()   from public;
revoke execute on function public.trg_member_likes_achievements()   from public;
revoke execute on function public.trg_buddies_achievements()        from public;

revoke execute on function public.trg_members_achievements()        from anon, authenticated;
revoke execute on function public.trg_members_rank_achievements()   from anon, authenticated;
revoke execute on function public.trg_snack_achievements()          from anon, authenticated;
revoke execute on function public.trg_teams_achievements()          from anon, authenticated;
revoke execute on function public.trg_team_members_achievements()   from anon, authenticated;
revoke execute on function public.trg_member_likes_achievements()   from anon, authenticated;
revoke execute on function public.trg_buddies_achievements()        from anon, authenticated;

-- ============================================================
-- 驗證（🔴 一個字都不准 raise —— 這份要留下 7 個觸發器）
-- ============================================================
do $$
declare
  v_msg  text := '';
  v_n    int;
  v_txt  text;
begin
  -- ---------- ① 七支函式都在，而且都是 DEFINER ----------
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prosecdef
     and p.proname in ('trg_members_achievements','trg_members_rank_achievements',
                       'trg_snack_achievements','trg_teams_achievements',
                       'trg_team_members_achievements','trg_member_likes_achievements',
                       'trg_buddies_achievements');
  v_msg := case when v_n = 7
    then '✅ ① 七支觸發器函式都在，而且都是 SECURITY DEFINER'
    else '🔴 ① 只有 ' || v_n || ' 支（DEFINER），應為 7' end;

  -- ---------- ② 七個觸發器逐名對照 ----------
  -- 🔴 數數量不夠（2026-09-20 才因為「數 orders 觸發器」數錯一次）——
  --    逐名比對才知道**少的是哪一個**。
  select coalesce(string_agg(x.nm, '、' order by x.nm), '（一個都沒有）') into v_txt
    from (values ('trg_members_ach'),('trg_members_rank_ach'),('trg_snack_ach'),
                 ('trg_teams_ach'),('trg_team_members_ach'),('trg_member_likes_ach'),
                 ('trg_buddies_ach')) x(nm)
   where not exists (select 1 from pg_trigger t
                      where not t.tgisinternal and t.tgname = x.nm);
  v_msg := v_msg || E'\n' || case when v_txt = '（一個都沒有）'
    then '✅ ② 七個觸發器全部掛上了'
    else '🔴 ② 缺這幾個：' || v_txt end;

  -- ---------- ③ 🔴 team_members 的 WHEN 真的排除團長 ----------
  -- 那是整份唯一一個「靠條件式」的地方，印出來讓人判讀（硬規則 3.5）
  select pg_get_triggerdef(t.oid) into v_txt
    from pg_trigger t where t.tgname = 'trg_team_members_ach' and not t.tgisinternal;
  v_msg := v_msg || E'\n' || case when v_txt ~ 'leader'
    then '✅ ③ 入團觸發器的 WHEN 含 leader 條件 → ' ||
         coalesce((regexp_match(v_txt, 'WHEN \(([^)]*\)?[^)]*)\) EXECUTE'))[1], '?')
    else '🔴 ③ WHEN 裡沒有 leader —— 建團的人會同時拿到 21 與 22' end;

  -- ---------- ④ members 上現在有幾個觸發器（逐名印出來） ----------
  -- ⚠ 原本 4 個（norm_display_name / org / updated / wallet），這批 +2 = 6
  select count(*), string_agg(t.tgname, '、' order by t.tgname) into v_n, v_txt
    from pg_trigger t join pg_class c on c.oid = t.tgrelid
   where not t.tgisinternal and c.relname = 'members'
     and c.relnamespace = 'public'::regnamespace;
  v_msg := v_msg || E'\n' || case when v_n = 6
    then '✅ ④ members 上 6 個觸發器（原 4 ＋ 這批 2）：' || v_txt
    else '⚠ ④ members 上 ' || v_n || ' 個（算式：4 原本 ＋ 2 這批 = 6）：' || v_txt end;

  -- ---------- ⑤ 授權：七支都不該給前端 ----------
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('trg_members_achievements','trg_members_rank_achievements',
                       'trg_snack_achievements','trg_teams_achievements',
                       'trg_team_members_achievements','trg_member_likes_achievements',
                       'trg_buddies_achievements')
     and (p.proacl is null
          or exists (select 1 from aclexplode(p.proacl) g
                      where g.privilege_type = 'EXECUTE'
                        and g.grantee in (0, 'anon'::regrole::oid,
                                             'authenticated'::regrole::oid)));
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ⑤ 七支都收乾淨了（PUBLIC 與 anon/authenticated 兩個方向）'
    else '🔴 ⑤ 還有 ' || v_n || ' 支前端叫得動（proacl is null ＝ PUBLIC 有）' end;

  -- ---------- ⑥ 🎯 整份的驗收：階段 1 還有哪一枚沒有發射端 ----------
  -- 這一格是**結構性的掃描不是清單** —— 它自己去問每一枚 active 成就
  -- 「全庫有沒有任何函式在 fire_event_tx 裡寫出你的事件名」。
  -- ⚠ 錨點寫成 `fire_event_tx(…'事件名'` 而不是光掃事件名，
  --   否則會被註解命中（硬規則 3.5 已經踩過五次）。
  -- ⚠ prokind = 'f'：pg_get_functiondef 對聚合函式會直接拋錯（硬規則 3.7）。
  select count(*), coalesce(string_agg(a.code || '（' || (a.trigger->>'event') || '）',
                                       '、' order by a.code), '')
    into v_n, v_txt
    from achievements a
   where a.is_active and a.deleted_at is null
     and not coalesce(a.trigger ? 'count', false)      -- meta 走 ach_meta_tx，沒有事件
     and not exists (
       select 1 from pg_proc p
        where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
          and pg_get_functiondef(p.oid) ~
              ('fire_event_tx\s*\([^;]{0,160}''' || (a.trigger->>'event') || ''''));
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ⑥ 🎯 階段 1 的 17 枚可解鎖成就**全部都有發射端了**'
    else '⏳ ⑥ 還有 ' || v_n || ' 枚沒有發射端：' || v_txt end;

  -- ---------- ⑦ 🔴 負對照：C 區 31 枚**不可以**有發射端 ----------
  -- 少了這一格，⑥ 那個掃描器就算整個壞掉（永遠回 0）也會全綠。
  select count(*) into v_n
    from achievements a
   where a.deleted_at is null and a.code like 'tile\_%'
     and exists (
       select 1 from pg_proc p
        where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
          and pg_get_functiondef(p.oid) ~
              ('fire_event_tx\s*\([^;]{0,160}''' || (a.trigger->>'event') || ''''));
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ⑦ C 區 31 枚一枚都沒有發射端（要等電子計分，掃描器是活的）'
    else '🔴 ⑦ 有 ' || v_n || ' 枚牌型成就已經有人在發了 —— ⑥ 的掃描器可能寫太寬' end;

  -- ---------- ⑧ 十個事件對應的成就都在、都 active ----------
  select count(*) into v_n from achievements a
   where a.deleted_at is null and a.is_active
     and a.trigger->>'event' in ('member_registered','title_granted','rank_placed',
          'snack_granted','snack_consumed','team_created','team_joined',
          'like_given','like_received','buddy_added');
  v_msg := v_msg || E'\n' || case when v_n = 10
    then '✅ ⑧ 這十個事件各對到一枚 active 成就（01·13·26·16·17·21·22·23·24·25）'
    else '🔴 ⑧ 對到 ' || v_n || ' 枚，應為 10 —— 有事件名拼錯或成就被關掉' end;

  perform set_config('migi.verify', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify', true), ''), '🔴 沒有驗證訊息') as "驗證";
