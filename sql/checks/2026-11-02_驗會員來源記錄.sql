/* 驗 2026-11-02_會員來源記錄.sql 的行為（交易內造樣本，最後整個回滾，一列都不留）
   要在跑完 migration 之後、於 Dashboard SQL Editor 執行。
   樣本：測試01～04 其中一位（is_test），在交易裡把他「變成剛註冊」 */
do $$
declare
  v_m uuid; v_ref uuid; v_staff uuid; ok boolean; v text := ''; r record;
begin
  select id into v_m   from members where is_test and deleted_at is null order by created_at limit 1;
  select id into v_ref from members where is_test and deleted_at is null and id <> v_m order by created_at limit 1;
  select id into v_staff from staff where deleted_at is null limit 1;
  if v_m is null or v_ref is null or v_staff is null then
    perform set_config('migi.t', '🔴 找不到樣本（測試會員兩位、店員一位）', true);
    raise exception 'migi_rollback';
  end if;

  -- ⓐ 剛註冊、還是 none ⇒ 記得到
  update members set acquisition_source = 'none', created_at = now(),
         referred_by_staff_id = null, referred_by_member_id = null where id = v_m;
  ok := _set_acquisition(v_m, 'staff', null, null, v_staff, null);
  select acquisition_source, referred_by_staff_id into r from members where id = v_m;
  v := v || case when ok and r.acquisition_source = 'staff' and r.referred_by_staff_id = v_staff
                 then '✅' else '🔴' end || ' ⓐ 剛註冊的人記得到店員' || E'\n';

  -- ⓑ 已經記過 ⇒ 第二個來源不能蓋掉（先到先記）
  ok := _set_acquisition(v_m, 'member', 'buddy_link', null, null, v_ref);
  select acquisition_source into r from members where id = v_m;
  v := v || case when not ok and r.acquisition_source = 'staff' then '✅' else '🔴' end
          || ' ⓑ 第二個來源蓋不掉' || E'\n';

  -- ⓒ 註冊超過 1 小時 ⇒ 不記
  update members set acquisition_source = 'none', created_at = now() - interval '2 hours',
         referred_by_staff_id = null where id = v_m;
  ok := _set_acquisition(v_m, 'member', 'buddy_link', null, null, v_ref);
  v := v || case when not ok then '✅' else '🔴' end || ' ⓒ 註冊超過 1 小時不記' || E'\n';

  -- ⓓ 自己帶自己 ⇒ 不記
  update members set created_at = now() where id = v_m;
  ok := _set_acquisition(v_m, 'member', 'buddy_link', null, null, v_m);
  v := v || case when not ok then '✅' else '🔴' end || ' ⓓ 自己帶自己不記' || E'\n';

  -- ⓔ 開始記錄之前的人（null）⇒ 不記（正對照在 ⓐ）
  update members set acquisition_source = null where id = v_m;
  ok := _set_acquisition(v_m, 'member', 'buddy_link', null, null, v_ref);
  v := v || case when not ok then '✅' else '🔴' end || ' ⓔ 開始記錄之前的人不會被改' || E'\n';

  -- ⓕ 管道：會員帶會員也走同一支，channel 與推薦人都寫進去
  update members set acquisition_source = 'none', created_at = now() where id = v_m;
  ok := _set_acquisition(v_m, 'member', 'team_link', null, null, v_ref);
  select acquisition_channel, referred_by_member_id into r from members where id = v_m;
  v := v || case when ok and r.acquisition_channel = 'team_link' and r.referred_by_member_id = v_ref
                 then '✅' else '🔴' end || ' ⓕ 會員連結記下種類與推薦人' || E'\n';

  -- ⓖ 管道主檔（資訊格）
  v := v || '⚪ ⓖ 管道主檔 ' || (select count(*) filter (where kind='ad') || ' 廣告／' || count(*) filter (where kind='other') || ' 自有' from acquisition_channels);

  perform set_config('migi.t', v, true);
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm <> 'migi_rollback' then
    perform set_config('migi.t', v || E'\n🔴 中途出錯：' || sqlerrm, true);
  else
    perform set_config('migi.t', v, true);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有訊息') as "行為測試";
