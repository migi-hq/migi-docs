/* ============================================================
   🔴 取消開桌之後，**已經滿的房**回到 waiting 就再也配不到桌
   2026-09-06 · MIGI 咪吉麻將

   ── 使用者問的 ────────────────────────────────────────
   「即時桌況選取消開桌，配桌列表開桌還在，是 BUG 嗎？」
   → **那個不是** —— 房回到排隊正是同日
     `trg_session_voided_release_queue` 設計的行為（人還在、時間也還沒到）。

   ── 🔴 但查下去發現一個我自己造成的死路 ────────────────
   那個觸發器**一律把房放回 `waiting`**。而：
   ```sql
   -- sweep_auto_seat_tx（pg_cron 每 5 分鐘）
   where q.status = 'matched' and q.matched_session_id is null
   ```
   ⇒ 只掃 `matched`。而成桌本身是靠「**有人加入**」觸發的
     （`_finalize_queue_full_tx` 在 join 時呼叫），
     **已經滿的房不會再有人加入**。

   ⇒ 一個 4/4 的房被放回 `waiting` 之後：
     · sweep 撿不到它
     · 也不會再有人加入來觸發成桌
     ⇒ **那四個人卡在一個永遠不會再配到桌的滿房裡**，直到過期。

   ⚠ 它不會報錯，畫面上還是「配桌中」，**看起來完全正常**。

   ── 修法：依「滿了沒」分岔（那是我當初就該分的）──────
   ```
   人數 >= seats  →  matched   （四人到齊、等桌 —— sweep 會撿它）
   人數 <  seats  →  waiting   （還在等人）
   過了開打時間+寬限 → expired  （沒變）
   ```
   🎯 三個狀態的語意本來就是這樣：
     `waiting` = 還在等人／`matched` = 人到齊了等桌／`seated` = 有桌了。
     我原本一律寫 `waiting`，等於**把「等桌」講成「等人」**。

   ⚠ 回 `matched` 時 `matched_at` **要留著**（它記的是「什麼時候湊滿的」，
     而它確實還是滿的）；回 `waiting` 才清掉。
   📌 POS 那邊本來就有對應的畫面：`QueueCard` 的 `stuck` 狀態
     「已滿 · 沒有空桌 · 四人已到齊，等有桌釋出系統會自動帶」——
     那段程式碼 2026-09-06 才剛因為 `pos_list_queues_tx` 不放行 `matched`
     而從「永遠不會執行」被救活，現在終於有真的資料會走到它。
   ============================================================ */

create or replace function public.trg_session_voided_release_queue()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r record;
  v_n int;
  /* 寬限與 `cleanup_empty_sessions_tx` 的預設一致（30 分）。
     ⚠ 兩邊要是不一樣，會出現「排程收了桌、但觸發器認為還沒過期
       所以把房放回去」→ 下一輪又配一張桌又被收，無限循環。 */
  c_grace constant interval := interval '30 minutes';
