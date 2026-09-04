/* ============================================================
   身分解析包一層：`migi_jwt_line_id()`
   2026-09-04 · MIGI · 待辦 14 拍板過的那一項

   ── 為什麼現在做 ──────────────────────────────────
   CLAUDE.md 待辦 14：
   > 🎯 **做的時候把身分解析包成一支函式** ——
   >   今天裡面就一行：查 `line_user_id`。
   >   **代價幾乎為零（多包一層），收益是日後只改一個地方。**

   🎯 **而「日後」在今天就到了。**
   2026-09-04 查出這個 Supabase 專案用的是**非對稱金鑰（ES256）**：
   ```
   /auth/v1/.well-known/jwks.json → {"keys":[{"alg":"ES256","kty":"EC",...}]}
   ```
   ⇒ **Edge Function 不能自己簽 JWT**（私鑰在 Supabase 手上）
   ⇒ 只能走 **Supabase Auth 本身**建立 user
   ⇒ 🔴 **那時 `sub` 會變成 uuid，不再是 `U4af49806…`**

   而現在三支身分函式**都直接寫 `auth.jwt() ->> 'sub'`**：
   ```
   current_org_id()     members.line_user_id = auth.jwt()->>'sub'
   current_member_id()  同上
   current_staff()      同上
   ```
   ⇒ 換發機制一上線，這三支要同時改對，而它們是 **29 條 RLS policy 的地基**。

   ✅ 包一層之後：**「sub 到底放什麼」變成一個可以之後再改的細節**，
     而不是一個要一次答對的決定。

   ============================================================
   🔴 寫的過程中撞到一個會致命的細節：`app_metadata` 不是 `user_metadata`
   ============================================================
   直覺是把 `line_user_id` 放進 `user_metadata`（建立 user 時帶）。**那是洞。**

   | | 誰能改 |
   |---|---|
   | `user_metadata`（`raw_user_meta_data`） | 🔴 **客戶端自己就能改** —— `supabase.auth.updateUser({ data: {...} })` |
   | `app_metadata`（`raw_app_meta_data`） | ✅ **只有 service_role** |

   ⇒ 用 `user_metadata` 的話，任何登入者都能
   `updateUser({ data: { line_user_id: '別人的' } })` ⇒ **變成別人**。
   🎯 **兩者在 JWT 裡長得幾乎一樣**（都是一個 claim、都能用 `->>` 取），
     而其中一個是完整的身分偽造。**這正是「看起來一樣但一個是洞」的形狀。**

   ============================================================
   設計：兩支函式互補，而且不重疊
   ============================================================
   ```
   migi_jwt_uuid()      sub 像 uuid  → 回 uuid，否則 null   （2026-09-04 上午建立）
   migi_jwt_line_id()   這個 JWT 代表哪一個 LINE 帳號        （這一份）
   ```
   `migi_jwt_line_id()` 的順序是刻意的：
   ① `app_metadata.line_user_id` —— **明確宣告的優先**（走 Supabase Auth 之後的形狀）
   ② `sub` 不是 uuid ⇒ **它本身就是 LINE id**（今天的形狀）

   🎯 **它不需要知道 LINE user id 的格式** —— 只需要知道「不是 uuid」。
     寫死 `^U[0-9a-f]{32}$` 那種 pattern 會在 LINE 改格式那天壞掉，
     而**那時的症狀是「所有人都登不進去」**。
   ============================================================ */

