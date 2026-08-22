-- 【這是什麼】配桌 → 實體桌的橋：pos_queue_members_tx、pos_seat_queue_tx。
--   附帶：將數統一成 2 將 / 3 將（拿掉一將），status 新增 seated。
-- 【何時讀】要測「POS 開固定局 → APP 報名 → 四人成桌 → POS 收桌 → APP 成績頁」之前。
--
-- ═══ 這座橋為什麼不存在 ═══
--   · open_session_tx 的簽名裡沒有任何 queue 參數
--   · match_queues.matched_session_id 這個欄位沒有任何程式在寫
--   · POS 看不到房裡是誰（list_match_queues_tx 只回 count(*)）
--   配桌房與實體開桌是兩個互不相識的世界，中間那一步只能靠店員記在腦子裡。
--
-- ═══ 兩個既有的衝突，一起修 ═══
--
-- 🔴 ① 將數對不上：配桌的 rounds 是文字「一將/二將/三將」，
--      而 open_session_tx 的 p_planned_rounds 只收 2 或 3（invalid_rounds）。
--      **一將的桌根本開不出來**，而 create_match_queue_tx 的預設就是一將。
--      → 決定拿掉一將（2026-08-23）。檯費定價本來就只有 2/3 將，
--        提供一個收不到錢的選項，是讓客人選一個到現場才發現不能用的東西。
--
-- 🔴 ② 同一個欄位兩種寫法：會員 App 存 '2 將'/'3 將'（阿拉伯數字），
--      POS 與 RPC 預設存 '一將'/'二將'/'三將'（中文數字）。
--      rounds 是自由文字，兩種都存得進去，而畫面是直接顯示原值。
--      → 統一成會員端那套（'2 將'/'3 將'）—— 那是客人看得到的字面。
--
-- ⚠ session_players 是**結帳後才建立**的（CLAUDE.md 待辦 3：
--   系統裡不存在「已入座但未付款」）。所以「帶到桌」只開 session，
--   不把人塞進 session_players —— 那會建出沒付錢的入座紀錄，檯費就永遠收不到。
--   人要走既有的結帳流程一個一個進去。

-- ============================================================
-- 一、status 新增 seated
-- ============================================================
-- 沒有終端狀態的話，房會永遠停在 matched，
-- 而 get_my_active_queue_tx 認 waiting+matched → 客人的配桌頁永遠顯示「即將開始」下不來。
do $do$
declare v_def text;
begin
  select pg_get_constraintdef(oid) into v_def
    from pg_constraint
   where conrelid = 'match_queues'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) ilike '%status%';

  if v_def is null then
    raise exception 'match_queues 沒有 status 的 CHECK，先確認實際約束再改';
  end if;
  if v_def ilike '%seated%' then
    raise notice 'status 已經允許 seated，略過';
  else
    -- 約束名要撈出來，不能寫死（不同環境可能不同名）
    execute (select 'alter table match_queues drop constraint ' || quote_ident(conname)
               from pg_constraint
              where conrelid = 'match_queues'::regclass and contype = 'c'
                and pg_get_constraintdef(oid) ilike '%status%' limit 1);
    alter table match_queues add constraint match_queues_status_check
      check (status = any (array['waiting', 'matched', 'seated', 'cancelled', 'expired']));
    raise notice 'status 已加入 seated';
  end if;
end $do$;

comment on column match_queues.status is
  'waiting 等待中／matched 已成桌／seated 已帶到實體桌（matched_session_id 有值）／cancelled 取消／expired 過期';

-- ============================================================
-- 二、將數統一：一將 → 2 將，中文數字 → 阿拉伯數字
-- ============================================================
update recurring_tables
   set rounds = case
     when rounds ilike '%三%' or rounds like '%3%' then '3 將'
     else '2 將'   -- 一將與二將都變成 2 將（一將已取消提供）
   end
 where rounds is distinct from '2 將' and rounds is distinct from '3 將';

update match_queues
   set rounds = case
     when rounds ilike '%三%' or rounds like '%3%' then '3 將'
     else '2 將'
   end
 where status in ('waiting', 'matched')
   and rounds is distinct from '2 將' and rounds is distinct from '3 將';

-- ============================================================
-- 三、POS 看得到房裡是誰
-- ============================================================
-- ⚠ 不改 list_match_queues_tx —— 那支會員端每 5 秒輪詢一次，
--   讓它多背四個人的資料是白白加重。POS 只在展開某一房時才需要名單。
drop function if exists pos_queue_members_tx(uuid, uuid);

create function pos_queue_members_tx(p_org_id uuid, p_queue uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'member_id', m.id,
    'nickname',  m.display_name,
    'rank',      m.rank,
    'title',     m.title,
    'joined_at', p.joined_at
  ) order by p.joined_at), '[]'::jsonb)
  from match_queue_players p
  join members m on m.id = p.member_id
  join match_queues q on q.id = p.queue_id
  where p.queue_id = p_queue
    and p.left_at is null
    and q.org_id = p_org_id
