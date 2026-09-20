-- ============================================================
-- 成就匯入 · 階段 1：A 新手引導 29 ＋ C 牌型收藏 31 ＝ **60 枚**
-- 2026-09-20　使用者指定「先上新手成就跟牌型的」
--
-- 📄 清單 `docs/03-會員App與社交/成就系統企劃.md` A 區與 C 區
-- 📄 事件 `docs/03-會員App與社交/成就事件清單.md`
-- 📄 引擎 `sql/applied/2026-09-20_成就系統核心RPC.sql` ＋ `…_成就meta判定.sql`
--
-- ============================================================
-- 🔴 讀之前先知道三件事
-- ============================================================
--
-- ### ① `is_active = true` 的只有 **18 枚**，全部在 A 區
-- 照企劃自己的規則：「功能還沒做的先建進主檔但 `is_active = false`
--   —— **一個永遠解不開的成就比沒有那枚更糟**。」
-- ```
-- A 新手引導 29 → active 18
--    ❌ 4  電子計分（首次胡牌／首次自摸／第一次牌型／第一次連莊）
--    ❌ 4  階段 4 的功能（打卡／抽獎／每週任務／每日報到）
--    ❌ 3  機制不存在（頭像框／小熊配件／優惠券）← 掃全庫函式確認，見 ③
-- C 牌型收藏 31 → active 0   ← 見 ②
-- ```
--
-- ### ② 🎯 C 區全 false，但現在匯入的價值不在「上架」，在**契約**
-- 電子計分有兩層，而 C 區要的是第二層：
-- ```
-- ① 只記台數  「這局 8 台」          ⇒ C 區不成立
-- ② 記到牌型  「碰碰胡 4 ＋ 門清 1」  ⇒ C 區成立   ← 要 hands.patterns
-- ```
-- 而 `hands` 表還沒建。
-- ⇒ **這 31 個 `pattern_*` 事件名就是記分板要存的牌型字彙** ——
--   寫在記分板之前而不是之後，它才知道要記什麼。
--   企劃那句「**事後補不回來**（歷史牌局沒記就是沒記）」講的就是這個。
--
-- ### ③ 🔴 trigger 一個牌型一個事件名，**不可以共用 `hand_pattern`**
-- `fire_event_tx` **只比對 `trigger->>'event'`**，其餘的鍵它看都不看。
-- ```
-- ❌ {"event":"hand_pattern","pattern":"menqing"}
--    ⇒ 任何一次 hand_pattern 事件會把 31 枚**全開**（跟 meta 那個洞一樣）
-- ✅ {"event":"pattern_menqing"}
--    ⇒ 條件判斷留在發射端，**事件名就是條件**
-- ```
--
-- ============================================================
-- ⚠ 這一批不需要任何 `achievement_tiers` —— A 與 C **全部是 specific、零累積**。
-- ⚠ 冪等：`uq_ach_code (org_id, code) where deleted_at is null` 是部分唯一索引，
--   所以 `on conflict` 要帶同一個 WHERE 才推論得到它。重跑這份不會長出第二批。
-- ⚠ 這份要留下資料 ⇒ 驗證段一個字都不准 raise（硬規則 1.8）。
-- ============================================================


insert into achievements (
  org_id, code, name, description, condition_text,
  group_key, ui_category, struct, motivation, rarity, visibility,
  trigger, is_active, sort)
