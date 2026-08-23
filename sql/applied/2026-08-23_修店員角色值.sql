-- ════════════════════════════════════════════════════════════════════
-- 修 grant_staff_tx：角色值與 CHECK 對不上，導致它在預設用法下必定失敗
-- 2026-08-23
--
-- ═══ 問題 ═══
--
-- 🔴 三個地方講三套話：
--    · staff_role_check           允許 floor / manager / hq / owner
--    · grant_staff_tx 的守衛      只放行 clerk / manager / hq
--    · grant_staff_tx 的預設值    'clerk'
--
--    推論出來的實況：
--    · grant_staff_tx(member, store) 用預設值呼叫
--      → 守衛放行 'clerk' → INSERT 撞 staff_role_check → **23514 例外**
--    · 'floor' 與 'owner' 被函式自己的守衛擋掉，回 invalid_role
--    · **只有 manager 與 hq 兩個值能成功**
--
--    也就是說：**這支「把會員升級成店員」的函式，在預設用法下從來不會成功。**
--    而它是「店員登入」整條路的第一道門 —— 沒有它就沒有任何店員。
--
-- ⚠ 這是硬規則 7 那個形狀：CREATE FUNCTION 不檢查函式體裡的值是否合法，
--   所以它建得起來、看起來沒問題，要到真的被呼叫那一刻才炸。
--   staff 表現在只有 1 筆（估計），那一筆多半是手動 INSERT 進去的。
--
-- ═══ 決定：以 CHECK 為準 ═══
--
-- 資料庫那一套已經有資料在用，改它要動既有列；改函式只是改一行。
-- 而且 owner（老闆）這個級別留著有用。
--
--    floor    一般店員（預設）
--    manager  店長
--    hq       總部
--    owner    老闆
--
-- ⚠ 這些是**內部代號**，畫面一律顯示中文，之後改中文名不影響資料。
-- ⚠ **權限差異（誰能收桌／作廢訂單／看報表）這批不定義** ——
--   現在定會是憑空想像。等有實際場景再拍板。
--   這支只讓「升級店員」這個動作能執行。
--
-- ═══ 順帶記錄兩件查到的事（本次不動） ═══
--
-- ⚠ staff.auth_uid 是**沒有人讀的欄位**：current_staff() 的判準是
--   `members.line_user_id = auth.jwt() ->> 'sub'`，完全沒用到 auth_uid。
--   那是舊設計（Supabase Auth email/password）的殘留，
--   而 docs/01-資料庫/資料架構基石規範.md:114 與
--   docs/02-POS與開桌/M2技術設計_桌台與配桌.md:468 還在講那套。
--   → 文件要更新，欄位先留著（不確定 migi-admin 有沒有在寫它）。
--
-- ⚠ 店員登入的實際卡點不在這支，是 **LINE Developers 帳號還沒申請**：
--   current_staff() 要 auth.jwt()->>'sub' 才有值，
--   而 POS 現在用 anon 沒有任何 JWT ——
--   ⑧ 實測 current_staff() 回空，正是這個原因。
-- ════════════════════════════════════════════════════════════════════

begin;

-- 簽名（參數型別）沒變 → 不需要 DROP。
-- ⚠ 預設值從 'clerk' 改成 'floor'，CREATE OR REPLACE 可以改預設值。
create or replace function public.grant_staff_tx(
  p_member_id uuid,
  p_store_id  uuid,
  p_role      text default 'floor'
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_org uuid; v_name text; v_id uuid;
begin
  -- ⚠ 這四個值必須與 staff_role_check 完全一致。
  --   2026-08-23 之前這裡寫的是 ('clerk','manager','hq') —— 與 CHECK 三個不同：
  --   clerk 不在 CHECK 裡（送了會 23514）、floor 與 owner 在 CHECK 裡卻被擋掉。
  --   結果是預設用法必定失敗，而那正是「把會員升級成店員」的標準用法。
  if p_role not in ('floor', 'manager', 'hq', 'owner') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_role',
      'message', '角色只能是 floor（一般店員）／manager（店長）／hq（總部）／owner（老闆）');
  end if;

  select org_id, display_name into v_org, v_name
    from members where id = p_member_id and deleted_at is null;
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found',
      'message', '找不到這位會員');
  end if;

  -- 已有記錄則更新角色（含已軟刪除的復職情況）
  select id into v_id from staff
   where member_id = p_member_id and store_id is not distinct from p_store_id;
  if v_id is not null then
    update staff set role = p_role, deleted_at = null,
                     name = coalesce(name, v_name), updated_at = now()
     where id = v_id;
    return jsonb_build_object('ok', true, 'staff_id', v_id, 'action', 'updated', 'role', p_role);
  end if;

  insert into staff(org_id, member_id, store_id, name, role)
  values (v_org, p_member_id, p_store_id, v_name, p_role)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'staff_id', v_id, 'action', 'created', 'role', p_role);
