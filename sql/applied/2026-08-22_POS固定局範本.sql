-- 【這是什麼】POS 建立／管理固定局範本：pos_create_recurring_tx、pos_list_recurring_tx、
--   pos_set_recurring_enabled_tx。
-- 【何時讀】改 migi-pos QueuePage 的「＋ 店員開桌」之前。
--
-- ═══ 定位 ═══
--
-- 店員開桌是**一個流程、兩種類型**：
--   · 即時 → pos_create_queue_tx（已上線）→ 直接建一筆 match_queues
--   · 固定 → 這支 → 建一筆 recurring_tables 範本，實例由 cron 生成
--
-- ⚠ 為什麼固定局是寫範本而不是一次開未來 7 天的實例：
--   「每天 21:00 都有」是**設定**不是事件。一次開 7 天的話，七天後要有人記得再開，
--   漏了就沒有固定局而且沒人會發現 —— 那正是 CLAUDE.md 5.5 說的
--   「需要有人每週維護」的形狀。
--
-- ⚠ 建完立刻呼叫一次 generate_recurring_instances_tx：
--   不然店員設好了要等最多 6 小時（下一輪 cron）才看得到東西，
--   會以為沒設成功而重設一次。

-- ============================================================
-- 一、前置：weekday 對 daily 範本應可為 null
-- ============================================================
-- docs/00-進度與索引/待辦與未定案.md:118 就記著這條。
-- daily 規則的 weekday 沒有意義（現有那筆是 0＝週日，純殘值），
-- 硬要塞一個數字會讓人以為「每天的局只在週日」。
do $do$
begin
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='recurring_tables'
                and column_name='weekday' and is_nullable='NO') then
    alter table recurring_tables alter column weekday drop not null;
    raise notice 'recurring_tables.weekday 已改為可為 null';
  else
    raise notice 'recurring_tables.weekday 本來就可為 null';
  end if;
end $do$;

-- 既有 daily 範本的殘值清掉
update recurring_tables set weekday = null where frequency = 'daily' and weekday is not null;

-- ============================================================
-- 二、建立固定局範本
-- ============================================================
drop function if exists pos_create_recurring_tx(uuid, uuid, uuid, text, int, time, text, text, text, int, int);

