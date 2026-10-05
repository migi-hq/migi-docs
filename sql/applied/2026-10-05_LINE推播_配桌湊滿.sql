/* ============================================================
   LINE 推播 · 第一種：配桌湊滿了
   2026-10-05 · MIGI 咪吉麻將

   ── 為什麼要做 ──────────────────────────────────────
   配桌最關鍵的一則訊息是「你的牌局湊滿了」。站內通知要客人自己打開 App 才看得到，
   而報名之後他通常去上班、吃飯了 ⇒ 湊滿那一刻沒有人知道（CLAUDE.md 待辦 38）。
   LINE 推播不需要 App 開著。

   ── 架構：寄件匣（outbox），不在交易裡直接打 LINE ─────────
   ```
   _finalize_queue_full_tx 寫 app_notifications（table_ok）   ← 這支一行都沒改
        │ 觸發器（每個陳述式一次）
        ▼
   notification_deliveries 一人一列 pending      ← 跟通知在同一個交易，回滾就一起消失
        │ 同一個觸發器順手叫 _push_kick() → pg_net 非同步打 Edge Function
        │ ＋ pg_cron 每分鐘再踢一次（補送、重試、卡住的退回）
        ▼
   Edge Function line-push：push_claim_tx 取件 → 查是不是好友 → 推播 → push_report_tx 回報
   ```
   🎯 為什麼不在交易裡直接打 LINE：
     ① 交易回滾了訊息卻已經送出（客人收到「湊滿了」，房其實沒湊滿）
     ② LINE 慢或掛了會拖住配桌的交易
     ③ 失敗沒有地方重試，也沒有紀錄
   ⇒ 寄件匣讓「要送」跟配桌同生同死，「送出」另外做、可以重試、每一筆都有結果。

   ── 每一筆最後一定落在四種結果之一 ─────────────────
   sent      LINE 收下了（存 x-line-request-id）
   skipped   刻意不送：沒有 LINE id／id 不是真的（測試帳號）／帳號隱藏或刪除／
             沒加官方帳號好友／牌局已經過時或取消
   failed    送不出去而且不再試：LINE 回 4xx、本月免費則數用完、重試 5 次都失敗
   pending   還在等（重試的退避：1、2、4、8 分鐘）
   ⚠ 「沒加好友」先用 LINE 的取得個人資料 API 查（免費、不吃則數）——
     直接推的話 LINE 一樣回 200，訊息卻沒送到，而且會不會扣則數官方沒寫清楚。

   ── 防重複送 ────────────────────────────────────────
   每一筆有自己的 retry_key，Edge Function 送的時候帶 X-Line-Retry-Key。
   ⇒ 送到一半斷線、重試、卡住被退回再送，LINE 都只會送一次（重複的回 409，當成已送）。

   ── 身分與權限 ──────────────────────────────────────
   · 寄件匣表開 RLS、0 條 policy、anon／authenticated 沒有任何權限（只有 DEFINER 進得去）
   · push_claim_tx／push_report_tx 只給 service_role（Edge Function 用）
   · 另外再要一把「工人鑰匙」：pg_cron 打 Edge Function 時放在 header，取件時比對 vault 裡那一份。
     🎯 鑰匙**在資料庫裡隨機產生**，人碰不到、不用複製貼上；
       Edge Function 不用開 Verify JWT，別人亂打它只會拿到空陣列。
   · LINE 的 channel access token **不進資料庫**，只放 Edge Function 的 Secrets（LINE_MESSAGING_TOKEN）。

   ── 刻意先不做 ──────────────────────────────────────
   · 其他通知（牌咖邀請、牌咖團、結算）先不推 —— 白名單只有 table_ok，要加就改 _push_enqueue 那一行，
     但每加一種都會吃免費則數（輕用量每月 200 則，一桌湊滿就是 4 則）
   · 客人自己的推播開關（通知系統規格 §9，上線前要有；行銷類一定要能關）
   · 用 webhook 記「誰加了好友／封鎖」—— 現在每次送之前即時查，量小夠用

   ⚠ 部署順序：這份 → Edge Function line-push（Verify JWT 關掉）→ Secrets 放 LINE_MESSAGING_TOKEN。
     順序反了也不會壞：Edge Function 還沒部署時 pg_net 打過去是 404，寄件匣的列留在 pending，
     部署好之後下一分鐘就會被送出去（而過時的會被標成 skipped，不會半夜補送昨天的牌局）。
   ============================================================ */

