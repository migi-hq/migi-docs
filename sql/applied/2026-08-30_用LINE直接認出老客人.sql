/* ============================================================
   `get_member_by_line_tx`：用已驗簽的 line_user_id 認出老客人
   2026-08-30

   ── 🔴 現在的錯誤流程 ──────────────────────────────
   一個 LINE **已經綁好帳號**的客人登出後重新進來：
   ```
   LIFF 拿到已驗簽的 line_user_id
     → 系統其實一開始就知道他是誰
     → 但沒有人去問
     → 把他丟進四步表單（暱稱／手機／驗證碼／生日／性別）
     → 送出時才發現「喔你已經有帳號了」
   ```
   ⚠ 而且中間**會發一則簡訊給他** —— 一個已經驗過的老客人。
     發太多次還會被自己的限流擋住，變成**完全登不回去**。
     （2026-08-30 創辦人實際卡在這裡。）

   📌 CLAUDE.md 待辦 14 早就記過缺的就是這一支：
     「接 LINE 時還缺一支後端函式：用 line_user_id 查會員的唯讀 RPC。
       沒有它就無法在 onboarding 之前判斷『這是老客人』」

   ── 為什麼不能用 `register_member_tx` 代替 ──────────
   🔴 **它查不到就會「建立」。** 拿一支會寫入的函式當查詢用，
     等於「問一個問題，順便改了資料」——
     而且那時還沒有手機，正是待辦 36 情境 E（重複帳號）的溫床。

   ── 只回自己的資料，不是洩漏 ────────────────────────
   `p_line_user_id` 由 Edge Function 從**驗過簽的 id_token** 取出，
   前端沒有機會塞別人的。所以回傳的一定是呼叫者自己的帳號。
   ⚠ 但仍然**只回畫面需要的欄位**：id、暱稱、手機驗證狀態。
     不回手機號碼本身（那是可聯絡的 PII，見下面 `get_my_profile_tx` 的說明）。

   ⚠ service_role only —— 這一支拿 `line_user_id` 換 `member_id`，
     開給 anon 等於「知道某人的 LINE id 就能拿到他的 member_id」。
   ============================================================ */

