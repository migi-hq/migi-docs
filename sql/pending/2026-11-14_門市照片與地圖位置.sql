/* ============================================================
   門市照片與地圖位置（管理後台「門市」頁）
   2026-11-14 · MIGI 咪吉麻將
   使用者：「建立門市後台 —— A：那一頁還缺功能，例如營業時間、照片、停車資訊」
   行為測試：sql/checks/2026-11-14_驗門市照片與地圖位置.sql（跑完這份再跑）

   ── 盤點（動手前查線上）────────────────────────────────
   · 營業時間、停車資訊、電話：後台早就能填（2026-10-23）—— **但會員 App 只畫營業時間**，
     電話、停車資訊客人看不到（list_stores_tx 沒回 parking）。這份補上。
   · 照片：stores.photos（jsonb，預設 []）與 bucket store-photos（公開、5 MB、jpg／png／webp）早就建好，
     **沒有任何寫入路徑** —— 8 間門市全部是 []。
   · 地圖位置：stores.lat／lng 在，後台不能改 ⇒ 新開的門市沒有座標，App 算不出離客人多遠。

   ── 照片怎麼上傳 ─────────────────────────────────────
   頭像與團徽走 Edge Function（客人的 LINE 身分要換成會員）；**後台不用**：
   後台本來就是 Supabase 登入（admin@migi.tw 或店員 LINE 換來的 session），
   所以直接在 Storage 加規則：「有 store.write 權限、而且路徑的第一層是本機構某間門市的 id」才能上傳／刪除。
   ⇒ 不用新寫、新部署一支 Edge Function。
   🔴 規則判斷寫在 _store_photo_writable（DEFINER）：Storage 的規則是用「上傳的人」的身分跑，
     直接在規則裡查 stores 會受 RLS 影響；而且「誰能改門市照片」只留這一份。

   路徑：<門市 id>/<uuid>.<webp|jpg>，縮圖 <門市 id>/<uuid>.s.<webp|jpg>（同頭像、團徽的縮圖規則）
   stores.photos 只存原圖路徑的陣列，第一張是封面，最多 8 張。

   ── 新增／改的函式 ─────────────────────────────────────
   _store_photo_writable(name)            新（Storage 規則用）
   admin_set_store_photos_tx(id, photos)  新：換整份照片清單，回傳「拿掉了哪些」讓後台刪檔
   admin_set_store_location_tx(id, lat, lng)  新：不併進 admin_upsert_store_tx —— 那支改簽名要 DROP，
                                          而部署空窗時舊版後台存門市會壞；分開一支 expand-safe
   admin_list_stores_tx()                 改：多回 lat／lng／photos（簽名不變）
   list_stores_tx(org)                    改：多回 parking／photos（簽名不變，會員 App 門市抽屜用）
   ============================================================ */

-- ① Storage 規則用的判斷（只有一份）
create or replace function public._store_photo_writable(p_name text)
returns boolean language sql stable security definer set search_path to 'public' as $fn$
  select public.can('store.write')
     and exists (select 1 from public.stores s
                  where s.id::text = split_part(p_name, '/', 1)
                    and s.org_id = public.current_org_id()
                    and s.deleted_at is null)
$fn$;
revoke execute on function public._store_photo_writable(text) from public, anon;
grant execute on function public._store_photo_writable(text) to authenticated;

drop policy if exists store_photos_insert on storage.objects;
create policy store_photos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'store-photos' and public._store_photo_writable(name));
drop policy if exists store_photos_delete on storage.objects;
create policy store_photos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'store-photos' and public._store_photo_writable(name));
/* ⚠ 不給 select、update：bucket 是公開的，讀圖走公開網址；改圖一律換新檔名（同成就徽章那條規則，避免 CDN 給舊圖） */

