/* ============================================================
   堵住換綁與提權：`rebind_line_user_tx` ＋ `grant_staff_tx` ＋ `revoke_staff_tx`
   2026-09-04 · MIGI · 🔴 店員登入上線當天發現

   ── 怎麼找到的 ──────────────────────────────────────
   使用者問「任何人都能用 LINE 登入嗎？應該要由總部設定後才能登入？」
   → 登入**本身**有擋（`get_staff_by_line_tx` 查不到就 403）✅
   → 但「**成為店員**」那一步沒有擋 🔴

   掃全庫用了一個很精準的判準：**簽名裡有 `p_staff_id` 的函式** ——
   那表示它設計上是店員操作，而店員操作不該讓 anon 叫。
   18 支裡有 15 支 anon 叫得動、**全部沒有權限檢查**。

   ── 🔴 但它們不是同一類，不可以一起收 ────────────────
   | | | |
   |---|---|---|
   | **A 營運函式** ×12<br>`open_session_tx`／`checkout_tx`／`topup_tx`／`settle_session_tx`… | anon ✅ 零檢查 | 🟡 **現況的必然** —— POS 用 anon key，而在店員登入之前**沒有任何身分可以檢查**。收了會直接打壞 POS。那是硬規則 5.6 的「身分靠前端宣告」複利捷徑，**屬於待辦 14** |
   | **B `rebind_line_user_tx`** | anon ✅ 零檢查 | 🔴 **真的洞** —— 它不是營運函式，是**改身分橋樑**的工具 |
   | **C `grant_staff_tx`／`revoke_staff_tx`** | anon ❌ authenticated ✅ 零檢查 | 🔴 **提權** —— 登入的店員可以把自己升成 owner |

   ✅ **這一份只修 B 與 C，而且零風險：它們都沒有任何前端在呼叫。**

   ============================================================
   🔴 B 有多嚴重：完整的帳號劫持，不需要任何憑證
   ============================================================
   ```sql
   rebind_line_user_tx(受害者的 member_id, 我的 line_user_id, null)
   → 那個帳號的 line_user_id 變成我的
   → 我用 LINE 登入 = 我就是他（錢包、消費紀錄、段位全部）
   ```
   函式體裡檢查的只有三件事：新 id 不可為空、member 存在、
   新 id 沒被別人用 —— **`p_staff_id` 只是寫進 log，完全不驗證**。

   ⚠ 唯一的門檻是「要知道對方的 `member_id`」，而 2026-08-30 才剛收掉
     洩漏它的路徑（`register_member_tx` 的 anon、`line_conflict` 回傳 id）。
     🔴 但那是**難不是不可能** —— uuid 一旦從任何一支 RPC 漏出去就完蛋。
     🎯 而 2026-09-04 建 `get_season_leaderboard_tx` 時**差點就漏了**：
       排行榜的第一版想回 `member_id`。**那兩件事合起來就是災難。**

   ============================================================
   設計：不收 `p_staff_id`，從 `current_staff()` 取
   ============================================================
   🔴 **只把授權收緊還不夠。** 就算收成 `authenticated`，
     登入的店員仍然可以**填別人的 `staff_id`** 假造稽核 ——
     而那比沒有稽核更糟（它看起來有，而且指向錯的人）。

   ✅ 正解跟 `set_member_phone_tx` 不收 `p_member_id` 是同一個道理
     （待辦 36 記過）：**身分不可以由呼叫端宣告**。
   ⇒ 拿掉 `p_staff_id`，改從 `current_staff()` 取。

   ⚠ 改簽名要 `DROP FUNCTION`（硬規則 2），而 **DROP 會把 GRANT 一起丟掉**
     ⇒ 檔案結尾一定要重新 grant。
   ✅ **現在改是免費的**：`rebind_line_user_tx` 沒有任何前端在呼叫
     （CLAUDE.md 待辦 41 ②：「函式早就在了，缺的只是畫面」）。
     ⏳ 日後 POS 做那個畫面時，**呼叫端不用送 staff_id** —— 更簡單。
   ============================================================ */

