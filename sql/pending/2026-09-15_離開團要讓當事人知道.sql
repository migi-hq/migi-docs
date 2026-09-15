/* ============================================================
   離開團要讓當事人知道
   2026-09-15

   起點是一個問題：「退出後它會跟著消失」跟「只有總部才能解散」矛盾嗎？
   撈了線上全文，不矛盾 —— 但查的過程挖到一個**真的**缺口：

   ┌ 有三條路會讓一個人失去一個團，而**當事人完全不會收到任何通知** ┐
   │  ① kick_team_member_tx   團長把他移出                          │
   │  ② _team_disband         總部解散（團裡還有人）                │
   │  ③ 同上，由一人團的團長退出觸發（那時沒有別人，本來就沒人要通知）│
   └────────────────────────────────────────────────────────────┘
   他只會某天發現這個團從清單上不見了，而且分不出是被移出、解散了、
   還是 App 壞了。**一件發生在別人身上的事，當事人不知道。**

   ⚠ 這份**不擋**「團長逐一移出所有人再自己退出」那條繞過解散限制的路。
     擋了會連「三人團踢掉兩個不活躍的」這種正常管理一起擋掉 —— 過度阻擋
     跟沒擋一樣糟（硬規則 3.55）。改成**讓它被看見**：每一次移出都留下一則
     給當事人的通知，那比一道擋牆誠實。

   ── 為什麼新增一個型別，不借用既有的 ──────────────────
   `team_ok` 的意思是「團的好消息」。被移出、團解散了都不是好消息，
   借過來用就是**一個名字兩個意思** —— 這個專案記過七次的那個病。
   新值只是把 CHECK 的白名單加寬一格，而前端對沒見過的型別本來就會
   走「整句顯示」那條路（`ACTION_TEXT` 查不到就印 payload 的句子），
   `list_notifications_tx` 的 CASE 也沒有 ELSE ⇒ **前端一行都不用改**。

   ── 話術：不可以寫成「你已離開」 ─────────────────────
   `kick_team_member_tx` 自己的註解就寫著：寫 `kicked` 不重用 `quit`，
   因為 quit 的意思是「他自己走的」。
   ⇒ 資料層已經拒絕說那句話了，**畫面更不可以說**。
   ⚠ 也不點名團長：事實不需要那個名字就完整，而點名會把一則通知
     變成一次對質 —— 何況團長是誰在團卡上本來就看得到。
     所以 `p_from_name` 傳 null（那一格的意思是「開頭要顯示誰的暱稱」，
     這裡刻意不要有人）。

   ── 兩支簽名都沒變 ⇒ CREATE OR REPLACE ───────────────
   不用 DROP、不會丟 GRANT（硬規則 2）。
   `_team_disband` 原本就對 public / anon / authenticated 都收著，
   REPLACE 不會動 ACL —— 驗證段第 ④ 格就是在盯這件事。

   🔴 這份留下 DDL ⇒ **一個 raise 都不准有**（硬規則 1.8）。
     造樣本測行為的那一份在 sql/checks/2026-09-15_驗離團通知.sql。
   ============================================================ */


/* ── ① 通知型別加一格 ──────────────────────────────── */
alter table public.app_notifications
  drop constraint app_notifications_type_check;

alter table public.app_notifications
  add constraint app_notifications_type_check
  check (type = any (array[
    'settle','buddy_req','buddy_ok','table_req','table_ok',
    'system','table_expired','team_req','team_ok',
    'team_out'                                    -- 🆕 你不在這個團了
  ]));


/* ── ② 移出團員：告訴被移出的人 ─────────────────────── */
create or replace function public.kick_team_member_tx(p_team_id uuid, p_member_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_me   uuid := public.current_member_id();
  v_org  uuid;
  v_team text;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_member_id = v_me then
    return jsonb_build_object('ok', false, 'reason', 'self',
                              'message', '要離開請用退團，不是移除自己');
  end if;
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = v_me
                    and tm.left_at is null and tm.role = 'leader') then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以移除團員');
  end if;

  /* 🔴 寫 `kicked` 不重用 `quit` —— `quit` 的意思是「他自己走的」，
     店員移除卻寫 quit 會讓那個欄位說一件沒發生的事（同 2026-09-10
     配桌那批的決定）。而且它不會報錯，只會讓日後的流失分析算錯。 */
  update public.team_members set left_at = now(), left_reason = 'kicked'
   where team_id = p_team_id and member_id = p_member_id and left_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_member', 'message', '他不在這個團裡');
  end if;

  /* 🆕 通知。org 取自 teams 不取 current_org_id() ——
     那支要有身分才回得出東西，而這支日後可能被排程或總部工具呼叫，
     那時它會回 null，而 app_notifications.org_id 是 NOT NULL
     ⇒ 症狀會是「移出成功、通知整筆炸掉」。teams.org_id 在任何情境都成立。
     ⚠ 放在擋牆全部通過、而且真的移掉一列之後 —— 上面每一個 return
       都不可以留下一則說謊的通知。 */
  select t.org_id, t.name into v_org, v_team
    from public.teams t where t.id = p_team_id;

  perform public._team_notify(v_org, p_member_id, 'team_out', null,
            '你已被移出 ' || v_team, p_team_id, v_team, null);

  return jsonb_build_object('ok', true, 'message', '已移除');
end $function$;


