-- ============================================================
-- 2026-10-28 換機代碼合併：手機換手機只要一種（使用者：「不用特別寫換人上桌」）
--
-- 在此之前平板有兩組碼：
--   「改手機計分」那一組（table_phone_codes）  → 本人的新手機在配對頁輸入 ＝ 改用手機
--   「換別人上桌 ›」那一組（session_seat_swaps）→ 別人的手機在「接手別人的位置」輸入 ＝ 換人
-- 之後平板只剩「改手機計分」那一組：
--   · 本人的新手機在配對頁輸入 ⇒ 改用手機（不變，tbl_phone_redeem_tx）
--   · 別人已配好的手機在「輸入換機代碼」輸入 ⇒ 換他上桌（這一份：tbl_swap_redeem_tx 也認得平板那一組）
-- 手機「換一支手機」本來就只有一組（session_seat_swaps），不受影響。
--
-- 做法：tbl_swap_redeem_tx 找不到換機代碼時，再找平板發的那一組（還沒用、沒過期、綁著這一場）；
--   找到就當場補一筆 session_seat_swaps（同一組數字、稽核照舊），後面整段換人流程一行不改。
--   換好之後平板那一組也標成用掉，不能再拿去配別的手機。
--
-- ⚠ 前端（migi-table：拿掉平板的「換別人上桌」、手機改叫「輸入換機代碼」）**等這一份跑完才推**，
--   不然中間有一段平板換不了人。
-- 跑法：Supabase SQL Editor 整份執行，看最後那一格。行為測試：sql/checks/2026-10-28_驗換機代碼合併.sql
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

-- 平板「改手機計分」那一組碼 → 補成一筆換機代碼（找不到就回空的那一列）
create or replace function public._tbl_swap_from_phone_code(p_code text)
returns public.session_seat_swaps language plpgsql security definer set search_path to 'public' as $$
declare pc public.table_phone_codes; r public.session_players; s public.session_seat_swaps;
begin
  select * into pc from table_phone_codes
   where code = p_code and used_at is null and expires_at > now()
     and session_id is not null and issued_by_device is not null   -- 只認平板發、綁著一場的那一種
   order by created_at desc limit 1;
  if pc.id is null then return s; end if;
  select * into r from session_players
   where session_id = pc.session_id and member_id = pc.member_id and left_at is null
   limit 1;
  if r.id is null then return s; end if;
  insert into session_seat_swaps (org_id, session_id, player_row_id, from_member_id, code, issued_device_id, expires_at)
  values (r.org_id, pc.session_id, r.id, r.member_id, pc.code, pc.issued_by_device,
          least(pc.expires_at, now() + interval '10 minutes'))
  returning * into s;
  return s;
end $$;
revoke execute on function public._tbl_swap_from_phone_code(text) from public, anon, authenticated;

select pg_temp.migi_patch('public.tbl_swap_redeem_tx(text,text,boolean)'::regprocedure,
  'insert into session_swap_tries (device_id) values (d.id);',
  '/* 🆕 2026-10-28：平板「改手機計分」那一組也認（手機換手機只要一種，平板不再另外給換人的碼） */
    s := public._tbl_swap_from_phone_code(v_code);
    if s.id is null then
    insert into session_swap_tries (device_id) values (d.id);');
select pg_temp.migi_patch('public.tbl_swap_redeem_tx(text,text,boolean)'::regprocedure,
  'return jsonb_build_object(''ok'', false, ''reason'', ''bad_code'', ''message'', ''代碼不對或已經過期，請對方重新產生一組'');',
  'return jsonb_build_object(''ok'', false, ''reason'', ''bad_code'', ''message'', ''代碼不對或已經過期，請對方重新產生一組'');
    end if;');
select pg_temp.migi_patch('public.tbl_swap_redeem_tx(text,text,boolean)'::regprocedure,
  'update session_seat_swaps set moved_extensions = v_moved, moved_queue_rows = v_queues where id = s.id;',
  'update session_seat_swaps set moved_extensions = v_moved, moved_queue_rows = v_queues where id = s.id;
  -- 平板「改手機計分」那一組也一起用掉（2026-10-28）：位置已經換人，不能再拿去配 B 的手機
  update table_phone_codes set used_at = now(), used_by_device = d.id
   where code = s.code and session_id = s.session_id and used_at is null;');

-- ── 驗證（不 raise）
do $$
declare v text := ''; d text; ok boolean;
begin
  d := pg_get_functiondef('public.tbl_swap_redeem_tx(text,text,boolean)'::regprocedure);
  ok := d ~ 's := public\._tbl_swap_from_phone_code\(v_code\);' and d ~ 'update table_phone_codes set used_at = now\(\), used_by_device = d\.id';
  v := v || case when ok then '✅' else '🔴' end || ' ① 換機代碼兌換：也認平板「改手機計分」那一組、換好一起用掉' || E'\n';
  ok := d ~ '''bad_code''' and d ~ 'session_swap_tries';
  v := v || case when ok then '✅' else '🔴' end || ' ② 兩種都找不到時照舊算一次錯誤、回代碼不對' || E'\n';
  ok := (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'tbl_swap_redeem_tx') = 1
    and has_function_privilege('anon', 'public.tbl_swap_redeem_tx(text,text,boolean)'::regprocedure, 'EXECUTE');
  v := v || case when ok then '✅' else '🔴' end || ' ③ 換機代碼兌換只有一個版本、手機（裝置憑證）照樣叫得動' || E'\n';
  ok := not has_function_privilege('anon', 'public._tbl_swap_from_phone_code(text)'::regprocedure, 'EXECUTE')
    and not has_function_privilege('authenticated', 'public._tbl_swap_from_phone_code(text)'::regprocedure, 'EXECUTE');
  v := v || case when ok then '✅' else '🔴' end || ' ④ 新的內部函式前端叫不到';
  perform set_config('migi.x', v, true);
end $$;
select coalesce(nullif(current_setting('migi.x', true), ''), '🔴 沒有訊息') as "換機代碼合併";
