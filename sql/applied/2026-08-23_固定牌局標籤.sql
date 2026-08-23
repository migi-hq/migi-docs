-- ════════════════════════════════════════════════════════════════════
-- 固定牌局也能掛標籤（接續 2026-08-23_配桌標籤主檔.sql）
-- 2026-08-23
--
-- ═══ 為什麼四件事必須一起做 ═══
--
-- 🔴 標籤要**從範本帶到每一場實例**。只加欄位而產生器沒帶過去，結果是
--    「店員設了標籤、範本裡確實存著、但客人看到的每一場都沒有」——
--    資料對、畫面空、完全不報錯。硬規則 4 那個形狀。
--
-- 🔴 `pos_list_recurring_tx` 不回傳 tags 的話，店員**設完看不到自己設了什麼**，
--    只能再設一次。設定類的功能沒有回顯，等於沒做。
--
-- 🔴 第五件（`pos_set_recurring_tags_tx`）不做的話，**現有 3 個範本永遠掛不上標籤**
--    —— 目前「固定牌局設定」那頁只有啟用／停用，沒有編輯。
--    店員唯一的辦法是停用舊的、重建一個，那會讓已生成的場次全部失效。
--
-- ═══ 一個刻意的不一致：tags 不是快照 ═══
--
-- 產生器寫 `open_at` 時的註解寫著「快照，之後改範本不影響它」。
-- **tags 刻意不照這個規則**：改了範本的標籤，未開打的實例會一起更新。
--   · `open_at` 是**對客人的承諾**（幾點開賣）—— 事後改動會移動別人已經看到的東西
--   · `tags` 是**描述**—— 店員發現寫錯了，他要的是「全部都改掉」，
--     包含已經看得到的那幾場。只改未來場次等於留著一個他知道是錯的畫面。
-- 兩者性質不同，所以規則不同；這是決定不是疏漏。
--
-- ═══ 已查證的現況（2026-08-23）═══
--   · recurring_tables 沒有 tags 欄位（14 欄，已列出）
--   · 3 個範本全部啟用中；5 筆已生成未開打的實例
--   · queue_tags 主檔與 list_queue_tags_tx 已上線（前一支）
-- ════════════════════════════════════════════════════════════════════

begin;

-- ─────────────────────────────────────────────────────────────
-- 一、recurring_tables.tags
--     形狀比照 match_queues.tags：jsonb NOT NULL default '[]'
--     ⚠ 不要允許 null。「沒有標籤」只該有一種寫法，
--       否則每個讀取端都要多寫一次 coalesce，而漏掉的那個會拋錯。
-- ─────────────────────────────────────────────────────────────
alter table public.recurring_tables
  add column if not exists tags jsonb;
update public.recurring_tables set tags = '[]'::jsonb where tags is null;
alter table public.recurring_tables alter column tags set default '[]'::jsonb;
alter table public.recurring_tables alter column tags set not null;

comment on column public.recurring_tables.tags is
  '這個固定牌局範本的標籤（queue_tags.code 陣列）。
   產生實例時會複製到 match_queues.tags。
   ⚠ 與 open_at 不同，tags 不是快照 —— 改範本會一併更新未開打的實例
     （見 pos_set_recurring_tags_tx）。';


-- ─────────────────────────────────────────────────────────────
-- 二、pos_create_recurring_tx 加 p_tags
--     ⚠ 簽名改了 → 硬規則 2，先 DROP。
--       不 DROP 的話 POS 送 12 個參數仍可能打到舊的 11 參數版，
--       標籤靜靜消失而且不報錯。
-- ─────────────────────────────────────────────────────────────
drop function if exists public.pos_create_recurring_tx(uuid, uuid, uuid, text, integer, time, text, text, text, integer, integer);
drop function if exists public.pos_create_recurring_tx(uuid, uuid, uuid, text, integer, time, text, text, text, integer, integer, jsonb);

