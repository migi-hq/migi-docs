-- ════════════════════════════════════════════════════════════════════
-- 桌況：預留中 / 現場專用 / 收桌保留給現場
-- 2026-08-23
--
-- 待辦 5 說「缺一不可」的最後兩件，加上讓「現場」這個設定可以關回去。
--
-- ═══ 為什麼現在非做不可 ═══
--
-- 🔴 **湊滿就佔桌之後，桌況會說謊。**
--    `list_tables_tx` 的 status 只看「有沒有 open 的 table_sessions」，
--    自動帶桌一成立就建 session，於是那張桌立刻變「使用中」——
--    但 `session_players` 是 0，**沒有任何人在打**，客人可能兩小時後才到。
--    POS 的桌況卡此時畫的是「0 人 · 00:03」（`App.jsx:150`／`:152`）。
--    店員看到滿格會把站在櫃檯的現場客人推掉 —— 那是實際的生意損失，
--    而且畫面上沒有任何地方看得出來那桌其實是空的。
--
-- 🟡 **`auto_assign = false` 目前完全看不見。**
--    週六為了現場客人關掉的桌，週一沒人記得改回來，
--    那幾桌會從此永遠不被自動配到，而且不會報錯、不會有異常畫面。
--    這是 CLAUDE.md 待辦 5 早就寫下的擔憂，現在補上「看得見」這一半。
--
-- 🔴 **而且現在根本沒有把它關回去的方法** —— `2026-08-23_自動配桌與現場登記.sql`
--    只建了欄位，沒有任何 RPC 會寫它。做「收完保留給現場」而不做「開回來」，
--    等於蓋一道單向門：第一個勾下去的店員就永久少了一張可配的桌。
--    → 三件事必須同一支落地。
--
-- ═══ 三個設計決定 ═══
--
-- ① **`status` 不動，改用 `is_hold` 旗標**（expand-safe）。
--    SQL 走 Dashboard、POS 走 Cloudflare，兩邊不會同時上線。
--    若把 status 多加一個 `'hold'` 值，舊版 POS 會掉進 TableCard 最後那個
--    「停用」分支 —— 使用中的桌畫成灰色停用卡，比現在更糟。
--    加旗標的話舊版 POS 行為完全不變（照樣顯示使用中），新版才讀得到。
--
-- ② **`hold_kind` 分 `queue` 與 `setup`，因為店員要做的事不同。**
--    - `queue`：配桌湊滿佔的桌，客人還沒到 → 要知道**幾點開打**、誰要來
--    - `setup`：店員自己按了開桌設定但還沒結帳 → 那是他一分鐘前的動作，
--      點進去就是繼續結帳
--    兩個都是「session 開著但沒人入座」，但一個要等、一個要接著做。
--    合成一種狀態會讓店員每次都得點進去才知道是哪種。
--
-- ③ **收桌的「保留給現場」與 `auto_assign` 是同一件事，故合在 `settle_session_tx`。**
--    情境是「現場有四人在等」，若分兩個動作，店員必須**先關掉那桌再按收桌**——
--    順序反了就在那零點幾秒被 App 搶走，而那是客人站在旁邊時要記得的事。
--    一個勾選同時做兩件事，就沒有順序可以搞錯。
--
-- ⚠ **它是設定不是狀態**：勾下去之後那張桌**永遠**不再被自動配，
--    直到有人手動開回來。這正是 ② 那個「看得見」為什麼是必要配套而不是裝飾。
-- ════════════════════════════════════════════════════════════════════

begin;