select o.id, v.code, v.name, v.descr, v.cond,
       -- 🔴 `ui_category` 是 NOT NULL ⇒ 必須在 INSERT 當下就給，
       --    不能先插進去再 UPDATE 補（那樣整批會被 NOT NULL 擋下來）。
       case when v.code like 'tile\_%' then '牌型收藏' else '新手引導' end,
       case when v.code like 'tile\_%' then 'game'     else 'onboarding' end,
       'specific', v.motiv, v.rarity, v.vis,
       jsonb_build_object('event', v.evt), v.act, v.sort
  from orgs o
 cross join (values
 -- ── A. 新手引導　29 枚（全部 specific、零累積）────────────────
 -- code            名稱          客人看到的說明                    解鎖條件
 ('onboarding_01','新手報到','歡迎加入 MIGI 的第一天','完成會員註冊',                    'completion','norm','visible','member_registered',     true , 1),
 ('onboarding_02','第一次開桌','你的第一場 MIGI 牌局','完成第一場牌局',                  'completion','norm','visible','session_finished',      true , 2),
 ('onboarding_03','首次胡牌','第一個漂亮胡牌時刻','第一次胡牌成功',                      'prestige','norm','visible','hand_won',                false, 3),
 ('onboarding_04','首次自摸','好運自己來','第一次自摸成功',                              'prestige','norm','visible','hand_tsumo',              false, 4),
 ('onboarding_05','第一次牌型','你第一次打出有記錄的牌型','第一次胡出可計台的牌型',      'exploration','norm','visible','hand_pattern_any',    false, 5),
 ('onboarding_06','第一杯飲料','打牌前先來一杯','第一次點任一飲品',                      'collection','norm','visible','fnb_drink',             true , 6),
 ('onboarding_07','第一份餐點','第一次吃 MIGI 的味道','第一次點主食／炸物／零嘴',        'collection','norm','visible','fnb_meal',              true , 7),
 ('onboarding_08','第一次打卡','留下你的 MIGI 瞬間','第一次到店留影',                    'social','norm','visible','photo_taken',               false, 8),
 ('onboarding_09','第一次參與配桌','系統幫你湊到一桌了','第一次透過配桌成桌並完成牌局',  'social','norm','visible','queue_session_done',       true , 9),
 ('onboarding_10','第一次預約包桌','你訂的桌，大家坐下來了','第一次預約包桌並完成牌局',  'social','norm','visible','booking_session_done',     true ,10),
 ('onboarding_11','第一次連莊','手氣開始延續了','第一次完成連莊',                        'prestige','norm','visible','renzhuang',               false,11),
 ('onboarding_12','第一次贏得牌局','第一場勝利值得紀念','第一次桌上積分為正',            'prestige','norm','visible','session_won',              true ,12),
 ('onboarding_13','第一個稱號','你有自己的 MIGI 身分了','第一次獲得稱號',                'prestige','norm','visible','title_granted',            true ,13),
 ('onboarding_14','第一個頭像框','個人頁也變可愛了','第一次獲得頭像框',                  'expression','norm','visible','frame_granted',          false,14),
 ('onboarding_15','第一個配件','小熊有新衣服了','第一次獲得小熊配件',                    'collection','norm','visible','bear_item_granted',      false,15),
 ('onboarding_16','第一個點心','點心櫃裡有東西了','第一次獲得任一點心',                  'collection','norm','visible','snack_granted',           true ,16),
 ('onboarding_17','餵一次小熊','牠好像更有精神了','第一次餵食小熊',                      'completion','norm','visible','snack_consumed',          true ,17),
 ('onboarding_18','抽一次牌','試試今天的手氣','第一次參加抽獎',                          'exploration','norm','visible','gacha_draw',            false,18),
 ('onboarding_19','第一個每週任務','這週的目標完成了','第一次完成任一每週任務',          'completion','norm','visible','weekly_quest',           false,19),
 ('onboarding_20','第一次報到','明天也要記得來','第一次完成每日報到',                    'completion','norm','visible','daily_checkin',          false,20),
 ('onboarding_21','建立牌咖團','這是你的地盤','第一次建立牌咖團',                        'social','norm','visible','team_created',               true ,21),
 ('onboarding_22','團員報到','找到一起打牌的人了','第一次加入牌咖團',                    'social','norm','visible','team_joined',                true ,22),
 ('onboarding_23','送出第一個讚','好牌品值得被看見','第一次給同桌玩家讚',                'social','norm','visible','like_given',                 true ,23),
 ('onboarding_24','收到第一個讚','有人覺得你很好相處','第一次獲得同桌玩家的讚',          'social','norm','visible','like_received',              true ,24),
 ('onboarding_25','第一個牌咖','下次還要一起打','第一次成功加一位牌咖',                  'social','norm','visible','buddy_added',                true ,25),
 ('onboarding_26','取得正式段位','系統知道你的實力了','完成定位賽並取得銅牌熊',          'completion','norm','visible','rank_placed',            true ,26),
 ('onboarding_27','第一張優惠券','下次結帳會有點不一樣','第一次獲得優惠券',              'consumption','norm','visible','coupon_granted',        false,27),
 ('onboarding_28','第一次儲值','錢包有底氣了','第一次完成儲值',                          'consumption','norm','visible','topup',                  true ,28),

 -- ── C. 牌型收藏　31 枚（全部 specific；一個牌型一個事件名）──────
 ('tile_01','門清','不吃不碰，自己走完','第一次門清胡牌',                  'prestige','norm','visible','pattern_menqing',          false,57),
 ('tile_02','門清自摸','自己做完，自己摸到','第一次門清自摸',              'prestige','rare','visible','pattern_menqing_tsumo',    false,58),
 ('tile_03','平胡','最基本，也最漂亮','第一次胡出平胡',                    'collection','norm','visible','pattern_pinghu',         false,59),
 ('tile_04','讀聽','只等那一張','第一次讀聽胡牌',                          'prestige','norm','visible','pattern_duting',           false,60),
 ('tile_05','全求人','全靠大家成全','第一次全求人胡牌',                    'story','norm','visible','pattern_quanqiuren',          false,61),
 ('tile_06','三個紅中','紅中都在你手上','胡牌時持有紅中刻',                'collection','norm','visible','pattern_triplet_red',     false,62),
 ('tile_07','三個發財','發財來了','胡牌時持有發財刻',                      'collection','norm','visible','pattern_triplet_green',   false,63),
 ('tile_08','三個白板','白板也是好牌','胡牌時持有白板刻',                  'collection','norm','visible','pattern_triplet_white',   false,64),
 ('tile_09','三個東風','東風在手','胡牌時持有東風刻',                      'collection','norm','visible','pattern_triplet_east',    false,65),
 ('tile_10','三個南風','南風也收齊了','胡牌時持有南風刻',                  'collection','norm','visible','pattern_triplet_south',   false,66),
 ('tile_11','三個西風','西風湊成一組','胡牌時持有西風刻',                  'collection','norm','visible','pattern_triplet_west',    false,67),
 ('tile_12','三個北風','四方風都有了','胡牌時持有北風刻',                  'collection','norm','visible','pattern_triplet_north',   false,68),
 ('tile_13','小三元','三元牌差一步','第一次胡出小三元',                    'prestige','rare','visible','pattern_xiaosanyuan',       false,69),
 ('tile_14','大三元','中發白全到齊','第一次胡出大三元',                    'prestige','epic','visible','pattern_dasanyuan',         false,70),
 ('tile_15','小四喜','四風差一張','第一次胡出小四喜',                      'prestige','epic','visible','pattern_xiaosixi',          false,71),
 ('tile_16','大四喜','東南西北全員到齊','第一次胡出大四喜',                'prestige','epic','silhouette','pattern_dasixi',         false,72),
 ('tile_17','字一色','整副都是字牌','第一次胡出字一色',                    'prestige','epic','silhouette','pattern_ziyise',         false,73),
 ('tile_18','第一個混一色','一種花色加字牌','第一次胡出混一色',            'collection','rare','visible','pattern_hunyise',         false,74),
 ('tile_19','第一個清一色','整副同一種花色','第一次胡出清一色',            'prestige','epic','visible','pattern_qingyise',          false,75),
 ('tile_20','第一個碰碰胡','今天的牌型很有個性','第一次胡出碰碰胡',        'collection','rare','visible','pattern_pengpenghu',      false,76),
 ('tile_21','三暗刻','三組都是自己摸的','第一次胡出三暗刻',                'prestige','norm','visible','pattern_sananke',           false,77),
 ('tile_22','四暗刻','四組暗刻在手','第一次胡出四暗刻',                    'prestige','rare','visible','pattern_sianke',            false,78),
 ('tile_23','五暗刻','整副都是自己摸來的','第一次胡出五暗刻',              'prestige','epic','visible','pattern_wuanke',            false,79),
 ('tile_24','海底撈月','最後一張是你的','第一次海底撈月',                  'story','norm','visible','pattern_haidi',                false,80),
 ('tile_25','槓上開花','槓完就胡了','第一次槓上開花',                      'story','norm','visible','pattern_gangshang',            false,81),
 ('tile_26','搶槓胡','從別人的槓裡搶下來','第一次搶槓胡',                  'competition','norm','visible','pattern_qianggang',      false,82),
 ('tile_27','正花','你的花剛好對上','第一次胡牌含正花',                    'collection','rare','visible','pattern_zhenghua',         false,83),
 ('tile_28','花槓','一門花全收','第一次胡出花槓',                          'collection','rare','visible','pattern_huagang',          false,84),
 ('tile_29','七搶一','只差一張花','第一次七搶一',                          'story','rare','visible','pattern_qiqiangyi',            false,85),
 ('tile_30','八仙過海','花牌滿手','第一次八仙過海',                        'collection','epic','visible','pattern_baxian',           false,86),
 ('tile_31','天胡','莊家起手就胡了','第一次天胡',                          'prestige','epic','silhouette','pattern_tianhu',         false,87)
 ) as v(code, name, descr, cond, motiv, rarity, vis, evt, act, sort)
 where o.deleted_at is null
 on conflict (org_id, code) where deleted_at is null do nothing;


