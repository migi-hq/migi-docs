-- ════════════════════════════════════════════════════════════════════
-- 配桌標籤：queue_tags 主檔 + POS 開桌可掛（非必選）
-- 2026-08-23
--
-- ═══ 為什麼要建主檔，而不是 POS 也寫死一份 ═══
--
-- 🔴 會員 App 的 QUEUE_TAGS 是**寫死的白名單**（migi-web match.jsx），
--    render 時會 filter 掉不認識的代碼：tags.filter((t) => QUEUE_TAGS[t])
--    而 match_queues.tags 上**沒有任何 CHECK**（已查證），任何字串都寫得進去。
--    → POS 只要寫進一個 App 沒有的值，**店員以為掛好了、客人什麼都沒看到、
--      而且不會有任何錯誤訊息**。這是最難查的那種 bug。
--
-- ⚠ 「兩端各自寫死」不是省事，是把上面那個洞永久留著：
--   加第四個標籤要改兩個 repo、部署兩次，漏掉會員端那次就靜靜失效。
--
-- ✅ 這正是主檔真正該存在的情況：**一端寫、另一端讀**。
--   對照 product_taxonomy 的教訓 —— 那張表的問題不是「建了主檔」，
--   是「建了卻只有 migi-admin 讀」（CLAUDE.md 待辦 0）。這裡兩端都會讀。
--   加標籤從此是 INSERT 一列，不用部署任何前端。
--
-- ⚠ 但主檔只解決「顯示文字同步」。**寫入端仍然要擋** ——
--   所以 pos_create_queue_tx 會拿 p_tags 去比對 queue_tags，
--   未知代碼直接回 unknown_tag 並說出是哪一個。
--   失敗要大聲，不要安靜。
--
-- ═══ 已查證的現況（2026-08-23）═══
--   · match_queues.tags：jsonb NOT NULL default '[]'::jsonb，無 CHECK
--   · 47 房全是空陣列 → 現在改成本為零，沒有歷史資料要遷移
--   · pos_create_queue_tx 沒有 tags 參數
--   · pos_list_queues_tx **不回傳 tags**（POS 卡片要顯示就得補）
--   · list_match_queues_tx 有回傳 tags（會員端不用改後端）
--   · recurring_tables **沒有 tags 欄位** → 本次只做「即時」，見檔尾
-- ════════════════════════════════════════════════════════════════════

begin;

-- ─────────────────────────────────────────────────────────────
-- 一、queue_tags 主檔
--     ⚠ 無 org_id、無 RLS 寫入政策 —— 比照 product_taxonomy。
--       讓單店自訂標籤代碼，會讓會員端顯示不出來（代碼是前端與後端的共同語言）。
--       要新增標籤是總部的事，走 SQL。
-- ─────────────────────────────────────────────────────────────
create table if not exists public.queue_tags (
  code        text primary key,
  label       text        not null,
  sort_order  int         not null default 0,
  is_active   boolean     not null default true,
  created_at  timestamptz not null default now()
);

comment on table public.queue_tags is
  '配桌房標籤主檔。POS 開桌時挑選（非必選），會員端讀 label 顯示。
   ⚠ 無 org_id：代碼是三端的共同語言，讓單店自訂會讓會員端顯示不出來。
   ⚠ 停用請設 is_active=false，不要 DELETE —— 舊的房還掛著那個代碼，
     刪掉之後那些房的標籤會變成查不到 label 的孤兒。';

-- 現有的三個（與 migi-web QUEUE_TAGS 一字不差）
insert into public.queue_tags(code, label, sort_order) values
  ('newbie',     '新手友善',   1),
  ('influencer', '網紅在這桌', 2),
  ('pro',        '職業選手桌', 3)
on conflict (code) do nothing;

alter table public.queue_tags enable row level security;

-- 只讀。⚠ 沒有 INSERT/UPDATE/DELETE 政策 = 誰都不能從前端改，這是刻意的。
drop policy if exists queue_tags_read on public.queue_tags;
create policy queue_tags_read on public.queue_tags for select using (true);


-- ─────────────────────────────────────────────────────────────
-- 二、list_queue_tags_tx()：三端唯一的標籤清單來源
-- ─────────────────────────────────────────────────────────────
drop function if exists public.list_queue_tags_tx();

create or replace function public.list_queue_tags_tx()
returns jsonb
language sql
security definer
set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', code, 'label', label
         ) order by sort_order, code), '[]'::jsonb)
    from queue_tags
   where is_active;
$function$;


-- ─────────────────────────────────────────────────────────────
-- 三、pos_create_queue_tx 加 p_tags
--     ⚠ 簽名改了 → 硬規則 2，先 DROP。
--       不 DROP 的話會建出多載版本，POS 送 9 個參數時仍可能打到舊的 8 參數版，
--       標籤靜靜消失而且不報錯。
--     ⚠ p_tags 有預設值 '[]'：標籤是**非必選**，不傳就是沒有。
--       這與「開桌設定五項全部不預選」不衝突 —— 那五項決定收多少錢，
--       這一項不影響任何金額，多數桌沒有特色是正常的。
-- ─────────────────────────────────────────────────────────────
drop function if exists public.pos_create_queue_tx(uuid, uuid, uuid, timestamptz, text, text, text, integer);
drop function if exists public.pos_create_queue_tx(uuid, uuid, uuid, timestamptz, text, text, text, integer, jsonb);