create function pos_create_recurring_tx(
  p_org_id     uuid,
  p_store      uuid,
  p_stake      uuid,
  p_frequency  text,              -- daily | weekly
  p_weekday    int,               -- weekly 才需要（0=週日 … 6=週六）；daily 傳 null
  p_start_time time,
  p_game_type  text default '台麻',
  p_flower     text default '無花',
  p_rounds     text default '一將',
  p_seats      int  default 4,
  p_lead_hours int  default null  -- null → daily 24、weekly 168
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid; v_lead int; v_gen int;
begin
  -- 業務錯誤回 {ok:false}，不拋例外 —— 前端要能分辨「擋下來」與「壞掉」
  if p_store      is null then return jsonb_build_object('ok', false, 'reason', 'store_required'); end if;
  if p_stake      is null then return jsonb_build_object('ok', false, 'reason', 'stake_required'); end if;
  if p_start_time is null then return jsonb_build_object('ok', false, 'reason', 'start_time_required'); end if;
  if p_frequency not in ('daily', 'weekly') then
    return jsonb_build_object('ok', false, 'reason', 'bad_frequency');
  end if;
  -- 每週的局沒指定星期幾，生成函式會拿 null 去比對而永遠不成立 ——
  -- 建得起來但一筆實例都不會產生，是最難查的那種
  if p_frequency = 'weekly' and (p_weekday is null or p_weekday not between 0 and 6) then
    return jsonb_build_object('ok', false, 'reason', 'weekday_required');
  end if;

  v_lead := coalesce(p_lead_hours, case when p_frequency = 'daily' then 24 else 24 * 7 end);
  if v_lead not between 1 and 720 then
    return jsonb_build_object('ok', false, 'reason', 'bad_lead_hours');
  end if;

  -- 同門市、同頻率、同星期、同時間已經有一個啟用中的範本 → 擋
  if exists (
    select 1 from recurring_tables
     where org_id = p_org_id and store_id = p_store
       and frequency = p_frequency
       and weekday is not distinct from (case when p_frequency = 'daily' then null else p_weekday end)
       and start_time = p_start_time
       and enabled = true
  ) then
    return jsonb_build_object('ok', false, 'reason', 'duplicate');
  end if;

  insert into recurring_tables(
    org_id, store_id, stake_level_id, frequency, weekday, start_time,
    game_type, flower, rounds, seats, enabled, lead_hours)
  values (
    p_org_id, p_store, p_stake, p_frequency,
    case when p_frequency = 'daily' then null else p_weekday end,   -- daily 不存星期
    p_start_time,
    p_game_type, p_flower, p_rounds, coalesce(p_seats, 4), true, v_lead)
  returning id into v_id;

  -- 立刻生成，不讓店員等下一輪 cron（最多 6 小時）
  v_gen := generate_recurring_instances_tx(p_org_id, 7);

  return jsonb_build_object('ok', true, 'recurring_id', v_id, 'generated', v_gen);
end $$;

comment on function pos_create_recurring_tx(uuid, uuid, uuid, text, int, time, text, text, text, int, int) is
  'POS 建立固定局範本，並立刻生成一次實例（不讓店員等 cron）。';

grant execute on function pos_create_recurring_tx(uuid, uuid, uuid, text, int, time, text, text, text, int, int) to anon, authenticated;

-- ============================================================
-- 三、列出本店的固定局範本
-- ============================================================
drop function if exists pos_list_recurring_tx(uuid, uuid);

create function pos_list_recurring_tx(p_org_id uuid, p_store uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', r.id,
    'frequency', r.frequency,
    'weekday', r.weekday,
    'start_time', r.start_time,
    'game_type', r.game_type,
    'flower', r.flower,
    'rounds', r.rounds,
    'seats', r.seats,
    'enabled', r.enabled,
    'lead_hours', r.lead_hours,
    'stake_level_id', r.stake_level_id,
    'stake', sl.label,
    -- 下一場：已生成、還沒開打的最早那筆
    'next_play_at', (select min(q.play_at) from match_queues q
                      where q.recurring_id = r.id and q.status = 'waiting' and q.play_at > now()),
    -- 客人現在看得到幾筆（開賣時間已到的）
    'open_now', (select count(*) from match_queues q
                  where q.recurring_id = r.id and q.status = 'waiting'
                    and q.play_at > now() and (q.open_at is null or q.open_at <= now())),
    -- 已生成但還沒開賣（接班用）
    'pending_open', (select count(*) from match_queues q
                      where q.recurring_id = r.id and q.status = 'waiting'
                        and q.play_at > now() and q.open_at is not null and q.open_at > now())
  ) order by r.enabled desc, r.frequency, r.weekday nulls first, r.start_time), '[]'::jsonb)
  from recurring_tables r
  left join stake_levels sl on sl.id = r.stake_level_id and sl.org_id = p_org_id
  where r.org_id = p_org_id and r.store_id = p_store
$$;

grant execute on function pos_list_recurring_tx(uuid, uuid) to anon, authenticated;

-- ============================================================
-- 四、停用／啟用範本
-- ============================================================
drop function if exists pos_set_recurring_enabled_tx(uuid, uuid, boolean);

