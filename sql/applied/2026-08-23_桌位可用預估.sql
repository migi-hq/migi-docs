-- 【這是什麼】桌位可用預估：算「某個時間點預估有幾張空桌」與「最早幾點會有桌」。
-- 【何時讀】要在 POS 開桌表單做防呆之前。
--
-- ═══ 前提（2026-08-23 拍板）═══
--
-- 包桌與配桌**預設都佔用 5 小時**。
-- 有了這個前提，「兩小時後有沒有桌」就從「猜不到」變成「算得出來」。
--
-- ⚠ 我先前說過「系統預測不了兩小時後有沒有桌」—— 那句話在沒有這個前提時是對的，
--   有了之後就不成立了。這支就是照著新前提做的。
--
-- ⚠ 不需要加欄位：table_sessions.planned_minutes 已經存在
--   （包桌 120 / 300 / 1440），配桌是 null。
--   規則是 coalesce(planned_minutes, 300) —— **包桌用它實際買的時數**
--   （買 24 小時的桌不該被當成 5 小時放進可用清單），配桌用 5 小時預設。
--
-- 🔴 **預約包桌上線時，這支一定要一起改。**
--   現在只算「正在用的桌」（table_sessions status='open'）。
--   預約是**還沒開始的佔用**，不在那張表裡 ——
--   預約一上線，這支就會高估可用桌數，等於承諾一張已經被訂走的桌。
--   而且不會報錯，只會在客人到店時才發現。
--
--   ⚠ 2026-08-23 現況：App 的「預約包桌」（buddies.jsx TeamBookingSheet）
--     按下去只把 {門市,日期,時間} 傳給一個成功彈窗，**沒有任何後端呼叫**；
--     POS 的「預約」頁是 Placeholder；資料庫沒有任何預約相關的表或 RPC。
--     所以現在不會漏算 —— 因為那個功能根本不存在。
--     ⚠ 但客人看得到「預約成功」，這件事本身要另外處理。
--
-- ⚠ **這是預估不是保證。** 麻將一將打多久本來就不固定，
--   而 planned_minutes 是「開桌時說的」不是「實際會打的」。
--   所以畫面上一律寫「預估」，而且**不擋店員**，只給資訊。
--   擋掉的話，店員遇到「我知道那桌快打完了」就只能繞過系統。

-- ============================================================
-- 一、預估函式
-- ============================================================
drop function if exists pos_table_forecast_tx(uuid, uuid, timestamptz);

create function pos_table_forecast_tx(p_org uuid, p_store uuid, p_at timestamptz default null)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with t as (
    select tb.id, tb.label, tb.auto_assign, tb.sort_order
      from tables tb
     where tb.org_id = p_org and tb.store_id = p_store
       and coalesce(tb.is_active, true) = true and tb.deleted_at is null
  ),
  busy as (
    -- 使用中的桌 + 預估結束時間。
    -- 開打時間優先用 activated_at（真正開打），沒有才退回 started_at（開桌）
    select t.id, t.label, s.mode,
           coalesce(s.activated_at, s.started_at)
             + make_interval(mins => coalesce(s.planned_minutes, 300)) as ends_at
      from t
      join table_sessions s on s.table_id = t.id
     where s.status = 'open' and s.deleted_at is null
  ),
  at_time as (select coalesce(p_at, now()) as v)
  select jsonb_build_object(
    'at',          (select v from at_time),
    'total',       (select count(*) from t),
    'auto',        (select count(*) from t where auto_assign),
    'in_use_now',  (select count(*) from busy),
    -- 在指定時間點預估空著的：沒被佔用的 + 預估已經結束的
    'free_at',     (select count(*) from t
                     where not exists (select 1 from busy b
                                        where b.id = t.id and b.ends_at > (select v from at_time))),
    -- 最早會釋出的那張（現在全滿時，這是店員唯一想知道的數字）
    'next_free_at', (select min(ends_at) from busy),
    'next_free_table', (select label from busy order by ends_at limit 1),
    -- 每張使用中的桌預估幾點結束，讓店員自己判斷（他知道哪桌快打完了）
    'detail', coalesce((select jsonb_agg(jsonb_build_object(
                          'label', b.label, 'mode', b.mode, 'ends_at', b.ends_at)
                          order by b.ends_at)
                        from busy b), '[]'::jsonb)
  )
$$;

comment on function pos_table_forecast_tx(uuid, uuid, timestamptz) is
  '桌位可用預估。佔用時數 = coalesce(planned_minutes, 300)，配桌預設 5 小時。'
  '⚠ 是預估不是保證 —— planned_minutes 是開桌時說的，不是實際會打的。畫面上要寫「預估」。'
  '🔴 只算 table_sessions status=open。**預約包桌上線時一定要把預約也算進來**，'
  '否則會高估可用桌數，等於承諾一張已經被訂走的桌。';

