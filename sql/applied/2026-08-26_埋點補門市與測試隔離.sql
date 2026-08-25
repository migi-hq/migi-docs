/* ============================================================
   埋點：app_events 補 store_id，測試隔離改成也認門市
   2026-08-26

   ── 為什麼非補不可 ──────────────────────────────────
   CLAUDE.md 一直寫「`app_events.is_test` 由 `set_is_test_from_store()`
   **依門市**自動帶入」—— 2026-08-26 查證後發現**那是假的**：
     · `app_events` **沒有 store_id 欄位**
     · 它唯一的觸發器是 `trg_app_events_no_mutate`（防改），不是 is_test
     · `is_test` 是 `log_app_event_tx` **從會員**推的：
         if p_member_id is not null then select is_test from members

   🔴 **POS 的事件 member_id 一律是 null → is_test 恆為 false**
     → 測試門市的操作會混進營運數據，**而且不報錯**。
     那正是硬規則 3 要防的：文件說有、實際上沒有。

   ⚠ `set_is_test_from_store()` 確實存在而且有在用 —— 掛在 `orders` 那類
     **本來就有 store_id** 的表上。app_events 沒有那一欄，所以掛不上去。

   ── 兩件事 ──────────────────────────────────────────
   一、app_events 加 store_id
   二、log_app_event_tx 加 p_store_id，is_test 改成「會員或門市任一是測試」

   ⚠ 加參數要 DROP 重建（Postgres 不允許 CREATE OR REPLACE 改參數個數）。
     ✅ **但對 migi-web 是安全的**：新參數有 DEFAULT，而前端送的是
       **具名參數**（p_org_id / p_member_id / p_event / p_props / p_client_ts），
       PostgREST 仍然對得上。不需要先部署前端。
   🔴 DROP 會把 GRANT 帶走（硬規則 2）—— 檔案結尾一定要補回來。

   ── 📌 順帶查到的兩條約束，寫程式時要遵守 ────────────
   ① `app_events_event_check  CHECK (event ~ '^[a-z][a-z0-9_]{0,49}$')`
      事件名要**小寫字母開頭**、只有小寫英數與底線、50 字以內。
      🔴 它**不是白名單**（我一度誤判成白名單）—— 名字是自由的，只管格式。
      → POS 的事件一律加 `pos_` 前綴：`event like 'pos_%'` 就能分開兩端，
        而不必記得在 props 裡多加條件。**讓區分是結構性的，不是靠人記得。**

   ② `app_events_props_check  CHECK (pg_column_size(props) <= 8192)`
      🔴 **props 上限 8KB** —— 而錯誤上報最想帶的 stack trace 很容易破。
      超過會 CHECK 違反 → 插入失敗 → **而前端會把它吞掉**（埋點是靜默的）。
      → 前端必須**截斷 stack**（建議 2000 字），寧可少幾行也不要整筆消失。
   ============================================================ */


/* ──────────────────────────────────────────────────────────
   一、app_events 加 store_id
   ⚠ 可為 null：會員端的事件本來就沒有門市（客人在家開 App）。
     只有 POS 一定會帶。
   ────────────────────────────────────────────────────────── */

alter table app_events
  add column if not exists store_id uuid references stores(id) on delete restrict;

/* 分析一定會用「某門市某段時間的事件」。3308 筆現在不需要索引，
   但這個欄位加了之後查詢形狀就固定了，順手建起來比日後補便宜。
   ⚠ 只建這一個，不要為了「可能會用到」建一堆 —— 索引會拖慢寫入，
     而埋點是高頻寫入低頻查詢。 */
create index if not exists idx_app_events_store_created
  on app_events (store_id, created_at desc)
  where store_id is not null;


/* ──────────────────────────────────────────────────────────
   二、log_app_event_tx 加 p_store_id
   ────────────────────────────────────────────────────────── */

drop function if exists public.log_app_event_tx(uuid, uuid, text, jsonb, timestamptz);

