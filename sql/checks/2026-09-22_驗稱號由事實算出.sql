-- 2026-09-22 驗「稱號由事實算出」的行為（跑在 2026-09-22_稱號改由後端認定.sql 之後）
-- ⚠ 會在交易內造樣本，最後 raise 'migi_rollback' 整個退掉 —— 一列都不會留下。
-- ⚠ 訊息設在 exception 處理器裡（硬規則 3.9），不然會跟著被回滾。

do $$
declare
  v_mem uuid; v_org uuid; v_ach uuid; v_msg text := '';
  v_n int;
begin
  -- 樣本：測試帳號（is_test），找不到就出聲
  select id, org_id into v_mem, v_org from members
   where deleted_at is null and is_test order by created_at limit 1;
  if v_mem is null then
    perform set_config('migi.t', '⚪ 找不到測試會員，這份測不了', false);
    return;
  end if;

  -- ① 負對照：還沒解鎖時沒有「新手村制霸」
  select count(*) into v_n from public._member_titles(v_mem) where title = '新手村制霸';
  v_msg := v_msg || case when v_n = 0 then '✅' else '🔴' end || ' ① 解鎖前沒有新手村制霸' || E'\n';

  -- ② 解鎖 onboarding_29 → 出現
  select id into v_ach from achievements where code = 'onboarding_29' and org_id = v_org and deleted_at is null;
  insert into member_achievements(member_id, achievement_id, org_id, status, current_tier, unlocked_at)
  values (v_mem, v_ach, v_org, 'unlocked', 1, now())
  on conflict (member_id, achievement_id) do update set status = 'unlocked', unlocked_at = now();
  select count(*) into v_n from public._member_titles(v_mem) where title = '新手村制霸';
  v_msg := v_msg || case when v_n = 1 then '✅' else '🔴' end || ' ② 解鎖後有新手村制霸' || E'\n';

  -- ③ 成就下架之後，已經拿到的不收回（稱號永久）
  update achievements set is_active = false where id = v_ach;
  select count(*) into v_n from public._member_titles(v_mem) where title = '新手村制霸';
  v_msg := v_msg || case when v_n = 1 then '✅' else '🔴' end || ' ③ 成就停用後稱號還在' || E'\n';

  -- ④ 當上賽季冠軍 → 「2026 秋季雀神熊」
  insert into season_champions(season, org_id, member_id, rating, awarded_at)
  values ('2026H2', v_org, v_mem, 999, now());
  select count(*) into v_n from public._member_titles(v_mem) where title = '2026 秋季雀神熊';
  v_msg := v_msg || case when v_n = 1 then '✅' else '🔴' end || ' ④ 冠軍拿到 2026 秋季雀神熊' || E'\n';

  -- ⑤ 前端寫進 member_app_state.titles 的東西，存檔之後不會變成稱號
  --   （直接模擬舊路徑：save_app_state_tx 已經不合併，這裡驗「表裡沒東西就沒有」）
  select count(*) into v_n from public._member_titles(v_mem) where source = '特別獲得';
  v_msg := v_msg || case when v_n = 0 then '✅' else '🔴' end || ' ⑤ 沒有來路不明的稱號' || E'\n';

  -- ⑥ 新手上路永遠在
  select count(*) into v_n from public._member_titles(v_mem) where title = '新手上路';
  v_msg := v_msg || case when v_n = 1 then '✅' else '🔴' end || ' ⑥ 新手上路還在';

  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.t', v_msg, false);
  else
    perform set_config('migi.t', '🔴 中途失敗：' || sqlerrm || E'\n已經跑完的：\n' || coalesce(v_msg, ''), false);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有訊息') as "驗證";
