/* ============================================================
   成就徽章搬進 Storage（第 2 步：回填 badge_path）
   2026-09-25 · MIGI 咪吉麻將

   🔴 **先跑第 1 份、再上傳圖、最後才跑這一份。**
     這一份只回填「bucket 裡確實有那個檔案」的成就 ——
     先寫路徑後傳圖的話，App 會畫出一張破圖而且不報錯。
     ⇒ 圖沒傳完就跑，沒傳到的那幾枚只是維持 emoji，不會壞；補傳之後再跑一次即可（冪等）。

   檔名規則：`ach_<成就 code>.webp`（與搬家前 migi-web 的檔名逐字相同）。
   ⚠ 只填 badge_path 還是 null 的 —— 已經指向新版檔名（例如 .v2）的不會被蓋回舊檔。
   ============================================================ */

update public.achievements a
   set badge_path = 'ach_' || a.code || '.webp',
       updated_at = now()
 where a.badge_path is null
   and exists (select 1 from storage.objects o
                where o.bucket_id = 'achievement-badges'
                  and o.name = 'ach_' || a.code || '.webp');


/* ── 驗證（不用 raise，硬規則 1.8）── */
do $$
declare
  v_msg text := '';
  v_objs int; v_set int; v_broken int; v_orphan int;
begin
  select count(*) into v_objs from storage.objects where bucket_id = 'achievement-badges';
  select count(*) into v_set  from public.achievements where badge_path is not null and deleted_at is null;

  -- ① 指向不存在檔案的（＝會畫破圖的）一定要是 0
  select count(*) into v_broken from public.achievements a
   where a.badge_path is not null and a.deleted_at is null
     and not exists (select 1 from storage.objects o
                      where o.bucket_id = 'achievement-badges' and o.name = a.badge_path);
  v_msg := case when v_broken = 0 then '✅ ① 沒有任何成就指向不存在的圖'
                else '🔴 ① ' || v_broken || ' 枚指向不存在的圖（App 會畫破圖）' end;

  -- ② 正對照：傳上去的圖有被用到（不是 0 ＝ 回填真的發生了）
  --   期望：搬家前 migi-web 有 29 張（新手引導 onboarding_01–29）
  v_msg := v_msg || E'\n' || case
    when v_objs = 0 then '🔴 ② bucket 是空的 —— 圖還沒上傳'
    when v_set = 0  then '🔴 ② bucket 有 ' || v_objs || ' 張但一枚都沒回填（檔名對不上？）'
    else '✅ ② bucket ' || v_objs || ' 張，已有 ' || v_set || ' 枚成就指向圖' end;

  -- ③ 傳上去卻沒有成就用到的（檔名打錯、或 code 已被軟刪除）—— 列出來給人判讀
  select count(*) into v_orphan from storage.objects o
   where o.bucket_id = 'achievement-badges'
     and not exists (select 1 from public.achievements a
                      where a.badge_path = o.name and a.deleted_at is null);
  v_msg := v_msg || E'\n' || case when v_orphan = 0 then '✅ ③ 每一張圖都有成就在用'
    else '⚠ ③ ' || v_orphan || ' 張圖沒有成就在用：' || coalesce((
      select string_agg(o.name, '、' order by o.name) from storage.objects o
       where o.bucket_id = 'achievement-badges'
         and not exists (select 1 from public.achievements a
                          where a.badge_path = o.name and a.deleted_at is null)), '') end;

  perform set_config('migi.v', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有訊息') as "驗證";
