/* ============================================================
   匯出完整結構 baseline —— 讓「從零重建資料庫」變成可能
   2026-08-29 建立 · 唯讀 · 可重複執行，不是 migration

   ⚠ 檔名刻意沒有日期：它是**常駐工具**，每次要更新 baseline 就重跑一次。

   ── 為什麼需要這支 ────────────────────────────────
   🔴 **`sql/applied/` 拼不回一個完整的資料庫。**
   CLAUDE.md 自己就寫著：
     · `applied/` 不是線上現況的鏡像（後來改過而沒留檔的不在裡面）
     · `uq_members_line_user` 是直接在 Dashboard 建的，`sql/` 裡完全找不到
   → 所以新人**無法在本機建一個一樣的資料庫**，只能一支一支 `pg_get_functiondef` 撈。

   ⚠ 那對「未來有人維護」是致命的，而且**每過一天就多一支 applied**，
     越晚做越貴。

   ── 這支產生什麼 ──────────────────────────────────
   一份可直接執行的 DDL，順序已排好（相依性由 sort 欄控制）：
     1 擴充套件　2 列舉型別　3 資料表　4 約束（PK/UNIQUE/CHECK）
     5 外鍵　6 索引　7 函式　8 觸發器　9 檢視表　10 RLS 與 policy
   🔴 **不含資料**（種子資料另外處理），也**不含 Storage 的 bucket 設定**
     （那在 storage schema，見檔尾備註）。

   ── 怎麼用 ────────────────────────────────────────
   ① 在 Supabase SQL Editor 執行這一整份
   ② 結果只有一欄 `ddl`，**全選複製**（或用右上角下載）
   ③ 存成 `sql/_baseline/YYYY-MM-DD_完整結構.sql`
   ④ 更新 `docs/01-資料庫/db-現況快照.md` 檔頭的 baseline 日期

   📌 **baseline 不取代 `applied/`** —— 那是歷史紀錄，有它才知道「為什麼」。
     baseline 回答的是「現在長什麼樣」。兩者都要。
   ============================================================ */

