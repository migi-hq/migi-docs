/* ═══════════════════════════════════════════════════════════════════
   修：`save_app_state_tx` 在「稱號兩邊都空」時會炸
   2026-09-19 · 寫點心關門的行為測試時撞到的既有 bug
   ═══════════════════════════════════════════════════════════════════

   🔴 **症狀是零，而且已經活了很久。**
   ```
   titles = (select jsonb_agg(distinct t)
               from jsonb_array_elements_text(member_app_state.titles || excluded.titles) t)
   ```
   `jsonb_agg` 對**空集合**回傳的是 `NULL`（不是 `[]`），而 `titles` 是 NOT NULL
   ⇒ **只要兩邊的稱號都是空的，那一次 UPDATE 就會拋
     `null value in column "titles" violates not-null constraint`**。

   🔴 線上實查：`member_app_state` 5 列，**5 列的稱號都是 0 個** ——
     也就是每一個會員的每一次存檔都在失敗。
   ⚠ 而前端只 `console.warn('[profile] 進度儲存失敗')`
     ⇒ 小熊的等級、成長值、名字**從第一次 INSERT 之後就再也沒存進去過**，
     而畫面上完全正常（本機 state 有值，重整才會退回去）。
   📌 這正是這個專案一再記錄的形狀：**「寫了、回了、什麼都沒發生」**
     （硬規則 4 那一族）。這次是靠**行為測試**撞出來的，
     不是靠讀程式碼 —— 那份測試本來是要驗別的東西。

   ✅ 修法一行：`coalesce(..., '[]'::jsonb)`。
   ⚠ 簽名不變 ⇒ CREATE OR REPLACE，前端不用改。
   ⚠ 這份要留下 DDL ⇒ 驗證段不 raise（硬規則 1.8）。
     行為驗證請重跑 `sql/checks/2026-09-19_驗點心關門.sql`
     —— 那一份本來就在呼叫這支函式，修好之後它才跑得完。
   ═══════════════════════════════════════════════════════════════════ */

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
     點心是獎勵（系統對事實的認定），來源只有
     `grant_snack_tx`／`consume_snack_tx`；小熊的等級、成長值、造型、名字
     仍然前端說了算（那是他自己的選擇）。 */
  insert into member_app_state(member_id, org_id, bear, titles, updated_at)
  values (p_member_id, p_org_id, coalesce(p_bear, '{}'::jsonb) - 'snacks', coalesce(p_titles, '[]'::jsonb), now())
  on conflict (member_id) do update set
    bear = (coalesce(excluded.bear, '{}'::jsonb) - 'snacks')
           || jsonb_build_object('snacks', coalesce(member_app_state.bear -> 'snacks', '{}'::jsonb)),
    /* 稱號聯集：只增不減（防舊裝置覆蓋掉新解鎖）。
       🔴 **`coalesce` 是必要的，不是保險**（2026-09-19 修）：
         `jsonb_agg` 對空集合回傳 `NULL` 而不是 `[]`，
         而 `titles` 是 NOT NULL ⇒ 兩邊都空時這一句會讓整次存檔失敗。
       ⚠ 線上 5 個會員的稱號**全部是空的**，所以那不是邊角案例，
         是「每一次存檔都炸」。而前端只 console.warn ⇒ 零症狀。 */
    titles = coalesce(
               (select jsonb_agg(distinct t)
                  from jsonb_array_elements_text(member_app_state.titles || excluded.titles) t),
               '[]'::jsonb),
    updated_at = now();
end $function$;


/* ═══ 驗證段（不 raise）═══════════════════════════════════════ */
do $$
declare
  v_msg text := '';
  v_def text;
  v_n   int;
begin
  v_def := pg_get_functiondef('public.save_app_state_tx(uuid,uuid,jsonb,jsonb)'::regprocedure);

  v_msg := case when v_def ilike '%coalesce(%jsonb_agg(distinct t)%'
    then '✅ ① 稱號聯集包了 coalesce（空集合不再變成 NULL）'
    else '🔴 ① 還是沒包 —— 兩邊都空時存檔仍然會炸' end;

  v_msg := v_msg || E'\n' || case when v_def ilike '%- ''snacks''%'
    then '✅ ② 點心仍然被剝掉（上一份的關門沒有被這次覆蓋掉）'
    else '🔴 ② 門被打開了 —— 前端又能覆蓋 snacks 了' end;

  /* ③ 現況：受影響的會員數。**這一格是這個 bug 的規模。** */
  select count(*) into v_n from member_app_state
   where jsonb_array_length(coalesce(titles, '[]'::jsonb)) = 0;
  v_msg := v_msg || E'\n📌 ③ 稱號是空的會員 ' || v_n || ' 人 —— '
        || '修之前他們的每一次存檔都在失敗（前端只 console.warn，零症狀）';

  /* ④ 負對照：`titles` 仍然是 NOT NULL（修的是函式不是把約束拿掉）。
     🔴 拿掉 NOT NULL 也會讓症狀消失，但那是把問題藏起來。 */
  v_msg := v_msg || E'\n' || case when exists (
      select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'member_app_state'
         and column_name = 'titles' and is_nullable = 'NO')
    then '✅ ④ titles 仍然 NOT NULL（修的是函式，不是把約束拿掉）'
    else '🔴 ④ 有人把 NOT NULL 拿掉了 —— 那是把問題藏起來' end;

  perform set_config('migi.verify_titles_fix', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify_titles_fix', true), ''), '🔴 沒有驗證訊息') as "驗證";
