/* ============================================================
   桌被作廢時，配桌房要回去排隊（而不是無聲消失）
   2026-09-06 · MIGI 咪吉麻將

   ── 洞在哪 ────────────────────────────────────────────
   2026-09-06 實測：A3 被排程作廢之後，
   ```
   table_sessions  voided
   match_queues    seated      ← 沒有任何人還原它
   ```
   ⇒ 那個房**永遠停在 `seated`**、指著一張已經不存在的桌。
   而四個客人的配桌畫面**直接消失，沒有任何說明** ——
   他們只會看到「你已經成桌囉」變成「我要配桌」。

   ✅ 好消息：**不會卡住他們**（`_check_join_conflict` 只看
     `waiting` 與 `matched`，`seated` 不擋）—— 但那是運氣不是設計。

   ── 🔴 為什麼用觸發器，不改 `void_session_tx` ─────────
   桌會變成 `voided` 有**兩條路**，而且都會製造孤兒：
   ```
   ① void_session_tx        店員在 POS 按「取消開桌」
   ② cleanup_empty_sessions_tx   排程回收（A3 就是這條）
   ```
   改函式要改兩個地方，而且**會漏掉未來新增的第三條**。
   觸發器一個地方涵蓋所有路徑，且完全不碰既有函式
   —— 同待辦 24 的判斷（觸發器掛在 `orders` 而不改 `checkout_tx`）。

   ── 兩種結局，由「開打時間過了沒」決定 ────────────────
   | 情況 | 房 | 人 | 通知 |
   |---|---|---|---|
   | **還沒到開打時間**（店員開錯桌） | 回 `waiting` | 留在房裡 | 「桌取消了，已幫你回到配桌等待」 |
   | **過了開打時間 ＋ 寬限**（沒人來） | `expired` | 標離開 | 「人數不足，本場流局」 |

   🎯 **判準不需要知道是誰做的** —— 用 `now() < play_at + 寬限` 就分得開，
     而那正好對應兩條路徑的實際情境（排程只在過了寬限之後才會動它，
     見同日的 `2026-09-06_空桌回收不要清掉預留中的桌.sql`）。

   ⚠ **回 `waiting` 時要延長 `expires_at`** —— 不延的話
     `sweep_expired_queues_tx`（每 5 分鐘）會在下一輪就把它判成流局，
     客人等於「回到排隊」了三分鐘又被踢掉。
     給 15 分鐘＝自動配桌 sweep 的**三個週期**（每 5 分鐘一次），
     夠它試著找下一張桌。

   ⚠ 通知用 `type = 'system'`：`app_notifications_type_check` 的白名單
     只有 `settle / buddy_req / buddy_ok / table_req / table_ok /
     system / table_expired`，**沒有適合的**。
     為了一則訊息去改 CHECK 是待辦 0.8 那個形狀（每加一種就改一次約束）。
   ============================================================ */

create or replace function public.trg_session_voided_release_queue()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r record;
  /* 寬限與 `cleanup_empty_sessions_tx` 的預設一致（30 分）。
     ⚠ 兩邊要是不一樣，會出現「排程收了桌、但觸發器認為還沒過期
       所以把房放回 waiting」→ 下一輪又配一張桌又被收，無限循環。 */
  c_grace constant interval := interval '30 minutes';
begin
  for r in
    select q.id, q.org_id, q.play_at, q.expires_at, q.source
      from match_queues q
     where q.matched_session_id = new.id
       and q.status = 'seated'
     for update
  loop
    if now() < r.play_at + c_grace then
      ---- 桌沒了，但人還在、時間也還沒到 → 回去排隊 --------
      update match_queues
         set status = 'waiting',
             matched_session_id = null,
             matched_at = null,
             /* 🔴 不延長的話 sweep 下一輪就把它判流局（見檔頭）。 */
             expires_at = greatest(r.expires_at, r.play_at, now() + interval '15 minutes'),
             updated_at = now()
       where id = r.id;

      insert into app_notifications(org_id, member_id, type, payload, ref_id)
      select r.org_id, qp.member_id, 'system',
             jsonb_build_object(
               'text', '原本安排的桌取消了，已幫你回到配桌等待',
               'queue_id', r.id, 'play_at', r.play_at),
             r.id
        from match_queue_players qp
       where qp.queue_id = r.id and qp.left_at is null;

    else
      ---- 過了開打時間還沒有人來 → 流局（比照 sweep）-------
      update match_queues set status = 'expired', updated_at = now() where id = r.id;

      insert into app_notifications(org_id, member_id, type, payload, ref_id)
      select r.org_id, qp.member_id, 'table_expired',
             jsonb_build_object(
               'text', case when r.source = 'recurring'
                            then '固定局人數不足，本場流局'
                            else '人數不足，本場流局' end,
               'queue_id', r.id, 'play_at', r.play_at),
             r.id
        from match_queue_players qp
       where qp.queue_id = r.id and qp.left_at is null;

      update match_queue_players
         set left_at = now(), leave_reason = 'expired'
       where queue_id = r.id and left_at is null;
    end if;
  end loop;

  return new;
end $function$;

drop trigger if exists trg_session_voided_release_queue on table_sessions;
create trigger trg_session_voided_release_queue
  after update of status on table_sessions
  for each row
  when (new.status = 'voided' and old.status is distinct from 'voided')
  execute function public.trg_session_voided_release_queue();


-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
do $v$
declare
  v_out text := '';
  v_q uuid; v_sess uuid; v_org uuid;
  v_st text; v_n int; v_exp timestamptz; v_play timestamptz;
