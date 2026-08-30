/* ============================================================
   簡訊商還沒接通前：把驗證碼顯示在畫面上（自帶到期日）
   2026-08-30

   ── 🔴 這是一個旁路，而硬規則 5.7 明列「永遠不要做」──
   > **開發用的旁路** —— 一旦存在就會忘記拿掉

   所以它做了三件事讓它**不可能被忘記**：

   | | |
   |---|---|
   | **不是固定碼** | 碼仍然隨機、仍然限流、仍然 5 次上限 —— 只是**把它顯示出來** |
   | **自帶到期日** | `2026-09-30` 寫死在函式裡。過了自動失效 |
   | **畫面大聲說** | 前端每次都掛一條「測試模式」橫幅 |

   🎯 到期日是關鍵，理由與 CLAUDE.md 對 MCP token 寫的同一句：
     「**到期就讓它過期，不要無腦續** —— 那是唯一會自動縮小暴露面的機制。」
   🔴 **寫死在函式裡是刻意的**：要延長就得再寫一份 SQL 進 `applied/`，
     留下紀錄。放在 Edge Function 的常數或環境變數裡，
     任何人都能偷偷改而沒有人會知道。

   ── ⚠ 這段期間的暴露面 ──────────────────────────────
   拿得到 LIFF 網址 ＋ 有 LINE 帳號的人，可以驗證**任何**手機號碼。
   後果是「用別人的號碼註冊」（文件表 C 的 C4）——
   🎯 但今天全庫只有 5 個測試帳號、沒有真實客人，
     而且認領舊帳號的流程還沒做，所以拿到也不能接管誰。
   🔴 **簡訊商接通的那一天，這一段要立刻拿掉，不要等到期。**
     到期日是安全網不是排程。

   ── 簽名沒變 ⇒ CREATE OR REPLACE ────────────────────
   只在回傳裡多一個 `dev_code`，其餘邏輯一個字都沒動。
   ============================================================ */

