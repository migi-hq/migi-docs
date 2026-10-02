/* ============================================================
   POS 座位頁看四台平板的即時畫面（只能看）· 2026-10-02
   📄 使用者 2026-10-02：「POS 的座位頁要大修正，改成 4 個平板的分割即時畫面（不用 HEADER）」
     → 定案：跟平板一模一樣（含彈窗、鎖定遮罩），只能看、不能按；不要造成 POS 負擔

   做法：平板讀狀態的 tbl_state_tx 拆成「共用核心 ＋ 兩個入口」—— 四格才會跟平板**一模一樣**，不另外抄一份
     _tbl_state_for_device(平板)   原本 tbl_state_tx 的全文，只把「用憑證認平板」那一行換成直接收平板（內容一字不改）
     tbl_state_tx(憑證)            平板用：認出平板 → 叫核心（行為與以前完全相同，包含記最後上線時間）
     pos_tbl_watch_tx(桌)          🆕 POS 用：店員給一張桌，一次回這張桌每一台平板各自看到的畫面資料
   🎯 POS 每幾秒叫一次 pos_tbl_watch_tx，四格共用這一份，不是四格各讀各的（使用者問「會不會造成 POS 負擔」）。
   ⚠ POS 觀看**不經過**「用憑證認平板」那一步 ⇒ 不會改到平板的最後上線時間（不然店員開著座位頁，平板看起來永遠在線）。
   ⚠ 身分：只有店員、而且要能看這間店（has_store_access）才給看；前端傳什麼身分都不算數。
   ⚠ 新建的函式預設全關（硬規則 2.7）：pos_tbl_watch_tx 明確給 authenticated；核心只給後端（不給前端叫）。
   ⚠ 改的是線上全文，錨點必須剛好出現一次；查過沒有其他函式從內部叫 tbl_state_tx。
   ============================================================ */

-- ① 共用核心：拿 tbl_state_tx 的線上全文，只換兩處（函式名與參數、認平板那一行）
do $$
declare
  v_def text; v_n int;
  a1 text := 'CREATE OR REPLACE FUNCTION public.tbl_state_tx(p_token text)';
  b1 text := 'CREATE OR REPLACE FUNCTION public._tbl_state_for_device(p_device public.table_devices)';
  a2 text := '  d := public._tbl_device(p_token);';
  b2 text := '  d := p_device;   -- 平板由呼叫端給（tbl_state_tx 用憑證認、pos_tbl_watch_tx 由店員指定），其餘一字不改';
begin
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = '_tbl_state_for_device') then
    return;   -- 已經建過（可重跑）
  end if;
  v_def := pg_get_functiondef('public.tbl_state_tx(text)'::regprocedure);
  v_n := (length(v_def) - length(replace(v_def, a1, ''))) / length(a1);
  if v_n <> 1 then raise exception 'tbl_state_tx 的函式開頭出現 % 次（要剛好 1 次），整份不執行', v_n; end if;
  v_n := (length(v_def) - length(replace(v_def, a2, ''))) / length(a2);
  if v_n <> 1 then raise exception 'tbl_state_tx 的認平板那一行出現 % 次（要剛好 1 次），整份不執行', v_n; end if;
  if position('p_token' in replace(replace(v_def, a1, ''), a2, '')) > 0 then
    raise exception 'tbl_state_tx 除了那兩處之外還有用到 p_token，不能直接拆，整份不執行';
  end if;
  execute replace(replace(v_def, a1, b1), a2, b2);
end $$;

revoke execute on function public._tbl_state_for_device(public.table_devices) from public;
revoke execute on function public._tbl_state_for_device(public.table_devices) from anon, authenticated;

