-- 【這是什麼】湊滿四人自動帶桌 + POS 幫現場客人登記進同一個隊列。
-- 【何時讀】執行前。前置盤點見 sql/checks/查自動配桌前置.sql（2026-08-23 已跑）。
--
-- ═══ 這批解掉的兩件事 ═══
--
-- ① **自動配桌**（CLAUDE.md 待辦 5，2026-08-20 拍板）
--    湊滿四人 → 系統自己挑一張空桌開下去，店員不用按任何東西。
--    ⚠ 拍板時說「四件事缺一不可」，這支做前兩件（欄位 + 指派規則），
--      另外兩件在 POS 前端：桌況卡的「現場」標記、收桌彈窗的「保留給現場」勾選。
--      少了那兩件，週六關掉的桌週一沒人記得，那幾桌會從此永遠不被配到而且看不出來。
--
-- ② 🔴 **現場客人與 App 不在同一條隊**（待辦 5 裡那條紅字）
--    店員在 POS 的空位按「＋」把現場客人加進同一個隊列，先來先排、同一份名單。
--    餐飲業的候位系統（OpenTable / Yelp Waitlist）都是這樣：
--    系統從不自己帶位，但兩種客人一定進同一條隊。
--
-- ═══ 為什麼抽出 _finalize_queue_full_tx ═══
--
-- 成桌可能由兩條路造成：App 報名（join_match_queue_tx）與 POS 現場登記。
-- 「滿員之後要做什麼」（改狀態、發通知、自動帶桌）如果兩邊各寫一份，
-- 遲早會漂 —— 改了一邊忘另一邊，而且不會報錯，只會有一半的人收不到通知。

-- ============================================================
-- 一、tables.auto_assign
-- ============================================================
-- ⚠ 這是**設定不是狀態**：桌況（使用中／空桌）每次從 table_sessions 算出來，
--   而「這桌不給系統配」是店員的意思，沒人改就不會變，所以要存欄位。
--   tables 仍然沒有 status 欄位，兩者不衝突。
alter table tables add column if not exists auto_assign boolean;
update tables set auto_assign = true where auto_assign is null;
alter table tables alter column auto_assign set not null;
alter table tables alter column auto_assign set default true;

comment on column tables.auto_assign is
  '是否開放系統自動配桌。預設 true —— 店員可把個別桌設成「現場專用」。'
  '⚠ 設成 false 的桌一定要在桌況卡上看得出來，否則關掉的桌沒人記得改回來。';

-- ============================================================
-- 二、自動挑一張桌帶進去
-- ============================================================
drop function if exists _try_auto_seat_tx(uuid, uuid, uuid);

