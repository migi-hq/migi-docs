-- ============================================================
-- table_sessions 補上 game_type（台麻／美麻）與 flower（有花／無花）
-- 產生日期：2026-08-15
--
-- 【問題】
--   開桌設定頁讓店員選了遊戲規則與花牌（OpenSetupPage.jsx:20-21），
--   但 open_session_tx 沒有對應參數，選完的值只停在前端記憶體裡，
--   靠 onDone 的 ctx 往下傳。一旦離開頁面就消失 ——
--   從桌況重新進入該桌時，桌工作區與座位頁都拿不到這兩項。
--
--   這也是 2026-08-14 合併文件時發現的落差：舊文件寫 table_sessions
--   有 game_type / flower 兩欄，實際盤點沒有。文件記的是「應該有」，
--   不是「實際有」。
--
-- 【值域】
--   比照 match_queues 既有的約束，讓配桌房與計費桌用同一套詞彙，
--   日後 matched_session_id 銜接時不必轉換：
--     game_type ∈ 台麻 / 美麻
--     flower    ∈ 無花 / 有花
--   兩欄皆可為 null（既有場次沒有這項資料，不能硬填預設值 ——
--   那會把「不知道」偽裝成「台麻無花」）。
--
-- 【硬規則 2】
--   open_session_tx 要加參數 → 簽名改變 → 必須先 DROP FUNCTION，
--   否則新舊版並存，而 PostgREST 依具名參數解析：
--   前端若還傳舊的 8 個參數就會打到舊版，開桌成功但牌規永遠是 null，
--   且不報錯。這種靜默不一致要很久才會發現。
--
--   get_session_tx 簽名不變，CREATE OR REPLACE 即可。
--
-- 【部署順序】
--   1. 先跑這份 SQL
--   2. 再推前端（OpenSetupPage 傳參數、enterTable 從 session 帶回）
--   順序反了的話，前端送出後端不認得的參數，PostgREST 會回
--   「function not found」，開桌整條掛掉。
-- ============================================================


-- ---------- ① 欄位 ----------
alter table table_sessions
  add column if not exists game_type text,
  add column if not exists flower    text;

alter table table_sessions
  drop constraint if exists table_sessions_game_type_chk;
alter table table_sessions
  add constraint table_sessions_game_type_chk
  check (game_type is null or game_type in ('台麻', '美麻'));

alter table table_sessions
  drop constraint if exists table_sessions_flower_chk;
alter table table_sessions
  add constraint table_sessions_flower_chk
  check (flower is null or flower in ('無花', '有花'));

comment on column table_sessions.game_type is '台麻／美麻。既有場次為 null（開桌時未記錄），值域比照 match_queues';
comment on column table_sessions.flower    is '無花／有花。既有場次為 null（開桌時未記錄），值域比照 match_queues';


-- ---------- ② open_session_tx：加兩個參數 ----------
-- 簽名改變，先 DROP（硬規則 2）
DROP FUNCTION IF EXISTS public.open_session_tx(uuid, text, uuid, integer, integer, uuid, text, text);

