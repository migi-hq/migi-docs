-- ════════════════════════════════════════════════════════════════════
-- 2026-10-30 三件事（使用者同日）
--
-- ① 好友練習賽每一場用的那張桌，名字從「F0001」改成「練習賽房間 1」
--    使用者：「應該不算門市，統一叫練習賽房間」。手機計分板有幾頁會直接印桌名
--    （「某某 還沒開桌」「某某 斷線了」「在某某計分」），F0001 客人看不懂。
--    · 同一間門市底下桌名不能重複（uq_tables_store_label）⇒ 後面帶編號
--    · 線上還沒有任何一張練習賽房間（0 張），所以只改建立的那一段，不用改舊資料
--    · 程式代號 stores.is_virtual／tables 照舊不動
--
-- ② 選牌型頁記住「這個人在這一場上一次用哪一種送出」（選牌型／數字鍵）
--    使用者：「記憶滑桿選擇要綁定個人帳號」「只記住當下牌局的選擇，重開新局還是切回預設牌型」
--    ⇒ 跟著人（這一場中途換平板、換手機、重新整理都一樣），但**只在這一場**；新的一場一律從選牌型開始。
--    🎯 不另外存一份設定：答案本來就在 hands 裡 ——
--      這一場他最後一次送出的胡牌／自摸（submitted_seat ＝ 他的座位），manual_tai = true 就是數字鍵。
--      ⇒ 只有一份事實，不會「設定說數字鍵、紀錄說選牌型」對不起來。
--    · 送出之後被取消的那一筆也算（他按的就是那一種）
--    · 這一場還沒送過、或還沒選座位 ⇒ 選牌型
--
-- ③ v_real_stores 補上 is_virtual（10-28 好友練習賽地基加的欄位，檢視表沒跟上，錯誤儀表 ⑫ 抓到）
--    create or replace view 只往最後加欄位，既有權限保留（前端照樣讀不到）
-- ════════════════════════════════════════════════════════════════════

