-- ============================================================
-- 牌型新增「全紅」1 台（2026-10-10，使用者）
--
-- 只加主檔一列：平板的牌型清單（_tbl_state_for_device）與台數計算（tbl_submit_hand_tx）都讀主檔，
-- 不用改任何函式；教學模式的牌型清單也是從後端狀態來的。
--   1 台、只能選 1 次、胡牌與自摸都能選、有花無花都出現、不跟別的牌型互斥
--   排在「特殊」組：天胡(410) → 全紅(415) → MIGI(420) → 豹子(430)
-- ⚠ 使用者只給了「全紅 1 台」，其餘照最單純的設定；要改條件再另外改這一列。
-- ============================================================

insert into scoring_patterns (code, label, tai, max_count, group_key, needs_flower, result_only, dealer_only,
                              conflicts, achievement_event, sort, is_active, note)
values ('quanhong', '全紅', 1, 1, 'special', false, null, false,
        '{}', null, 415, true, '1 台（2026-10-10 使用者新增）');

-- ── 驗證（單一 SELECT）──
select string_agg(label || ' · ' || tai || ' 台 · 最多 ' || max_count || ' 次 · 排序 ' || sort
                  || case when is_active then '' else ' · 🔴 停用' end, E'\n' order by sort) as "驗證（特殊組，應為 天胡／全紅／MIGI／豹子）"
  from scoring_patterns
 where group_key = 'special';
