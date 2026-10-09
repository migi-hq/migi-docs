-- ============================================================
-- A1 誤按「流局」撤銷（2026-10-09，使用者：「有人按到流局，把它恢復原始狀態」）
--
-- 場次  e6e51224-d54c-4836-b54a-ec00330498f8（A1，美麻・有花，四位都是測試帳號）
-- 那一局 c7dfb06f-8c98-46da-bb6b-fecd44cb214c（第 1 將第 1 局，result = draw，已入帳，四家都 0）
--
-- 做法照抄 tbl_undo_last_tx（撤銷上一局）的內容，不自己發明：
--   ① 那一局 status → 'undone'、記 undone_at
--   ② 那一將若被標成打完就改回 playing（這一將本來就是 playing，所以不會動到）
--   ③ _tbl_ping：通知四台平板重新拉狀態
-- 退回之後就是「定好座位、第 1 將第 1 局還沒打」的樣子；座位與莊家不動。
--
-- 🔴 先確認那一局**仍然是這場最後一筆已入帳的局**才動 —— 平板還在用，
--   如果這段時間又送了別的局，就不可以撤這一筆（會撤錯順序），整份停下來。
-- ============================================================

do $$
declare
  v_session constant uuid := 'e6e51224-d54c-4836-b54a-ec00330498f8';
  v_hand    constant uuid := 'c7dfb06f-8c98-46da-bb6b-fecd44cb214c';
  v_last uuid;
  v_n int;
begin
  if exists (select 1 from hands where session_id = v_session and status = 'pending') then
    raise exception '這場有一局在等確認，先處理那一局再撤';
  end if;
  select id into v_last from hands
   where session_id = v_session and status = 'confirmed'
   order by created_at desc limit 1;
  if v_last is distinct from v_hand then
    raise exception '那一局已經不是最後一局（之後又打了別的局），停下來不撤';
  end if;

  update hands set status = 'undone', undone_at = now()
   where id = v_hand and status = 'confirmed';
  get diagnostics v_n = row_count;
  if v_n <> 1 then raise exception '沒有改到那一局'; end if;

  update session_rounds set status = 'playing', finished_at = null
   where id = (select round_id from hands where id = v_hand) and status = 'finished';

  perform public._tbl_ping(v_session);
end $$;

-- ── 驗證（單一 SELECT）──
select
  (select status from hands where id = 'c7dfb06f-8c98-46da-bb6b-fecd44cb214c')                    as "那一局",
  (select count(*) from hands where session_id = 'e6e51224-d54c-4836-b54a-ec00330498f8'
                                and status = 'confirmed')                                         as "已入帳的局（應為 0）",
  (select status from session_rounds where session_id = 'e6e51224-d54c-4836-b54a-ec00330498f8'
                                       and round_no = 1)                                          as "第 1 將（應為 playing）",
  (select status from table_sessions where id = 'e6e51224-d54c-4836-b54a-ec00330498f8')            as "場次（應為 open）";
