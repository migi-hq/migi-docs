-- ════════════════════════════════════════════════════════════════════
-- 2026-10-17 簡訊送達狀態（使用者：「接 MAAC Go 的 Webhooks：簡訊被退件時，告訴客人『沒送到，請稍後再試』，不用一直按重送」）
--
-- 起因：10-16 13:23 起 MAAC Go 往電信那一段送不出去（gateway_error），但 MAAC Go 是**先收下、事後才判定失敗**
--   ⇒ line-login 當下拿到成功，畫面寫「已寄出」，客人等不到碼就一直按重送（三支號碼 7 分鐘內要了 12 組）。
--
-- 這一份只做資料庫：
--   · phone_otps 多四欄：MAAC Go 的訊息 ID、送達狀態、狀態時間、失敗原因
--   · otp_set_sms_id_tx   line-login 寄出後把訊息 ID 記到「這支號碼剛發的那一組」
--   · sms_delivery_tx     sms-webhook 收到 MAAC Go 的送達／失敗通知時寫狀態
--   · otp_sms_status_tx   line-login 給會員 App 查「我剛要的那組碼送到了沒」——
--                         🔒 只回**同一個 LINE 帳號**要的那一組，別人拿號碼來問查不到東西
-- 三支都只給 service_role（Edge Function 用），前端叫不到（2026-09-29 起新函式預設全關，這裡再明寫一次）
-- ════════════════════════════════════════════════════════════════════

alter table public.phone_otps
  add column if not exists sms_message_id  text,
  add column if not exists sms_status      text,          -- sent（MAAC Go 收下）／delivered／failed；null ＝ 還不知道（舊資料、或簡訊商回應裡沒有 ID）
  add column if not exists sms_status_at   timestamptz,
  add column if not exists sms_fail_reason text;
comment on column public.phone_otps.sms_message_id is 'MAAC Go 回的訊息 ID（sms_xxx），用來對上送達／失敗通知（2026-10-17）';
comment on column public.phone_otps.sms_status is '簡訊送達狀態：sent＝簡訊商收下、delivered＝送達、failed＝失敗（2026-10-17）';

create unique index if not exists uq_phone_otps_sms_message on public.phone_otps (sms_message_id) where sms_message_id is not null;

-- ① 寄出後記下訊息 ID：「這支號碼、這個 LINE、還沒作廢、兩分鐘內發的」最新那一組
create or replace function public.otp_set_sms_id_tx(p_org_id uuid, p_phone text, p_line_user_id text, p_message_id text)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_phone text; v_id uuid;
begin
  v_phone := public.migi_norm_phone(p_phone);
  if v_phone is null or coalesce(p_message_id, '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'bad_input');
  end if;
  select id into v_id from phone_otps
   where org_id = p_org_id and phone = v_phone and consumed_at is null
     and line_user_id is not distinct from p_line_user_id
     and sent_at > now() - interval '2 minutes'
   order by sent_at desc limit 1;
  if v_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  update phone_otps set sms_message_id = p_message_id,
         sms_status = coalesce(sms_status, 'sent'), sms_status_at = coalesce(sms_status_at, now())
   where id = v_id;
  return jsonb_build_object('ok', true);
end $function$;

-- ② 送達／失敗通知：用訊息 ID 對上那一組。
--    ⚠ 通知可能比 ① 先到（MAAC Go 很快就判定失敗、line-login 還沒寫 ID）⇒ 對不上就回 matched 0，
--      sms-webhook 回 200 不重送也沒關係：會員 App 查不到失敗只是少一句提示，不會更糟
--    ⚠ delivered 不蓋掉 failed、failed 也不蓋掉 delivered —— 先到的終點狀態算數（重送的通知不會把結果翻過來）
create or replace function public.sms_delivery_tx(p_message_id text, p_status text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_n int;
begin
  if coalesce(p_message_id, '') = '' or p_status not in ('delivered', 'failed', 'sent') then
    return jsonb_build_object('ok', false, 'reason', 'bad_input');
  end if;
  update phone_otps set sms_status = p_status, sms_status_at = now(),
         sms_fail_reason = case when p_status = 'failed' then left(coalesce(p_reason, ''), 200) else sms_fail_reason end
   where sms_message_id = p_message_id
     and coalesce(sms_status, 'sent') not in ('delivered', 'failed');
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'matched', v_n);
end $function$;

-- ③ 會員 App 問「我剛要的那組碼送到了沒」：同一支號碼、同一個 LINE、還沒作廢的最新一組
create or replace function public.otp_sms_status_tx(p_org_id uuid, p_phone text, p_line_user_id text)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_phone text; r phone_otps;
begin
  v_phone := public.migi_norm_phone(p_phone);
  if v_phone is null or p_line_user_id is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_input');
  end if;
  select * into r from phone_otps
   where org_id = p_org_id and phone = v_phone and line_user_id = p_line_user_id and consumed_at is null
   order by sent_at desc limit 1;
  if r.id is null then
    return jsonb_build_object('ok', true, 'status', null);
  end if;
  return jsonb_build_object('ok', true, 'status', r.sms_status, 'verified', r.verified_at is not null,
                            'sent_at', r.sent_at);
end $function$;

revoke all on function public.otp_set_sms_id_tx(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.sms_delivery_tx(text, text, text)          from public, anon, authenticated;
revoke all on function public.otp_sms_status_tx(uuid, text, text)        from public, anon, authenticated;
grant execute on function public.otp_set_sms_id_tx(uuid, text, text, text) to service_role;
grant execute on function public.sms_delivery_tx(text, text, text)          to service_role;
grant execute on function public.otp_sms_status_tx(uuid, text, text)        to service_role;

-- ════════════ 驗證（單一 SELECT，不 raise）════════════
select string_agg(x, E'\n' order by n) as "驗證" from (
  select 1 n, case when (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'phone_otps'
                          and column_name in ('sms_message_id', 'sms_status', 'sms_status_at', 'sms_fail_reason')) = 4
              then '✅ ① phone_otps 多了四欄' else '🔴 ① 欄位不齊' end x
  union all
  select 2, case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
                        and proname in ('otp_set_sms_id_tx', 'sms_delivery_tx', 'otp_sms_status_tx')) = 3
              then '✅ ② 三支函式都在、各一個版本' else '🔴 ② 函式數量不對' end
  union all
  select 3, case when not has_function_privilege('anon', 'public.otp_sms_status_tx(uuid, text, text)', 'execute')
                  and not has_function_privilege('authenticated', 'public.sms_delivery_tx(text, text, text)', 'execute')
                  and has_function_privilege('service_role', 'public.otp_set_sms_id_tx(uuid, text, text, text)', 'execute')
              then '✅ ③ 只有 service_role 叫得動（前端叫不到）' else '🔴 ③ 權限不對' end
  union all
  select 4, case when exists (select 1 from pg_indexes where indexname = 'uq_phone_otps_sms_message')
              then '✅ ④ 訊息 ID 唯一索引在' else '🔴 ④ 索引不在' end
) t;
