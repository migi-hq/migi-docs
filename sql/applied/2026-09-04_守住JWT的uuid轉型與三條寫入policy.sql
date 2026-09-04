/* ============================================================
   開 JWT 之前的地基：守住 uuid 轉型 ＋ 三條寫入 policy 限縮到總部
   2026-09-04 · MIGI · 待辦 21 的第 ①② 步

   ── 這一份在做什麼 ──────────────────────────────────
   ① `migi_jwt_uuid()` —— 把 JWT 的 `sub` **安全地**轉成 uuid
   ② `current_org_id()` / `current_staff()` 改用它（語意不變，只是不會炸）
   ③ `can(權限碼)` —— 權限判斷點（待辦 29 ①）
   ④ 三條 `ALL`（含寫入）的 policy 限縮到總部，**讀取完全不動**

   ============================================================
   🔴 ①② 是一顆埋在待辦 14／20 路上的地雷（2026-09-04 實測炸出來）
   ============================================================
   `auth.uid()` 的定義是把 `sub` **cast 成 uuid**：
   ```sql
   (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid
   ```
   而 `current_org_id()` 的 `coalesce` **第一行就叫它**：
   ```sql
   coalesce(
     (select org_id from staff   where auth_uid = auth.uid() …),          ← 這裡
     (select org_id from members where line_user_id = auth.jwt()->>'sub' …)
   )
   ```
   ⇒ **同一個 `sub` 被當成兩種東西**：
     · 總部那條路：`sub` 是 Supabase auth 的 **uuid**
     · 會員／店員那條路：`sub` 是 LINE 的 **`U4af49806…`**（不是 uuid）

   實測（把 claims 設成 LINE id 再叫 `current_org_id()`）：
   ```
   invalid input syntax for type uuid: "U4af4980629abc1234567890abcdef012"
   ```
   🔴 **它不是回 null，是拋錯。** 而 28 條 RLS policy 全部依賴這支函式
     ⇒ 發出第一張會員／店員 JWT 的那一刻，**整個 App 的每一次查詢都會炸**。

   ⚠ **今天不是活著的 bug**：Edge Function `line-login` 目前**沒有發任何
     Supabase JWT**（它自己在伺服器端驗 LINE token 後直接呼叫
     `register_member_tx`）。所以這是**地雷不是火災** ——
     它會在「開 JWT 的那一刻」引爆，而那正是最不想除錯的時刻。

   🎯 **這跟 `players` 一個 key 兩種形狀、`score_points` 一個名字兩個意思
     是同一族的病**，只是這次發生在身分層。

   ⚠ 修法**刻意不改語意**：`sub` 長得像 uuid 就當 uuid 比對 `staff.auth_uid`，
     不像就當 LINE id 比對 `members.line_user_id`。兩條路都還在。
   ⚠ 用 `case` 不是 `and` —— **Postgres 不保證 `AND` 的求值順序**，
     所以 `where sub ~ '…' and auth_uid = sub::uuid` 仍然可能先做 cast。
     `CASE` 是少數保證由左到右的結構（同硬規則 3.7 那個 `prokind` 的坑）。

   📌 只有兩支函式用到 `auth.uid()`（`current_org_id` / `current_staff`），
     **沒有任何 RLS policy 直接用** —— 2026-09-04 掃過，所以修面就是這兩支。

   ============================================================
   🔴 ④ 三條 policy 是寫入權，而現在只靠「幾乎沒有人有 session」擋著
   ============================================================
   28 條 policy 盤點下來：
   ```
   4 條  公開主檔（條件 true）—— member_tiers / product_taxonomy /
                              queue_tags / topup_plans，本來就該全 org 可讀
   3 條  ALL（含寫入）        ← 這一份要處理的
   21 條 SELECT ＋ org        ← 待辦 21 的第 ③ 步再處理
   ```
   | policy | 表 | 給誰 | 開 JWT 後 |
   |---|---|---|---|
   | `products_org_write` | products | **public** | 任何登入者可改**商品價格** |
   | `order_items_org` | order_items | authenticated | 可改訂單品項 |
   | `order_payments_org` | order_payments | authenticated | 可改付款紀錄 |

   🔴 `products` 那條特別刺：待辦 2 才剛把價格改成「後端一律回查主檔，
     不信前端」（硬規則 5.8）。**如果登入者能直接 `UPDATE unit_price`，
     那道防線就繞過去了。**

   ⚠ **不能直接刪** —— `migi-admin/src/lib/products.js` 有 5 處直接
     `.from('products')` 寫入，而 migi-admin 用的是真的 Supabase Auth
     （`signInWithPassword`，`admin@migi.tw`）。**那條 policy 是承重的。**
   ⇒ 所以是**限縮角色**不是移除。

   ⚠ **讀取一條都不能誤傷**（同硬規則 3.55：過度阻擋跟沒擋一樣糟）：
     · `products` 另有 `products_org`（SELECT）→ 不受影響 ✅
     · `order_items` 另有 `oi_org`（SELECT）→ 不受影響 ✅
     · 🔴 `order_payments` **只有這一條**，所以要**先補一條 SELECT**
       再把 ALL 那條收緊，否則會連讀取一起關掉。
   ============================================================ */

