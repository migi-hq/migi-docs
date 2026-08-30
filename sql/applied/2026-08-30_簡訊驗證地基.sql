/* ============================================================
   簡訊驗證（OTP）地基：表 ＋ 產碼 ＋ 驗碼
   2026-08-30 · 第 1 份（共 2 份）

   🚧 **這一份不動 `register_member_tx`。**
     順序：① 這份 → ② Edge Function → ③ 前端 → ④ 第 2 份（註冊時強制驗過）
     反了的話註冊會全部失敗。

   ── 為什麼註冊時就要驗（而不是「需要時再驗」）──────
   認領舊帳號要能自助，前提是**那個帳號上的手機是可信的**。
   ```
   只在撞到 phone_taken 才驗
     → 95% 的帳號手機從沒驗過
     → 那 95% 的人日後換 LINE 時手機仍然不是憑證 → 還是要找店員
   ```
   🎯 所以驗證必須發生在**號碼被寫上帳號的那一刻**。

   ── 一套機制，三個用途 ──────────────────────────────
   | purpose | 什麼時候 |
   |---|---|
   | `register` | 註冊第 2 步，必經 |
   | `claim` | 撞到「這支號碼已經是會員」時，自助認領舊帳號 |
   | `change` | 個人設定改手機 |

   ── 🔴 三個安全決定 ────────────────────────────────
   **① 不存明碼。** 存 `sha256(code:phone)`。
     明碼只存在於「產生 → 發簡訊」那一瞬間的記憶體裡。
   **② 不用 `random()`。** 它是可預測的偽隨機 ——
     知道種子就能算出下一組碼。用 `gen_random_bytes`（pgcrypto，密碼學等級）。
   **③ 一定要有嘗試次數上限。** 6 位數只有 100 萬種組合，
     沒有上限的話暴力猜解在幾分鐘內就會成功。**這一格比其他兩格都重要。**

   ⚠ pgcrypto 在 `extensions` schema，不是 `public` ——
     所以要寫 `extensions.digest` / `extensions.gen_random_bytes`。
   ============================================================ */

-- ── ① 會員的手機驗證狀態 ──────────────────────────
/* ⚠ 這一欄是「這支號碼是不是憑證」的唯一答案。
   🔴 **未驗證的手機只是聯絡方式，不可以拿來認領帳號** ——
     否則有人填了別人的號碼（C4），真正的機主反而被那個帳號擋住。
   ⚠ 既有 5 個帳號一律留 null（＝沒驗過）。那是事實，不要回填成 now()。 */
alter table members add column if not exists phone_verified_at timestamptz;
comment on column members.phone_verified_at is
  '手機通過簡訊驗證的時間。null = 未驗證（只能當聯絡方式，不能用來認領帳號）';


-- ── ② 驗證碼 ──────────────────────────────────────
create table if not exists phone_otps (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references orgs(id),
  phone         text not null,                      -- 已正規化
  code_hash     text not null,                      -- 🔴 只存雜湊，不存明碼
  purpose       text not null check (purpose in ('register','claim','change')),
  line_user_id  text,                               -- 驗簽過的 sub，用來限流
  attempts      int  not null default 0,
  sent_at       timestamptz not null default now(),
  expires_at    timestamptz not null,
  verified_at   timestamptz,                        -- 驗過的時間（給註冊那一步查）
  consumed_at   timestamptz                         -- 已經被拿去用掉（單次）
);

create index if not exists idx_phone_otps_lookup
  on phone_otps (org_id, phone, sent_at desc);
create index if not exists idx_phone_otps_line
  on phone_otps (line_user_id, sent_at desc) where line_user_id is not null;

/* 🔴 RLS：這張表裡有電話號碼與驗證碼雜湊，**任何前端都不該讀得到**。
   ⚠ 開了 RLS 又沒有任何 policy ＝ 除了 service_role（rolbypassrls）以外全部讀不到。
     那正是我們要的 —— 不是漏掉 policy，是刻意一條都不給。 */
alter table phone_otps enable row level security;


