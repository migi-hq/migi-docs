-- ============================================================
-- 牌型新增「骰龜」2 台（2026-10-10，使用者：「全紅右邊新增骰龜按鈕 2 台」）
--
-- 只加主檔一列：平板的牌型清單（_tbl_state_for_device）與台數計算（tbl_submit_hand_tx）都讀主檔，
-- 不用改任何函式；教學模式的牌型清單也是從後端狀態來的。
--   2 台、只能選 1 次、胡牌與自摸都能選、有花無花都出現、不跟別的牌型互斥
--   排在「特殊」組：天胡(410) → 全紅(415) → 骰龜(417) → MIGI(420) → 豹子(430)
--   （平板把 MIGI 固定放最右下，所以畫面上是 天胡、全紅、骰龜、豹子 …… MIGI）
-- ⚠ 使用者只給了「骰龜 2 台」，其餘照全紅的設定；要改條件再另外改這一列。
-- ============================================================

insert into scoring_patterns (code, label, tai, max_count, group_key, needs_flower, result_only, dealer_only,
                              conflicts, achievement_event, sort, is_active, note)
values ('shaigui', '骰龜', 2, 1, 'special', false, null, false,
        '{}', null, 417, true, '2 台（2026-10-10 使用者新增，排在全紅右邊）');

-- ── 驗證（單一 SELECT）──
select string_agg(label || ' · ' || tai || ' 台 · 最多 ' || max_count || ' 次 · 排序 ' || sort
                  || case when is_active then '' else ' · 🔴 停用' end, E'\n' order by sort) as "驗證（特殊組，應為 天胡／全紅／骰龜／MIGI／豹子）"
  from scoring_patterns
 where group_key = 'special';
