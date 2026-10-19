-- ════════════════════════════════════════════════════════════════════
-- POS 配桌：店員可以直接改開打時間（2026-10-19 使用者）
--
-- 起因：有人遲到，整個房就被取消。
--   · 還沒湊滿的房：expires_at ＝ 開打時間（建房時就這樣設），時間一到
--     sweep_expired_queues_tx（pg_cron 每 5 分）就把整房標成流局、把人踢出
--   · 已經帶到桌的房：開打後 30 分鐘還沒人入座，cleanup_empty_sessions_tx 收桌，
--     觸發器再把房標成流局
--   ⇒ 兩條都看「開打時間」，所以店員把開打時間往後延，兩條就都跟著延
--
-- 為什麼不用線上既有的 update_play_at_tx：
--   ① 它只改開打時間、沒有一起改 expires_at ⇒ 往後延了，房還是在原本的時間被流局
--   ② 不看房的狀態（流局、收桌的也改得動）
--   ③ 三個前端都沒有人在叫它（2026-10-19 查過）—— 這份不動它
--
-- 這份做的事：
--   1. match_queues 加三欄：誰改的、什麼時候改的、原本的開打時間（稽核，不可回溯 ⇒ 現在就記）
--   2. 新函式 pos_set_queue_play_at_tx：只有店員；房必須還沒開打；新時間要在未來、7 天內；
--      開打時間與 expires_at 一起改；通知房裡的人
--   3. 固定牌局的排程（generate_recurring_instances_tx）改認「原本的開打時間」——
--      它用「範本＋開打時間有沒有一場」判斷要不要產生，改過時間的那一場會被當成不存在，
--      到了原本的時間又多產生一場重複的
--   4. 報表檢視表 v_real_match_queues 補上三個新欄位（欄位清單是寫死的，不補就查不到）
-- ════════════════════════════════════════════════════════════════════

-- ── 1. 稽核欄位 ──────────────────────────────────────────────────────
alter table public.match_queues
  add column if not exists play_at_changed_by_staff_id uuid references public.staff(id),
  add column if not exists play_at_changed_at timestamptz,
  add column if not exists play_at_original timestamptz;

comment on column public.match_queues.play_at_changed_by_staff_id is
  '最後一次在 POS 改開打時間的店員（2026-10-19）。值由 current_staff() 解析，前端不能指定';
comment on column public.match_queues.play_at_changed_at is
  '最後一次在 POS 改開打時間的時間';
comment on column public.match_queues.play_at_original is
  '第一次被改之前的開打時間；沒改過是 null。固定牌局的排程用它判斷「這一場已經產生過」';

