-- ============================================================
-- 行為測試：計分板數字鍵直接輸入台數（2026-10-12）
-- 前提：先跑完 sql/pending/2026-10-12_計分板數字鍵直接輸入台數.sql
-- 🔴 交易內自己造一場測試牌局（測試門市一張空桌、四位測試帳號、一台測試平板坐座位 1），不碰任何真的牌局；
--   最後故意 raise 'migi_rollback' 全部回滾，資料庫不會留下任何東西（訊息寫在 exception 處理器裡）。
-- 莊家設成座位 2 ⇒ 座位 1 胡、座位 3 放槍時兩邊都不是莊家，金額 ＝ 底 ＋ 每台 × 台數（沒有莊家台）
-- ============================================================
do $$
declare
  v_org uuid; v_store uuid; v_tbl uuid; v_s uuid; v_r uuid; v_m uuid[]; v_dev uuid; v_stake uuid;
  v_base int; v_unit int;
  v_tok text := 'migi-test-manual-' || md5(random()::text);
  j jsonb; h record;
  v_msg text := '';
begin
  select t.id, t.store_id, st.org_id into v_tbl, v_store, v_org
    from tables t join stores st on st.id = t.store_id
   where st.is_test and t.deleted_at is null
     and not exists (select 1 from table_sessions o where o.table_id = t.id and o.status = 'open' and o.deleted_at is null)
   limit 1;
  if v_tbl is null then v_msg := '⚪ 找不到測試門市的空桌'; raise exception 'migi_rollback'; end if;
  select array_agg(id) into v_m from (select id from members where org_id = v_org and is_test and deleted_at is null limit 4) x;
  if coalesce(array_length(v_m, 1), 0) < 4 then v_msg := '⚪ 測試帳號不到四個'; raise exception 'migi_rollback'; end if;
  select id, base, tai into v_stake, v_base, v_unit from stake_levels
   where org_id = v_org and base > 0 and tai > 0 and not coalesce(is_hygiene, false) and deleted_at is null order by base limit 1;
  if v_stake is null then v_msg := '⚪ 找不到積分級距'; raise exception 'migi_rollback'; end if;

  insert into table_sessions (org_id, store_id, table_id, mode, status, game_type, stake_level_id)
  values (v_org, v_store, v_tbl, 'private', 'open', '台麻', v_stake) returning id into v_s;
  insert into session_players (org_id, session_id, member_id, seat)
  select v_org, v_s, v_m[i], i from generate_series(1, 4) i;
  insert into session_rounds (org_id, session_id, round_no, first_dealer_seat)
  values (v_org, v_s, 1, 2) returning id into v_r;
  insert into table_devices (org_id, store_id, table_id, label, token_hash)
  values (v_org, v_store, v_tbl, '測試平板（數字鍵）', public._tbl_hash(v_tok)) returning id into v_dev;
  update session_players set device_id = v_dev where session_id = v_s and seat = 1;

  -- ① 數字鍵：座位 3 放槍、5 台 ⇒ 記成手動台數、沒有牌型、金額 ＝ 底 ＋ 每台 × 5
  j := public.tbl_submit_hand_tx(v_tok, 'ron', 3::smallint, '[]'::jsonb, 5);
  select * into h from hands where id = (j ->> 'hand_id')::uuid;
  v_msg := case when (j ->> 'ok')::boolean and h.manual_tai and h.patterns = '[]'::jsonb and h.tai_pattern = 5
                 and (h.proposed_delta ->> '3')::int = -(v_base + v_unit * 5) and (h.proposed_delta ->> '1')::int = v_base + v_unit * 5
                then '✅ ① 數字鍵 5 台 ⇒ 手動台數、沒有牌型、放槍的付 ' || (v_base + v_unit * 5)
                else '🔴 ① 回傳 ' || j::text end;
  update hands set status = 'confirmed', score_delta = proposed_delta, confirmed_at = now() where id = h.id;

  -- ② 自摸也能用，而且不自動多帶自摸 1 台（打 3 就是 3）
  j := public.tbl_submit_hand_tx(v_tok, 'tsumo', null, '[]'::jsonb, 3);
  select * into h from hands where id = (j ->> 'hand_id')::uuid;
  v_msg := v_msg || E'\n' || case when (j ->> 'ok')::boolean and h.manual_tai and h.tai_pattern = 3 and h.patterns = '[]'::jsonb
                                   then '✅ ② 自摸數字鍵 3 台 ⇒ 記 3 台、不自動帶自摸'
                                   else '🔴 ② 回傳 ' || j::text end;
  update hands set status = 'confirmed', score_delta = proposed_delta, confirmed_at = now() where id = h.id;

  -- ③ 擋牆：同時帶牌型／超過 99／不是胡牌
  j := public.tbl_submit_hand_tx(v_tok, 'ron', 3::smallint, '[{"code":"zimo","n":1}]'::jsonb, 5);
  v_msg := v_msg || E'\n' || case when j ->> 'reason' = 'manual_with_patterns' then '✅ ③ 數字鍵同時帶牌型 ⇒ 擋下'
                                   else '🔴 ③ 回傳 ' || j::text end;
  j := public.tbl_submit_hand_tx(v_tok, 'ron', 3::smallint, '[]'::jsonb, 100);
  v_msg := v_msg || E'\n' || case when j ->> 'reason' = 'bad_manual_tai' then '✅ ④ 100 台 ⇒ 擋下（0～99）'
                                   else '🔴 ④ 回傳 ' || j::text end;
  j := public.tbl_submit_hand_tx(v_tok, 'kala', 3::smallint, '[]'::jsonb, 5);
  v_msg := v_msg || E'\n' || case when j ->> 'reason' = 'bad_manual' then '✅ ⑤ 咔啦碰帶台數 ⇒ 擋下'
                                   else '🔴 ⑤ 回傳 ' || j::text end;

  -- ⑥ 正對照：不帶台數照舊走選牌型（沒台），不是手動台數
  j := public.tbl_submit_hand_tx(v_tok, 'ron', 3::smallint, '[]'::jsonb);
  select * into h from hands where id = (j ->> 'hand_id')::uuid;
  v_msg := v_msg || E'\n' || case when (j ->> 'ok')::boolean and not h.manual_tai and h.tai_pattern = 0
                                   then '✅ ⑥ 選牌型（沒台）照舊、不是手動台數'
                                   else '🔴 ⑥ 回傳 ' || j::text end;

  -- ⑦ 平板狀態的紀錄頁帶得到 manual_tai
  j := public.tbl_state_tx(v_tok);
  v_msg := v_msg || E'\n' || case when exists (select 1 from jsonb_array_elements(j -> 'log') e where (e ->> 'manual_tai')::boolean)
                                   then '✅ ⑦ 紀錄頁拿得到「手動台數」標記'
                                   else '🔴 ⑦ 紀錄頁沒有 manual_tai' end;
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.x', v_msg, true);
  else
    perform set_config('migi.x', '🔴 中途出錯：' || sqlstate || ' ' || sqlerrm || E'\n已跑完的：\n' || v_msg, true);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.x', true), ''), '🔴 沒有訊息') as "行為測試（應為 7 行 ✅，全部回滾）";