-- ① pg_net：讓資料庫能非同步發 HTTP（請求在交易提交後才真的送出，回滾就不送）
create extension if not exists pg_net with schema extensions;

-- ② 寄件匣
create table if not exists public.notification_deliveries (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.orgs(id),
  -- 🔴 刻意不放 member_id：誰收從通知那一列查。指向 members 的外鍵已經 40 個，
  --    每多一個，日後會員合併就多一個要搬的欄位（CLAUDE.md 待辦 15）
  notification_id uuid not null references public.app_notifications(id) on delete cascade,
  channel         text not null default 'line' check (channel in ('line')),
  status          text not null default 'pending'
                  check (status in ('pending', 'sending', 'sent', 'skipped', 'failed')),
  reason          text,                      -- skipped／failed 的原因（no_line／bad_line_id／member_gone／not_friend／stale／quota／http_4xx／too_many_attempts）
  attempts        int  not null default 0,
  next_try_at     timestamptz not null default now(),
  claimed_at      timestamptz,
  retry_key       uuid not null default gen_random_uuid(),   -- 送 LINE 時的 X-Line-Retry-Key
  http_status     int,
  line_request_id text,
  last_error      text,
  sent_at         timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (notification_id, channel)
);
create index if not exists idx_deliveries_due on public.notification_deliveries (next_try_at) where status = 'pending';
create index if not exists idx_deliveries_month on public.notification_deliveries (created_at);

comment on table public.notification_deliveries is
  'LINE 推播寄件匣：一則站內通知一個管道一列。狀態 pending→sending→sent／skipped／failed。'
  '寫入只有觸發器 _push_enqueue；取件與回報只有 Edge Function line-push（service_role）。';

alter table public.notification_deliveries enable row level security;
revoke all on public.notification_deliveries from public, anon, authenticated;

-- ③ 工人鑰匙：資料庫自己產生，沒有人看過它
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'push_worker_key') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'push_worker_key',
      'pg_cron／觸發器打 Edge Function line-push 時放在 x-migi-worker-key；push_claim_tx 比對這一份');
  end if;
end $$;

-- ④ 踢一下 Edge Function：有到期的待送才打，沒有就什麼都不做
create or replace function public._push_kick()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_key text;
begin
  if not exists (select 1 from notification_deliveries
                  where (status = 'pending' and next_try_at <= now())
                     or (status = 'sending' and claimed_at < now() - interval '5 minutes')) then
    return;
  end if;
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'push_worker_key';
  perform net.http_post(
    url     := 'https://roksgepxxmcewlkshtzn.supabase.co/functions/v1/line-push',
    body    := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-migi-worker-key', v_key),
    timeout_milliseconds := 10000);
end $$;

revoke execute on function public._push_kick() from public, anon, authenticated;

-- ⑤ 觸發器：通知寫進來 → 白名單內的類型排進寄件匣 → 踢一下
--    🎯 每個陳述式一次（transition table）：一桌四個人是一個 insert，只打一次 HTTP
create or replace function public._push_enqueue()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_n int;
begin
  insert into notification_deliveries (org_id, notification_id, channel)
  select nr.org_id, nr.id, 'line'
    from new_rows nr
   where nr.type in ('table_ok')          -- 🔴 白名單：要推哪一種通知就加在這裡（每一種都吃免費則數）
  on conflict (notification_id, channel) do nothing;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    perform _push_kick();
  end if;
  return null;
end $$;

revoke execute on function public._push_enqueue() from public, anon, authenticated;