-- ── ① 練習賽房間 ─────────────────────────────────────────────────
create or replace function public._friendly_start(p_game uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare g friendly_games; v_store uuid; v_table uuid; v_sid uuid; n int; r record;
begin
  select * into g from friendly_games where id = p_game for update;
  if g.id is null or g.status <> 'waiting' then return g.session_id; end if;
  if (select count(*) from friendly_game_players where game_id = p_game and left_at is null) <> 4 then
    return null;
  end if;

  select id into v_store from stores where org_id = g.org_id and is_virtual and deleted_at is null limit 1;
  if v_store is null then raise exception '好友練習賽的設定不存在（請找總部）'; end if;

  -- 一間沒有開著場次的練習賽房間；沒有就建一間（打完放回去重用，所以房間數 ＝ 同時在打的最多場數）
  select t.id into v_table
    from tables t
   where t.store_id = v_store and t.is_active and t.deleted_at is null
     and not exists (select 1 from table_sessions s
                      where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
   order by t.sort_order, t.created_at
   limit 1 for update skip locked;
  if v_table is null then
    select count(*) into n from tables where store_id = v_store;
    -- 桌名客人會在手機計分板上看到；同一間門市底下不能重名 ⇒ 帶編號（2026-10-30 使用者定名「練習賽房間」）
    insert into tables (org_id, store_id, label, is_active, seats, sort_order, auto_assign, note)
    values (g.org_id, v_store, '練習賽房間 ' || (n + 1)::text, true, 4, n + 1, false, '好友練習賽用（系統建立）')
    returning id into v_table;
  end if;

  insert into table_sessions (org_id, store_id, table_id, mode, stake_level_id, status, planned_rounds,
                              game_type, flower, started_at, idempotency_key)
  values (g.org_id, v_store, v_table, 'friendly', g.stake_level_id, 'open', g.rounds,
          g.game_type, g.flower, now(), 'friendly-' || g.id::text)
  returning id into v_sid;

  -- 座位留空：四支手機在計分板「定座位」時決定（同店裡）
  insert into session_players (org_id, session_id, member_id, join_type, status, charged_points)
  select g.org_id, v_sid, fp.member_id, 'opener', 'playing', 0
    from friendly_game_players fp
   where fp.game_id = p_game and fp.left_at is null;

  update friendly_games set status = 'playing', session_id = v_sid, started_at = now(), updated_at = now()
   where id = p_game;

  -- 成桌通知：App 內（成桌彈窗），不推 LINE
  for r in select fp.member_id from friendly_game_players fp where fp.game_id = p_game and fp.left_at is null loop
    insert into app_notifications (org_id, member_id, type, ref_id, payload)
    values (g.org_id, r.member_id, 'friendly_ok', p_game,
            jsonb_build_object('text', '好友練習賽成桌了！打開 MIGI 智慧計分板開始記分', 'game_id', p_game));
  end loop;
  return v_sid;
end $function$;

-- ── ② 這個人上一次用哪一種送出 ─────────────────────────────────────
create or replace function public.tbl_my_send_mode_tx(p_token text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare d public.table_devices; v_session uuid; v_seat smallint; v_manual boolean;
begin
  d := public._tbl_device(p_token);   -- 手機的 table_id 已換成他現在坐的那一桌
  select id into v_session from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if v_session is null then
    return jsonb_build_object('ok', true, 'mode', 'pat');
  end if;

  -- 這台裝置在這一場代表哪個座位：手機看人、平板看它選了誰
  select sp.seat into v_seat
    from session_players sp
   where sp.session_id = v_session and sp.left_at is null
     and (case when d.kind = 'phone' then sp.member_id = d.member_id else sp.device_id = d.id end)
   limit 1;
  if v_seat is null then
    return jsonb_build_object('ok', true, 'mode', 'pat');
  end if;

  -- 這一場他最後一次送出的胡牌／自摸（被取消的也算 —— 他按的就是那一種）
  select h.manual_tai into v_manual
    from hands h
   where h.session_id = v_session and h.submitted_seat = v_seat and h.result in ('ron', 'tsumo')
   order by h.created_at desc
   limit 1;
  return jsonb_build_object('ok', true, 'mode', case when coalesce(v_manual, false) then 'num' else 'pat' end);
end $function$;

-- 平板與手機用裝置憑證叫（同其他 tbl_* 函式）；身分由 _tbl_device 從憑證認出來，不收「我是誰」
grant execute on function public.tbl_my_send_mode_tx(text) to anon, authenticated;

-- ── ③ 報表檢視表補欄位 ────────────────────────────────────────────
create or replace view public.v_real_stores as
 select s.id, s.org_id, s.name, s.address, s.is_active, s.deleted_at, s.created_at, s.updated_at,
        s.created_by, s.updated_by, s.code, s.city, s.district, s.lat, s.lng, s.open_time, s.close_time,
        s.store_type, s.is_test, s.entity_id, s.phone, s.parking, s.photos, s.note,
        s.on_duty_staff_id, s.on_duty_since, s.is_virtual
   from stores s
   join orgs o on o.id = s.org_id
  where s.is_test = false and s.deleted_at is null
    and s.created_at >= coalesce(o.live_from, 'infinity'::timestamptz);

-- ── 驗證（單一 SELECT）────────────────────────────────────────────
select
  case when pg_get_functiondef('public._friendly_start(uuid)'::regprocedure) like '%''練習賽房間 ''%'
       then '✅' else '🔴' end || ' ① 練習賽房間的桌名'                                         as "①",
  case when exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.oid = 'public.tbl_my_send_mode_tx(text)'::regprocedure
                       and a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
        and (select prosecdef from pg_proc where oid = 'public.tbl_my_send_mode_tx(text)'::regprocedure)
       then '✅' else '🔴' end || ' ② 讀送出方式的函式在、平板手機叫得動'                          as "②",
  case when exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'v_real_stores' and column_name = 'is_virtual')
        and not has_table_privilege('anon', 'public.v_real_stores', 'SELECT')
       then '✅' else '🔴' end || ' ③ 檢視表補上欄位、前端仍讀不到'                              as "③";
