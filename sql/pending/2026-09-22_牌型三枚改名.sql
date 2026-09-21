-- ============================================================
-- 牌型收藏三枚改名（使用者指定）
--   tile_05  全求人 → 全求
--   tile_26  搶槓胡 → 搶槓
--   tile_04  讀聽   → 獨聽   ⚠ 連解鎖條件一起改
--
-- 🔴 為什麼 04 的條件也要改、另外兩枚不用：
--   「讀聽」是**錯字**（正確是「獨聽」—— 只聽一張），
--   條件「第一次讀聽胡牌」裡的是同一個錯字 ⇒ 名稱改了條件不改，
--   詳情頁就會同時出現「獨聽」和「讀聽」。
--   另外兩枚的條件（第一次全求人胡牌／第一次搶槓胡）寫的是**完整說法**，
--   不是錯字，保留。
--
-- ⚠ 事件名（pattern_duting／pattern_quanqiuren／pattern_qianggang）不動 ——
--   那是發射端契約，拼音 duting 本來就是「獨聽」。
-- ⚠ 已查證三個新名稱**沒有撞到**任何既有成就。
-- 🔴 冪等：用 code 當條件。
-- 硬規則 1.8：這份要留下 UPDATE ⇒ 驗證段一個字都不准 raise。
-- ============================================================

update public.achievements
   set name = case code
                when 'tile_05' then '全求'
                when 'tile_26' then '搶槓'
                when 'tile_04' then '獨聽'
              end,
       condition_text = case code
                          when 'tile_04' then '第一次獨聽胡牌'
                          else condition_text
                        end,
       updated_at = now()
 where code in ('tile_04', 'tile_05', 'tile_26')
   and deleted_at is null;


-- ---------- 驗證段 ----------
do $$
declare
  v_msg text := '';
  v_n   int;
  v_t   text;
begin
  -- ① 三枚改完的樣子（名稱｜條件）
  select string_agg(code || '  ' || name || '｜' || condition_text, E'\n' order by code)
    into v_t
    from public.achievements
   where code in ('tile_04', 'tile_05', 'tile_26');
  v_msg := '① 三枚改名後（名稱｜條件）' || E'\n' || coalesce(v_t, '🔴 一枚都查不到');

  -- ② 錯字「讀聽」全表不管在哪個欄位都不在了
  select count(*) into v_n from public.achievements
   where deleted_at is null
     and (name like '%讀聽%' or condition_text like '%讀聽%' or coalesce(description, '') like '%讀聽%');
  v_msg := v_msg || E'\n\n② 錯字「讀聽」還在的：' || v_n || case when v_n = 0 then '  ✅' else '  🔴' end;

  -- ③ 正對照：05 與 26 的條件**不可以**被動到
  select count(*) into v_n from public.achievements
   where (code = 'tile_05' and condition_text = '第一次全求人胡牌')
      or (code = 'tile_26' and condition_text = '第一次搶槓胡');
  v_msg := v_msg || E'\n③ 全求／搶槓的條件原封不動：' || v_n || ' / 2' || case when v_n = 2 then '  ✅' else '  🔴' end;

  -- ④ 說明文案都沒被動到
  select count(*) into v_n from public.achievements
   where (code = 'tile_04' and description = '只等那一張')
      or (code = 'tile_05' and description = '全靠大家成全')
      or (code = 'tile_26' and description = '從別人的槓裡搶下來');
  v_msg := v_msg || E'\n④ 說明文案原封不動：' || v_n || ' / 3' || case when v_n = 3 then '  ✅' else '  🔴' end;

  -- ⑤ 全表沒有兩枚同名
  select count(*) - count(distinct name) into v_n from public.achievements where deleted_at is null;
  v_msg := v_msg || E'\n⑤ 同名的成就：' || v_n || case when v_n = 0 then '  ✅' else '  🔴 有重複' end;

  -- ⑥ 牌型收藏總數沒變
  select count(*) into v_n from public.achievements where group_key = '牌型收藏' and deleted_at is null;
  v_msg := v_msg || E'\n⑥ 牌型收藏總數：' || v_n || ' / 31' || case when v_n = 31 then '  ✅' else '  🔴' end;

  perform set_config('migi.rename3', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.rename3', true), ''), '🔴 沒有訊息') as "驗證";