create or replace function public.pos_create_recurring_tx(
  p_org_id     uuid,
  p_store      uuid,
  p_stake      uuid,
  p_frequency  text,
  p_weekday    integer,
  p_start_time time,
  p_game_type  text    default '台麻',
  p_flower     text    default '無花',
  p_rounds     text    default '一將',
  p_seats      integer default 4,
  p_lead_hours integer default null,
  p_tags       jsonb   default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_id uuid; v_lead int; v_gen int;
  v_tags jsonb; v_bad text;
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

  -- ── 標籤驗證（與 pos_create_queue_tx 同一套）─────────────
  -- ⚠ 先判型別再展開：jsonb 欄位也可能收到物件或字串，
  --   那時 jsonb_array_elements_text 是直接拋錯而不是回空集合。
  v_tags := coalesce(p_tags, '[]'::jsonb);
  if jsonb_typeof(v_tags) <> 'array' then
    return jsonb_build_object('ok', false, 'reason', 'tags_not_array',
      'message', '標籤要用陣列格式');
  end if;
  select string_agg(e.t, '、') into v_bad
    from jsonb_array_elements_text(v_tags) as e(t)
   where not exists (select 1 from queue_tags g where g.code = e.t and g.is_active);
  if v_bad is not null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_tag',
      'message', '找不到這些標籤：' || v_bad);
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
    game_type, flower, rounds, seats, enabled, lead_hours, tags)
  values (
    p_org_id, p_store, p_stake, p_frequency,
    case when p_frequency = 'daily' then null else p_weekday end,   -- daily 不存星期
    p_start_time,
    p_game_type, p_flower, p_rounds, coalesce(p_seats, 4), true, v_lead, v_tags)
  returning id into v_id;

  -- 立刻生成，不讓店員等下一輪 cron（最多 6 小時）
  v_gen := generate_recurring_instances_tx(p_org_id, 7);

  return jsonb_build_object('ok', true, 'recurring_id', v_id, 'generated', v_gen, 'tags', v_tags);
end $function$;


-- ─────────────────────────────────────────────────────────────
-- 三、generate_recurring_instances_tx 把 tags 帶進實例
--     🔴 這是整件事的關鍵。少了它，範本存了標籤而客人每一場都看不到。
--     ⚠ 撈全文重建而不是堆 DO 區塊（CLAUDE.md：要改三處以上就撈全文）——
--       這裡只改兩處（欄位列與值列），但函式本體不長，重建比較看得出全貌。
--       原有註解全部保留，一個字都沒動。
-- ─────────────────────────────────────────────────────────────
create or replace function public.generate_recurring_instances_tx(
  p_org_id uuid, p_days_ahead integer default 7)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r          record;
  v_local_d  timestamp;
  v_play_at  timestamptz;
  v_created  integer := 0;
  v_now      timestamptz := now();
  v_match    boolean;
  v_keep     integer;   -- 這個範本要保持幾筆未來實例
  v_found    integer;   -- 這一輪已存在（或剛建立）的未來實例數
begin
  for r in select * from recurring_tables where org_id = p_org_id and enabled = true loop

    -- daily 保持未來 2 筆：一筆現在開放中，一筆等它過期後接班。
    -- 只保 1 筆不夠 —— 跑排程當下那筆還沒過期，就不會生成下一筆，
    -- 等它過期到下次 cron 之間就是空窗（原本每天 21:00–02:00 就是這樣來的）。
    -- weekly 不設上限，照 p_days_ahead 的天數掃完（一週內最多命中一次）。
    v_keep  := case when r.frequency = 'daily' then 2 else p_days_ahead + 1 end;
    v_found := 0;

    for i in 0..(p_days_ahead) loop
      exit when v_found >= v_keep;

      -- 以台北時間切日再轉回 timestamptz —— 跨日界線要用當地時間判斷
      v_local_d := date_trunc('day', (v_now at time zone 'Asia/Taipei')) + (i || ' days')::interval;
      v_play_at := (v_local_d + r.start_time) at time zone 'Asia/Taipei';
      v_match   := case when r.frequency = 'daily' then true
                        else extract(dow from v_local_d)::int = r.weekday end;

      -- ⚠ 只判斷「還沒開打」，不再判斷距今多久。
      --   「距今多久」是相對 now 的，而 now 取決於 cron 幾點跑 —— 那正是空窗的來源。
      --   要提前多久才給客人看到，改由 open_at 決定（見下）。
      if v_match and v_play_at > v_now then
        if not exists (select 1 from match_queues where recurring_id = r.id and play_at = v_play_at) then
          insert into match_queues(org_id, store_id, stake_level_id, game_type, flower, rounds, seats,
            opened_by, play_at, open_at, expires_at, source, recurring_id, recurring_freq, status, tags)
          values (r.org_id, r.store_id, r.stake_level_id, r.game_type, r.flower, r.rounds, r.seats,
            null, v_play_at,
            v_play_at - make_interval(hours => r.lead_hours),  -- 開賣時間（快照，之後改範本不影響它）
            v_play_at,                                          -- 開打即不可再加入
            'recurring', r.id, r.frequency, 'waiting',
            -- ⚠ 標籤從範本複製過來。與 open_at 不同，它不是快照 ——
            --   改範本會一併更新未開打的實例（pos_set_recurring_tags_tx）。
            coalesce(r.tags, '[]'::jsonb));
          v_created := v_created + 1;
        end if;
        -- 本來就有或剛建立，都算「已經有一筆」
        v_found := v_found + 1;
      end if;
    end loop;
  end loop;

  return v_created;