drop trigger if exists trg_app_notifications_push on public.app_notifications;
create trigger trg_app_notifications_push
  after insert on public.app_notifications
  referencing new table as new_rows
  for each statement execute function public._push_enqueue();

-- ⑥ 訊息內容：送的那一刻才組（自動帶桌在通知之後才發生，這時桌號才查得到）
create or replace function public._push_text(p_notif uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  n app_notifications%rowtype;
  q record;
  v_tbl text; v_others text; v_when text; v_d date;
  v_today date := (now() at time zone 'Asia/Taipei')::date;
begin
  select * into n from app_notifications where id = p_notif;
  if n.id is null or n.type <> 'table_ok' then return null; end if;

  select mq.id, mq.play_at, mq.matched_session_id, s.name as store_name into q
    from match_queues mq left join stores s on s.id = mq.store_id
   where mq.id = coalesce((n.payload ->> 'queue_id')::uuid, n.ref_id);
  if q.id is null then return null; end if;

  select t.label into v_tbl
    from table_sessions ts join tables t on t.id = ts.table_id
   where ts.id = q.matched_session_id and ts.status = 'open';

  -- 隱藏的會員名字已經是「隱藏的會員」（隱藏時就換掉了），這裡不用另外判斷
  select string_agg(m.display_name, '、' order by qp.joined_at) into v_others
    from match_queue_players qp join members m on m.id = qp.member_id
   where qp.queue_id = q.id and qp.left_at is null and qp.member_id <> n.member_id;

  if q.play_at is null then
    v_when := '湊滿就開打';
  else
    v_d := (q.play_at at time zone 'Asia/Taipei')::date;
    -- 「今天 21:00」中間空一格；「10/8（四）21:00」全形括號後面不再空格
    v_when := case when v_d = v_today then '今天 '
                   when v_d = v_today + 1 then '明天 '
                   else to_char(v_d, 'FMMM/FMDD') || '（' ||
                        (array['日','一','二','三','四','五','六'])[extract(dow from v_d)::int + 1] || '）'
              end || to_char(q.play_at at time zone 'Asia/Taipei', 'HH24:MI') || ' 開打';
  end if;

  return concat_ws(E'\n',
    case when n.payload ->> 'test' = 'true' then '【推播測試】' end,
    '你的牌局湊滿了！',
    '時間：' || v_when,
    '地點：' || coalesce(q.store_name, 'MIGI') || coalesce(' · ' || v_tbl || ' 桌', ''),
    case when v_others is not null then '同桌：' || v_others end,
    '請準時到店，到櫃檯報到就能入座。',
    '查看牌局：https://liff.line.me/2011312117-Zuul0Ndo');
end $$;

revoke execute on function public._push_text(uuid) from public, anon, authenticated;

-- ⑦ 取件（Edge Function 呼叫）：鑰匙對了才給；不該送的當場標 skipped，該送的標 sending 交出去
create or replace function public.push_claim_tx(p_key text, p_limit int default 20)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_out jsonb := '[]'::jsonb;
  r record;
  v_to text; v_gone boolean; v_q record; v_text text; v_skip text;
begin
  if p_key is null or not exists (select 1 from vault.decrypted_secrets
                                   where name = 'push_worker_key' and decrypted_secret = p_key) then
    return '[]'::jsonb;
  end if;

  -- 卡在 sending 超過 5 分鐘（Edge Function 中途掛掉）→ 退回 pending。同一把 retry_key，LINE 不會重複送
  update notification_deliveries
     set status = 'pending', claimed_at = null, updated_at = now()
   where status = 'sending' and claimed_at < now() - interval '5 minutes';

  for r in
    select d.id, d.retry_key, n.id as nid, n.member_id, n.created_at as n_at, n.payload, n.ref_id
      from notification_deliveries d
      join app_notifications n on n.id = d.notification_id
     where d.status = 'pending' and d.next_try_at <= now()
     order by d.created_at
     limit greatest(1, least(coalesce(p_limit, 20), 50))
       for update of d skip locked
  loop
    v_skip := null;
    select m.line_user_id, (m.deleted_at is not null or m.hidden_at is not null)
      into v_to, v_gone
      from members m where m.id = r.member_id;

    select mq.status, mq.play_at into v_q
      from match_queues mq where mq.id = coalesce((r.payload ->> 'queue_id')::uuid, r.ref_id);

    if v_gone then
      v_skip := 'member_gone';
    elsif v_to is null then
      v_skip := 'no_line';
    elsif v_to !~ '^U[0-9a-f]{32}$' then
      v_skip := 'bad_line_id';                -- 測試帳號的假 id（TEST…）
    elsif coalesce(r.payload ->> 'test', '') <> 'true' and (
            v_q.status is null or v_q.status not in ('matched', 'seated')
            or v_q.play_at < now() - interval '30 minutes'
            or r.n_at < now() - interval '6 hours') then
      v_skip := 'stale';                      -- 房取消了、牌局已經過了、或塞太久 —— 不要半夜補送昨天的牌局
    end if;

    if v_skip is null then
      v_text := _push_text(r.nid);
      if v_text is null then v_skip := 'stale'; end if;
    end if;

    if v_skip is not null then
      update notification_deliveries
         set status = 'skipped', reason = v_skip, updated_at = now()
       where id = r.id;
    else
      update notification_deliveries
         set status = 'sending', claimed_at = now(), attempts = attempts + 1, updated_at = now()
       where id = r.id;
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'id', r.id, 'to', v_to, 'retry_key', r.retry_key, 'text', v_text));
    end if;
  end loop;

  return v_out;
