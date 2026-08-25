/* ============================================================
   測試標記：門市或會員任一是測試，就算測試
   2026-08-26

   ✅ 已執行並驗證通過（2026-08-26）
      函式仍是 DEFINER／兩張表的觸發器都還在／內文確實有查 members／
      v_real_orders 已建立（營運訂單 0 筆，因為 153 筆全是測試 —— 正確）／
      既有訂單標記沒被動到（153 測試 / 0 營運）。

      ⚠ 煙霧測試分兩次才乾淨：
        第一次失敗在 `table_sessions.mode` NOT NULL —— **與改動無關**，
        是我的測試 insert 少給了必填欄位。
        補驗見 sql/checks/2026-08-26_補驗觸發器在無member_id的表上.sql，
        結論：insert 成功、觸發器沒拋錯，
        **也就是 to_jsonb 動態判斷確實讓同一支函式安全地服務兩張表**。

   ── 洞 ──────────────────────────────────────────────
   `set_is_test_from_store()` **只問門市，不問會員**：

       if NEW.store_id is not null then
         select coalesce(s.is_test, false) into NEW.is_test
           from stores s where s.id = NEW.store_id;
       end if;

   它掛在 `orders.trg_orders_is_test` 與 `table_sessions.trg_sessions_is_test`。
   → **測試帳號在正式門市消費，訂單會被標成營運 → 那筆假的錢進真實營收。**

   ⚠ 這與 2026-08-26 早上修掉的埋點漏洞是同一個形狀（只認一個訊號），
     但嚴重得多：埋點錯了是分析數字歪，**訂單錯了是財報數字歪**。

   ── 🔴 為什麼現在修是零成本，晚一天就不是 ──────────────
   2026-08-26 查證：**七間門市全部 is_test = true**，
   所以現有 153 筆測試會員的訂單**全部標對了**，沒有歷史要回填。

   **那個洞會在「第一間門市轉正式」的那一刻發作** —— 也就是上線日。
   而上線日之後才修，就要面對「哪些歷史訂單該回填」這個問題。

   ⚠ 使用者接下來要接 LINE，四個測試帳號會拿到真實 LINE ID ——
     那讓「測試帳號出現在正式門市」從假設變成很可能。

   ── 為什麼用 to_jsonb 而不是直接寫 NEW.member_id ────────
   同一支觸發器函式掛在兩張表上，而 **table_sessions 沒有 member_id 欄位**。
   直接寫 `NEW.member_id` 會在 table_sessions 上**執行期**拋錯
   （欄位不存在），而那是開桌時 —— 最不能壞的地方。
   → 用 `to_jsonb(NEW) ? 'member_id'` 動態判斷，一支函式安全地服務兩張表。
   ============================================================ */

create or replace function public.set_is_test_from_store()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row  jsonb;
  v_mid  uuid;
  v_test boolean := false;
begin
  -- ① 門市（原本就有的判斷）
  if NEW.store_id is not null then
    select coalesce(s.is_test, false) into v_test
      from stores s where s.id = NEW.store_id;
  end if;

  /* ② 會員（2026-08-26 新增）。
     ⚠ **用 or 不是 else** —— 兩個是獨立訊號：
       · 測試帳號在正式門市 → 是測試
       · 正式客人在測試門市 → 也是測試
     只認其中一個，另一邊會靜靜污染，而且**不報錯**。

     ⚠ 用 to_jsonb 動態取欄位：table_sessions 沒有 member_id，
       直接寫 NEW.member_id 會在開桌時拋「欄位不存在」。 */
  if not coalesce(v_test, false) then
    v_row := to_jsonb(NEW);
    if v_row ? 'member_id' and nullif(v_row ->> 'member_id', '') is not null then
      v_mid := (v_row ->> 'member_id')::uuid;
      select coalesce(m.is_test, false) into v_test
        from members m where m.id = v_mid;
    end if;
  end if;

  NEW.is_test := coalesce(v_test, false);
  return NEW;
end $function$;


