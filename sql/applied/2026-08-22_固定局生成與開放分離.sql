-- 【這是什麼】把固定局的「生成實例」與「開放報名」分成兩件事，修掉每天 5 小時的空窗。
-- 【何時讀】執行前。盤點見 sql/checks/查固定牌局.sql、查固定局生成與過期.sql、查固定局母範本.sql。
--
-- ═══ 問題 ═══
--
-- generate_recurring_instances_tx 對 daily 範本用的是**相對 now 的時間視窗**：
--     v_play_at > now AND v_play_at <= now + interval '1 day'   -- 「只提前 24 小時生成」
-- 而 cron 每 6 小時跑一次（UTC 00/06/12/18 = 台北 08:00 / 14:00 / 20:00 / 02:00），
-- daily 範本開打時間 21:00。兩件事的相位對不上：
--
--   20:00  cron 跑 → 明天 21:00 距今 25 小時 > 24，不在窗內，不生成
--   21:00  今天的局開打，expires_at = play_at → 立刻 expired
--   21:00–02:00  **daily 固定局完全消失**（每天都會發生）
--   02:00  下一次 cron → 距今 19 小時，進窗，生成
--
-- 2026-08-22 22:49 實測：畫面上一個固定局都沒有。
-- ⚠ 這不是資料壞掉，是每天都會發生的空窗，只是以前沒人在這個時段看。
--
-- ═══ 解法：生成 ≠ 開放 ═══
--
-- 病根是「什麼時候生出來」與「客人什麼時候看得到」被綁成同一件事。
-- 綁在一起的話，能見度就取決於排程幾點跑 —— 而排程頻率是維運細節，
-- 不該決定客人看到什麼。
--
--   · **生成**：改成計數制（daily 永遠保持未來 2 筆）。
--     對排程相位免疫 —— 不管 cron 幾點跑、跑多密，結果都一樣。
--     ⚠ 不用「把視窗調寬成 1 day 6 hours」：那個 6 是綁 cron 頻率的魔術數字，
--       哪天有人把 cron 改成每 8 小時，空窗會無聲無息地回來且不報錯。
--
--   · **開放**：新增 match_queues.open_at（開放報名時間），
--     由範本的 lead_hours 決定（daily 24 小時、weekly 7 天）。
--     list 只回 open_at <= now() 的。
--     這就是售票系統的「開賣時間」—— 票早就印好了，時間到才賣。
--
-- 兩者合起來：明天 21:00 那筆在**今天 20:00 的 cron 就已經建立**（不受相位影響），
-- 但 open_at = 今天 21:00，正好在今天那場過期的同一刻開放。**接縫為零。**
--
-- ⚠ open_at 存在實例上而不是每次讀取時算：
--   實例是快照。之後店員把範本的 lead_hours 從 24 改成 48，
--   已經生出來的實例不該回頭改變開放時間 —— 那跟 order_items 存快照是同一個道理。

-- ============================================================
-- 一、前置檢查
-- ============================================================
do $do$
declare v_missing text;
begin
  select string_agg(need.t || '.' || need.c, '、' order by need.t, need.c) into v_missing
    from (values
      ('match_queues','play_at'), ('match_queues','expires_at'), ('match_queues','status'),
      ('match_queues','source'), ('match_queues','recurring_id'), ('match_queues','recurring_freq'),
      ('recurring_tables','id'), ('recurring_tables','org_id'), ('recurring_tables','enabled'),
      ('recurring_tables','frequency'), ('recurring_tables','weekday'), ('recurring_tables','start_time')
    ) as need(t, c)
   where not exists (select 1 from information_schema.columns
                      where table_schema='public' and table_name=need.t and column_name=need.c);
  if v_missing is not null then
    raise exception '缺欄位，整支中止：%', v_missing;
  end if;
end $do$;

-- ============================================================
-- 二、刪掉重複的生成排程
-- ============================================================
-- 兩個 job 呼叫同一支函式、同樣參數：
--   gen-recurring-instances [0 */6 * * *] → generate_recurring_instances_tx(org, 7)
--   migi_generate_recurring [0 19 * * *]  → generate_recurring_instances_tx(org, 7)
-- 不是備援，是有人加了第二個沒刪第一個。留每 6 小時那個。
do $do$
begin
  if exists (select 1 from cron.job where jobname = 'migi_generate_recurring') then
    perform cron.unschedule('migi_generate_recurring');
    raise notice '已刪除重複排程 migi_generate_recurring';
  else
    raise notice 'migi_generate_recurring 不存在，略過';
  end if;
end $do$;

-- ============================================================
-- 三、新欄位
-- ============================================================
-- 範本：提前幾小時開放報名
alter table recurring_tables add column if not exists lead_hours integer;
update recurring_tables
   set lead_hours = case when frequency = 'daily' then 24 else 24 * 7 end
 where lead_hours is null;