end $$;

-- ⑧ 回報（Edge Function 呼叫）
--    p_outcome ∈ sent／skipped／failed／retry
create or replace function public.push_report_tx(
  p_key text, p_id uuid, p_outcome text,
  p_http int default null, p_reason text default null,
  p_request_id text default null, p_error text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_att int;
begin
  if p_key is null or not exists (select 1 from vault.decrypted_secrets
                                   where name = 'push_worker_key' and decrypted_secret = p_key) then
    return jsonb_build_object('ok', false, 'reason', 'forbidden');
  end if;
  if p_outcome not in ('sent', 'skipped', 'failed', 'retry') then
    return jsonb_build_object('ok', false, 'reason', 'bad_outcome');
  end if;

  select attempts into v_att from notification_deliveries where id = p_id and status = 'sending' for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_sending');   -- 已經被別人處理掉了（或被退回 pending）
  end if;

  if p_outcome = 'retry' and v_att >= 5 then
    p_outcome := 'failed'; p_reason := 'too_many_attempts';
  end if;

  update notification_deliveries
     set status          = case when p_outcome = 'retry' then 'pending' else p_outcome end,
         reason          = case when p_outcome = 'sent' then null else coalesce(p_reason, reason) end,
         next_try_at     = case when p_outcome = 'retry' then now() + make_interval(mins => power(2, v_att - 1)::int) else next_try_at end,
         claimed_at      = null,
         http_status     = coalesce(p_http, http_status),
         line_request_id = coalesce(p_request_id, line_request_id),
         last_error      = case when p_outcome = 'sent' then null else left(coalesce(p_error, last_error), 500) end,
         sent_at         = case when p_outcome = 'sent' then now() else sent_at end,
         updated_at      = now()
   where id = p_id;

  return jsonb_build_object('ok', true, 'status', case when p_outcome = 'retry' then 'pending' else p_outcome end);
end $$;

-- 只給 Edge Function（service_role）。09-29 之後新建的預設就是關的，這裡照硬規則 2.6b 兩個方向都寫明
revoke execute on function public.push_claim_tx(text, int) from public, anon, authenticated;
revoke execute on function public.push_report_tx(text, uuid, text, int, text, text, text) from public, anon, authenticated;
grant  execute on function public.push_claim_tx(text, int) to service_role;
grant  execute on function public.push_report_tx(text, uuid, text, int, text, text, text) to service_role;

-- ⑨ 每分鐘補踢一次：觸發器那一次沒打到（Edge Function 還沒部署、LINE 暫時掛掉）時，靠這個重試
do $$
begin
  if exists (select 1 from cron.job where jobname = 'line-push-sweep') then
    perform cron.unschedule('line-push-sweep');
  end if;
  perform cron.schedule('line-push-sweep', '* * * * *', 'select public._push_kick()');
end $$;

/* ============================================================
   驗證（單一 SELECT，不 raise —— 硬規則 1.8）
   🔴 這一段驗的是「交易內的狀態」。跑完之後我會另外查一次線上，才算數。
   行為測試（造通知 → 取件 → 回報）在 sql/checks/2026-10-05_驗LINE推播寄件匣.sql，那份會回滾。
   ============================================================ */
select concat_ws(E'\n',
  case when exists (select 1 from pg_extension where extname = 'pg_net')
            and to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is not null
       then '✅ ① pg_net 已啟用，net.http_post 在'
       else '🔴 ① pg_net 沒裝好' end,
  case when (select relrowsecurity from pg_class where oid = 'public.notification_deliveries'::regclass)
            and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'notification_deliveries')
            and not has_table_privilege('anon', 'public.notification_deliveries', 'select')
            and not has_table_privilege('authenticated', 'public.notification_deliveries', 'select')
       then '✅ ② 寄件匣：RLS 開、0 條 policy、anon 與 authenticated 讀不到'
       else '🔴 ② 寄件匣的權限不對' end,
  case when exists (select 1 from pg_trigger where tgname = 'trg_app_notifications_push'
                      and tgrelid = 'public.app_notifications'::regclass and not tgisinternal)
       then '✅ ③ 通知表的觸發器在' else '🔴 ③ 觸發器不見了' end,
  case when exists (select 1 from vault.secrets where name = 'push_worker_key')
       then '✅ ④ 工人鑰匙已在 vault（值沒有印出來）' else '🔴 ④ 工人鑰匙沒建' end,
  case when exists (select 1 from cron.job where jobname = 'line-push-sweep' and active and schedule = '* * * * *')
       then '✅ ⑤ 每分鐘補送的排程在' else '🔴 ⑤ 排程沒建' end,
  (select case when bool_and(has_function_privilege('service_role', p.oid, 'execute'))
                and not bool_or(has_function_privilege('anon', p.oid, 'execute'))
                and not bool_or(has_function_privilege('authenticated', p.oid, 'execute'))
                and not bool_or(exists (select 1 from aclexplode(coalesce(p.proacl, '{}')) a
                                         where a.grantee = 0 and a.privilege_type = 'EXECUTE') or p.proacl is null)
               then '✅ ⑥ 取件與回報只有 service_role 叫得動（anon、authenticated、PUBLIC 都沒有）'
               else '🔴 ⑥ 取件／回報的授權不對' end
     from pg_proc p where p.oid in ('public.push_claim_tx(text,int)'::regprocedure,
                                    'public.push_report_tx(text,uuid,text,int,text,text,text)'::regprocedure)),
  case when public.push_claim_tx('不是那把鑰匙', 5) = '[]'::jsonb
        and (public.push_report_tx('不是那把鑰匙', gen_random_uuid(), 'sent') ->> 'reason') = 'forbidden'
       then '✅ ⑦ 鑰匙不對：取件拿到空陣列、回報被拒（負對照；正對照在行為測試那份）'
       else '🔴 ⑦ 鑰匙不對卻沒被擋' end,
  coalesce((select '✅ ⑧ 訊息組得出來（拿最近一個房試）：' || replace(public._push_text(n.id), E'\n', ' ／ ')
              from app_notifications n where n.type = 'table_ok' order by n.created_at desc limit 1),
           '⚪ ⑧ 線上還沒有 table_ok 通知可以試，行為測試那份會自己造')
) as "驗證";
