-- ============================================================
-- 驗成就引擎「真的會動」—— 造樣本測行為，最後整個回滾
-- 2026-09-20　前置：建表 ＋ 核心 RPC ＋ 補正（三份都已執行）
--
-- 🔴 **這份與那三份的分工來自硬規則 1.8**：
--   要留下 DDL 的檔案 → **一個字都不准 raise**（raise 會把 DDL 一起回滾）
--   要造樣本測行為的 → **只能 raise 回滾**（不然會在正式庫留下測試資料）
--   ⇒ 所以行為測試一定是獨立的一份，放 sql/checks/。
--
-- ⚠ 這份**不留下任何東西**，可以重複跑。
-- ⚠ 沒有 staging（硬規則 5.7），所以造的樣本全部靠回滾清掉，
--   而且測試成就的 code 一律 `_t_` 前綴，萬一回滾失敗也認得出來。
-- ============================================================

do $$
declare
  v_msg    text := '';
  v_org    uuid;
  v_member uuid;
  v_line   text;
  v_r      jsonb;
  v_n      int;
  v_a1     uuid;
  v_a2     uuid;
begin
  begin
    -- ---------- 造樣本 ----------
    select m.id, m.org_id, m.line_user_id into v_member, v_org, v_line
    from members m
    where m.is_test and m.deleted_at is null
    order by m.created_at limit 1;

    if v_member is null then
      v_msg := '⚪ 找不到測試會員，整份測不了';
      raise exception 'migi_rollback';
    end if;

    insert into achievements(org_id, code, name, ui_category, struct, motivation, rarity, trigger)
    values (v_org, '_t_spec',   '測試一次性', 'onboarding', 'specific',   'completion', 'norm', '{"event":"_t_evt"}'::jsonb),
           (v_org, '_t_cum',    '測試累積',   'game',       'cumulative', 'completion', 'norm', '{"event":"_t_evt"}'::jsonb),
           (v_org, '_t_streak', '測試連續',   'game',       'streak',     'habit',      'norm', null);

    insert into achievements(org_id, code, name, ui_category, struct, motivation, rarity, trigger, requires_code)
    values (v_org, '_t_req', '測試前置', 'game', 'specific', 'completion', 'norm',
            '{"event":"_t_evt"}'::jsonb, '_t_spec');

    -- 累積型的兩級門檻：I=3、II=5
    insert into achievement_tiers(org_id, achievement_id, tier_level, tier_name, threshold)
    select v_org, id, 1, 'I', 3 from achievements where code='_t_cum' and org_id=v_org;
    insert into achievement_tiers(org_id, achievement_id, tier_level, tier_name, threshold)
    select v_org, id, 2, 'II', 5 from achievements where code='_t_cum' and org_id=v_org;

    -- ---------- ① 一次性解鎖 ＋ 重複 ----------
    v_r := public.ach_unlock_tx(v_member, '_t_spec', 'idem-1');
    v_msg := v_msg || case when (v_r->>'unlocked')::boolean
      then '✅ ① 一次性成就解鎖了' else '🔴 ① 解鎖失敗：' || v_r::text end;

    v_r := public.ach_unlock_tx(v_member, '_t_spec', 'idem-1');
    v_msg := v_msg || E'\n' || case when (v_r->>'already')::boolean
      then '✅ ① 再解一次回 already（不會重複）' else '🔴 ① 重複解鎖沒有被擋：' || v_r::text end;

    -- ---------- ② 累積跨級 ----------
    perform public.ach_progress_tx(v_member, '_t_cum', 1, 'p1');
    perform public.ach_progress_tx(v_member, '_t_cum', 1, 'p2');
    v_r := public.ach_progress_tx(v_member, '_t_cum', 1, 'p3');   -- 到 3 ⇒ 跨第 I 級
    v_msg := v_msg || E'\n' || case when (v_r->>'value')::int = 3 and (v_r->>'tier')::int = 1
      then '✅ ② 累積到 3 跨過第 I 級'
      else '🔴 ② 累積或分級不對：' || v_r::text end;

    v_r := public.ach_progress_tx(v_member, '_t_cum', 2, 'p4');   -- 到 5 ⇒ 最高級 ⇒ 解鎖
    v_msg := v_msg || E'\n' || case when (v_r->>'value')::int = 5 and (v_r->>'tier')::int = 2
      then '✅ ② 累積到 5 跨過第 II 級（最高級 ⇒ 自動解鎖）'
      else '🔴 ② 第二次累積不對：' || v_r::text end;

    -- ⚠ 一律用回傳值判斷，**不要 select into 累積訊息的那個變數** ——
    --   那會把前面的訊息整個覆寫掉，而症狀看起來像「測試沒跑」。

    -- ---------- ③ 🔴 冪等：同一把鑰匙再送一次 ----------
    v_r := public.ach_progress_tx(v_member, '_t_cum', 1, 'p4');
    v_msg := v_msg || E'\n' || case when (v_r->>'dedup')::boolean or (v_r->>'already')::boolean
      then '✅ ③ 同一個冪等鍵重送被擋下（設計稿漏掉的那個）'
      else '🔴 ③ 重送又加了一次：' || v_r::text end;

    -- ---------- ④ 連續型：同一個期間鍵去重 ----------
    v_r := public.ach_streak_tx(v_member, '_t_streak', '2026-09-20', true, null);
    v_msg := v_msg || E'\n' || case when (v_r->>'value')::int = 1
      then '✅ ④ 連續型第一天記到了' else '🔴 ④ 連續型失敗：' || v_r::text end;

    v_r := public.ach_streak_tx(v_member, '_t_streak', '2026-09-20', true, null);
    v_msg := v_msg || E'\n' || case when (v_r->>'dedup')::boolean
      then '✅ ④ 同一天重送被擋下' else '🔴 ④ 同一天被算了兩次：' || v_r::text end;

    -- ---------- ⑤⑥ fire_event_tx 端到端 ＋ 前置依賴 ----------
    -- _t_req 的前置是 _t_spec（① 已解鎖）⇒ 這次應該會被觸發
    v_r := public.fire_event_tx(v_member, '_t_evt', 1, null, 'evt-1');
    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_member and a.code = '_t_req' and ma.status = 'unlocked';
    v_msg := v_msg || E'\n' || case when v_n = 1
      then '✅ ⑤ 前置已解鎖 ⇒ requires_code 那枚被觸發了'
      else '🔴 ⑤ 前置成就沒有被觸發：' || v_r::text end;

    v_msg := v_msg || E'\n' || case when jsonb_array_length(v_r->'matched') >= 2
      then '✅ ⑥ 一個事件同時推進多枚（matched '
           || jsonb_array_length(v_r->'matched') || ' 枚）'
      else '🔴 ⑥ fire_event 只推進了 '
           || coalesce(jsonb_array_length(v_r->'matched'), 0) || ' 枚' end;

    -- ---------- ⑦ 展示櫃：只能 1 枚，而且是切換 ----------
    if v_line is null then
      v_msg := v_msg || E'\n' || '⚪ ⑦ 這個測試帳號沒有 line_user_id，展示櫃測不了';
    else
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_line, 'role', 'authenticated')::text, true);

      -- 先讓 _t_cum 也是 unlocked，才有兩枚可以釘
      update member_achievements set status = 'unlocked', unlocked_at = now()
       where member_id = v_member
         and achievement_id in (select id from achievements where code in ('_t_spec','_t_cum') and org_id = v_org);

      perform public.ach_pin_tx('_t_spec', true);
      v_r := public.ach_pin_tx('_t_cum', true);

      select count(*) into v_n from member_achievements
       where member_id = v_member and pinned;
      v_msg := v_msg || E'\n' || case when v_n = 1
        then '✅ ⑦ 釘第二枚時第一枚自動取消（同時只有 1 枚）'
        else '🔴 ⑦ 現在釘著 ' || v_n || ' 枚，應該只有 1' end;

      perform set_config('request.jwt.claims', '', true);
    end if;

    -- ---------- ⑧ 🔴 負對照：anon 不可以叫得動判定函式 ----------
    begin
      set local role anon;
      perform public.ach_unlock_tx(v_member, '_t_spec', null);
      reset role;
      v_msg := v_msg || E'\n' || '🔴 ⑧ anon 竟然叫得動 ach_unlock_tx —— 客人可以自己宣告解鎖';
    exception when insufficient_privilege then
      reset role;
      v_msg := v_msg || E'\n' || '✅ ⑧ anon 被正確拒絕（42501）';
    when others then
      reset role;
      v_msg := v_msg || E'\n' || '⚠ ⑧ 被擋下但錯誤碼是 ' || sqlstate;
    end;

    raise exception 'migi_rollback';

  exception when others then
    -- 🔴 訊息一定要在 handler 裡設（硬規則 3.9：set_config 會被 savepoint 回滾）
    if sqlerrm = 'migi_rollback' then
      perform set_config('migi.verify', v_msg || E'\n\n🧹 樣本已全部回滾。', true);
    else
      perform set_config('migi.verify',
        v_msg || E'\n\n🔴 意外中斷：' || sqlstate || ' ' || sqlerrm, true);
    end if;
  end;
end $$;

select coalesce(nullif(current_setting('migi.verify', true), ''), '🔴 沒有驗證訊息') as "行為測試";