-- ── 這個 JWT 代表哪一個 LINE 帳號 ──────────────────────
create or replace function public.migi_jwt_line_id()
returns text
language sql stable
as $function$
  select coalesce(
    /* ① 走 Supabase Auth 之後：`sub` 是 uuid，LINE id 掛在 app_metadata。
       🔴 **一定要 `app_metadata` 不可以是 `user_metadata`** ——
         後者客戶端自己就能改（`supabase.auth.updateUser({ data: … })`），
         那等於「輸入任何 line_user_id 就能變成他」。 */
    nullif(auth.jwt() -> 'app_metadata' ->> 'line_user_id', ''),
    /* ② 今天的形狀：還沒發 Supabase JWT，`sub` 直接就是 LINE user id。
       ⚠ 用「不是 uuid」判斷而不是比對 `^U…` 的格式 ——
         格式寫死會在 LINE 改格式那天壞掉，而症狀是**所有人都登不進去**。 */
    case when public.migi_jwt_uuid() is null
         then nullif(auth.jwt() ->> 'sub', '') end
  );
$function$;

comment on function public.migi_jwt_line_id() is
  '這個 JWT 代表哪一個 LINE 帳號。app_metadata 優先（只有 service_role 能寫），'
  '否則 sub 不是 uuid 就當成 LINE id。🔴 不可以讀 user_metadata —— 客戶端能改。';

revoke execute on function public.migi_jwt_line_id() from public;
revoke execute on function public.migi_jwt_line_id() from anon;
grant  execute on function public.migi_jwt_line_id() to authenticated, service_role;


-- ── 三支身分函式改用它（語意不變）────────────────────
create or replace function public.current_org_id()
returns uuid
language sql stable security definer set search_path to 'public'
as $function$
  /* 兩條路都在，順序沒變：
       ① 總部：Supabase Auth Email → staff.auth_uid（sub 是 uuid）
       ② 會員／店員：LINE → members.line_user_id
     🎯 2026-09-04 第二次改：`auth.jwt()->>'sub'` → `migi_jwt_line_id()`。
       **語意完全不變**（今天那支就是回 sub），差別在
       日後 sub 變成 uuid 時**只要改那一支**。 */
  select coalesce(
    (select org_id from staff
      where auth_uid = public.migi_jwt_uuid() and deleted_at is null limit 1),
    (select org_id from members
      where line_user_id = public.migi_jwt_line_id() and deleted_at is null limit 1)
  );
$function$;

create or replace function public.current_member_id()
returns uuid
language sql stable security definer set search_path to 'public'
as $function$
  /* ⚠ **完全沒有 org 過濾，而那是必然的不是疏漏** ——
     org 是從 member 查出來的，不可能先用 org 縮小範圍（雞生蛋）。
     🔴 所以 `uq_members_line_user`（全域唯一）是**承重牆**：
       只有它能保證「我是誰」有唯一答案。
     ⚠ 這裡有 `limit 1` ⇒ 重複時**不會報錯，會靜默選錯**。 */
  select m.id from members m
   where m.line_user_id = public.migi_jwt_line_id()
     and m.deleted_at is null
   limit 1;
$function$;

create or replace function public.current_staff()
returns table(staff_id uuid, member_id uuid, store_id uuid, role text, name text)
language sql stable security definer set search_path to 'public'
as $function$
  select s.id, s.member_id, s.store_id, s.role, s.name
    from staff s
    -- ⚠ LEFT JOIN 不是 INNER：總部那條路的 staff.member_id 是 null，
    --   INNER JOIN 會把整列濾掉，而那正是 2026-08-23 修掉的 bug。
    left join members m
           on m.id = s.member_id
          and m.deleted_at is null
   where s.deleted_at is null
     and (
       -- ① 總部：Supabase Auth Email 帳號 → staff.auth_uid
       s.auth_uid = public.migi_jwt_uuid()
       -- ② 店員／會員：LINE → members.line_user_id
       or m.line_user_id = public.migi_jwt_line_id()
     )
   -- 一個人可能在多店有 staff 列 → 取權限最高的那一列。
   -- ⚠ `owner` 與 `hq` 同級（`can()` 也是這樣看），所以並列第 1。
   order by case s.role when 'hq' then 1 when 'owner' then 1
                        when 'manager' then 2 else 3 end
   limit 1;
$function$;