create or replace function public.log_app_event_tx(
  p_org_id     uuid,
  p_member_id  uuid,
  p_event      text,
  p_props      jsonb       default '{}'::jsonb,
  p_client_ts  timestamptz default null,
  p_store_id   uuid        default null
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_is_test boolean := false;
begin
  /* 測試隔離：**會員或門市任一是測試，就算測試**。
     ⚠ 用 or 不是 else if —— 兩個來源是獨立的訊號：
       · 會員端：測試帳號在正式門市操作 → 是測試
       · POS：正式店員在測試門市操作     → 也是測試
     只認其中一個的話，另一邊會靜靜污染營運數據。 */
  if p_member_id is not null then
    select coalesce(is_test, false) into v_is_test
      from members where id = p_member_id;
  end if;

  if not coalesce(v_is_test, false) and p_store_id is not null then
    select coalesce(s.is_test, false) into v_is_test
      from stores s where s.id = p_store_id;
  end if;

  insert into app_events(org_id, member_id, store_id, event, props, client_ts, is_test)
  values (p_org_id, p_member_id, p_store_id, p_event,
          coalesce(p_props, '{}'::jsonb), p_client_ts,
          coalesce(v_is_test, false));
end $function$;

/* 🔴 硬規則 2：DROP 帶走 GRANT，一定要補回來。
   ⚠ 忘了補的症狀是「埋點全部靜默失效」—— 而埋點本來就是靜默的，
     沒有人會發現，直到半年後要分析時才知道那段是空的。 */
grant execute on function public.log_app_event_tx(
  uuid, uuid, text, jsonb, timestamptz, uuid) to anon, authenticated;


/* ============================================================
   驗證段（單一 SELECT）

   ⚠ 硬規則 7：要真的呼叫一次。
     但 app_events 有 trg_app_events_no_mutate（防改）——
     **寫進去的測試列刪不掉**。所以：
       · 只在「找得到一間 is_test = true 的門市」時才真的寫
       · 寫進去的那筆 is_test 會是 true，不會污染營運分析
       · 找不到測試門市就跳過寫入，只驗結構（並明說跳過了）
   ============================================================ */

do $$
declare
  v_store uuid;
  v_org   uuid;
  v_ok    boolean;
begin
  select s.id, s.org_id into v_store, v_org
    from stores s where coalesce(s.is_test, false) limit 1;

  if v_store is null then
    perform set_config('migi.smoke',
      '⚠ 跳過寫入測試：找不到 is_test = true 的門市（結構已驗，但沒實際跑過）', true);
    return;
  end if;

  begin
    /* ⚠ 事件名必須符合 app_events_event_check：
         CHECK (event ~ '^[a-z][a-z0-9_]{0,49}$')
       —— **小寫字母開頭**、只有小寫英數與底線、50 字以內。
       2026-08-26 第一版用了 `_smoke_pos_log`（底線開頭）被擋，
       我當時誤判成「事件名是白名單」，整段推論都建立在錯的前提上。
       🔴 它不是白名單，是格式檢查 —— 事件名是自由的。 */
    perform log_app_event_tx(
      p_org_id    => v_org,
      p_member_id => null,               -- ★ 模擬 POS：沒有登入的會員
      p_event     => 'pos_smoke_test',
      p_props     => jsonb_build_object('_surface', 'pos', '_smoke', true),
      p_client_ts => now(),
      p_store_id  => v_store);

    /* ⚠ 型別要對：is_test 是 boolean。
       第一版寫成 `select is_test into v_id` 而 v_id 宣告成 uuid ——
       就算事件名對了也會拋型別錯誤。 */
    select is_test into v_ok
      from app_events
     where event = 'pos_smoke_test' and store_id = v_store
     order by created_at desc limit 1;

    perform set_config('migi.smoke',
      case when coalesce(v_ok, false)
           then '✅ 寫入成功，且 member_id 為 null 時仍靠門市判定為 is_test = true'
           else '🔴 寫進去了但 is_test 不是 true —— 門市判定沒生效' end, true);
  exception when others then
    perform set_config('migi.smoke', '🔴 寫入失敗：' || sqlerrm, true);
  end;
end $$;

select 序, 項目, 結果 from (

  select 0 as 序, '① app_events.store_id' as 項目,
         coalesce((select column_name || ' ' || data_type ||
                          (case when is_nullable = 'YES' then '　可為 null ✅' else '　🔴 NOT NULL' end)
                     from information_schema.columns
                    where table_schema = 'public' and table_name = 'app_events'
                      and column_name = 'store_id'), '🔴 欄位沒建起來') as 結果

  union all
  select 0, '② log_app_event_tx 簽名',
         coalesce((select pg_get_function_arguments(p.oid)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname = 'log_app_event_tx'
                    limit 1), '🔴 不存在')

  union all
  select 0, '③ 版本數（DROP 有沒有清乾淨）',
         (case when count(*) = 1 then '✅ 1 個'
               else '🔴 ' || count(*)::text || ' 個 —— 有多載，PostgREST 會不知道叫哪支' end)
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname = 'log_app_event_tx'

  union all
  /* 🔴 最重要的一項。忘了補 GRANT 的症狀是「埋點全部靜默失效」，
        而埋點本來就靜默 —— 半年後要分析才發現是空的。 */
  select 0, '④ EXECUTE 授權',
         coalesce((select 'anon ' ||
                     (case when has_function_privilege('anon', p.oid, 'EXECUTE') then '✅' else '🔴 沒有' end) ||
                     '／authenticated ' ||
                     (case when has_function_privilege('authenticated', p.oid, 'EXECUTE') then '✅' else '🔴 沒有' end)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname = 'log_app_event_tx'
                    limit 1), '🔴 函式不存在')

  union all
  select 1, '⑤ 煙霧測試',
         coalesce(current_setting('migi.smoke', true), '🔴 DO 區塊沒執行')

  union all
  /* ⑥ 既有 3308 筆不受影響 —— store_id 是新欄位，舊資料是 null。
        這一項是確認「加欄位沒有動到既有資料」。 */
  select 2, '⑥ 既有事件沒被動到',
         (select '總計 ' || count(*)::text || ' 筆　'
              || 'store_id 有值 ' || count(*) filter (where store_id is not null)::text || ' 筆　'
              || 'is_test ' || count(*) filter (where is_test)::text || ' 筆'
            from app_events)

) x order by 序, 項目;