-- ── ③ 產碼 ────────────────────────────────────────
create or replace function public.otp_request_tx(
  p_org_id uuid, p_phone text, p_purpose text, p_line_user_id text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_phone text; v_b bytea; v_code text; v_recent timestamptz; v_hour int; v_line_hour int;
begin
  if p_purpose is null or p_purpose not in ('register','claim','change') then
    return jsonb_build_object('ok', false, 'reason', 'bad_purpose');
  end if;

  /* ⚠ 正規化只有這一個來源（同 `phone_in_use_tx`）——
     `0912-345-678` 與 `0912345678` 若被當成兩支號碼，
     產碼與驗碼就會對不起來，而症狀是「明明輸對了卻說錯」。 */
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

  -- 限流 ②：同一支號碼一小時 5 則（防有人一直轟炸同一個受害者）
  select count(*) into v_hour from phone_otps
   where org_id = p_org_id and phone = v_phone and sent_at > now() - interval '1 hour';
  if v_hour >= 5 then
    return jsonb_build_object('ok', false, 'reason', 'rate_limited_phone');
  end if;

  /* 限流 ③：同一個 LINE 帳號一小時 10 則
     🔴 沒有這一道，一個人可以拿同一個 LINE 帳號對**很多不同號碼**發簡訊
       —— 那是幫別人付錢做騷擾，限流 ② 完全擋不到。 */
  if p_line_user_id is not null then
    select count(*) into v_line_hour from phone_otps
     where line_user_id = p_line_user_id and sent_at > now() - interval '1 hour';
    if v_line_hour >= 10 then
      return jsonb_build_object('ok', false, 'reason', 'rate_limited_account');
    end if;
  end if;

  /* 🔴 用 `gen_random_bytes` 不用 `random()` ——
     後者是可預測的偽隨機，知道種子就能算出下一組碼。
     四個 byte 各自非負，組起來再取模，不會有 abs() 溢位的問題。 */
  v_b := extensions.gen_random_bytes(4);
  v_code := lpad(((get_byte(v_b,0)::bigint * 16777216
                 + get_byte(v_b,1) * 65536
                 + get_byte(v_b,2) * 256
                 + get_byte(v_b,3)) % 1000000)::text, 6, '0');

  -- 同一支號碼還沒用掉的舊碼一律作廢（不然新舊都能過）
  update phone_otps set consumed_at = now()
   where org_id = p_org_id and phone = v_phone and consumed_at is null;

  insert into phone_otps (org_id, phone, code_hash, purpose, line_user_id, expires_at)
  values (p_org_id, v_phone,
          encode(extensions.digest(v_code || ':' || v_phone, 'sha256'), 'hex'),
          p_purpose, p_line_user_id, now() + interval '5 minutes');

  /* ⚠ 明碼只回給呼叫端（service_role 的 Edge Function）拿去發簡訊，
     資料庫裡留下的只有雜湊。 */
  return jsonb_build_object('ok', true, 'code', v_code, 'phone', v_phone, 'expires_in', 300);
end $$;


-- ── ④ 驗碼 ────────────────────────────────────────
create or replace function public.otp_verify_tx(
  p_org_id uuid, p_phone text, p_code text, p_purpose text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_phone text; v_row phone_otps%rowtype;
begin
  v_phone := public.migi_norm_phone(p_phone);
  if v_phone is null then
    return jsonb_build_object('ok', false, 'reason', 'phone_invalid');
  end if;

  select * into v_row from phone_otps
   where org_id = p_org_id and phone = v_phone and purpose = p_purpose
     and consumed_at is null
   order by sent_at desc limit 1;

  if v_row.id is null then
    return jsonb_build_object('ok', false, 'reason', 'no_code');
  end if;
  if v_row.expires_at < now() then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;

  /* 🔴 **嘗試次數上限是這支函式最重要的一行。**
     6 位數只有 100 萬種組合 —— 沒有上限的話，
     一支腳本幾分鐘就能猜到，而前面所有的雜湊與亂數都白做。 */
  if v_row.attempts >= 5 then
    update phone_otps set consumed_at = now() where id = v_row.id;
    return jsonb_build_object('ok', false, 'reason', 'too_many_attempts');
  end if;

  update phone_otps set attempts = attempts + 1 where id = v_row.id;

  if v_row.code_hash <> encode(extensions.digest(coalesce(p_code,'') || ':' || v_phone, 'sha256'), 'hex') then
    return jsonb_build_object('ok', false, 'reason', 'wrong_code',
      'left', 5 - (v_row.attempts + 1));
  end if;

  /* ⚠ 驗過**不立刻 consume** —— 註冊要到第 4 步才建立會員，
     那時還要再查一次「這支號碼剛剛驗過」。
     consume 留給真正用掉它的那一刻（第 2 份 SQL 會做）。 */
  update phone_otps set verified_at = now() where id = v_row.id;
  return jsonb_build_object('ok', true, 'phone', v_phone);
end $$;


-- ── ⑤ 查「最近驗過沒」（給註冊那一步用）──────────
create or replace function public.phone_recently_verified_tx(
  p_org_id uuid, p_phone text, p_line_user_id text, p_purpose text default 'register')
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select exists (
    select 1 from phone_otps
     where org_id = p_org_id
       and phone = public.migi_norm_phone(p_phone)
       and purpose = p_purpose
       and verified_at is not null
       and consumed_at is null
       and verified_at > now() - interval '15 minutes'
       /* 🔴 一定要比對 line_user_id ——
          不然 A 驗過的號碼，B 可以在 15 分鐘內拿去註冊。 */
       and (p_line_user_id is null or line_user_id = p_line_user_id)
  );
$$;


/* 🔴 硬規則 2.6 ＋ 2.6b：三支全部只給 service_role。
   它們一旦讓前端叫得動就完全失效：
   · `otp_request_tx` 會**把明碼回傳** → 前端自己就能看到驗證碼
   · `otp_verify_tx` 可以被無限次呼叫繞過限流的意義
   ⚠ 兩個方向都要收（PUBLIC 繼承 ＋ default privileges 的明確授權）。 */
revoke execute on function public.otp_request_tx(uuid, text, text, text) from public;
revoke execute on function public.otp_request_tx(uuid, text, text, text) from anon, authenticated;
grant  execute on function public.otp_request_tx(uuid, text, text, text) to service_role;

revoke execute on function public.otp_verify_tx(uuid, text, text, text) from public;
revoke execute on function public.otp_verify_tx(uuid, text, text, text) from anon, authenticated;
grant  execute on function public.otp_verify_tx(uuid, text, text, text) to service_role;

revoke execute on function public.phone_recently_verified_tx(uuid, text, text, text) from public;
revoke execute on function public.phone_recently_verified_tx(uuid, text, text, text) from anon, authenticated;
grant  execute on function public.phone_recently_verified_tx(uuid, text, text, text) to service_role;


/* ============================================================
   驗證（單一 SELECT）

   🎯 在交易內跑完整的一輪：產碼 → 錯的碼 → 對的碼 → 查「驗過沒」，最後回滾。
     只看表建起來了證明不了任何事。

   正對照缺一不可：
     ② 錯的碼要**被拒絕**（否則「永遠通過」會過關）
     ④ 別人的 line_user_id 要**查不到**（否則 A 驗的碼 B 能用）
     ⑤ anon 要叫不動，但 `get_wallet_tx` 要還叫得動
   ============================================================ */
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_ph text := '0900000123'; v_r jsonb; v_code text;
  v_a text; v_b text; v_c text; v_d text; v_e text; v_f text;
begin
  v_r := otp_request_tx(v_org, v_ph, 'register', 'U_test_otp');
  v_code := v_r ->> 'code';
  v_a := case when (v_r->>'ok')::boolean and v_code ~ '^\d{6}$'
              then '✅ 產出 6 位數碼' else '🔴 ' || v_r::text end;

  v_r := otp_verify_tx(v_org, v_ph, '000000', 'register');
  v_b := case when not (v_r->>'ok')::boolean and v_r->>'reason' = 'wrong_code'
              then '✅ 被拒絕（剩 ' || coalesce(v_r->>'left','?') || ' 次）'
              else '🔴 錯的碼竟然通過了：' || v_r::text end;

  v_r := otp_verify_tx(v_org, v_ph, v_code, 'register');
  v_c := case when (v_r->>'ok')::boolean then '✅ 通過' else '🔴 ' || v_r::text end;

  v_d := case when phone_recently_verified_tx(v_org, v_ph, 'U_test_otp')
              then '✅ 查得到' else '🔴 驗過了卻查不到' end;

  v_e := case when phone_recently_verified_tx(v_org, v_ph, 'U_someone_else')
              then '🔴 別人也查得到 —— A 驗的碼 B 能用'
              else '✅ 別人查不到' end;

  -- 限流：立刻再要一次應該被擋
  v_r := otp_request_tx(v_org, v_ph, 'register', 'U_test_otp');
  v_f := case when v_r->>'reason' = 'too_soon' then '✅ 60 秒內擋住'
              else '🔴 沒擋：' || v_r::text end;

  raise exception 'rollback_on_purpose';
exception when others then
  if sqlerrm <> 'rollback_on_purpose' then
    perform set_config('migi.a', '🔴 測試本身失敗：' || sqlerrm, true);
  else
    perform set_config('migi.a', coalesce(v_a,'?'), true);
    perform set_config('migi.b', coalesce(v_b,'?'), true);
    perform set_config('migi.c', coalesce(v_c,'?'), true);
    perform set_config('migi.d', coalesce(v_d,'?'), true);
    perform set_config('migi.e', coalesce(v_e,'?'), true);
    perform set_config('migi.f', coalesce(v_f,'?'), true);
  end if;
end $$;

do $$
declare v_g text; v_h text;
begin
  begin
    set local role anon;
    begin
      perform otp_request_tx('11111111-1111-1111-1111-111111111111','0900000123','register',null);
      v_g := '🔴 anon 叫得動 —— 前端自己就看得到驗證碼';
    exception when insufficient_privilege then v_g := '✅ permission denied';
      when others then v_g := '⚠ ' || left(sqlerrm,40);
    end;
    begin
      perform get_wallet_tx('69016205-afde-4036-95a6-5893c9d0e5fe', 1);
      v_h := '✅ 還叫得動（沒有誤傷）';
    exception when insufficient_privilege then v_h := '🔴 也被擋了 —— 收過頭';
      when others then v_h := '✅ 叫得動';
    end;
    reset role;
  exception when others then reset role;
  end;
  perform set_config('migi.g', coalesce(v_g,'?'), true);
  perform set_config('migi.h', coalesce(v_h,'?'), true);
end $$;

select 序, 項目, 內容 from (
  select 1 as 序, '① 產碼' as 項目, coalesce(current_setting('migi.a',true),'🔴 沒跑到') as 內容
  union all select 2, '② 🎯 正對照：錯的碼要被拒絕', coalesce(current_setting('migi.b',true),'?')
  union all select 3, '③ 對的碼要通過', coalesce(current_setting('migi.c',true),'?')
  union all select 4, '④ 驗過之後查得到', coalesce(current_setting('migi.d',true),'?')
  union all select 5, '⑤ 🎯 正對照：別人的 LINE 查不到', coalesce(current_setting('migi.e',true),'?')
  union all select 6, '⑥ 60 秒限流', coalesce(current_setting('migi.f',true),'?')
  union all select 7, '⑦ 🎯 anon 叫不動／錢包還叫得動',
    coalesce(current_setting('migi.g',true),'?') || '　／　' || coalesce(current_setting('migi.h',true),'?')
  union all select 8, '⑧ 🎯 正對照：測試資料真的回滾了（應為 0）',
    (select count(*)::text || ' 筆 0900000123 的驗證碼　'
         || case when count(*)=0 then '✅ 乾淨' else '🔴 有殘留' end
       from phone_otps where phone = '0900000123')
) x order by 序;
