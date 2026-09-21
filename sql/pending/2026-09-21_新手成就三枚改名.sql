-- ============================================================
-- 新手引導三枚改名（使用者指定）
--   onboarding_22  團員報到       → 加入牌咖團
--   onboarding_20  第一次報到     → 每日報到
--   onboarding_19  第一個每週任務 → 每週任務
--
-- 🎯 22 改名之後與 21「建立牌咖團」成對 —— 一個開團、一個入團，
--   在同一格裡讀起來是對稱的。
-- ⚠ 「每日報到」「每週任務」與獎勵頁「小熊的房間」那兩張功能卡的
--   膠囊**同名**。那不是「一個名字兩個意思」：成就就是「完成那個功能」，
--   借用功能名讓客人一看就知道去哪裡拿。
--
-- ⚠ condition_text 不改（「第一次完成每日報到」…）—— 那是解鎖條件，
--   「第一次」在那裡是必要的。
-- ⚠ 已查證三個新名稱**沒有撞到**任何既有成就。
-- 🔴 冪等：用 code 當條件，重跑只是把已經正確的值再寫一次。
--
-- 硬規則 1.8：這份要留下 UPDATE ⇒ 驗證段一個字都不准 raise。
-- ============================================================

update public.achievements
   set name = case code
                when 'onboarding_22' then '加入牌咖團'
                when 'onboarding_20' then '每日報到'
                when 'onboarding_19' then '每週任務'
              end,
       updated_at = now()
 where code in ('onboarding_19', 'onboarding_20', 'onboarding_22')
   and deleted_at is null;


-- ---------- 驗證段（set_config ＋ 最後一支 SELECT 讀回來） ----------
do $$
declare
  v_msg text := '';
  v_n   int;
  v_t   text;
begin
  -- ① 三枚的現況
  select string_agg(code || '  ' || name, E'\n' order by code)
    into v_t
    from public.achievements
   where code in ('onboarding_19', 'onboarding_20', 'onboarding_22');
  v_msg := '① 三枚改名後' || E'\n' || coalesce(v_t, '🔴 一枚都查不到');

  -- ② 舊名全表都不存在了
  select count(*) into v_n
    from public.achievements
   where deleted_at is null and name in ('團員報到', '第一次報到', '第一個每週任務');
  v_msg := v_msg || E'\n\n② 舊名還在的：' || v_n
        || case when v_n = 0 then '  ✅' else '  🔴' end;

  -- ③ 🔴 正對照（硬規則 3.55）：其餘「第一個 X」不可以被誤改。
  --    期望值有算式（硬規則 3.56）：原本 6 枚
  --    （稱號 13／頭像框 14／配件 15／點心 16／每週任務 19／牌咖 25）
  --    − 這份改掉的 19 ＝ 5。
  select count(*) into v_n
    from public.achievements
   where group_key = '新手引導' and deleted_at is null and name like '第一個%';
  v_msg := v_msg || E'\n③ 新手引導仍叫「第一個」的：' || v_n
        || case when v_n = 5 then '  ✅（6 − 這次改掉的 1 ＝ 5）' else '  🔴 被誤改了' end;

  -- ④ 解鎖條件不可以被動到
  select count(*) into v_n
    from public.achievements
   where code in ('onboarding_19', 'onboarding_20', 'onboarding_22')
     and condition_text in ('第一次完成任一每週任務', '第一次完成每日報到', '第一次加入牌咖團');
  v_msg := v_msg || E'\n④ 解鎖條件原封不動：' || v_n || ' / 3'
        || case when v_n = 3 then '  ✅' else '  🔴' end;

  -- ⑤ 全表沒有兩枚同名（改名最容易撞的就是這個）
  select count(*) - count(distinct name) into v_n
    from public.achievements
   where deleted_at is null;
  v_msg := v_msg || E'\n⑤ 同名的成就：' || v_n
        || case when v_n = 0 then '  ✅' else '  🔴 有重複' end;

  -- ⑥ 新手引導總數沒變
  select count(*) into v_n
    from public.achievements
   where group_key = '新手引導' and deleted_at is null;
  v_msg := v_msg || E'\n⑥ 新手引導總數：' || v_n || ' / 29'
        || case when v_n = 29 then '  ✅' else '  🔴' end;

  perform set_config('migi.rename', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.rename', true), ''), '🔴 沒有訊息') as "驗證";
