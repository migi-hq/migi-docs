-- ============================================================
-- 驗 `ach_meta_tx` 真的會動 —— 造樣本測行為，最後整個回滾
-- 2026-09-20　前置：`sql/applied/2026-09-20_成就meta判定.sql` 已執行
--
-- 🔴 為什麼與那一份分家（硬規則 1.8）：
--   那一份要**留下**函式 ⇒ 一個字都不准 raise
--   這一份要**造樣本** ⇒ 只能 raise 回滾（沒有 staging，硬規則 5.7）
--
-- ⚠ 這份不留下任何東西，可以重複跑。測試成就一律 `_m_` 前綴，
--   萬一回滾失敗也認得出來。
-- ============================================================

do $$
declare
  v_msg    text := '';
  v_org    uuid;
  v_member uuid;
  v_r      jsonb;
  v_n      int;
begin
  begin
    -- ---------- 造樣本 ----------
    select m.id, m.org_id into v_member, v_org
      from members m
     where m.is_test and m.deleted_at is null
     order by m.created_at limit 1;

    if v_member is null then
      v_msg := '⚪ 找不到測試會員，整份測不了';
      raise exception 'migi_rollback';
    end if;

    -- 三枚「真的」成就，同一個 ui_category
    insert into achievements(org_id, code, name, ui_category, struct, motivation, rarity, trigger)
    values (v_org, '_m_a', '真成就 A', 'game', 'specific', 'completion', 'norm', '{"event":"_m_evt"}'::jsonb),
           (v_org, '_m_b', '真成就 B', 'game', 'specific', 'completion', 'norm', '{"event":"_m_evt"}'::jsonb),
           (v_org, '_m_c', '真成就 C', 'game', 'specific', 'completion', 'norm', '{"event":"_m_evt"}'::jsonb);

    -- meta：解鎖 3 枚 game 類
    insert into achievements(org_id, code, name, ui_category, struct, motivation, rarity, trigger)
    values (v_org, '_m_meta3', 'META 三枚', 'game', 'specific', 'completion', 'rare',
            '{"event":"achievement_unlocked","scope":"ui_category","value":"game","count":3}'::jsonb);

    -- meta：解鎖 4 枚 game 類 —— 🔴 用來驗「meta 不計入 meta」
    insert into achievements(org_id, code, name, ui_category, struct, motivation, rarity, trigger)
    values (v_org, '_m_meta4', 'META 四枚', 'game', 'specific', 'completion', 'epic',
            '{"event":"achievement_unlocked","scope":"ui_category","value":"game","count":4}'::jsonb);

    -- meta：scope 打錯字 —— 必須被跳過而且報出來，**不可以算全部**
    insert into achievements(org_id, code, name, ui_category, struct, motivation, rarity, trigger)
    values (v_org, '_m_bad', 'META 壞的', 'game', 'specific', 'completion', 'norm',
            '{"event":"achievement_unlocked","scope":"categoryyy","value":"game","count":1}'::jsonb);

    -- ---------- ① 還沒達標時不可以解鎖 ----------
    perform public.ach_unlock_tx(v_member, '_m_a', 'm1');
    perform public.ach_unlock_tx(v_member, '_m_b', 'm2');   -- 只有 2 枚
    v_r := public.ach_meta_tx(v_member, 'chk');
    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_member and a.code = '_m_meta3' and ma.status = 'unlocked';
    v_msg := v_msg || case when v_n = 0
      then '✅ ① 只解 2 枚時，門檻 3 的 meta 沒有被解鎖'
      else '🔴 ① 還沒達標就解鎖了 —— 門檻沒有在擋' end;

    -- ---------- ② 達標就解鎖 ----------
    perform public.ach_unlock_tx(v_member, '_m_c', 'm3');   -- 湊到 3 枚
    v_r := public.ach_meta_tx(v_member, 'chk2');
    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_member and a.code = '_m_meta3' and ma.status = 'unlocked';
    v_msg := v_msg || E'\n' || case when v_n = 1
      then '✅ ② 解到 3 枚，門檻 3 的 meta 解鎖了'
      else '🔴 ② 達標卻沒解鎖：' || v_r::text end;

    -- ---------- ③ 🔴 meta 不計入 meta ----------
    -- 現在已解鎖：真 A/B/C（3 枚）＋ meta3（1 枚）= 資料上 4 列
    -- 若 meta 也算進去，門檻 4 的 _m_meta4 會被誤開 —— 那正是要擋的
    v_r := public.ach_meta_tx(v_member, 'chk3');
    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_member and a.code = '_m_meta4' and ma.status = 'unlocked';
    v_msg := v_msg || E'\n' || case when v_n = 0
      then '✅ ③ meta 不計入 meta（3 真 ＋ 1 meta 沒有湊成 4）'
      else '🔴 ③ meta 被算進去了 —— 那個名字會說謊（14 真 ＋ 1 meta = 15）' end;

    -- ---------- ④ scope 打錯字：跳過 ＋ 報出來 ----------
    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_member and a.code = '_m_bad' and ma.status = 'unlocked';
    v_msg := v_msg || E'\n' || case when v_n = 0
      then '✅ ④ scope 打錯字的那一枚沒有被解鎖（沒有 fallback 成算全部）'
      else '🔴 ④ 壞 trigger 竟然解鎖了 —— 門檻 1 配上「算全部」會當場開' end;
    v_msg := v_msg || E'\n' || case
      when v_r->'skipped' @> '[{"reason":"bad_trigger"}]'::jsonb
      then '✅ ④ 而且它出現在回傳的 skipped 裡（壞匯入看得見）'
      else '🔴 ④ 它被安靜跳過了 —— 壞掉的 trigger 不會有人發現' end;

    -- ---------- ⑤ 冪等：重跑不會變 ----------
    v_r := public.ach_meta_tx(v_member, 'chk4');
    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_member and a.code like '\_m\_meta%' and ma.status = 'unlocked';
    v_msg := v_msg || E'\n' || case when v_n = 1
      then '✅ ⑤ 重跑一次，解鎖的 meta 還是 1 枚（天生冪等）'
      else '🔴 ⑤ 重跑之後變成 ' || v_n || ' 枚' end;

    -- ---------- ⑥ 🔴 fire_event_tx 不可以把 meta 免費開掉 ----------
    -- 這是整份最重要的一格：守衛少了的話，一次事件就把所有 meta 全開
    v_r := public.fire_event_tx(v_member, 'achievement_unlocked', 1, null, 'chk5');
    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_member and a.code = '_m_meta4' and ma.status = 'unlocked';
    v_msg := v_msg || E'\n' || case when v_n = 0
      then '✅ ⑥ fire_event_tx 發 achievement_unlocked 也開不了未達標的 meta'
      else '🔴 ⑥ 被免費開掉了 —— fire_event_tx 的守衛沒生效' end;

    -- ---------- ⑦ 負對照：一般成就照樣被 fire_event_tx 推進 ----------
    -- 只驗「meta 被擋住」的話，一個什麼都不做的 fire_event_tx 也會全綠
    insert into achievements(org_id, code, name, ui_category, struct, motivation, rarity, trigger)
    values (v_org, '_m_plain', '一般成就', 'game', 'specific', 'completion', 'norm',
            '{"event":"_m_evt2"}'::jsonb);
    v_r := public.fire_event_tx(v_member, '_m_evt2', 1, null, 'chk6');
    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_member and a.code = '_m_plain' and ma.status = 'unlocked';
    v_msg := v_msg || E'\n' || case when v_n = 1
      then '✅ ⑦ 一般成就照樣被推進（守衛沒有誤擋）'
      else '🔴 ⑦ 連一般成就都不動了 —— 守衛管太寬：' || v_r::text end;

    -- ---------- ⑧ 端到端：fire_event 之後 meta 自己會補上 ----------
    -- _m_plain 讓 game 類達到 4 枚真成就 ⇒ _m_meta4 應該在同一次呼叫裡解鎖
    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_member and a.code = '_m_meta4' and ma.status = 'unlocked';
    v_msg := v_msg || E'\n' || case when v_n = 1
      then '✅ ⑧ 端到端：fire_event_tx 收尾對帳，門檻 4 的 meta 自己補上了'
      else '🔴 ⑧ 湊滿 4 枚真成就，meta 卻沒有跟上：' || (v_r->'meta')::text end;

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
