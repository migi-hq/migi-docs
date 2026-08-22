-- 【這是什麼】POS 官方開桌：pos_create_queue_tx + pos_close_queue_tx。
-- 【何時讀】改 migi-pos 的 QueuePage 之前。盤點見 sql/checks/查POS配桌可用RPC.sql。
--
-- ═══ 為什麼不用現成的 create_match_queue_tx ═══
--
-- 那支是「會員開房並坐進去」的邏輯，三處對 POS 不成立：
--   ① 沒有 p_source 參數 → POS 開的房會被標成 member，之後分不出誰開的
--   ② 會把 p_opener 塞進 match_queue_players → 官方開桌沒有人要入座
--   ③ _check_join_conflict(..., p_opener, ...) 對 null 開房者行為未知
--
-- ⚠ list_match_queues_tx **不用改**：它的 p_member 只用在黑名單過濾
--   （_blocked_between），POS 傳 null 等於不過濾，正是要的。
--   而且它的排序已經寫著 order by (source='pos') desc —— 當初就預留了。
--
-- ═══ 設計決定 ═══
--
-- · opened_by = null：官方開桌沒有「開房的人」。店員登入還沒做（POS 一律傳 null），
--   硬塞一個 member id 進去是假的，而且那個外鍵是 ON DELETE RESTRICT，
--   塞錯人之後連刪都刪不掉。
-- · 不寫 match_queue_players：沒有人入座。會員版會塞是因為「開房＝報名」。
-- · expires_at = play_at：與 recurring 一致 —— 開打即不可再加入。
-- · source = 'pos'：CHECK 本來就允許（member / pos / recurring）。
--
-- ⚠ 這一版**不做重複開桌的模糊判斷**，只擋「同門市、同開打時間、還在等待中」的完全撞號。
--   同一時段開兩桌不同級距是合理的（大注場與純娛樂場並存），不該擋。

-- ============================================================
-- 一、前置檢查
-- ============================================================
do $do$
declare v_missing text; v_status_def text;
begin
  select string_agg(need.t || '.' || need.c, '、' order by need.t, need.c)
    into v_missing
    from (values
      ('match_queues','org_id'), ('match_queues','store_id'), ('match_queues','stake_level_id'),
      ('match_queues','game_type'), ('match_queues','flower'), ('match_queues','rounds'),
      ('match_queues','seats'), ('match_queues','prefs'), ('match_queues','opened_by'),
      ('match_queues','play_at'), ('match_queues','expires_at'), ('match_queues','source'),
      ('match_queues','status'),
      ('match_queue_players','queue_id'), ('match_queue_players','member_id'), ('match_queue_players','left_at')
    ) as need(t, c)
   where not exists (select 1 from information_schema.columns
                      where table_schema = 'public' and table_name = need.t and column_name = need.c);
  if v_missing is not null then
    raise exception '缺欄位，整支中止：%', v_missing;
  end if;

  -- status 的允許值要確認過才敢寫入（不猜，硬規則 3）
  select string_agg(pg_get_constraintdef(oid), ' ｜ ') into v_status_def
    from pg_constraint
   where conrelid = 'match_queues'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) ilike '%status%';
  if v_status_def is null then
    raise notice 'match_queues.status 沒有 CHECK 約束，沿用資料裡出現過的值：waiting / matched / expired';
  else
    raise notice 'match_queues.status 的 CHECK：%', v_status_def;
    if v_status_def not ilike '%waiting%' or v_status_def not ilike '%expired%' then
      raise exception 'status 的允許值與預期不同（waiting / expired），整支中止。實際：%', v_status_def;
    end if;
  end if;
end $do$;

-- ============================================================
-- 二、官方開桌
-- ============================================================
drop function if exists pos_create_queue_tx(uuid, uuid, uuid, timestamptz, text, text, text, int);

create function pos_create_queue_tx(
  p_org_id    uuid,
  p_store     uuid,
  p_stake     uuid,
  p_play_at   timestamptz,
  p_game_type text default '台麻',
  p_flower    text default '無花',
  p_rounds    text default '一將',
  p_seats     int  default 4
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_qid uuid;
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
    prefs, opened_by, play_at, expires_at, source, status)
  values (
    p_org_id, p_store, p_stake, p_game_type, p_flower, p_rounds, coalesce(p_seats, 4),
    '{}'::jsonb,
    null,          -- 官方開桌沒有開房者；店員登入還沒做
    p_play_at,
    p_play_at,     -- 開打即不可再加入，與 recurring 一致
    'pos', 'waiting')
  returning id into v_qid;

  return jsonb_build_object('ok', true, 'queue_id', v_qid);
end $$;

comment on function pos_create_queue_tx(uuid, uuid, uuid, timestamptz, text, text, text, int) is
  'POS 官方開桌：建立 source=pos 的等待房，不寫入 match_queue_players（沒有人入座）。';

grant execute on function pos_create_queue_tx(uuid, uuid, uuid, timestamptz, text, text, text, int) to anon, authenticated;

-- ============================================================
-- 三、關掉開錯的房
-- ============================================================
-- 沒有這支的話，開錯的房會一直掛在客人畫面上直到 play_at 才自動過期 —— 最久一整天。
drop function if exists pos_close_queue_tx(uuid, uuid);

