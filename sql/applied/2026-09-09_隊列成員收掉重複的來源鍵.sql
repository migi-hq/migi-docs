/* ============================================================
   contract：`pos_queue_members_tx` 收掉重複的來源鍵
   2026-09-09 · 只改一支函式的回傳 · 簽名不變

   ── 這是在收拾今天稍早自己造的東西 ──────────────────
   `2026-09-09_隊列成員回傳現場登記標記.sql` 的檔頭寫著
   「寫入端從一開始就在記，只是**沒有人讀**」。
   🔴 **那句話是錯的，而它讓整份 SQL 建立在一個假前提上。**

   實際查證（2026-09-09，`pg_get_functiondef` 逐支撈）：
   ```
   pos_list_queues_tx     'walk_in', p.join_source = 'pos_walkin'    ← 早就有
   pos_queue_members_tx   'join_source', p.join_source               ← 今天加的
   ```
   而 POS **早就在畫那顆徽章**：`QueuePage.jsx` 的 `SeatCards` 讀
   `m.walk_in`，深墨底白字「現場」／白底墨字「App」，
   連「徽章在粉底上不能用淺灰」都已經寫在註解裡。
   來源是 `bc176d9`「配桌列表：客人卡、空位加現場客人…」。

   ⇒ 那個事實**一直都被回傳、也一直都被顯示**。
     今天做的不是「補上缺口」，是**替同一個事實取了第二個名字**。

   ── 為什麼要收掉而不是留著 ──────────────────────────
   ① **沒有任何呼叫點在讀它。** `posQueueMembers` 只有一個使用者：
      `OpenCheckoutPage.jsx:119` 拿它預帶四個座位，
      而那頁的座位卡徽章講的是「配桌帶入」與付款狀態，不是現場／App
      （`QueuePage.jsx:529` 的註解自己寫著「兩邊的徽章本來就不同」）。
   ② 留著就是**一個事實兩個名字、兩種形狀**（布林 vs 原始字串）——
      而那正是 CLAUDE.md 記過七次的那一族病
      （`wallet_txns.type`／`staff.role`／`players`／`score_points`／
        `--gray-4`／`paid_count`／`--divider` 那一串）。
      🔴 差別只在於：前六次是繼承來的，**這一次是我今天親手加的**。
   ③ 真的哪天要在別的畫面標現場，正解是**沿用 `walk_in`** ——
      一個名字一個意思，而它已經有定義、有顯示規則、有樣式決定。

   ── 保留什麼（不要一起收掉）────────────────────────
   · `match_queue_players.join_source` 欄位本身 —— 它是**事實來源**，
     `pos_list_queues_tx` 正在讀它算 `walk_in`。
   · `pos_add_queue_member_tx` 的寫入 —— 現場登記照樣蓋章。
   ⇒ 收的只有「多出來的那個回傳鍵」。

   ⚠ `CREATE OR REPLACE`、簽名不變 ⇒ 不掉 GRANT（硬規則 2）。
     而這支剛在 `2026-09-09_pos函式全面收掉anon.sql` 收成
     authenticated-only，驗證段第 ④ 格會確認它沒被這次改動弄回去。

   ⚠ 硬規則 3.5：新版函式體裡**不可以出現那個鍵的字面字串**，
     否則第 ① 格會被自己的註解觸發而永遠是紅的（那已經發生過四次）。
     所以下面的註解用文字描述，不寫出那個詞。
   ============================================================ */

create or replace function public.pos_queue_members_tx(p_org_id uuid, p_queue uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'member_id', m.id,
    'nickname',  m.display_name,
    'rank',      m.rank,
    'title',     m.title,
    'joined_at', p.joined_at
    /* ⚠ 「這個人是櫃檯登記的還是自己在 App 報名的」**不在這裡回**。
       那個問題由 pos_list_queues_tx 的布林欄位回答，POS 的配桌座位卡
       讀的就是它。同一個事實只有一個名字 —— 這支曾經多回過一份，
       2026-09-09 當天收掉。要標現場請用那一個，不要在這裡再加。 */
  ) order by p.joined_at), '[]'::jsonb)
  from match_queue_players p
  join members m on m.id = p.member_id
  join match_queues q on q.id = p.queue_id
  where p.queue_id = p_queue
    and p.left_at is null
    and q.org_id = p_org_id
$function$;

/* ============================================================
   驗證（單一 SELECT）

   🔴 **收尾一定要 `set_config` ＋ 最後一支 SELECT，不可以用
     `raise exception` 把訊息印出來。**（2026-09-09 第一次跑就踩到）
   Supabase SQL Editor 是**單一交易**，而 `raise` 會回滾整個交易
   ⇒ 上面那個 `create or replace` **一起被撤銷**。
   ⚠ 症狀是最惡劣的一種：**六格全綠，而函式一行都沒改。**
     那些格子是在交易裡跑的，當下 replace 確實生效了，
     然後 raise 把它連同訊息一起丟掉 —— 綠燈是真的，結果是假的。
   📌 這與 2026-09-04 那次剛好相反：那次是 exception handler
     **接住了沒往上拋 ⇒ DDL 照樣提交**（一支沒驗完的函式留在線上）。
     ⇒ **兩個方向都會說謊**，而判準只有一個：
     **驗證段驗的是交易內的狀態，不是提交後的狀態。**
   ✅ 所以「這份跑完了沒」一律**跑完之後另外查一次線上**，
     不要拿驗證段的綠燈當提交的證據。
   ⚠ `raise` 只保留給「這一份**故意不要提交**」的測試
     （造樣本驗行為那一類，硬規則 1 的交易內測試 ＋ 回滾）。
     這一份是 migration，**必須提交**。
   ============================================================ */
