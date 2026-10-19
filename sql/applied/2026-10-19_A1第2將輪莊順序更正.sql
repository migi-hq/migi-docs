-- ════════════════════════════════════════════════════════════════════
-- A1 第 2 將：輪莊順序更正（2026-10-19 現場回報「莊家輪轉異常」）
--
-- 發生了什麼：
--   「開始下一將」依序問 誰是莊家 → 莊家的下家（右手邊）→ 莊家的對家。
--   第 2 將點成 莊家 3、下家 2、對家 1 ⇒ 輪莊順序 3 → 2 → 1 → 4。
--   但第 1 將的順序是 1 → 2 → 3 → 4（座位 3 的右手邊是座位 4），
--   第 2 將沒有換位置的話，「下家」那一步點成了上家，輪莊方向整個反過來。
--
-- 這份做的事：只把第 2 將的順序改成 3 → 4 → 1 → 2（第一位莊家仍是座位 3）。
--   · 第 1 局（座位 1 自摸、莊家座位 3）分數不動 —— 那一局的莊家本來就是對的
--   · 改完之後下一位莊家是座位 4（原本錯排成座位 2）
--
-- ⚠ 前提：第 2 將沒有換位置。換過的話不要跑這份，告訴我實際怎麼坐。
-- ⚠ 安全閥：只在「順序還是 3,2,1,4、只打完 1 局、沒有等確認的局」時才改；
--   現場已經又打了一局的話，這份什麼都不做，驗證會說明原因。
-- ════════════════════════════════════════════════════════════════════

do $do$
declare
  v_round uuid := 'a97f8e34-d27b-44b1-9e01-cb60b5fdef45';   -- A1 本場第 2 將
  r record;
  v_conf int;
  v_pend int;
  v_msg text;
begin
  select id, round_no, first_dealer_seat, seat_ring, status into r
    from public.session_rounds where id = v_round for update;
  select count(*) into v_conf from public.hands where round_id = v_round and status = 'confirmed';
  select count(*) into v_pend from public.hands where round_id = v_round and status = 'pending';

  if r.id is null then
    v_msg := '🔴 找不到這一將，沒有改';
  elsif r.seat_ring is distinct from '{3,2,1,4}'::smallint[] then
    v_msg := '🔴 順序已經不是 3,2,1,4（現在是 ' || coalesce(r.seat_ring::text, 'null') || '），沒有改';
  elsif v_pend > 0 then
    v_msg := '🔴 有一局正在等確認，沒有改 —— 等那一局確認或取消之後再跑一次';
  elsif v_conf <> 1 then
    v_msg := '🔴 這一將已經打完 ' || v_conf || ' 局（不是 1 局），沒有改 —— 後面那幾局的莊家是用錯的順序算的，要另外處理';
  else
    update public.session_rounds set seat_ring = '{3,4,1,2}'::smallint[] where id = v_round;
    v_msg := '✅ 已改成 3 → 4 → 1 → 2';
  end if;
  perform set_config('migi.v', v_msg, true);
end
$do$;

-- 驗證（單一 SELECT）：改的結果 ＋ 系統現在算出來的莊家
select current_setting('migi.v', true) as "結果",
       r.seat_ring                      as "現在的輪莊順序",
       (public._tbl_round_state(r.id) ->> 'dealer_seat') as "目前莊家（應該是 4）",
       (public._tbl_round_state(r.id) ->> 'hand_no')     as "下一局是第幾局"
  from public.session_rounds r
 where r.id = 'a97f8e34-d27b-44b1-9e01-cb60b5fdef45';
