-- ════════════════════════════════════════════════════════════════════
-- current_staff() 補回總部（Email）那條身分路徑
-- 2026-08-23
--
-- ═══ 問題 ═══
--
-- 系統本來就有**兩條身分路徑**，`current_org_id()` 兩條都認：
--
--   select coalesce(
--     (select org_id from staff   where auth_uid = auth.uid() …),            ← 總部 Email
--     (select org_id from members where line_user_id = auth.jwt()->>'sub' …) ← LINE
--   );
--
-- 🔴 但 `current_staff()` **只認 LINE**，而且用 INNER JOIN members：
--
--   from staff s join members m on m.id = s.member_id
--    where m.line_user_id = (auth.jwt() ->> 'sub')
--
--   → `staff.member_id` 是 null 的那一列**永遠 join 不到**。
--     現有唯一那筆「MIGI 總部管理員 · hq」正是這種形狀
--     （auth_uid 有值、member_id 空，對得上 admin@migi.tw）。
--     **總部人員永遠不會被認成 staff。**
--
-- ⚠ 這不是「當初決策錯了」。總部走 Supabase Auth Email 有三個成立的理由
--   （docs/06-架構藍圖/總部後台架構藍圖.md:33、決策紀錄.md 第八節）：
--     ① 總部員工不是會員，不打牌、不需要 LINE
--     ② **開機問題**：第一個管理員沒有人能升級他（那時一個 staff 都沒有），
--        必須有一條不依賴既有 staff 的路 → Dashboard 手動建 Auth 帳號
--     ③ 職能不同：HQ 管全集團建檔，POS 管單店現場
--   而 `staff.auth_uid` **正是為那條路存在的**
--   （基石規範:114 原文：「insert 進 staff(role='hq', auth_uid=該帳號的 auth id)」）。
--
--   → 錯的是後來的漂移：店員登入改用 LINE 時，current_staff() 被寫成只認 LINE，
--     **總部那條路被順手切掉而沒有人發現**。
--
-- ═══ 為什麼現在改 ═══
--
-- ✅ 影響面幾乎為零（2026-08-23 查證）：
--    · 用到 current_staff / has_store_access 的 RLS policy：**0 條**
--    · 唯一呼叫 current_staff() 的函式：has_store_access（而它也沒人用）
--    現在改是零風險；等 policy 掛上去之後再改就不是了。
--
-- ⚠ 順帶記錄一個**這支不處理、但必須知道**的洞：
--    整套 RLS 只靠 current_org_id()（24 條 policy），
--    而 has_store_access() 沒有接到任何 policy 上 ——
--    **「店員只看自己店」那道門市隔離存在，但沒插電。**
--    🔴 同一個洞對會員更嚴重：待辦 14 給會員發 JWT 之後，
--       current_org_id() 會走 members 那條路回傳 org，
--       那位會員就**通過全部 24 條 org 級 policy**。
--       → 待辦 14 不是「換發 JWT」而已，是「換發 JWT ＋ 同時收緊 policy」。
-- ════════════════════════════════════════════════════════════════════

begin;

-- 回傳型別與參數皆未變 → 不需要 DROP
create or replace function public.current_staff()
returns table(staff_id uuid, member_id uuid, store_id uuid, role text, name text)
language sql
stable security definer
set search_path to 'public'
as $function$
  select s.id, s.member_id, s.store_id, s.role, s.name
    from staff s
    -- ⚠ LEFT JOIN 不是 INNER：總部那條路的 staff.member_id 是 null，
    --   INNER JOIN 會把整列濾掉，而那正是原本的 bug。
    left join members m
           on m.id = s.member_id
          and m.deleted_at is null
   where s.deleted_at is null
     and (
       -- ① 總部：Supabase Auth Email 帳號 → staff.auth_uid
       --    ⚠ auth.uid() 在 anon 之下是 null，`s.auth_uid = null` 的結果是
       --      NULL 不是 TRUE，所以會被 WHERE 濾掉 —— 這是對的行為。
       --      （同 CLAUDE.md 2026-08-19 那條 NULL 陷阱：NULL 不等於 TRUE。）
       s.auth_uid = auth.uid()
       -- ② 店員／會員：LINE → members.line_user_id
       --    同理，沒有 JWT 時 auth.jwt()->>'sub' 是 null，整條也會是 NULL。
       or m.line_user_id = (auth.jwt() ->> 'sub')
     )
   -- 一個人可能在多店有 staff 列（例如店長兼支援）——
   -- 取權限最高的那一列。這是原本就有的行為，保留。
   order by case s.role when 'hq' then 1 when 'manager' then 2 else 3 end
   limit 1;