-- ── B. 換綁 LINE：只有店員能做，而且身分不由呼叫端宣告 ──
drop function if exists public.rebind_line_user_tx(uuid, text, uuid, text);

create or replace function public.rebind_line_user_tx(
  p_member_id uuid, p_new_line_user_id text, p_reason text default null
) returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_old text; v_org uuid; v_taken uuid; v_staff record;
begin
  /* 🔴 **第一道：誰在呼叫。**
     在此之前這支 anon 就能叫，而它會直接改 `members.line_user_id`
     ⇒ 「給我一個 member_id，我就把那個帳號變成我的」。
     ⚠ 用 `can()` 不比對 role 字串（待辦 29 ①）——
       日後「店長可以換綁但一般店員不行」時只要改 `can()` 一支。 */
  if not public.can('staff.rebind') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden',
      'message', '只有店員可以換綁 LINE 帳號');
  end if;

  /* 🔴 **第二道：身分從 `current_staff()` 取，不收參數。**
     舊版的 `p_staff_id` 只是寫進 log 而且不驗證 ⇒ 登入的店員可以
     **填別人的 staff_id 假造稽核**，而那比沒有稽核更糟。 */
  select * into v_staff from public.current_staff();
  if v_staff.staff_id is null then
    return jsonb_build_object('ok', false, 'reason', 'no_staff_identity',
      'message', '取不到操作者身分，請重新登入');
  end if;

  if p_new_line_user_id is null or length(trim(p_new_line_user_id)) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'line_user_id_required');
  end if;

  select line_user_id, org_id into v_old, v_org
    from members where id = p_member_id and deleted_at is null;
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  /* ⚠ 新的 LINE 帳號若已被其他會員使用，必須先處理那一邊，不可直接覆蓋。
     🔴 這一道**不只是資料完整性** —— 少了它，換綁就變成
       「把別人的 LINE 搶過來掛到這個帳號上」。 */
  select id into v_taken from members
   where line_user_id = p_new_line_user_id and deleted_at is null and id <> p_member_id;
  if v_taken is not null then
    /* ⚠ **不回傳 `bound_member_id`**（舊版有回）——
       那正是上面說的「uuid 一旦漏出去就完蛋」，而這支函式自己漏它
       等於幫攻擊者完成第一步。同 2026-08-30 收掉 `line_conflict`
       回傳 member_id 的那個決定。 */
    return jsonb_build_object('ok', false, 'reason', 'line_user_already_bound',
      'message', '此 LINE 帳號已綁定其他會員，請先確認是否為同一人');
  end if;

  update members
     set line_user_id = p_new_line_user_id, updated_at = now()
   where id = p_member_id;

  /* 換綁是敏感操作，必須留下稽核軌跡（誰換的、何時、原因、換前換後）。
     ✅ 現在 `staff_id` 是**從 JWT 解析出來的**，不是呼叫端說的。 */
  perform log_app_event_tx(
    p_org_id    => v_org,
    p_member_id => p_member_id,
    p_event     => 'line_rebind',
    p_props     => jsonb_build_object('old', v_old, 'new', p_new_line_user_id,
                                      'staff_id', v_staff.staff_id,
                                      'staff_name', v_staff.name, 'reason', p_reason),
    p_client_ts => now());

  return jsonb_build_object('ok', true, 'old_line_user_id', v_old,
    'new_line_user_id', p_new_line_user_id, 'by', v_staff.name);
end $function$;

comment on function public.rebind_line_user_tx(uuid, text, text) is
  '店員把某個會員的 LINE 換成另一個。🔴 2026-09-04 修：'
  '在此之前 anon 就能叫且零檢查（＝帳號劫持），而 p_staff_id 只寫進 log 不驗證。'
  '現在走 can(staff.rebind)，操作者從 current_staff() 取。';