-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
do $$
declare
  v_out text := '';
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_line text; v_admin uuid; v_mid uuid; v_txt text;
begin
  begin
    select line_user_id, id into v_line, v_mid from members
     where org_id = v_org and line_user_id is not null and deleted_at is null
     order by created_at limit 1;
    select auth_uid into v_admin from staff
     where auth_uid is not null and deleted_at is null limit 1;

    ---- ① 今天的形狀：sub 就是 LINE id ------------------
    perform set_config('request.jwt.claims',
      '{"sub":' || to_json(v_line)::text || '}', true);
    v_out := v_out || E'\n' || '① sub 是 LINE id → 原樣回傳' || E'\t' ||
      case when public.migi_jwt_line_id() = v_line then '✅' else '🔴 ' ||
           coalesce(public.migi_jwt_line_id(), 'null') end;

    v_out := v_out || E'\n' || '② 🎯 正對照：真的查得到那個人' || E'\t' ||
      case when public.current_member_id() = v_mid then '✅ 身分解析沒壞'
           else '🔴 ' || coalesce(public.current_member_id()::text, 'null') end;

    ---- ③ 總部那條路：sub 是 uuid ----------------------
    perform set_config('request.jwt.claims',
      '{"sub":' || to_json(v_admin::text)::text || '}', true);
    v_out := v_out || E'\n' || '③ sub 是 uuid → LINE id 回 null（不是那條路）' || E'\t' ||
      case when public.migi_jwt_line_id() is null then '✅' else '🔴 ' || public.migi_jwt_line_id() end;

    v_out := v_out || E'\n' || '④ 🎯 正對照：總部那條路仍然通' || E'\t' ||
      case when public.current_org_id() = v_org then '✅ 查得到 org'
           else '🔴 ' || coalesce(public.current_org_id()::text, 'null') end;

    ---- ⑤ 未來的形狀：sub 是 uuid ＋ app_metadata -------
    /* 🎯 **這一格是這份 SQL 存在的理由** ——
       它在驗「換發機制上線之後會不會動」，而那一天還沒到。
       ⚠ 沒有這一格的話，這層包裝的價值是**假設**不是事實。 */
    perform set_config('request.jwt.claims',
      '{"sub":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","app_metadata":{"line_user_id":'
      || to_json(v_line)::text || '}}', true);
    v_out := v_out || E'\n' || '⑤ 🎯 未來形狀：uuid 的 sub ＋ app_metadata' || E'\t' ||
      case when public.migi_jwt_line_id() = v_line then '✅ 認得出來' else '🔴 ' ||
           coalesce(public.migi_jwt_line_id(), 'null') end;

    v_out := v_out || E'\n' || '⑥ 🎯 而且身分解析真的通（換發上線後會動）' || E'\t' ||
      case when public.current_member_id() = v_mid then '✅ 查得到同一個人'
           else '🔴 ' || coalesce(public.current_member_id()::text, 'null') end;

    ---- ⑦ 🔴 user_metadata 不可以被採信 ----------------
    /* 🔴 **這一格擋的是完整的身分偽造。**
       `user_metadata` 客戶端自己就能改（`supabase.auth.updateUser({ data: … })`），
       所以讀它等於「輸入任何 line_user_id 就能變成他」。
       ⚠ 它跟 `app_metadata` 在 JWT 裡長得幾乎一樣 ——
         **這一格就是那個差別的守衛**。 */
    perform set_config('request.jwt.claims',
      '{"sub":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","user_metadata":{"line_user_id":'
      || to_json(v_line)::text || '}}', true);
    v_out := v_out || E'\n' || '⑦ 🔴 user_metadata 被忽略（客戶端能改它）' || E'\t' ||
      case when public.migi_jwt_line_id() is null then '✅ 沒有採信'
           else '🔴 採信了 —— 任何人都能冒充別人' end;

    v_out := v_out || E'\n' || '⑧ 🔴 所以 current_member_id() 也查不到' || E'\t' ||
      case when public.current_member_id() is null then '✅ null'
           else '🔴 竟然回 ' || public.current_member_id()::text end;

    ---- ⑨ 亂七八糟的 JWT 不可以拋錯 --------------------
    perform set_config('request.jwt.claims', '{"sub":""}', true);
    begin
      v_txt := coalesce(public.migi_jwt_line_id(), '(null)') || ' / ' ||
               coalesce(public.current_org_id()::text, '(null)');
    exception when others then v_txt := '🔴 拋錯：' || sqlerrm; end;
    v_out := v_out || E'\n' || '⑨ 空的 sub 不拋錯' || E'\t' ||
      case when v_txt like '🔴%' then v_txt else '✅ ' || v_txt end;

    ---- ⑩ 授權 -----------------------------------------
    v_out := v_out || E'\n' || '⑩ migi_jwt_line_id：anon／PUBLIC 收掉、authenticated 留' || E'\t' ||
      (select case when not a and not p and au then '✅'
                   else '🔴 anon=' || a || ' public=' || p || ' auth=' || au end
         from (select
                 exists (select 1 from aclexplode(coalesce(pr.proacl,'{}')) x
                          where x.grantee='anon'::regrole::oid and x.privilege_type='EXECUTE') a,
                 (pr.proacl is null or exists (select 1 from aclexplode(pr.proacl) x
                          where x.grantee=0 and x.privilege_type='EXECUTE')) p,
                 exists (select 1 from aclexplode(coalesce(pr.proacl,'{}')) x
                          where x.grantee='authenticated'::regrole::oid and x.privilege_type='EXECUTE') au
                from pg_proc pr where pr.pronamespace='public'::regnamespace
                 and pr.proname='migi_jwt_line_id') z);

    ---- ⑪ 🔴 掃全庫：還有誰直接讀 sub -------------------
    /* 🎯 **包一層的意義在於「只有那一層知道 sub 在哪」** ——
       所以要驗「沒有別人繞過它」。
       ⚠ 禁字用 `->> 'sub'` 而不是 `sub`（硬規則 3.5：
         禁字不能是註解裡會出現的詞，而 `sub` 到處都是）。
       ⚠ `prokind='f'` 排除聚合，否則 `pg_get_functiondef` 會拋錯（硬規則 3.7）。

       🔴 **2026-09-04：期望值第一版寫「應該只剩 1」，那是錯的**
         （硬規則 3.56 第五次 —— 而且又是「數量」那一類）。
         `migi_jwt_uuid()` **當然也讀 `sub`** —— 它的工作就是
         「把 sub 轉成 uuid」。⇒ **正確答案是 2，而且它們是一對**：
         · `migi_jwt_uuid()`    「這個 sub 是 uuid 嗎」
         · `migi_jwt_line_id()` 「這個 JWT 代表哪個 LINE 帳號」
         兩支合起來就是那一層，**都必須讀 sub**。
       📌 所以這一格盯的是**第 3 支** —— 那才是繞過抽象的人。 */
    v_out := v_out || E'\n' || '⑪ 🎯 還有幾支函式直接讀 sub（那一層本身是 2 支）' || E'\t' ||
      (select case when count(*) = 2
                     and bool_and(p.proname in ('migi_jwt_uuid', 'migi_jwt_line_id'))
                   then '✅ 只有 migi_jwt_uuid ＋ migi_jwt_line_id'
                   else '🔴 ' || count(*) || ' 支：' || string_agg(p.proname, '／')
                        || ' —— 有人繞過那一層了' end
         from pg_proc p
        where p.pronamespace = 'public'::regnamespace
          and p.prokind = 'f'
          and pg_get_functiondef(p.oid) like '%->> ''sub''%');

    perform set_config('request.jwt.claims', '', true);
    perform set_config('migi.jid', v_out, true);
  exception when others then
    perform set_config('migi.jid', v_out || E'\n🔴 測試自己炸了\t' || sqlerrm, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.jid', true), E'\n')) as x
 where coalesce(x,'') <> '';
