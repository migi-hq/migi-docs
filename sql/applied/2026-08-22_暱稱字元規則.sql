-- 【這是什麼】暱稱的字元規則：正規化 trigger + 加嚴 CHECK（隱形字元、保留字）。
-- 【何時讀】執行前。前一支是 2026-08-22_暱稱長度守衛.sql（已跑），這支補它漏掉的洞。
--
-- ═══ 為什麼要做 ═══
--
-- 前一支的 CHECK 寫 `btrim(display_name) <> ''`，但 PostgreSQL 的 btrim 單參數版
-- **只 trim ASCII 半形空格 chr(32)**。所以下面兩種暱稱現在都通過：
--   · 「　　　　」全形空格 U+3000 × 4  → 長度 4、btrim 不吃 → 一片空白的暱稱
--   · 「​​​​」零寬空格 U+200B × 4      → 完全看不見的暱稱
-- 第二種更嚴重：座位列裡一個沒有名字的人，在有金流的社交 App 裡離冒充只差一步。
--
-- ═══ 為什麼用 trigger 而不是改函式 ═══
--
-- 把正規化寫進 set_my_nickname_tx 的話，register_member_tx 仍然沒有 ——
-- 而 CHECK 若要求「必須已正規化」，註冊時打「小　美」就會被擋下噴 23514，
-- 比現在更糟。trigger 在寫入前自動正規化，涵蓋所有寫入路徑（含未來新增的），
-- 不需要任何一支函式記得呼叫它。這是「在邊界正規化一次」的標準做法。
--
-- ═══ 刻意不擋的 ═══
--
-- · emoji —— LINE / Discord / IG / X 都允許，2×2 放大後版面也吃得下。
--   ⚠ 特別注意下面的 strip 清單**不含 U+200C / U+200D**：
--     組合 emoji（👨‍👩‍👧‍👦）靠 ZWJ 接起來，擋掉會裂成四個人。
-- · 一般符號（★ ♠ ·）—— 沒有危害。
-- · 髒話字典 —— 要有人每週維護，而那個人不存在（硬規則 5.5）。

-- ============================================================
-- 一、正規化函式（IMMUTABLE，CHECK 與 trigger 共用）
-- ============================================================
-- 順序有意義：先把各種空白換成半形空格（含 tab／換行），
-- 再清掉剩下的控制字元與隱形字元，最後收斂連續空格並 trim。
-- 反過來做的話，換行會先被當控制字元刪掉，「小\n美」會變成「小美」而不是「小 美」。
create or replace function migi_norm_nickname(p text)
returns text language sql immutable strict as $$
  select btrim(
    regexp_replace(
      regexp_replace(
        -- ① 各種空白 → 半形空格
        --    tab / LF / CR / 半形空格 / NBSP / U+2000–U+200A / 窄NBSP / 數學空格 / 全形空格
        regexp_replace(
          p,
          '[' || chr(9) || chr(10) || chr(13) || chr(32) || chr(160)
              || chr(8192) || '-' || chr(8202)
              || chr(8239) || chr(8287) || chr(12288) || ']',
          ' ', 'g'),
        -- ② 控制字元 + 隱形字元 → 刪除
        --    軟連字號 / 零寬空格 / LRM / RLM / 行段分隔 / 雙向覆寫 / 連字禁止 / BOM
        --    ⚠ 不含 chr(8204) ZWNJ 與 chr(8205) ZWJ —— 組合 emoji 要用
        '[[:cntrl:]' || chr(173) || chr(8203) || chr(8206) || chr(8207)
                     || chr(8232) || chr(8233) || chr(8234) || chr(8235)
                     || chr(8236) || chr(8237) || chr(8238) || chr(8288)
                     || chr(65279) || ']',
        '', 'g'),
      -- ③ 連續空格收斂成一個
      ' +', ' ', 'g')
  )
$$;

comment on function migi_norm_nickname(text) is
  '暱稱正規化：各種空白→半形、去控制與隱形字元、連續空格收斂、前後 trim。保留 ZWJ/ZWNJ 供組合 emoji 使用。';

