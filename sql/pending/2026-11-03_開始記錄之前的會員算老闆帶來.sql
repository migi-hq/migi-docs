-- ════════════════════════════════════════════════════════════════
-- 2026-11-03 開始記錄之前註冊的會員，來源一律算「老闆帶來的」
--
--   使用者：「開始記錄之前 全都算在老闆的成桌」
--   ⇒ 2026-11-02 開始記錄會員來源之前註冊、來源還是空的會員（2026-11-03 查：146 位非測試，
--     其中一位是老闆自己），補記成：
--        acquisition_source     = 'staff'
--        referred_by_staff_id   = 老闆那一列 staff（黃偉晉，role = owner）
--        acquisition_at         = 那位會員的註冊時間
--        acquisition_backfilled = true   ← 看得出是事後補的，不是當下記的
--
--   · 老闆自己不補（不能自己帶自己），維持 null
--   · 測試帳號不補
--   · 已經從邀請連結補記過的 12 位不動（他們有真的推薦人）
--   · 11-02 之後註冊的人一建立就是 none 或真的來源，不會被這份碰到
--   · 配桌成桌的歸屬不用動：9/29 起記在 match_queues.credited_staff_id，有效的 68 場本來就全部是老闆
-- ════════════════════════════════════════════════════════════════

update members m
   set acquisition_source     = 'staff',
       referred_by_staff_id   = s.id,
       acquisition_at         = m.created_at,
       acquisition_backfilled = true
  from staff s
 where s.role = 'owner' and s.deleted_at is null
   and s.org_id = m.org_id
   and m.acquisition_source is null
   and not m.is_test
   and m.deleted_at is null
   and m.id is distinct from s.member_id;

comment on column public.members.acquisition_backfilled is
  'true = 事後補記，不是當下記的：2026-11-02 從邀請連結補記（member）、2026-11-03 開始記錄之前的其餘會員一律算老闆帶來（staff）';

-- 驗證（不 raise，硬規則 1.8）------------------------------------
do $$
declare v text := ''; n int;
begin
  -- ① 這次補成老闆帶來的（期望 145 ＝ 146 位空的 − 老闆自己）
  select count(*) into n from members m join staff s on s.id = m.referred_by_staff_id
   where m.acquisition_backfilled and m.acquisition_source = 'staff' and s.role = 'owner';
  v := v || case when n = 145 then '✅' else '⚠' end || ' ① 補成老闆帶來 ' || n || ' 位（期望 145）' || E'\n';

  -- ② 非測試會員裡還是空的：只剩老闆自己
  select count(*) into n from members where acquisition_source is null and not is_test and deleted_at is null;
  v := v || case when n = 1 then '✅' else '🔴' end || ' ② 來源還是空的非測試會員 ' || n || ' 位（期望 1 ＝ 老闆自己）' || E'\n';

  -- ③ 連結補記的 12 位沒被蓋掉（正對照）
  select count(*) into n from members where acquisition_backfilled and acquisition_source = 'member';
  v := v || case when n = 12 then '✅' else '🔴' end || ' ③ 邀請連結補記的仍是 ' || n || ' 位（期望 12）' || E'\n';

  -- ④ 測試帳號沒被碰
  select count(*) into n from members where is_test and acquisition_source is not null;
  v := v || case when n = 0 then '✅' else '🔴' end || ' ④ 測試帳號被補到 ' || n || ' 位（期望 0）' || E'\n';

  -- ⑤ 沒有人被記成自己帶自己
  select count(*) into n from members m join staff s on s.id = m.referred_by_staff_id where s.member_id = m.id;
  v := v || case when n = 0 then '✅' else '🔴' end || ' ⑤ 自己帶自己 ' || n || ' 位（期望 0）';

  perform set_config('migi.acq_owner', v, true);
end $$;

select coalesce(nullif(current_setting('migi.acq_owner', true), ''), '🔴 沒有訊息') as "驗證";