end $function$;


-- ─────────────────────────────────────────────────────────────
-- 四、pos_list_recurring_tx 回傳 tags
--     ⚠ 沒有回顯的設定等於沒做：店員設完看不到自己設了什麼，只能再設一次。
-- ─────────────────────────────────────────────────────────────
create or replace function public.pos_list_recurring_tx(p_org_id uuid, p_store uuid)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
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
    'tags', coalesce(r.tags, '[]'::jsonb),
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
$function$;


-- ─────────────────────────────────────────────────────────────
-- 五、pos_set_recurring_tags_tx：改既有範本的標籤
--     🔴 沒有這支的話，現有 3 個範本永遠掛不上標籤 ——
--       「固定牌局設定」那頁目前只有啟用／停用，沒有編輯。
--       店員唯一的辦法是停用舊的重建一個，那會讓已生成的場次全部失效。
--     ⚠ 會一併更新**未開打**的實例。已開打或已成桌的不動 ——
--       那些是歷史，改描述會讓紀錄與當時客人看到的不一致。
-- ─────────────────────────────────────────────────────────────
drop function if exists public.pos_set_recurring_tags_tx(uuid, uuid, jsonb);

create or replace function public.pos_set_recurring_tags_tx(
  p_org_id uuid,
  p_id     uuid,
  p_tags   jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_tags jsonb; v_bad text; v_hit int; v_synced int;
begin
  if p_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '沒有指定要改哪一個');
  end if;

  v_tags := coalesce(p_tags, '[]'::jsonb);
  if jsonb_typeof(v_tags) <> 'array' then
    return jsonb_build_object('ok', false, 'reason', 'tags_not_array',
      'message', '標籤要用陣列格式');
  end if;
  select string_agg(e.t, '、') into v_bad
    from jsonb_array_elements_text(v_tags) as e(t)
   where not exists (select 1 from queue_tags g where g.code = e.t and g.is_active);
  if v_bad is not null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_tag',
      'message', '找不到這些標籤：' || v_bad);
  end if;

  update recurring_tables
     set tags = v_tags
   where id = p_id and org_id = p_org_id;
  get diagnostics v_hit = row_count;

  if v_hit = 0 then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個固定牌局');
  end if;

  -- 同步到未開打的實例。⚠ 只動 waiting 且還沒開打的：
  --   已成桌／已過期的是歷史，改描述會讓紀錄與當時客人看到的不一致。
  update match_queues
     set tags = v_tags
   where recurring_id = p_id
     and status = 'waiting'
     and play_at > now();
  get diagnostics v_synced = row_count;

  return jsonb_build_object('ok', true, 'tags', v_tags, 'synced_instances', v_synced);
end $function$;


-- ─────────────────────────────────────────────────────────────
-- 六、回填：已生成的實例對齊各自範本
--     現在是 no-op（範本剛加欄位，全是 '[]'），但留著這句是為了語意完整 ——
--     跑完這支之後「範本與未開打實例的標籤一致」必須成立。
-- ─────────────────────────────────────────────────────────────
update match_queues q
   set tags = coalesce(r.tags, '[]'::jsonb)
  from recurring_tables r
 where q.recurring_id = r.id
   and q.status = 'waiting'
   and q.play_at > now()
   and q.tags is distinct from coalesce(r.tags, '[]'::jsonb);

commit;


