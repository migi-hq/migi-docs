/* ============================================================
   消費明細改從 JWT 取身分（＋ 量退回次數）
   2026-09-09 · 待辦 14 的第 ③a 步
   ============================================================

   ── 這一步做什麼 ────────────────────────────────────────
   `get_my_orders_tx` 加上其餘 21 支會員端函式早就有的那一行：
   ```
   有 JWT → 用 JWT 解出來的會員
   沒有   → 退回前端送的 p_member_id（跟今天完全一樣）
   ```
   ⚠ **行為對現有的人完全不變** —— 拿得到 session 的走 JWT（結果一樣，
     因為他本來就只查自己），拿不到的退回原路。**這一步零風險。**

   ── 🔴 但它**不收 anon**，而那是刻意的 ────────────────────
   收掉 `anon` 是**第 ③c 步**，症狀是「會員打開錢包，最近消費空白」。
   而支撐它的證據今天只有 26 筆探針、來自一兩個人。
   🎯 **所以這一份的重點其實是第二件事：把「退回」變成一個可以查的數字。**

   ── 回傳多一個 `id_src`，三種值 ──────────────────────────
   | 值 | 意思 | 這個數字要變成 |
   |---|---|---|
   | `jwt` | 有 session，而且查的就是自己 | 越多越好 |
   | `param` | **沒有 session，靠退回才拿到資料** | 🎯 **要等它變 0 才能做 ③c** |
   | `jwt_override` | 🔴 有 session，但**參數指向別人** | **永遠應該是 0** |

   🔴 `jwt_override` 是這一份順帶換到的東西：它同時抓得到**bug**
     （前端送錯 id）與**攻擊**（拿別人的 uuid 來查）。
     ⚠ 而在此之前那件事**完全沒有痕跡** —— 函式會老老實實回別人的資料。

   ── ⚠ 為什麼是「回傳一個鍵」而不是埋點 ──────────────────
   `get_my_orders_tx` 是 **STABLE** ⇒ **函式體裡不能 INSERT**，
   埋不進 `app_events`（使用者這個 session 開頭問 `provolatile` 問的就是這件事）。
   三條路裡選這一條：
   · `raise notice` → 撈得到，但混在 Postgres log 的雜訊裡
   · ✅ **回傳一個鍵，讓前端用既有的埋點回報** → 零新基礎建設，
        而且那正是 `member_session` 探針已經在用的形狀
   · 改成 VOLATILE 去 INSERT → 動到函式特性與查詢規劃，代價不對稱

   ── ⚠ 前端不會壞 ───────────────────────────────────────
   回傳是 `jsonb`，多一個鍵不影響 `data.orders` / `data.has_more`。
   ✅ POS **已經不叫這一支了**（2026-09-09 改叫 `pos_member_orders_tx` 並部署，
     正式站產物確認過），所以這一層只有會員 App 會走到。

   ── 🔴 而 POS 那一支必須不受影響，那是整個拆分的目的 ──────
   店員本人也是會員 ⇒ 若 POS 走這一層，`current_member_id()` 會回**他自己**
   ⇒ 店員查客人時看到自己的帳，**而且不會報錯**。
   `pos_member_orders_tx` 直接呼叫 `_member_orders_core`（不經過這一層）
   ⇒ **結構上免疫**。驗證段第 ⑥ 格用**真的店員身分**證明它，不是推論。
   ============================================================ */

create or replace function public.get_my_orders_tx(
  p_member_id uuid,
  p_limit     int default 10,
  p_before    timestamptz default null
) returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_jwt uuid := public.current_member_id();
  v_src text;
begin
  /* ⚠ 三種值要**在覆寫之前**判斷 —— 算完 coalesce 才判斷的話，
     `jwt` 與 `jwt_override` 就分不出來了（而後者是這一份的重點）。
     📌 `p_member_id is null` 也算 `jwt`：那是「前端根本沒送」，
       不是「送了別人的」。 */
  v_src := case
             when v_jwt is null then 'param'
             when p_member_id is null or p_member_id = v_jwt then 'jwt'
             else 'jwt_override'
           end;

  /* ⚠ 兩者都是 null 時由 core 拋 `member_id required`（行為與今天相同）。 */
  return public._member_orders_core(coalesce(v_jwt, p_member_id), p_limit, p_before)
         || jsonb_build_object('id_src', v_src);
end $function$;

/* ⚠ 簽名沒變 ⇒ `CREATE OR REPLACE`、不 DROP、不掉 GRANT。
   🔴 **`anon` 刻意留著** —— 收它是第 ③c 步，要等 `id_src='param'` 的數字歸零。 */


/* ============================================================
   驗證段
   🎯 這一份最容易自欺的地方：**函式自己回報 `id_src`**。
     只看那個字串的話，一支「永遠回 'jwt' 但其實沒覆寫」的實作也會全綠。
   ⇒ 所以每一格都**同時看筆數** —— 兩個取樣的筆數不一樣，
     覆寫有沒有真的發生，筆數會說話。
   ============================================================ */