/* 🔴 兩個方向都要收（硬規則 2.6b）。
   ⚠ `authenticated` 要留 —— POS 登入後走的就是這個角色，
     真正的把關在函式裡的 `can()`。 */
revoke execute on function public.rebind_line_user_tx(uuid, text, text) from public;
revoke execute on function public.rebind_line_user_tx(uuid, text, text) from anon;
grant  execute on function public.rebind_line_user_tx(uuid, text, text) to authenticated, service_role;


-- ── C. 授予／撤銷店員身分：只有總部能做 ─────────────────
/* 🔴 在此之前這兩支 **`authenticated` 叫得動而且零檢查**
   ⇒ **任何登入的店員可以把自己升成 owner**，或把任何人加成店員。
   ⚠ 那讓上面那個「登入有擋」的保證整個失效：擋的是「不是店員的人」，
     而任何一個店員都能把別人變成店員。 */
create or replace function public.grant_staff_tx(
  p_member_id uuid, p_store_id uuid, p_role text default 'floor'
) returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_org uuid; v_name text; v_id uuid;
begin
  /* 🔴 **2026-09-04 新增的第一道**：授予店員身分是總部級操作。
     ⚠ 這支**沒有開機問題** —— 總部那條路走 Email Auth（`staff.auth_uid`），
       第一個管理員是在 Dashboard 手動建的，不依賴這支函式。 */
  if not public.can('staff.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden',
      'message', '只有總部可以設定店員');
  end if;

  -- ⚠ 這四個值必須與 staff_role_check 完全一致。
  --   2026-08-23 之前這裡寫的是 ('clerk','manager','hq') —— 與 CHECK 三個不同：
  --   clerk 不在 CHECK 裡（送了會 23514）、floor 與 owner 在 CHECK 裡卻被擋掉。
  --   結果是預設用法必定失敗，而那正是「把會員升級成店員」的標準用法。
  if p_role not in ('floor', 'manager', 'hq', 'owner') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_role',
      'message', '角色只能是 floor（一般店員）／manager（店長）／hq（總部）／owner（老闆）');
  end if;

  select org_id, display_name into v_org, v_name
    from members where id = p_member_id and deleted_at is null;
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found',
      'message', '找不到這位會員');
  end if;

  -- 已有記錄則更新角色（含已軟刪除的復職情況）
  select id into v_id from staff
   where member_id = p_member_id and store_id is not distinct from p_store_id;
  if v_id is not null then
    update staff set role = p_role, deleted_at = null,
                     name = coalesce(name, v_name), updated_at = now()
     where id = v_id;
    return jsonb_build_object('ok', true, 'staff_id', v_id, 'action', 'updated', 'role', p_role);
  end if;

  insert into staff(org_id, member_id, store_id, name, role)
  values (v_org, p_member_id, p_store_id, v_name, p_role)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'staff_id', v_id, 'action', 'created', 'role', p_role);
end $function$;

create or replace function public.revoke_staff_tx(p_staff_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_n int;
begin
  if not public.can('staff.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden',
      'message', '只有總部可以移除店員');
  end if;

  update staff set deleted_at = now(), updated_at = now()
   where id = p_staff_id and deleted_at is null;
  get diagnostics v_n = row_count;

  /* ⚠ **一定要看 `FOUND`／`row_count`** —— `register_member_tx` 就是因為
     沒看而謊報成功（2026-08-26 修）。改到 0 列要說出來。 */
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'not_found',
      'message', '找不到這位店員，或已經移除過了');
  end if;
  return jsonb_build_object('ok', true, 'staff_id', p_staff_id);
end $function$;

revoke execute on function public.grant_staff_tx(uuid, uuid, text) from public;
revoke execute on function public.grant_staff_tx(uuid, uuid, text) from anon;
grant  execute on function public.grant_staff_tx(uuid, uuid, text) to authenticated, service_role;
revoke execute on function public.revoke_staff_tx(uuid) from public;
revoke execute on function public.revoke_staff_tx(uuid) from anon;
grant  execute on function public.revoke_staff_tx(uuid) to authenticated, service_role;