-- ════════════════════════════════════════════════════════════════════
-- 驗證（單一 SELECT）
-- ════════════════════════════════════════════════════════════════════
select 項目, 結果
from (
  select 1 as ord, '① recurring_tables.tags 欄位' as 項目,
    coalesce((select data_type || '　可為 null：' || is_nullable
                     || '　預設：' || coalesce(column_default, '(無)')
                from information_schema.columns
               where table_schema='public' and table_name='recurring_tables' and column_name='tags'),
             '❌ 沒有加成功') as 結果

  union all select 2, '② pos_create_recurring_tx 版本數（應為 1，證明 DROP 生效）',
    (select count(*)::text from pg_proc
      where pronamespace='public'::regnamespace and proname='pos_create_recurring_tx')

  union all select 3, '③ pos_create_recurring_tx 簽名（應含 p_tags jsonb）',
    coalesce((select pg_get_function_identity_arguments(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='pos_create_recurring_tx' limit 1),
             '❌ 不存在')

  union all select 4, '④ 🔴 產生器有沒有把 tags 寫進 match_queues（最關鍵的一項）',
    coalesce((select case when pg_get_functiondef(oid) like '%r.tags%' then '有' else '❌ 沒有 —— 範本會存但客人看不到' end
                from pg_proc
               where pronamespace='public'::regnamespace
                 and proname='generate_recurring_instances_tx' limit 1),
             '❌ 函式不存在')

  union all select 5, '⑤ pos_list_recurring_tx 有沒有回傳 tags',
    coalesce((select case when pg_get_functiondef(oid) like '%''tags''%' then '有' else '❌ 沒有' end
                from pg_proc
               where pronamespace='public'::regnamespace and proname='pos_list_recurring_tx' limit 1),
             '❌ 函式不存在')

  union all select 6, '⑥ pos_set_recurring_tags_tx 存在且為 DEFINER',
    coalesce((select case when prosecdef then '是（DEFINER）' else '❌ INVOKER' end
                from pg_proc
               where pronamespace='public'::regnamespace and proname='pos_set_recurring_tags_tx' limit 1),
             '❌ 不存在')

  union all select 10, '⑩ 範本與未開打實例的標籤是否一致（應為 0 筆不一致）',
    coalesce((select count(*)::text || ' 筆不一致'
                from match_queues q join recurring_tables r on r.id = q.recurring_id
               where q.status='waiting' and q.play_at > now()
                 and q.tags is distinct from coalesce(r.tags, '[]'::jsonb)), '—')

  union all select 11, '⑪ 現有範本與各自的標籤',
    coalesce((select string_agg(
                r.frequency || coalesce('/週' || r.weekday::text, '') || ' ' ||
                to_char(r.start_time, 'HH24:MI') || '　→ ' ||
                case when jsonb_array_length(r.tags) = 0 then '(沒有標籤)' else r.tags::text end,
                chr(10) order by r.frequency, r.start_time)
                from recurring_tables r), '（沒有範本）')

  union all select 20, '⑳ 煙霧測試：改標籤用不存在的範本（應回 not_found）',
    coalesce(pos_set_recurring_tags_tx(
      '00000000-0000-0000-0000-000000000000'::uuid,
      '00000000-0000-0000-0000-000000000000'::uuid,
      '[]'::jsonb)->>'reason', '❌ 沒有回 reason')

  union all select 21, '㉑ 煙霧測試：改標籤帶未知代碼（應回 unknown_tag）',
    coalesce(pos_set_recurring_tags_tx(
      '00000000-0000-0000-0000-000000000000'::uuid,
      '00000000-0000-0000-0000-000000000000'::uuid,
      '["不存在的標籤"]'::jsonb)->>'reason', '❌ 沒有回 reason')
) x
order by ord;

-- ── 怎麼看 ────────────────────────────────────────────────
-- ④ 是這支的重點。它若是 ❌，代表店員設得起來、範本存得下、
--   而客人看到的每一場都沒有標籤 —— 全程不報錯。
-- ⑩ 應為 0：跑完之後「範本與未開打實例一致」必須成立。
-- ㉑ 要先擋標籤才輪到 not_found（驗證排在 update 之前），
--   所以即使範本不存在也該回 unknown_tag。若回 not_found，
--   代表驗證被排到 update 後面 —— 那樣真實呼叫會先寫入才發現錯。