create function _try_auto_seat_tx(p_org uuid, p_queue uuid, p_staff uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_store uuid; v_tbl uuid;
begin
  select store_id into v_store from match_queues where id = p_queue and org_id = p_org;
  if v_store is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  /* 指派規則（拍板）：只看 auto_assign = true 且目前沒有 open 場次的桌。
     ⚠ for update skip locked：兩桌同時湊滿時不會挑到同一張。
       沒有它的話第二個會撞上 uq_sessions_open_table 而失敗 ——
       雖然不會重複開桌，但那是「靠約束擋下來」而不是「本來就不會發生」。 */
  select t.id into v_tbl
    from tables t
   where t.org_id = p_org and t.store_id = v_store
     and coalesce(t.is_active, true) = true
     and t.deleted_at is null
     and t.auto_assign = true
     and not exists (select 1 from table_sessions s
                      where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
   order by t.sort_order nulls last, t.label
   limit 1
   for update of t skip locked;

  if v_tbl is null then
    -- 沒有可配的桌不是錯誤：房留在 matched，店員自己處理（現場可能就是滿的）
    return jsonb_build_object('ok', false, 'reason', 'no_free_table');
  end if;

  return pos_seat_queue_tx(p_org, p_queue, v_tbl, p_staff);
end $$;

-- ============================================================
-- 三、滿員之後要做的事（兩條路共用）
-- ============================================================
drop function if exists _finalize_queue_full_tx(uuid, uuid, uuid);

create function _finalize_queue_full_tx(p_org uuid, p_queue uuid, p_staff uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_seat jsonb; v_tbl text;
begin
  update match_queues
     set status = 'matched', matched_at = now(), updated_at = now()
   where id = p_queue and status = 'waiting';

  -- 通知房裡每一個人
  insert into app_notifications(org_id, member_id, type, payload, ref_id)
  select p_org, qp.member_id, 'table_ok',
         jsonb_build_object('text', '配桌成功！準時到店開打', 'queue_id', p_queue),
         p_queue
    from match_queue_players qp
   where qp.queue_id = p_queue and qp.left_at is null;

  -- 自動帶桌。失敗（沒空桌）不算錯 —— 房停在 matched，店員自己帶
  v_seat := _try_auto_seat_tx(p_org, p_queue, p_staff);

  if coalesce((v_seat->>'ok')::boolean, false) then
    select t.label into v_tbl
      from table_sessions s join tables t on t.id = s.table_id
     where s.id = (v_seat->>'session_id')::uuid;
    return jsonb_build_object('ok', true, 'status', 'seated',
      'session_id', v_seat->>'session_id', 'table_label', v_tbl);
  end if;

  return jsonb_build_object('ok', true, 'status', 'matched',
    'seat_reason', v_seat->>'reason');
end $$;

comment on function _finalize_queue_full_tx(uuid, uuid, uuid) is
  '湊滿之後的共用收尾：改 matched、發通知、嘗試自動帶桌。'
  'App 報名與 POS 現場登記兩條路都走這裡 —— 各寫一份遲早會漂。';

-- ============================================================
-- 四、join_match_queue_tx 接上自動帶桌
-- ============================================================
-- 整支重建（原文已用 pg_get_functiondef 撈出並逐行審過，硬規則 3）。
-- 簽名沒變，不需要 DROP。
--
-- ⚠ 回傳值**維持 'matched'** 不改成 'seated'。
--   會員端 App 不需要知道被帶到哪張桌（他人就在店裡），
--   而改回傳值會動到前端既有的判斷 —— 為了一個 App 用不到的資訊冒那個險不值得。
--   POS 靠輪詢 pos_list_queues_tx 得知。
create or replace function join_match_queue_tx(p_org_id uuid, p_member uuid, p_queue uuid, p_join_source text default 'browse')
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_seats int; v_cnt int; v_status text; v_expires timestamptz; v_other uuid; v_play_at timestamptz; v_source text;
begin
  -- 鎖住這一房，序列化「搶最後一位」
  select seats, status, expires_at, play_at, source
    into v_seats, v_status, v_expires, v_play_at, v_source
    from match_queues where id=p_queue and org_id=p_org_id for update;
  if not found then raise exception '房不存在'; end if;
  if v_status <> 'waiting' then raise exception '此桌目前無法加入'; end if;
  if v_expires is not null and v_expires < now() then raise exception '此桌目前無法加入'; end if;

  -- ★ 類型上限 + 6h 間隔檢查（成桌也算）
  perform _check_join_conflict(p_org_id, p_member, v_play_at, v_source);

  -- 黑名單雙向
  for v_other in
    select member_id from match_queue_players where queue_id=p_queue and left_at is null
  loop
    if _blocked_between(p_org_id, p_member, v_other) then
      raise exception '此桌目前無法加入';
    end if;
  end loop;

  insert into match_queue_players(org_id, queue_id, member_id, join_source)
  values (p_org_id, p_queue, p_member, p_join_source)
  on conflict do nothing;

  select count(*) into v_cnt from match_queue_players where queue_id=p_queue and left_at is null;
  if v_cnt >= v_seats then
    -- 改狀態、發通知、自動帶桌都在這一支裡（POS 現場登記走同一支）
    perform _finalize_queue_full_tx(p_org_id, p_queue, null);
    return 'matched';
  end if;
  return 'waiting';
end $function$;

-- ============================================================
-- 五、POS 幫現場客人登記
-- ============================================================
drop function if exists pos_add_queue_member_tx(uuid, uuid, uuid, uuid);

create function pos_add_queue_member_tx(p_org uuid, p_queue uuid, p_member uuid, p_staff uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seats int; v_cnt int; v_status text; v_expires timestamptz;
  v_play_at timestamptz; v_source text; v_other uuid; v_fin jsonb;
begin
  if p_member is null then return jsonb_build_object('ok', false, 'reason', 'member_required'); end if;

  select seats, status, expires_at, play_at, source
    into v_seats, v_status, v_expires, v_play_at, v_source
    from match_queues where id = p_queue and org_id = p_org for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_status <> 'waiting' then return jsonb_build_object('ok', false, 'reason', 'not_waiting', 'status', v_status); end if;
  if v_expires is not null and v_expires < now() then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;

  if exists (select 1 from match_queue_players
              where queue_id = p_queue and member_id = p_member and left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'already_in');
  end if;

  /* ⚠ 黑名單與衝突檢查照樣做，跟 App 那條路一致。
     店員在現場、看得到人，但「互相封鎖的兩個人被排在同一桌」是客人自己設的意思，
     不該因為換一個入口就繞過。擋下來之後店員可以當面問，那比事後尷尬好。 */
  begin
    perform _check_join_conflict(p_org, p_member, v_play_at, v_source);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'conflict', 'message', sqlerrm);
  end;

  for v_other in
    select member_id from match_queue_players where queue_id = p_queue and left_at is null
  loop
    if _blocked_between(p_org, p_member, v_other) then
      return jsonb_build_object('ok', false, 'reason', 'blocked');
    end if;
  end loop;

  -- join_source = 'pos_walkin'：這是之後分析「現場登記 vs App 自己報名」的唯一依據，
  -- 沿用 'browse' 就永遠分不出來了
  insert into match_queue_players(org_id, queue_id, member_id, join_source)
  values (p_org, p_queue, p_member, 'pos_walkin')
  on conflict do nothing;

  select count(*) into v_cnt from match_queue_players where queue_id = p_queue and left_at is null;
  if v_cnt >= v_seats then
    v_fin := _finalize_queue_full_tx(p_org, p_queue, p_staff);
    return jsonb_build_object('ok', true, 'full', true,
      'status', v_fin->>'status', 'session_id', v_fin->>'session_id',
      'table_label', v_fin->>'table_label', 'seat_reason', v_fin->>'seat_reason');
  end if;

  return jsonb_build_object('ok', true, 'full', false, 'players', v_cnt, 'seats', v_seats);
end $$;

grant execute on function pos_add_queue_member_tx(uuid, uuid, uuid, uuid) to anon, authenticated;

-- ============================================================
-- 六、POS 專用列表（含成員、含剛帶到桌的）
-- ============================================================
-- ⚠ 不改 list_match_queues_tx：那支會員端每 5 秒輪詢，
--   讓它多背四個人的資料是白白加重。POS 另開一支。
-- ⚠ 也回傳「最近 10 分鐘內帶到桌的」——
--   自動帶桌沒有人按按鈕，POS 得靠輪詢才知道剛剛發生了什麼，
--   否則店員只會看到那一房憑空消失。
drop function if exists pos_list_queues_tx(uuid, uuid);

create function pos_list_queues_tx(p_org uuid, p_store uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', q.id,
    'status', q.status,
    'source', q.source,
    'stake_level_id', q.stake_level_id,
    'stake', sl.label,
    'game_type', q.game_type, 'flower', q.flower, 'rounds', q.rounds,
    'seats', q.seats,
    'play_at', q.play_at,
    'open_at', q.open_at,
    'recurring_freq', q.recurring_freq,
    'opener', mo.display_name,
    'session_id', q.matched_session_id,
    'table_label', tb.label,
    'seated_at', case when q.status = 'seated' then q.updated_at else null end,
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'member_id', m.id, 'nickname', m.display_name,
        'rank', m.rank, 'title', m.title,
        'tier', coalesce(m.tier_override, m.tier),
        'joined_at', p.joined_at,
        'walk_in', p.join_source = 'pos_walkin'
      ) order by p.joined_at)
      from match_queue_players p
      join members m on m.id = p.member_id
      where p.queue_id = q.id and p.left_at is null), '[]'::jsonb)
  ) order by (q.status = 'seated') desc, q.play_at), '[]'::jsonb)
  from match_queues q
  left join stake_levels sl on sl.id = q.stake_level_id and sl.org_id = p_org
  left join members mo on mo.id = q.opened_by
  left join table_sessions ts on ts.id = q.matched_session_id
  left join tables tb on tb.id = ts.table_id
  where q.org_id = p_org and q.store_id = p_store
    and (
      (q.status = 'waiting'
        and (q.expires_at is null or q.expires_at > now())
        and (q.open_at is null or q.open_at <= now()))
      or
      -- 剛帶到桌的：讓 POS 有機會跳「已帶到 T1」的彈窗
      (q.status = 'seated' and q.updated_at > now() - interval '10 minutes')
    )
