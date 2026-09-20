-- ============================================================
-- 驗「收桌真的會發成就事件」—— 造樣本測行為，最後整個回滾
-- 2026-09-20　前置：`sql/applied/2026-09-20_收桌發成就事件.sql` 已執行
--
-- 🔴 與那一份分家的理由（硬規則 1.8）：
--   那一份要**留下**函式 ⇒ 一個字都不准 raise
--   這一份要**造場次** ⇒ 只能 raise 回滾（沒有 staging，硬規則 5.7）
--
-- ⚠ 這份不留下任何東西，可以重複跑。
-- 🔴 它會真的呼叫 `settle_session_tx`，而那一支會動
--   `session_players` / `table_sessions` / `app_notifications` /
--   `member_achievements` —— **全部靠最外層那個 raise 回滾**。
-- ============================================================

do $$
declare
  v_msg     text := '';
  v_org     uuid;
  v_store   uuid;
  v_table   uuid;
  v_stake   uuid;
  v_m1      uuid;
  v_m2      uuid;
  v_sess    uuid;
  v_r       jsonb;
  v_n       int;
begin
  begin
    -- ---------- 造樣本 ----------
    select m.id, m.org_id into v_m1, v_org
      from members m where m.is_test and m.deleted_at is null
     order by m.created_at limit 1;
    select m.id into v_m2
      from members m where m.is_test and m.deleted_at is null and m.id <> v_m1
     order by m.created_at limit 1;

    select t.id, t.store_id into v_table, v_store
      from tables t where t.deleted_at is null
       and not exists (select 1 from table_sessions s
                        where s.table_id = t.id and s.status = 'open'
                          and s.deleted_at is null)
     limit 1;

    select id into v_stake from stake_levels
     where deleted_at is null and not is_hygiene order by sort_order limit 1;

    -- 🔴 找不到樣本要**出聲**，不要 if…then 安靜跳過（硬規則 3.57）
    if v_m1 is null or v_m2 is null then
      v_msg := '⚪ 測試會員不足兩個，整份測不了'; raise exception 'migi_rollback';
    end if;
    if v_table is null then
      v_msg := '⚪ 找不到一張沒有進行中場次的桌，整份測不了'; raise exception 'migi_rollback';
    end if;

    -- 一場「配桌」場次（mode = 'matched'）
    insert into table_sessions (org_id, store_id, table_id, stake_level_id,
                                status, mode, open_method, started_at)
    values (v_org, v_store, v_table, v_stake, 'open', 'matched', 'manual', now())
    returning id into v_sess;

    -- 兩個玩家：一個贏（final_score > 0）、一個輸
    insert into session_players (org_id, session_id, member_id, joined_at,
                                 charged_points, final_score)
    values (v_org, v_sess, v_m1, now(), 100,  200),
           (v_org, v_sess, v_m2, now(), 100, -200);

    -- ---------- 收桌 ----------
    -- ⚠ placeholder_ranks_tx 可能會覆寫 final_score（live_from 還沒到時），
    --   所以下面每一格都**重新查一次真正的值**再判斷，不要假設是 200／−200。
    v_r := public.settle_session_tx(v_sess, null, false);
    v_msg := case when (v_r->>'ok')::boolean
      then '✅ ① 收桌本身成功（' || coalesce(v_r->>'players_left','?') || ' 人離座）'
      else '🔴 ① 收桌失敗，後面每一格都不用看：' || v_r::text end;

    -- ---------- ② session_finished：兩個人都要有 ----------
    select count(distinct ma.member_id) into v_n
      from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where a.code = 'onboarding_02' and ma.status = 'unlocked'
       and ma.member_id in (v_m1, v_m2);
    v_msg := v_msg || E'\n' || case when v_n = 2
      then '✅ ② session_finished 發給了兩個人（第一次開桌）'
      else '🔴 ② 只有 ' || v_n || ' 個人拿到「第一次開桌」，應為 2' end;

    -- ---------- ③ 🔴 session_won：只有贏的人 ----------
    -- 這一格是整份最重要的：判準是**桌上積分的正負**不是名次
    select count(*) into v_n
      from member_achievements ma
      join achievements a on a.id = ma.achievement_id
      join session_players sp on sp.member_id = ma.member_id and sp.session_id = v_sess
     where a.code = 'onboarding_12' and ma.status = 'unlocked'
       and ma.member_id in (v_m1, v_m2)
       and coalesce(sp.final_score, 0) <= 0;      -- 不該拿到卻拿到了
    v_msg := v_msg || E'\n' || case when v_n = 0
      then '✅ ③ session_won 沒有發給積分不是正的人'
      else '🔴 ③ 有 ' || v_n || ' 個非正分的人拿到「第一次贏得牌局」' end;

    select count(*) into v_n
      from member_achievements ma
      join achievements a on a.id = ma.achievement_id
      join session_players sp on sp.member_id = ma.member_id and sp.session_id = v_sess
     where a.code = 'onboarding_12' and ma.status = 'unlocked'
       and coalesce(sp.final_score, 0) > 0;
    v_msg := v_msg || E'\n' || case when v_n >= 1
      then '✅ ③ 而積分為正的人確實拿到了（正對照）'
      else '⚪ ③ 這一場沒有人積分為正 —— 這一格測不出東西'
           || '（placeholder_ranks_tx 覆寫了樣本分數）' end;

    -- ---------- ④ queue_session_done：mode = 'matched' ----------
    select count(distinct ma.member_id) into v_n
      from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where a.code = 'onboarding_09' and ma.status = 'unlocked'
       and ma.member_id in (v_m1, v_m2);
    v_msg := v_msg || E'\n' || case when v_n = 2
      then '✅ ④ queue_session_done 發了（這一場 mode = matched）'
      else '🔴 ④ 只有 ' || v_n || ' 個人拿到「第一次參與配桌」，應為 2' end;

    -- ---------- ⑤ 🔴 負對照：booking_session_done **不可以**發 ----------
    -- 這一場沒有任何 bookings 指過來 ⇒ 發了就表示條件判斷失效
    select count(distinct ma.member_id) into v_n
      from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where a.code = 'onboarding_10' and ma.status = 'unlocked'
       and ma.member_id in (v_m1, v_m2);
    v_msg := v_msg || E'\n' || case when v_n = 0
      then '✅ ⑤ booking_session_done 沒有誤發（這一場不是包桌預約）'
      else '🔴 ⑤ 有 ' || v_n || ' 個人拿到「第一次預約包桌」—— 條件判斷失效了' end;

    -- ---------- ⑥ 🔴 C 區那 31 枚是 is_active = false，不可以被碰到 ----------
    select count(*) into v_n
      from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where a.code like 'tile\_%' and ma.member_id in (v_m1, v_m2)
       and ma.status <> 'locked';
    v_msg := v_msg || E'\n' || case when v_n = 0
      then '✅ ⑥ C 區 31 枚（is_active=false）一枚都沒被碰到'
      else '🔴 ⑥ 有 ' || v_n || ' 枚牌型成就動了 —— is_active 沒有在擋' end;

    -- ---------- ⑦ 🎯 端到端：meta 也跟上了嗎 ----------
    -- 新手畢業門檻 15，這一場只解得開 3 枚 ⇒ **不該**解鎖
    select count(*) into v_n
      from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where a.code = 'onboarding_29' and ma.status = 'unlocked'
       and ma.member_id in (v_m1, v_m2);
    v_msg := v_msg || E'\n' || case when v_n = 0
      then '✅ ⑦ 新手畢業沒有被誤開（門檻 15，這一場只解得開 3 枚）'
      else '🔴 ⑦ 新手畢業被開了 ' || v_n || ' 個人 —— meta 門檻失效' end;

    -- ---------- ⑧ 🔴 重複收桌不可以再發一次 ----------
    v_r := public.settle_session_tx(v_sess, null, false);
    v_msg := v_msg || E'\n' || case when (v_r->>'already_settled')::boolean
      then '✅ ⑧ 第二次收桌回 already_settled（成就不會重發）'
      else '🔴 ⑧ 第二次收桌沒有走冪等那條路：' || v_r::text end;

    raise exception 'migi_rollback';

  exception when others then
    -- 🔴 訊息一定要在 handler 裡設（硬規則 3.9）
    if sqlerrm = 'migi_rollback' then
      perform set_config('migi.verify', v_msg || E'\n\n🧹 樣本已全部回滾。', true);
    else
      perform set_config('migi.verify',
        v_msg || E'\n\n🔴 意外中斷：' || sqlstate || ' ' || sqlerrm, true);
    end if;
  end;
end $$;

select coalesce(nullif(current_setting('migi.verify', true), ''), '🔴 沒有驗證訊息') as "行為測試";