create or replace function public.pos_create_queue_tx(
  p_org_id    uuid,
  p_store     uuid,
  p_stake     uuid,
  p_play_at   timestamptz,
  p_game_type text    default '台麻',
  p_flower    text    default '無花',
  p_rounds    text    default '一將',
  p_seats     integer default 4,
  p_tags      jsonb   default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_qid  uuid;
  v_tags jsonb;
  v_bad  text;
begin
  -- 業務錯誤一律回 {ok:false}，不拋例外 —— 前端要能分辨「擋下來」與「壞掉」
  if p_store   is null then return jsonb_build_object('ok', false, 'reason', 'store_required'); end if;
  if p_stake   is null then return jsonb_build_object('ok', false, 'reason', 'stake_required'); end if;
  if p_play_at is null then return jsonb_build_object('ok', false, 'reason', 'play_at_required'); end if;

  -- 開一個已經過去的時間點：客人永遠看不到（list 有 expires_at > now 的條件），
  -- 店員會以為開好了。這種「成功了但沒有效果」正是硬規則 4 要防的形狀。
  if p_play_at <= now() then
    return jsonb_build_object('ok', false, 'reason', 'play_at_in_past');
  end if;

  -- ── 標籤驗證 ─────────────────────────────────────────────
  -- ⚠ null 與 '[]' 都視為「沒有標籤」，不是錯誤。
  v_tags := coalesce(p_tags, '[]'::jsonb);

  -- ⚠ 先判型別再展開：jsonb 欄位也可能收到物件或字串，
  --   那時 jsonb_array_elements_text 是**直接拋錯**而不是回空集合。
  if jsonb_typeof(v_tags) <> 'array' then
    return jsonb_build_object('ok', false, 'reason', 'tags_not_array',
      'message', '標籤要用陣列格式');
  end if;

  -- 未知代碼一律擋，而且要說出是哪一個。
  -- ⚠ 這道擋牆才是重點：match_queues.tags 沒有 CHECK，
  --   放行未知代碼的後果是「店員以為掛好了、客人什麼都看不到、沒有錯誤訊息」。
  --   零列時 string_agg 回 null，所以 v_bad is null 就是全部合法。
  select string_agg(e.t, '、') into v_bad
    from jsonb_array_elements_text(v_tags) as e(t)
   where not exists (
     select 1 from queue_tags g where g.code = e.t and g.is_active
   );
  if v_bad is not null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_tag',
      'message', '找不到這些標籤：' || v_bad);
  end if;

  -- 完全撞號才擋。同時段開兩桌不同級距是合理的（大注場與純娛樂場並存）。
  if exists (
    select 1 from match_queues
     where org_id = p_org_id and store_id = p_store
       and play_at = p_play_at
       and stake_level_id is not distinct from p_stake
       and status = 'waiting'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'duplicate');
  end if;

  insert into match_queues(
    org_id, store_id, stake_level_id, game_type, flower, rounds, seats,
    prefs, opened_by, play_at, expires_at, source, status, tags)
  values (
    p_org_id, p_store, p_stake, p_game_type, p_flower, p_rounds, coalesce(p_seats, 4),
    '{}'::jsonb,
    null,          -- 官方開桌沒有開房者；店員登入還沒做
    p_play_at,
    p_play_at,     -- 開打即不可再加入，與 recurring 一致
    'pos', 'waiting', v_tags)
  returning id into v_qid;

  return jsonb_build_object('ok', true, 'queue_id', v_qid, 'tags', v_tags);
end $function$;