$$;

grant execute on function pos_list_queues_tx(uuid, uuid) to anon, authenticated;

-- ============================================================
-- 七、驗證（硬規則 7：實際執行並看到回傳）
-- ============================================================
create temp table if not exists _v(ord int primary key, 項目 text, 結果 text) on commit drop;

do $do$
declare
  v_org   uuid := '11111111-1111-1111-1111-111111111111';
  v_store uuid := '22222222-2222-2222-2222-222222222222';   -- 高雄自由店（14 張桌）
  v_stake uuid;
  v_q uuid; v_r jsonb; v_ids uuid[]; v_i int; v_last jsonb;
begin
  delete from _v;

  /* 先把測試帳號從既有的房裡拉出來 —— 不然 _check_join_conflict 的
     「6 小時內不可同時報名」會擋住，測試永遠湊不滿四人。
     ⚠ 只清人不刪房：固定局的實例被關掉之後排程不會補回來
     （重複檢查不看 status，已存在就不再生成）。 */
  update match_queue_players p
     set left_at = now()
    from members m, match_queues q
   where m.id = p.member_id and q.id = p.queue_id
     and m.is_test = true and p.left_at is null
     and q.status in ('waiting', 'matched');
  update match_queues q
     set status = 'waiting', matched_at = null
   where q.status = 'matched'
     and (select count(*) from match_queue_players p
           where p.queue_id = q.id and p.left_at is null) < q.seats;

  insert into _v values (1, '① auto_assign 欄位',
    coalesce((select '有，預設 ' || column_default || '，not null=' ||
                     case when is_nullable = 'NO' then '是' else '否' end
                from information_schema.columns
               where table_schema='public' and table_name='tables' and column_name='auto_assign'),
             '❌ 沒建起來'));

  insert into _v values (2, '② 這間店可自動配的空桌數',
    (select count(*)::text from tables t
      where t.org_id=v_org and t.store_id=v_store and t.auto_assign
        and coalesce(t.is_active,true) and t.deleted_at is null
        and not exists (select 1 from table_sessions s
                         where s.table_id=t.id and s.status='open' and s.deleted_at is null)));

  select id into v_stake from stake_levels where org_id=v_org limit 1;
  v_q := (pos_create_queue_tx(v_org, v_store, v_stake,
            now() + interval '30 hours', '台麻', '無花', '2 將', 4)->>'queue_id')::uuid;
  insert into _v values (3, '③ 開一間測試房', v_q::text);

  /* 四個測試帳號逐一加入，第四個應該觸發自動帶桌。
     ⚠ limit 要放在子查詢裡 —— array_agg 之後只有一列，
       外層 limit 4 等於沒限制，會把所有測試帳號都抓進來。 */
  select array_agg(id) into v_ids
    from (select id from members
           where org_id = v_org and is_test and deleted_at is null
           order by display_name limit 4) t;

  if v_ids is null or array_length(v_ids, 1) is null then
    insert into _v values (99, '⛔ 沒有測試帳號，加人那幾步略過', 'members.is_test 全是 false？');
    return;
  end if;

  for v_i in 1..array_length(v_ids, 1) loop
    v_last := pos_add_queue_member_tx(v_org, v_q, v_ids[v_i], null);
    insert into _v values (10 + v_i, '④-' || v_i || ' 加入第 ' || v_i || ' 人', v_last::text);
  end loop;

  insert into _v values (20, '⑤ 房的最終狀態',
    (select status || '　桌=' || coalesce((select t.label from table_sessions s
                                            join tables t on t.id=s.table_id
                                           where s.id=q.matched_session_id), '(沒帶到桌)')
       from match_queues q where q.id=v_q));

  insert into _v values (21, '⑥ session_players 應為 0（結帳後才建立）',
    coalesce((select (select count(*) from session_players p where p.session_id=q.matched_session_id)::text
                from match_queues q where q.id=v_q), '-'));

  /* ⚠ 每一段都要 coalesce。table_label 在還沒帶到桌時是 null，
     而 SQL 的 '字串' || NULL 會讓**整串變 NULL** ——
     外層 coalesce 就會誤報成「列表裡找不到」，明明房好好地在裡面。
     （同 2026-08-19 的 NULL not in (...) 之坑：null 不是空字串） */
  insert into _v values (22, '⑦ pos_list_queues_tx 有沒有回傳這一房（含成員）',
    coalesce((select coalesce(e->>'status', '?')
                     || '　桌=' || coalesce(e->>'table_label', '(還沒帶到桌)')
                     || '　成員 ' || jsonb_array_length(e->'members') || ' 人：'
                     || coalesce((select string_agg((x->>'nickname') ||
                                    case when (x->>'walk_in')::bool then '(現場)' else '' end, '、')
                                    from jsonb_array_elements(e->'members') x), '(空的)')
                from jsonb_array_elements(pos_list_queues_tx(v_org, v_store)) e
               where e->>'id' = v_q::text), '❌ 列表裡真的找不到'));

  insert into _v values (23, '⑧ 重複加同一人（應回 already_in）',
    pos_add_queue_member_tx(v_org, v_q, v_ids[1], null)::text);

  -- 清理：房與桌都收掉
  declare v_sid uuid;
  begin
    select matched_session_id into v_sid from match_queues where id=v_q;
    delete from match_queue_players where queue_id=v_q;
    update match_queues set status='cancelled', matched_session_id=null where id=v_q;
    if v_sid is not null then delete from table_sessions where id=v_sid; end if;
    insert into _v values (30, '⑨ 已清理', '✅ 測試房與測試桌都收掉了');
  exception when others then
    insert into _v values (30, '⑨ 清理失敗', '⚠ ' || sqlerrm || '　→ 去 POS 手動收掉');
  end;
