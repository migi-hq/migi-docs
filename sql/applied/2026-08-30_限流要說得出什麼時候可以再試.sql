/* ============================================================
   限流要回「還要等多久」，不要只說「請稍後再試」
   2026-08-30

   ── 問題 ────────────────────────────────────────────
   ```
   這支號碼今天要求太多次了，請稍後再試
   ```
   🔴 **「稍後」是多久？** 客人不知道要等 10 秒還是等到明天，
     只能一直按 —— 而每一次都會再被擋一次，看起來就像壞掉。
   ⚠ 而且那句話還說錯了：限流是**一小時 5 則**，不是「今天」。

   ── 修法 ────────────────────────────────────────────
   三種限流**都回 `retry_after`（秒）**，由前端換算成人話：
   | reason | 規則 | retry_after 怎麼算 |
   |---|---|---|
   | `too_soon` | 同號碼 60 秒 1 則 | 上一則 + 60 秒 |
   | `rate_limited_phone` | 同號碼 1 小時 5 則 | **第 5 新的那一則** + 1 小時 |
   | `rate_limited_account` | 同 LINE 1 小時 10 則 | 第 10 新的那一則 + 1 小時 |

   🎯 關鍵是**倒數第 N 則**而不是最新那一則：
     視窗是滑動的 —— 最舊的那一則滿一小時掉出視窗，就空出一個名額。
     用最新那一則算會多等將近一小時，而且是**錯的**。

   ── 簽名沒變 ⇒ CREATE OR REPLACE ────────────────────
   只有三個 return 多帶一個欄位，其餘邏輯一個字都沒動。
   ============================================================ */