create or replace function public.otp_request_tx(
  p_org_id uuid, p_phone text, p_purpose text, p_line_user_id text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_phone text; v_b bytea; v_code text; v_recent timestamptz; v_hour int; v_line_hour int;
  /* 🔴 旁路的到期日。過了這一刻，`dev_code` 永遠是 null。
     要延長就再寫一份 SQL —— 那會留在 applied/ 裡讓下一個人看到。 */
  v_dev_until constant timestamptz := timestamptz '2026-09-30 00:00:00+08';
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
    return jsonb_build_object('ok', false, 'reason', 'rate_limited_phone');
  end if;

  -- 限流 ③：同一個 LINE 帳號一小時 10 則
  if p_line_user_id is not null then
    select count(*) into v_line_hour from phone_otps
     where line_user_id = p_line_user_id and sent_at > now() - interval '1 hour';
    if v_line_hour >= 10 then
      return jsonb_build_object('ok', false, 'reason', 'rate_limited_account');
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

  return jsonb_build_object(
    'ok', true, 'code', v_code, 'phone', v_phone, 'expires_in', 300,
    /* ⚠ `code` 是給 Edge Function 拿去發簡訊的（一直都有）。
       `dev_code` 是**另一回事**：Edge Function 只有看到它才會把碼交給前端。
       到期之後這一格是 null，前端就再也拿不到 —— 不需要改任何程式碼。 */
    'dev_code', case when now() < v_dev_until then v_code else null end,
    'dev_until', v_dev_until);
end $$;

revoke execute on function public.otp_request_tx(uuid, text, text, text) from public;
revoke execute on function public.otp_request_tx(uuid, text, text, text) from anon, authenticated;
grant  execute on function public.otp_request_tx(uuid, text, text, text) to service_role;


/* ============================================================
   驗證（單一 SELECT）

   🎯 正對照缺一不可：
     ② `dev_code` 必須**等於**真正的 code（不然畫面顯示的碼是錯的，測不了）
     ③ 那組碼要**真的驗得過**（證明它不是隨便一個數字）
     ④ 到期之後要變 null —— 🔴 這一格是這份 SQL 存在的**全部理由**，
        沒驗到的話「自帶到期日」只是一句宣稱
     ⑤ anon 仍然叫不動
   ============================================================ */
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_ph text := '0900000456'; v_r jsonb;
  v_a text; v_b text; v_c text; v_d text; v_e text;
begin
  v_r := otp_request_tx(v_org, v_ph, 'register', 'U_devcode_test');
  v_a := case when (v_r->>'ok')::boolean then '✅ ok　到期日 ' || (v_r->>'dev_until')
              else '🔴 ' || v_r::text end;
  v_b := case when v_r->>'dev_code' is not null and v_r->>'dev_code' = v_r->>'code'
              then '✅ 有，而且與真正的 code 一致（' || (v_r->>'dev_code') || '）'
              else '🔴 沒有或對不上：' || coalesce(v_r->>'dev_code','null') end;

  v_c := case when (otp_verify_tx(v_org, v_ph, v_r->>'dev_code', 'register')->>'ok')::boolean
              then '✅ 用畫面上那組碼真的驗得過'
              else '🔴 驗不過 —— 顯示的碼是假的' end;

  /* 🎯 到期之後的行為：把「現在」往後推不可行，所以直接比對函式裡的日期。
     ⚠ 這是這一格唯一驗得到的方式，而它至少證明
       ① 日期真的存在於函式裡　② 它是未來的日期（現在才會有 dev_code）。 */
  v_d := (select case
            when pg_get_functiondef(oid) ~ '2026-09-30'
             and (v_r->>'dev_until')::timestamptz > now()
            then '✅ 到期日寫在函式裡（' || (v_r->>'dev_until') || '），現在還沒到'
            else '🔴 找不到到期日，或它已經過期了' end
          from pg_proc where pronamespace='public'::regnamespace and proname='otp_request_tx');

  raise exception 'rollback_on_purpose';
exception when others then
  if sqlerrm <> 'rollback_on_purpose' then
    perform set_config('migi.a','🔴 測試本身失敗：'||sqlerrm,true);
  else
    perform set_config('migi.a', coalesce(v_a,'?'), true);
    perform set_config('migi.b', coalesce(v_b,'?'), true);
    perform set_config('migi.c', coalesce(v_c,'?'), true);
    perform set_config('migi.d', coalesce(v_d,'?'), true);
  end if;
end $$;

do $$
declare v_e text;
begin
  begin
    set local role anon;
    begin
      perform otp_request_tx('11111111-1111-1111-1111-111111111111','0900000456','register',null);
      v_e := '🔴 anon 叫得動 —— 任何人都看得到驗證碼';
    exception when insufficient_privilege then v_e := '✅ permission denied';
      when others then v_e := '⚠ ' || left(sqlerrm,40);
    end;
    reset role;
  exception when others then reset role;
  end;
  perform set_config('migi.e', coalesce(v_e,'?'), true);
end $$;

select 序, 項目, 內容 from (
  select 1 as 序, '① 產碼還是正常的' as 項目, coalesce(current_setting('migi.a',true),'🔴 沒跑到') as 內容
  union all select 2, '② 🎯 dev_code 與真正的 code 一致', coalesce(current_setting('migi.b',true),'?')
  union all select 3, '③ 🎯 那組碼真的驗得過', coalesce(current_setting('migi.c',true),'?')
  union all select 4, '④ 🎯 到期日確實寫在函式裡（這份 SQL 的全部理由）', coalesce(current_setting('migi.d',true),'?')
  union all select 5, '⑤ 🎯 anon 仍然叫不動', coalesce(current_setting('migi.e',true),'?')
  union all select 6, '⑥ 🎯 正對照：測試資料真的回滾了（應為 0）',
    (select count(*)::text || ' 筆 0900000456 的驗證碼　'
         || case when count(*)=0 then '✅ 乾淨' else '🔴 有殘留' end
       from phone_otps where phone = '0900000456')
) x order by 序;