end $function$;

commit;


-- ════════════════════════════════════════════════════════════════════
-- 驗證（單一 SELECT）
-- ════════════════════════════════════════════════════════════════════
select 項目, 結果
from (
  select 1 as ord, '① 版本數（應為 1）' as 項目,
    (select count(*)::text from pg_proc
      where pronamespace='public'::regnamespace and proname='grant_staff_tx') as 結果

  union all select 2, '② 預設值（應為 floor）',
    coalesce((select pg_get_function_arguments(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='grant_staff_tx' limit 1),
             '❌ 不存在')

  -- 🔴 這一項是重點：函式裡的四個值與 CHECK 必須完全一致。
  --    只看「有沒有改」不夠 —— 要證明它們對得上。
  union all select 3, '③ 🔴 函式的四個角色值是否與 CHECK 完全一致',
    case when
      (select pg_get_functiondef(oid) from pg_proc
        where pronamespace='public'::regnamespace and proname='grant_staff_tx' limit 1)
        like '%''floor'', ''manager'', ''hq'', ''owner''%'
      and (select pg_get_constraintdef(oid) from pg_constraint
            where conrelid='public.staff'::regclass and conname='staff_role_check')
        like '%floor%manager%hq%owner%'
    then '是（四個都對得上）' else '❌ 仍然對不上' end

  -- 🔴 這一項我寫錯了，執行時回「❌ 還有 clerk」——
  --    但那是因為 clerk 出現在我自己寫的**註解**裡（「之前這裡寫的是 clerk…」）。
  --    行為上 clerk 確實被擋掉了，證據是 ⑳ 回 invalid_role。
  --    ⚠ 教訓：**檢查「有沒有這個字」會被註解騙，要檢查行為。**
  --      跟同一天 jsxcomment.py 那個誤判是同一類 —— 儀器要能分辨。
  --      留著這一行是為了記錄這個錯，不是因為它有用。
  union all select 4, '④（寫壞的檢查，看 ⑳ 就好）函式文字裡有沒有 clerk',
    case when (select pg_get_functiondef(oid) from pg_proc
                where pronamespace='public'::regnamespace and proname='grant_staff_tx' limit 1)
              like '%clerk%' then '有（在註解裡，非程式碼）' else '沒有' end

  union all select 10, '⑩ 現有 staff 資料（角色必須都在 CHECK 裡）',
    coalesce((select string_agg(coalesce(s.name, '(無名)') || ' · ' || s.role ||
                                coalesce(' · ' || st.name, ' · (無門市=總部)') ||
                                case when s.deleted_at is not null then ' · 已離職' else '' end,
                                chr(10) order by s.role)
                from staff s left join stores st on st.id = s.store_id),
             '（沒有任何 staff）')

  union all select 11, '⑪ 有多少 staff 綁了 member（登入靠這個關聯）',
    coalesce((select count(*) filter (where member_id is not null)::text || ' / ' ||
                     count(*)::text || ' 筆有綁 member'
                from staff where deleted_at is null), '—')

  -- 煙霧測試：兩題都在寫入之前就回傳，不會留下任何 staff 列
  union all select 20, '⑳ 煙霧測試：不合法角色（應回 invalid_role）',
    coalesce(grant_staff_tx('00000000-0000-0000-0000-000000000000'::uuid,
                            null, 'clerk')->>'reason', '❌ 沒有回 reason')

  union all select 21, '㉑ 煙霧測試：不存在的會員 + 預設角色（應回 member_not_found）',
    coalesce(grant_staff_tx('00000000-0000-0000-0000-000000000000'::uuid,
                            null)->>'reason', '❌ 沒有回 reason')
) x
order by ord;

-- ── 怎麼看 ────────────────────────────────────────────────
-- ③ 是這支唯一真正重要的一項：**證明兩邊對得上**，不是「我改了」。
-- ㉑ 用預設值呼叫且**沒有回 invalid_role** —— 那就是修好了：
--    改之前預設值是 clerk，會先過守衛再撞 CHECK 拋 23514；
--    現在預設值是 floor，會走到 member_not_found 才停。
--    ⚠ 這一題測的是「預設值本身合法」，不是「函式能建立店員」。
--
-- ⚠ 真的建立一位店員要等 migi-admin 有介面，或手動：
--      select grant_staff_tx('<member_id>', '<store_id>', 'floor');
--    但**建了現在也還登不進 POS** —— current_staff() 要 auth.jwt()->>'sub'，
--    而 POS 用 anon 沒有 JWT。那一段卡在 LINE Developers 帳號還沒申請。
