/* ============================================================
   成就徽章搬進 Storage（第 1 步：bucket ＋ 欄位 ＋ 回傳）
   2026-09-25 · MIGI 咪吉麻將

   ── 為什麼 ───────────────────────────────────────────
   徽章原本是 migi-web 的 src/assets/ach_<code>.webp，寫死在 images.js。
   ⇒ 補一枚徽章 ＝ 改程式 ＋ build ＋ 部署，而且只有會員 App 看得到。
   改成「圖在 Storage、路徑在成就主檔」之後：
     · 補一枚 ＝ 上傳一張圖 ＋ 改一筆資料，任何一端都不用重新部署
     · POS／桌邊平板／Kiosk 要顯示時讀同一個欄位，全系統只有一個來源
   📌 這是硬規則 13 的「內容美術」那一格：不進 @migi/assets（公開套件、
     每換一張就要打 tag），也不該留在單一 App 的程式碼裡。

   ── 這一份做三件事 ───────────────────────────────────
   ① 建公開 bucket `achievement-badges`（只收 webp／png，上限 256 KB）
   ② achievements 加 `badge_path`（bucket 內的路徑，不是完整網址）
   ③ get_my_achievements_tx 多回 `badge_path`（CREATE OR REPLACE，簽名不變、授權不動）

   ⚠ 這一份**不回填** badge_path —— 圖還沒上傳。
     回填是第 2 份，而且只填「檔案確實存在」的那幾枚
     （先寫路徑、後傳圖的話，App 會畫出一張破圖）。

   ── 寫入規則（日後補圖照這個）────────────────────────
   · bucket 沒有任何寫入 policy ⇒ 只有 Dashboard／service_role 傳得進去。
     公開 bucket 的讀取走公開網址，不需要 policy。
   · 🔴 **改圖一律換新檔名，不要覆蓋同一個路徑**（例：ach_tile_14.v2.webp），
     再把 badge_path 改成新檔名。覆蓋的話 CDN 與瀏覽器會繼續給舊圖，而且不報錯。
   ============================================================ */

-- ① bucket
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('achievement-badges', 'achievement-badges', true, 262144,
        array['image/webp', 'image/png'])
on conflict (id) do nothing;

-- ② 欄位
alter table public.achievements add column if not exists badge_path text;
comment on column public.achievements.badge_path is
  '徽章圖在 Storage bucket achievement-badges 裡的路徑（不是完整網址）。'
  ' null ＝ 還沒有圖，前端用 emoji。改圖一律換新檔名再改這一欄，不要覆蓋舊檔（快取）。';

-- ③ 回傳 badge_path（其餘逐字照線上版，2026-09-25 以 pg_get_functiondef 撈出）
create or replace function public.get_my_achievements_tx()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_member uuid;
  v_org    uuid;
  v_rows   jsonb;
  v_total  int;
  v_done   int;
