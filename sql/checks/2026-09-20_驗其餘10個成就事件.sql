-- ============================================================
-- 驗那 10 個事件真的會發 —— 造兩個新會員測行為，最後整個回滾
-- 2026-09-20　前置：`sql/pending/2026-09-20_其餘10個成就事件.sql` 已執行
--
-- 🔴 與那一份分家的理由（硬規則 1.8）：
--   那一份要**留下**觸發器 ⇒ 一個字都不准 raise
--   這一份要**造會員** ⇒ 只能 raise 回滾（沒有 staging，硬規則 5.7）
--
-- ⚠ 這份會真的寫 members / wallets / snack_grants / teams / team_members /
--   member_likes / mahjong_buddies / member_achievements，
--   **全部靠最外層那個 raise 回滾**。可以重複跑。
-- 🎯 刻意造**全新的會員**而不是借既有的 —— 既有那 5 個早就有段位、
--   有牌咖，借來測「第一次」會分不出「觸發了」與「本來就有」（硬規則 3.57）。
-- ============================================================

do $$
declare
  v_msg   text := '';
  v_org   uuid;
  v_a     uuid;   -- 會員 A：建團的人、按讚的人
  v_b     uuid;   -- 會員 B：入團的人、被按讚的人
  v_rank  text;
  v_team  uuid;
  v_n     int;
  v_n2    int;
