/* ═══════════════════════════════════════════════════════════════════
   點心改由後端說了算：關上前端那扇門
   2026-09-19 · 接續「按讚發小熊餅乾」那一份
   ═══════════════════════════════════════════════════════════════════

   🔴 **上一份只做了一半。** `snack_grants` 帳本與 `grant_snack_tx` 建好了，
     但 `save_app_state_tx` 仍然接受整包 `bear`（含 `snacks`）並直接覆蓋
     ⇒ **前端還是可以自己塞 999 個餅乾**，帳本形同虛設。
   📌 實證：測試02 帳上有 90 個餅乾，而 `snack_grants` 是 0 筆 ——
     那 90 個全部是前端寫進去的。

   ── 為什麼不能只加一行「忽略 snacks」────────────────
   🔴 **餵小熊是唯一真的會扣點心的地方**（`rewards.jsx` 的 `feedBear`／
     `feedSnack`），而它也是走同一個 `save_app_state_tx`。
     只擋寫入、不給消耗的路 ⇒ **餵了之後重整，點心會復活**，
     而畫面上完全看不出為什麼。
   ⇒ 所以這一份必須同時給「消耗」一條後端的路。

   ── 這份做三件事 ────────────────────────────────────
   ① 帳本放寬成**雙向**：`qty <> 0`（發放為正、消耗為負），
      餘額 = `sum(qty)`。形狀與 `wallet_txns` 一致（那是這個專案唯一
      一個做對的流水）。⚠ 表名維持 `snack_grants` 不改 ——
      改名要動剛寫好的函式與索引，而那不值得。**名字不準確是已知的代價。**
   ② `consume_snack_tx` —— 餵食走這裡。**身分一律從 JWT 取**，
      不採信呼叫端送的 member_id（他只能扣自己的）。
   ③ `save_app_state_tx` **忽略傳進來的 snacks**，一律保留資料庫既有值。
      ⚠ 小熊造型、等級、成長值、名字**維持前端說了算** ——
        那是他自己的選擇（硬規則：內容不是狀態）。點心是獎勵，屬於系統的認定。

   ⚠ 這份要留下 DDL ⇒ 驗證段一個字都不准 raise（硬規則 1.8）。
     行為測試在 `sql/checks/2026-09-19_驗點心關門.sql`。
   ═══════════════════════════════════════════════════════════════════ */


/* ═══ ① 帳本改雙向 ═══════════════════════════════════════════ */
alter table public.snack_grants drop constraint if exists snack_grants_qty_check;
alter table public.snack_grants add  constraint snack_grants_qty_check check (qty <> 0);

alter table public.snack_grants drop constraint if exists snack_grants_reason_check;
alter table public.snack_grants add  constraint snack_grants_reason_check
  check (reason in ('like', 'daily', 'task', 'draw', 'admin', 'feed'));

comment on table public.snack_grants is
  '點心流水（雙向）：qty > 0 是發放、qty < 0 是消耗。餘額 = sum(qty)。'
  '⚠ 表名寫 grants 是歷史（建立當天只有發放），改名要動函式與索引，不值得。';


/* ═══ ② 消耗（餵小熊）═══════════════════════════════════════════
   回 `{ ok, spent, kind, qty, total }`；餘額不足回
   `{ ok:false, reason:'insufficient', total }` —— 前端照它把畫面退回去。 */
