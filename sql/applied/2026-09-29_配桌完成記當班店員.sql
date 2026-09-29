-- ════════════════════════════════════════════════════════════════════
-- 2026-09-29 配桌完成那一刻，記下當班的店員（獎金歸屬）
-- 📄 規則：CLAUDE.md 13.9c（2026-09-29 使用者）
--   列入條件  有收桌（status = completed）＋ 這一場是配桌來的；包桌預約、現場直接開桌不列入
--   算給誰    配桌完成（match_queues 從 waiting 變成 matched）那一刻當班的店員
--             ⚠ 不是按收桌的人（交班時下一位常常只是代按）、也不是開桌的人（配桌完成後可能換班才開桌）
--
-- 「當班」本來就有：POS 的設計是「登入的人＝當班的人」，交接班完成後按「交班登出」、下一位再登入。
-- 缺的只是**資料庫不知道** —— 那只存在 POS 那台機器上，而配桌湊滿常常是客人在 App 按的、
-- pg_cron 自動帶桌，那一刻沒有任何店員動作。所以：
--   ① stores.on_duty_staff_id / on_duty_since    這間店現在是誰（POS 門市確定或切換時寫、交班登出時清）
--   ② pos_set_on_duty_tx(store) / pos_clear_on_duty_tx()   POS 呼叫；身分一律從登入的 JWT 取，不收前端送的 id
--   ③ match_queues.credited_staff_id + 觸發器     waiting → matched 那一刻把當班店員記在那一場配桌上
--      （之後換班、改當班都不會回頭改掉已經發生的歸屬）；退回 waiting 就清掉，下次湊滿再記
--      ⚠ 那一刻沒人登入 ⇒ 記成 null ⇒ 那一場算不到任何人（看得出來，不是默默算錯人）
--   ④ 順手更正 table_sessions.closed_by_staff_id 的欄位說明（上一份寫成「獎金只認這一欄」，那是錯的）
--
-- ⚠ 一間店同一時間只有一位店員（使用者 2026-09-29）⇒ 後登入的人直接取代前一位，不做多人分攤。
-- ⚠ 只新增、不改任何既有函式 ⇒ 不需要套用前的錨點檢查。
-- ⚠ 這份要留下東西 ⇒ 驗證段一個字都不准 raise（硬規則 1.8）。
--   行為測試：sql/checks/2026-09-29_驗配桌完成記當班店員.sql（交易內造樣本、最後回滾）
-- ════════════════════════════════════════════════════════════════════

-- ① 這間店現在是誰 ───────────────────────────────────────────────────
alter table public.stores
  add column if not exists on_duty_staff_id uuid references public.staff(id),
  add column if not exists on_duty_since   timestamptz;

comment on column public.stores.on_duty_staff_id is
  '這間店現在當班的店員（POS 門市確定或切換時由 pos_set_on_duty_tx 寫入、交班登出時由 pos_clear_on_duty_tx 清掉）。
   一間店同一時間只有一位店員：後登入的人直接取代前一位。null ＝ 現在沒有人登入。
   配桌完成那一刻會把它複製到 match_queues.credited_staff_id（獎金歸屬）。';

-- ③-a 配桌完成那一刻的當班店員 ───────────────────────────────────────
alter table public.match_queues
  add column if not exists credited_staff_id uuid references public.staff(id);

comment on column public.match_queues.credited_staff_id is
  '配桌完成（waiting → matched）那一刻這間店當班的店員 ＝ 獎金歸屬（2026-09-29 使用者）。
   由觸發器 trg_match_queues_credit 寫入，不接受前端指定；退回 waiting 會清掉、下次湊滿再記。
   null ＝ 那一刻沒有店員登入 ⇒ 這一場算不到任何人。
   獎金還要這一場有收桌（table_sessions.status = completed）才列入。';

-- ④ 更正上一份寫錯的欄位說明 ─────────────────────────────────────────
comment on column public.table_sessions.closed_by_staff_id is
  '按收桌的店員（settle_session_tx 從登入身分寫入，第一次按的人為準，之後不會被覆蓋）。稽核用。
   ⚠ 不是獎金歸屬：交班時下一位常常只是代按收桌。獎金看 match_queues.credited_staff_id（2026-09-29 更正）。
   null ＝ 還沒收桌，或不是店員收的。';

