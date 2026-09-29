/* ============================================================
   預設權限改成「全關」：新建的函式／表／檢視表，前端一律碰不到，要用的才明確開放
   2026-09-29 · 使用者問「是不是每做一個新功能都要檢查 anon 繞過 RLS」

   ── 根因（唯讀 MCP 查 pg_default_acl）──────────────────────
   postgres 在 public 的預設：
     函式            anon、authenticated 自動 EXECUTE
     表／檢視表      anon、authenticated 自動 全部權限（讀寫刪）
     序列            anon、authenticated 自動 讀與遞增
   ＋ Postgres 內建的全域規則：新函式自動給 PUBLIC EXECUTE（schema 那一層收不掉這條）
   ⇒ **每個新功能一出生就是公開的**，要有人記得收；忘了收不會有任何錯誤。
     這個專案因此修過六次：9/4 換綁提權、9/10 頭像下架、9/11 埋點身分、
     9/20 收退回、9/29 檢視表、9/29 54 支函式。

   ── 改完之後 ───────────────────────────────────────────
   · 新東西預設只有 postgres 與 service_role 碰得到
   · 要給前端叫的新 RPC，同一份 SQL 裡**明確寫**：
       grant execute on function public.xxx(...) to authenticated;        -- 登入的人
       grant execute on function public.xxx(...) to anon, authenticated;  -- 連沒登入的也要（少見）
   · 忘了寫的後果從「安靜地外洩」變成「前端一叫就 permission denied」——
     測試時第一次按就會發現。**讓錯誤大聲出現**。
   ⚠ 已經存在的東西**完全不受影響**（預設權限只管以後新建的）⇒ 今天的前端不會壞。
   ⚠ 只改 postgres 那一組（SQL Editor 用的身分）。supabase_admin 那一組不動：
     那是 Supabase 自己建東西用的，我們的 SQL 不會用那個身分建。
   ⚠ storage schema 不動（Supabase 管的）。
   ⚠ 全域那一條也會影響以後在 extensions 裝的新套件函式（不再給 PUBLIC）——
     前端從來不直接叫套件函式，我們的 DEFINER 函式以 postgres 身分跑，照樣叫得到。
   ⚠ 硬規則 2 的「DROP 重建要補 grant」從此更重要：DROP 重建 ＝ 新建 ⇒ 預設是關的。

   ── 這份要留下東西 ⇒ 驗證段一個字都不 raise（硬規則 1.8）──
     驗證段用 savepoint 包住試探物件：建一支函式、一張檢視表，量完權限就退掉，不留下來。
   ============================================================ */

alter default privileges for role postgres in schema public revoke all on functions from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on tables    from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres revoke execute on functions from public;   -- 全域：Postgres 內建的 PUBLIC 那條

/* ── 驗證段（單一 SELECT，不 raise）────────────────────────── */
do $$
declare v_msg text := ''; v_t text; f_anon bool; f_auth bool; f_pub bool; f_sr bool; v_anon bool; v_auth bool;
begin
  /* ① public 那三組給前端的都沒了 */
  select string_agg(d.defaclobjtype::text, ',') into v_t
    from pg_default_acl d, aclexplode(d.defaclacl) a
   where d.defaclrole = 'postgres'::regrole and d.defaclnamespace = 'public'::regnamespace
     and a.grantee in ('anon'::regrole::oid, 'authenticated'::regrole::oid);
  v_msg := v_msg || case when v_t is null then '✅ ① postgres 在 public 的預設不再給 anon／authenticated'
                         else '🔴 ① 還有給前端的預設：' || v_t end;

  /* ② 🎯 正對照：真的建一支新函式與一張新檢視表，看它一出生是不是關的（量完就退掉）
        只看 pg_default_acl 的話，全域 PUBLIC 那條漏掉也會綠 —— 所以要真的建一次 */
  begin
    create function public._zz_default_probe() returns int language sql as 'select 1';
    create view public._zz_default_probe_v as select 1 as x;
    f_anon := has_function_privilege('anon',          'public._zz_default_probe()', 'EXECUTE');
    f_auth := has_function_privilege('authenticated', 'public._zz_default_probe()', 'EXECUTE');
    f_pub  := exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                       where p.oid = 'public._zz_default_probe()'::regprocedure and a.grantee = 0);
    f_sr   := has_function_privilege('service_role',  'public._zz_default_probe()', 'EXECUTE');
    v_anon := has_table_privilege('anon',          'public._zz_default_probe_v', 'SELECT');
    v_auth := has_table_privilege('authenticated', 'public._zz_default_probe_v', 'SELECT');
    raise exception 'probe_rollback';   -- 只退這個 savepoint，試探物件不留下來
  exception when others then
    if sqlerrm <> 'probe_rollback' then v_msg := v_msg || E'\n🔴 ② 試探物件建不起來：' || sqlerrm; end if;
  end;
  v_msg := v_msg || E'\n' || case when f_anon = false and f_auth = false and f_pub = false
    then '✅ ② 新建的函式：anon／authenticated／PUBLIC 都叫不到'
    else '🔴 ② 新建的函式仍然開放：anon=' || coalesce(f_anon::text,'?') || ' auth=' || coalesce(f_auth::text,'?') || ' PUBLIC=' || coalesce(f_pub::text,'?') end;
  v_msg := v_msg || E'\n' || case when v_anon = false and v_auth = false
    then '✅ ③ 新建的檢視表：anon／authenticated 都讀不到'
    else '🔴 ③ 新建的檢視表仍然開放：anon=' || coalesce(v_anon::text,'?') || ' auth=' || coalesce(v_auth::text,'?') end;
  v_msg := v_msg || E'\n' || case when f_sr then '✅ ④ 正對照：service_role 照樣叫得到新函式（Supabase 那一條沒被誤收）'
                                   else '🔴 ④ service_role 也叫不到了 —— 收過頭' end;

  /* ⑤ 試探物件真的沒留下來 */
  v_msg := v_msg || E'\n' || case when to_regprocedure('public._zz_default_probe()') is null and to_regclass('public._zz_default_probe_v') is null
    then '✅ ⑤ 試探物件已退掉，沒有留下' else '🔴 ⑤ 試探物件還在 —— 請手動 drop' end;

  /* ⑥ 負對照：既有的前端函式沒被影響（預設權限只管以後） */
  v_msg := v_msg || E'\n' || case when has_function_privilege('anon', 'public.list_stores_tx(uuid)', 'EXECUTE')
                                    and has_function_privilege('authenticated', 'public.get_wallet_tx(uuid,integer)', 'EXECUTE')
    then '✅ ⑥ 負對照：既有的前端函式照常（門市清單、錢包）' else '🔴 ⑥ 既有函式被影響了' end;

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