-- ② 換整份照片清單
create or replace function public.admin_set_store_photos_tx(p_id uuid, p_photos jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_org uuid; v_staff uuid; v_old jsonb; v_p text; v_n int;
begin
  if not public.can('store.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限管理門市');
  end if;
  v_org := public.current_org_id();
  v_staff := (select staff_id from public.current_staff());
  select photos into v_old from stores where id = p_id and org_id = v_org and deleted_at is null for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這間門市');
  end if;
  if p_photos is null or jsonb_typeof(p_photos) <> 'array' then
    return jsonb_build_object('ok', false, 'reason', 'bad_photos', 'message', '照片清單格式不對');
  end if;
  v_n := jsonb_array_length(p_photos);
  if v_n > 8 then
    return jsonb_build_object('ok', false, 'reason', 'too_many', 'message', '一間門市最多 8 張照片');
  end if;
  if (select count(distinct x) from jsonb_array_elements_text(p_photos) x) <> v_n then
    return jsonb_build_object('ok', false, 'reason', 'dup_photo', 'message', '同一張照片放了兩次');
  end if;
  for v_p in select x from jsonb_array_elements_text(p_photos) x loop
    -- 路徑一定是「這間門市的資料夾 ＋ uuid」：擋掉別間店的照片、縮圖、與任何手打的路徑
    if v_p !~ ('^' || p_id::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(webp|jpg)$') then
      return jsonb_build_object('ok', false, 'reason', 'bad_path', 'message', '照片路徑不對：' || v_p);
    end if;
    if not exists (select 1 from storage.objects o where o.bucket_id = 'store-photos' and o.name = v_p) then
      return jsonb_build_object('ok', false, 'reason', 'photo_missing', 'message', '有一張照片還沒上傳成功，請重新加一次');
    end if;
  end loop;

  update stores set photos = p_photos, updated_at = now(), updated_by = v_staff where id = p_id;
  return jsonb_build_object('ok', true, 'photos', p_photos,
    'removed', coalesce((select jsonb_agg(x) from jsonb_array_elements_text(coalesce(v_old, '[]'::jsonb)) x
                          where not (p_photos ? x)), '[]'::jsonb));
end $fn$;
revoke execute on function public.admin_set_store_photos_tx(uuid, jsonb) from public, anon;
grant execute on function public.admin_set_store_photos_tx(uuid, jsonb) to authenticated;

-- ③ 地圖位置（兩個都空 ＝ 清掉）
create or replace function public.admin_set_store_location_tx(p_id uuid, p_lat numeric, p_lng numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_org uuid; v_staff uuid;
begin
  if not public.can('store.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限管理門市');
  end if;
  v_org := public.current_org_id();
  v_staff := (select staff_id from public.current_staff());
  if (p_lat is null) <> (p_lng is null) then
    return jsonb_build_object('ok', false, 'reason', 'bad_location', 'message', '緯度和經度要一起填');
  end if;
  -- 台灣本島與離島（含金門、馬祖）的範圍；貼反（經度貼到緯度）最常見，這一道會擋下
  if p_lat is not null and not (p_lat between 21 and 27 and p_lng between 118 and 123) then
    return jsonb_build_object('ok', false, 'reason', 'bad_location',
      'message', '位置不在台灣：緯度應在 21～27、經度應在 118～123（是不是貼反了？）');
  end if;
  update stores set lat = round(p_lat, 6), lng = round(p_lng, 6), updated_at = now(), updated_by = v_staff
   where id = p_id and org_id = v_org and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這間門市');
  end if;
  return jsonb_build_object('ok', true);
end $fn$;
revoke execute on function public.admin_set_store_location_tx(uuid, numeric, numeric) from public, anon;
grant execute on function public.admin_set_store_location_tx(uuid, numeric, numeric) to authenticated;

-- ④ 後台門市清單多回 lat／lng／photos（其餘照抄線上版）
create or replace function public.admin_list_stores_tx()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_org uuid;
begin
  if not public.can('store.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限管理門市');
  end if;
  v_org := public.current_org_id();

  return jsonb_build_object(
    'ok', true,
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id, 'code', s.code, 'name', s.name,
        'address', s.address, 'city', s.city, 'district', s.district,
        'phone', s.phone, 'parking', s.parking, 'note', s.note,
        'open_time', to_char(s.open_time, 'HH24:MI'), 'close_time', to_char(s.close_time, 'HH24:MI'),
        'lat', s.lat, 'lng', s.lng, 'photos', s.photos,          -- 🆕 2026-11-14
        'store_type', s.store_type, 'entity_id', s.entity_id, 'entity_name', e.name,
        'is_active', s.is_active, 'is_test', s.is_test,
        'tables', (select count(*) from tables t where t.store_id = s.id and t.deleted_at is null),
        'tables_active', (select count(*) from tables t where t.store_id = s.id and t.deleted_at is null and t.is_active),
        'open_sessions', (select count(*) from table_sessions ts
                           where ts.store_id = s.id and ts.status = 'open' and ts.deleted_at is null),
        'sessions_14d', (select count(*) from table_sessions ts
                          where ts.store_id = s.id and ts.deleted_at is null and ts.created_at > now() - interval '14 days'),
        'recurring', (select count(*) from recurring_tables r where r.store_id = s.id and r.enabled),
        -- 🆕 2026-10-26：停用中、而且沒有真客人紀錄才給刪（畫面只在 true 時畫刪除鈕；後端刪除時會再檢查一次）
        'can_delete', (not s.is_active) and public._store_real_record_count(s.id) = 0
      ) order by s.code)
        from stores s left join legal_entities e on e.id = s.entity_id
       where s.org_id = v_org and s.deleted_at is null and not s.is_virtual), '[]'::jsonb),
    'entities', coalesce((
      select jsonb_agg(jsonb_build_object('id', le.id, 'name', le.name, 'kind', le.kind) order by le.kind, le.name)
        from legal_entities le where le.org_id = v_org and le.is_active), '[]'::jsonb));