/* ── ③ 團收掉：告訴還在裡面的人 ─────────────────────── */
create or replace function public._team_disband(p_team_id uuid, p_by uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_n    int;
  v_org  uuid;
  v_team text;
  v_mid  uuid;
begin
  update public.teams set deleted_at = now(), updated_at = now()
   where id = p_team_id and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'already_gone', 'message', '這個團已經解散了');
  end if;

  /* 🆕 通知要在**標記離開之前**送 —— 標完之後那些人就不在名單裡了，
     再去撈會一個都撈不到，而且不會報錯（同硬規則 4 那個形狀：
     濾成空陣列，看起來像「本來就沒人」）。 */
  select t.org_id, t.name into v_org, v_team
    from public.teams t where t.id = p_team_id;

  for v_mid in
    select tm.member_id from public.team_members tm
     where tm.team_id = p_team_id
       and tm.left_at is null
       /* 按下去的那個人不用通知他自己按了什麼。
          ⚠ 用 `is distinct from` 不用 `<>` —— 總部那條路 p_by 是 null，
            而 `任何值 <> null` 是 null 不是 true ⇒ 會變成一個都不通知
            （同硬規則 0.7：null 在運算式裡不是「沒有」，是會傳染）。 */
       and tm.member_id is distinct from p_by
  loop
    perform public._team_notify(v_org, v_mid, 'team_out', null,
              v_team || ' 已經解散了', p_team_id, v_team, null);
  end loop;

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
end $function$;


/* ── 驗證（單一 SELECT，全程不 raise：這份要留下 DDL） ─── */
do $$
declare
  v_msg  text := '';
  v_vals text[];
  v_n    int;
  v_a    boolean;
  v_p    boolean;
  v_row  record;
begin
  /* ① 白名單：9 個舊值 ＋ 1 個新值 = 10
        （期望值用算式寫出來，下次紅的時候才知道是哪一項變了，硬規則 3.56） */
  select array_agg(x order by x) into v_vals
    from regexp_matches(pg_get_constraintdef(c.oid), '''([a-z_]+)''::text', 'g') as m(x1),
         lateral (select x1[1]) as t(x)
   where c.conrelid = 'public.app_notifications'::regclass
     and c.conname  = 'app_notifications_type_check';

  v_msg := v_msg || case when array_length(v_vals, 1) = 10 then '✅' else '🔴' end
        || ' ① 通知型別 ' || coalesce(array_length(v_vals, 1), 0) || ' 個（期望 9＋1＝10）：'
        || array_to_string(v_vals, '、');

  /* ② 新值真的在裡面，而且舊值一個都沒被我打掉（正對照） */
  v_msg := v_msg || E'\n'
        || case when 'team_out' = any(v_vals) then '✅' else '🔴' end
        || ' ② 新值在　'
        || case when 'team_ok' = any(v_vals) and 'team_req' = any(v_vals)
                 and 'settle' = any(v_vals) and 'buddy_req' = any(v_vals)
                 and 'buddy_ok' = any(v_vals) and 'table_req' = any(v_vals)
                 and 'table_ok' = any(v_vals) and 'system' = any(v_vals)
                 and 'table_expired' = any(v_vals)
                then '✅ 舊值 9 個全在' else '🔴 有舊值被打掉了' end;

  /* ③ 兩支各只有一個版本（多載會讓前端叫到舊的那支，而且不報錯） */
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname = 'kick_team_member_tx';
  v_msg := v_msg || E'\n' || case when v_n = 1 then '✅' else '🔴' end
        || ' ③ 移出團員 版本數 ' || v_n;

  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname = '_team_disband';
  v_msg := v_msg || '　收尾函式 版本數 ' || v_n;

  /* ④ 授權沒被 REPLACE 弄掉。
        兩個方向都印（硬規則 2.6b）：明確授權 與 PUBLIC 各自有沒有，
        因為 has_function_privilege 分不出這兩種。 */
  select exists (select 1 from aclexplode(p.proacl) a
                  where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE'),
         (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                  where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
    into v_a, v_p
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname = 'kick_team_member_tx';
  v_msg := v_msg || E'\n' || case when v_a then '✅' else '🔴' end
        || ' ④ 移出團員 anon 明確授權 ' || coalesce(v_a::text, '?')
        || '（前端要叫得動）　PUBLIC ' || coalesce(v_p::text, '?');

  select exists (select 1 from aclexplode(p.proacl) a
                  where a.grantee in ('anon'::regrole::oid, 'authenticated'::regrole::oid)
                    and a.privilege_type = 'EXECUTE'),
         (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                  where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
    into v_a, v_p
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname = '_team_disband';
  v_msg := v_msg || E'\n' || case when (not v_a) and (not v_p) then '✅' else '🔴' end
        || ' ⑤ 收尾函式 仍然收著：前端明確授權 ' || coalesce(v_a::text, '?')
        || '　PUBLIC ' || coalesce(v_p::text, '?') || '（兩個都要是 false）';

  /* ⑥ 既有資料沒被動到。逐行印出讓人判讀，不回傳是非題（硬規則 3.5）。
        ⚠ 這一格永遠不會是 🔴 —— 它的工作是讓人看見「加寬白名單沒有
          動到任何一列」，而不是斷言什麼。 */
  v_msg := v_msg || E'\n⚪ ⑥ 現有通知各型別列數（加寬白名單不會動到資料）：';
  for v_row in
    select n.type, count(*) as c from public.app_notifications n
     group by n.type order by count(*) desc
  loop
    v_msg := v_msg || E'\n      ' || rpad(v_row.type, 16) || v_row.c || ' 列';
  end loop;

  v_msg := v_msg || E'\n\n📌 行為（真的有沒有發通知）在 sql/checks/2026-09-15_驗離團通知.sql，'
                 || '那一份會造樣本並整個回滾。';

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