create function pos_set_recurring_enabled_tx(p_org_id uuid, p_id uuid, p_enabled boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_closed int := 0; v_kept int := 0; v_gen int := 0;
begin
  if not exists (select 1 from recurring_tables where id = p_id and org_id = p_org_id) then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  update recurring_tables set enabled = p_enabled where id = p_id and org_id = p_org_id;

  if p_enabled then
    -- 重新啟用：立刻補生成，不然要等下一輪 cron
    v_gen := generate_recurring_instances_tx(p_org_id, 7);
    return jsonb_build_object('ok', true, 'enabled', true, 'generated', v_gen);
  end if;

  -- 停用時**必須一併關掉已經生出來的未來實例** ——
  -- 只改 enabled 的話，客人畫面上還看得到那幾場，而店員以為已經停了。
  -- 「設定關了但畫面還在」是最容易變成客訴的形狀。
  -- ⚠ 已經有人報名的不動：客人排了半小時被無聲刪掉，那是客訴。
  --   要能關得先有通知機制。
  select count(*) into v_kept
    from match_queues q
   where q.recurring_id = p_id and q.status = 'waiting' and q.play_at > now()
     and exists (select 1 from match_queue_players p
                  where p.queue_id = q.id and p.left_at is null);

  with done as (
    update match_queues q
       set status = 'expired', expires_at = least(coalesce(q.expires_at, now()), now()), updated_at = now()
     where q.recurring_id = p_id and q.status = 'waiting' and q.play_at > now()
       and not exists (select 1 from match_queue_players p
                        where p.queue_id = q.id and p.left_at is null)
    returning 1)
  select count(*) into v_closed from done;

  return jsonb_build_object('ok', true, 'enabled', false, 'closed', v_closed, 'kept_with_players', v_kept);
end $$;

comment on function pos_set_recurring_enabled_tx(uuid, uuid, boolean) is
  '停用固定局範本會一併關掉未來實例（有人報名的除外）—— 只改旗標的話客人還看得到。';

grant execute on function pos_set_recurring_enabled_tx(uuid, uuid, boolean) to anon, authenticated;

-- ============================================================
-- 五、驗證（硬規則 7：實際執行並看到回傳）
-- ============================================================
-- 完整來回：建每週範本 → 列表看得到 → 有生成實例 → 停用 → 實例被關掉 → 清理。
-- 用「每週四 15:00」這種現有範本沒有的組合，不會撞到既有資料。
--
-- ⚠ 用暫存表而不是一個大 SELECT：Postgres 不允許資料修改的 CTE 出現在子查詢裡
--   （WITH clause containing a data-modifying statement must be at the top level），
--   而第 ⑩ 項要 delete 測試資料。DO 區塊裡沒有這個限制。
create temp table if not exists _v(ord int primary key, 項目 text, 結果 text) on commit drop;

do $do$
declare
  v_org   uuid := '11111111-1111-1111-1111-111111111111';
  v_store uuid := '22222222-2222-2222-2222-222222222222';
  v_stake uuid := '1efa2006-4480-4996-9605-afc0ac2c51c7';
  v_r jsonb; v_id uuid; v_lst jsonb; v_off jsonb;
  v_inst int; v_after int; v_del_q int; v_del_r int;
begin
  delete from _v;

  v_r := pos_create_recurring_tx(v_org, v_store, v_stake, 'weekly', 4, '15:00'::time,
                                 '台麻', '無花', '一將', 4, null);
  insert into _v values (1, '① 建範本回傳', v_r::text);

  if not coalesce((v_r->>'ok')::boolean, false) then
    insert into _v values (99, '⛔ 建範本就失敗了，後續全部略過', v_r::text);
    return;
  end if;
  v_id := (v_r->>'recurring_id')::uuid;

  select count(*) into v_inst from match_queues where recurring_id = v_id and status = 'waiting';
  insert into _v values (2, '② 建完立刻生成了幾筆實例（應 ≥ 1）', v_inst::text);

  v_lst := pos_list_recurring_tx(v_org, v_store);
  insert into _v values (3, '③ 範本清單裡找得到它嗎',
    coalesce((select string_agg((e->>'frequency') || ' ' || (e->>'start_time'), ',')
                from jsonb_array_elements(v_lst) e
               where e->>'id' = v_id::text), '❌ 清單裡沒有'));

  v_off := pos_set_recurring_enabled_tx(v_org, v_id, false);
  insert into _v values (4, '④ 停用回傳（closed 應等於 ②）', v_off::text);

  select count(*) into v_after from match_queues where recurring_id = v_id and status = 'waiting';
  insert into _v values (5, '⑤ 停用後還剩幾筆等待中（應為 0）', v_after::text);

  insert into _v values (6, '⑥ 重複建同一個範本（應回 duplicate）',
    pos_create_recurring_tx(v_org, v_store, v_stake, 'daily', null, '21:00'::time)::text);
  insert into _v values (7, '⑦ 每週卻沒給星期（應回 weekday_required）',
    pos_create_recurring_tx(v_org, v_store, v_stake, 'weekly', null, '09:00'::time)::text);
  insert into _v values (8, '⑧ 亂給頻率（應回 bad_frequency）',
    pos_create_recurring_tx(v_org, v_store, v_stake, 'monthly', 1, '09:00'::time)::text);
  insert into _v values (9, '⑨ daily 範本的 weekday 應為 null',
    coalesce((select string_agg(coalesce(weekday::text, 'null'), ',')
                from recurring_tables where frequency = 'daily'), '（沒有 daily 範本）'));

  delete from match_queues where recurring_id = v_id;
  get diagnostics v_del_q = row_count;
  delete from recurring_tables where id = v_id;
  get diagnostics v_del_r = row_count;
  insert into _v values (10, '⑩ 清掉測試範本',
    '刪實例 ' || v_del_q || ' 筆、範本 ' || v_del_r || ' 筆');
end $do$;

select 項目, 結果 from _v order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
-- ② 應該 ≥ 1：週四 15:00 在未來 7 天內一定會命中一次。
--    若為 0 → generate_recurring_instances_tx 沒把新範本算進去，要看它的 where。
-- ④ 的 closed 應等於 ②，kept_with_players 應為 0（測試範本沒人報名）。
-- ⑤ 必須是 0：停用卻沒關掉實例的話，客人畫面上還看得到而店員以為停了。
-- ⑨ 應為 null：daily 範本存星期幾會讓人以為「每天的局只在週日」。
-- ⑩ 之後資料庫回到執行前的狀態，只多了 lead_hours 欄位與 weekday 可為 null。