-- ── ① 安全的 sub → uuid ────────────────────────────────
create or replace function public.migi_jwt_uuid()
returns uuid
language sql stable
as $function$
  /* JWT 的 `sub` 長得像 uuid 就轉，不像就回 null（**不要拋錯**）。
     ⚠ `case` 保證由左到右求值；`and` 不保證。 */
  select case
           when s ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
           then s::uuid
         end
    from (select nullif(auth.jwt() ->> 'sub', '') as s) t;
$function$;

comment on function public.migi_jwt_uuid() is
  'JWT 的 sub 安全轉 uuid：不是 uuid 格式就回 null。⚠ auth.uid() 會直接拋 invalid input syntax，而會員／店員那條路的 sub 是 LINE user id（U4af…）不是 uuid。';


-- ── ② 兩支身分函式改用它（語意不變）────────────────────
create or replace function public.current_org_id()
returns uuid
language sql stable security definer set search_path to 'public'
as $function$
  /* 兩條路都在，順序也沒變：
       ① 總部：Supabase Auth Email → staff.auth_uid（sub 是 uuid）
       ② 會員／店員：LINE → members.line_user_id（sub 是 U4af…）
     🔴 唯一的差別是第一行改用 `migi_jwt_uuid()` ——
       在此之前 `auth.uid()` 會對 LINE id **拋錯**，
       而它是 coalesce 的第一項，所以第二條路根本走不到。 */
  select coalesce(
    (select org_id from staff
      where auth_uid = public.migi_jwt_uuid() and deleted_at is null limit 1),
    (select org_id from members
      where line_user_id = (auth.jwt() ->> 'sub') and deleted_at is null limit 1)
  );
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
       --    🔴 2026-09-04 改用 migi_jwt_uuid()：`auth.uid()` 對 LINE id 會拋錯，
       --      而 OR 的兩邊都可能被求值（不保證短路）。
       s.auth_uid = public.migi_jwt_uuid()
       -- ② 店員／會員：LINE → members.line_user_id
       or m.line_user_id = (auth.jwt() ->> 'sub')
     )
   -- 一個人可能在多店有 staff 列（例如店長兼支援）——
   -- 取權限最高的那一列。這是原本就有的行為，保留。
   order by case s.role when 'hq' then 1 when 'manager' then 2 else 3 end
   limit 1;
$function$;


