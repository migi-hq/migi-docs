-- ============================================================
-- 管理後台發手機計分配對碼（不用等成桌通知）
-- 2026-10-13 · MIGI 咪吉麻將
--
-- 使用者：「除了成桌通知，可以從管理後台生成手機配對碼與連結嗎」
--   用途：現場直接開桌、包桌的客人沒有成桌通知；或客人換手機、刪了主畫面圖示要重新配對。
--
-- 規則：
--   · 總部權限（can('device.write')，跟配對、停用平板同一個碼）
--   · 發的是**永久配對**的碼（不綁某一場）：同成桌通知那一種，24 小時內有效、用一次
--   · 同一位會員由後台再發一次 ⇒ 舊的那組（後台發、還沒用的）立刻作廢，只留最新一組
--   · 隱藏中的會員不發
--   · 記下是哪位店員發的：table_phone_codes.issued_by_staff_id（身分一律 current_staff()，不收前端傳的）
--   · 回傳配對碼 ＋ 連結（table.migi.tw/?install=1&code=…）：Android 打開會自動填好；iPhone 會先教加到主畫面，
--     並把這組碼印在教學頁上，加完從主畫面打開再輸入
-- 找會員沿用「會員」頁那支 admin_find_members_tx（用手機號碼找），不另開一支。
-- ============================================================

alter table public.table_phone_codes add column if not exists issued_by_staff_id uuid references public.staff(id);
comment on column public.table_phone_codes.issued_by_staff_id is
  '管理後台發的配對碼：是哪位店員發的（2026-10-13）。成桌通知與平板發的是 null';

create or replace function public.admin_phone_code_tx(p_member_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_staff uuid := (select staff_id from public.current_staff());
  v_org uuid;
  m public.members;
  v_code text;
  v_exp timestamptz := now() + interval '24 hours';
begin
  if v_staff is null or not public.can('device.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '發配對碼是總部的權限');
  end if;
  select org_id into v_org from staff where id = v_staff;

  select * into m from members where id = p_member_id and org_id = v_org and deleted_at is null;
  if m.id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這位會員');
  end if;
  if m.hidden_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'hidden', 'message', '這位會員已經隱藏帳號，要先恢復才能發配對碼');
  end if;

  -- 同一位會員：後台發過、還沒用的舊碼作廢（成桌通知與平板發的不動）
  update table_phone_codes set expires_at = now()
   where member_id = m.id and issued_by_staff_id is not null and used_at is null and expires_at > now();

  v_code := public._tbl_new_phone_code(v_org, m.id, null, null, null, v_exp);
  update table_phone_codes set issued_by_staff_id = v_staff
   where code = v_code and member_id = m.id and used_at is null and expires_at = v_exp;

  return jsonb_build_object('ok', true, 'code', v_code, 'name', m.display_name, 'expires_at', v_exp,
    'url', 'https://table.migi.tw/?install=1&code=' || v_code);
end $function$;

-- 2026-09-29 起新建的函式預設全關（硬規則 2.7）⇒ 後台要叫得到就明確開給 authenticated；身分與權限函式自己問
grant execute on function public.admin_phone_code_tx(uuid) to authenticated;


-- ============================================================
-- 驗證（單一 SELECT，不 raise —— 硬規則 1.8）
--   ① 欄位在
--   ② 函式在、DEFINER、有權限判斷（can device.write）
--   ③ 授權：authenticated 叫得到、anon 叫不到
--   ④ 行為：在這個查詢裡不是店員（current_staff 是空的）⇒ 回 forbidden（擋牆是活的；正對照請在後台實際按一次）
-- ============================================================
select concat_ws(E'\n',
  case when exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'table_phone_codes' and column_name = 'issued_by_staff_id')
       then '① ✅ table_phone_codes.issued_by_staff_id 在' else '① 🔴 欄位沒建' end,
  case when (select count(*) from pg_proc where proname = 'admin_phone_code_tx' and pronamespace = 'public'::regnamespace) = 1
        and (select prosecdef from pg_proc where proname = 'admin_phone_code_tx' and pronamespace = 'public'::regnamespace)
        and (select pg_get_functiondef('public.admin_phone_code_tx'::regproc) ~ 'public\.can\(''device\.write''\)')
       then '② ✅ admin_phone_code_tx：版本數 1、DEFINER、有權限判斷' else '② 🔴 函式不對' end,
  case when has_function_privilege('authenticated', 'public.admin_phone_code_tx(uuid)', 'execute')
        and not has_function_privilege('anon', 'public.admin_phone_code_tx(uuid)', 'execute')
       then '③ ✅ 後台叫得到、沒登入的叫不到' else '③ 🔴 授權不對' end,
  case when public.admin_phone_code_tx((select id from members limit 1)) ->> 'reason' = 'forbidden'
       then '④ ✅ 不是店員 ⇒ 擋下（forbidden），沒有發出任何碼'
       else '④ 🔴 不是店員也發得出碼' end
) as "驗證";
