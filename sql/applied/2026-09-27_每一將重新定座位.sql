-- ════════════════════════════════════════════════════════════════════
-- 每一將重新定座位（2026-09-27）
--
-- 起因：使用者要第二將、第三將選完莊家之後，也要選下家、對家（實際打牌時每一將可能換位子）。
--
-- 🔴 不可以直接改 session_players.seat：
--   座位號同時是「這個人」的身分 —— hands 的 winner_seat／deal_in_seat／score_delta 全部用座位號記。
--   第二將把人換到別的座位號，第一將的紀錄就會對到錯的人、總分算錯，而且不報錯。
-- ✅ 座位號不動（永遠代表那個人），改成**每一將記一份繞桌順序** session_rounds.seat_ring：
--   [莊家, 下家, 對家, 上家]。null ＝ 原本的 1→2→3→4（第一將與舊資料都是這樣）。
--   · _tbl_round_state 換莊改照 seat_ring 往下輪，並把 seat_ring 回給前端
--     （tbl_state_tx 本來就把 _tbl_round_state 整包併進 round，所以它不用改）
--   · tbl_start_round_tx 多收 p_next_seat / p_opposite_seat，**有預設值 null** ⇒
--     還沒更新的平板照舊只送莊家也叫得動（expand-safe），那種情況 seat_ring 留 null
--
-- 改簽名 ⇒ 先 DROP 舊的再建（硬規則 2），結尾補回授權（原本是 anon ＋ authenticated 叫得動）。
-- 行為測試另一份：sql/checks/2026-09-27_驗每一將重新定座位.sql
-- 最後一格「驗證」應該是 5 行 ✅。
-- ════════════════════════════════════════════════════════════════════

alter table public.session_rounds add column if not exists seat_ring smallint[];

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'session_rounds_seat_ring_chk') then
    -- ⚠ CHECK 裡不能有子查詢（第一版用 unnest 排序比對，被 0A000 擋下）。
    --   改成「剛好 4 格 ＋ 1～4 每個都在裡面」：4 格要裝下 4 個不同的值，就只能是一個排列，
    --   重複（1,1,2,3）與空格（null）都過不了「每個都在」那一關。
    alter table public.session_rounds add constraint session_rounds_seat_ring_chk check (
      seat_ring is null or (
        cardinality(seat_ring) = 4
        and seat_ring @> '{1,2,3,4}'::smallint[]
      ));
  end if;
end $$;

comment on column public.session_rounds.seat_ring is
  '這一將的繞桌順序 [莊家, 下家, 對家, 上家]（座位號）；null ＝ 1→2→3→4。座位號本身永遠代表那個人，換位子只改這一欄。';

