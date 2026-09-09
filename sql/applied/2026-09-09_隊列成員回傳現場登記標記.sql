/* ============================================================
   隊列成員補回傳 `join_source`（現場登記 vs App 自己報名）
   2026-09-09 · 待辦 5 的最後一塊
   ============================================================

   ── 先更正 CLAUDE.md 待辦 5 的一句話 ────────────────────
   它寫著：
   > 🔴 **還沒解決：現場客人與 App 不在同一條隊。**
   >   → POS 要能幫現場客人登記進同一個隊列（walk-in）

   ✅ **那件事早就做完了**（`QueuePage.jsx` 的檔頭註解自己寫著
     「解掉待辦 5 那條」）：`pos_add_queue_member_tx` 存在、前端有
     「空位按 ＋ 加現場客人」、滿員還會自動帶桌。
   → 又一次「文件說沒有、實際上有」（踩坑第 29 條）。**先查再說沒有。**

   ── 而真正還缺的是「讀不到」不是「沒有做」──────────────
   `pos_add_queue_member_tx` 寫入時就標了 `join_source = 'pos_walkin'`，
   而且它的註解自己寫著：
   > 「這是之後分析『現場登記 vs App 自己報名』的唯一依據」

   🔴 **但 `pos_queue_members_tx` 沒有回傳它** ⇒ 那個標記**每天都在被寫，
     而畫面上一輩子讀不到**。
   📌 線上實測三種值都真的存在：`browse`（App 瀏覽加入）／
     `open`（開房的人）／`pos_walkin`（店員現場登記）。

   🎯 **這就是這個專案一再記錄的「建了沒人讀」**（待辦 0 的
     `member_tiers.label`、待辦 17 的 `topup_plans`、待辦 24 的
     `visit_count`… 都是同一個形狀）。

   ── 為什麼它值得做（不是為了整齊）────────────────────────
   店員把現場客人加進去之後，**三十秒後就分不出哪一位是他加的**。
   而配桌最常見的爭執正是「我們先到的」——
   🔴 **今天店員手上有順序（`joined_at`）卻沒有來源**，
     所以他能說「這位先報名」，卻說不出「他是在 App 上報名的」。
   ⇒ 補上之後，那句話才講得完整。

   ── 這一份只做一件事 ────────────────────────────────────
   `pos_queue_members_tx` 的回傳多一個 `join_source`。
   ✅ **簽名不變** ⇒ `CREATE OR REPLACE`、不 DROP、不掉 GRANT。
   ✅ 前端多一個鍵不會壞（同 `id_src` 那次）。
   ⚠ **刻意不動 `pos_list_queues_tx`** —— 它不回成員名單（查證過），
     而配桌列表那一層要的是「幾人」不是「哪些人」（同待辦 35 的結論：
     一個名字一個意思）。
   ============================================================ */

create or replace function public.pos_queue_members_tx(p_org_id uuid, p_queue uuid)
returns jsonb
language sql stable security definer set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'member_id', m.id,
    'nickname',  m.display_name,
    'rank',      m.rank,
    'title',     m.title,
    'joined_at', p.joined_at,
    /* 🔴 2026-09-09 補上。寫入端從一開始就在記，只是沒有人讀。
       值域（線上實測三種都有）：
         pos_walkin  店員在 POS 幫現場客人登記
         browse      客人自己在 App 的列表上報名
         open        這個房是他開的
       ⚠ 舊資料可能是 null（欄位可為空）—— 前端要把 null 當成
         「不知道」而不是「App 報名的」，那是兩件事。 */
    'join_source', p.join_source
  ) order by p.joined_at), '[]'::jsonb)
  from match_queue_players p
  join members m on m.id = p.member_id
  join match_queues q on q.id = p.queue_id
  where p.queue_id = p_queue
    and p.left_at is null
    and q.org_id = p_org_id
$function$;