begin
  /* ⚠ 取樣要求「**現在就有在座的人**」——
     🔴 第一版是先 `update match_queue_players set left_at = null`
       把所有人復活，結果撞到
       `uq_queue_member UNIQUE (queue_id, member_id) WHERE left_at IS NULL`：
       樣本房是 4 個在座 ＋ **1 個已離開**，而那個離開的人本來就還有一列在座
       ⇒ 復活之後同一個人有兩列 left_at is null。
     🎯 正解不是加 `on conflict`，是**不要動那個欄位** ——
       驗證需要的是「有人在房裡」，而樣本本來就有。 */
  select q.id, q.matched_session_id, q.org_id into v_q, v_sess, v_org
    from match_queues q
   where q.matched_session_id is not null
     and exists (select 1 from match_queue_players p
                  where p.queue_id = q.id and p.left_at is null)
   order by q.updated_at desc limit 1;

  if v_q is null then
    perform set_config('migi.v', E'\n🔴 取樣失敗' || E'\t' ||
      '找不到「有 matched_session_id 且還有人在座」的房 —— 下面每一格都不算數', true);
    return;
  end if;

  /* 借用樣本：房 seated、桌 open、開打時間在一小時後
     —— 那正是「店員開錯桌按取消」的情境。整段最後回滾。 */
  update match_queues
     set status = 'seated', matched_session_id = v_sess,
         play_at = now() + interval '60 minutes',
         expires_at = now() - interval '10 minutes'   -- 故意設成已過期，驗延長
   where id = v_q;
  update table_sessions set status = 'open', ended_at = null where id = v_sess;
  delete from app_notifications where ref_id = v_q;

  ---- ① 取消開桌 → 房回 waiting -------------------------
  update table_sessions set status = 'voided', ended_at = now() where id = v_sess;
  select status, expires_at, play_at into v_st, v_exp, v_play from match_queues where id = v_q;
  v_out := v_out || E'\n① 桌作廢後房回到排隊' || E'\t' ||
    case when v_st = 'waiting' then '✅ waiting（原本永遠停在 seated）'
         else '🔴 還是 ' || v_st end;

  ---- ② 🎯 正對照：人要留在房裡 --------------------------
  /* 只驗 ① 的話，一支把房設成 waiting **卻把人清光**的實作也會綠 ——
     而那時房是空的，等於白等。 */
  select count(*) into v_n from match_queue_players
   where queue_id = v_q and left_at is null;
  v_out := v_out || E'\n② 🎯 正對照：人還在房裡' || E'\t' ||
    case when v_n > 0 then '✅ ' || v_n || ' 人' else '🔴 0 人 —— 房是空的' end;

  ---- ③ 有通知，而且客人看得懂 ---------------------------
  select count(*) into v_n from app_notifications
   where ref_id = v_q and payload ->> 'text' like '%回到配桌等待%';
  v_out := v_out || E'\n③ 有發通知' || E'\t' ||
    case when v_n > 0 then '✅ ' || v_n || ' 則' else '🔴 沒有 —— 客人不會知道發生什麼事' end;

  ---- ④ 🎯 正對照：expires_at 有延長 ---------------------
  /* 不延的話 sweep（每 5 分鐘）下一輪就把它判流局，
     客人「回到排隊」三分鐘又被踢掉。 */
  v_out := v_out || E'\n④ 🎯 正對照：expires_at 有延長' || E'\t' ||
    case when v_exp > now() then '✅ 還有 ' || round(extract(epoch from (v_exp - now()))/60) || ' 分鐘'
         else '🔴 已過期 —— 下一輪 sweep 就會把它判流局' end;

  ---- ⑤ 🎯 正對照：過了開打時間就流局，不要無限回鍋 ------
  update match_queues
     set status = 'seated', matched_session_id = v_sess,
         play_at = now() - interval '120 minutes'
   where id = v_q;
  update table_sessions set status = 'open', ended_at = null where id = v_sess;
  update table_sessions set status = 'voided', ended_at = now() where id = v_sess;

  select status into v_st from match_queues where id = v_q;
  select count(*) into v_n from match_queue_players where queue_id = v_q and left_at is null;
  v_out := v_out || E'\n⑤ 🎯 正對照：過了開打時間 → 流局' || E'\t' ||
    case when v_st = 'expired' and v_n = 0 then '✅ expired 且人已標離開'
         else '🔴 房=' || v_st || '　還在房裡的人=' || v_n end;

  ---- ⑥ 🎯 正對照：沒有配桌房的桌，作廢不受影響 ----------
  select count(*) into v_n
    from table_sessions ts
   where ts.status = 'voided'
     and not exists (select 1 from match_queues q where q.matched_session_id = ts.id);
  v_out := v_out || E'\n⑥ 🎯 正對照：一般的桌照樣作廢得了' || E'\t' ||
    case when v_n > 0 then '✅ ' || v_n || ' 張（觸發器沒有擋到別人）'
         else '🟡 目前沒有這種桌可以比對' end;

  raise exception 'migi_rollback';

exception when others then
  /* 🔴 訊息設在這裡（硬規則 3.9）。 */
  perform set_config('migi.v',
    v_out || case when sqlerrm <> 'migi_rollback'
                  then E'\n🔴 驗證中斷' || E'\t' || sqlerrm else '' end, true);
end $v$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(coalesce(current_setting('migi.v', true), ''), E'\n')) as x
 where coalesce(x, '') <> '';