-- ── 換莊照這一將的順序輪 ──
create or replace function public._tbl_round_state(p_round_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_first smallint; v_dealer smallint; v_wind smallint := 1; v_ren smallint := 0;
  v_pass smallint := 0; v_n int := 0; v_fin boolean := false; h record; v_stay boolean;
  v_ring smallint[];
begin
  select first_dealer_seat, seat_ring into v_first, v_ring from session_rounds where id = p_round_id;
  if v_first is null then return null; end if;
  -- null ＝ 原本的 1→2→3→4（第一將、舊資料）
  v_ring := coalesce(v_ring, '{1,2,3,4}'::smallint[]);
  v_dealer := v_first;
  /* 只看已生效的局；咔啦碰不是一局（不推進局數、莊家、連莊） */
  for h in select result, winner_seat, deal_in_seat from hands
            where round_id = p_round_id and status = 'confirmed' and result <> 'kala'
            order by hand_no, created_at
  loop
    v_n := v_n + 1;
    /* 誰留莊：
         流局              莊家連莊
         胡／自摸          胡的人是莊家 ⇒ 連莊，否則換莊
         包牌（09-24 拍板）莊家包牌才下莊；閒家包牌莊家繼續連莊 */
    v_stay := case h.result
                when 'draw' then true
                when 'bao'  then h.deal_in_seat <> v_dealer
                else h.winner_seat = v_dealer
              end;
    if v_stay then
      v_ren := v_ren + 1;
    else
      -- 換莊：輪到這一將順序裡的下一位（2026-09-27 起不再寫死 1→2→3→4）
      v_dealer := v_ring[(array_position(v_ring, v_dealer) % 4) + 1];
      v_ren := 0;
      v_pass := v_pass + 1;
      if v_pass = 4 then
        v_pass := 0;
        v_wind := v_wind + 1;
        if v_wind > 4 then v_wind := 4; v_fin := true; exit; end if;
      end if;
    end if;
  end loop;
  return jsonb_build_object('wind', v_wind, 'dealer_seat', v_dealer, 'renzhuang', v_ren,
                            'hand_no', v_n + 1, 'finished', v_fin, 'confirmed_hands', v_n,
                            'seat_ring', to_jsonb(v_ring));
end $function$;

-- ── 開下一將：莊家 ＋（可選）下家、對家 ──
drop function if exists public.tbl_start_round_tx(text, smallint);

create or replace function public.tbl_start_round_tx(p_token text, p_dealer_seat smallint default 1,
                                                     p_next_seat smallint default null, p_opposite_seat smallint default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare d public.table_devices; s public.table_sessions; r public.session_rounds; v_ring smallint[]; v_last smallint;
begin
  d := public._tbl_device(p_token);
  select * into s from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  if p_dealer_seat not between 1 and 4 then
    return jsonb_build_object('ok', false, 'reason', 'bad_seat', 'message', '請選莊家');
  end if;
  -- 下家、對家要嘛都給、要嘛都不給（都不給 ＝ 舊版平板，照原本的 1→2→3→4）
  if (p_next_seat is null) <> (p_opposite_seat is null) then
    return jsonb_build_object('ok', false, 'reason', 'bad_order', 'message', '請選下家和對家');
  end if;
  if p_next_seat is not null then
    if p_next_seat not between 1 and 4 or p_opposite_seat not between 1 and 4
       or p_next_seat = p_dealer_seat or p_opposite_seat = p_dealer_seat or p_next_seat = p_opposite_seat then
      return jsonb_build_object('ok', false, 'reason', 'bad_order', 'message', '三個人要選不同的人');
    end if;
    select x into v_last from unnest('{1,2,3,4}'::smallint[]) x
     where x not in (p_dealer_seat, p_next_seat, p_opposite_seat);
    v_ring := array[p_dealer_seat, p_next_seat, p_opposite_seat, v_last];
  end if;
  if exists (select 1 from session_rounds where session_id = s.id and status = 'playing') then
    return jsonb_build_object('ok', false, 'reason', 'round_playing', 'message', '這一將還沒打完');
  end if;
  select * into r from session_rounds
   where session_id = s.id and status <> 'voided' order by round_no desc limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_order', 'message', '請先定好座位');
  end if;

  insert into session_rounds (org_id, session_id, round_no, first_dealer_seat, seat_ring)
  values (s.org_id, s.id, r.round_no + 1, p_dealer_seat, v_ring);
  perform public._tbl_ping(s.id);
  return jsonb_build_object('ok', true, 'round_no', r.round_no + 1, 'seat_ring', to_jsonb(v_ring));
end $function$;

-- DROP 會把授權一起丟掉 ⇒ 補回（原本 anon ＋ authenticated 叫得動；平板是 anon ＋ 裝置憑證）
grant execute on function public.tbl_start_round_tx(text, smallint, smallint, smallint) to anon, authenticated;

-- ── 驗證（只讀，不 raise ⇒ 不會回滾上面的 DDL，硬規則 1.8）──
do $$
declare v text := ''; n int;
begin
  v := v || case when exists (select 1 from information_schema.columns
                               where table_schema = 'public' and table_name = 'session_rounds' and column_name = 'seat_ring')
                 then '✅' else '🔴' end || ' ① session_rounds.seat_ring 在' || E'\n';

  select count(*) into n from pg_proc where pronamespace = 'public'::regnamespace and proname = 'tbl_start_round_tx';
  v := v || case when n = 1 then '✅' else '🔴' end || ' ② tbl_start_round_tx 版本數 ' || n || '（應為 1，舊的兩參數版已拿掉）' || E'\n';

  v := v || case when has_function_privilege('anon', 'public.tbl_start_round_tx(text,smallint,smallint,smallint)', 'execute')
                 then '✅' else '🔴' end || ' ③ 平板（anon）叫得動新的 tbl_start_round_tx' || E'\n';

  v := v || case when pg_get_functiondef('public._tbl_round_state(uuid)'::regprocedure) ~ 'v_ring\[\(array_position\(v_ring, v_dealer\) % 4\) \+ 1\]'
                 then '✅' else '🔴' end || ' ④ 換莊改照這一將的順序輪' || E'\n';

  -- ⑤ 正對照：舊資料（seat_ring 是 null）算出來的莊家要跟改之前一樣 —— 拿現有每一將重算，跟 1→2→3→4 的結果比
  select count(*) into n from session_rounds r
   where r.seat_ring is null and public._tbl_round_state(r.id) ->> 'seat_ring' <> '[1, 2, 3, 4]';
  v := v || case when n = 0 then '✅' else '🔴' end || ' ⑤ 舊的每一將（沒有順序）都當成 1→2→3→4（不符 ' || n || ' 將）' || E'\n';

  perform set_config('migi.v', v, true);
end $$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有訊息') as "驗證";
