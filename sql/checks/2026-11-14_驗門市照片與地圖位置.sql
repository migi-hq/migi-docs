/* 行為測試：門市照片與地圖位置（sql/pending/2026-11-14_門市照片與地圖位置.sql 跑完之後跑）
   整段在交易裡做、最後故意回滾（raise 'migi_rollback'）⇒ 不留任何東西。結果印在最後那支 SELECT。
   身分：總部（admin@migi.tw 的 auth uid，role=hq）；負對照用一個不存在的使用者。
   🔴 用 set local role authenticated 真的換身分 —— Storage 的規則只有用前端的身分跑才驗得到。 */
do $$
declare
  v_msg text := '';
  v_sid uuid := (select id from public.stores where code = 'S01' and deleted_at is null);
  v_other uuid := (select id from public.stores where code = 'S02' and deleted_at is null);
  v_p text; v_r jsonb; v_lat numeric; v_ok boolean;
  v_hq text := '{"sub":"2485579b-966f-4da6-8ccd-d3adb7ba084b","role":"authenticated"}';
  v_nobody text := '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}';
  ln text := E'\n';
begin
  begin
    perform set_config('request.jwt.claims', v_hq, true);
    execute 'set local role authenticated';

    -- ⓐ 經緯度貼反要擋
    v_r := public.admin_set_store_location_tx(v_sid, 120.3, 22.6);
    v_msg := v_msg || case when v_r->>'reason' = 'bad_location' then '✅' else '🔴' end || ' ⓐ 經緯度貼反被擋：' || coalesce(v_r->>'reason', 'ok') || ln;
    -- ⓑ 正常的位置存得進去
    v_r := public.admin_set_store_location_tx(v_sid, 22.6756712, 120.3127634);
    select lat into v_lat from public.stores where id = v_sid;
    v_msg := v_msg || case when (v_r->>'ok')::boolean and v_lat = 22.675671 then '✅' else '🔴' end || ' ⓑ 位置存進去（四捨五入到 6 位）：' || coalesce(v_lat::text, 'null') || ln;
    -- ⓒ 只填一個要擋
    v_r := public.admin_set_store_location_tx(v_sid, 22.6, null);
    v_msg := v_msg || case when v_r->>'reason' = 'bad_location' then '✅' else '🔴' end || ' ⓒ 只填緯度被擋' || ln;

    -- ⓓ Storage 規則：自己門市的資料夾傳得進去（正對照）
    v_p := v_sid::text || '/' || gen_random_uuid()::text || '.webp';
    begin
      insert into storage.objects (bucket_id, name) values ('store-photos', v_p);
      v_ok := true;
    exception when others then v_ok := false; v_msg := v_msg || '   （ⓓ 錯誤：' || sqlerrm || '）' || ln;
    end;
    v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓓ 總部傳得進自己門市的資料夾' || ln;
    -- ⓔ 不是門市的資料夾傳不進去
    begin
      insert into storage.objects (bucket_id, name) values ('store-photos', gen_random_uuid()::text || '/' || gen_random_uuid()::text || '.webp');
      v_ok := true;
    exception when others then v_ok := false;
    end;
    v_msg := v_msg || case when not v_ok then '✅' else '🔴' end || ' ⓔ 亂編的資料夾傳不進去' || ln;

    -- ⓕ 別間店的照片放不進這間店
    v_r := public.admin_set_store_photos_tx(v_sid, jsonb_build_array(v_other::text || '/' || gen_random_uuid()::text || '.webp'));
    v_msg := v_msg || case when v_r->>'reason' = 'bad_path' then '✅' else '🔴' end || ' ⓕ 別間店的路徑被擋：' || coalesce(v_r->>'reason', 'ok') || ln;
    -- ⓖ 還沒上傳的照片放不進去
    v_r := public.admin_set_store_photos_tx(v_sid, jsonb_build_array(v_sid::text || '/' || gen_random_uuid()::text || '.webp'));
    v_msg := v_msg || case when v_r->>'reason' = 'photo_missing' then '✅' else '🔴' end || ' ⓖ 沒上傳的照片被擋：' || coalesce(v_r->>'reason', 'ok') || ln;
    -- ⓗ 傳好的放得進去（正對照）
    v_r := public.admin_set_store_photos_tx(v_sid, jsonb_build_array(v_p));
    v_msg := v_msg || case when (v_r->>'ok')::boolean and (select photos from public.stores where id = v_sid) = jsonb_build_array(v_p)
                            then '✅' else '🔴' end || ' ⓗ 傳好的照片放得進去：' || coalesce(v_r->>'reason', 'ok') || ln;
    -- ⓘ 拿掉之後回傳「拿掉了哪一張」（後台靠它刪檔）
    v_r := public.admin_set_store_photos_tx(v_sid, '[]'::jsonb);
    v_msg := v_msg || case when v_r->'removed' = jsonb_build_array(v_p) then '✅' else '🔴' end || ' ⓘ 回傳拿掉的照片：' || coalesce(v_r->>'removed', 'null') || ln;
    -- ⓙ 同一張放兩次要擋
    v_r := public.admin_set_store_photos_tx(v_sid, jsonb_build_array(v_p, v_p));
    v_msg := v_msg || case when v_r->>'reason' = 'dup_photo' then '✅' else '🔴' end || ' ⓙ 同一張放兩次被擋' || ln;

    -- ⓚ 換成沒有權限的人：函式擋、Storage 也擋（負對照）
    perform set_config('request.jwt.claims', v_nobody, true);
    v_r := public.admin_set_store_location_tx(v_sid, 22.6, 120.3);
    v_msg := v_msg || case when v_r->>'reason' = 'forbidden' then '✅' else '🔴' end || ' ⓚ 沒權限的人改不了位置' || ln;
    begin
      insert into storage.objects (bucket_id, name) values ('store-photos', v_sid::text || '/' || gen_random_uuid()::text || '.webp');
      v_ok := true;
    exception when others then v_ok := false;
    end;
    v_msg := v_msg || case when not v_ok then '✅' else '🔴' end || ' ⓛ 沒權限的人傳不了照片' || ln;

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then v_msg := v_msg || '🔴 中途出錯：' || sqlerrm; end if;
    perform set_config('migi.store_photo_test', v_msg, true);
  end;
end $$;
select coalesce(nullif(current_setting('migi.store_photo_test', true), ''), '🔴 沒有測試訊息') as "門市照片與地圖位置（行為）";