-- 🔴 29「新手畢業」是 meta，trigger 的形狀跟上面 59 枚不同（帶 count），
--   所以單獨一筆 —— 混進上面那個 VALUES 會讓整批的欄位型別對不齊。
-- ⚠ 它要「解鎖 15 個新手成就」，而 A 區 active 只有 18 枚 ⇒ 達得到但很緊。
--   **日後把 A 區任何一枚關掉之前，先回來看這個數字。**
insert into achievements (
  org_id, code, name, description, condition_text,
  group_key, ui_category, struct, motivation, rarity, visibility,
  trigger, is_active, sort)
select o.id, 'onboarding_29', '新手畢業', 'MIGI 你已經很熟了', '解鎖 15 個新手成就',
       '新手引導', 'onboarding', 'specific', 'completion', 'rare', 'visible',
       '{"event":"achievement_unlocked","scope":"group_key","value":"新手引導","count":15}'::jsonb,
       true, 29
  from orgs o where o.deleted_at is null
 on conflict (org_id, code) where deleted_at is null do nothing;

-- ⚠ 分類在 INSERT 當下就給了（見上面那兩個 CASE），這裡**不需要**再 UPDATE 一次。
--   驗證段第 ⑥ 格會把結果查出來確認。


-- ============================================================
-- 驗證
-- ============================================================
do $$
declare
  v_msg text := '';
  v_n   int;
  v_n2  int;
  v_txt text;