create or replace function public.consume_snack_tx(
  p_org_id uuid, p_member_id uuid, p_kind text, p_qty int default 1,
  p_ref_id uuid default null, p_idem_key text default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_me    uuid;
  v_have  int;
  v_key   text;
  v_id    uuid;
  v_total int;
begin
  /* 🔴 身分從 JWT 取，不採信呼叫端（待辦 14 的通則）。
     ⚠ 這一支給前端叫得到，所以這道牆比發放那支更重要 ——
       沒有它就是「給我一個 member_id 就扣光他的點心」。 */
  v_me := coalesce(public.current_member_id(), p_member_id);
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_kind is null or coalesce(p_qty, 0) <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_args');
  end if;

  /* 餘額是**帳本算出來的**，不是讀 `bear.snacks`
     —— 那一欄從今天起是顯示值，不是來源。 */
  select coalesce(sum(qty), 0) into v_have
    from snack_grants where member_id = v_me and kind = p_kind;

  if v_have < p_qty then
    return jsonb_build_object('ok', false, 'reason', 'insufficient',
      'message', '點心不夠', 'total', v_have);
  end if;

  /* 冪等鍵：呼叫端沒給就自己產一把。
     ⚠ 餵食是**刻意重複**的動作（連餵三個），所以預設不是「同一把鑰匙」；
       但網路重試時前端可以送同一把，避免扣兩次。 */
  v_key := coalesce(p_idem_key, 'feed:' || v_me::text || ':' || gen_random_uuid()::text);

  insert into snack_grants (org_id, member_id, kind, qty, reason, ref_id, idem_key)
  values (p_org_id, v_me, p_kind, -p_qty, 'feed', p_ref_id, v_key)
  on conflict (idem_key) do nothing
  returning id into v_id;

  if v_id is null then
    select coalesce(sum(qty), 0) into v_total from snack_grants where member_id = v_me and kind = p_kind;
    return jsonb_build_object('ok', true, 'spent', false, 'reason', 'already_spent', 'total', v_total);
  end if;

  update member_app_state set
    bear = jsonb_set(coalesce(bear, '{}'::jsonb), array['snacks', p_kind],
             to_jsonb(greatest(0, coalesce((bear -> 'snacks' ->> p_kind)::int, 0) - p_qty)), true),
    updated_at = now()
   where member_id = v_me;

  select coalesce(sum(qty), 0) into v_total from snack_grants where member_id = v_me and kind = p_kind;
  return jsonb_build_object('ok', true, 'spent', true, 'kind', p_kind, 'qty', p_qty, 'total', v_total);
end $function$;

/* ⚠ 這一支**要給前端叫**（餵食是前端動作）。
   風險可接受：他只扣得到自己的（身分從 JWT 取），而且扣光只是自己吃虧。 */
grant execute on function public.consume_snack_tx(uuid, uuid, text, int, uuid, text) to anon, authenticated;


/* ═══ ③ 關門：存檔時忽略 snacks ═══════════════════════════════
   ⚠ 簽名不變 ⇒ CREATE OR REPLACE，前端照舊呼叫（只是送什麼 snacks 都沒用）。 */
create or replace function public.save_app_state_tx(p_org_id uuid, p_member_id uuid, p_bear jsonb, p_titles jsonb default null::jsonb)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
  if pg_column_size(p_bear) > 8192 then raise exception 'bear state 過大'; end if;

  /* 🔴 **2026-09-19：`snacks` 一律忽略。**
     點心是**獎勵**（系統對事實的認定），來源只有 `grant_snack_tx`／`consume_snack_tx`；
     小熊的等級、成長值、造型、名字仍然前端說了算（那是他自己的選擇）。
   ⚠ 做法是「剝掉再貼回資料庫既有的那份」，不是拒絕整包 ——
     拒絕會讓前端存不了等級與名字，而那是無辜的。
   ⚠ 新會員（還沒有列）**不給預設點心**：`- 'snacks'` 之後就沒有那個鍵，
     發放函式第一次發時會自己建。 */
  insert into member_app_state(member_id, org_id, bear, titles, updated_at)
  values (p_member_id, p_org_id, coalesce(p_bear, '{}'::jsonb) - 'snacks', coalesce(p_titles, '[]'::jsonb), now())
  on conflict (member_id) do update set
    bear = (coalesce(excluded.bear, '{}'::jsonb) - 'snacks')
           || jsonb_build_object('snacks', coalesce(member_app_state.bear -> 'snacks', '{}'::jsonb)),
    -- 稱號聯集：只增不減（防舊裝置覆蓋掉新解鎖）
    titles = (select jsonb_agg(distinct t) from jsonb_array_elements_text(member_app_state.titles || excluded.titles) t),
    updated_at = now();
end $function$;


/* ═══ 驗證段（不 raise）═══════════════════════════════════════ */
do $$
declare
  v_msg text := '';
  v_def text;
  v_n   int;
begin
  /* ① 帳本可以記負數了 */
  select count(*) into v_n from pg_constraint
   where conrelid = 'public.snack_grants'::regclass
     and conname = 'snack_grants_qty_check'
     and pg_get_constraintdef(oid) ilike '%<> 0%';
  v_msg := case when v_n = 1
    then '✅ ① 帳本改雙向（qty <> 0，發放為正、消耗為負）'
    else '🔴 ① qty 約束還是只允許正數 —— 消耗記不進去' end;

  /* ② feed 進了 reason 白名單 */
  v_msg := v_msg || E'\n' || case when exists (
      select 1 from pg_constraint
       where conrelid = 'public.snack_grants'::regclass
         and conname = 'snack_grants_reason_check'
         and pg_get_constraintdef(oid) ilike '%feed%')
    then '✅ ② reason 白名單含 feed'
    else '🔴 ② feed 不在白名單 —— 餵食會被 CHECK 擋下' end;

  /* ③ 消耗函式在，而且前端叫得動（餵食是前端動作）*/
  v_msg := v_msg || E'\n' || case
    when has_function_privilege('anon', 'public.consume_snack_tx(uuid,uuid,text,int,uuid,text)', 'execute')
    then '✅ ③ consume_snack_tx：anon 叫得動（餵食走這條）'
    else '🔴 ③ 前端叫不動 —— 餵食會失敗' end;

  /* ④ 而它一定要從 JWT 取身分（不然就是「給我 id 就扣光你的點心」）*/
  v_def := pg_get_functiondef('public.consume_snack_tx(uuid,uuid,text,int,uuid,text)'::regprocedure);
  v_msg := v_msg || E'\n' || case when v_def ilike '%current_member_id()%'
    then '✅ ④ 消耗的身分從 JWT 取，不採信呼叫端'
    else '🔴 ④ 沒有從 JWT 取身分 —— 這一支給前端叫，那是個洞' end;

  /* ⑤ 門關上了：存檔那支會剝掉 snacks */
  v_def := pg_get_functiondef('public.save_app_state_tx(uuid,uuid,jsonb,jsonb)'::regprocedure);
  v_msg := v_msg || E'\n' || case
    when v_def ilike '%- ''snacks''%' and v_def ilike '%member_app_state.bear -> ''snacks''%'
    then '✅ ⑤ save_app_state_tx 剝掉傳進來的 snacks，保留資料庫既有值'
    else '🔴 ⑤ 前端仍然能覆蓋 snacks —— 帳本形同虛設' end;

  /* ⑥ 負對照：**等級與名字沒有被一起擋掉**（那是前端該說了算的）*/
  v_msg := v_msg || E'\n' || case
    when v_def ilike '%coalesce(excluded.bear%'
    then '✅ ⑥ 小熊的等級／成長值／造型／名字照舊由前端存（沒有一起擋掉）'
    else '🔴 ⑥ 連小熊狀態都存不了了 —— 那是無辜的' end;

  /* ⑦ 現況：目前帳面與帳本的落差（**這一格會很難看，那是事實**）*/
  select count(*) into v_n from member_app_state
   where coalesce((bear -> 'snacks' ->> 'cookie')::int, 0) > 0;
  v_msg := v_msg || E'\n📌 ⑦ 帳上有餅乾的會員 ' || v_n || ' 人，而帳本 '
        || (select count(*)::text from snack_grants)
        || ' 筆 —— 落差是 2026-09-19 之前前端自己寫的，**刻意不回填**'
        || E'\n     （回填等於承認那些是發過的；讓它自然歸零比較誠實）';

  perform set_config('migi.verify_snack_lock', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify_snack_lock', true), ''), '🔴 沒有驗證訊息') as "驗證";
