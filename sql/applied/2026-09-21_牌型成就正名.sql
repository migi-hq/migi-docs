-- ============================================================
-- 牌型收藏的三枚成就正名：拿掉「第一個」
--   第一個混一色 → 混一色
--   第一個清一色 → 清一色
--   第一個碰碰胡 → 碰碰胡
--
-- 🔴 為什麼是三枚不是一枚（使用者只指出清一色）：
--    牌型收藏 31 枚裡，其餘 28 枚**全部**直接用牌型名
--    （門清／平胡／小三元／大三元／四暗刻／天胡…），
--    只有這三枚多了「第一個」。
--    ⇒ 只改清一色的話，畫面上會變成
--      「第一個混一色」與「清一色」並排 —— **比現在更不一致**。
--
-- ⚠ 新手引導那 6 枚「第一個 X」**不改**（稱號／頭像框／配件／點心／
--   每週任務／牌咖）—— 那幾枚講的是「**第一次拿到**」這件事本身，
--   不是某個牌型的名字。兩者形狀像但語意不同。
--
-- ⚠ `condition_text` 也不改（「第一次胡出清一色」）——
--   那是**解鎖條件**，「第一次」在那裡是必要的。
--
-- ⚠ `sql/applied/2026-09-20_成就匯入階段1.sql` **不會回頭改** ——
--   那是歷史，記的是「當時跑了什麼」。改它就是偽造紀錄。
--
-- 🔴 冪等：用 `code` 當條件，重跑只是把已經正確的值再寫一次。
--   （用 `name like '第一個%'` 的話第二次會 0 列，看起來像失敗。）
--
-- 硬規則 1.8：這份要留下 UPDATE ⇒ **驗證段一個字都不准 raise**。
-- ============================================================

update public.achievements
   set name = case code
                when 'tile_18' then '混一色'
                when 'tile_19' then '清一色'
                when 'tile_20' then '碰碰胡'
              end,
       updated_at = now()
 where code in ('tile_18', 'tile_19', 'tile_20')
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
   where code in ('tile_18', 'tile_19', 'tile_20');
  v_msg := '① 三枚改名後' || E'\n' || coalesce(v_t, '🔴 一枚都查不到');

  -- ② 牌型收藏這一組還有沒有叫「第一個」的
  select count(*) into v_n
    from public.achievements
   where group_key = '牌型收藏' and deleted_at is null and name like '第一個%';
  v_msg := v_msg || E'\n\n② 牌型收藏還叫「第一個」的：' || v_n
        || case when v_n = 0 then '  ✅' else '  🔴 還有漏的' end;

  -- ③ 🔴 正對照（硬規則 3.55）：新手引導那 6 枚**不可以**被誤改。
  --    少了這一格，一句 `set name = replace(name,'第一個','')` 會讓
  --    「第一個牌咖」變成「牌咖」而這裡照樣全綠。
  select count(*) into v_n
    from public.achievements
   where group_key = '新手引導' and deleted_at is null and name like '第一個%';
  v_msg := v_msg || E'\n③ 新手引導仍叫「第一個」的：' || v_n
        || case when v_n = 6 then '  ✅（本來就該是 6 枚）' else '  🔴 被誤改了' end;

  -- ④ 解鎖條件與說明不可以被動到
  select count(*) into v_n
    from public.achievements
   where code in ('tile_18', 'tile_19', 'tile_20')
     and condition_text in ('第一次胡出混一色', '第一次胡出清一色', '第一次胡出碰碰胡');
  v_msg := v_msg || E'\n④ 解鎖條件原封不動：' || v_n || ' / 3'
        || case when v_n = 3 then '  ✅' else '  🔴' end;

  -- ⑤ 這一組總數沒變（沒有多寫或少寫）
  select count(*) into v_n
    from public.achievements
   where group_key = '牌型收藏' and deleted_at is null;
  v_msg := v_msg || E'\n⑤ 牌型收藏總數：' || v_n || ' / 31'
        || case when v_n = 31 then '  ✅' else '  🔴' end;

  perform set_config('migi.rename', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.rename', true), ''), '🔴 沒有訊息') as "驗證";
