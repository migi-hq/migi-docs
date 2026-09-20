-- ============================================================
-- 補正：ach_unlock_tx 的註解觸發了自己的驗證段（硬規則 3.5 第四次）
-- 2026-09-20　前置：2026-09-20_成就系統核心RPC.sql（已執行）
--
-- 【發生了什麼】
--   `2026-09-20_成就系統核心RPC.sql` 的驗證段第 ⑦ 格問
--   「有沒有函式會呼叫不存在的發放函式」，掃法是
--       pg_get_functiondef(oid) ~ 'grant_points'
--   而唯一命中的是 ach_unlock_tx 裡**我自己寫的一行註解**：
--       -- ⚠ 這裡刻意沒有發點數 —— grant_<那個字> 不存在
--
--   🔴 症狀正是硬規則 3.5 警告的那一種：**函式完全正確、驗證段永遠紅**。
--     而「一個永遠紅的檢查會讓人學會忽略紅色」，那比沒有檢查更危險。
--
-- 【這是第四次】
--   2026-08-23 掃 clerk      被自己的註解觸發
--   2026-08-25 掃 session_id 被「不回填 session_id」這句觸發
--   2026-09-08 掃「收入桶」   被「話術改名」那行觸發 —— **在引用這條規則的同時踩它**
--   2026-09-20 本次          掃發放函式名，被「刻意沒有發它」這句觸發
--
-- 【兩邊都要修，不是只改一邊】
--   ① 註解改成文字描述，不寫出那個識別字本身
--   ② 驗證段改成**逐行印出來讓人判讀**，不要回傳一個是非題
--      （硬規則 3.5 的正解，範本：sql/checks/2026-08-25_驗證快速結帳沒碰桌次.sql）
--
-- ⚠ 簽名不變 ⇒ CREATE OR REPLACE ⇒ 不用 DROP、不丟 GRANT
--   （前一份已經 revoke 過 public／anon，這一份不會把它還原）
-- ============================================================

create or replace function public.ach_unlock_tx(
  p_member uuid, p_code text, p_idem text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
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

  -- ⚠ 這裡**刻意不發點數**：那支發放函式今天不存在，而且 §8.5 的鐵則是
  --   「成就給徽章與稱號，點數是最克制的那一層」。reward_points 欄位留著，
  --   日後真的要發再接。
  --   🔴 這段話刻意不寫出那個函式的識別字 —— 寫了會觸發掃描（硬規則 3.5）
  return jsonb_build_object('ok', true, 'unlocked', true,
                            'code', p_code, 'title', a.grants_title);
end $$;


-- ============================================================
-- 驗證（🔴 不可以用 raise，硬規則 1.8）
-- ============================================================
do $$
declare v_msg text := ''; v_n int; v_t text;
begin
  -- ① 🎯 改成逐行印出來判讀，不回傳是非題（硬規則 3.5 的正解）
  select coalesce(string_agg(
           proname || '：' ||
           case when (regexp_match(pg_get_functiondef(oid), '([^\n]*grant_points[^\n]*)'))[1] ~ '^\s*--'
                then '（註解，無害）' else '🔴 程式碼' end,
           E'\n     '), '(沒有任何函式提到它)') into v_t
  from pg_proc
  where pronamespace='public'::regnamespace and prokind='f'
    and pg_get_functiondef(oid) ~ 'grant_points';
  v_msg := v_msg || '① 提到發放函式的：' || E'\n     ' || v_t;

  -- ② 真正該問的：有沒有**程式碼**在呼叫它（perform／select 開頭才算）
  select count(*) into v_n
  from pg_proc
  where pronamespace='public'::regnamespace and prokind='f'
    and pg_get_functiondef(oid) ~ '(perform|select|:=)\s+(public\.)?grant_points';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ② 沒有任何函式**呼叫**它（註解不算）'
    else '🔴 ② 有 ' || v_n || ' 支真的會在 runtime 炸' end;

  -- ③ 那支函式本身還在而且還是 DEFINER（補正沒有弄壞它）
  select count(*) into v_n from pg_proc
  where pronamespace='public'::regnamespace and proname='ach_unlock_tx' and prosecdef;
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '✅ ③ ach_unlock_tx 還在，而且還是 SECURITY DEFINER'
    else '🔴 ③ ach_unlock_tx 壞了' end;

  -- ④ 🔴 負對照：CREATE OR REPLACE 不該把授權還原（anon 仍然叫不動它）
  select count(*) into v_n from pg_proc p
  where p.pronamespace='public'::regnamespace and p.proname='ach_unlock_tx'
    and (exists (select 1 from aclexplode(p.proacl) a
                 where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE')
      or p.proacl is null
      or exists (select 1 from aclexplode(p.proacl) a
                 where a.grantee = 0 and a.privilege_type='EXECUTE'));
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ④ anon 與 PUBLIC 都還是叫不動它（授權沒被還原）'
    else '🔴 ④ 授權被還原了 —— 客人可以自己宣告解鎖任何成就' end;

  perform set_config('migi.verify', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify', true), ''), '🔴 沒有驗證訊息') as "驗證";
