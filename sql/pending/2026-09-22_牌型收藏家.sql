-- ════════════════════════════════════════════════════════════════════
-- 2026-09-22 補牌型區的收藏套組：牌型收藏家（使用者拍板）
--
-- 解鎖 10 個牌型成就 → 稱號「胡牌達人」
-- ⚠ 9/20 依計台表重編時把原本兩枚牌型 meta 刪了，牌型區從此沒有收藏套組。
-- ⚠ 門檻 10 不是 5：牌型區 26 枚是最大的一區，平胡／門清／自摸這類日常牌型
--   5 枚很快就湊滿。
-- ⚠ 解鎖走既有的 ach_meta_tx（有 count 就是 meta，通用）⇒ 不用改任何函式。
-- ⚠ 實際要等電子計分上線才有人拿得到（牌型事件的發射端還沒接）。
-- ════════════════════════════════════════════════════════════════════

insert into achievements
  (org_id, code, name, description, condition_text, group_key, ui_category,
   struct, motivation, rarity, visibility, trigger, grants_title,
   is_signature, reward_points, is_active, sort)
select a.org_id, 'tile_32', '牌型收藏家', '什麼牌型你都胡過', '解鎖 10 個牌型成就',
       '牌型收藏', a.ui_category, 'specific', 'collection', 'rare', 'visible',
       '{"event":"achievement_unlocked","scope":"group_key","value":"牌型收藏","count":10}'::jsonb,
       '胡牌達人', false, 0, true,
       (select max(sort) + 1 from achievements where group_key = '牌型收藏' and deleted_at is null)
  from achievements a
 where a.code = 'tile_31' and a.deleted_at is null
   and not exists (select 1 from achievements x where x.code = 'tile_32' and x.org_id = a.org_id);

-- ════════════════════════════════════════════════════════════════════
-- 驗證（單一 SELECT，不 raise —— 硬規則 1.8）
-- ════════════════════════════════════════════════════════════════════
select * from (
  select 1 as n, '① 新成就在，而且只有一枚' as 項目,
         case when (select count(*) from achievements where code = 'tile_32' and deleted_at is null) = 1 then '✅' else '🔴' end as 結果,
         (select name || ' · ' || condition_text || ' · ' || rarity || ' · sort ' || sort from achievements where code = 'tile_32') as 細節
  union all
  select 2, '② 稱號是胡牌達人',
         case when (select grants_title from achievements where code = 'tile_32') = '胡牌達人' then '✅' else '🔴' end, null
  union all
  select 3, '③ ach_meta_count_tx 認得這個 scope（null ＝ 認不得，會被跳過）',
         case when public.ach_meta_count_tx((select id from members where deleted_at is null limit 1), 'group_key', '牌型收藏') is not null
              then '✅' else '🔴' end, null
  union all
  -- 算式：26 枚一般 ＋ 1 枚收藏套組 = 27
  select 4, '④ 牌型區共 27 枚（26 ＋ 1）',
         case when (select count(*) from achievements where group_key = '牌型收藏' and deleted_at is null) = 27 then '✅' else '🔴' end,
         (select count(*)::text from achievements where group_key = '牌型收藏' and deleted_at is null)
  union all
  -- 算式：新手村制霸 ＋ MIGI ＋ 胡牌達人 = 3
  select 5, '⑤ 線上會發稱號的成就共 3 枚',
         case when (select count(*) from achievements where deleted_at is null and grants_title is not null) = 3 then '✅' else '🔴' end,
         (select string_agg(code || '→' || grants_title, '、' order by sort) from achievements where deleted_at is null and grants_title is not null)
) v order by n;
