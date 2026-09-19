-- 【成就系統・執行狀態待確認】事件觸發自動解鎖成就的 RPC。
-- ============================================================
-- MIGI 成就系統 · 事件自動解鎖(依 trigger 規則,免逐成就手寫邏輯)
-- 接在 成就系統_achievements_schema_RPC.sql + 總部專屬權限 之後部署
--
-- 概念:
--   每個成就的 trigger 欄存 {"event":"<事件名>","count":N}。
--   系統發生事件時呼叫 fire_event_tx,它自動找出所有「該事件」對應的成就,
--   依結構(struct)呼叫既有的 ach_unlock_tx / ach_progress_tx / ach_streak_tx。
--   => 新增成就只要在後台填 trigger,不必工程師為每個成就寫一段判斷。
-- ============================================================

alter table achievements add column if not exists trigger jsonb;        -- 防呆:確保欄位存在
alter table achievements add column if not exists requires_code text;   -- 前置依賴(若族群欄位檔尚未跑)

-- 依事件快速找成就
create index if not exists idx_ach_trigger_event
  on achievements ((trigger->>'event'))
  where is_active and deleted_at is null;

-- ---------- 事件派發:一個事件 → 自動解鎖/推進所有對應成就 ----------
create or replace function fire_event_tx(
  p_member     uuid,
  p_event      text,
  p_delta      bigint default 1,       -- 累積型:本次增加多少(預設 1)
  p_period_key text   default null,    -- 連續型:本次的日/週/月鍵
  p_idem       text   default null     -- 來源唯一鍵(防同一事件重複計)
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r record; v_res jsonb := '[]'::jsonb; v_one jsonb; v_idem text;
begin
  for r in
    select code, struct, requires_code from achievements
    where deleted_at is null and is_active
      and (trigger->>'event') = p_event
      and (valid_from is null or now() >= valid_from)
      and (valid_to   is null or now() <  valid_to)
  loop
    -- 前置依賴:要先解鎖 requires_code,否則跳過(等前置解了再觸發)
    if r.requires_code is not null then
      if not exists (
        select 1 from member_achievements ma
        join achievements a2 on a2.id = ma.achievement_id
        where ma.member_id = p_member and a2.code = r.requires_code and ma.status = 'unlocked'
      ) then
        continue;
      end if;
    end if;

    -- 每個成就各自的冪等鍵:同一來源事件不會把同一成就重複計
    v_idem := coalesce(p_idem, 'evt') || ':' || p_event || ':' || r.code;

    if r.struct in ('specific','prestige') then
      v_one := ach_unlock_tx(p_member, r.code, v_idem);                 -- 一次達成即解鎖
    elsif r.struct = 'cumulative' then
      v_one := ach_progress_tx(p_member, r.code, p_delta, v_idem);      -- 累積推進(分級在內處理)
    elsif r.struct = 'streak' then
      if p_period_key is null then
        raise exception '連續型成就 % 需提供 p_period_key(日/週/月鍵)', r.code;
      end if;
      v_one := ach_streak_tx(p_member, r.code, p_period_key, true, v_idem);
    else
      continue;
    end if;

    v_res := v_res || jsonb_build_array(
      jsonb_build_object('code', r.code, 'struct', r.struct, 'result', v_one)
    );
  end loop;

  return jsonb_build_object('event', p_event, 'member', p_member, 'matched', v_res);
end $$;

-- 用法(後端在對應動作發生時呼叫):
--   首次到店完成      → select fire_event_tx(member, 'visit_completed', 1, null, visit_id::text);
--   點一筆餐飲(累積)→ select fire_event_tx(member, 'fnb_order',       1, null, order_id::text);
--   每日到店(連續)  → select fire_event_tx(member, 'daily_visit',    1, to_char(now(),'YYYY-MM-DD'), visit_id::text);
--   做出咪幾          → select fire_event_tx(member, 'migi_win',       1, null, hand_id::text);
-- 隱藏成就同樣靠 struct(多為 specific)+ is_hidden,觸發邏輯一致。