grant execute on function pos_table_forecast_tx(uuid, uuid, timestamptz) to anon, authenticated;

-- ============================================================
-- 二、自動帶桌失敗時，一併告訴店員最早幾點有桌
-- ============================================================
-- 原本 no_free_table 只回一個代碼，店員只知道「配不出桌」，
-- 不知道「還要等多久」—— 而那正是他要拿去跟客人講的那句話。
create or replace function _try_auto_seat_tx(p_org uuid, p_queue uuid, p_staff uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_store uuid; v_play timestamptz; v_tbl uuid; v_fc jsonb;
begin
  select store_id, play_at into v_store, v_play
    from match_queues where id = p_queue and org_id = p_org;
  if v_store is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  -- ★ 只在接近開打時才佔桌。湊滿 ≠ 客人到場，提早佔桌等於讓那張桌空著不能賣。
  if v_play > now() + interval '30 minutes' then
    return jsonb_build_object('ok', false, 'reason', 'too_early', 'play_at', v_play);
  end if;

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
    -- 帶不出桌時把預估一起回去，店員才有話可以跟客人講
    v_fc := pos_table_forecast_tx(p_org, v_store, null);
    return jsonb_build_object('ok', false, 'reason', 'no_free_table',
      'next_free_at', v_fc->'next_free_at',
      'next_free_table', v_fc->'next_free_table');
  end if;

  return pos_seat_queue_tx(p_org, p_queue, v_tbl, p_staff);
end $$;

-- ============================================================
-- 三、驗證（單一 SELECT）
-- ============================================================
select 項目, 結果
from (
  select 1 as ord, '① 現在的桌況預估（高雄自由店）' as 項目,
    pos_table_forecast_tx('11111111-1111-1111-1111-111111111111'::uuid,
                          '22222222-2222-2222-2222-222222222222'::uuid, null)::text as 結果

  union all select 2, '② 兩小時後預估有幾張空桌',
    (pos_table_forecast_tx('11111111-1111-1111-1111-111111111111'::uuid,
                           '22222222-2222-2222-2222-222222222222'::uuid,
                           now() + interval '2 hours')->>'free_at')

  union all select 3, '③ 使用中的桌與預估結束時間',
    coalesce((select string_agg(
                (e->>'label') || '　' || coalesce(e->>'mode','?') || '　預估 ' ||
                to_char((e->>'ends_at')::timestamptz at time zone 'Asia/Taipei', 'MM/DD HH24:MI') || ' 結束',
                chr(10))
                from jsonb_array_elements(
                       pos_table_forecast_tx('11111111-1111-1111-1111-111111111111'::uuid,
                                             '22222222-2222-2222-2222-222222222222'::uuid, null)->'detail') e),
             '（目前沒有使用中的桌）')

  union all select 4, '④ 前鎮店（4 張桌）的預估',
    pos_table_forecast_tx('11111111-1111-1111-1111-111111111111'::uuid,
                          '931cd0ee-b6bd-4fc5-9f25-16d618d6994a'::uuid, null)::text

  union all select 5, '⑤ _try_auto_seat_tx 是否已帶回預估（應含 next_free_at）',
    (select case when prosrc like '%next_free_at%' then '✅ 是' else '❌ 否' end
       from pg_proc where pronamespace='public'::regnamespace
        and proname='_try_auto_seat_tx' limit 1)

  union all select 9, '現在時間（台北）',
    (now() at time zone 'Asia/Taipei')::text
) x
order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
-- ① total 應為 14、in_use_now 是目前使用中的張數。
--    全空的話 free_at = total、next_free_at = null（沒有東西要等）。
-- ② 兩小時後的預估。若 ① 全滿而 ② > 0，代表那段時間會有桌釋出 —— 那正是要防呆的情境。
-- ③ 每張使用中的桌預估幾點結束。⚠ 這是**給店員判斷用的**，不是拿來擋他的：
--    他知道哪一桌快打完了，系統不知道。
--
-- ── 接下來要在 POS 做的防呆（給資訊，不擋）───────────────────
-- 1. 開桌表單選了開打時間之後，底下顯示：
--      「開打時預估有 3 張空桌」            free_at > 0
--      「⚠ 開打時預估沒有空桌，最早 20:30 由 A3 釋出」  free_at = 0
--    ⚠ 不擋按鈕。「現在沒桌」不是不能開房的理由 —— 那正是提前開房的用途。
-- 2. 配桌卡在 no_free_table 時顯示「已滿 · 等桌（預估 20:30 A3 釋出）」
-- 3. 開桌表單頂部常駐「目前 14 張 · 使用中 14 · 空 0」
--
-- ⚠ 一律寫「預估」。planned_minutes 是開桌時說的，不是實際會打的 ——
--   寫成肯定句的話，店員照著跟客人保證，然後那桌多打了一小時。
