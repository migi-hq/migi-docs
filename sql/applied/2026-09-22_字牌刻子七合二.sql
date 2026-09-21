-- ============================================================
-- 牌型收藏：七枚字牌刻子合併成兩枚（使用者拍板）
--
--   tile_06  三個紅中 ─┐
--   tile_07  三個發財  ├→ tile_06「三元牌」 胡牌時持有中、發、白任一組刻子
--   tile_08  三個白板 ─┘
--   tile_09  三個東風 ─┐
--   tile_10  三個南風  ├→ tile_09「風牌」   胡牌時持有東、南、西、北任一組刻子
--   tile_11  三個西風  │
--   tile_12  三個北風 ─┘
--
-- 🎯 為什麼合併：
--   · 比較難的版本本來就有 —— 三元牌 → 小三元 → 大三元、風牌 → 小四喜 → 大四喜，
--     合併後剛好兩條由淺到深的路。拆成七枚只是把第一階切成七份。
--   · 七枚佔牌型收藏 31 枚的將近四分之一，而且全是最容易的普通款。
--   · 七枚都還沒畫圖，合併後只要畫兩張。
--
-- 🔴 店裡的規則：**見字就有台**（2026-09-22 使用者更正）——
--   任何字牌刻子（三元牌、風牌）都算台，**不限門風或圈風**。
--   我一度建議風牌只算門風／圈風，那是照別的規則套的，錯的。
--
-- ⚠ 保留 tile_06、tile_09 兩個 code（改名＋改條件＋改事件），
--   其餘五枚**軟刪除**（deleted_at ＋ is_active = false）。
--   已查證：七枚解鎖 0 人、tiers 0 列 ⇒ 沒有任何人會因此少一枚成就。
--   讀取成就的三支函式（get_my_achievements_tx／fire_event_tx／ach_meta_tx）
--   都有過濾 deleted_at ⇒ App 上會真的消失。
--
-- ⚠ 事件：七個 pattern_triplet_red／green／white／east／south／west／north
--   → 兩個 pattern_triplet_dragon／pattern_triplet_wind。
--   已查證**沒有任何函式**在送 pattern_triplet_*（要等電子計分），
--   ⇒ 現在改契約是零成本；上線後再改就要動計分程式。
--
-- 🔴 冪等：用 code 當條件；軟刪除只動 deleted_at 還是 null 的列。
-- 硬規則 1.8：這份要留下資料 ⇒ 驗證段一個字都不准 raise。
-- ============================================================

update public.achievements
   set name           = '三元牌',
       condition_text = '胡牌時持有中、發、白任一組刻子',
       description    = '中發白，見字就有台',
       trigger        = '{"event": "pattern_triplet_dragon"}'::jsonb,
       updated_at     = now()
 where code = 'tile_06' and deleted_at is null;

update public.achievements
   set name           = '風牌',
       condition_text = '胡牌時持有東、南、西、北任一組刻子',
       description    = '東南西北，見字就有台',
       trigger        = '{"event": "pattern_triplet_wind"}'::jsonb,
       updated_at     = now()
 where code = 'tile_09' and deleted_at is null;

update public.achievements
   set deleted_at = now(),
       is_active  = false,
       updated_at = now()
 where code in ('tile_07', 'tile_08', 'tile_10', 'tile_11', 'tile_12')
   and deleted_at is null;


-- ---------- 驗證段 ----------
do $$
declare
  v_msg text := '';
  v_n   int;
  v_t   text;