begin
  for r in
    select q.id, q.org_id, q.play_at, q.expires_at, q.source, q.seats
      from match_queues q
     where q.matched_session_id = new.id
       and q.status = 'seated'
     for update
  loop
    if now() < r.play_at + c_grace then
      select count(*) into v_n
        from match_queue_players qp
       where qp.queue_id = r.id and qp.left_at is null;

      /* ★ 2026-09-06：依「滿了沒」分岔。
         🔴 舊版一律回 `waiting`，而 `sweep_auto_seat_tx` **只掃 `matched`**
           ⇒ 一個 4/4 的房被放回 waiting 之後，sweep 撿不到它，
             也不會再有人加入來觸發成桌 ⇒ **永遠配不到桌**，
             而畫面上還是「配桌中」，看起來完全正常。 */
      if v_n >= coalesce(r.seats, 4) then
        -- 人到齊了，只是沒有桌 → 交給 sweep 找下一張
        update match_queues
           set status = 'matched',
               matched_session_id = null,
               -- ⚠ `matched_at` 留著：它記的是「什麼時候湊滿的」，而它還是滿的
               expires_at = greatest(r.expires_at, r.play_at, now() + interval '15 minutes'),
               updated_at = now()
         where id = r.id;
      else
        update match_queues
           set status = 'waiting',
               matched_session_id = null,
               matched_at = null,
               expires_at = greatest(r.expires_at, r.play_at, now() + interval '15 minutes'),
               updated_at = now()
         where id = r.id;
      end if;

      insert into app_notifications(org_id, member_id, type, payload, ref_id)
      select r.org_id, qp.member_id, 'system',
             jsonb_build_object(
               'text', case when v_n >= coalesce(r.seats, 4)
                            then '原本安排的桌取消了，正在幫你找下一張桌'
                            else '原本安排的桌取消了，已幫你回到配桌等待' end,
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


-- ══════════════════════════════════════════════════════
-- 一次性：把現在卡住的滿房推回 matched
-- ══════════════════════════════════════════════════════
do $fix$
declare v_n int;
begin
  /* 🔴 修觸發器不會修好**已經卡住**的房（同日已經學過一次）。
     條件：`waiting` ＋ 已經滿 ＋ 沒有桌 ＋ 還沒過開打時間。 */
  update match_queues q
     set status = 'matched', updated_at = now()
   where q.status = 'waiting'
     and q.matched_session_id is null
     and q.play_at > now()
     and (select count(*) from match_queue_players p
           where p.queue_id = q.id and p.left_at is null) >= coalesce(q.seats, 4);
  get diagnostics v_n = row_count;
  perform set_config('migi.fix', v_n::text || ' 個卡住的滿房推回 matched', true);
end $fix$;


-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
do $v$
declare
  v_out text := '';
  v_q uuid; v_sess uuid; v_st text; v_n int; v_seats int;
begin
  v_out := v_out || E'\n⓪ 一次性推回' || E'\t' || coalesce(current_setting('migi.fix', true), '(沒有紀錄)');

  /* ⚠ **不要求那個房現在就指著一張桌。**
     🔴 第一次跑就是這樣失敗的：⓪ 把卡住的房修好之後，
       它的 `matched_session_id` 被清空 ⇒ 取樣條件不再成立
       ⇒ 七格全部沒跑。**修好的東西反而讓驗證找不到樣本**，
       而那正是「驗證依賴線上當下狀態」的老問題（同日第二次）。
     🎯 只要「有人的房」＋「任何一張桌」，剩下的在交易裡自己接起來
       —— 整段最後會回滾。 */
  select q.id, q.seats into v_q, v_seats
    from match_queues q
   where exists (select 1 from match_queue_players p
                  where p.queue_id = q.id and p.left_at is null)
   order by q.updated_at desc limit 1;
  select ts.id into v_sess from table_sessions ts
   where ts.deleted_at is null order by ts.created_at desc limit 1;

  if v_q is null or v_sess is null then
    perform set_config('migi.v', v_out || E'\n🔴 取樣失敗' || E'\t' ||
      '房=' || coalesce(v_q::text,'無') || '　桌=' || coalesce(v_sess::text,'無') ||
      ' —— 下面每一格都不算數', true);
    return;
  end if;

  select count(*) into v_n from match_queue_players
   where queue_id = v_q and left_at is null;

  ---- ① 滿的房：桌作廢 → matched（不是 waiting）----------
  update match_queues set status='seated', matched_session_id=v_sess,
         play_at = now() + interval '60 minutes', seats = v_n   -- 借成「剛好滿」
   where id = v_q;
  update table_sessions set status='open', ended_at=null where id = v_sess;
  update table_sessions set status='voided', ended_at=now()   where id = v_sess;

  select status into v_st from match_queues where id = v_q;
  v_out := v_out || E'\n① 滿的房 → matched' || E'\t' ||
    case when v_st = 'matched' then '✅ matched（sweep 撿得到）'
         when v_st = 'waiting' then '🔴 waiting —— 就是那個死路'
         else '🔴 ' || v_st end;

  ---- ② 🎯 sweep 的條件真的成立 --------------------------
  /* 光是「狀態對」不夠 —— sweep 還要求 `matched_session_id is null`。 */
  select count(*) into v_n from match_queues
   where id = v_q and status='matched' and matched_session_id is null;
  v_out := v_out || E'\n② 🎯 sweep 的條件成立' || E'\t' ||
    case when v_n = 1 then '✅ matched ＋ 沒有桌' else '🔴 條件不符，sweep 還是撿不到' end;

  ---- ③ 🎯 正對照：沒滿的房仍然回 waiting ----------------
  /* 只驗 ① 的話，一支**一律回 matched** 的實作也會綠 ——
     而那會讓「還差兩個人」的房謊稱人到齊了。

     ⚠ 借「沒滿」的狀態要**讓一個人離開**，不能去加大 `seats`：
       🔴 第一次就是那樣寫，撞到 `match_queues_seats_check`
         （`seats >= 2 and seats <= 4`）—— 4 個人的房設成 6 就違反。
       同硬規則 3.8：**約束名稱不等於約束內容，動它之前要先撈定義。** */
  update match_queue_players
     set left_at = now(), leave_reason = 'quit'
   where id = (select p.id from match_queue_players p
                where p.queue_id = v_q and p.left_at is null limit 1);

  select count(*) into v_n from match_queue_players
   where queue_id = v_q and left_at is null;
  -- ⚠ ① 把 seats 借成了「剛好滿」，這裡要讀現值不是取樣時的舊值
  select seats into v_seats from match_queues where id = v_q;

  update match_queues set status='seated', matched_session_id=v_sess where id = v_q;
  update table_sessions set status='open', ended_at=null where id = v_sess;
  update table_sessions set status='voided', ended_at=now()   where id = v_sess;

  select status into v_st from match_queues where id = v_q;
  v_out := v_out || E'\n③ 🎯 正對照：沒滿的房 → waiting' || E'\t' ||
    case when v_st = 'waiting' then '✅ waiting（' || v_n || '/' || v_seats || '，還在等人）'
         else '🔴 ' || v_st || '（' || v_n || '/' || v_seats || '）' end;

  ---- ④ 🎯 正對照：過了開打時間仍然流局 ------------------
  update match_queues set status='seated', matched_session_id=v_sess,
         play_at = now() - interval '120 minutes' where id = v_q;
  update table_sessions set status='open', ended_at=null where id = v_sess;
  update table_sessions set status='voided', ended_at=now()   where id = v_sess;

  select status into v_st from match_queues where id = v_q;
  select count(*) into v_n from match_queue_players where queue_id=v_q and left_at is null;
  v_out := v_out || E'\n④ 🎯 正對照：過了開打時間 → 流局' || E'\t' ||
    case when v_st='expired' and v_n=0 then '✅ expired 且人已標離開'
         else '🔴 房=' || v_st || '　還在房裡=' || v_n end;

  ---- ⑤ 通知的文案分得出兩種情況 -------------------------
  select count(*) into v_n from app_notifications
   where ref_id = v_q and payload ->> 'text' like '%找下一張桌%';
  v_out := v_out || E'\n⑤ 滿的房通知說「找下一張桌」' || E'\t' ||
    case when v_n > 0 then '✅ ' || v_n || ' 則'
         else '🟡 沒有 —— 客人會以為要重新等人' end;

  raise exception 'migi_rollback';

exception when others then
  /* 🔴 訊息設在這裡（硬規則 3.9）。
     ⚠ ①③④ 有真的寫入，靠這個 raise 回滾；
       上面那個一次性推回是**另一個 DO 區塊**，不受影響。 */
  perform set_config('migi.v',
    v_out || case when sqlerrm <> 'migi_rollback'
                  then E'\n🔴 驗證中斷' || E'\t' || sqlerrm else '' end, true);
end $v$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(coalesce(current_setting('migi.v', true), ''), E'\n')) as x
 where coalesce(x, '') <> '';
