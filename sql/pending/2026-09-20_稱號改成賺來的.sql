-- ============================================================
-- 稱號改成「賺來的」，不是註冊就有（2026-09-20 使用者選 B 案）
--
-- ============================================================
-- 🔴 「只拿掉 DEFAULT」不夠 —— 「新手上路」寫死在 **4 個地方**
-- ============================================================
-- ```
-- ① members.title 的 DEFAULT                    ← 這一份
-- ② set_my_title_tx 的硬性放行                   ← 這一份
-- ③ profile.jsx:572   || '新手上路'              ⏳ 前端另一批
-- ④ rewards.jsx:859/876/877 清單／has／預設配戴   ⏳ 前端另一批
-- ```
-- ⚠ 只動 ① 的話**畫面一個字都不會變** —— 前端的 fallback 會接住，
--   只是從「資料庫說謊」換成「前端說謊」。
--
-- 🔴 而我一度說「換掉就換不回來」——**那是錯的**，② 那行硬性放行讓它換得回去。
--   我先前撈 `set_my_title_tx` 時過濾器只抓 `titles|raise|update members`，
--   **剛好漏掉 `and p_title <> '新手上路'` 那一行**（硬規則 3.5：先懷疑儀器）。
--
-- ============================================================
-- 🎯 正解不是發明新機制，是把一條**已經存在卻沒接起來**的線接上
-- ============================================================
-- `achievements.grants_title` 這個欄位早就在，而 `ach_unlock_tx`
-- 解鎖時**已經把它回傳出來**（`'title', a.grants_title`）——
-- 🔴 **但沒有任何東西拿它去寫 `members.title`**，而且 60 枚成就
--   **沒有一枚填了那個欄位**。典型的「建了沒人讀」。
--
-- ```
-- onboarding_02（第一次開桌）.grants_title = '新手上路'
--    ↓ 收桌 → session_finished → ach_unlock_tx 解鎖
--    ↓ 寫進 member_app_state.titles（解鎖清單）
--    ↓ **只在 members.title 是 null 時**才自動配戴
-- ```
--
-- ⚠ **「只在 null 時配戴」是刻意的。** 否則客人戴著「三屆雀神」時
--   解鎖了新稱號會被系統偷偷換掉 ——
--   **解鎖是加進清單，配戴是他自己的選擇**，兩件事。
--
-- ============================================================
-- ⚠ 回填：今天零風險，但仍然要寫（它是規則不是一次性操作）
-- ============================================================
-- 實查五個會員：`title` 全是「新手上路」，而且**每一個都完成過牌局**
-- （12 / 12 / 3 / 13 / 12 場）⇒ 依新規則他們本來就該有 ⇒ **一個都不用清掉**。
-- 🔴 但 `member_app_state.titles` **五個全是 `[]`** ⇒ 拿掉 ② 的硬性放行之後
--   他們會**換掉就換不回來**。所以這一份要把它補進去。
--
-- ⚠ 這份要留下 DDL 與資料 ⇒ 驗證段一個字都不准 raise（硬規則 1.8）。
--   行為測試另一份：`sql/checks/2026-09-20_驗稱號要賺才有.sql`
-- ============================================================


-- ---------- ① 讓「還沒賺到」表達得出來 ----------
-- 🔴 只 drop default 不夠：`title` 是 NOT NULL，
--   不改成可為 null 的話「沒有稱號」會被迫填一個值
--   （同待辦 24：「從來沒來過」是有意義的值，不要寫成 now()）。
alter table public.members alter column title drop default;
alter table public.members alter column title drop not null;


-- ---------- ② 回填解鎖清單 ----------
-- 現有會員配戴的稱號要進得了清單，否則換掉就換不回來
insert into member_app_state (member_id, org_id, titles)
select m.id, m.org_id, jsonb_build_array(m.title)
  from members m
 where m.deleted_at is null and m.title is not null
on conflict (member_id) do update
   set titles = case
         when member_app_state.titles ? excluded.titles->>0 then member_app_state.titles
         else member_app_state.titles || excluded.titles end,
       updated_at = now();

-- 🔴 沒有完成過任何牌局的人，依新規則不該有稱號 ⇒ 清掉
--   （今天是 0 列 —— 五個人都打過。寫它是因為它是規則，不是因為今天有資料。）
update members m set title = null
 where m.deleted_at is null and m.title is not null
   and not exists (select 1 from session_players sp
                    join table_sessions ts on ts.id = sp.session_id
                   where sp.member_id = m.id and ts.status = 'completed');


-- ---------- ③ 把稱號掛到「第一次開桌」那一枚 ----------
update achievements set grants_title = '新手上路', updated_at = now()
 where code = 'onboarding_02' and deleted_at is null
   and grants_title is distinct from '新手上路';