do $$
declare
  a_id uuid; b_id uuid; b_line text; nA int; nB int;
  v1 text; v2 text; v3 text; v4 text; r jsonb;
begin
  /* 取樣：A 訂單最多、B 有綁 LINE 且筆數與 A 不同。
     ⚠ 動態取樣不寫死 id —— 2026-09-01 照抄文件裡的會員 id，
       結果把三場戰績造給了錯的帳號（硬規則 3）。 */
  select m.id into a_id
    from members m join orders o on o.member_id = m.id
   where m.deleted_at is null and o.status = 'paid' and o.deleted_at is null
   group by m.id order by count(*) desc limit 1;

  select m.id, m.line_user_id into b_id, b_line
    from members m join orders o on o.member_id = m.id
   where m.deleted_at is null and m.line_user_id is not null and m.id <> a_id
     and o.status = 'paid' and o.deleted_at is null
   group by m.id, m.line_user_id order by count(*) asc limit 1;

  if a_id is null or b_id is null then
    perform set_config('migi.v1', '⚪ 取樣失敗，四格都測不了', true);
    perform set_config('migi.v2', '⚪ 同上', true);
    perform set_config('migi.v3', '⚪ 同上', true);
    perform set_config('migi.v4', '⚪ 同上', true);
    return;
  end if;

  /* 基準筆數（直接問 core，繞過這一層）。 */
  nA := jsonb_array_length(public._member_orders_core(a_id, 50, null) -> 'orders');
  nB := jsonb_array_length(public._member_orders_core(b_id, 50, null) -> 'orders');

  /* 🔴 兩個取樣筆數一樣的話，「覆寫有沒有生效」用筆數就分不出來
     ⇒ 這個驗證段會變成只信函式自己回報的字串。**要出聲。** */
  if nA = nB then
    perform set_config('migi.v1', '⚪ 兩個取樣筆數都是 ' || nA ||
      ' —— 筆數分不出覆寫有沒有生效，這一輪的 ③④ 不算數', true);
  end if;

  /* ── ③ 沒有 JWT → 退回參數，而且**資料照樣回得到** ──────
     🔴 只驗 `id_src='param'` 不夠：一支「回 param 但資料空了」的實作也會綠。 */
  begin
    perform set_config('request.jwt.claims', '', true);
    r := public.get_my_orders_tx(a_id, 50, null);
    v1 := 'id_src=' || coalesce(r->>'id_src','（沒有）')
       || ' · 筆數 ' || jsonb_array_length(r->'orders') || '（基準 ' || nA || '）'
       || E'\n' || case when r->>'id_src' = 'param' and jsonb_array_length(r->'orders') = nA
                        then '✅ 退回參數，資料完整（今天的行為沒變）'
                        else '🔴 不對' end;
  exception when others then v1 := '🔴 ' || left(coalesce(sqlerrm,'?'), 60);
  end;

  /* ── ④ 🎯 最重要：有 JWT，但參數指向**別人** ─────────────
     期望：回的是 **JWT 那個人（B）** 的資料，不是參數那個人（A）。
     🎯 **筆數就是證據** —— nB ≠ nA。 */
  begin
    perform set_config('request.jwt.claims',
      json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated',
                        'app_metadata', json_build_object('line_user_id', b_line))::text, true);
    r := public.get_my_orders_tx(a_id, 50, null);
    v2 := 'id_src=' || coalesce(r->>'id_src','（沒有）')
       || ' · 筆數 ' || jsonb_array_length(r->'orders')
       || '（JWT 那位 ' || nB || ' · 參數那位 ' || nA || '）'
       || E'\n' || case when r->>'id_src' = 'jwt_override' and jsonb_array_length(r->'orders') = nB
                        then '✅ JWT 蓋過參數 —— 拿別人的 uuid 查不到別人的資料'
                        when jsonb_array_length(r->'orders') = nA
                        then '🔴 回的是參數那個人的資料 —— 覆寫沒有生效'
                        else '🔴 不對' end;
  exception when others then v2 := '🔴 ' || left(coalesce(sqlerrm,'?'), 60);
  end;

  /* ── ⑤ 有 JWT 且參數就是自己 → `jwt`（最常見的那條路） ── */
  begin
    perform set_config('request.jwt.claims',
      json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated',
                        'app_metadata', json_build_object('line_user_id', b_line))::text, true);
    r := public.get_my_orders_tx(b_id, 50, null);
    v3 := 'id_src=' || coalesce(r->>'id_src','（沒有）')
       || ' · 筆數 ' || jsonb_array_length(r->'orders') || '（基準 ' || nB || '）'
       || E'\n' || case when r->>'id_src' = 'jwt' and jsonb_array_length(r->'orders') = nB
                        then '✅ 正常路徑' else '🔴 不對' end;
  exception when others then v3 := '🔴 ' || left(coalesce(sqlerrm,'?'), 60);
  end;

  /* ── ⑥ 🎯 負對照：POS 那一支**不可以**被 JWT 蓋掉 ────────
     🔴 這是整個拆分存在的理由。用**真的店員身分**（B 若同時是店員就更貼近，
       但只要 `current_member_id()` 解得出 B 就足以構成陷阱）呼叫
       `pos_member_orders_tx(A)`：
       · 回 A 的筆數 → ✅ 沒被蓋掉
       · 回 B 的筆數 → 🔴 店員查客人看到自己的帳 */
  begin
    perform set_config('request.jwt.claims',
      json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated',
                        'app_metadata', json_build_object('line_user_id', b_line))::text, true);
    r := public.pos_member_orders_tx(a_id, 50, null);
    v4 := case
      when r ? 'ok' and not (r->>'ok')::boolean
        then '⚪ 被業務邏輯擋下（' || coalesce(r->>'reason','?') || '）—— 這一格測不到'
      when r ? 'id_src'
        then '🔴 POS 那支也長出 id_src 了 —— 它不該經過這一層'
      when jsonb_array_length(coalesce(r->'orders','[]'::jsonb)) = nA
        then '✅ 回的是客人（' || nA || ' 筆）不是店員自己（' || nB || ' 筆）'
      when jsonb_array_length(coalesce(r->'orders','[]'::jsonb)) = nB
        then '🔴 回的是店員自己的帳 —— 拆分沒有生效'
      else '⚠ 筆數 ' || jsonb_array_length(coalesce(r->'orders','[]'::jsonb)) || '，兩個基準都對不上' end;
  exception when others then v4 := '🔴 ' || left(coalesce(sqlerrm,'?'), 70);
  end;

  perform set_config('request.jwt.claims', '', true);
  if nA <> nB then perform set_config('migi.v1', v1, true); end if;
  perform set_config('migi.v2', v2, true);
  perform set_config('migi.v3', v3, true);
  perform set_config('migi.v4', v4, true);