-- ============================================================
-- 二、寫入前自動正規化（涵蓋所有寫入路徑）
-- ============================================================
create or replace function trg_members_norm_display_name()
returns trigger language plpgsql as $$
begin
  new.display_name := migi_norm_nickname(new.display_name);
  return new;
end $$;

drop trigger if exists members_norm_display_name on members;
create trigger members_norm_display_name
  before insert or update of display_name on members
  for each row execute function trg_members_norm_display_name();

-- ============================================================
-- 三、把現有資料正規化，再換上加嚴的 CHECK
-- ============================================================
do $do$
declare
  v_bad  bigint;
  v_list text;
begin
  -- ① 先讓 trigger 把現有列洗一遍（寫回自己就會觸發 before update）
  update members set display_name = display_name
   where display_name is distinct from migi_norm_nickname(display_name);

  -- ② 洗完之後還違規的（長度、空白、保留字），列出來並中止 —— 不自動改客人的名字
  select count(*) into v_bad
    from members
   where display_name is null
      or char_length(display_name) not between 1 and 12
      or display_name ~* '(migi|官方|客服|店長|管理員|系統|admin)';

  if v_bad > 0 then
    select string_agg('「' || coalesce(display_name, '<NULL>') || '」', '  ')
      into v_list
      from members
     where display_name is null
        or char_length(display_name) not between 1 and 12
        or display_name ~* '(migi|官方|客服|店長|管理員|系統|admin)';
    raise exception '有 % 列不符合新規則：%。請先決定怎麼處理 —— 改客人的名字要先確認，不要順手 update。',
                    v_bad, v_list;
  end if;

  -- ③ 換掉舊約束（舊的只管長度與 ASCII 空白）
  if exists (select 1 from pg_constraint
              where conrelid = 'members'::regclass
                and conname = 'members_display_name_len_chk') then
    alter table members drop constraint members_display_name_len_chk;
  end if;
  if exists (select 1 from pg_constraint
              where conrelid = 'members'::regclass
                and conname = 'members_display_name_chk') then
    alter table members drop constraint members_display_name_chk;
  end if;

  -- ⚠ `display_name = migi_norm_nickname(display_name)` 一條就涵蓋了
  --   前後空白、連續空白、隱形字元、控制字元 —— 因為正規化後不等於自己就代表有問題。
  --   trigger 已保證這件事，這條是 trigger 被停掉時的最後防線。
  -- ⚠ IS NOT NULL 必須明寫：Postgres 的 CHECK 判定為 NULL 時視為「通過」。
  alter table members
    add constraint members_display_name_chk
    check (display_name is not null
           and display_name = migi_norm_nickname(display_name)
           and char_length(display_name) between 1 and 12
           and display_name !~* '(migi|官方|客服|店長|管理員|系統|admin)');
end $do$;

-- ============================================================
-- 四、set_my_nickname_tx：改用正規化 + 友善訊息
-- ============================================================
-- 簽名沒變，不需要 DROP。整支重建而非單點替換 ——
-- 這次要改的是「輸入怎麼處理」，不是換個數字（2026-08-20 的教訓）。
-- 舊版body（供比對）：null/空白檢查 → length > 12 拋錯 → update trim(p_nickname)。
-- 想留存舊定義的話，執行前先跑：
--   select pg_get_functiondef('set_my_nickname_tx'::regproc);
create or replace function set_my_nickname_tx(p_org_id uuid, p_member_id uuid, p_nickname text)
returns void language plpgsql security definer set search_path = public as $$
declare v text;
begin
  v := migi_norm_nickname(coalesce(p_nickname, ''));

  -- 正規化之後才判斷 —— 「　　　」會在這裡變成空字串被擋下，
  -- 而舊版的 length(trim(...)) = 0 完全擋不到全形空格
  if v = '' then
    raise exception '暱稱不可空白';
  end if;
  if char_length(v) > 12 then
    raise exception '暱稱最多 12 個字';
  end if;
  if v ~* '(migi|官方|客服|店長|管理員|系統|admin)' then
    raise exception '暱稱不可使用保留字（官方／客服／店長等）';
  end if;

  update members set display_name = v, updated_at = now()
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
end $$;

