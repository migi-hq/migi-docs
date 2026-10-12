-- 2026-10-13 選牌型頁的牌型順序改成使用者指定的新順序
--
-- 使用者給的順序（沒台固定第一、MIGI 固定最右下，這兩格是前端擺的，不靠 sort）：
--   東南西北、中發白、邊張單吊中洞、搶槓、門清、槓上開花、海底撈月、平胡、門清自摸、全求、
--   碰碰胡、三暗刻、四暗刻、五暗刻、小三元、大三元、小四喜、大四喜、混一色、清一色、字一色、
--   正花、花槓、七搶一、八仙過海、全紅、骰龜、豹子、天胡
--
-- · 只改 scoring_patterns.sort（資料，不動結構）。讀它的只有 _tbl_state_for_device（order by sort），
--   前端照回傳順序畫 ⇒ 平板與手機下一次讀狀態就換順序，不用部署。
-- · sort 沒有唯一約束；新值每格隔 10，日後要插一格不用整批重排。
-- · 「自摸」前端不顯示（自動帶），給 5 排在最前面，不影響畫面。
-- · MIGI 給 300（最後），前端本來就把它固定在最右下。
-- · 胡牌與自摸兩個畫面共用這一份順序：只在其中一邊出現的牌型（門清／全求／搶槓 只在胡牌，
--   門清自摸／海底撈月／槓上開花／天胡 只在自摸）在另一邊就不出現，其餘照這個先後排。

update public.scoring_patterns p
   set sort = v.s, updated_at = now()
  from (values
    ('zimo',             5),
    ('triplet_wind',    10),   -- 東南西北
    ('triplet_dragon',  20),   -- 中發白
    ('duting',          30),   -- 邊張單吊中洞
    ('qianggang',       40),   -- 搶槓
    ('menqing',         50),   -- 門清
    ('gangshang',       60),   -- 槓上開花
    ('haidi',           70),   -- 海底撈月
    ('pinghu',          80),   -- 平胡
    ('menqing_tsumo',   90),   -- 門清自摸
    ('quanqiuren',     100),   -- 全求
    ('pengpenghu',     110),   -- 碰碰胡
    ('sananke',        120),   -- 三暗刻
    ('sianke',         130),   -- 四暗刻
    ('wuanke',         140),   -- 五暗刻
    ('xiaosanyuan',    150),   -- 小三元
    ('dasanyuan',      160),   -- 大三元
    ('xiaosixi',       170),   -- 小四喜
    ('dasixi',         180),   -- 大四喜
    ('hunyise',        190),   -- 混一色
    ('qingyise',       200),   -- 清一色
    ('ziyise',         210),   -- 字一色
    ('zhenghua',       220),   -- 正花
    ('huagang',        230),   -- 花槓
    ('qiqiangyi',      240),   -- 七搶一
    ('baxian',         250),   -- 八仙過海
    ('quanhong',       260),   -- 全紅
    ('shaigui',        270),   -- 骰龜
    ('baozi',          280),   -- 豹子
    ('tianhu',         290),   -- 天胡
    ('migi',           300)    -- MIGI（前端固定最右下）
  ) as v(code, s)
 where p.code = v.code;

-- ── 驗證（單一 SELECT，不用 raise）────────────────────────────
-- ① 上架中的牌型 31 個，每一個都拿到新的 sort（沒有漏掉、沒有沒上架的被改到也無妨）
-- ② sort 沒有重複
-- ③ 依 sort 排出來的順序（不含自摸、MIGI）逐字等於使用者給的那一串
-- ④ 胡牌畫面（排除只限自摸的）與自摸畫面（排除只限胡牌的）各自的順序，給人看一眼
with act as (
  select code, label, sort, result_only from public.scoring_patterns where is_active
), ordered as (
  select string_agg(label, '、' order by sort) as s
    from act where code not in ('zimo', 'migi')
)
select
  (select case when count(*) = 31 and count(*) filter (where sort is null) = 0
               then '✅ ① 上架 31 個都有 sort' else '🔴 ① 上架 ' || count(*) || ' 個，' end from act)
  || E'\n' ||
  (select case when count(*) = count(distinct sort) then '✅ ② sort 沒有重複'
               else '🔴 ② sort 有重複' end from act)
  || E'\n' ||
  (select case when s = '東南西北、中發白、邊張單吊中洞、搶槓、門清、槓上開花、海底撈月、平胡、門清自摸、全求、碰碰胡、三暗刻、四暗刻、五暗刻、小三元、大三元、小四喜、大四喜、混一色、清一色、字一色、正花、花槓、七搶一、八仙過海、全紅、骰龜、豹子、天胡'
               then '✅ ③ 順序與指定的一致' else '🔴 ③ 順序不一致：' || coalesce(s, '（空）') end from ordered)
  || E'\n④ 胡牌：' ||
  coalesce((select string_agg(label, '、' order by sort) from act
             where code not in ('zimo', 'migi') and coalesce(result_only, 'ron') = 'ron'), '（空）')
  || E'\n④ 自摸：' ||
  coalesce((select string_agg(label, '、' order by sort) from act
             where code not in ('zimo', 'migi') and coalesce(result_only, 'tsumo') = 'tsumo'), '（空）')
  as "驗證";