-- ─────────────────────────────────────────────────────────────
-- 一、list_tables_tx：加 is_hold / hold_kind / 開打資訊 / auto_assign
--     簽名不變 → 不需要 DROP（硬規則 2 只在改簽名時適用）
-- ─────────────────────────────────────────────────────────────
create or replace function public.list_tables_tx(p_org_id uuid, p_store_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', t.id, 'label', t.label, 'area', t.area, 'seats', t.seats,
      'is_active', t.is_active, 'note', t.note,

      -- ⚠ status 維持三值（off / use / idle），不新增 'hold'。
      --    舊版 POS 遇到沒見過的值會掉進「停用」分支畫成灰卡，比現況更糟。
      'status', case
                  when not t.is_active then 'off'
                  when ts.id is not null then 'use'
                  else 'idle' end,

      'session_id', ts.id,
      'started_at', ts.started_at,
      'planned_minutes', ts.planned_minutes,
      'stake_level_id', ts.stake_level_id,
      'mode', ts.mode,

      -- 在座人數：session_players 是**結帳成功後**才建立的，
      -- 所以「還沒有人結帳」與「還沒有人到」在這個系統裡是同一件事。
      'players', coalesce(pl.n, 0),

      -- ── 預留中 ───────────────────────────────────────────
      -- 桌開著但一個人都還沒入座。畫面上必須跟「真的有人在打」分開，
      -- 否則店員會把現場客人推掉（見檔頭）。
      'is_hold', (ts.id is not null and coalesce(pl.n, 0) = 0),

      -- queue = 配桌湊滿自動佔的（客人還沒到，要等）
      -- setup = 店員按了開桌設定還沒結帳（他一分鐘前的動作，點進去繼續）
      'hold_kind', case
                     when ts.id is null or coalesce(pl.n, 0) > 0 then null
                     when mq.id is not null then 'queue'
                     else 'setup' end,

      'queue_id',       mq.id,
      'queue_play_at',  mq.play_at,
      -- 誰要來。⚠ 只算沒離開的（left_at is null）——
      -- 報名後又退出的人不該出現在「等一下會來這桌」的名單裡。
      'queue_members',  coalesce(mq.names, '[]'::jsonb),

      -- ── 現場專用 ─────────────────────────────────────────
      -- false = 這張桌不給系統自動配。是**店員的意思**，沒人改就不會變，
      -- 所以它是欄位不是算出來的（桌況本身仍然是每次從 table_sessions 算）。
      'auto_assign', t.auto_assign

    ) order by t.sort_order, t.label)
    from tables t

    left join lateral (
      select ts.* from table_sessions ts
       where ts.table_id = t.id and ts.status = 'open' and ts.deleted_at is null
       order by ts.started_at desc limit 1
    ) ts on true

    -- 在座人數獨立拉出來：is_hold 與 players 都要用，算兩次會有機會寫歪一次
    left join lateral (
      select count(*)::int as n
        from session_players sp
       where sp.session_id = ts.id
         and sp.left_at is null
    ) pl on true

    -- 這張桌是被哪一房配走的。matched_session_id 是 2026-08-23 那批補上的橋。
    left join lateral (
      select q.id, q.play_at,
             (select coalesce(jsonb_agg(m.display_name order by p.joined_at), '[]'::jsonb)
                from match_queue_players p
                join members m on m.id = p.member_id
               where p.queue_id = q.id and p.left_at is null) as names
        from match_queues q
       where q.matched_session_id = ts.id
       order by q.play_at desc
       limit 1
    ) mq on true

    where t.org_id = p_org_id and t.store_id = p_store_id and t.deleted_at is null
  ), '[]'::jsonb);
end $function$;


-- ─────────────────────────────────────────────────────────────
-- 二、settle_session_tx：加「收完保留給現場」
--     ⚠ 簽名改了 → 硬規則 2，必須先 DROP，否則會建出多載版本
--       （多載的後果是 POS 送兩個參數時仍呼叫到舊版，勾選靜靜失效）
-- ─────────────────────────────────────────────────────────────
drop function if exists public.settle_session_tx(uuid, uuid);
drop function if exists public.settle_session_tx(uuid, uuid, boolean);