-- ── ③ 權限判斷點（待辦 29 ①）────────────────────────────
create or replace function public.can(p_perm text)
returns boolean
language sql stable security definer set search_path to 'public'
as $function$
  /* 🎯 **判斷點一律呼叫 `can('動詞.名詞')`，不要在 policy 裡比對 role 字串**
     （CLAUDE.md 待辦 29 ①）—— 即使今天的實作就是一行 `role in ('hq','owner')`。
     重點是**「權限怎麼決定」與「誰有權限」從第一天就分家**：
     日後換成查 `role_permissions` 表時，**所有呼叫點一行都不用改**。
     （同 `member_tiers` 的教訓：折扣率原本寫在兩支函式各一份 case。）

   ⚠ 權限碼用**動詞**不用頁面名（待辦 29 ④）——
     頁面會改名、會合併、會拆開；動作不會。
   ⚠ 目前只有兩個碼，**不要先列一整張表** —— 那是憑空想像（待辦 29）。
     收斂判準：控制在 10–15 個以內。

   📌 今天所有權限碼的答案都一樣（總部才有），所以沒有 `case p_perm`。
     等真的出現「店長可以但店員不行」的碼再分岔。 */
  select exists (
    select 1 from public.current_staff() cs
     where cs.role in ('hq', 'owner')
  );
$function$;

comment on function public.can(text) is
  '權限判斷點。今天的實作是 role in (hq, owner)，日後換成查 role_permissions 表時呼叫點不用改。權限碼用動詞不用頁面名（product.write / order.write）。';

/* 🔴 兩個方向都要收（硬規則 2.6b）：
   · 舊函式的 anon 來自 PUBLIC 繼承 → `revoke from public`
   · **新建的函式**吃 default privileges，是**明確**授權給 anon → `revoke from anon`
   ⚠ 但 `authenticated` **必須留著** —— 下面三條 policy 的角色是
     `authenticated`，而 policy 運算式是用**查詢者的身分**執行的。
     收掉的話那三條會直接拋 permission denied（不是「擋住」是「壞掉」）。 */
revoke execute on function public.can(text) from public;
revoke execute on function public.can(text) from anon;
grant  execute on function public.can(text) to authenticated, service_role;

/* `migi_jwt_uuid()` 同理：它被 `current_org_id()`（DEFINER）呼叫，
   但也可能在 policy 裡被直接用，所以 authenticated 要留。
   ⚠ 它只讀 JWT claim，不碰任何表 —— 給 anon 也沒有資訊外洩，
     但照樣收掉：**沒有理由給的就不給**。 */
revoke execute on function public.migi_jwt_uuid() from public;
revoke execute on function public.migi_jwt_uuid() from anon;
grant  execute on function public.migi_jwt_uuid() to authenticated, service_role;


-- ── ④ 三條寫入 policy 限縮到總部 ────────────────────────

/* 🔴 order_payments **只有這一條 policy**，所以要先補讀取再收緊，
   否則會連 SELECT 一起關掉（過度阻擋跟沒擋一樣糟）。 */
drop policy if exists order_payments_read_org on public.order_payments;
create policy order_payments_read_org on public.order_payments
  for select using (org_id = public.current_org_id());

drop policy if exists order_payments_org on public.order_payments;
create policy order_payments_org on public.order_payments
  for all to authenticated
  using       (org_id = public.current_org_id() and public.can('order.write'))
  with check  (org_id = public.current_org_id() and public.can('order.write'));

/* order_items 另有 `oi_org`（SELECT，經 orders 判斷 org）→ 讀取不受影響。 */
drop policy if exists order_items_org on public.order_items;
create policy order_items_org on public.order_items
  for all to authenticated
  using       (org_id = public.current_org_id() and public.can('order.write'))
  with check  (org_id = public.current_org_id() and public.can('order.write'));

/* products 另有 `products_org`（SELECT）→ 讀取不受影響。
   ⚠ 角色從 `public` 改成 `authenticated` —— `public` 含 anon，
     而 anon 永遠不可能是總部，留著只是讓人以為它有意義。 */
drop policy if exists products_org_write on public.products;
create policy products_org_write on public.products
  for all to authenticated
  using       (org_id = public.current_org_id() and public.can('product.write'))
  with check  (org_id = public.current_org_id() and public.can('product.write'));


