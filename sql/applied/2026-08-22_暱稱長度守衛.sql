-- 【這是什麼】幫 members.display_name 加長度 CHECK，並把 set_my_nickname_tx 的守衛從 20 對齊成 12。
-- 【何時讀】執行前。盤點結果見 sql/checks/查暱稱長度與守衛.sql（2026-08-22 已跑）。
--
-- 【為什麼要做】
--   前端 maxLength={12}（profile.jsx:368、App.jsx:138）不是約束，只是輸入框的行為。
--   2026-08-22 盤點確認：
--     · members 上與 display_name 有關的 CHECK ＝ 完全沒有
--     · register_member_tx ＝ 沒有任何長度守衛，直接打 RPC 可塞任意長度
--     · set_my_nickname_tx ＝ 線上守衛是 20，與前端的 12 不一致
--   而 migi-web 有五處顯示暱稱時完全沒有截斷（牌咖列表 buddies.jsx:95/151/179、
--   黑名單 match.jsx:57/665、配桌動態 match.jsx:460、通知標題 notifications.jsx:157），
--   一處一處補 ellipsis 是打地鼠 —— 忘記補不會報錯，只在某個客人取長名字那天才發現。
--   在源頭擋住，上述全部自動安全。
--
-- 【現有資料】4 位會員、最長 4 字、無 emoji、無空白 → 加 CHECK 零風險。
--   ⚠ 但盤點查詢帶了 deleted_at is null，而 ALTER TABLE ADD CHECK 會驗證「所有」列
--     （含軟刪除的）。所以下面第一段會先自己重查一次不帶條件的，違規就整支中止。
--
-- 【上限為什麼是 12】對齊前端既有規則，不是新訂的。
--   ⚠ char_length 算的是碼點，一個組合 emoji（如家庭）可能吃掉 7 個。
--     這是刻意接受的：真要按「視覺寬度」限制，Postgres 沒有可靠做法。

-- ============================================================
-- 一、前置檢查（含軟刪除列）＋ 加 CHECK
-- ============================================================
do $do$
declare
  v_bad   bigint;
  v_worst text;
begin
  select count(*) into v_bad
    from members
   where display_name is null
      or btrim(display_name) = ''
      or char_length(display_name) > 12;

  -- 取真正最長的那一筆（不是 max(text) —— 那是字典序，會挑錯人）
  select '「' || coalesce(display_name, '<NULL>') || '」('
         || coalesce(char_length(display_name), 0) || ' 字)'
    into v_worst
    from members
   where display_name is null
      or btrim(display_name) = ''
      or char_length(display_name) > 12
   order by char_length(display_name) desc nulls first
   limit 1;

  if v_bad > 0 then
    raise exception '有 % 列不符合 1～12 字（含軟刪除列），最長的是 %。'
                    '請先決定怎麼處理再執行 —— 回填是改客人的名字，不要順手 update。',
                    v_bad, v_worst;
  end if;

  -- 已存在就先移除，避免同一欄位長出兩條約束（待辦 4 的教訓：
  -- 數量不等於衝突，但兩條約束同一欄位就是重複，看定義決定要不要換掉舊的）
  if exists (select 1 from pg_constraint
              where conrelid = 'members'::regclass
                and conname  = 'members_display_name_len_chk') then
    alter table members drop constraint members_display_name_len_chk;
  end if;

  -- ⚠ Postgres 的 CHECK 判定為 NULL 時視為「通過」。所以 is not null 必須明寫，
  --    不能寫成 char_length(display_name) between 1 and 12 就了事
  --    —— 那樣 NULL 會直接放行（同 2026-08-19 的 NULL not in (...) 之坑）。
  alter table members
    add constraint members_display_name_len_chk
    check (display_name is not null
           and btrim(display_name) <> ''
           and char_length(display_name) between 1 and 12);
end $do$;