create or replace function public.otp_request_tx(
  p_org_id uuid, p_phone text, p_purpose text, p_line_user_id text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_phone text; v_b bytea; v_code text; v_recent timestamptz;
  v_hour int; v_line_hour int; v_free_at timestamptz;
begin
  if p_purpose is null or p_purpose not in ('register','claim','change') then
    return jsonb_build_object('ok', false, 'reason', 'bad_purpose');
  end if;

  v_phone := public.migi_norm_phone(p_phone);
  if v_phone is null then
    return jsonb_build_object('ok', false, 'reason', 'phone_invalid');
  end if;

  -- 限流 ①：同一支號碼 60 秒內只發一次
  select max(sent_at) into v_recent from phone_otps
   where org_id = p_org_id and phone = v_phone;
  if v_recent is not null and v_recent > now() - interval '60 seconds' then
    return jsonb_build_object('ok', false, 'reason', 'too_soon',
      'retry_after', ceil(extract(epoch from (v_recent + interval '60 seconds' - now()))));
  end if;

  -- 限流 ②：同一支號碼一小時 5 則
  select count(*) into v_hour from phone_otps
   where org_id = p_org_id and phone = v_phone and sent_at > now() - interval '1 hour';
  if v_hour >= 5 then
    /* 🎯 **第 5 新的那一則**掉出一小時視窗時就空出名額。
       ⚠ 用 `max(sent_at)` 算的話會多等將近一小時 —— 而且是錯的。 */
    select sent_at into v_free_at from phone_otps
     where org_id = p_org_id and phone = v_phone and sent_at > now() - interval '1 hour'
     order by sent_at desc offset 4 limit 1;
    return jsonb_build_object('ok', false, 'reason', 'rate_limited_phone',
      'retry_after', greatest(1, ceil(extract(epoch from (v_free_at + interval '1 hour' - now())))));
  end if;

  -- 限流 ③：同一個 LINE 帳號一小時 10 則
  if p_line_user_id is not null then
    select count(*) into v_line_hour from phone_otps
     where line_user_id = p_line_user_id and sent_at > now() - interval '1 hour';
    if v_line_hour >= 10 then
      select sent_at into v_free_at from phone_otps
       where line_user_id = p_line_user_id and sent_at > now() - interval '1 hour'
       order by sent_at desc offset 9 limit 1;
      return jsonb_build_object('ok', false, 'reason', 'rate_limited_account',
        'retry_after', greatest(1, ceil(extract(epoch from (v_free_at + interval '1 hour' - now())))));
    end if;
  end if;

  v_b := extensions.gen_random_bytes(4);
  v_code := lpad(((get_byte(v_b,0)::bigint * 16777216
                 + get_byte(v_b,1) * 65536
                 + get_byte(v_b,2) * 256
                 + get_byte(v_b,3)) % 1000000)::text, 6, '0');

  update phone_otps set consumed_at = now()
   where org_id = p_org_id and phone = v_phone and consumed_at is null;

  insert into phone_otps (org_id, phone, code_hash, purpose, line_user_id, expires_at)
  values (p_org_id, v_phone,
          encode(extensions.digest(v_code || ':' || v_phone, 'sha256'), 'hex'),
          p_purpose, p_line_user_id, now() + interval '5 minutes');

  return jsonb_build_object('ok', true, 'code', v_code, 'phone', v_phone, 'expires_in', 300);
end $$;

revoke execute on function public.otp_request_tx(uuid, text, text, text) from public;
revoke execute on function public.otp_request_tx(uuid, text, text, text) from anon, authenticated;
grant  execute on function public.otp_request_tx(uuid, text, text, text) to service_role;


/* ============================================================
   驗證（單一 SELECT）—— 交易內造滿 5 則再問，最後回滾

   🎯 正對照缺一不可：
     ② `retry_after` 要是**正數而且小於 3600**
        （等於 3600 代表用最新那一則算的，那是錯的）
     ③ 沒被擋的情況要正常產碼（不能因為加了限流就全部擋住）
     ④ 資料真的回滾
   ============================================================ */
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_ph text := '0900000789'; v_r jsonb; v_a text; v_b text; v_c text;
begin
  -- 先造 5 則（時間往前錯開，避免撞到 60 秒那道）
  for i in 1..5 loop
    insert into phone_otps (org_id, phone, code_hash, purpose, expires_at, sent_at)
    values (v_org, v_ph, 'x', 'register', now() + interval '5 minutes',
            now() - (interval '1 minute' * (60 - i * 9)));
  end loop;

  v_r := otp_request_tx(v_org, v_ph, 'register', 'U_ratelimit_test');
  v_a := '回 ' || coalesce(v_r->>'reason','(沒被擋)')
      || '　retry_after=' || coalesce(v_r->>'retry_after','(沒給)');
  v_b := case
    when v_r->>'reason' <> 'rate_limited_phone' then '🔴 沒擋住'
    when v_r->>'retry_after' is null then '🔴 沒有回 retry_after'
    when (v_r->>'retry_after')::int <= 0 then '🔴 不是正數'
    when (v_r->>'retry_after')::int >= 3600 then '🔴 用最新那一則算的（會多等快一小時）'
    else '✅ ' || (v_r->>'retry_after') || ' 秒 ≈ '
         || round((v_r->>'retry_after')::numeric / 60) || ' 分鐘' end;

  -- 正對照：沒被擋的號碼要正常產碼
  v_r := otp_request_tx(v_org, '0900000790', 'register', 'U_ratelimit_test2');
  v_c := case when (v_r->>'ok')::boolean and (v_r->>'code') ~ '^\d{6}$'
              then '✅ 正常產碼' else '🔴 也被擋了：' || v_r::text end;

  raise exception 'rollback_on_purpose';
exception when others then
  if sqlerrm <> 'rollback_on_purpose' then
    perform set_config('migi.a', '🔴 測試本身失敗：' || sqlerrm, true);
  else
    perform set_config('migi.a', coalesce(v_a,'?'), true);
    perform set_config('migi.b', coalesce(v_b,'?'), true);
    perform set_config('migi.c', coalesce(v_c,'?'), true);
  end if;
end $$;

select 序, 項目, 內容 from (
  select 1 as 序, '① 第 6 次要求的回應' as 項目, coalesce(current_setting('migi.a',true),'🔴 沒跑到') as 內容
  union all select 2, '② 🎯 retry_after 合理嗎（正數且 < 3600）', coalesce(current_setting('migi.b',true),'?')
  union all select 3, '③ 🎯 正對照：沒被擋的號碼要正常產碼', coalesce(current_setting('migi.c',true),'?')
  union all select 4, '④ 🎯 正對照：測試資料真的回滾了（應為 0）',
    (select count(*)::text || ' 筆　' || case when count(*)=0 then '✅ 乾淨' else '🔴 有殘留' end
       from phone_otps where phone in ('0900000789','0900000790'))
) x order by 序;
