-- ════════════════════════════════════════════════════════════════════
-- A1 第 2 將：起莊改成小豪、第 1 局莊家台改由小豪付（2026-10-19 現場回報）
--
-- 現場說：第 2 將開局的莊家是小豪（座位 4），下一位是翁萊（座位 3）。
-- 系統原本記的起莊是翁萊（座位 3），所以：
--   ① 輪莊順序改成 小豪 → 翁萊 → 林政坤 → 皓（座位 4 → 3 → 2 → 1）
--      （照店員當時點的 3 → 2 → 1，前面補上開局的小豪）
--      改完之後：第 1 局皓自摸、莊家小豪沒胡 ⇒ 目前莊家 ＝ 翁萊 ✅
--   ② 第 1 局（皓自摸，1 底 30、每台 10，自摸 1 台）的莊家台改由小豪付：
--        原本  皓 +130　林政坤 −40　翁萊 −50　小豪 −40
--        改成  皓 +130　林政坤 −40　翁萊 −40　小豪 −50
--      （總和仍是 0；只是把莊家多付的 10 從翁萊換到小豪）
--
-- ⚠ 安全閥：只在「起莊 3、順序 3,4,1,2、只打完 1 局、沒有等確認的局、
--   第 1 局分數還是原本那組」時才改；任何一項不符就整份不動，驗證會說原因。
-- ════════════════════════════════════════════════════════════════════

do $do$
declare
  v_round uuid := 'a97f8e34-d27b-44b1-9e01-cb60b5fdef45';   -- A1 本場第 2 將
  r record;
  h record;
  v_conf int;
  v_pend int;
  v_msg text;
begin
  select id, first_dealer_seat, seat_ring into r
    from public.session_rounds where id = v_round for update;
  select count(*) into v_conf from public.hands where round_id = v_round and status = 'confirmed';
  select count(*) into v_pend from public.hands where round_id = v_round and status = 'pending';
  select id, dealer_seat, score_delta into h
    from public.hands where round_id = v_round and hand_no = 1 and status = 'confirmed' for update;

  if r.id is null then
    v_msg := '🔴 找不到這一將，沒有改';
  elsif r.first_dealer_seat <> 3 or r.seat_ring is distinct from '{3,4,1,2}'::smallint[] then
    v_msg := '🔴 現在不是「起莊 3、順序 3,4,1,2」（起莊 ' || r.first_dealer_seat || '、順序 ' || coalesce(r.seat_ring::text, 'null') || '），沒有改';
  elsif v_pend > 0 then
    v_msg := '🔴 有一局正在等確認，沒有改 —— 等那一局確認或取消之後再跑一次';
  elsif v_conf <> 1 then
    v_msg := '🔴 這一將已經打完 ' || v_conf || ' 局（不是 1 局），沒有改';
  elsif h.id is null or h.dealer_seat <> 3
        or h.score_delta <> '{"1":130,"2":-40,"3":-50,"4":-40}'::jsonb then
    v_msg := '🔴 第 1 局已經不是原本那組分數，沒有改';
  else
    update public.session_rounds
       set first_dealer_seat = 4, seat_ring = '{4,3,2,1}'::smallint[]
     where id = v_round;
    update public.hands
       set dealer_seat = 4,
           score_delta    = '{"1":130,"2":-40,"3":-40,"4":-50}'::jsonb,
           proposed_delta = '{"1":130,"2":-40,"3":-40,"4":-50}'::jsonb
     where id = h.id;
    v_msg := '✅ 起莊改成小豪、順序 4 → 3 → 2 → 1；第 1 局莊家台改由小豪付';
  end if;
  perform set_config('migi.v', v_msg, true);
end
$do$;

-- 驗證（單一 SELECT）
select current_setting('migi.v', true) as "結果",
       r.first_dealer_seat             as "起莊座位（應該是 4）",
       r.seat_ring                     as "輪莊順序",
       (public._tbl_round_state(r.id) ->> 'dealer_seat') as "目前莊家（應該是 3 ＝ 翁萊）",
       (select h.score_delta::text from public.hands h
         where h.round_id = r.id and h.hand_no = 1 and h.status = 'confirmed') as "第 1 局分數"
  from public.session_rounds r
 where r.id = 'a97f8e34-d27b-44b1-9e01-cb60b5fdef45';
