/* ============================================================
   平胡照店內「詳細台數表」（2026-11-09 使用者：「修平胡」）

   台數表原文：全部都是順子而沒有刻子且無花牌（四風中發白），
              胡牌為雙頭或三頭，中洞單吊及自摸無平胡。

   計分板原本三種組合都選得到（會多算台）：
     · 自摸也能選平胡，系統還會自動再加自摸 1 台
     · 平胡可以跟「邊張單吊中洞」一起選
     · 平胡可以跟正花、花槓、七搶一、八仙過海一起選

   改法：只改牌型主檔一列資料，不改函式
     · result_only = 'ron'   只能胡別人打的（自摸時平胡那一格按不了，後端也擋）
     · conflicts 加 duting、zhenghua、huagang、qiqiangyi、baxian（雙向互斥，後端與畫面都讀這一欄）
   ⚠ 有花但不是正花的那幾張，計分板不知道客人摸過 ⇒ 擋不了，只能靠客人自己不按
   ⚠ 已經記下的舊局不重算（那是當時大家確認過的結果）
   ⚠ migi-table/src/preview.jsx 有一份主檔副本，同批改
   ============================================================ */

update public.scoring_patterns
   set result_only = 'ron',
       conflicts = array(select distinct c from unnest(conflicts || array['duting', 'zhenghua', 'huagang', 'qiqiangyi', 'baxian']) c order by c),
       updated_at = now()
 where code = 'pinghu';

/* ── 驗證（單一 SELECT；不用 raise）──────────────────────────── */
select
  case when p.result_only = 'ron' then '✅' else '🔴' end || ' ① 平胡只能胡別人打的（result_only = ' || coalesce(p.result_only, 'null') || '）' || E'\n' ||
  case when p.conflicts @> array['duting', 'zhenghua', 'huagang', 'qiqiangyi', 'baxian'] then '✅' else '🔴' end
    || ' ② 跟獨聽與四種花互斥' || E'\n' ||
  case when p.conflicts @> array['pengpenghu', 'sananke', 'sianke', 'wuanke', 'triplet_dragon', 'triplet_wind', 'ziyise'] then '✅' else '🔴' end
    || ' ③ 原本的七個互斥都還在' || E'\n' ||
  case when cardinality(p.conflicts) = 12 then '✅' else '🔴' end
    || ' ④ 互斥共 12 個（原本 7 ＋ 這次 5），實際 ' || cardinality(p.conflicts) || E'\n' ||
  case when (select count(*) from public.scoring_patterns where code = 'pinghu') = 1 then '✅' else '🔴' end
    || ' ⑤ 平胡只有一列' as "驗證"
from public.scoring_patterns p
where p.code = 'pinghu';
