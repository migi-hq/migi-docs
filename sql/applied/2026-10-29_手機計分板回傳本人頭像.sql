-- ============================================================
-- 2026-10-29 手機計分板回傳本人頭像（使用者：「目前沒有在打的牌局」那一頁名字上面放頭像）
--
-- _tbl_state_for_device 的 device 原本只有 owner（名字）。兩處（有場次、沒場次）各多一個 owner_avatar：
--   { avatar_source, avatar_url, avatar_bear, avatar_photo_path } —— 跟 players[] 每個人的頭像欄位同一組名字，
--   前端用同一支 avatarSrc() 換成圖（隱藏的會員 avatar_source = hidden ⇒ 問號，規則不變）。
-- 平板沒有 member_id ⇒ owner_avatar 是 null，前端不畫。
-- 前端（migi-table）讀不到這個鍵時照舊只畫名字 ⇒ 這一份先跑、前端後推都可以。
-- 跑法：Supabase SQL Editor 整份執行，看最後那一格。
-- ============================================================

create or replace function pg_temp.migi_patch(p_fn regprocedure, p_old text, p_new text, p_expect int default 1)
returns void language plpgsql as $$
declare d text; n int;
begin
  d := pg_get_functiondef(p_fn);
  n := (length(d) - length(replace(d, p_old, ''))) / greatest(length(p_old), 1);
  if n <> p_expect then
    raise exception '改 % 失敗：原文出現 % 次，預期 % 次 —— 線上版本跟寫這份 SQL 時看到的不一樣，整份不提交。原文：%',
      p_fn, n, p_expect, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

select pg_temp.migi_patch('public._tbl_state_for_device(table_devices)'::regprocedure,
  '''owner'', (select m.display_name from members m where m.id = d.member_id)),',
  '''owner'', (select m.display_name from members m where m.id = d.member_id),
                          ''owner_avatar'', (select jsonb_build_object(''avatar_source'', m.avatar_source, ''avatar_url'', m.avatar_url,
                                                ''avatar_bear'', m.avatar_bear, ''avatar_photo_path'', m.avatar_photo_path)
                                               from members m where m.id = d.member_id)),',
  2);

-- ── 驗證（不 raise）
do $$
declare v text := ''; d text; n int;
begin
  d := pg_get_functiondef('public._tbl_state_for_device(table_devices)'::regprocedure);
  n := (length(d) - length(replace(d, '''owner_avatar''', ''))) / length('''owner_avatar''');
  v := v || case when n = 2 then '✅' else '🔴' end || format(' ① 手機狀態兩處都回本人頭像（%s／2）', n) || E'\n';
  n := (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = '_tbl_state_for_device');
  v := v || case when n = 1 then '✅' else '🔴' end || format(' ② 只有一個版本（%s 支）', n);
  perform set_config('migi.x', v, true);
end $$;
select coalesce(nullif(current_setting('migi.x', true), ''), '🔴 沒有訊息') as "手機計分板回傳本人頭像";