begin
  -- ① 合併後的兩枚
  select string_agg(code || '  ' || name || '｜' || condition_text || '｜' || (trigger->>'event'), E'\n' order by code)
    into v_t
    from public.achievements
   where code in ('tile_06', 'tile_09') and deleted_at is null;
  v_msg := '① 合併後（名稱｜條件｜事件）' || E'\n' || coalesce(v_t, '🔴 查不到');

  -- ② 五枚已軟刪除而且關閉
  select count(*) into v_n
    from public.achievements
   where code in ('tile_07', 'tile_08', 'tile_10', 'tile_11', 'tile_12')
     and deleted_at is not null and not is_active;
  v_msg := v_msg || E'\n\n② 已軟刪除並關閉：' || v_n || ' / 5' || case when v_n = 5 then '  ✅' else '  🔴' end;

  -- ③ 牌型收藏剩幾枚（算式：31 − 5 ＝ 26）
  select count(*) into v_n
    from public.achievements where group_key = '牌型收藏' and deleted_at is null;
  v_msg := v_msg || E'\n③ 牌型收藏：' || v_n || ' 枚' || case when v_n = 26 then '  ✅（31 − 5）' else '  🔴' end;

  -- ④ 全部成就剩幾枚（算式：62 − 5 ＝ 57）
  select count(*) into v_n from public.achievements where deleted_at is null;
  v_msg := v_msg || E'\n④ 全部成就：' || v_n || ' 枚' || case when v_n = 57 then '  ✅（62 − 5）' else '  🔴' end;

  -- ⑤ 舊的七個事件名，活著的成就一個都不再用
  select count(*) into v_n
    from public.achievements
   where deleted_at is null
     and trigger->>'event' in ('pattern_triplet_red', 'pattern_triplet_green', 'pattern_triplet_white',
                               'pattern_triplet_east', 'pattern_triplet_south', 'pattern_triplet_west',
                               'pattern_triplet_north');
  v_msg := v_msg || E'\n⑤ 還在用舊事件名的：' || v_n || case when v_n = 0 then '  ✅' else '  🔴' end;

  -- ⑥ 活著的成就，事件名沒有**意外**重複（重複會讓一次事件解鎖兩枚）
  --   🔴 第一次跑時這一格是紅的，而資料是對的：
  --     migi_01（MIGI）與 migi_02（十次 MIGI）**刻意共用** migi_hu ——
  --     一枚是第一次、一枚是累積十次。期望值寫成 0 是我沒查（硬規則 3.56）。
  --   ⇒ 排除那一對，並把實際重複的事件印出來，不回是非題。
  select count(*), coalesce(string_agg(e, '、'), '') into v_n, v_t
    from (select trigger->>'event' as e
            from public.achievements where deleted_at is null
           group by 1 having count(*) > 1) d
   where e <> 'migi_hu';
  v_msg := v_msg || E'\n⑥ 意外重複的事件名：' || v_n
        || case when v_n = 0 then '  ✅（migi_hu 由傳說兩枚刻意共用，已排除）' else '  🔴 ' || v_t end;

  -- ⑦ 🔴 正對照：往上那兩條路的四枚不可以被動到
  select count(*) into v_n
    from public.achievements
   where deleted_at is null and is_active
     and ((code = 'tile_13' and name = '小三元' and trigger->>'event' = 'pattern_xiaosanyuan')
       or (code = 'tile_14' and name = '大三元' and trigger->>'event' = 'pattern_dasanyuan')
       or (code = 'tile_15' and name = '小四喜' and trigger->>'event' = 'pattern_xiaosixi')
       or (code = 'tile_16' and name = '大四喜' and trigger->>'event' = 'pattern_dasixi'));
  v_msg := v_msg || E'\n⑦ 小三元／大三元／小四喜／大四喜原封不動：' || v_n || ' / 4' || case when v_n = 4 then '  ✅' else '  🔴' end;

  -- ⑧ 同名的成就
  select count(*) - count(distinct name) into v_n from public.achievements where deleted_at is null;
  v_msg := v_msg || E'\n⑧ 同名的成就：' || v_n || case when v_n = 0 then '  ✅' else '  🔴' end;

  perform set_config('migi.merge7', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.merge7', true), ''), '🔴 沒有訊息') as "驗證";