create or replace function public.settle_session_tx(
  p_session_id      uuid,
  p_staff_id        uuid    default null,
  p_keep_for_walkin boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_s      record;
  v_total  bigint;
  v_left   int;
begin
  select * into v_s
    from table_sessions
   where id = p_session_id and deleted_at is null;

  if v_s.id is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found',
      'message', '場次不存在');
  end if;

  -- 冪等：重複按不該報錯，也不該再動一次 ended_at。
  -- 店員在網路慢的時候按兩下是常態，第二下應該是「已經收好了」。
  if v_s.status = 'completed' then
    -- ⚠ 這條路也要套用勾選：情境是店員收完桌才想到「這桌留給現場」，
    --   再開一次收桌彈窗勾了按下去。設 false 兩次跟設一次一樣，不會壞。
    if p_keep_for_walkin then
      update tables set auto_assign = false where id = v_s.table_id;
    end if;
    return jsonb_build_object('ok', true, 'already_settled', true,
      'session_id', p_session_id, 'table_id', v_s.table_id,
      'ended_at', v_s.ended_at, 'total_points', v_s.fee_points,
      'kept_for_walkin', p_keep_for_walkin);
  end if;

  if v_s.status <> 'open' then
    return jsonb_build_object('ok', false, 'reason', 'session_not_open',
      'message', '此場次已作廢，無法收桌', 'status', v_s.status);
  end if;

  -- 在座的人一律標記離座。left_at 是「這個人什麼時候離開這張桌」，
  -- 收桌就是所有人同時離開 —— 不寫的話桌況的在座人數會永遠停在那個數字。
  update session_players
     set left_at = now()
   where session_id = p_session_id
     and left_at is null;
  get diagnostics v_left = row_count;

  -- 本桌實扣點數合計。charged_points 在入座/加購當下就寫好了，
  -- 這裡只是彙總，不重新計價 —— 收桌不該是第二個計價的地方。
  select coalesce(sum(charged_points), 0) into v_total
    from session_players
   where session_id = p_session_id;

  update table_sessions
     set status     = 'completed',
         ended_at   = now(),
         fee_points = v_total,
         updated_at = now(),
         updated_by = coalesce(p_staff_id, updated_by)
   where id = p_session_id;

  -- ── 收完保留給現場 ─────────────────────────────────────
  -- 與收桌同一個交易，所以不存在「關掉了但沒收成」或「收了但沒關掉」的中間態。
  -- ⚠ 這是**持續設定**不是一次性保留：那張桌從此不再被自動配，
  --   直到有人在桌況上手動開回來（set_table_auto_assign_tx）。
  --   桌況卡的「現場」標記就是為了讓這件事不會被忘記。
  if p_keep_for_walkin then
    update tables set auto_assign = false where id = v_s.table_id;
  end if;

  return jsonb_build_object('ok', true,
    'session_id',      p_session_id,
    'table_id',        v_s.table_id,
    'players_left',    v_left,
    'total_points',    v_total,
    'kept_for_walkin', p_keep_for_walkin,
    'ended_at',        now());
end $function$;


-- ─────────────────────────────────────────────────────────────
-- 三、set_table_auto_assign_tx：把「現場專用」開回來
--     沒有這支的話，上面那個勾選就是單向門 —— 第一個勾下去的店員
--     永久少一張可配的桌，而且沒有任何介面能還原。
-- ─────────────────────────────────────────────────────────────
drop function if exists public.set_table_auto_assign_tx(uuid, boolean);

