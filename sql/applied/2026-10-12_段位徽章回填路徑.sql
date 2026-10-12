/* ============================================================
   段位七枚徽章回填 badge_path
   2026-10-12 · MIGI 咪吉麻將

   🔴 順序：
     ① 先跑 2026-10-12_成就新增升上銅牌熊.sql（rank_18 要先存在）
     ② 把 docs/_資產/成就徽章/ 這七張傳進 Storage 的 achievement-badges：
        ach_rank_18.webp   升上銅牌熊（銅牌）
        ach_rank_02.webp   升上銀牌熊（銀牌）
        ach_rank_03.webp   升上金牌熊（金牌）
        ach_rank_04.webp   升上白金熊（白金）
        ach_rank_05.webp   升上鑽石熊（鑽石）
        ach_rank_06.webp   升上大師熊（紫盾）
        ach_season_06.webp 賽季雀神（皇冠）
     ③ 才跑這一份
   只回填「bucket 裡確實有那個檔案、而且 badge_path 還是空的」—— 沒傳到的維持 emoji，補傳後再跑一次即可。
   ============================================================ */

update public.achievements a
   set badge_path = 'ach_' || a.code || '.webp',
       updated_at = now()
 where a.badge_path is null
   and a.deleted_at is null
   and a.code in ('rank_18','rank_02','rank_03','rank_04','rank_05','rank_06','season_06')
   and exists (select 1 from storage.objects o
                where o.bucket_id = 'achievement-badges'
                  and o.name = 'ach_' || a.code || '.webp');

/* ── 驗證（單一 SELECT，不 raise）── */
with want as (select unnest(array['rank_18','rank_02','rank_03','rank_04','rank_05','rank_06','season_06']) code),
     st as (
  select w.code,
         a.badge_path,
         exists (select 1 from storage.objects o where o.bucket_id = 'achievement-badges' and o.name = 'ach_' || w.code || '.webp') uploaded
    from want w left join public.achievements a on a.code = w.code and a.deleted_at is null)
select concat_ws(E'\n',
  case when (select count(*) from st where badge_path = 'ach_' || code || '.webp') = 7
       then '✅ ① 七枚都指向自己的圖'
       else '🔴 ① 還沒指到圖：' || coalesce((select string_agg(code, '、') from st where badge_path is distinct from 'ach_' || code || '.webp'), '') end,
  case when (select count(*) from st where not uploaded) = 0
       then '✅ ② 七張都在 bucket 裡'
       else '🔴 ② bucket 裡沒有：' || (select string_agg('ach_' || code || '.webp', '、') from st where not uploaded) end,
  case when not exists (select 1 from public.achievements a
                         where a.badge_path is not null and a.deleted_at is null
                           and not exists (select 1 from storage.objects o where o.bucket_id = 'achievement-badges' and o.name = a.badge_path))
       then '✅ ③ 全部成就沒有任何一枚指向不存在的圖'
       else '🔴 ③ 有成就指向不存在的圖（App 會畫破圖）' end
) as "驗證";