-- ── 2. 店員改開打時間 ────────────────────────────────────────────────
create or replace function public.pos_set_queue_play_at_tx(p_queue uuid, p_play_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_staff_id uuid;
  v_org      uuid;
  q          record;
begin
  -- 身分：從 API 進來的只有店員能叫；操作者一律從登入身分取，不收前端的值
  perform public._api_staff_only();
  select cs.staff_id into v_staff_id from public.current_staff() cs limit 1;
  if v_staff_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff');
  end if;
  select s.org_id into v_org from public.staff s where s.id = v_staff_id;

  if p_play_at is null then
    return jsonb_build_object('ok', false, 'reason', 'play_at_required');
  end if;
  -- 改成過去的時間，房會在下一輪排程立刻流局 —— 那就不是在救這個房
  if p_play_at <= now() then
    return jsonb_build_object('ok', false, 'reason', 'play_at_in_past');
  end if;
  if p_play_at > now() + interval '7 days' then
    return jsonb_build_object('ok', false, 'reason', 'play_at_too_far');
  end if;

  select mq.id, mq.org_id, mq.status, mq.play_at, mq.matched_session_id
    into q
    from public.match_queues mq
   where mq.id = p_queue and mq.org_id = v_org
   for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  -- 流局、取消、已收桌的房不能改（改了也救不回來，而且會讓紀錄說謊）
  if q.status not in ('waiting', 'matched', 'seated') then
    return jsonb_build_object('ok', false, 'reason', 'bad_status');
  end if;
  -- 帶到桌而且已經開打：時間對它沒有意義了
  if q.status = 'seated' and exists (
       select 1 from public.table_sessions ts
        where ts.id = q.matched_session_id and ts.activated_at is not null) then
    return jsonb_build_object('ok', false, 'reason', 'already_started');
  end if;

  if q.play_at = p_play_at then
    return jsonb_build_object('ok', true, 'unchanged', true, 'play_at', p_play_at);
  end if;

  -- expires_at 跟著開打時間走（建房時的規則就是 expires_at ＝ 開打時間）
  update public.match_queues
     set play_at = p_play_at,
         expires_at = p_play_at,
         play_at_original = coalesce(play_at_original, q.play_at),
         play_at_changed_by_staff_id = v_staff_id,
         play_at_changed_at = now(),
         updated_at = now()
   where id = q.id;

  -- 通知房裡還在的人（同既有的「開打時間已更新」那一類，type = system）
  insert into public.app_notifications (org_id, member_id, type, payload, ref_id)
  select q.org_id, qp.member_id, 'system',
         jsonb_build_object(
           'text', '店家把開打時間改成 ' || to_char(p_play_at at time zone 'Asia/Taipei', 'MM/DD HH24:MI'),
           'queue_id', q.id,
           'play_at', p_play_at),
         q.id
    from public.match_queue_players qp
   where qp.queue_id = q.id and qp.left_at is null;

  return jsonb_build_object('ok', true, 'play_at', p_play_at, 'old_play_at', q.play_at);
end
$function$;

revoke execute on function public.pos_set_queue_play_at_tx(uuid, timestamptz) from public;
revoke execute on function public.pos_set_queue_play_at_tx(uuid, timestamptz) from anon;
grant  execute on function public.pos_set_queue_play_at_tx(uuid, timestamptz) to authenticated;

-- ── 3. 固定牌局的排程認「原本的開打時間」────────────────────────────
-- 撈線上全文、只換那一個判斷，換不到（或不只一處）就整份不跑
do $do$
declare
  d   text := pg_get_functiondef('public.generate_recurring_instances_tx'::regproc);
  old text := 'where recurring_id = r.id and play_at = v_play_at';
  new text := 'where recurring_id = r.id and (play_at = v_play_at or play_at_original = v_play_at)';
  n   int;
begin
  n := (length(d) - length(replace(d, old, ''))) / length(old);
  if n <> 1 then
    raise exception '固定牌局排程裡要改的那一句出現 % 次（應該是 1 次），整份不跑', n;
  end if;
  execute replace(d, old, new);
end
$do$;

-- ── 4. 報表檢視表補欄位（原本的欄位一個不動，新欄位接在最後）────────
create or replace view public.v_real_match_queues as
 SELECT x.id,
    x.org_id,
    x.store_id,
    x.stake_level_id,
    x.game_type,
    x.rounds,
    x.seats,
    x.prefs,
    x.status,
    x.opened_by,
    x.play_at,
    x.matched_at,
    x.matched_session_id,
    x.expires_at,
    x.created_at,
    x.updated_at,
    x.source,
    x.tags,
    x.recurring_id,
    x.recurring_freq,
    x.flower,
    x.open_at,
    x.auto_seat,
    x.credited_staff_id,
    x.play_at_changed_by_staff_id,
    x.play_at_changed_at,
    x.play_at_original
   FROM match_queues x
     JOIN orgs o ON o.id = x.org_id
  WHERE x.created_at >= COALESCE(o.live_from, 'infinity'::timestamp with time zone) AND NOT (EXISTS ( SELECT 1
           FROM stores s
          WHERE s.id = x.store_id AND s.is_test));

-- ── 驗證（硬規則 1.8：不用 raise，訊息用 set_config 帶到最後一支 SELECT）──
do $v$
declare
  m   text := '';
  fid oid;
  def text;
  gdef text;
  ok  boolean;
begin
  -- ① 新函式只有一個版本、是 DEFINER
  select count(*) = 1 into ok from pg_proc where proname = 'pos_set_queue_play_at_tx' and pronamespace = 'public'::regnamespace;
  select oid into fid from pg_proc where proname = 'pos_set_queue_play_at_tx' and pronamespace = 'public'::regnamespace limit 1;
  m := m || case when ok and (select prosecdef from pg_proc where oid = fid)
             then '✅ ① 新函式 1 個版本、SECURITY DEFINER' else '🔴 ① 新函式版本數或 DEFINER 不對' end || E'\n';

  -- ② 授權：authenticated 明確有；anon 明確沒有；PUBLIC 沒有（兩個方向都看，硬規則 2.6）
  m := m || case when
      exists (select 1 from aclexplode((select proacl from pg_proc where oid = fid)) a
               where a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE')
      and not exists (select 1 from aclexplode((select proacl from pg_proc where oid = fid)) a
               where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
      and not exists (select 1 from aclexplode((select proacl from pg_proc where oid = fid)) a
               where a.grantee = 0 and a.privilege_type = 'EXECUTE')
    then '✅ ② 授權：authenticated 有、anon 沒有、PUBLIC 沒有'
    else '🔴 ② 授權不對：' || coalesce((select string_agg(a.grantee::regrole::text, ',') from aclexplode((select proacl from pg_proc where oid = fid)) a), '（proacl 是 null ＝ PUBLIC 有）') end || E'\n';

  -- ③ 函式真的有問身分、真的把 expires_at 跟著改（問「有沒有呼叫／指定」，不是「有沒有提到」）
  def := pg_get_functiondef(fid);
  m := m || case when def ~ 'perform\s+public\._api_staff_only\(\)' and def ~ 'expires_at\s*=\s*p_play_at'
             then '✅ ③ 有檢查店員身分、expires_at 跟著開打時間改' else '🔴 ③ 少了身分檢查或 expires_at 沒跟著改' end || E'\n';

  -- ④ 三個稽核欄位都在
  select count(*) = 3 into ok from information_schema.columns
   where table_schema = 'public' and table_name = 'match_queues'
     and column_name in ('play_at_changed_by_staff_id', 'play_at_changed_at', 'play_at_original');
  m := m || case when ok then '✅ ④ match_queues 三個新欄位都在' else '🔴 ④ 新欄位不齊' end || E'\n';

  -- ⑤ 報表檢視表也有三個新欄位
  select count(*) = 3 into ok from information_schema.columns
   where table_schema = 'public' and table_name = 'v_real_match_queues'
     and column_name in ('play_at_changed_by_staff_id', 'play_at_changed_at', 'play_at_original');
  m := m || case when ok then '✅ ⑤ v_real_match_queues 補上三個新欄位' else '🔴 ⑤ 檢視表沒補到' end || E'\n';

  -- ⑥ 固定牌局排程：只有一個版本、判斷改成也認原本的時間
  gdef := pg_get_functiondef('public.generate_recurring_instances_tx'::regproc);
  select count(*) = 1 into ok from pg_proc where proname = 'generate_recurring_instances_tx' and pronamespace = 'public'::regnamespace;
  m := m || case when ok and gdef like '%play_at = v_play_at or play_at_original = v_play_at%'
             then '✅ ⑥ 固定牌局排程改認原本的開打時間（1 個版本）' else '🔴 ⑥ 固定牌局排程沒改到' end || E'\n';

  -- ⑦ 負對照：檢視表沒有因為重建而開放給前端（2026-09-29 收回的，不可以跑回來）
  m := m || case when not has_table_privilege('anon', 'public.v_real_match_queues', 'select')
             then '✅ ⑦ 檢視表仍然不給 anon 讀' else '🔴 ⑦ 檢視表 anon 讀得到了' end;

  perform set_config('migi.v', m, true);
end
$v$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有驗證訊息') as "驗證";