-- ---------- ④ ach_unlock_tx：解鎖時真的發稱號 ----------
create or replace function public.ach_unlock_tx(
  p_member uuid, p_code text, p_idem text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_org uuid; a achievements; r member_achievements;
begin
  select org_id into v_org from members where id = p_member and deleted_at is null;
  if v_org is null then return jsonb_build_object('ok', false, 'reason', 'member_not_found'); end if;

  select * into a from achievements
   where org_id = v_org and code = p_code and deleted_at is null;
  if not found then return jsonb_build_object('ok', false, 'reason', 'achievement_not_found'); end if;
  if not _ach_live(a) then return jsonb_build_object('ok', true, 'skipped', 'out_of_window'); end if;

  r := _ma_row(p_member, a.id, v_org);
  if r.status = 'unlocked' then return jsonb_build_object('ok', true, 'already', true); end if;

  update member_achievements
     set status = 'unlocked', current_tier = 1, unlocked_at = now(),
         last_idem = coalesce(p_idem, last_idem), updated_at = now()
   where id = r.id;

  /* 🆕 2026-09-20：解鎖時真的發稱號。
     🔴 在此之前 `grants_title` 只被**回傳**、沒有任何東西寫進 `members.title`
       ——「建了沒人讀」的形狀，而且 60 枚成就一枚都沒填那個欄位。
     ⚠ 整段吞例外：**稱號發不出去不可以讓成就解鎖失敗**
       （而成就失敗又不可以回滾結帳／收桌 —— 那是上一層的事）。 */
  if a.grants_title is not null then
    begin
      -- ① 加進解鎖清單（只增不減，與 save_app_state_tx 的語意一致）
      insert into member_app_state (member_id, org_id, titles)
      values (p_member, v_org, jsonb_build_array(a.grants_title))
      on conflict (member_id) do update
         set titles = case
               when member_app_state.titles ? a.grants_title then member_app_state.titles
               else member_app_state.titles || jsonb_build_array(a.grants_title) end,
             updated_at = now();

      /* ② 🔴 **只在還沒有稱號時才自動配戴。**
         否則客人戴著「三屆雀神」時解鎖了新稱號會被系統偷偷換掉 ——
         解鎖是加進清單，配戴是他自己的選擇，兩件事不可以合併。 */
      update members set title = a.grants_title
       where id = p_member and title is null;
    exception when others then null;
    end;
  end if;

  -- ⚠ 這裡刻意沒有發點數：那支發放函式今天不存在，而 §8.5 的鐵則是
  --   「成就給徽章與稱號，點數是最克制的那一層」。reward_points 欄位留著，
  --   日後真的要發再接。
  --   🔴 這段話刻意不寫出那個函式的識別字 —— 寫了會觸發掃描（硬規則 3.5）
  return jsonb_build_object('ok', true, 'unlocked', true,
                            'code', p_code, 'title', a.grants_title);
end $$;


-- ---------- ⑤ 拿掉硬性放行 ----------
-- 🎯 ② 回填完之後，現有會員的「新手上路」真的在清單裡了
--   ⇒ 這行例外不再需要，而留著它等於「清單說了不算」。
create or replace function public.set_my_title_tx(
  p_org_id uuid, p_member_id uuid, p_title text
) returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。 */
  p_member_id := public.current_member_id();
  if p_member_id is null then
    raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000';
  end if;

  /* 🔴 2026-09-20 拿掉 `and p_title <> '新手上路'` 那行硬性放行。
     它當初存在是因為 `member_app_state.titles` 全是 `[]` 而大家都戴著它
     —— 現在那份清單已經回填了，放行就變成「清單說了不算」。 */
  if not exists (
    select 1 from member_app_state
     where member_id = p_member_id and titles ? p_title
  ) then
    raise exception '稱號未解鎖';
  end if;

  update members set title = p_title
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
end $$;


-- ============================================================
-- 驗證
-- ============================================================
do $$
declare v_msg text := ''; v_n int; v_txt text;
begin
  -- ① 欄位可為 null 而且沒有預設
  select is_nullable || ' / ' || coalesce(column_default, '（無預設）') into v_txt
    from information_schema.columns
   where table_schema='public' and table_name='members' and column_name='title';
  v_msg := case when v_txt = 'YES / （無預設）'
    then '✅ ① members.title 已可為 null 且無預設'
    else '🔴 ① 現在是：' || coalesce(v_txt, '⚪ 取不到') end;

  -- ② 回填：每一個「有配戴稱號」的人，那個稱號都要在他的解鎖清單裡
  --    🔴 這一格是 ⑤ 的前提 —— 少了它，拿掉放行就等於把人鎖在外面
  select count(*) into v_n
    from members m
   where m.deleted_at is null and m.title is not null
     and not exists (select 1 from member_app_state s
                      where s.member_id = m.id and s.titles ? m.title);
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ② 每個配戴中的稱號都在自己的解鎖清單裡（換掉換得回來）'
    else '🔴 ② 有 ' || v_n || ' 個人的稱號不在清單裡 —— 他們會換掉就換不回來' end;

  -- ③ 🔴 負對照：沒完成過牌局的人不可以有稱號
  --    ⚠ 今天五個人都打過 ⇒ 這一格「沒有樣本」，要說成 ⚪ 不是 ✅
  select count(*) into v_n
    from members m
   where m.deleted_at is null
     and not exists (select 1 from session_players sp
                      join table_sessions ts on ts.id = sp.session_id
                     where sp.member_id = m.id and ts.status = 'completed');
  if v_n = 0 then
    v_msg := v_msg || E'\n' || '⚪ ③ 今天每個會員都完成過牌局 —— 這一格測不出東西';
  else
    select count(*) into v_n
      from members m
     where m.deleted_at is null and m.title is not null
       and not exists (select 1 from session_players sp
                        join table_sessions ts on ts.id = sp.session_id
                       where sp.member_id = m.id and ts.status = 'completed');
    v_msg := v_msg || E'\n' || case when v_n = 0
      then '✅ ③ 沒完成過牌局的人都沒有稱號'
      else '🔴 ③ 有 ' || v_n || ' 個沒打過的人還戴著稱號' end;
  end if;

  -- ④ 稱號掛在對的那一枚上，而且只有那一枚
  select coalesce(string_agg(code || '→' || grants_title, '　' order by code), '（一枚都沒有）')
    into v_txt
    from achievements where deleted_at is null and grants_title is not null;
  v_msg := v_msg || E'\n' || case when v_txt = 'onboarding_02→新手上路'
    then '✅ ④ 只有 onboarding_02（第一次開桌）發稱號'
    else '🔴 ④ 帶 grants_title 的是：' || v_txt end;

  -- ⑤ 兩支函式都改到了（問「有沒有那個行為」，不是「有沒有提到那個詞」）
  select count(*) into v_n from pg_proc p
   where p.pronamespace='public'::regnamespace and p.proname='ach_unlock_tx'
     and pg_get_functiondef(p.oid) ~ 'update members set title';
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '✅ ⑤ ach_unlock_tx 會寫 members.title 了'
    else '🔴 ⑤ ach_unlock_tx 還是只回傳不寫入' end;

  -- ⑥ 🔴 硬性放行真的不見了
  --    ⚠ 掃的是那個**條件式**不是「新手上路」四個字 ——
  --      後者會被我自己寫在同一支函式裡的註解命中（硬規則 3.5 第六次）
  select count(*) into v_n from pg_proc p
   where p.pronamespace='public'::regnamespace and p.proname='set_my_title_tx'
     and pg_get_functiondef(p.oid) ~ 'p_title\s*<>';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ⑥ set_my_title_tx 的硬性放行已拿掉'
    else '🔴 ⑥ 還有 `p_title <> …` 這個例外' end;

  -- ⑦ 負對照：兩支函式的版本數與授權沒被動到
  select string_agg(p.proname || '=' || (select count(*) from pg_proc q
            where q.pronamespace='public'::regnamespace and q.proname=p.proname)
          || '版/' || case when has_function_privilege('anon', p.oid, 'execute')
                           then 'anon 有' else 'anon 沒有' end, '　' order by p.proname)
    into v_txt
    from pg_proc p
   where p.pronamespace='public'::regnamespace
     and p.proname in ('ach_unlock_tx','set_my_title_tx');
  v_msg := v_msg || E'\n' || '　　⑦ ' || coalesce(v_txt, '⚪ 取不到')
    || E'\n' || '　　（ach_unlock_tx 只給 service_role；set_my_title_tx 要給 anon —— 會員 App 在叫）';

  -- ⑧ 現況印出來讓人判讀
  v_msg := v_msg || E'\n' || coalesce(
    (select '　　⑧ ' || string_agg(m.display_name || '＝' || coalesce(m.title,'（無稱號）')
              || '／清單 ' || coalesce((select s.titles::text from member_app_state s
                                        where s.member_id = m.id), '（沒有那一列）'),
              E'\n　　   ' order by m.created_at)
       from members m where m.deleted_at is null),
    '⚪ 取不到');   -- 字串 || NULL 會吃掉前面所有格（硬規則 3.555）

  perform set_config('migi.verify', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify', true), ''), '🔴 沒有驗證訊息') as "驗證";