-- ② POS 呼叫的兩支 ───────────────────────────────────────────────────
create or replace function public.pos_set_on_duty_tx(p_store_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_staff uuid;
begin
  /* 身分從 JWT 取（current_staff），不收前端送的 staff_id —— 前端可填的歸屬比沒有更糟。
     同一個人可能有好幾列 staff（不同門市）：優先用「這間店」那一列；
     沒有的話，老闆／總部那一列（沒有門市）要有全部門市權限才算數。 */
  select cs.staff_id into v_staff
    from public.current_staff() cs
   where cs.store_id = p_store_id
      or (cs.store_id is null and public.can('store.all'))
   order by (cs.store_id = p_store_id) desc nulls last
   limit 1;
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff_of_store', 'message', '你不是這間店的店員');
  end if;

  -- 一個人一次只在一間店當班：先把他從別間店拿掉
  update stores set on_duty_staff_id = null, on_duty_since = null
   where on_duty_staff_id in (select cs.staff_id from public.current_staff() cs)
     and id <> p_store_id;

  -- 已經是他就不動時間（POS 每次開機、切回來都會叫，不要讓「當班起點」一直往後跳）
  update stores set on_duty_staff_id = v_staff, on_duty_since = now()
   where id = p_store_id and on_duty_staff_id is distinct from v_staff;

  return jsonb_build_object('ok', true, 'staff_id', v_staff, 'store_id', p_store_id);
end $$;

create or replace function public.pos_clear_on_duty_tx()
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_n int;
begin
  /* 交班登出：只清「自己」—— 下一位如果已經先登入了（取代了我），不可以把他清掉 */
  update stores set on_duty_staff_id = null, on_duty_since = null
   where on_duty_staff_id in (select cs.staff_id from public.current_staff() cs);
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'cleared', v_n);
end $$;

-- 授權：兩個方向都收（硬規則 2.6／2.6b），只給登入的店員
revoke execute on function public.pos_set_on_duty_tx(uuid) from public;
revoke execute on function public.pos_set_on_duty_tx(uuid) from anon;
grant  execute on function public.pos_set_on_duty_tx(uuid) to authenticated;
revoke execute on function public.pos_clear_on_duty_tx() from public;
revoke execute on function public.pos_clear_on_duty_tx() from anon;
grant  execute on function public.pos_clear_on_duty_tx() to authenticated;

-- ③-b 觸發器 ─────────────────────────────────────────────────────────
create or replace function public.trg_match_queues_credit()
returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  if new.status = 'matched' and old.status = 'waiting' then
    -- 配桌完成的那一刻（_finalize_queue_full_tx）
    new.credited_staff_id := (select on_duty_staff_id from stores where id = new.store_id);
  elsif new.status = 'waiting' and old.status is distinct from 'waiting' then
    -- 取消開桌、人不夠退回等人 ⇒ 這次配桌不算數，下次湊滿再記
    new.credited_staff_id := null;
  end if;
  -- ⚠ seated → matched（取消開桌但人還夠）不動：配桌完成的那一刻沒變
  return new;
end $$;

revoke execute on function public.trg_match_queues_credit() from public;
revoke execute on function public.trg_match_queues_credit() from anon, authenticated;

drop trigger if exists trg_match_queues_credit on public.match_queues;
create trigger trg_match_queues_credit
  before update of status on public.match_queues
  for each row execute function public.trg_match_queues_credit();

-- ⑤ 驗證（單一 SELECT，不 raise）────────────────────────────────────────
do $$
declare v text := ''; n int; t text; ok text := '✅ '; bad text := '🔴 ';
begin
  select count(*) into n from information_schema.columns
   where table_schema = 'public'
     and ((table_name = 'stores' and column_name in ('on_duty_staff_id', 'on_duty_since'))
       or (table_name = 'match_queues' and column_name = 'credited_staff_id'));
  v := v || (case when n = 3 then ok else bad end) || '① 三個新欄位都在（' || n || '/3）' || E'\n';

  select count(*) into n from pg_trigger
   where tgrelid = 'public.match_queues'::regclass and not tgisinternal and tgname = 'trg_match_queues_credit';
  v := v || (case when n = 1 then ok else bad end) || '② match_queues 的觸發器在' || E'\n';

  select count(*) into n from pg_proc
   where pronamespace = 'public'::regnamespace and proname in ('pos_set_on_duty_tx', 'pos_clear_on_duty_tx', 'trg_match_queues_credit');
  v := v || (case when n = 3 then ok else bad end) || '③ 三支函式各一個版本（' || n || '/3）' || E'\n';

  -- 授權：兩種來源都看（硬規則 2.6／2.6b）
  select string_agg(p.proname, '、') into t
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('pos_set_on_duty_tx', 'pos_clear_on_duty_tx', 'trg_match_queues_credit')
     and (p.proacl is null
          or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')
          or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE'));
  v := v || (case when t is null then ok else bad end) || '④ 沒有 PUBLIC／anon 可執行' || coalesce('：' || t, '') || E'\n';

  -- 正對照：POS 登入後叫得動（authenticated 要有）
  select count(*) into n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('pos_set_on_duty_tx', 'pos_clear_on_duty_tx')
     and exists (select 1 from aclexplode(p.proacl) a where a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE');
  v := v || (case when n = 2 then ok else bad end) || '⑤ 正對照：兩支 POS 函式登入的店員叫得動（' || n || '/2）' || E'\n';

  select count(*) into n from pg_description d
   where d.objoid = 'public.table_sessions'::regclass
     and d.description like '%不是獎金歸屬%';
  v := v || (case when n = 1 then ok else bad end) || '⑥ closed_by_staff_id 的說明已更正（不再寫「獎金只認這一欄」）' || E'\n';

  perform set_config('migi.v', v, true);
end $$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有訊息') as "驗證";