-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
do $$
declare
  v_out text := '';
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_admin uuid; v_mid uuid; v_r jsonb; v_line text; v_line_mid uuid;
begin
  begin
    select auth_uid into v_admin from staff
     where auth_uid is not null and role in ('hq','owner') and deleted_at is null limit 1;

    /* 🔴 **第一次跑時 ⑦⑧ 安靜地沒出現，而那是取樣寫錯**（2026-09-04）。
       原本一句 `order by created_at limit 1` 同時當成 ⑥ 與 ⑦⑧ 的樣本，
       取到的是最早的會員（測試01）——**而它的 `line_user_id` 是 null**
       ⇒ `if v_line is not null` 整段跳過。

       🎯 **這比硬規則 3.56（期望值錯）更早一步：取樣就錯了。**
       ⚠ 而症狀最陰險：那兩格**不是變紅，是不出現** ——
         看到的人會以為「7 格全過」，但**沒通過的那一半正是
         「該通的有沒有通」**（硬規則 3.55）。
       → 兩個樣本各取各的，條件寫在 where 裡。 */
    select id into v_mid from members
     where org_id = v_org and deleted_at is null order by created_at limit 1;
    select id, line_user_id into v_line_mid, v_line from members
     where org_id = v_org and deleted_at is null and line_user_id is not null limit 1;

    ---- ① 簽名變了（`p_staff_id` 拿掉了）------------------
    v_out := v_out || E'\n' || '① rebind 的簽名不再收 p_staff_id' || E'\t' ||
      (select case when count(*) = 1 and max(pg_get_function_identity_arguments(oid)) not like '%p_staff_id%'
                   then '✅ ' || max(pg_get_function_identity_arguments(oid))
                   else '🔴 ' || count(*) || ' 個版本：' ||
                        string_agg(pg_get_function_identity_arguments(oid), ' ｜ ') end
         from pg_proc where pronamespace='public'::regnamespace and proname='rebind_line_user_tx');

    ---- ② 授權（DROP 會丟掉 GRANT，所以一定要驗）----------
    v_out := v_out || E'\n' || '② 三支都是 anon❌ PUBLIC❌ authenticated✅' || E'\t' ||
      (select case when count(*) = 3 then '✅ 三支都對'
                   else '🔴 只有 ' || count(*) || ' 支' end
         from pg_proc p
        where p.pronamespace='public'::regnamespace
          and p.proname in ('rebind_line_user_tx','grant_staff_tx','revoke_staff_tx')
          and not exists (select 1 from aclexplode(coalesce(p.proacl,'{}')) a
                           where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE')
          and not (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                           where a.grantee=0 and a.privilege_type='EXECUTE'))
          and exists (select 1 from aclexplode(coalesce(p.proacl,'{}')) a
                           where a.grantee='authenticated'::regrole::oid and a.privilege_type='EXECUTE'));

    ---- ③ 三支都有權限檢查 -------------------------------
    v_out := v_out || E'\n' || '③ 三支的函式體都有 can()' || E'\t' ||
      (select case when count(*) = 3 then '✅' else '🔴 只有 ' || count(*) || ' 支' end
         from pg_proc p
        where p.pronamespace='public'::regnamespace
          and p.proname in ('rebind_line_user_tx','grant_staff_tx','revoke_staff_tx')
          and pg_get_functiondef(p.oid) like '%public.can(%');

    ---- ④ 🎯 沒有身分時擋得住 ---------------------------
    /* 🔴 **這一格是這份 SQL 的核心**：修之前 anon 呼叫它會**直接改掉
       別人的 line_user_id**，而現在應該被 `can()` 擋下。 */
    perform set_config('request.jwt.claims',
      '{"sub":"99999999-9999-9999-9999-999999999999"}', true);
    v_r := public.rebind_line_user_tx(v_mid, 'U_attacker_0000000000000000000000');
    v_out := v_out || E'\n' || '④ 🎯 沒有店員身分 → 換綁被擋' || E'\t' ||
      case when (v_r ->> 'reason') = 'forbidden' then '✅ 擋住了'
           else '🔴 ' || v_r::text end;

    v_r := public.grant_staff_tx(v_mid, null, 'owner');
    v_out := v_out || E'\n' || '⑤ 🎯 沒有身分 → 不能把自己升成 owner' || E'\t' ||
      case when (v_r ->> 'reason') = 'forbidden' then '✅ 擋住了'
           else '🔴 ' || v_r::text end;

    ---- ⑥ 🔴 正對照：總部身分要做得到 --------------------
    /* 只驗「擋住了」的話，一支永遠回 forbidden 的實作也會全綠 ——
       而那會讓總部連自己的工具都用不了（硬規則 3.55）。 */
    perform set_config('request.jwt.claims',
      '{"sub":' || to_json(v_admin::text)::text || '}', true);
    v_r := public.grant_staff_tx(v_mid, null, 'floor');
    v_out := v_out || E'\n' || '⑥ 🎯 正對照：總部身分做得到' || E'\t' ||
      case when (v_r ->> 'ok')::boolean then '✅ ' || (v_r ->> 'action')
           else '🔴 ' || v_r::text end;

    ---- ⑦ 🔴 正對照：換綁在有身分時真的會動 --------------
    /* 🔴 **這兩格才是「該通的有沒有通」那一半。**
       只驗 ④⑤「擋住了」的話，一支永遠回 forbidden 的實作也會全綠 ——
       而那會讓店員連自己的工具都用不了（硬規則 3.55：
       **過度阻擋跟沒擋一樣糟，而且更難發現**）。 */
    if v_line_mid is not null then
      v_r := public.rebind_line_user_tx(v_line_mid, v_line || '_x');
      v_out := v_out || E'\n' || '⑦ 🎯 正對照：有身分時換綁真的成功' || E'\t' ||
        case when (v_r ->> 'ok')::boolean then '✅ by ' || coalesce(v_r ->> 'by', '?')
             else '🔴 ' || v_r::text end;

      v_out := v_out || E'\n' || '⑧ 稽核記到的是**解析出來的**操作者' || E'\t' ||
        (select case when count(*) > 0 then '✅ app_events 有 line_rebind 且帶 staff_name'
                     else '🔴 沒有留下紀錄' end
           from app_events
          where event = 'line_rebind' and props ? 'staff_name'
            and created_at > now() - interval '1 minute');
    else
      /* ⚠ 找不到樣本時**要說出來**，不要安靜跳過 ——
         那正是第一次跑時發生的事。 */
      v_out := v_out || E'\n' || '⑦⑧ 換綁的正對照' || E'\t' ||
        '🔴 **沒驗到**：找不到任何綁了 LINE 的會員。不要當成通過';
    end if;

    ---- ⑨ 沒有誤傷 A 那批營運函式 -----------------------
    /* ⚠ 它們**刻意不動**：POS 用 anon key，收了會直接打壞收銀機。
       那是待辦 14 的範圍（身分靠前端宣告 → 改吃 current_staff()）。 */
    v_out := v_out || E'\n' || '⑨ 🎯 正對照：POS 的營運函式沒被誤傷' || E'\t' ||
      (select case when count(*) = 4 then '✅ open/checkout/settle/void 都還是 anon 叫得動'
                   else '🔴 只剩 ' || count(*) || ' 支 —— POS 會壞' end
         from pg_proc p
        where p.pronamespace='public'::regnamespace
          and p.proname in ('open_session_tx','checkout_tx','settle_session_tx','void_session_tx')
          and (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                where a.grantee=0 and a.privilege_type='EXECUTE')
            or exists (select 1 from aclexplode(coalesce(p.proacl,'{}')) a
                where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE')));

    perform set_config('request.jwt.claims', '', true);
    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.gs', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.gs', true), E'\n')) as x
 where coalesce(x,'') <> '';