$$;

grant execute on function pos_queue_members_tx(uuid, uuid) to anon, authenticated;

-- ============================================================
-- 四、帶到桌
-- ============================================================
drop function if exists pos_seat_queue_tx(uuid, uuid, uuid, uuid);

create function pos_seat_queue_tx(
  p_org_id   uuid,
  p_queue    uuid,
  p_table_id uuid,
  p_staff_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  q        record;
  v_rounds int;
  v_open   jsonb;
  v_sid    uuid;
begin
  select * into q from match_queues where id = p_queue and org_id = p_org_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  -- 冪等：已經帶過就直接回同一張桌，不再開第二桌
  if q.status = 'seated' and q.matched_session_id is not null then
    return jsonb_build_object('ok', true, 'already', true, 'session_id', q.matched_session_id);
  end if;
  if q.status not in ('waiting', 'matched') then
    return jsonb_build_object('ok', false, 'reason', 'bad_status', 'status', q.status);
  end if;
  if p_table_id is null then
    return jsonb_build_object('ok', false, 'reason', 'table_required');
  end if;

  -- 將數：兩種寫法都吃（'2 將' 與 '二將'），但一將擋下並說清楚
  v_rounds := case
    when q.rounds ilike '%三%' or q.rounds like '%3%' then 3
    when q.rounds ilike '%二%' or q.rounds like '%2%' then 2
    else null end;
  if v_rounds is null then
    return jsonb_build_object('ok', false, 'reason', 'rounds_not_supported', 'rounds', q.rounds);
  end if;

  /* 直接重用 open_session_tx —— 它已經有 p_game_type / p_flower，
     牌規可以完整帶進 table_sessions，收桌後的紀錄才有牌型。
     ⚠ idempotency_key 用 queue id：店員連按兩下不會開出兩張桌
       （open_session_tx 撞到同一把鑰匙會回原本那張，duplicate=true）。
     ⚠ open_method 用 'auto'：這桌是系統配出來的，不是店員自己排的。
       之後要分析「自動配桌佔比」就靠這個欄位。 */
  v_open := open_session_tx(
    p_table_id, 'matched', q.stake_level_id, v_rounds, null,
    p_staff_id, 'auto', 'queue-' || p_queue::text, q.game_type, q.flower);

  if not coalesce((v_open->>'ok')::boolean, false) then
    return v_open;   -- table_busy / table_unavailable 等原樣傳回，訊息已經是中文
  end if;
  v_sid := (v_open->>'session_id')::uuid;

  update match_queues
     set status = 'seated', matched_session_id = v_sid, updated_at = now()
   where id = p_queue;

  return jsonb_build_object(
    'ok', true, 'session_id', v_sid, 'rounds', v_rounds,
    'members', pos_queue_members_tx(p_org_id, p_queue));
end $$;

comment on function pos_seat_queue_tx(uuid, uuid, uuid, uuid) is
  'POS 把成桌的配桌房帶到實體桌：開 session、寫回 matched_session_id、房改 seated。'
  '⚠ 不寫 session_players —— 那是結帳後才建立的，人要走既有結帳流程進去。';

grant execute on function pos_seat_queue_tx(uuid, uuid, uuid, uuid) to anon, authenticated;

-- ============================================================
-- 五、驗證（硬規則 7：實際執行並看到回傳）
-- ============================================================
create temp table if not exists _v(ord int primary key, 項目 text, 結果 text) on commit drop;

do $do$
declare
  v_org   uuid := '11111111-1111-1111-1111-111111111111';
  v_store uuid := '22222222-2222-2222-2222-222222222222';
  v_stake uuid := '1efa2006-4480-4996-9605-afc0ac2c51c7';
  v_q uuid; v_tbl uuid; v_r jsonb; v_r2 jsonb; v_sid uuid;
begin
  delete from _v;

  insert into _v values (1, '① status 現在允許哪些值',
    (select pg_get_constraintdef(oid) from pg_constraint
      where conrelid='match_queues'::regclass and contype='c'
        and pg_get_constraintdef(oid) ilike '%status%' limit 1));

  insert into _v values (2, '② 將數統一後的實際值',
    coalesce((select string_agg(distinct rounds, '   ') from match_queues
               where status in ('waiting','matched','seated')), '（沒有房）')
    || '　｜範本：' ||
    coalesce((select string_agg(distinct rounds, '   ') from recurring_tables), '（沒有範本）'));

  -- 找一間等待中的房來測；沒有就自己開一間即時房
  select id into v_q from match_queues
   where org_id = v_org and store_id = v_store and status = 'waiting' and play_at > now()
   order by play_at limit 1;
  if v_q is null then
    v_q := (pos_create_queue_tx(v_org, v_store, v_stake,
              now() + interval '30 hours', '台麻', '無花', '2 將', 4)->>'queue_id')::uuid;
    insert into _v values (3, '③ 沒有現成的房，臨時開了一間來測', v_q::text);
  else
    insert into _v values (3, '③ 拿來測的房', v_q::text);
  end if;

  select t.id into v_tbl from tables t
   where t.org_id = v_org and t.store_id = v_store
     and coalesce(t.is_active, true) = true and t.deleted_at is null
     and not exists (select 1 from table_sessions s
                      where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
   order by t.sort_order nulls last limit 1;
  if v_tbl is null then
    insert into _v values (99, '⛔ 沒有空桌可測，後續略過', '先去 POS 收掉一張桌');
    return;
  end if;

  insert into _v values (4, '④ 房裡有誰', pos_queue_members_tx(v_org, v_q)::text);

  v_r := pos_seat_queue_tx(v_org, v_q, v_tbl, null);
  insert into _v values (5, '⑤ 帶到桌回傳', v_r::text);

  if coalesce((v_r->>'ok')::boolean, false) then
    v_sid := (v_r->>'session_id')::uuid;

    insert into _v values (6, '⑥ 房的狀態與 matched_session_id',
      (select status || ' / ' || coalesce(matched_session_id::text, 'null')
         from match_queues where id = v_q));

    insert into _v values (7, '⑦ 開出來的 session（牌規有沒有帶過去）',
      (select 'mode=' || mode || ' 將=' || coalesce(planned_rounds::text,'null')
              || ' ' || coalesce(game_type,'?') || coalesce(flower,'?')
              || ' open_method=' || coalesce(open_method,'?')
         from table_sessions where id = v_sid));

    insert into _v values (8, '⑧ session_players 應為 0（結帳後才建立）',
      (select count(*)::text from session_players where session_id = v_sid));

    -- 冪等：再帶一次應該回同一張桌
    v_r2 := pos_seat_queue_tx(v_org, v_q, v_tbl, null);
    insert into _v values (9, '⑨ 再帶一次（應回 already=true 且同一個 session）',
      v_r2::text);

    /* 清理：把測試開的桌收掉、房改回等待中。
       ⚠ 順序不能反 —— matched_session_id 若有外鍵指向 table_sessions，
         先刪桌會被擋住，整支 DO 拋例外連 seated 狀態都一起回滾。
         先把外鍵斷開再刪。
       ⚠ 外包一層 exception：清理失敗不該讓前面驗過的東西全部白做。 */
    update match_queues set status = 'waiting', matched_session_id = null where id = v_q;
    begin
      delete from table_sessions where id = v_sid;
      insert into _v values (10, '⑩ 已清理（房改回等待中、測試桌刪掉）', '✅');
    exception when others then
      insert into _v values (10, '⑩ 房已改回等待中，但測試桌刪不掉',
        '⚠ ' || sqlerrm || '　→ session ' || v_sid::text || ' 留在資料庫，去 POS 收掉即可');
    end;
  end if;

  insert into _v values (20, '⑳ 一將的房應該被擋',
    coalesce((select pos_seat_queue_tx(v_org, v_q, v_tbl, null)::text
                from match_queues where id = v_q and rounds = '一將'), '（沒有一將的房 —— 已全部改成 2 將）'));
end $do$;

select 項目, 結果 from _v order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
-- ① 應含 seated。② 應該只剩「2 將」「3 將」。
-- ⑦ planned_rounds 應為 2 或 3、game_type/flower 有值、open_method=auto。
--    ⚠ 牌規是 null 的話，收桌後的牌局紀錄就少了牌型 —— 那時候補不回來。
-- ⑧ 必須是 0：帶到桌不建立入座紀錄，人要走結帳流程進去。
--    這裡若不是 0，代表有人在別處偷塞 session_players，檯費會收不到。
-- ⑨ 應為 already=true 且 session_id 與 ⑤ 相同 —— 店員連按兩下不會開出兩張桌。
-- ⑩ 之後資料庫回到執行前的狀態（只多了 seated 狀態與將數正規化）。
--
-- ── 接下來要改的前端 ─────────────────────────────────────────
-- · migi-pos QueuePage：將數選項改 ['2 將','3 將']，預設 '2 將'
-- · migi-web social.js createMatchQueue：預設 rounds 從 '一將' 改 '2 將'
-- · migi-pos 配桌卡：加「帶到桌」按鈕（選空桌 → pos_seat_queue_tx → 跳結帳頁）
-- ⚠ SeatPage.jsx 裡的「一將／下一將」是**牌局進行中的將數計數**，完全不同的東西，
--   千萬不要一起取代（同名不同義，跟 2026-08-19 的 kind 是同一個陷阱）。