begin
  v_member := public.current_member_id();
  if v_member is null then
    raise exception '未登入，無法讀取成就' using errcode = '28000';
  end if;

  select org_id into v_org from members where id = v_member and deleted_at is null;
  if v_org is null then
    raise exception '會員不存在' using errcode = '28000';
  end if;

  select coalesce(jsonb_agg(x order by x.ord, x.code), '[]'::jsonb),
         count(*)::int,
         count(*) filter (where x.status = 'unlocked')::int
    into v_rows, v_total, v_done
  from (
    select
      a.code,
      case when a.visibility = 'silhouette'
                and coalesce(ma.status, 'locked') <> 'unlocked'
           then '？？？' else a.name end                          as name,
      case when a.visibility = 'silhouette'
                and coalesce(ma.status, 'locked') <> 'unlocked'
           then null else a.description end                       as description,
      case when a.visibility = 'silhouette'
                and coalesce(ma.status, 'locked') <> 'unlocked'
           then null else a.condition_text end                    as condition_text,
      a.ui_category                                               as category,
      a.rarity,
      a.group_key,
      a.is_signature                                              as signature,
      case when a.visibility = 'silhouette'
                and coalesce(ma.status, 'locked') <> 'unlocked'
           then null else a.grants_title end                      as grants_title,
      (a.visibility = 'silhouette'
        and coalesce(ma.status, 'locked') <> 'unlocked')          as masked,
      /* 徽章圖。遮蔽的成就照樣回傳 —— 前端本來就把未解鎖的圖畫成灰階剪影，
         行為與搬家前（圖寫死在前端）完全相同。 */
      a.badge_path                                                as badge_path,
      coalesce(ma.status, 'locked')                               as status,
      /* 🎯 **進度的分子**，兩種來源（不同機制）：
           cumulative  `ach_progress_tx` 一路累加，值就在 member_achievements
           meta        沒有人累加 ⇒ 當下數一次，與 ach_meta_tx 同一支函式 */
      case when a.trigger ? 'count'
           then coalesce(public.ach_meta_count_tx(
                  v_member, a.trigger->>'scope', a.trigger->>'value'), 0)
           else coalesce(ma.current_value, 0) end                 as current_value,
      /* 🔴 **分母也有兩種來源，而這是 2026-09-20 補的**：
           meta        `trigger->>'count'`
           cumulative  `achievement_tiers` 的最大 threshold（ach_progress_tx 讀的就是它）
         ⚠ 少了第二條，累積型成就的 target 是 null ⇒ **進度條畫不出來而且不報錯**。
           今天踩不到只是因為在此之前一枚 cumulative 都沒有。 */
      coalesce(
        case when a.trigger ? 'count' then (a.trigger->>'count')::int end,
        (select max(t.threshold)::int from achievement_tiers t
          where t.achievement_id = a.id)
      )                                                           as target,
      coalesce(ma.pinned, false)                                  as pinned,
      ma.unlocked_at,
      a.sort                                                      as ord
      from achievements a
      left join member_achievements ma
             on ma.achievement_id = a.id and ma.member_id = v_member
     where a.org_id = v_org
       and a.deleted_at is null
       and a.is_active
       and (a.valid_from is null or now() >= a.valid_from)
       and (a.valid_to   is null or now() <  a.valid_to)
       and not (a.visibility = 'hidden'
                and coalesce(ma.status, 'locked') <> 'unlocked')
  ) x;

  return jsonb_build_object(
    'ok', true,
    'total', v_total,
    'unlocked', v_done,
    'achievements', v_rows
  );
end $function$;


/* ── 驗證（🔴 不用 raise：這一份要留下 DDL，硬規則 1.8）── */
do $$
declare
  v_msg  text := '';
  v_out  jsonb;
  v_n    int;
  v_has  int;
begin
  -- ① bucket
  v_msg := v_msg || coalesce((
    select case when public and file_size_limit = 262144
                 and allowed_mime_types @> array['image/webp']
           then '✅ ① bucket achievement-badges 公開、上限 256 KB、收 webp'
           else '🔴 ① bucket 設定不對' end
      from storage.buckets where id = 'achievement-badges'), '🔴 ① bucket 不存在');

  -- ② 欄位
  v_msg := v_msg || E'\n' || case when exists (
      select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'achievements' and column_name = 'badge_path')
    then '✅ ② achievements.badge_path 存在' else '🔴 ② 欄位不存在' end;

  -- ③ 版本數 ＋ 授權沒被動到（CREATE OR REPLACE 不丟 GRANT，這一格盯的是「沒有人順手收掉」）
  select count(*) into v_n from pg_proc
   where pronamespace = 'public'::regnamespace and proname = 'get_my_achievements_tx';
  v_msg := v_msg || E'\n' || case when v_n = 1 then '✅ ③ 版本數 1' else '🔴 ③ 版本數 ' || v_n end
        || case when has_function_privilege('authenticated', 'public.get_my_achievements_tx()', 'execute')
                then '，authenticated 叫得動' else '，🔴 authenticated 叫不動' end;

  -- ④ 用測試02 的身分真的叫一次：每一列都要帶 badge_path 這個鍵（值可以是 null）
  perform set_config('request.jwt.claims', '{"sub":"TEST-02","role":"authenticated"}', true);
  v_out := public.get_my_achievements_tx();
  select count(*), count(*) filter (where e ? 'badge_path')
    into v_n, v_has
    from jsonb_array_elements(v_out -> 'achievements') e;
  v_msg := v_msg || E'\n' || case
    when v_n = 0 then '⚪ ④ 測試02 拿到 0 枚成就，測不出鍵'
    when v_has = v_n then '✅ ④ 測試02 拿到 ' || v_n || ' 枚，每一枚都有 badge_path 鍵'
    else '🔴 ④ ' || v_n || ' 枚裡只有 ' || v_has || ' 枚有 badge_path' end;

  perform set_config('migi.v', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有訊息') as "驗證";