-- ② 平板的入口：認出平板 → 叫核心（簽名不變、CREATE OR REPLACE ⇒ 授權不會掉）
create or replace function public.tbl_state_tx(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  /* 2026-10-02 拆成共用核心：內容搬到 _tbl_state_for_device（一字不改），這裡只負責用憑證認出是哪一台平板
     （_tbl_device 也順便記最後上線時間）。POS 觀看走 pos_tbl_watch_tx，同一個核心 ⇒ 兩邊畫面不會漂 */
  return public._tbl_state_for_device(public._tbl_device(p_token));
end $$;

-- ③ POS 的入口：一張桌、每一台平板各自看到的畫面資料
create or replace function public.pos_tbl_watch_tx(p_table_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_store uuid; v_out jsonb;
begin
  /* 只有店員、而且要能看這間店。身分一律問 JWT（current_staff），不收前端傳的身分 */
  if (select staff_id from public.current_staff()) is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '只有店員可以看平板畫面');
  end if;
  select store_id into v_store from tables where id = p_table_id and deleted_at is null;
  if v_store is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這張桌');
  end if;
  if not public.has_store_access(v_store) then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '你不能看這間店的平板');
  end if;
  /* 每一台還在用的平板，依標籤排（A1-1、A1-2…）；畫面資料跟那台平板自己讀到的是同一份核心 */
  select coalesce(jsonb_agg(jsonb_build_object(
           'device_id', d.id, 'label', d.label, 'last_seen_at', d.last_seen_at,
           'state', public._tbl_state_for_device(d)) order by d.label), '[]'::jsonb)
    into v_out
    from table_devices d
   where d.table_id = p_table_id and d.is_active;
  return jsonb_build_object('ok', true, 'devices', v_out);
end $$;

revoke execute on function public.pos_tbl_watch_tx(uuid) from public;
revoke execute on function public.pos_tbl_watch_tx(uuid) from anon;
grant  execute on function public.pos_tbl_watch_tx(uuid) to authenticated;

/* ── 驗證（單一 SELECT；不用 raise，硬規則 1.8）──
   行為（換身分、拿真的平板比對兩個入口回的是不是同一份）在 sql/checks/2026-10-02_驗POS看四台平板畫面.sql */
with
f as (select p.proname, p.oid from pg_proc p where p.pronamespace = 'public'::regnamespace
       and p.proname in ('_tbl_state_for_device', 'tbl_state_tx', 'pos_tbl_watch_tx')),
acl as (
  select f.proname,
         bool_or(a.grantee = 0) as pub,
         bool_or(a.grantee = 'anon'::regrole::oid) as anon,
         bool_or(a.grantee = 'authenticated'::regrole::oid) as auth
    from f, pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
   where p.oid = f.oid and a.privilege_type = 'EXECUTE' group by f.proname)
select concat_ws(E'\n',
  case when (select count(*) from f) = 3 then '✅ ① 三支都在（核心、平板入口、POS 入口），各一個版本' else '🔴 ① 函式數 ' || (select count(*) from f) end,
  case when pg_get_functiondef('public._tbl_state_for_device(public.table_devices)'::regprocedure) ~ 'd := p_device;'
        and pg_get_functiondef('public._tbl_state_for_device(public.table_devices)'::regprocedure) !~ '_tbl_device\(p_token\)'
       then '✅ ② 核心收平板、不再用憑證' else '🔴 ② 核心沒有改對' end,
  case when pg_get_functiondef('public.tbl_state_tx(text)'::regprocedure) ~ '_tbl_state_for_device\(public\._tbl_device\(p_token\)\)'
       then '✅ ③ 平板入口改成「認平板 → 叫核心」' else '🔴 ③ 平板入口沒有改對' end,
  case when (select not pub and not anon and not auth from acl where proname = '_tbl_state_for_device') is not false
       then '✅ ④ 核心前端叫不到（PUBLIC、anon、authenticated 都沒有）' else '🔴 ④ 核心前端叫得到' end,
  case when (select anon and auth from acl where proname = 'tbl_state_tx')
       then '✅ ⑤ 平板入口授權沒變（平板用 anon 叫）' else '🔴 ⑤ 平板入口的授權變了 —— 平板會讀不到狀態' end,
  case when (select not pub and not anon and auth from acl where proname = 'pos_tbl_watch_tx')
       then '✅ ⑥ POS 入口只給登入的人（PUBLIC、anon 都收）' else '🔴 ⑥ POS 入口授權不對' end
) as "驗證";