CREATE OR REPLACE FUNCTION public.open_session_tx(
  p_table_id uuid,
  p_mode text,
  p_stake_level_id uuid DEFAULT NULL::uuid,
  p_planned_rounds integer DEFAULT NULL::integer,
  p_planned_minutes integer DEFAULT NULL::integer,
  p_staff_id uuid DEFAULT NULL::uuid,
  p_open_method text DEFAULT 'manual'::text,
  p_idempotency_key text DEFAULT NULL::text,
  p_game_type text DEFAULT NULL::text,   -- 新增
  p_flower text DEFAULT NULL::text)      -- 新增
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_t record; v_id uuid; v_busy uuid;
begin
  if p_mode not in ('matched','private') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_mode',
      'message', '模式須為 matched（配桌）或 private（包桌）');
  end if;
  if p_mode = 'matched' and coalesce(p_planned_rounds, 0) not in (2, 3) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_rounds',
      'message', '配桌需指定 2 或 3 將');
  end if;
  if p_mode = 'private' and coalesce(p_planned_minutes, 0) not in (120, 300, 1440) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_minutes',
      'message', '包桌需選擇 2 小時／5 小時／24 小時');
  end if;
  if p_open_method not in ('auto','manual') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_open_method');
  end if;

  -- 新增：牌規驗證。允許 null（呼叫端沒傳就是沒記錄），
  -- 但傳了就必須是合法值 —— 與其讓 CHECK 約束拋 23514，
  -- 不如照本函式既有風格回友善訊息
  if p_game_type is not null and p_game_type not in ('台麻','美麻') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_game_type',
      'message', '遊戲規則須為 台麻 或 美麻');
  end if;
  if p_flower is not null and p_flower not in ('無花','有花') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_flower',
      'message', '花牌須為 無花 或 有花');
  end if;

  if p_idempotency_key is not null then
    select id into v_id from table_sessions where idempotency_key = p_idempotency_key;
    if v_id is not null then
      return jsonb_build_object('ok', true, 'session_id', v_id, 'duplicate', true);
    end if;
  end if;

  select t.id, t.org_id, t.store_id into v_t
    from tables t
   where t.id = p_table_id and t.deleted_at is null and t.is_active;
  if v_t.id is null then
    return jsonb_build_object('ok', false, 'reason', 'table_unavailable',
      'message', '桌位不存在或已停用');
  end if;

  select id into v_busy from table_sessions
   where table_id = p_table_id and status = 'open' and deleted_at is null;
  if v_busy is not null then
    return jsonb_build_object('ok', false, 'reason', 'table_busy',
      'session_id', v_busy, 'message', '此桌已有進行中的牌局');
  end if;

  insert into table_sessions(
    org_id, store_id, table_id, mode, stake_level_id, status,
    planned_rounds, planned_minutes, open_method,
    opened_by_staff_id, promoted_by_staff_id, started_at, idempotency_key,
    game_type, flower)                                      -- 新增
  values (
    v_t.org_id, v_t.store_id, p_table_id, p_mode, p_stake_level_id, 'open',
    p_planned_rounds, p_planned_minutes, p_open_method,
    p_staff_id, p_staff_id, now(), p_idempotency_key,
    p_game_type, p_flower)                                  -- 新增
  returning id into v_id;

  return jsonb_build_object('ok', true, 'session_id', v_id,
    'mode', p_mode, 'store_id', v_t.store_id, 'org_id', v_t.org_id);
end $function$;


-- ---------- ③ get_session_tx：回傳新欄位 ----------
-- 簽名不變，不需要 DROP。其餘內容照抄線上版本，只多兩個鍵。
CREATE OR REPLACE FUNCTION public.get_session_tx(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return (
    select jsonb_build_object(
      'id', s.id, 'status', s.status, 'mode', s.mode,
      'is_playing', (s.activated_at is not null),
      'table_id', s.table_id, 'table_label', t.label, 'area', t.area,
      'planned_rounds', s.planned_rounds, 'planned_minutes', s.planned_minutes,
      'game_type', s.game_type,                       -- 新增
      'flower', s.flower,                             -- 新增
      'started_at', s.started_at, 'activated_at', s.activated_at,
      'stake_level_id', s.stake_level_id,
      'stake_label', (select label from stake_levels where id = s.stake_level_id),
      'fee_total', (select coalesce(sum(charged_points),0) from session_players
                     where session_id = s.id and left_at is null),
      'players', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'player_id', sp.id, 'member_id', m.id, 'nickname', m.display_name,
          'rank', m.rank, 'avatar_source', m.avatar_source,
          'avatar_photo_path', m.avatar_photo_path,
          'join_type', sp.join_type, 'seat', sp.seat, 'status', sp.status,
          'charged', sp.charged_points, 'joined_at', sp.joined_at,
          'order_id', sp.order_id,
          'paid_by', sp.paid_by,
          'paid_by_name', (select display_name from members where id = sp.paid_by)
        ) order by sp.joined_at), '[]'::jsonb)
        from session_players sp join members m on m.id = sp.member_id
        where sp.session_id = s.id and sp.left_at is null)
    )
    from table_sessions s
    left join tables t on t.id = s.table_id
    where s.id = p_session_id
  );
end $function$;


-- ---------- ④ 驗證（單一 SELECT）----------
select '欄位' as 類別,
       column_name as 項目,
       data_type as 結果
from information_schema.columns
where table_schema = 'public' and table_name = 'table_sessions'
  and column_name in ('game_type', 'flower')
union all
select '約束', conname, pg_get_constraintdef(oid)
from pg_constraint
where conrelid = 'public.table_sessions'::regclass
  and conname in ('table_sessions_game_type_chk', 'table_sessions_flower_chk')
union all
select 'open_session_tx 版本數',
       count(*)::text,
       string_agg(pg_get_function_identity_arguments(p.oid), ' ||| ')
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'open_session_tx'
union all
select 'get_session_tx 含新欄位',
       case when prosrc like '%game_type%' then '✓' else '✗' end,
       ''
from pg_proc where proname = 'get_session_tx'
order by 1, 2;

-- 跑完期待：
--   欄位 2 列（text）、約束 2 列、
--   open_session_tx 版本數 = 1（若是 2 代表 DROP 沒生效，新舊並存）、
--   get_session_tx 含新欄位 = ✓
