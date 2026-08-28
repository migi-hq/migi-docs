/* ============================================================
   兩個「等著發生」的靜默故障（待辦 34）
   2026-08-28

   ── ① 「一將」預設值：湊滿也永遠不會帶桌 ────────────
   `pos_seat_queue_tx` 解析 `rounds` 時只吃「三/3」或「二/2」，
   其餘一律回 `rounds_not_supported` **而且只是不帶桌，不報錯**。
   而 `'一將'` 是**五個地方的預設值**（2026-08-28 查證）：

       create_match_queue_tx.p_rounds      '一將'
       pos_create_queue_tx.p_rounds        '一將'
       pos_create_recurring_tx.p_rounds    '一將'
       match_queues.rounds 欄位             '一將'
       recurring_tables.rounds 欄位         '一將'

   任何呼叫端只要漏傳 `p_rounds`，就會建出一個
   **湊滿 → status='matched' → 排程每 5 分鐘試一次 → 每次都失敗 → 沒有人知道** 的房。
   🔴 客人以為成桌了，而那張桌永遠不會出現。

   ✅ **目前不是活的問題**：最後一個「一將」房建於 2026-08-22 15:58，
     前端選項 2026-08-23 就拿掉了，33 房全部 expired/cancelled。
     這支修的是**潛在陷阱**，不是現行故障。
   ⚠ 欄位預設值其實輪不到（三支函式都會明確傳 `p_rounds` 進 INSERT），
     但一起改 —— 防禦深度，而且成本是零。

   ── ② `topup_void_tx` 沒有授權給 anon ────────────────
   `anon=無`、`auth=✅`。POS 用 anon key，所以**作廢儲值一叫就 permission denied**。
   ⚠ 現在沒踩到只是因為 POS 還沒有那個按鈕。
   🔴 硬規則 2.5：`topup_tx` 就是這樣 —— 一直只被 DEFINER 包裝從內部呼叫，
     前端第一次直接叫它就 permission denied，
     也就是**櫃檯儲值從上線那天起沒成功過一次**。這支是同一個形狀，提前補掉。

   ── 為什麼用「撈定義 → 取代 → 重新執行」──────────────
   三支函式的本體很長（`pos_create_queue_tx` 有整套標籤驗證），
   而這次要改的**只有簽名那一行的預設值**。
   🔴 **手抄 80 行金流相鄰的邏輯，風險比改動本身大。**
   → 用 `pg_get_functiondef` 撈線上版、字串取代、`execute` 回去：**零抄寫**。
   ⚠ 每一支都加 guard：取代沒發生就 `raise`，整支交易回滾
     （Supabase SQL Editor 是單一交易）。CLAUDE.md 記過這個 guard 救過兩次
     ——「沒有它，線上會出現只改對一半的函式而且不報錯」。
   ============================================================ */

do $$
declare
  r record;
  v_def text;
  v_new text;
  v_done text := '';
begin
  for r in
    select p.oid, p.proname
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.prokind = 'f'
       and p.proname in ('create_match_queue_tx','pos_create_queue_tx','pos_create_recurring_tx')
     order by p.proname
  loop
    v_def := pg_get_functiondef(r.oid);

    /* 只改簽名那一行的預設值。用完整的片段比對，
       避免誤傷函式體裡任何提到「一將」的字（例如註解）。 */
    v_new := replace(v_def,
               'p_rounds text DEFAULT ''一將''::text',
               'p_rounds text DEFAULT ''2 將''::text');

    if v_new = v_def then
      raise exception '🔴 % 的預設值沒有被取代 —— 簽名格式與預期不同，整支回滾', r.proname;
    end if;

    /* guard：確認新定義裡真的不再有「一將」當預設。
       ⚠ 不能只掃「有沒有『一將』這三個字」—— 函式體或註解裡可能合法地提到它。
         這裡掃的是**預設值那個完整片段**。 */
    if v_new like '%p_rounds text DEFAULT ''一將''::text%' then
      raise exception '🔴 % 取代後仍有「一將」預設 —— 可能有多個位置，整支回滾', r.proname;
    end if;

    execute v_new;
    v_done := v_done || r.proname || ' ';
  end loop;

  if v_done = '' then
    raise exception '🔴 一支函式都沒改到 —— 名稱可能不對，整支回滾';
  end if;
  raise notice '已改：%', v_done;
end $$;

/* 欄位預設值（防禦深度）。
   ⚠ 這兩個目前輪不到 —— 三支函式都會明確傳值進 INSERT。
     改它是為了「有人日後寫了直接 INSERT 的路徑」時不會踩到。 */
alter table public.match_queues     alter column rounds set default '2 將';
alter table public.recurring_tables alter column rounds set default '2 將';

/* ② 補 topup_void_tx 的執行權。
   ⚠ 簽名要寫完整，否則有多載時會授權錯支（硬規則 2）。 */
grant execute on function public.topup_void_tx(uuid, text, uuid, text) to anon;

/* ============================================================
   驗證（單一 SELECT）

   ── 該看到什麼 ──────────────────────────────────────
   ① 三支都是「2 將」
   ② 兩張表的欄位預設都是 '2 將'
   ③ ✅ 有
   ④ 三支各 1 個版本（沒建出多載）
   ⑤ 現有資料**完全沒動**：一將 33／2 將 23／3 將 3
      🔴 這一項是重點 —— 改預設值**不可以**動到既有列。
   ============================================================ */
select 序, 項目, 內容 from (

  select 1 as 序, '① 三支函式的 p_rounds 預設值' as 項目,
         coalesce(string_agg(
           p.proname || ' → ' ||
           coalesce(substring(pg_get_functiondef(p.oid) from 'p_rounds text DEFAULT ''([^'']*)'''),
                    '(無預設)') ||
           case when substring(pg_get_functiondef(p.oid) from 'p_rounds text DEFAULT ''([^'']*)''') = '2 將'
                then '　✅' else '　🔴' end,
           E'\n' order by p.proname), '🔴 一支都找不到') as 內容
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname in ('create_match_queue_tx','pos_create_queue_tx','pos_create_recurring_tx')

  union all
  select 2, '② 欄位預設值',
         (select string_agg(table_name || '.rounds → ' || coalesce(column_default,'(無)') ||
                            case when column_default like '%2 將%' then '　✅' else '　🔴' end,
                            E'\n' order by table_name)
            from information_schema.columns
           where table_schema='public' and column_name='rounds'
             and table_name in ('match_queues','recurring_tables'))

  union all
  select 3, '③ topup_void_tx 的 anon 授權',
         (select case when has_function_privilege('anon', p.oid, 'EXECUTE')
                      then '✅ 有' else '🔴 仍然沒有' end
            from pg_proc p
           where p.pronamespace='public'::regnamespace and p.prokind='f'
             and p.proname='topup_void_tx' limit 1)

  union all
  select 4, '④ 版本數（各應為 1）',
         (select string_agg(proname || '=' || n::text, '　' order by proname)
            from (select p.proname, count(*) n from pg_proc p
                   where p.pronamespace='public'::regnamespace and p.prokind='f'
                     and p.proname in ('create_match_queue_tx','pos_create_queue_tx',
                                       'pos_create_recurring_tx','topup_void_tx')
                   group by p.proname) s)

  union all
  select 5, '⑤ 既有資料沒被動到（應為 一將 33／2 將 23／3 將 3）',
         (select string_agg(rounds || ' × ' || n::text, '　' order by n desc)
            from (select rounds, count(*) n from match_queues group by rounds) s)

) x order by 序;