create function pos_close_queue_tx(p_org_id uuid, p_queue uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_src text; v_status text; v_players int;
begin
  select source, status into v_src, v_status
    from match_queues where id = p_queue and org_id = p_org_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  if v_status <> 'waiting' then
    -- 冪等：已經關掉或已成桌就直接回報現況，不當成錯誤
    return jsonb_build_object('ok', true, 'already', v_status);
  end if;

  -- ⚠ 有人報名就不給關。客人排了半小時，房被店員一鍵刪掉而且沒有任何通知，
  --   那是客訴。要處理得先有「通知報名者」這件事，先擋住。
  select count(*) into v_players
    from match_queue_players where queue_id = p_queue and left_at is null;
  if v_players > 0 then
    return jsonb_build_object('ok', false, 'reason', 'has_players', 'players', v_players);
  end if;

  update match_queues
     set status = 'expired', expires_at = least(coalesce(expires_at, now()), now()), updated_at = now()
   where id = p_queue and org_id = p_org_id;

  return jsonb_build_object('ok', true, 'source', v_src);
end $$;

comment on function pos_close_queue_tx(uuid, uuid) is
  'POS 關閉等待中的配桌房（開錯桌用）。有人報名就拒絕 —— 沒有通知機制之前不能一鍵刪。';

grant execute on function pos_close_queue_tx(uuid, uuid) to anon, authenticated;

-- ============================================================
-- 四、驗證（硬規則 7：必須實際執行並看到回傳）
-- ============================================================
-- 用真實門市與級距做一次完整來回：開 → 列表看得到 → 關 → 列表看不到。
-- 全部在同一個交易裡，最後那筆會留在資料庫（Supabase SQL Editor 會提交），
-- 但已經被關成 expired，不影響畫面。
with ids as (
  select '11111111-1111-1111-1111-111111111111'::uuid as org,
         '22222222-2222-2222-2222-222222222222'::uuid as store,
         '1efa2006-4480-4996-9605-afc0ac2c51c7'::uuid as stake,
         (date_trunc('hour', now()) + interval '30 hours')     as play_at
),
made as (
  select i.*, pos_create_queue_tx(i.org, i.store, i.stake, i.play_at, '台麻', '無花', '一將', 4) as r from ids i
),
listed as (
  select m.*, list_match_queues_tx(m.org, null, m.store) as q from made m
),
closed as (
  select l.*, pos_close_queue_tx(l.org, (l.r->>'queue_id')::uuid) as c from listed l
),
after as (
  select c.*, list_match_queues_tx(c.org, null, c.store) as q2 from closed c
)
select 項目, 結果 from (
  select 1 as ord, '① 開桌回傳' as 項目, (select r::text from after) as 結果
  union all select 2, '② 開的是不是 source=pos',
    (select coalesce((select string_agg(e->>'source', ',') from jsonb_array_elements(q) e
                       where e->>'id' = (r->>'queue_id')), '❌ 列表裡找不到剛開的房') from after)
  union all select 3, '③ 列表總筆數（p_member 傳 null 沒有炸掉就算過）',
    (select jsonb_array_length(q)::text from after)
  union all select 4, '④ 關房回傳',
    (select c::text from after)
  union all select 5, '⑤ 關掉後列表還找不找得到它（應為 0）',
    (select (select count(*) from jsonb_array_elements(q2) e
              where e->>'id' = (r->>'queue_id'))::text from after)
  union all select 6, '⑥ 重複開同一時段同級距（應回 duplicate）',
    (select pos_create_queue_tx(org, store, stake,
              (date_trunc('hour', now()) + interval '31 hours'), '台麻', '無花', '一將', 4)::text
       from after)
  union all select 7, '⑦ 開過去的時間（應回 play_at_in_past）',
    (select pos_create_queue_tx(org, store, stake, now() - interval '1 hour')::text from after)
  union all select 8, '⑧ 關不存在的房（應回 not_found）',
    (select pos_close_queue_tx(org, '00000000-0000-0000-0000-000000000000'::uuid)::text from after)
) x order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
-- ② 若是「列表裡找不到剛開的房」→ list_match_queues_tx 把它濾掉了，
--    最可能是 _blocked_between(org, null, member) 在 p_member 為 null 時回了 true。
--    那 POS 就不能直接用這支，要另開一支或加 p_member is null 的分支。
-- ③ 只要是數字就代表 p_member 傳 null 不會炸 —— 那是這次最想確認的事。
-- ⑥ 第 6 項開的是 31 小時後、跟第 1 項的 30 小時不同時間，所以**應該成功**才對；
--    若回 duplicate 代表撞號判斷寫太寬。⚠ 這筆會留下來，記得之後手動關掉，
--    或直接在 POS 上按關閉測一次。
--
-- ── 接下來（順序不能反）─────────────────────────────────────
-- 1. POS QueuePage 接 list_match_queues_tx（唯讀，最安全）
-- 2. 「＋ 官方開桌」接 pos_create_queue_tx
-- 3. 確認 POS 開得出來之後，才停掉 gen-recurring-instances
--    —— 先停的話固定局會完全消失（現在只剩 30 筆過期的）
-- 4. recurring_tables 先留著不刪，之後要恢復自動生成或加「今天不開」的覆寫還用得到