alter table recurring_tables alter column lead_hours set not null;
alter table recurring_tables alter column lead_hours set default 24;

do $do$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid='recurring_tables'::regclass and conname='recurring_lead_hours_chk') then
    -- 上限 720 小時（30 天）：再遠就不是「固定局」而是活動預告了
    alter table recurring_tables
      add constraint recurring_lead_hours_chk check (lead_hours between 1 and 720);
  end if;
end $do$;

comment on column recurring_tables.lead_hours is
  '提前幾小時開放報名。實例會更早被生成（不受排程相位影響），但要到 play_at - lead_hours 才對客人可見。';

-- 實例：開放報名時間
-- ⚠ 可為 null，語意是「立刻開放」—— 與同一支查詢裡 expires_at 的寫法一致
--   （(expires_at is null or expires_at > now())）。POS 即時開的房、
--   會員自己開的房都不需要開賣時間。
alter table match_queues add column if not exists open_at timestamptz;

comment on column match_queues.open_at is
  '開放報名時間。null = 立刻開放。固定局實例會早於此時間就生成，時間到才對客人可見（同售票系統的開賣時間）。';

-- 既有的等待中固定局回填 —— 不回填的話它們的 open_at 是 null（立刻開放），
-- 行為跟現在一樣，不會壞；但補上才對得起 lead_hours 的語意。
update match_queues q
   set open_at = q.play_at - make_interval(hours => r.lead_hours)
  from recurring_tables r
 where q.recurring_id = r.id
   and q.open_at is null
   and q.status = 'waiting';

-- ============================================================
-- 四、生成函式：計數制 + 寫入 open_at
-- ============================================================
-- 簽名沒變，不需要 DROP（硬規則 2 只針對改簽名）。
-- 整支重建而非單點替換 —— 改的是判斷條件的本質。
-- 原版全文已在 2026-08-22 用 pg_get_functiondef 撈出並逐行審過（硬規則 3）。
create or replace function generate_recurring_instances_tx(p_org_id uuid, p_days_ahead integer default 7)
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
            opened_by, play_at, open_at, expires_at, source, recurring_id, recurring_freq, status)
          values (r.org_id, r.store_id, r.stake_level_id, r.game_type, r.flower, r.rounds, r.seats,
            null, v_play_at,
            v_play_at - make_interval(hours => r.lead_hours),  -- 開賣時間（快照，之後改範本不影響它）
            v_play_at,                                          -- 開打即不可再加入
            'recurring', r.id, r.frequency, 'waiting');
          v_created := v_created + 1;
        end if;
        -- 本來就有或剛建立，都算「已經有一筆」
        v_found := v_found + 1;
      end if;
    end loop;
  end loop;

  return v_created;
end $function$;

-- ============================================================
-- 五、兩支列表函式加上「開賣時間到了沒」
-- ============================================================
-- 單點替換 + guard：找不到既有的 expires_at 條件就整支中止，
-- 不會出現「改對一支、另一支沒改」而且不報錯的狀況（2026-08-19 那批的教訓）。
do $do$
declare fn text; v_old text; v_new text; v_done int := 0;
begin
  foreach fn in array array['list_match_queues_tx', 'list_match_queues_by_city_tx'] loop
    select pg_get_functiondef(p.oid) into v_old
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = fn;

    if v_old is null then
      raise exception '% 不存在，整支中止', fn;
    end if;
    if v_old ~ 'open_at' then
      raise notice '% 已經有 open_at 條件，略過', fn;
      continue;
    end if;

    -- 在既有的 expires_at 條件後面補一條；容忍空白與換行差異
    v_new := regexp_replace(
      v_old,
      '(\(\s*q\.expires_at\s+is\s+null\s+or\s+q\.expires_at\s*>\s*now\(\)\s*\))',
      E'\\1\n      and (q.open_at is null or q.open_at <= now())');

    if v_new = v_old then
      raise exception '% 裡找不到 (q.expires_at is null or q.expires_at > now()) 這個條件，整支中止。'
                      '可能是別名不叫 q，或條件寫法不同。實際定義：%', fn, v_old;
    end if;

    execute v_new;
    v_done := v_done + 1;
  end loop;
  raise notice '已為 % 支列表函式加上 open_at 條件', v_done;
end $do$;

-- ============================================================
-- 六、立刻補生成一次（不等下一輪 cron）
-- ============================================================
select generate_recurring_instances_tx('11111111-1111-1111-1111-111111111111'::uuid, 7) as 本次新建筆數;