with parts as (

  /* ── 1. 擴充套件 ── */
  select 1 as sort, 0 as sub, extname as name,
         'create extension if not exists ' || quote_ident(extname) || ';' as ddl
    from pg_extension
   where extname not in ('plpgsql')

  union all
  /* ── 2. 列舉型別 ── */
  select 2, 0, t.typname,
         'create type ' || quote_ident(t.typname) || ' as enum ('
      || (select string_agg(quote_literal(e.enumlabel), ', ' order by e.enumsortorder)
            from pg_enum e where e.enumtypid = t.oid) || ');'
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
   where n.nspname = 'public' and t.typtype = 'e'

  union all
  /* ── 3. 資料表（欄位、型別、預設值、NOT NULL）── */
  select 3, 0, c.relname,
         'create table ' || quote_ident(c.relname) || ' (' || E'\n  '
      || (select string_agg(
                   quote_ident(a.attname) || ' ' || format_type(a.atttypid, a.atttypmod)
                   || coalesce(' default ' || pg_get_expr(d.adbin, d.adrelid), '')
                   || case when a.attnotnull then ' not null' else '' end,
                   ',' || E'\n  ' order by a.attnum)
            from pg_attribute a
            left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
           where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped)
      || E'\n);'
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'

  union all
  /* ── 4. 約束：PK / UNIQUE / CHECK（外鍵另外一段，因為要等所有表都建好）── */
  select 4,
         case con.contype when 'p' then 1 when 'u' then 2 else 3 end,
         con.conrelid::regclass::text || '.' || con.conname,
         'alter table ' || quote_ident(con.conrelid::regclass::text)
      || ' add constraint ' || quote_ident(con.conname) || ' '
      || pg_get_constraintdef(con.oid)
      || case when not con.convalidated then '' else '' end || ';'
    from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and con.contype in ('p','u','c')

  union all
  /* ── 5. 外鍵（最後才加，否則建表順序會卡）── */
  select 5, 0, con.conrelid::regclass::text || '.' || con.conname,
         'alter table ' || quote_ident(con.conrelid::regclass::text)
      || ' add constraint ' || quote_ident(con.conname) || ' '
      || pg_get_constraintdef(con.oid) || ';'
    from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and con.contype = 'f'

  union all
  /* ── 6. 索引（排除由約束自動建立的）──
     🔴 這一段特別重要：`uq_members_line_user` 就是只存在這裡、
        `sql/` 裡完全找不到的那個承重牆。 */
  select 6, 0, i.relname, pg_get_indexdef(x.indexrelid) || ';'
    from pg_index x
    join pg_class i on i.oid = x.indexrelid
    join pg_class t on t.oid = x.indrelid
    join pg_namespace n on n.oid = t.relnamespace
   where n.nspname = 'public'
     and not exists (select 1 from pg_constraint con where con.conindid = x.indexrelid)

  union all
  /* ── 7. 函式 ──
     ⚠ 一定要 `prokind = 'f'`：pg_get_functiondef 對聚合函式會直接拋
       `42809: "array_agg" is an aggregate function`（硬規則 3.7）。
     ⚠ 用 `pronamespace = 'public'::regnamespace` 直接比對，不 join ——
       WHERE 裡的函式可能在 join 過濾之前就被求值，規劃器不保證順序。 */
  select 7, 0, p.proname,
         pg_get_functiondef(p.oid) || ';'
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prokind = 'f'

  union all
  /* ── 7.5 函式授權 ──
     🔴 DROP 會把 GRANT 一起丟掉（硬規則 2），所以 baseline 一定要含它，
        否則重建出來的資料庫「函式都在但前端叫不動」。 */
  select 8, 0, p.proname || ':grant',
         'grant execute on function ' || p.oid::regprocedure::text || ' to '
      || (select string_agg(r, ', ') from unnest(array['anon','authenticated','service_role']) r
           where has_function_privilege(r, p.oid, 'execute')) || ';'
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prokind = 'f'
     and (has_function_privilege('anon', p.oid, 'execute')
       or has_function_privilege('authenticated', p.oid, 'execute')
       or has_function_privilege('service_role', p.oid, 'execute'))

  union all
  /* ── 8. 觸發器 ── */
  select 9, 0, t.tgname, pg_get_triggerdef(t.oid) || ';'
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and not t.tgisinternal

  union all
  /* ── 9. 檢視表 ──
     ⚠ 含 v_real_* 那 12 個 —— 它們是報表看不到測試資料的那一層。 */
  select 10, 0, c.relname,
         'create or replace view ' || quote_ident(c.relname) || ' as ' || E'\n'
      || pg_get_viewdef(c.oid, true)
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'v'

  union all
  /* ── 10a. 開啟 RLS ── */
  select 11, 0, c.relname,
         'alter table ' || quote_ident(c.relname) || ' enable row level security;'
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity

  union all
  /* ── 10b. RLS policy ──
     🔴 那 24 條 org 級 policy 全在這裡（待辦 21）。 */
  select 12, 0, pol.tablename || '.' || pol.policyname,
         'create policy ' || quote_ident(pol.policyname)
      || ' on ' || quote_ident(pol.tablename)
      || ' as ' || pol.permissive
      || ' for ' || pol.cmd
      || ' to ' || array_to_string(pol.roles, ', ')
      || coalesce(' using (' || pol.qual || ')', '')
      || coalesce(' with check (' || pol.with_check || ')', '') || ';'
    from pg_policies pol
   where pol.schemaname = 'public'
)
select
  /* 每個物件前面加一行註解，重建時看得出斷在哪 */
  '-- [' || sort || '.' || sub || '] ' || name || E'\n' || ddl || E'\n' as ddl
from parts
order by sort, sub, name;

/* ============================================================
   ⚠ 這份 baseline **沒有**包含的東西（要另外處理）

   1. **種子資料** —— orgs / stores / tables / products / stake_levels /
      member_tiers / product_taxonomy / topup_plans / coupons。
      那些是「營運設定」不是結構，重建時要另外匯入。

   2. **Storage 的 bucket 與 policy** —— 它們在 `storage` schema：
      ```sql
      select * from storage.buckets;
      select * from pg_policies where schemaname = 'storage';
      ```
      現況：`member-avatars`（private, 3MB）／`store-photos`（public, 5MB），
      🔴 四條 avatar policy **只比對 bucket_id，沒有檢查是不是自己的檔案**。

   3. **pg_cron 排程** —— 在 `cron` schema：
      ```sql
      select jobname, schedule, command from cron.job;
      ```
      現況五個：auto-seat-matched／migi_sweep_expired／cleanup-empty-sessions／
      gen-recurring-instances／daily-wallet-audit。

   4. **Edge Functions** —— 不在資料庫裡，原始碼在 `supabase/functions/`。

   5. **auth schema** —— Supabase 自己管理，不要匯出也不要重建。
   ============================================================ */