end $$;

select
  /* ── ① 仍是薄殼、簽名不變、anon 仍在 ── */
  (select rpad(p.proname, 22)
       || case when p.prosecdef then 'DEFINER' else '🔴 INVOKER' end
       || '　anon：' || case when exists (select 1 from aclexplode(p.proacl) a
              where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE')
            then '✅ 還在（③c 才收）' else '🔴 被提早收掉了' end
       || E'\n　本體：' || case when pg_get_functiondef(p.oid) ~ '_member_orders_core'
                                 and pg_get_functiondef(p.oid) !~ 'topup_orders'
                              then '✅ 仍是薄殼（沒有長出第二份查詢）'
                              else '🔴 本體有查詢邏輯' end
       || E'\n　參數：' || pg_get_function_identity_arguments(p.oid)
   from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind='f'
    and p.proname='get_my_orders_tx') as "① get_my_orders_tx 的狀態",

  /* ② 全庫數量（不新增函式、不動授權）：183 / 108 / 106，三個都該不變。 */
  (select '　函式總數：' || count(*) || '（期望 183，不變）'
     || E'\n　anon 明確：' || count(*) filter (where exists (
          select 1 from aclexplode(p.proacl) a where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE'))
     || '（期望 108，不變）'
     || E'\n　PUBLIC　　：' || count(*) filter (where p.proacl is null or exists (
          select 1 from aclexplode(p.proacl) a where a.grantee=0 and a.privilege_type='EXECUTE'))
     || '（期望 106，不變）'
   from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind='f') as "② 全庫數量",

  coalesce(nullif(current_setting('migi.v1', true), ''), '🔴 沒有訊息') as "③ 沒有 JWT → 退回參數（資料要完整）",
  coalesce(nullif(current_setting('migi.v2', true), ''), '🔴 沒有訊息') as "④ 🎯 參數指向別人 → JWT 要蓋過它",
  coalesce(nullif(current_setting('migi.v3', true), ''), '🔴 沒有訊息') as "⑤ 有 JWT 且查自己 → 正常路徑",
  coalesce(nullif(current_setting('migi.v4', true), ''), '🔴 沒有訊息') as "⑥ 🎯 負對照：POS 那支不受影響",

  /* ── ⑦ 之後要看的那個數字長什麼樣（現在必然是 0 —— 前端還沒接）。
       ⚠ **不是通過條件。** 它是給下次看的：`param` 歸零之前不要做 ③c。 */
  coalesce((
    /* ⚠ **要先分組再聚合** —— `string_agg(… || count(*))` 是巢狀聚合，
       Postgres 直接拋 `42803: aggregate function calls cannot be nested`。
       （2026-09-09 這一格就是這樣紅的，而錯的是驗證段不是函式。） */
    select string_agg(s.src || '：' || s.n, '　' order by s.n desc)
      from (
        select coalesce(props->>'src', '?') as src, count(*) as n
          from app_events
         where event = 'member_id_src' and created_at > now() - interval '7 days'
         group by 1
      ) s
  ), '（還沒有資料 —— 前端接上並部署之後才會開始長）') as "⑦ 參考：近 7 天的 id_src 分布";
