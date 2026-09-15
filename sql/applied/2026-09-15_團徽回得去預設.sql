/* ============================================================
   團徽回得去預設
   2026-09-15

   使用者說「預設團徽你沒改到，還是舊圖示」。查下去不是圖沒換，是**回不去**：

   ┌ 兩張抽屜的「預設」是兩個不同的東西 ────────────────┐
   │  建團抽屜的「預設團徽」 → crest_emoji 留 null → 顯示那張熊圖      │
   │  換團徽抽屜的「預設」   → set_team_crest_tx(emoji:'…') → 麻將字   │
   └──────────────────────────────────────────────────┘
   而且它**不可逆**：
   ```
   set_team_crest_tx:   crest_emoji = coalesce(v_emoji, crest_emoji)   ← 永遠清不掉
   clear_team_crest_tx: 只清 crest_path
   ```
   ⇒ 一旦設過圖示，那個團**再也回不到真正的預設團徽**，
     而畫面上看起來就是「預設團徽沒有換」。
     實際資料：`2486發財隊` 的 crest_emoji 就掛著那個麻將字。

   ── 這一份只做一件事 ────────────────────────────
   `clear_team_crest_tx` 從「清照片」變成「**清團徽**」＝ 兩個欄位一起清。
   它本來只清照片，而那時「預設」的意思還是圖示；
   預設換成圖檔之後，這支的語意就該跟著變成「回到系統預設」。

   🔴 **簽名一個字都不改** ⇒ `CREATE OR REPLACE`、不用 DROP、不會丟 GRANT。

   ⚠ 而 `p_member_id` 要**留著**，不可以改成 `current_member_id()`：
     這支只授權給 `service_role`，唯一的呼叫點是 Edge Function `team-crest`
     的 delete 模式，那裡走 service_role、**手上沒有會員的 JWT**
     ⇒ `current_member_id()` 在那個情境永遠是 null，改了會把「刪除團徽」
       整條打死，而且症狀是「按了說請先登入」。
     📌 身分在**上游**已經驗過（Edge Function 先驗 LINE id_token 再解出 member），
       與 `get_staff_by_line_tx` 是同一個形狀 —— 這不是「呼叫端宣告身分」。

   🎯 這一段是被打臉之後才寫對的：第一版我只 grep 了前端的 `social.js`，
     看到沒有呼叫點就打算改簽名。**Edge Function 不在那次搜尋範圍裡。**
     同硬規則 3：改既有函式之前，呼叫點要連 `supabase/functions/` 一起找。

   🔴 這份留下 DDL ⇒ **一個 raise 都不准有**（硬規則 1.8）。
   ============================================================ */

create or replace function public.clear_team_crest_tx(p_team_id uuid, p_member_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_old text;
begin
  if not public._is_team_leader(p_team_id, p_member_id) then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以換團徽');
  end if;

  select t.crest_path into v_old from public.teams t
   where t.id = p_team_id and t.deleted_at is null;

  /* 🔴 兩個欄位一起清才是「回到預設」。
     只清照片的話，設過圖示的團會退回那個圖示而不是預設團徽 ——
     而那正是使用者看到的症狀。
     ⚠ `crest_blocked` **不在這裡碰**：那是總部下架違規團徽用的旗標，
       團長自己清團徽不該把它解開。 */
  update public.teams
     set crest_path = null, crest_emoji = null, updated_at = now()
   where id = p_team_id and deleted_at is null;

  /* 回傳舊路徑讓 Edge Function 去刪 storage 的檔案 ——
     **路徑由這裡給，不採信呼叫端送的**，不然那是一個「刪別人檔案」的洞。 */
  return jsonb_build_object('ok', true, 'path', v_old);
end $function$;


/* ── 驗證（單一 SELECT，全程不 raise：這份要留下 DDL） ─── */
do $$
declare
  v_msg text := '';
  v_n   int;
  v_txt text;
  v_row record;
begin
  /* ① 只有一個版本，而且簽名沒被動到（動了 Edge Function 就會 404） */
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname = 'clear_team_crest_tx';
  select pg_get_function_identity_arguments(p.oid) into v_txt from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname = 'clear_team_crest_tx' limit 1;
  v_msg := v_msg || case when v_n = 1 and v_txt = 'p_team_id uuid, p_member_id uuid' then '✅' else '🔴' end
        || ' ① 版本數 ' || v_n || '　簽名：' || coalesce(v_txt, '（找不到）')
        || E'\n      （簽名必須原封不動 —— Edge Function team-crest 正在照這個簽名呼叫）';

  /* ② 兩個欄位一起清。
     ⚠ 掃的是**賦值那一段**，不是欄位名 —— 欄位名在註解裡也會出現（硬規則 3.5）。 */
  select pg_get_functiondef(p.oid) into v_txt from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname = 'clear_team_crest_tx';
  v_msg := v_msg || E'\n' || case when v_txt like '%crest_path = null, crest_emoji = null%' then '✅' else '🔴' end
        || ' ② 照片與圖示兩個欄位一起清';

  /* ③ 授權沒被動到。只印角色清單讓人判讀，不回傳是非題（硬規則 3.5）。
     ⚠ 期望值當場查過：這支是 **service_role 專用**，
       前端走 Edge Function，不直接叫它。 */
  select coalesce(string_agg(distinct case when a.grantee = 0 then 'PUBLIC'
                                           else a.grantee::regrole::text end, '、'), '（完全沒有授權）')
    into v_txt
    from pg_proc p
    left join lateral aclexplode(p.proacl) a on a.privilege_type = 'EXECUTE'
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname = 'clear_team_crest_tx';
  v_msg := v_msg || E'\n' || case when v_txt not like '%anon%'
                                   and v_txt not like '%authenticated%'
                                   and v_txt not like '%PUBLIC%' then '✅' else '🔴' end
        || ' ③ 可執行：' || v_txt || '（前端三個角色一個都不該有）';

  /* ④ 負對照：另一支設定團徽的函式沒被波及（它與這支是一對） */
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname = 'set_team_crest_tx';
  v_msg := v_msg || E'\n' || case when v_n = 1 then '✅' else '🔴' end
        || ' ④ 設定團徽那支 版本數 ' || v_n || '（不該被這一批動到）';

  /* ⑤ 現況：哪些團還掛著圖示。逐行印出讓人判讀。
     📌 這一格是給人看的：清掉是**團長自己的動作**（在抽屜裡按一次「預設團徽」），
       不在這裡幫他們改 —— 那是「沒有人做過那個決定」。 */
  v_msg := v_msg || E'\n⚪ ⑤ 目前還掛著圖示的團（要回到預設團徽，請團長在抽屜按一次「預設團徽」）：';
  v_n := 0;
  for v_row in
    select t.name, t.crest_emoji from public.teams t
     where t.deleted_at is null and t.crest_emoji is not null
     order by t.created_at
  loop
    v_msg := v_msg || E'\n      ' || rpad(v_row.name, 18) || v_row.crest_emoji;
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then v_msg := v_msg || E'\n      （沒有，全部都是預設團徽或自己的照片）'; end if;

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