do $$
declare
  v_org   uuid;
  v_queue uuid;
  v_j     jsonb;
  v_msg   text := '';
begin
  select id into v_org from orgs order by created_at limit 1;

  /* ── ① contract 做到了嗎 ─────────────────────────────── */
  v_msg := v_msg || (
    select case when count(*) = 0 then '① ✅ 這支不再回傳那個重複的鍵'
                else '① 🔴 還在（' || count(*) || ' 支）' end
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and p.proname = 'pos_queue_members_tx'
      and pg_get_functiondef(p.oid) ~ 'join_source');

  /* ── ② 🎯 正對照：本來就有的那一個沒被誤傷 ───────────────
     🔴 只驗「① 沒了」的話，把整個回傳寫壞也會全綠（硬規則 3.55）。 */
  v_msg := v_msg || E'\n' || coalesce((
    select case when pg_get_functiondef(p.oid) ~ '''walk_in'', p\.join_source = ''pos_walkin'''
                then '② ✅ pos_list_queues_tx 的布林欄位原封不動（POS 的徽章沒壞）'
                else '② 🔴 pos_list_queues_tx 被動到了' end
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname = 'pos_list_queues_tx'
  ), '② ⚪ 找不到 pos_list_queues_tx');

  /* ── ③ 🎯 正對照：函式真的還叫得動，而且回得出人 ───────────
     ⚠ 硬規則 3.57：借線上的房當樣本，所以挑「現在有人的」而不是最新的。 */
  select p.queue_id into v_queue
    from match_queue_players p
    join match_queues q on q.id = p.queue_id
   where p.left_at is null and q.org_id = v_org
   group by p.queue_id
  having count(*) > 0
   order by max(p.joined_at) desc
   limit 1;

  if v_queue is null then
    v_msg := v_msg || E'\n③ ⚪ 現在沒有任何有人的配桌房，這一格測不了';
  else
    v_j := public.pos_queue_members_tx(v_org, v_queue);
    v_msg := v_msg || E'\n' ||
      case when jsonb_array_length(v_j) > 0
                 and (v_j -> 0) ? 'nickname'
                 and (v_j -> 0) ? 'member_id'
           then '③ ✅ 回得出 ' || jsonb_array_length(v_j) || ' 人，鍵完整（'
                || (select string_agg(k, '·' order by k) from jsonb_object_keys(v_j -> 0) k) || '）'
           else '③ 🔴 回傳不對：' || left(v_j::text, 120) end;
  end if;

  /* ── ④ 授權沒有被這次改動弄回去 ────────────────────────
     ⚠ 硬規則 2.6b：兩個方向都要看，而且用 aclexplode 不用
       has_function_privilege（後者分不出明確授權與 PUBLIC 繼承）。 */
  v_msg := v_msg || E'\n' || coalesce((
    select '④ ' ||
      case when not has_anon and not has_public and has_auth
           then '✅ anon 無 · PUBLIC 無 · authenticated 有（09-09 那批的收斂還在）'
           else '🔴 anon=' || has_anon || ' PUBLIC=' || has_public || ' auth=' || has_auth end
    from (
      select
        exists (select 1 from aclexplode(p.proacl) a
                 where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE') as has_anon,
        (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                 where a.grantee = 0 and a.privilege_type = 'EXECUTE')) as has_public,
        exists (select 1 from aclexplode(p.proacl) a
                 where a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE') as has_auth
      from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.proname = 'pos_queue_members_tx'
    ) z
  ), '④ ⚪ 撈不到授權');

  /* ── ⑤ 負對照：寫入端還在蓋章，欄位沒被一起收掉 ───────────
     🔴 收掉回傳鍵 ≠ 停止記錄。停止記錄的話 walk_in 會**永遠是 false**，
       而畫面完全看不出來 —— 那是「現場客人從此消失」。 */
  v_msg := v_msg || E'\n' || coalesce((
    select case when pg_get_functiondef(p.oid) ~ 'pos_walkin'
                then '⑤ ✅ pos_add_queue_member_tx 仍然標記現場登記'
                else '⑤ 🔴 寫入端不再標記了' end
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname = 'pos_add_queue_member_tx'
  ), '⑤ ⚪ 找不到 pos_add_queue_member_tx');

  /* ── ⑥ 負對照：欄位與資料都還在 ──────────────────────── */
  v_msg := v_msg || E'\n' || coalesce((
    select '⑥ ✅ 欄位與資料都在 —— ' || string_agg(src || '：' || c, '　' order by c desc)
    from (select coalesce(p.join_source, '(null 舊資料)') as src, count(*) as c
            from match_queue_players p group by 1) z
  ), '⑥ 🔴 一筆都沒有');

  /* 🔴 不 raise。訊息交給最後那支 SELECT，交易才會提交。
     ⚠ `is_local = true` 的設定活到交易結束，而我們不回滾 ⇒ 讀得到。
       （硬規則 3.9 警告的是「set_config 之後才 raise」，那會被回滾；
        這裡根本不 raise。） */
  perform set_config('migi.qm', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.qm', true), ''), '🔴 沒有訊息') as "驗證";
