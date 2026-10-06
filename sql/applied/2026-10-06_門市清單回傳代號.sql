/* ============================================================
   門市清單多回一個「代號」（code，例：S01）
   2026-10-06 · MIGI 咪吉麻將

   為什麼：掃門市 QR 進來註冊的客人，網址帶 `?store=S01`，註冊成功後要把那間店存成預設門市。
     會員 App 用 list_stores_tx 比對網址上的值 —— 在此之前它只回 id／名稱，沒有代號，
     所以只認得 id、認不出 S01（認不出來時完成頁照實說「還沒設定常去門市」，不會假裝存好）。
   🔴 背景：在此之前門市「從來沒有存過」—— 網址參數只拿來顯示店名（而且對照表寫死 ziyou／sanmin，三民店資料庫裡根本沒有），
     完成頁卻說「已為你設定預設門市」（migi-web 同日修）。

   改了什麼：只在回傳裡多一個 'code', s.code，其餘逐字照線上版（2026-10-06 撈 pg_get_functiondef）。
   ⚠ CREATE OR REPLACE、簽名不變 ⇒ 授權不會丟（anon／authenticated 照舊叫得動 —— 門市清單本來就是公開主檔）。
   ⚠ 門市代號不是機密（印在 QR 上就是要給人掃的）。
   ============================================================ */

create or replace function public.list_stores_tx(p_org_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
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
end $function$;

/* ============================================================
   驗證（單一 SELECT，不 raise —— 硬規則 1.8）
   ============================================================ */
with r as (select public.list_stores_tx('11111111-1111-1111-1111-111111111111') j)
select concat_ws(E'\n',
  case when (select count(*) from jsonb_array_elements(r.j) e where e ? 'code') = jsonb_array_length(r.j) and jsonb_array_length(r.j) > 0
       then '✅ ① 每一間門市都回了 code：' || (select string_agg(e ->> 'code', '、' order by e ->> 'code') from jsonb_array_elements(r.j) e)
       else '🔴 ① 有門市沒有 code' end,
  case when (select count(*) from jsonb_array_elements(r.j) e where e ? 'tables_free' and e ? 'name' and e ? 'id') = jsonb_array_length(r.j)
       then '✅ ② 原本的欄位都還在（id／name／tables_free…）' else '🔴 ② 原本的欄位不見了' end,
  case when has_function_privilege('anon', 'public.list_stores_tx(uuid)', 'execute')
        and has_function_privilege('authenticated', 'public.list_stores_tx(uuid)', 'execute')
       then '✅ ③ 授權照舊（anon、authenticated 都叫得動，註冊前也讀得到）' else '🔴 ③ 授權不見了，註冊頁會讀不到門市' end,
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'list_stores_tx') = 1
       then '✅ ④ 只有一個版本（沒有長出多載）' else '🔴 ④ 有多個版本' end
) as "驗證" from r;