$function$;

commit;


-- ════════════════════════════════════════════════════════════════════
-- 驗證（單一 SELECT）
-- ⚠ SQL Editor 裡 auth.uid() 與 auth.jwt() 都是 null，**無法直接測登入**。
--   所以下面用「把 auth.uid() 換成真實值」的等價查詢來證明 JOIN/WHERE 的邏輯，
--   而不是宣稱「應該會動」。
-- ════════════════════════════════════════════════════════════════════
select 項目, 結果
from (
  select 1 as ord, '① 版本數（應為 1）' as 項目,
    (select count(*)::text from pg_proc
      where pronamespace='public'::regnamespace and proname='current_staff') as 結果

  union all select 2, '② 定義是否已改成 LEFT JOIN（應為 是）',
    case when (select pg_get_functiondef(oid) from pg_proc
                where pronamespace='public'::regnamespace and proname='current_staff' limit 1)
              ilike '%left join members%' then '是' else '❌ 還是 INNER JOIN' end

  union all select 3, '③ 定義是否含 auth_uid 那條路（應為 是）',
    case when (select pg_get_functiondef(oid) from pg_proc
                where pronamespace='public'::regnamespace and proname='current_staff' limit 1)
              like '%s.auth_uid = auth.uid()%' then '是' else '❌ 沒有' end

  -- 🔴 這一項才是真的驗證：用總部那筆的 auth_uid 當作「假裝登入的身分」，
  --    跑一次與函式完全相同的 JOIN/WHERE，看撈不撈得到。
  --    改之前這個查詢會回 0 列（INNER JOIN 把 member_id=null 的濾掉）。
  union all select 10, '⑩ 🔴 模擬總部登入：撈得到那筆 hq 嗎',
    coalesce((
      select s.name || ' · ' || s.role || ' · store=' ||
             coalesce(st.name, '(無門市＝總部)')
        from staff s
        left join members m on m.id = s.member_id and m.deleted_at is null
        left join stores  st on st.id = s.store_id
       where s.deleted_at is null
         and (s.auth_uid = (select auth_uid from staff
                             where auth_uid is not null and deleted_at is null limit 1)
              or m.line_user_id = (auth.jwt() ->> 'sub'))
       order by case s.role when 'hq' then 1 when 'manager' then 2 else 3 end
       limit 1
    ), '❌ 撈不到 —— LEFT JOIN 或 auth_uid 條件沒生效')

  union all select 11, '⑪ 現在直接呼叫 current_staff()（SQL Editor 無 auth，應為空）',
    coalesce((select s.name from current_staff() s limit 1),
             '（空 —— 正確：SQL Editor 沒有 auth session）')

  union all select 12, '⑫ 影響面覆核：用到 current_staff/has_store_access 的 policy 數（應為 0）',
    coalesce((select count(*)::text || ' 條'
                from pg_policies
               where schemaname='public'
                 and (coalesce(qual,'') like '%current_staff%'
                   or coalesce(qual,'') like '%has_store_access%'
                   or coalesce(with_check,'') like '%current_staff%'
                   or coalesce(with_check,'') like '%has_store_access%')), '—')
) x
order by ord;

-- ── 怎麼看 ────────────────────────────────────────────────
-- ⑩ 是唯一真正證明修好了的一項：**改之前它會回 ❌**（INNER JOIN 把
--    member_id=null 的總部那筆濾掉），改之後應該撈得到「MIGI 總部管理員 · hq」。
-- ⑪ 回空是**正確的**，不是失敗 —— SQL Editor 沒有 auth session。
--    要真的測登入只能從 migi-admin 的畫面上測。
-- ⑫ 覆核影響面仍是 0，代表這次改動確實沒有牽動任何 RLS。