-- ── 驗證 ───────────────────────────────────────────────
do $$
declare
  v_out text := '';
  v_admin uuid; v_line text; v_pid uuid; v_n int;
  v_org uuid := '11111111-1111-1111-1111-111111111111';
begin
  begin
    select auth_uid into v_admin from staff
     where auth_uid is not null and deleted_at is null limit 1;
    select line_user_id into v_line from members
     where line_user_id is not null and deleted_at is null limit 1;
    select id into v_pid from products where org_id = v_org and deleted_at is null limit 1;

    ---- ① sub → uuid 的轉型 ----------------------------
    perform set_config('request.jwt.claims',
      '{"sub":"2485579b-1111-2222-3333-444455556666"}', true);
    v_out := v_out || E'\n' || '① sub 是 uuid → 轉得出來' || E'\t' ||
      case when public.migi_jwt_uuid() = '2485579b-1111-2222-3333-444455556666'::uuid
           then '✅' else '🔴 ' || coalesce(public.migi_jwt_uuid()::text,'null') end;

    perform set_config('request.jwt.claims',
      '{"sub":"U4af4980629abc1234567890abcdef012"}', true);
    v_out := v_out || E'\n' || '② 🎯 sub 是 LINE id → 回 null 而不是拋錯' || E'\t' ||
      case when public.migi_jwt_uuid() is null
           then '✅ null（在此之前 auth.uid() 會拋 invalid input syntax）'
           else '🔴 ' || public.migi_jwt_uuid()::text end;

    /* 🎯 **這一格是這份 SQL 的核心**：修之前它會拋
       `invalid input syntax for type uuid`，整個 App 起不來。 */
    begin
      v_out := v_out || E'\n' || '③ 🎯 current_org_id() 在 LINE id 之下不再拋錯' || E'\t' ||
        '✅ 回 ' || coalesce(public.current_org_id()::text, 'null（沒有這個 LINE 帳號，正確）');
    exception when others then
      v_out := v_out || E'\n' || '③ 🎯 current_org_id()' || E'\t' || '🔴 還是炸：' || sqlerrm;
    end;

    /* 🔴 **正對照**：用一個**真的存在**的 LINE id，要回得出 org ——
       只驗「不拋錯」的話，一支永遠回 null 的實作也會讓 ③ 變綠。 */
    if v_line is not null then
      perform set_config('request.jwt.claims',
        '{"sub":' || to_json(v_line)::text || '}', true);
      v_out := v_out || E'\n' || '④ 🎯 正對照：真的 LINE id → 查得到 org' || E'\t' ||
        case when public.current_org_id() = v_org then '✅ ' || v_org::text
             else '🔴 ' || coalesce(public.current_org_id()::text,'null') end;
    else
      v_out := v_out || E'\n' || '④ 正對照' || E'\t' || '⚠ 沒有任何會員綁 LINE，跳過';
    end if;

    /* 總部那條路也要還在（uuid 的 sub）。 */
    perform set_config('request.jwt.claims',
      '{"sub":' || to_json(v_admin::text)::text || '}', true);
    v_out := v_out || E'\n' || '⑤ 🎯 正對照：總部 uuid → 查得到 org（兩條路都在）' || E'\t' ||
      case when public.current_org_id() = v_org then '✅'
           else '🔴 ' || coalesce(public.current_org_id()::text,'null') end;

    v_out := v_out || E'\n' || '⑥ can() 對總部回 true' || E'\t' ||
      case when public.can('product.write') then '✅' else '🔴 false' end;

    ---- ⑦ 授權 -----------------------------------------
    /* ⚠ `authenticated` 必須留著 —— policy 運算式用查詢者的身分執行，
         收掉會讓那三條 policy 拋 permission denied（不是擋住是壞掉）。 */
    v_out := v_out || E'\n' || '⑦ can()：anon／PUBLIC 收掉、authenticated 留著' || E'\t' ||
      (select case when not has_anon and not has_public and has_auth
                   then '✅ 三項都對'
                   else '🔴 anon=' || has_anon || ' public=' || has_public || ' auth=' || has_auth end
         from (select
                 exists (select 1 from aclexplode(p.proacl) a
                          where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE') as has_anon,
                 (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                          where a.grantee = 0 and a.privilege_type='EXECUTE')) as has_public,
                 exists (select 1 from aclexplode(p.proacl) a
                          where a.grantee='authenticated'::regrole::oid and a.privilege_type='EXECUTE') as has_auth
                 from pg_proc p where p.pronamespace='public'::regnamespace
                  and p.proname='can') z);

    ---- ⑧ policy 的形狀 --------------------------------
    v_out := v_out || E'\n' || '⑧ 三條 ALL policy 都帶 can() 且限 authenticated' || E'\t' ||
      (select case when count(*) = 3 then '✅ 三條都收好了'
                   else '🔴 只有 ' || count(*) || ' 條' end
         from pg_policies
        where schemaname='public' and cmd='ALL'
          and roles::text = '{authenticated}'
          and coalesce(qual,'') like '%can(%');

    v_out := v_out || E'\n' || '⑨ order_payments 補了讀取用的 SELECT policy' || E'\t' ||
      (select case when count(*) = 1 then '✅ 在（不然收緊寫入會連讀取一起關掉）'
                   else '🔴 ' || count(*) || ' 條' end
         from pg_policies
        where schemaname='public' and tablename='order_payments' and cmd='SELECT');

    ---- ⑩⑪ 真的用 authenticated 的身分寫一次 -------------
    /* 🎯 待辦 21 第 ⑤ 項要求的「拿真的身分實際查一次」——
       只讀 policy 定義不算數（RLS 的實際效果取決於 policy 組合）。 */
    if v_pid is not null and v_admin is not null then
      perform set_config('request.jwt.claims',
        '{"sub":' || to_json(v_admin::text)::text || ',"role":"authenticated"}', true);
      set local role authenticated;
      begin
        update products set updated_at = now() where id = v_pid;
        get diagnostics v_n = row_count;
      exception when others then v_n := -1;
      end;
      reset role;
      v_out := v_out || E'\n' || '⑩ 🎯 總部身分**仍然改得動**商品（migi-admin 靠它）' || E'\t' ||
        case when v_n = 1 then '✅ 改到 1 列'
             when v_n = -1 then '🔴 拋錯了 —— migi-admin 會壞掉'
             else '🔴 改到 ' || v_n || ' 列' end;

      /* 🔴 **正對照**：一個沒有 staff 列的 authenticated 身分要改不動。
         只驗「總部改得動」的話，一條沒收緊的 policy 也會讓 ⑩ 變綠。 */
      perform set_config('request.jwt.claims',
        '{"sub":"99999999-9999-9999-9999-999999999999","role":"authenticated"}', true);
      set local role authenticated;
      begin
        update products set updated_at = now() where id = v_pid;
        get diagnostics v_n = row_count;
      exception when others then v_n := -1;
      end;
      reset role;
      v_out := v_out || E'\n' || '⑪ 🎯 正對照：非總部身分改不動商品' || E'\t' ||
        case when v_n = 0 then '✅ 0 列（沒收緊的話這裡會是 1）'
             when v_n = -1 then '⚠ 拋錯（也擋住了，但訊息會很難懂）'
             else '🔴 竟然改到 ' || v_n || ' 列' end;
    else
      v_out := v_out || E'\n' || '⑩⑪ 實際寫入測試' || E'\t' || '⚠ 缺 products 或 staff.auth_uid，跳過';
    end if;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'migi_rollback';
  exception when others then
    begin reset role; exception when others then end;
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.pol', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.pol', true), E'\n')) as x
 where coalesce(x,'') <> '';