-- ─────────────────────────────────────────────────────────────
-- 四、pos_list_queues_tx 補回傳 tags
--     ⚠ 這裡只加一個欄位，所以用單點替換 + guard，不重建全文
--       （CLAUDE.md：要改三處以上才撈全文重建）。
--       找不到錨點就整支 raise —— 寧可整批回滾，也不要「改了一半」。
-- ─────────────────────────────────────────────────────────────
do $$
declare
  v_old text;
  v_new text;
  v_anchor text := '''session_id'', q.matched_session_id,';
begin
  select pg_get_functiondef(oid) into v_old
    from pg_proc
   where pronamespace = 'public'::regnamespace and proname = 'pos_list_queues_tx'
   limit 1;

  if v_old is null then
    raise exception 'pos_list_queues_tx 不存在，無法加 tags';
  end if;

  if position('''tags''' in v_old) > 0 then
    raise notice 'pos_list_queues_tx 已經回傳 tags，略過';
    return;
  end if;

  if position(v_anchor in v_old) = 0 then
    raise exception '找不到錨點 % —— 線上版與預期不同，請先撈全文再改', v_anchor;
  end if;

  v_new := replace(v_old, v_anchor, v_anchor || ' ''tags'', q.tags,');
  execute v_new;

  -- guard：確認真的改到了。沒有這道的話，replace 沒生效也會靜靜成功。
  select pg_get_functiondef(oid) into v_new
    from pg_proc
   where pronamespace = 'public'::regnamespace and proname = 'pos_list_queues_tx'
   limit 1;
  if position('''tags''' in v_new) = 0 then
    raise exception 'tags 沒有進到 pos_list_queues_tx，已回滾';
  end if;
end $$;

commit;


-- ════════════════════════════════════════════════════════════════════
-- 驗證（單一 SELECT）
-- ════════════════════════════════════════════════════════════════════
select 項目, 結果
from (
  select 1 as ord, '① queue_tags 內容' as 項目,
    coalesce((select string_agg(code || ' → ' || label, chr(10) order by sort_order)
                from queue_tags where is_active), '❌ 空的') as 結果

  union all select 2, '② list_queue_tags_tx() 回傳',
    coalesce(list_queue_tags_tx()::text, '❌ null')

  union all select 3, '③ pos_create_queue_tx 版本數（應為 1，證明 DROP 生效）',
    (select count(*)::text from pg_proc
      where pronamespace='public'::regnamespace and proname='pos_create_queue_tx')

  union all select 4, '④ pos_create_queue_tx 簽名（應含 p_tags jsonb）',
    coalesce((select pg_get_function_identity_arguments(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='pos_create_queue_tx' limit 1),
             '❌ 不存在')

  union all select 5, '⑤ pos_list_queues_tx 現在有沒有回傳 tags',
    coalesce((select case when pg_get_functiondef(oid) like '%''tags''%' then '有' else '❌ 沒有' end
                from pg_proc
               where pronamespace='public'::regnamespace and proname='pos_list_queues_tx' limit 1),
             '❌ 函式不存在')

  -- 煙霧測試：全部走「不會真的建立」的路徑（store_required 在最前面就擋掉），
  -- 所以不會在資料庫留下任何一房。
  union all select 10, '⑩ 煙霧測試：未知標籤（應回 unknown_tag）',
    coalesce(
      pos_create_queue_tx(
        '00000000-0000-0000-0000-000000000000'::uuid,
        '00000000-0000-0000-0000-000000000000'::uuid,
        '00000000-0000-0000-0000-000000000000'::uuid,
        now() + interval '3 hours',
        '台麻', '無花', '2 將', 4,
        '["newbie","不存在的標籤"]'::jsonb
      )->>'reason', '❌ 沒有回 reason')

  union all select 11, '⑪ 煙霧測試：標籤不是陣列（應回 tags_not_array）',
    coalesce(
      pos_create_queue_tx(
        '00000000-0000-0000-0000-000000000000'::uuid,
        '00000000-0000-0000-0000-000000000000'::uuid,
        '00000000-0000-0000-0000-000000000000'::uuid,
        now() + interval '3 hours',
        '台麻', '無花', '2 將', 4,
        '"newbie"'::jsonb
      )->>'reason', '❌ 沒有回 reason')

  -- ⚠ 這一題順便撈：固定牌局要能掛標籤，得知道這兩支長什麼樣。
  --   recurring_tables 沒有 tags 欄位（已查證），所以本次只做「即時」。
  union all select 20, '⑳ pos_create_recurring_tx 全文（下一步做固定牌局用）',
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='pos_create_recurring_tx' limit 1),
             '（不存在）')

  union all select 21, '㉑ 固定牌局的實例產生函式有哪些',
    coalesce((select string_agg(proname || '(' || pg_get_function_identity_arguments(oid) || ')',
                                chr(10) order by proname)
                from pg_proc
               where pronamespace='public'::regnamespace and prokind='f'
                 and (proname ilike '%recurring%' or proname ilike '%generate%')),
             '（無）')
) x
order by ord;

-- ── 怎麼看 ────────────────────────────────────────────────
-- ①〜⑤ 是結構，照括號裡寫的對。
-- ⑩⑪ 是這支的重點：**未知代碼必須被擋且說出是哪一個**。
--   兩題都用不存在的 org/store uuid，但標籤檢查排在 INSERT 之前，
--   所以會在碰到外鍵之前就回傳，不會在資料庫留下任何一房。
--   ⚠ 若它們沒有回 unknown_tag / tags_not_array，而是噴外鍵錯誤，
--     代表標籤檢查被排到 INSERT 後面了 —— 那樣真實呼叫會留下半筆髒資料。
-- ⑳㉑ 是下一步的材料，這次不動它們。
--
-- ⚠ 前端還沒改：跑完這支之後 POS 仍然不會送 tags（送不送都不影響現有行為，
--   因為 p_tags 有預設值）。UI 我接著做。