create or replace function public.get_member_by_line_tx(
  p_org_id uuid, p_line_user_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_m members%rowtype;
begin
  if p_org_id is null or coalesce(trim(p_line_user_id), '') = '' then
    return jsonb_build_object('found', false);
  end if;

  select * into v_m from members
   where org_id = p_org_id and line_user_id = p_line_user_id and deleted_at is null
   limit 1;

  if v_m.id is null then
    return jsonb_build_object('found', false);
  end if;

  return jsonb_build_object(
    'found', true,
    'member_id', v_m.id,
    'display_name', v_m.display_name,
    /* 🎯 遮罩顯示：`0910***736`。
       客人認得出是不是自己的號碼，但這串**打不通** ——
       所以就算 member_id 哪天外流，也不會連帶交出一支可聯絡的門號。 */
    'phone_masked', case when v_m.phone is null then null
                         else left(v_m.phone, 4) || '***' || right(v_m.phone, 3) end,
    'phone_verified', v_m.phone_verified_at is not null);
end $$;

revoke execute on function public.get_member_by_line_tx(uuid, text) from public;
revoke execute on function public.get_member_by_line_tx(uuid, text) from anon, authenticated;
grant  execute on function public.get_member_by_line_tx(uuid, text) to service_role;


/* ── 個人設定要顯示手機 → `get_my_profile_tx` 補兩個欄位 ──
   ⚠ 簽名不變 ⇒ `CREATE OR REPLACE`，不用 DROP。

   🔴 **只回遮罩後的號碼，不回完整號碼。**
     待辦 36 當初刻意不加 phone，理由是「`p_member_id` 是前端傳的，
     多回一個**可聯絡**的個資等於擴大暴露面」。那個理由今天仍然成立
     （C9：拿到 member_id 就能叫 `get_my_profile_tx`）。
   🎯 遮罩把「客人要確認是哪支號碼」與「別人拿得到一支可撥打的門號」分開 ——
     前者需要，後者不需要。
   ⚠ 要顯示完整號碼的話，是等待辦 14 的 JWT 完成（那時 member_id 不再是通行證），
     不是現在把它打開。 */
do $$
declare v_old text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_old from pg_proc p
   where p.pronamespace='public'::regnamespace and p.prokind='f'
     and p.proname='get_my_profile_tx';
  if v_old is null then raise exception '找不到 get_my_profile_tx'; end if;

  /* 錨點：`'nickname', <別名>.display_name,` —— 只出現一次。
     ⚠ 別名用 \1 帶出來，不要寫死。 */
  v_new := regexp_replace(v_old,
    '''nickname''\s*,\s*([a-zA-Z_]+)\.display_name\s*,',
    '''nickname'', \1.display_name,' ||
    E'\n    ''phone_masked'', case when \\1.phone is null then null' ||
    E'\n                        else left(\\1.phone,4) || ''***'' || right(\\1.phone,3) end,' ||
    E'\n    ''phone_verified'', (\\1.phone_verified_at is not null),');
  if v_new = v_old then raise exception '錨點沒對上（nickname 那一行）'; end if;
  if v_new !~ 'phone_masked' then raise exception '改完之後找不到 phone_masked'; end if;

  execute v_new;
end $$;


/* ============================================================
   驗證（單一 SELECT）

   🎯 正對照缺一不可：
     ② 不存在的 LINE 要回 found=false（不能永遠回 found）
     ③ 手機一定要是**遮罩過的**（回完整號碼就白改了）
     ④ anon 叫不動
   ============================================================ */
select 序, 項目, 內容 from (

  select 1 as 序, '① 用真實的 line_user_id 查得到嗎' as 項目,
         (select case when (r->>'found')::boolean
                      then '✅ found　暱稱=' || coalesce(r->>'display_name','?')
                         || '　手機=' || coalesce(r->>'phone_masked','(無)')
                         || '　驗過=' || coalesce(r->>'phone_verified','?')
                      else '🔴 查不到' end
            from (select get_member_by_line_tx(m.org_id, m.line_user_id) r
                    from members m
                   where m.line_user_id is not null and m.deleted_at is null
                   order by m.created_at limit 1) t) as 內容

  union all
  select 2, '② 🎯 正對照：不存在的 LINE 要回 found=false',
         (select case when (get_member_by_line_tx('11111111-1111-1111-1111-111111111111','U_nobody')->>'found')::boolean
                      then '🔴 竟然找得到' else '✅ found=false' end)

  union all
  select 3, '③ 🎯 手機一定要遮罩（不可以是完整號碼）',
         (select case when r->>'phone_masked' like '%***%'
                      then '✅ ' || (r->>'phone_masked')
                      when r->>'phone_masked' is null then '⚠ 這個帳號沒有手機，這一格沒驗到'
                      else '🔴 回了完整號碼：' || (r->>'phone_masked') end
            from (select get_member_by_line_tx(m.org_id, m.line_user_id) r
                    from members m
                   where m.line_user_id is not null and m.phone is not null and m.deleted_at is null
                   order by m.created_at limit 1) t)

  union all
  select 4, '④ get_my_profile_tx 也補上了嗎',
         (select case when (p ? 'phone_masked') and (p ? 'phone_verified')
                      then '✅ 兩個欄位都在　手機=' || coalesce(p->>'phone_masked','(無)')
                         || '　驗過=' || coalesce(p->>'phone_verified','?')
                      else '🔴 少了欄位' end
            from (select get_my_profile_tx(m.org_id, m.id) p from members m
                   where m.line_user_id is not null and m.deleted_at is null
                   order by m.created_at limit 1) t)

  union all
  select 5, '⑤ 🎯 anon 叫不動 get_member_by_line_tx',
         (select case when has_function_privilege('anon', oid, 'execute')
                      then '🔴 叫得動 —— 知道 LINE id 就能換到 member_id'
                      else '✅ 叫不動' end
            from pg_proc where pronamespace='public'::regnamespace
                          and proname='get_member_by_line_tx')

) x order by 序;