begin
  begin
    select id into v_org from orgs where deleted_at is null limit 1;
    -- 🔴 段位值從現有資料抄，不要自己打一個（硬規則 3：不猜約束值）
    select rank into v_rank from members where rank is not null and deleted_at is null limit 1;

    if v_org is null or v_rank is null then
      v_msg := '⚪ 找不到 org 或現成的段位值，整份測不了';
      raise exception 'migi_rollback';
    end if;

    -- ---------- 造兩個全新會員（這一步本身就是 ①② 的測試） ----------
    /* 🔴 暱稱不可以隨便取（2026-09-20 第一版整份炸在這裡，23514）：
         members_display_name_chk CHECK (
           display_name = migi_norm_nickname(display_name)   ← 要等於正規化後的自己
           AND char_length 介於 1 與 12                      ← 🔴 第一版 14 字
           AND display_name !~* '(migi|官方|客服|店長|管理員|系統|admin)')
       ⚠ 同硬規則 3.8：錯誤訊息只給約束**名字**不給定義。
       ✅ `成就甲` ＋ md5 前 4 碼 ＝ 7 字，而小寫英數不會被正規化動到（實測）。
       📌 前綴刻意保留中文可辨識性 —— 萬一回滾失敗，看名字就知道是這份造的。 */
    insert into members (org_id, display_name, is_test)
    values (v_org, '成就甲' || substr(md5(random()::text), 1, 4), true)
    returning id into v_a;
    insert into members (org_id, display_name, is_test)
    values (v_org, '成就乙' || substr(md5(random()::text), 1, 4), true)
    returning id into v_b;

    -- ---------- ① member_registered ----------
    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id in (v_a, v_b) and a.code = 'onboarding_01'
       and ma.status = 'unlocked';
    v_msg := case when v_n = 2
      then '✅ ① 兩個新會員都拿到「新手報到」'
      else '🔴 ① 只有 ' || v_n || ' 人拿到，應為 2 —— members 的 AFTER INSERT 沒生效' end;

    -- ---------- ② title_granted（與註冊同一時刻） ----------
    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id in (v_a, v_b) and a.code = 'onboarding_13'
       and ma.status = 'unlocked';
    v_msg := v_msg || E'\n' || case when v_n = 2
      then '✅ ② 兩個人也都拿到「第一個稱號」（稱號是註冊預設就有）'
      else '🔴 ② 只有 ' || v_n || ' 人拿到，應為 2' end;

    -- ---------- ③ 🔴 負對照先跑：還沒有段位，26 不可以解鎖 ----------
    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_a and a.code = 'onboarding_26' and ma.status = 'unlocked';
    v_msg := v_msg || E'\n' || case when v_n = 0
      then '✅ ③ 新會員 rank 還是 null，「取得正式段位」沒有被誤開'
      else '🔴 ③ 還沒打過牌就拿到段位成就了' end;

    -- ---------- ④ rank_placed：null → 有值 ----------
    update members set rank = v_rank where id = v_a;
    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_a and a.code = 'onboarding_26' and ma.status = 'unlocked';
    v_msg := v_msg || E'\n' || case when v_n = 1
      then '✅ ④ rank 從 null 變成「' || v_rank || '」→ 解鎖「取得正式段位」'
      else '🔴 ④ 段位寫進去了卻沒解鎖 —— WHEN 條件或 UPDATE OF 欄位寫錯' end;

    -- ---------- ⑤ 🔴 負對照：只有 A 被改，B 不可以跟著拿到 ----------
    -- ⚠ 「升等不重發」這件事在這裡測不出來：specific 本來就冪等，
    --   而 WHEN (old.rank is null) 也已經擋掉第二次 —— 兩層防線的結果一樣，
    --   所以測它只會得到一個**永遠會綠的格子**。改測範圍。
    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_b and a.code = 'onboarding_26' and ma.status = 'unlocked';
    v_msg := v_msg || E'\n' || case when v_n = 0
      then '✅ ⑤ 沒有段位的 B 沒被波及（A 改段位不會誤發給別人）'
      else '🔴 ⑤ B 也拿到段位成就了' end;

    -- ---------- ⑥ 🔴 負對照：還沒發點心，17 不可以有 ----------
    insert into snack_grants (org_id, member_id, kind, qty, reason, idem_key)
    values (v_org, v_a, 'cookie', 1, 'admin', '_ach_' || gen_random_uuid()::text);

    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_a and a.code = 'onboarding_16' and ma.status = 'unlocked';
    select count(*) into v_n2 from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_a and a.code = 'onboarding_17' and ma.status = 'unlocked';
    v_msg := v_msg || E'\n' || case when v_n = 1 and v_n2 = 0
      then '✅ ⑥ qty > 0 只解鎖「第一個點心」，沒有連「餵一次小熊」一起開'
      else '🔴 ⑥ 得到=' || v_n || ' 餵食=' || v_n2 || '，應為 1 / 0 —— 正負號沒有在分' end;

    -- ---------- ⑦ snack_consumed：qty < 0 ----------
    insert into snack_grants (org_id, member_id, kind, qty, reason, idem_key)
    values (v_org, v_a, 'cookie', -1, 'feed', '_ach_' || gen_random_uuid()::text);

    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_a and a.code = 'onboarding_17' and ma.status = 'unlocked';
    v_msg := v_msg || E'\n' || case when v_n = 1
      then '✅ ⑦ qty < 0 解鎖「餵一次小熊」'
      else '🔴 ⑦ 扣點心沒有解鎖餵食成就' end;

    -- ---------- ⑧ team_created，而且 🔴 建團的人不可以同時拿到「團員報到」 ----------
    -- 🎯 這是整份最重要的一格：`create_team_tx` 會把團長自己也插進 team_members
    -- ⚠ teams_name_len_check：btrim 後 2–20 字（**沒有**正規化約束，與 members 不同）
    insert into teams (org_id, name, created_by)
    values (v_org, '成就團' || substr(md5(random()::text), 1, 4), v_a)
    returning id into v_team;
    insert into team_members (org_id, team_id, member_id, role)
    values (v_org, v_team, v_a, 'leader');

    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_a and a.code = 'onboarding_21' and ma.status = 'unlocked';
    select count(*) into v_n2 from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_a and a.code = 'onboarding_22' and ma.status = 'unlocked';
    v_msg := v_msg || E'\n' || case when v_n = 1 and v_n2 = 0
      then '✅ ⑧ 建團拿到「建立牌咖團」，而**沒有**同時拿到「團員報到」'
      else '🔴 ⑧ 建團=' || v_n || ' 入團=' || v_n2 || '，應為 1 / 0 —— leader 沒被排除' end;

    -- ---------- ⑨ team_joined：真的入團的人 ----------
    insert into team_members (org_id, team_id, member_id)   -- role 吃預設 'member'
    values (v_org, v_team, v_b);

    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_b and a.code = 'onboarding_22' and ma.status = 'unlocked';
    select count(*) into v_n2 from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_a and a.code = 'onboarding_22' and ma.status = 'unlocked';
    v_msg := v_msg || E'\n' || case when v_n = 1 and v_n2 = 0
      then '✅ ⑨ B 入團拿到「團員報到」，而團長 A 仍然沒有（正負對照同時成立）'
      else '🔴 ⑨ B=' || v_n || ' A=' || v_n2 || '，應為 1 / 0' end;

    -- ---------- ⑩ 🔴 一列兩個事件，而且對象不可以搞反 ----------
    insert into member_likes (org_id, liker_id, target_id)
    values (v_org, v_a, v_b);

    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_a and a.code = 'onboarding_23' and ma.status = 'unlocked';
    select count(*) into v_n2 from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_b and a.code = 'onboarding_24' and ma.status = 'unlocked';
    v_msg := v_msg || E'\n' || case when v_n = 1 and v_n2 = 1
      then '✅ ⑩ 按讚的 A 拿到「送出」、被按的 B 拿到「收到」'
      else '🔴 ⑩ A送出=' || v_n || ' B收到=' || v_n2 || '，應為 1 / 1' end;

    -- ---------- ⑪ 🔴 交叉負對照：不可以兩枚都記在同一個人身上 ----------
    -- 照抄 like_given 那一行去寫 like_received 的話，這一格會變紅
    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_a and a.code = 'onboarding_24' and ma.status = 'unlocked';
    select count(*) into v_n2 from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id = v_b and a.code = 'onboarding_23' and ma.status = 'unlocked';
    v_msg := v_msg || E'\n' || case when v_n = 0 and v_n2 = 0
      then '✅ ⑪ A 沒有「收到讚」、B 沒有「送出讚」—— 對象沒有寫反'
      else '🔴 ⑪ A收到=' || v_n || ' B送出=' || v_n2 || '，應為 0 / 0' end;

    -- ---------- ⑫ buddy_added：雙向兩列 → 兩個人各一次 ----------
    insert into mahjong_buddies (org_id, member_id, buddy_id, origin)
    values (v_org, v_a, v_b, 'matched'),
           (v_org, v_b, v_a, 'matched');

    select count(distinct ma.member_id) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id in (v_a, v_b) and a.code = 'onboarding_25'
       and ma.status = 'unlocked';
    v_msg := v_msg || E'\n' || case when v_n = 2
      then '✅ ⑫ 牌咖雙向兩列 → 兩個人都拿到「第一個牌咖」'
      else '🔴 ⑫ 只有 ' || v_n || ' 人拿到，應為 2 —— 只對 member_id 發不夠？' end;

    -- ---------- ⑬ 🔴 meta 不可以被誤開 ----------
    -- A 這一輪最多解 8 枚，門檻是 15
    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id in (v_a, v_b) and a.code = 'onboarding_29'
       and ma.status = 'unlocked';
    select count(*) into v_n2 from member_achievements ma
     where ma.member_id = v_a and ma.status = 'unlocked';
    v_msg := v_msg || E'\n' || case when v_n = 0
      then '✅ ⑬ 新手畢業沒有被誤開（A 這一輪解了 ' || v_n2 || ' 枚，門檻 15）'
      else '🔴 ⑬ 新手畢業被開了 ' || v_n || ' 人 —— meta 門檻失效' end;

    -- ---------- ⑭ 🔴 C 區 31 枚一枚都不可以動 ----------
    select count(*) into v_n from member_achievements ma
      join achievements a on a.id = ma.achievement_id
     where ma.member_id in (v_a, v_b) and a.code like 'tile\_%' and ma.status <> 'locked';
    v_msg := v_msg || E'\n' || case when v_n = 0
      then '✅ ⑭ C 區 31 枚（is_active=false）一枚都沒被碰到'
      else '🔴 ⑭ 有 ' || v_n || ' 枚牌型成就動了' end;

    raise exception 'migi_rollback';

  exception when others then
    -- 🔴 訊息一定要在 handler 裡設（硬規則 3.9）
    if sqlerrm = 'migi_rollback' then
      perform set_config('migi.verify', v_msg || E'\n\n🧹 兩個測試會員與所有樣本已全部回滾。', true);
    else
      perform set_config('migi.verify',
        v_msg || E'\n\n🔴 意外中斷：' || sqlstate || ' ' || sqlerrm, true);
    end if;
  end;
end $$;

select coalesce(nullif(current_setting('migi.verify', true), ''), '🔴 沒有驗證訊息') as "行為測試";