-- ============================================================
-- 二、set_my_nickname_tx：20 → 12，並換成看得懂的訊息
-- ============================================================
-- 單點替換 + guard（同 2026-08-19 revenue_type 那批的做法，救過兩次）。
-- 只改兩處，未達「三處以上就撈全文重建」的門檻，故用 DO 區塊。
-- 簽名沒變，不需要 DROP（硬規則 2 只針對改簽名）。
do $do$
declare v_old text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_old
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'set_my_nickname_tx';

  if v_old is null then
    raise exception 'set_my_nickname_tx 不存在，請先確認函式名稱';
  end if;

  -- ① 上限 20 → 12
  v_new := regexp_replace(v_old,
             'length\s*\(\s*p_nickname\s*\)\s*>\s*20',
             'char_length(p_nickname) > 12');
  if v_new = v_old then
    raise exception '找不到「length(p_nickname) > 20」，線上定義與預期不同，整支中止。實際定義：%', v_old;
  end if;

  -- ② 訊息換成使用者看得懂的（店員與客人都看得到這句）
  v_new := replace(v_new, '''暱稱過長''', '''暱稱最多 12 個字''');

  -- guard：確認沒有殘留
  if v_new ~ 'p_nickname\s*\)\s*>\s*20' then
    raise exception '仍有 20 殘留，整支中止';
  end if;

  execute v_new;
end $do$;

-- ============================================================
-- 三、驗證（單一 SELECT）
-- ============================================================
select 項目, 值
from (
  select 1 as ord, 'CHECK 定義' as 項目,
    coalesce((select pg_get_constraintdef(oid) from pg_constraint
               where conrelid = 'members'::regclass
                 and conname  = 'members_display_name_len_chk'),
             '❌ 沒建起來') as 值

  union all select 2, 'members 上與 display_name 有關的 CHECK 條數',
    (select count(*)::text from pg_constraint
      where conrelid = 'members'::regclass and contype = 'c'
        and pg_get_constraintdef(oid) ilike '%display_name%')

  union all select 3, 'set_my_nickname_tx 守衛上限（應為 12）',
    coalesce((select substring(pg_get_functiondef(oid) from 'p_nickname\s*\)\s*>\s*(\d+)')
                from pg_proc
               where pronamespace = 'public'::regnamespace
                 and proname = 'set_my_nickname_tx' limit 1),
             '❌ 找不到守衛')

  union all select 4, 'set_my_nickname_tx 仍殘留 20（應為 0）',
    (select count(*)::text from pg_proc
      where pronamespace = 'public'::regnamespace
        and proname = 'set_my_nickname_tx'
        and prosrc ~ 'p_nickname\s*\)\s*>\s*20')

  union all select 5, '訊息是否已換（應含「12 個字」）',
    (select case when prosrc like '%12 個字%' then '✅ 是' else '❌ 否' end
       from pg_proc
      where pronamespace = 'public'::regnamespace
        and proname = 'set_my_nickname_tx' limit 1)

  union all select 6, '現有會員最長暱稱（應 ≤ 12）',
    (select coalesce(max(char_length(display_name)), 0)::text from members)
) x
order by ord;

-- ── 執行後的實機測試 ──────────────────────────────────────────
-- 在會員 App 個人檔案改暱稱，貼 13 個字進去 →
--   前端 maxLength 會先擋（打不進第 13 個字），這是正常的。
--   要測後端就直接在 SQL Editor 打：
--   select set_my_nickname_tx('<org>', '<member>', '一二三四五六七八九十一二三');
--   應看到「暱稱最多 12 個字」，而不是 constraint violation
--   （若看到 23514 constraint 錯誤，代表函式守衛沒生效、CHECK 才是最後防線）。
--
-- ── 沒做的事（刻意）──────────────────────────────────────────
-- register_member_tx 沒加友善守衛。理由：
--   註冊表單有 maxLength={12}，正常路徑進不來；直接打 RPC 的人看到
--   constraint violation 是可接受的。要加的話得先撈它的線上全文（硬規則 3），
--   而 CHECK 已經把安全問題解決了，剩下的只是錯誤訊息好不好看。
