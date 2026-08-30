/* ============================================================
   `phone_in_use_tx` 加上「排除自己」
   2026-08-30

   ── 🔴 現在的錯誤行為 ──────────────────────────────
   一個 **LINE 已經綁好**的客人重走註冊（清了 App 資料、換裝置、
   或自己按了登出），在手機那一步填**自己的號碼**：
   ```
   check_phone → 查到「有人用了」→ 擋住
             → 「這支號碼已經是 MIGI 會員了，請找店員或客服」
   ```
   🔴 **那是他自己的號碼。** 對他說「請找店員」是完全錯的訊息，
     而且他其實只要按完剩下兩步就會回到自己的帳號
     （`register_member_tx` 第一條就是 `line_user_id` 查得到 → `existing_line`）。

   ⚠ 這不是測試才會遇到的狀況 —— 客人清 App 資料、換手機、
     或在另一台裝置開 LIFF 都會走到。

   ── 修法：問題問清楚一點 ────────────────────────────
   「這支號碼有人用嗎」問錯了。要問的是
   **「這支號碼被『不是你』的人用了嗎」**。
   → 多一個 `p_line_user_id`，把綁在那個 LINE 上的會員排除掉。

   ⚠ 傳 null 時行為與現在完全一樣（沒有人可以排除）——
     所以就算 Edge Function 忘了帶，也只是退回舊行為，不會壞。

   ── 硬規則 2：加參數＝改簽名 ⇒ 一定要先 DROP ────────
   `CREATE OR REPLACE` 不能加參數（會變成多載版本，
   然後 PostgREST 呼叫時撞「函式不明確」而且錯誤訊息看不懂）。
   ⚠ **DROP 會把 GRANT 一起丟掉**，所以結尾一定要補回授權。
   ============================================================ */

drop function if exists public.phone_in_use_tx(uuid, text);

create or replace function public.phone_in_use_tx(
  p_org_id uuid, p_phone text, p_line_user_id text default null)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_phone text;
begin
  if p_org_id is null or coalesce(trim(p_phone), '') = '' then
    return false;
  end if;

  /* ⚠ 正規化只有這一個來源 —— `uq_members_phone` 是字串比對，
     `0912-345-678` 與 `0912345678` 會被當成兩支號碼。 */
  v_phone := public.migi_norm_phone(p_phone);
  if v_phone is null then
    return false;
  end if;

  return exists (
    select 1 from members
     where org_id = p_org_id
       and phone = v_phone
       and deleted_at is null
       /* 🎯 排除「綁在這個 LINE 上的那個會員」——
          他填自己的號碼不叫做「被占用」。
          ⚠ `p_line_user_id` 是 null 時這個條件恆真，
            也就是退回「只要有人用就算」的舊行為。 */
       and (p_line_user_id is null or line_user_id is distinct from p_line_user_id)
  );
end $$;

/* 🔴 DROP 把 GRANT 丟掉了，一定要補回來（硬規則 2）。
   ⚠ 兩個方向都要收（硬規則 2.6 ＋ 2.6b）：
     新建的函式 Supabase 的 default privileges 會**明確授權**給 anon，
     而它是一個「這支號碼是不是會員」的查詢器 —— 只能給 service_role。 */
revoke execute on function public.phone_in_use_tx(uuid, text, text) from public;
revoke execute on function public.phone_in_use_tx(uuid, text, text) from anon, authenticated;
grant  execute on function public.phone_in_use_tx(uuid, text, text) to service_role;


/* ============================================================
   驗證（單一 SELECT）

   三個子測試缺一不可：
     ① 別人的號碼 → **要擋**（不能因為加了排除就全部放行）
     ② 🎯 自己的號碼 ＋ 自己的 line_user_id → **不擋**（這次要修的）
     ③ 🎯 沒帶 line_user_id → 退回舊行為（**要擋**）
   ⚠ 少了 ① 或 ③，一支「永遠回 false」的函式會完全過關。
   ============================================================ */
select 序, 項目, 內容 from (

  select 1 as 序, '① 別人的號碼（應為 true＝擋住）' as 項目,
         (select m.phone || ' + 別人的 LINE → '
              || phone_in_use_tx(m.org_id, m.phone, 'U_someone_else')::text
              || case when phone_in_use_tx(m.org_id, m.phone, 'U_someone_else')
                      then '　✅ 擋住' else '　🔴 沒擋住' end
            from members m
           where m.deleted_at is null and m.phone is not null and m.line_user_id is not null
           order by m.created_at limit 1) as 內容

  union all
  select 2, '② 🎯 自己的號碼 ＋ 自己的 LINE（應為 false＝放行）',
         (select m.phone || ' + 他自己的 LINE → '
              || phone_in_use_tx(m.org_id, m.phone, m.line_user_id)::text
              || case when phone_in_use_tx(m.org_id, m.phone, m.line_user_id)
                      then '　🔴 還是擋住了（沒修好）' else '　✅ 放行' end
            from members m
           where m.deleted_at is null and m.phone is not null and m.line_user_id is not null
           order by m.created_at limit 1)

  union all
  select 3, '③ 🎯 正對照：沒帶 line_user_id 要退回舊行為（應為 true）',
         (select m.phone || ' + null → '
              || phone_in_use_tx(m.org_id, m.phone)::text
              || case when phone_in_use_tx(m.org_id, m.phone)
                      then '　✅ 照樣擋住' else '　🔴 忘了帶就全部放行了' end
            from members m
           where m.deleted_at is null and m.phone is not null
           order by m.created_at limit 1)

  union all
  select 4, '④ 🎯 anon 叫不動（DROP 之後 GRANT 有補回來嗎）',
         (select case when has_function_privilege('anon', p.oid, 'execute')
                      then '🔴 anon 叫得動' else '✅ 叫不動' end
              || '　service_role：'
              || case when exists (select 1 from aclexplode(p.proacl) a
                        where a.grantee='service_role'::regrole::oid and a.privilege_type='EXECUTE')
                      then '✅ 有' else '🔴 沒有 —— Edge Function 會壞' end
            from pg_proc p
           where p.pronamespace='public'::regnamespace and p.proname='phone_in_use_tx')

  union all
  select 5, '⑤ 🎯 正對照：沒有留下多載版本（應為 1）',
         (select count(*)::text || ' 個版本　'
              || case when count(*) = 1 then '✅' else '🔴 DROP 沒生效，PostgREST 會撞函式不明確' end
            from pg_proc where pronamespace='public'::regnamespace and proname='phone_in_use_tx')

) x order by 序;