/* ============================================================
   驗證段
   🎯 重點不是「有沒有多一個鍵」，是**舊的鍵一個都不能少** ——
     這一支的回傳前端正在用，掉一個鍵畫面就空一格而且不報錯。
   ============================================================ */
select
  /* ① 簽名與模式沒變（沒有 DROP 過，所以授權也不該變） */
  (select rpad(p.proname, 22)
       || case when p.prosecdef then 'DEFINER' else '🔴 INVOKER' end
       || '　參數：' || pg_get_function_identity_arguments(p.oid)
       || E'\n　anon：' || case when exists (select 1 from aclexplode(p.proacl) a
              where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE') then '有' else '沒' end
       || '　authenticated：' || case when exists (select 1 from aclexplode(p.proacl) a
              where a.grantee='authenticated'::regrole::oid and a.privilege_type='EXECUTE') then '✅ 有（POS 要用）' else '🔴 沒有' end
   from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind='f'
    and p.proname='pos_queue_members_tx') as "① 簽名與授權",

  /* ② 🎯 拿一個**真的有成員的隊列**跑一次，把回傳的鍵全部印出來。
       ⚠ 找不到樣本要出聲，不要安靜跳過（硬規則 3.57）。 */
  coalesce((
    select case when jsonb_array_length(r.j) = 0 then '⚪ 取樣到的隊列沒有成員，測不出東西'
           else '取樣隊列 ' || left(r.qid::text, 8) || '　' || jsonb_array_length(r.j) || ' 位' || E'\n'
             || '　回傳的鍵：' || (select string_agg(k, '、' order by k)
                                   from jsonb_object_keys(r.j->0) k) || E'\n'
             || '　' || case when (r.j->0) ? 'join_source'
                             and (r.j->0) ? 'member_id' and (r.j->0) ? 'nickname'
                             and (r.j->0) ? 'rank' and (r.j->0) ? 'title' and (r.j->0) ? 'joined_at'
                        then '✅ 新的有了，而且舊的五個一個都沒少'
                        else '🔴 鍵不齊 —— 前端會空一格而且不報錯' end
           end
    from (
      select q.id as qid, public.pos_queue_members_tx(q.org_id, q.id) as j
        from match_queues q
       where exists (select 1 from match_queue_players p
                      where p.queue_id = q.id and p.left_at is null)
       order by q.created_at desc limit 1
    ) r
  ), '🔴 找不到任何有成員的隊列 —— 這一格測不了') as "② 回傳的鍵齊不齊",

  /* ③ 🎯 正對照：`pos_walkin` 那個值真的出得來嗎。
       只驗「鍵存在」不夠 —— 一支永遠回 null 的實作也會讓第 ② 格全綠。 */
  coalesce((
    select string_agg(x.src || '：' || x.n || ' 位', '　' order by x.n desc)
      from (
        select coalesce(p.join_source, '(null 舊資料)') as src, count(*) as n
          from match_queue_players p where p.left_at is null
         group by 1
      ) x
  ), '⚪ 目前沒有在隊列裡的人') as "③ 正對照：三種來源的實際分布",

  /* ④ 🎯 負對照：`pos_add_queue_member_tx` 寫入端沒有被動到。
       這一份只改讀取，寫入端一個字都不該變。 */
  (select case when pg_get_functiondef(oid) ~ '''pos_walkin'''
               then '✅ 寫入端仍然標 pos_walkin（沒有被動到）'
               else '🔴 寫入端的標記不見了' end
   from pg_proc where pronamespace='public'::regnamespace and prokind='f'
    and proname='pos_add_queue_member_tx') as "④ 負對照：寫入端沒被動到",

  /* ⑤ 參考：全庫數量不該變（不新增不刪除函式）。 */
  (select '函式總數 ' || count(*) || '（期望 183，不變）'
   from pg_proc where pronamespace='public'::regnamespace and prokind='f') as "⑤ 全庫數量";