-- ============================================================
-- 七、驗證（單一 SELECT）
-- ============================================================
select 項目, 結果
from (
  select 1 as ord, '生成排程還剩幾個（應為 1）' as 項目,
    (select count(*)::text from cron.job where command ilike '%generate_recurring_instances_tx%') as 結果

  union all select 2, '留下來的是哪一個',
    coalesce((select jobname || ' [' || schedule || ']' from cron.job
               where command ilike '%generate_recurring_instances_tx%' limit 1), '❌ 一個都沒有')

  union all select 3, '生成函式已改計數制（應含 v_keep）',
    (select case when prosrc like '%v_keep%' then '✅ 是' else '❌ 否' end from pg_proc
      where pronamespace='public'::regnamespace and proname='generate_recurring_instances_tx' limit 1)

  union all select 4, '生成函式殘留的相對視窗判斷（應為 0）',
    (select count(*)::text from pg_proc
      where pronamespace='public'::regnamespace and proname='generate_recurring_instances_tx'
        and prosrc ~ 'v_now \+ v_window')

  union all select 5, '有 open_at 條件的列表函式數（應為 2）',
    (select count(*)::text from pg_proc
      where pronamespace='public'::regnamespace
        and proname in ('list_match_queues_tx','list_match_queues_by_city_tx')
        and prosrc like '%open_at%')

  union all select 10, 'lead_hours 設定',
    coalesce((select string_agg(frequency || ' ' || start_time::text || ' → 提前 ' || lead_hours || ' 小時', '   '
                                order by frequency)
                from recurring_tables where enabled = true), '（沒有啟用中的範本）')

  union all select 11, '等待中的固定局：開打 / 開賣（台北）',
    coalesce((select string_agg(
                recurring_freq || '　開打 ' || (play_at at time zone 'Asia/Taipei')::text
                || '　開賣 ' || coalesce((open_at at time zone 'Asia/Taipei')::text, '(立刻)')
                || case when open_at is null or open_at <= now() then '　✅ 客人看得到'
                        else '　⏳ 還沒開賣' end, chr(10) order by play_at)
                from match_queues
               where source='recurring' and status='waiting' and play_at > now()),
             '❌ 一筆都沒有')

  union all select 12, '客人現在實際看得到幾筆固定局（應 ≥ 1）',
    (select count(*)::text from match_queues
      where source='recurring' and status='waiting'
        and play_at > now() and (open_at is null or open_at <= now()))

  union all select 13, '已生成但還沒開賣的（接班用，應 ≥ 1）',
    (select count(*)::text from match_queues
      where source='recurring' and status='waiting'
        and play_at > now() and open_at is not null and open_at > now())

  union all select 14, '實測 list_match_queues_tx 回傳筆數',
    (select jsonb_array_length(list_match_queues_tx(
       '11111111-1111-1111-1111-111111111111'::uuid, null,
       '22222222-2222-2222-2222-222222222222'::uuid))::text)

  union all select 20, '現在時間（台北）',
    (now() at time zone 'Asia/Taipei')::text
) x
order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
-- 第 5 項若是 1 → 只改到一支。第五段的 guard 應該會先中止，若沒有代表
--   list_match_queues_by_city_tx 的別名不叫 q，要撈全文另外處理。
-- 第 12 項是 0、第 13 項 > 0 → 生成正常但全部還沒開賣。
--   對 daily 而言只有在「今天那場已過、明天那場的開賣時間還沒到」時才會這樣，
--   而 lead_hours=24 表示明天 21:00 的局在今天 21:00 就開賣 —— 不該出現。
--   真的出現就是 lead_hours 設太小。
-- 第 14 項應該包含第 12 項的筆數（可能再加上 POS 開的即時房）。
--
-- ── 真正的驗證要等明天 ───────────────────────────────────────
-- 明天 21:00 過後再看一次：以前這個時間點固定局會消失 5 小時，
-- 現在接班的那筆早就生好、而且開賣時間正好是 21:00，畫面不該變空。
--
-- ── 沒做的事（刻意）──────────────────────────────────────────
-- 🟡 cron 回報的「succeeded ｜ 1 row」沒有意義 —— 那是 SELECT 的列數，
--    跟建立幾筆無關。這支可以連續三天產生零筆而紀錄永遠成功（今天就是這樣）。
--    要有觀測性得把回傳值寫進 log 表，另一件事。
-- 🟡 recurring_id 沒有外鍵指向 recurring_tables。孤兒 0 筆，但刪範本不會連動。
--    加外鍵要先決定「刪範本時客人已報名的房怎麼辦」，不是加個 references 就好。
-- 🟡 recurring_tables.weekday 對 daily 範本無意義（現有那筆是 0＝週日，純殘值）。
--    docs 待辦已記，做 POS 固定局介面時一併處理。