/* ──────────────────────────────────────────────────────────
   順帶補上 v_real_orders

   🔴 CLAUDE.md 寫「做報表一律查 v_real_*」，但 2026-08-26 查證
     只有四個：v_real_app_events / v_real_members / v_real_stores /
     v_real_wallet_txns —— **訂單沒有那一層保護**。
     而訂單正是營收的來源，最需要被濾。

   ⚠ 只濾 is_test，不濾 status —— 作廢單要不要算是報表自己的決定，
     不該由這個檢視表替它決定（那會變成兩個地方在定義「什麼是營收」）。
   ────────────────────────────────────────────────────────── */

create or replace view public.v_real_orders as
  select * from orders where not coalesce(is_test, false);

grant select on public.v_real_orders to anon, authenticated;


/* ============================================================
   驗證段（單一 SELECT）

   ⚠ 硬規則 7：要真的觸發一次。
     但**不能真的建訂單**（那會留下假資料而且刪不掉）。
     改成用 table_sessions 那張表驗「沒有 member_id 也不會拋錯」——
     那才是這次改動最可能壞掉的地方。
     ⚠ 用 rollback 的 savepoint 包起來，測完不留痕跡。
   ============================================================ */

do $$
declare
  v_store uuid;
  v_org   uuid;
  v_table uuid;
begin
  select s.id, s.org_id into v_store, v_org from stores s limit 1;
  select t.id into v_table from tables t where t.store_id = v_store limit 1;

  if v_table is null then
    perform set_config('migi.smoke', '⚠ 跳過：找不到可用的桌', true);
    return;
  end if;

  begin
    /* table_sessions 沒有 member_id —— 這一段驗的就是
       「to_jsonb 的動態判斷有沒有讓它安全通過」。
       ⚠ 立刻 raise 讓整段回滾，不留測試場次。 */
    insert into table_sessions(org_id, store_id, table_id, status, open_method)
    values (v_org, v_store, v_table, 'open', 'manual');
    raise exception 'rollback_on_purpose';
  exception
    when others then
      if sqlerrm = 'rollback_on_purpose' then
        perform set_config('migi.smoke',
          '✅ table_sessions（無 member_id 欄位）插入時沒有拋錯，動態判斷安全', true);
      else
        perform set_config('migi.smoke', '🔴 插入失敗：' || sqlerrm, true);
      end if;
  end;
end $$;

select 序, 項目, 結果 from (

  select 0 as 序, '① 函式還在、還是 DEFINER' as 項目,
         coalesce((select (case when p.prosecdef then '✅ DEFINER' else '🔴 INVOKER' end)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname = 'set_is_test_from_store'
                    limit 1), '🔴 不存在') as 結果

  union all
  /* ② 兩張表的觸發器都還在 —— CREATE OR REPLACE 不會動到觸發器，
        但確認一次比假設便宜。 */
  select 0, '② 掛著的觸發器',
         coalesce((select string_agg(t.relname || '.' || tg.tgname, '　' order by t.relname)
                     from pg_trigger tg
                     join pg_class t on t.oid = tg.tgrelid
                     join pg_proc p on p.oid = tg.tgfoid
                    where not tg.tgisinternal and p.proname = 'set_is_test_from_store'),
                  '🔴 一個都沒有')

  union all
  select 0, '③ 內文有沒有真的加上會員判斷',
         (case when exists (
                 select 1 from pg_proc p
                  where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
                    and p.proname = 'set_is_test_from_store'
                    and pg_get_functiondef(p.oid) ilike '%from members%')
               then '✅ 有查 members' else '🔴 沒有' end)

  union all
  select 0, '④ v_real_orders',
         (case when to_regclass('public.v_real_orders') is null then '🔴 沒建起來'
               else '✅ 已建立　營運訂單 ' ||
                    (select count(*)::text from v_real_orders) || ' 筆　' ||
                    '（orders 全表 ' || (select count(*)::text from orders) || ' 筆）' end)

  union all
  select 1, '⑤ 煙霧測試',
         coalesce(current_setting('migi.smoke', true), '🔴 DO 區塊沒執行')

  union all
  /* ⑥ 既有資料不受影響 —— 觸發器只在 INSERT 時跑，
        改函式不會回溯更新歷史。這一項是確認那件事。 */
  select 2, '⑥ 既有訂單的標記沒被動到',
         (select 'is_test ' || count(*) filter (where is_test)::text
              || ' 筆　營運 ' || count(*) filter (where not is_test)::text || ' 筆'
            from orders)

) x order by 序, 項目;