grant execute on function set_my_nickname_tx(uuid, uuid, text) to anon, authenticated;
grant execute on function migi_norm_nickname(text) to anon, authenticated;

-- ============================================================
-- 五、驗證（單一 SELECT）
-- ============================================================
select 項目, 結果
from (
  select 1 as ord, '正規化：全形空格 ×3 → 應為空字串' as 項目,
    '「' || migi_norm_nickname(chr(12288) || chr(12288) || chr(12288)) || '」' as 結果

  union all select 2, '正規化：零寬空格 ×4 → 應為空字串',
    '「' || migi_norm_nickname(chr(8203) || chr(8203) || chr(8203) || chr(8203)) || '」'

  union all select 3, '正規化：「  小   美  」→ 應為「小 美」',
    '「' || migi_norm_nickname('  小   美  ') || '」'

  union all select 4, '正規化：小＋零寬＋美 → 應為「小美」',
    '「' || migi_norm_nickname('小' || chr(8203) || '美') || '」'

  union all select 5, '正規化：含換行 → 應變空格不是消失',
    '「' || migi_norm_nickname('小' || chr(10) || '美') || '」'

  union all select 6, '正規化：組合 emoji 應完整保留（ZWJ 沒被刪）',
    case when migi_norm_nickname('👨' || chr(8205) || '👩') = '👨' || chr(8205) || '👩'
         then '✅ 保留' else '❌ ZWJ 被刪掉了' end

  union all select 10, 'trigger 是否存在',
    coalesce((select tgname from pg_trigger
               where tgrelid = 'members'::regclass
                 and tgname = 'members_norm_display_name'), '❌ 沒建起來')

  union all select 11, 'CHECK 定義',
    coalesce((select pg_get_constraintdef(oid) from pg_constraint
               where conrelid = 'members'::regclass
                 and conname = 'members_display_name_chk'), '❌ 沒建起來')

  union all select 12, 'members 上 display_name 相關 CHECK 條數（應為 1）',
    (select count(*)::text from pg_constraint
      where conrelid = 'members'::regclass and contype = 'c'
        and pg_get_constraintdef(oid) ilike '%display_name%')

  union all select 13, 'set_my_nickname_tx 是否已改用 migi_norm_nickname',
    (select case when prosrc like '%migi_norm_nickname%' then '✅ 是' else '❌ 否' end
       from pg_proc where pronamespace = 'public'::regnamespace
        and proname = 'set_my_nickname_tx' limit 1)

  union all select 20, '現有會員暱稱（確認沒被洗壞）',
    (select string_agg('「' || display_name || '」', '  ' order by display_name) from members)
) x
order by ord;

-- ── 執行後的實機測試 ──────────────────────────────────────────
-- 在 SQL Editor 直接打（<org> / <member> 換成實際值）：
--   select set_my_nickname_tx('<org>','<member>', '　　　');        → 應噴「暱稱不可空白」
--   select set_my_nickname_tx('<org>','<member>', 'MIGI客服');      → 應噴保留字
--   select set_my_nickname_tx('<org>','<member>', '  小   美  ');   → 應成功，存成「小 美」
--   select display_name from members where id = '<member>';
--
-- ── 已知後果 ────────────────────────────────────────────────
-- · 註冊時打保留字會噴 23514 constraint violation（訊息不好看）——
--   register_member_tx 沒有友善守衛。安全問題已由 CHECK 解決，
--   要補訊息得先撈它的線上全文（硬規則 3），另外一支再處理。
-- · 保留字是子字串比對：「MIGIちゃん」也會被擋。刻意如此 ——
--   在配桌座位列裡叫「MIGI 客服」是能騙到人的。