begin
  -- ① 總數：算式寫出來，不要憑印象（硬規則 3.56）
  --    29（A 區，含新手畢業）＋ 31（C 區）= 60
  select count(*) into v_n from achievements
   where deleted_at is null and (code like 'onboarding\_%' or code like 'tile\_%');
  v_msg := case when v_n = 60
    then '✅ ① 共 60 枚（A 29 ＋ C 31）'
    else '🔴 ① 共 ' || v_n || ' 枚，應為 60（29 ＋ 31）' end;

  -- ② active 的只有 18 枚，而且**全部在 A 區**
  select count(*) filter (where code like 'onboarding\_%'),
         count(*) filter (where code like 'tile\_%')
    into v_n, v_n2
    from achievements where deleted_at is null and is_active
     and (code like 'onboarding\_%' or code like 'tile\_%');
  v_msg := v_msg || E'\n' || case when v_n = 18 and v_n2 = 0
    then '✅ ② active 18 枚，全部在 A 區；C 區 0 枚（hands 還沒建）'
    else '🔴 ② active：A 區 ' || v_n || ' 枚（應 18）／C 區 ' || v_n2 || ' 枚（應 0）' end;

  -- ③ 🔴 每一個 event 都是獨一無二的
  --    共用事件名的話，一次事件會把共用那批**全開**（同 meta 那個洞）
  select count(*) into v_n from (
    select trigger->>'event' e from achievements
     where deleted_at is null and (code like 'onboarding\_%' or code like 'tile\_%')
     group by 1 having count(*) > 1) d;
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ③ 60 個事件名沒有任何重複（不會一次全開）'
    else '🔴 ③ 有 ' || v_n || ' 個事件名被多枚共用 —— 那批會被一次全開' end;

  -- ④ 🔴 只有「新手畢業」是 meta（帶 count）
  --    多一枚帶 count 的就表示我把某個 trigger 寫錯成 meta 形狀
  select string_agg(code, '　' order by code) into v_txt
    from achievements
   where deleted_at is null and trigger ? 'count'
     and (code like 'onboarding\_%' or code like 'tile\_%');
  v_msg := v_msg || E'\n' || case when v_txt = 'onboarding_29'
    then '✅ ④ 帶 count 的只有 onboarding_29（新手畢業）'
    else '🔴 ④ 帶 count 的是：' || coalesce(v_txt, '⚪ 一枚都沒有 —— 新手畢業沒進去') end;

  -- ⑤ 負對照：沒有任何一枚落在 tiers（這一批全 specific、零累積）
  select count(*) into v_n from achievement_tiers t
    join achievements a on a.id = t.achievement_id
   where a.code like 'onboarding\_%' or a.code like 'tile\_%';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ⑤ 這一批沒有任何 tiers（A 與 C 全是 specific）'
    else '🔴 ⑤ 竟然有 ' || v_n || ' 筆 tiers —— 那表示 struct 寫錯了' end;

  -- ⑥ group_key / ui_category 都補齊了
  select count(*) into v_n from achievements
   where deleted_at is null
     and ((code like 'onboarding\_%' and (group_key <> '新手引導' or ui_category <> 'onboarding'))
       or (code like 'tile\_%'       and (group_key <> '牌型收藏' or ui_category <> 'game')));
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ⑥ group_key 與 ui_category 全部正確'
    else '🔴 ⑥ 有 ' || v_n || ' 枚的分類不對' end;

  -- ⑦ 🎯 端到端的一格：新手畢業的門檻達得到嗎
  --    15 ≤ A 區 active 枚數（含它自己）—— 這一格在盯「永遠解不開」那個形狀
  select count(*) into v_n from achievements
   where deleted_at is null and is_active and code like 'onboarding\_%'
     and not coalesce(trigger ? 'count', false);
  v_msg := v_msg || E'\n' || case when v_n >= 15
    then '✅ ⑦ 新手畢業門檻 15，而 A 區可解鎖的有 ' || v_n || ' 枚 —— 達得到'
    else '🔴 ⑦ A 區可解鎖只有 ' || v_n || ' 枚，門檻 15 **永遠解不開**' end;

  -- ⑧ 冪等：重跑不會長出第二批
  select count(*) into v_n from (
    select code from achievements where deleted_at is null
     group by code having count(*) > 1) d;
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ⑧ 沒有重複的 code（重跑這份不會長出第二批）'
    else '🔴 ⑧ 有 ' || v_n || ' 個 code 重複了' end;

  -- ⑨ 逐區印出來讓人判讀（不回是非題，硬規則 3.5）
  v_msg := v_msg || E'\n' || coalesce(
    (select string_agg(x, E'\n' order by x) from (
       select '　　' || grp || '：共 ' || count(*) || ' 枚，其中 active '
              || count(*) filter (where is_active) || ' 枚' as x
         from (select case when code like 'tile\_%' then 'C 牌型收藏'
                           else 'A 新手引導' end as grp, is_active
                 from achievements
                where deleted_at is null
                  and (code like 'onboarding\_%' or code like 'tile\_%')) s
        group by grp) t),
    '⚪ 取不到');   -- 字串 || NULL 會吃掉前面所有格（硬規則 3.555）

  perform set_config('migi.verify', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify', true), ''), '🔴 沒有驗證訊息') as "驗證";