create or replace function public.set_table_auto_assign_tx(
  p_table_id uuid,
  p_auto     boolean
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_t record;
begin
  -- ⚠ p_auto 不給預設值：這支唯一的用途就是切換那個開關，
  --   忘記傳而靜靜變成某一邊，是收不收得到客人的差別。
  if p_auto is null then
    return jsonb_build_object('ok', false, 'reason', 'auto_required',
      'message', '必須指定要開或關');
  end if;

  update tables
     set auto_assign = p_auto
   where id = p_table_id and deleted_at is null
  returning id, label, auto_assign into v_t;

  if v_t.id is null then
    return jsonb_build_object('ok', false, 'reason', 'table_not_found',
      'message', '找不到這張桌');
  end if;

  return jsonb_build_object('ok', true,
    'table_id', v_t.id, 'label', v_t.label, 'auto_assign', v_t.auto_assign);
end $function$;

commit;


-- ════════════════════════════════════════════════════════════════════
-- 驗證（單一 SELECT）
-- ════════════════════════════════════════════════════════════════════
with s as (
  -- 挑一間真的有桌的門市來實測，不寫死 uuid
  select t.org_id, t.store_id
    from tables t
   where t.deleted_at is null
   group by t.org_id, t.store_id
   order by count(*) desc
   limit 1
),
r as (
  select jsonb_array_elements(list_tables_tx(s.org_id, s.store_id)) as t from s
)
select 項目, 結果
from (
  select 1 as ord, '① list_tables_tx 版本數（應為 1）' as 項目,
    (select count(*)::text from pg_proc
      where pronamespace='public'::regnamespace and proname='list_tables_tx') as 結果

  union all select 2, '② 定義是否含 is_hold / auto_assign（應為 是）',
    case when (select pg_get_functiondef(oid) from pg_proc
                where pronamespace='public'::regnamespace and proname='list_tables_tx' limit 1)
              like '%is_hold%auto_assign%' then '是' else '❌ 否' end

  union all select 3, '③ settle_session_tx 版本數（應為 1，證明 DROP 生效）',
    (select count(*)::text from pg_proc
      where pronamespace='public'::regnamespace and proname='settle_session_tx')

  union all select 4, '④ settle_session_tx 簽名（應含 p_keep_for_walkin）',
    coalesce((select pg_get_function_identity_arguments(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='settle_session_tx' limit 1),
             '❌ 不存在')

  union all select 5, '⑤ set_table_auto_assign_tx 存在且為 DEFINER',
    coalesce((select case when prosecdef then '是（DEFINER）' else '❌ INVOKER' end
                from pg_proc
               where pronamespace='public'::regnamespace and proname='set_table_auto_assign_tx' limit 1),
             '❌ 不存在')

  union all select 10, '⑩ 實測門市',
    coalesce((select st.name || '（' || (select count(*) from tables tb
                                          where tb.store_id = s.store_id and tb.deleted_at is null)::text
                    || ' 桌）'
                from s join stores st on st.id = s.store_id), '❌ 沒有任何門市有桌')

  union all select 11, '⑪ 桌況現況（狀態／在座／預留／自動配）',
    coalesce((select string_agg(
                (t->>'label') || '　' ||
                (case t->>'status' when 'use' then '使用中' when 'idle' then '空桌' else '停用' end) ||
                '　在座 ' || coalesce(t->>'players','?') ||
                (case when (t->>'is_hold')::boolean
                      then '　🟠 預留中(' || coalesce(t->>'hold_kind','?') || ')' ||
                           coalesce('　' || to_char((t->>'queue_play_at')::timestamptz
                                     at time zone 'Asia/Taipei', 'MM/DD HH24:MI') || ' 開打', '') ||
                           coalesce('　' || (select string_agg(x, '、')
                                               from jsonb_array_elements_text(t->'queue_members') x), '')
                      else '' end) ||
                (case when (t->>'auto_assign')::boolean then '' else '　🔒 現場專用' end),
                chr(10) order by t->>'label')
                from r), '❌ 回傳空陣列')

  union all select 20, '⑳ 煙霧測試：收桌用不存在的場次（應回 session_not_found）',
    coalesce(settle_session_tx('00000000-0000-0000-0000-000000000000'::uuid, null, true)->>'reason',
             '❌ 沒有回 reason')

  union all select 21, '㉑ 煙霧測試：切換不存在的桌（應回 table_not_found）',
    coalesce(set_table_auto_assign_tx('00000000-0000-0000-0000-000000000000'::uuid, false)->>'reason',
             '❌ 沒有回 reason')

  union all select 22, '㉒ 煙霧測試：p_auto 傳 null（應回 auto_required）',
    coalesce(set_table_auto_assign_tx('00000000-0000-0000-0000-000000000000'::uuid, null)->>'reason',
             '❌ 沒有回 reason')
) x
order by ord;

-- ── 怎麼看 ────────────────────────────────────────────────
-- ①②③④⑤ 是結構，照括號裡寫的對。
-- ⑪ 是這支的重點：**「使用中　在座 0」而沒有 🟠 預留中，就是壞的**。
--    若現在剛好沒有配桌佔著的桌，那一行只會顯示使用中／空桌，那是正常的
--    —— 等一下走一次「APP 報名湊滿 4 人」就會看到 🟠。
-- ⑳ 傳了 p_keep_for_walkin = true 但場次不存在，必須什麼都不做就回 not_found
--    （若它先去改 tables 才檢查場次，就會關掉一張不相干的桌）。