end $do$;

select 項目, 結果 from _v order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
-- ④-4（加入第 4 人）應該回 full=true、status=seated、table_label 有值。
--   status 是 matched 而不是 seated → 看 seat_reason：
--     no_free_table = 這間店沒有可自動配的空桌（第 ② 項是 0）
-- ⑥ 必須是 0：自動帶桌不建立入座紀錄，人要走結帳流程進去。
-- ⑦ 成員名單應該四個人，而且每個都帶「(現場)」—— 這批測試全部走 POS 登記。
-- ⑨ 之後資料庫回到執行前的狀態（只多了 auto_assign 欄位與三支新函式）。
--
-- ── 接下來要做的 POS 前端（待辦 5 說「四件事缺一不可」）───────
-- 1. 座位格改成客人卡（頭像／暱稱／段位），不再顯示「已報名」
-- 2. 空位「＋」→ 選客人 → pos_add_queue_member_tx
-- 3. 拿掉「帶到桌」按鈕；輪詢偵測到新的 seated 就跳彈窗（成員 + 牌局資訊）
-- 4. 🔴 桌況卡顯示「現場」標記 + 收桌彈窗加「收完保留給現場」勾選
--    ⚠ 少了第 4 項，週六關掉的桌週一沒人記得，
--      那幾桌會從此永遠不被自動配到而且畫面上看不出來。