end $fn$;

-- ⑤ 會員 App 的門市清單多回 parking／photos（其餘照抄線上版）
create or replace function public.list_stores_tx(p_org_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'address', s.address,
      'code', s.code,          -- 2026-10-06：門市 QR 帶的是代號（S01），註冊時比對用
      'city', s.city, 'district', s.district,
      'lat', s.lat, 'lng', s.lng,
      'open_time', s.open_time, 'close_time', s.close_time,
      'store_type', s.store_type,
      'phone', s.phone,
      'parking', s.parking, 'photos', s.photos,   -- 🆕 2026-11-14：門市抽屜畫照片與停車資訊
      -- 啟用中的桌數（總桌數）
      'tables_total', coalesce(tc.total, 0),
      -- 空桌數：啟用中且目前沒有進行中場次的桌
      -- 尚未建桌的門市回 null（而非 0），讓前端降級成地標圖示，
      -- 不會誤顯示成「滿桌」
      'tables_free', case when coalesce(tc.total, 0) = 0 then null
                          else coalesce(tc.total, 0) - coalesce(tc.busy, 0) end
    ) order by s.city, s.name)
    from stores s
    left join lateral (
      select count(*) as total,
             count(*) filter (
               where exists (
                 select 1 from table_sessions ts
                  where ts.table_id = t.id
                    and ts.status = 'open'
                    and ts.deleted_at is null)) as busy
        from tables t
       where t.store_id = s.id and t.deleted_at is null and t.is_active
    ) tc on true
    where s.org_id = p_org_id and s.is_active = true and s.deleted_at is null
  ), '[]'::jsonb);
end $fn$;

-- ── 驗證（單一 SELECT；不用 raise —— 那會回滾上面的 DDL，硬規則 1.8）──
select x.項目, x.結果 from (
  select 1 as n, '① 三支新函式都在、各一個版本' as 項目,
         case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
                     and proname in ('_store_photo_writable', 'admin_set_store_photos_tx', 'admin_set_store_location_tx')) = 3
              then '✅ 3 支' else '🔴 ' || (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
                     and proname in ('_store_photo_writable', 'admin_set_store_photos_tx', 'admin_set_store_location_tx')) || ' 支' end as 結果
  union all
  select 2, '② 授權：authenticated 叫得動、anon 叫不動',
         case when bool_and(has_function_privilege('authenticated', p.oid, 'EXECUTE'))
                   and not bool_or(has_function_privilege('anon', p.oid, 'EXECUTE'))
              then '✅' else '🔴 授權不對' end
    from pg_proc p where p.pronamespace = 'public'::regnamespace
     and p.proname in ('_store_photo_writable', 'admin_set_store_photos_tx', 'admin_set_store_location_tx')
  union all
  select 3, '③ Storage 兩條規則（上傳、刪除）都在',
         case when (select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'
                     and policyname in ('store_photos_insert', 'store_photos_delete')) = 2
              then '✅ 2 條' else '🔴 少了' end
  union all
  select 4, '④ 兩支清單多回了新欄位',
         case when pg_get_functiondef('public.list_stores_tx'::regproc) like '%''parking''%''photos''%'
                   and pg_get_functiondef('public.admin_list_stores_tx'::regproc) like '%''lat''%''photos''%'
              then '✅' else '🔴 清單沒改到' end
  union all
  select 5, '⑤ 會員 App 清單還是 anon 叫得動（沒被誤收）',
         case when has_function_privilege('anon', 'public.list_stores_tx(uuid)'::regprocedure, 'EXECUTE')
              then '✅' else '🔴 會員 App 門市清單會壞' end
) x order by x.n;
