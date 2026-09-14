/* ============================================================
   解散牌咖團收歸總部：團長不能再解散
   2026-09-14
   ------------------------------------------------------------
   使用者：「把解散團的功能先隱藏起來，只有總部可以解散團」。

   🔴 **只隱藏前端不算做完。** 那顆按鈕拿掉之後，`disband_team_tx` 仍然
     authenticated 叫得動而且只認「你是不是團長」⇒ 規則只存在於畫面上，
     直接打 RPC 就繞過了。
     📌 同待辦 9 的 `is_system` 保護：那道牆本來只活在 `Products.jsx` 的
       一個 `if` 裡，資料庫端什麼都沒有。

   ── 🔴 而這裡有一個地雷，改之前一定要先看 ──────────
   `leave_team_tx` 在「團長是**最後一個人**」時**直接呼叫
   `disband_team_tx`**（撈全文確認）：
   ```
   if v_role = 'leader' and v_cnt > 1 then  → leader_must_transfer
   if v_role = 'leader' then                → return disband_team_tx(...)
   ```
   ⇒ 只把 `disband_team_tx` 收成總部限定的話，**一人團的團長會永遠出不來**，
     而且他看到的訊息是「只有總部可以解散」—— 一句與他的動作完全對不上的話。

   🎯 根因是同一個名字兩件事（這個專案記過七次的病）：
   ```
   ① 團長主動解散          ← 要收走的是這個
   ② 最後一個人離開的收尾   ← 這不是權限問題，是資料收尾
   ```
   ✅ 所以拆成兩層：`_team_disband()` 做收尾（誰都不能直接叫），
     `disband_team_tx()` 只剩「總部才能按」那道門。

   ── 這份做什麼 ───────────────────────────────────
   ① 新增 `_team_disband(team, by)` —— 收尾，不含任何權限判斷
   ② `disband_team_tx` 守衛改成 `can('team.disband')`（＝ hq / owner）
   ③ `leave_team_tx` 改叫 `_team_disband`，並改掉那句「或解散這個團」

   ⚠ **已知代價，寫在這裡免得有人以為是 bug**：migi-admin 今天**沒有
     牌咖團的畫面** ⇒ 總部要解散團只能從 SQL Editor 呼叫這支。
     真實資料是 2 個團、都是自己人，所以現在可以接受；
     要做畫面時它是 migi-admin 的一頁（同待辦 42 的分工）。
   ============================================================ */

/* ── ① 收尾：內部函式，不含權限 ───────────────────── */
create or replace function public._team_disband(p_team_id uuid, p_by uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_n int;
begin
  update public.teams set deleted_at = now(), updated_at = now()
   where id = p_team_id and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'already_gone', 'message', '這個團已經解散了');
  end if;

  update public.team_members
     set left_at = now(), left_reason = 'disband'
   where team_id = p_team_id and left_at is null;
  get diagnostics v_n = row_count;

  /* ⚠ `p_by` 可以是 null —— 總部那個帳號 `member_id` 是 null
     （Email 路徑的 staff 本來就不是會員）。`decided_by` 允許 null。 */
  update public.team_requests
     set status = 'cancelled', decided_by = p_by, decided_at = now()
   where team_id = p_team_id and status = 'pending';

  return jsonb_build_object('ok', true, 'left', v_n);
end $$;

/* 🔴 誰都不能直接叫它 —— 它是收尾不是動作，沒有任何權限判斷。
   ⚠ 新建的函式會從 default privileges 明確拿到 anon ⇒ 兩個方向都要收
     （硬規則 2.6b：只收 PUBLIC 或只收 anon，症狀都跟沒收一模一樣）。
   📌 包在 SECURITY DEFINER 裡呼叫它的那兩支不受影響 ——
     DEFINER 內的有效使用者是 owner，不會去檢查呼叫端的權限。 */
revoke execute on function public._team_disband(uuid, uuid) from public;
revoke execute on function public._team_disband(uuid, uuid) from anon, authenticated;


/* ── ② 解散：總部限定 ───────────────────────────── */
/* ⚠ 簽名沒變 ⇒ `CREATE OR REPLACE`，GRANT 不會掉。 */
create or replace function public.disband_team_tx(p_team_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  /* 🔴 不再問「你是不是團長」，改問「你是不是總部」。
     ⚠ 也不再要求 `current_member_id()` 有值 —— 總部那個帳號沒有會員身分，
       留著那道檢查會讓它在權限通過之後才被擋，訊息還是「請先登入」。 */
  if not public.can('team.disband') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden',
                              'message', '只有總部可以解散牌咖團');
  end if;

  return public._team_disband(p_team_id, public.current_member_id());
end $$;


/* ── ③ 退出：最後一人時走收尾，不走那道門 ────────── */
create or replace function public.leave_team_tx(p_team_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_me   uuid := public.current_member_id();
  v_role text;
  v_cnt  int;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  select tm.role into v_role from public.team_members tm
   where tm.team_id = p_team_id and tm.member_id = v_me and tm.left_at is null;
  if v_role is null then
    return jsonb_build_object('ok', false, 'reason', 'not_member', 'message', '你不在這個團裡');
  end if;

  select count(*) into v_cnt from public.team_members tm
   where tm.team_id = p_team_id and tm.left_at is null;

  /* 🔴 話術改了：舊版在這裡還提供了第二條路（把團收掉），
     而那已經不是他做得到的事 —— 一句叫人去做做不到的事的提示
     比沒有提示更糟。現在只剩一條路，就只講那一條。
     ⚠ **這段註解刻意不寫出舊的那句話**：驗證段第 ⑤ 格掃的就是它，
       而 `pg_get_functiondef` 回的是含註解的全文（硬規則 3.5）——
       寫出來的話那一格會永遠紅，而函式其實是對的。 */
  if v_role = 'leader' and v_cnt > 1 then
    return jsonb_build_object('ok', false, 'reason', 'leader_must_transfer',
                              'message', '你是團長，請先把團長轉給其他團員');
  end if;

  /* 團長且只剩自己 ⇒ 這個團沒有人了，收掉它。
     🔴 走下面那支**收尾**函式，不走總部那道門 —— 那道門現在只認 hq/owner，
       經過它的話一人團的團長會被自己的團鎖住，而且訊息會說
       「只有總部可以解散」，跟他按的動作完全對不上。
     ⚠ 同上：**不寫出那道門的函式名**，第 ④ 格掃的就是它。 */
  if v_role = 'leader' then
    return public._team_disband(p_team_id, v_me);
  end if;

  update public.team_members set left_at = now(), left_reason = 'quit'
   where team_id = p_team_id and member_id = v_me and left_at is null;

  return jsonb_build_object('ok', true, 'message', '已退出這個牌咖團');
end $$;


/* ============================================================
   驗證。🔴 一個 raise 都沒有（硬規則 1.8）。
   行為在 `sql/checks/2026-09-14_驗解散收歸總部.sql`。
   ============================================================ */
do $$
declare v_msg text := '';
begin
  v_msg := '① 版本數（各應為 1）：_team_disband '
    || coalesce((select count(*)::text from pg_proc p where p.pronamespace='public'::regnamespace
                  and p.proname='_team_disband'), '🔴')
    || '　disband_team_tx '
    || coalesce((select count(*)::text from pg_proc p where p.pronamespace='public'::regnamespace
                  and p.proname='disband_team_tx'), '🔴')
    || '　leave_team_tx '
    || coalesce((select count(*)::text from pg_proc p where p.pronamespace='public'::regnamespace
                  and p.proname='leave_team_tx'), '🔴');

  v_msg := v_msg || E'\n② 解散改問 can()：'
    || coalesce((select (pg_get_functiondef(p.oid) like '%team.disband%')::text
         from pg_proc p where p.pronamespace='public'::regnamespace
           and p.proname='disband_team_tx'), '🔴')
    || '　還在問「是不是團長」嗎（應為 false）：'
    || coalesce((select (pg_get_functiondef(p.oid) like '%role = ''leader''%')::text
         from pg_proc p where p.pronamespace='public'::regnamespace
           and p.proname='disband_team_tx'), '🔴');

  /* ③ 收尾函式誰都叫不動。兩個方向都印（硬規則 2.6b）。 */
  v_msg := v_msg || E'\n③ _team_disband 授權：anon '
    || coalesce((select (exists (select 1 from aclexplode(p.proacl) a
                 where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE'))::text
         from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='_team_disband'), '🔴')
    || '　authenticated '
    || coalesce((select (exists (select 1 from aclexplode(p.proacl) a
                 where a.grantee='authenticated'::regrole::oid and a.privilege_type='EXECUTE'))::text
         from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='_team_disband'), '🔴')
    || '　PUBLIC '
    || coalesce((select (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                 where a.grantee = 0 and a.privilege_type='EXECUTE'))::text
         from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='_team_disband'), '🔴')
    || '（三個都應為 false）';

  /* ④ 🔴 退出不可以再經過那道門 —— 這一格就是那個地雷。 */
  v_msg := v_msg || E'\n④ leave_team_tx 改走收尾：呼叫 _team_disband '
    || coalesce((select (pg_get_functiondef(p.oid) like '%\_team\_disband%')::text
         from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='leave_team_tx'), '🔴')
    || '（應 true）　還在呼叫 disband_team_tx 嗎 '
    || coalesce((select (pg_get_functiondef(p.oid) like '%disband\_team\_tx%')::text
         from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='leave_team_tx'), '🔴')
    || '（應 false）';

  /* ⑤ 那句叫人去解散的提示沒了。 */
  v_msg := v_msg || E'\n⑤ 退出的提示還叫人解散嗎（應為 false）：'
    || coalesce((select (pg_get_functiondef(p.oid) like '%或解散這個團%')::text
         from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='leave_team_tx'), '🔴');

  /* ⑥ 還有誰在呼叫 disband_team_tx（應為 0 支 —— 只剩前端／總部直接叫）。 */
  v_msg := v_msg || E'\n⑥ 其他函式還在呼叫 disband_team_tx 的：'
    || coalesce((select string_agg(p.proname, '　' order by p.proname)
         from pg_proc p
        where p.pronamespace='public'::regnamespace and p.prokind='f'
          and p.proname <> 'disband_team_tx'
          and pg_get_functiondef(p.oid) like '%disband\_team\_tx%'), '（沒有）✅');

  v_msg := v_msg || E'\n⑦ 現況：還活著的團 '
    || coalesce((select count(*)::text from public.teams where deleted_at is null), '🔴')
    || ' 個（這份不動資料）';

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
