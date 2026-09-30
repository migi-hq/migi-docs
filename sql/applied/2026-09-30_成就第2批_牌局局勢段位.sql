/* ============================================================
   成就第 2 批：牌局 27 ＋ 局勢轉折 9 ＋ 段位 17 ＝ 53 枚（50 枚上架）
   2026-09-30 · MIGI 咪吉麻將
   來源：docs/03-會員App與社交/成就系統企劃.md 的 B／D／E 區

   ── 使用者 2026-09-30 拍板 ──────────────────────────────
   · 「守住正值」與「三將全正」條件一樣 ⇒ 前者改成「一路領先」（每一將結束都是第 1 名）
   · 講「第三將」的幾枚只算打滿 3 將的場（三將全正、第三將定勝負、最後一刻上車、大逆轉）
   · 「穩定輸出」＝每一將的得分都比上一將多
   · 賽季區（F）留到下一批；那一批要拿掉「名人堂」（與賽季雀神同一件事）

   ── 先建但不上架（is_active = false）──────────────────────
   · 爆卡、讓對手爆卡：企劃明寫要等電子計分定出「掉到多少算爆卡」
   · 整季不降階：要在賽季結算時判定，跟賽季區同一批

   ── 發射端（三個地方，全部「出錯不影響本來的動作」）──────────
   ① _ach_session_events(場次)：收桌時判定牌局、局勢轉折、同桌對象、單場大躍進
      由 settle_session_tx 在原本的成就事件之後呼叫；出錯寫 ach_error 埋點（錯誤儀表看得到）
   ② trg_members_rank_events：members.rank 每次寫入時判定同階升級、跨階、段位分門檻、回到巔峰
   ③ apply_session_rounds_tx：低段降階保護真的把段位分夾住時，發「保級成功」

   ── 刻意的判定細節 ─────────────────────────────────────
   · 純娛樂的 final_score 是 null ⇒ 積分類、局勢轉折類一律不算（現行規則，不是新決定）
   · 「大牌」＝牌型台數 ≥ 8（tai_pattern，不含莊家附加台）；胡牌只認 ron／tsumo（與既有 hand_won 同一個判準）
   · 放槍認 ron 與 bao；連莊不認 kala（與既有 renzhuang 事件同一個判準）
   · 連續類（三連正、連續首位、連場大牌）在發射端算歷史，所以引擎結構寫 specific ——
     引擎的 streak 只會往上加、不會因為一場沒達成而歸零
   · 段位分 300／600／900 是「達到那個分數」，不是累積 ⇒ 也是 specific
   · 名次同分時並列（1 ＋ 比我高的人數）

   行為測試：sql/checks/2026-09-30_驗成就第2批.sql（交易內收一場真的牌局、全部回滾）
   ============================================================ */

-- ① 主檔 53 枚（重跑不重複插）
insert into public.achievements
  (org_id, code, name, description, condition_text, group_key, ui_category,
   struct, motivation, rarity, visibility, trigger, sort, grants_title, is_active)
select o.org_id, v.code, v.name, v.description, v.condition_text, v.group_key, 'game',
       v.struct, v.motivation, v.rarity, v.visibility, v.trigger::jsonb, v.sort, v.grants_title, v.is_active
  from (select org_id from public.achievements where code = 'tile_32' and deleted_at is null limit 1) o
 cross join (values
  -- B 牌局
  ('game_01','牌局常客','一場一場累積起來的','累積完成牌局（I 10／II 50／III 100／IV 300）','牌局','cumulative','completion','norm','visible','{"event":"session_finished"}',30,null,true),
  ('game_02','勝場收藏','贏的次數自己會說話','累積桌上積分為正的場次（I 10／II 30／III 60／IV 120）','牌局','cumulative','prestige','norm','visible','{"event":"session_won"}',31,null,true),
  ('game_03','一日雙場','今天玩得很盡興','同一天完成 2 場牌局','牌局','specific','completion','norm','visible','{"event":"day_sessions_2"}',32,null,true),
  ('game_04','一日三場','今天是你的日子','同一天完成 3 場牌局','牌局','specific','competition','rare','visible','{"event":"day_sessions_3"}',33,null,true),
  ('game_05','三連正','手感正熱','連續 3 場桌上積分為正','牌局','specific','habit','norm','visible','{"event":"streak_positive_3"}',34,null,true),
  ('game_06','五連正','這不是運氣了','連續 5 場桌上積分為正','牌局','specific','habit','rare','visible','{"event":"streak_positive_5"}',35,null,true),
  ('game_07','首位達成','這桌你最強','第一次拿下第 1 名','牌局','specific','competition','norm','visible','{"event":"session_first_place"}',36,null,true),
  ('game_08','連續首位','兩場都站在最上面','連續 2 場拿下第 1 名','牌局','specific','habit','rare','visible','{"event":"streak_first_2"}',37,null,true),
  ('game_09','零負之日','今天一場都沒輸','同一天完成 2 場以上且全部為正','牌局','specific','prestige','rare','visible','{"event":"day_all_positive"}',38,null,true),
  ('game_10','三將全正','從頭順到尾','打滿 3 將，每一將結束都為正值','牌局','specific','prestige','rare','visible','{"event":"rounds_all_positive"}',39,null,true),
  ('game_11','單場破千','今天的積分很可觀','單場桌上積分 ≥ 1,000','牌局','specific','competition','norm','visible','{"event":"score_1000"}',40,null,true),
  ('game_12','單場破三千','這一桌會被記住','單場桌上積分 ≥ 3,000','牌局','specific','prestige','rare','visible','{"event":"score_3000"}',41,null,true),
  ('game_13','單場破六千','手氣好到不像話','單場桌上積分 ≥ 6,000','牌局','specific','prestige','rare','visible','{"event":"score_6000"}',42,null,true),
  ('game_14','單場破萬','五位數，這一場會被說很久','單場桌上積分 ≥ 10,000','牌局','specific','prestige','epic','visible','{"event":"score_10000"}',43,null,true),
  ('game_15','深夜大牌','凌晨的大牌最痛快','深夜時段（00:00–05:59）胡出牌型 8 台以上','牌局','specific','prestige','rare','visible','{"event":"big_hand_late"}',44,null,true),
  ('game_16','連場大牌','手氣連續兩場都在','連續 2 場都胡出牌型 8 台以上','牌局','specific','habit','epic','visible','{"event":"big_hand_2_sessions"}',45,null,true),
  ('game_17','梅開二度','同一桌做出兩次大牌','同一場胡出 2 次牌型 8 台以上','牌局','specific','prestige','epic','visible','{"event":"big_hand_twice"}',46,null,true),
  ('game_18','零放槍','守得滴水不漏','打滿約定將數且一次都沒有放槍','牌局','specific','competition','rare','visible','{"event":"no_deal_in"}',47,null,true),
  ('game_19','莊家胡牌','坐莊也能穩穩胡','擔任莊家時胡牌','牌局','specific','prestige','norm','visible','{"event":"dealer_won"}',48,null,true),
  ('game_20','莊家自摸','坐莊自摸最過癮','擔任莊家時自摸','牌局','specific','prestige','rare','visible','{"event":"dealer_tsumo"}',49,null,true),
  ('game_21','連莊 2','再來一把','連莊 2 次','牌局','specific','competition','norm','visible','{"event":"renzhuang_2"}',50,null,true),
  ('game_22','連莊 5','這桌快變你的主場','連莊 5 次','牌局','specific','prestige','rare','visible','{"event":"renzhuang_5"}',51,null,true),
  ('game_23','連莊 8','大家都在等你下莊','連莊 8 次','牌局','specific','prestige','epic','visible','{"event":"renzhuang_8"}',52,null,true),
  ('game_24','拉莊成功','把別的莊家拉下來','連莊中的莊家因你胡牌而下莊','牌局','specific','competition','norm','visible','{"event":"break_dealer"}',53,null,true),
  ('game_25','爆卡','這局有點慘烈','單場桌上積分跌破爆卡門檻','牌局','specific','story','norm','visible','{"event":"bust"}',54,null,false),
  ('game_26','讓對手爆卡','你把對面打到見底','因你胡牌或自摸導致對手爆卡','牌局','specific','competition','rare','visible','{"event":"bust_other"}',55,null,false),
  ('game_27','牌局收藏家','牌桌上的事你都經歷過','解鎖 10 個牌局類成就','牌局','specific','collection','rare','visible','{"count":10,"event":"achievement_unlocked","scope":"group_key","value":"牌局"}',56,'牌桌老手',true),
  -- D 局勢轉折
  ('swing_01','第一將領先','開局狀態很好','第一將結束時為正值且排名第一','局勢轉折','specific','competition','norm','visible','{"event":"swing_first_lead"}',88,null,true),
  ('swing_02','第二將守住','沒有被追上','第一將正值，第二將結束仍為正','局勢轉折','specific','competition','norm','visible','{"event":"swing_hold_second"}',89,null,true),
  ('swing_03','第三將定勝負','最後一將翻上來','打滿 3 將，第三將結束後排名從非第一變第一','局勢轉折','specific','story','rare','visible','{"event":"swing_third_decides"}',90,null,true),
  ('swing_04','從負轉正','追回來了','任一將結束由負值轉為正值','局勢轉折','specific','story','norm','visible','{"event":"swing_neg_to_pos"}',91,null,true),
  ('swing_05','一路領先','每一將你都在最上面','打滿 2 將以上，每一將結束都排名第一','局勢轉折','specific','prestige','rare','visible','{"event":"swing_lead_all"}',92,null,true),
  ('swing_06','穩定輸出','一將比一將好','打滿 2 將以上，每一將的得分都比上一將多','局勢轉折','specific','competition','rare','visible','{"event":"swing_steady"}',93,null,true),
  ('swing_07','最後一刻上車','最後一將剛好轉正','打滿 3 將，第三將結束才首次變正值','局勢轉折','specific','story','rare','visible','{"event":"swing_last_boarding"}',94,null,true),
  ('swing_08','大逆轉','從最後一名翻到第一','打滿 3 將，第三將由第 4 名變第 1 名','局勢轉折','specific','story','epic','visible','{"event":"swing_comeback"}',95,null,true),
  ('swing_09','逆轉收藏家','你的牌局故事很多','解鎖 5 個局勢轉折類成就','局勢轉折','specific','collection','rare','visible','{"count":5,"event":"achievement_unlocked","scope":"group_key","value":"局勢轉折"}',96,'打不死的小強',true),
  -- E 段位
  ('rank_01','第一次升級','同一階裡也有進步','同階內級數提升（如 IV → III）','段位','specific','completion','norm','visible','{"event":"rank_band_up"}',97,null,true),
  ('rank_02','升上銀牌熊','第一次跨階','段位達到銀牌熊','段位','prestige','prestige','norm','visible','{"event":"rank_reach_silver"}',98,null,true),
  ('rank_03','升上金牌熊','中段班了','段位達到金牌熊','段位','prestige','prestige','rare','visible','{"event":"rank_reach_gold"}',99,null,true),
  ('rank_04','升上白金熊','開始有人認得你','段位達到白金熊','段位','prestige','prestige','rare','visible','{"event":"rank_reach_platinum"}',100,null,true),
  ('rank_05','升上鑽石熊','這裡空氣稀薄','段位達到鑽石熊','段位','prestige','prestige','epic','visible','{"event":"rank_reach_diamond"}',101,null,true),
  ('rank_06','升上大師熊','段位的天花板','段位達到大師熊','段位','prestige','prestige','epic','silhouette','{"event":"rank_reach_master"}',102,null,true),
  ('rank_07','段位分 300','穩定累積中','段位分達到 300','段位','specific','competition','norm','visible','{"event":"rating_300"}',103,null,true),
  ('rank_08','段位分 600','你打得比多數人好','段位分達到 600','段位','specific','competition','rare','visible','{"event":"rating_600"}',104,null,true),
  ('rank_09','段位分 900','很少人到得了這裡','段位分達到 900','段位','prestige','prestige','epic','visible','{"event":"rating_900"}',105,null,true),
  ('rank_10','單場大躍進','這一場加很多','單場段位分變動 ≥ +30','段位','specific','competition','rare','visible','{"event":"rating_jump_30"}',106,null,true),
  ('rank_11','保級成功','守住了','觸發低段降階保護後仍維持段位','段位','specific','story','norm','visible','{"event":"rank_protected"}',107,null,true),
  ('rank_12','整季不降階','一路往上沒有退','一個賽季內未曾降階','段位','specific','habit','epic','visible','{"event":"rank_no_drop_season"}',108,null,false),
  ('rank_13','回到巔峰','掉下去又爬回來','降階後重新升回原本的最高階','段位','specific','story','rare','visible','{"event":"rank_back_to_peak"}',109,null,true),
  ('rank_14','高段對局','對面那三個都很強','與段位鑽石熊以上的玩家同桌','段位','specific','competition','rare','visible','{"event":"table_with_diamond"}',110,null,true),
  ('rank_15','大師對局','這一桌不好打','與段位大師熊以上的玩家同桌','段位','specific','competition','epic','visible','{"event":"table_with_master"}',111,null,true),
  ('rank_16','雀神對局','同桌坐著一位雀神','與賽季冠軍同桌','段位','specific','competition','epic','silhouette','{"event":"table_with_champion"}',112,null,true),
  ('rank_17','段位收藏家','段位這條路你走得完整','解鎖 5 個段位類成就','段位','specific','collection','rare','visible','{"count":5,"event":"achievement_unlocked","scope":"group_key","value":"段位"}',113,null,true)
 ) as v(code, name, description, condition_text, group_key, struct, motivation, rarity, visibility, trigger, sort, grants_title, is_active)
 where not exists (select 1 from public.achievements a where a.org_id = o.org_id and a.code = v.code and a.deleted_at is null);

-- 累積型的分級（I／II／III／IV）
insert into public.achievement_tiers (org_id, achievement_id, tier_level, tier_name, threshold)
select a.org_id, a.id, t.lv, t.nm, t.th
  from public.achievements a
  join (values ('game_01',1,'I',10),('game_01',2,'II',50),('game_01',3,'III',100),('game_01',4,'IV',300),
               ('game_02',1,'I',10),('game_02',2,'II',30),('game_02',3,'III',60),('game_02',4,'IV',120)
       ) as t(code, lv, nm, th) on t.code = a.code
 where a.deleted_at is null
   and not exists (select 1 from public.achievement_tiers x where x.achievement_id = a.id and x.tier_level = t.lv);

-- ② 收桌時的判定（牌局／局勢轉折／同桌對象／單場大躍進）
create or replace function public._ach_session_events(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_s      public.table_sessions;
  v_idem   text := 'settle2:' || p_session_id::text;
  v_end    timestamptz;
  v_day    date;
  v_p      record;
  v_ev     text[];
  v_e      text;
  v_fired  int := 0;
  v_n int; v_scored int; v_allpos boolean;
  v_arr    bigint[];
  v_g bigint[]; v_c bigint[]; v_k bigint[]; v_nr int; i int; v_ok boolean;
  v_big int; v_late int; v_dealin int; v_dwin int; v_dtsumo int; v_renz int; v_break int; v_hands int;
  v_finished int;
  v_prev_sid uuid; v_prev_seat smallint; v_prev_rating int;
  v_diamond int; v_master int;
begin
  select * into v_s from public.table_sessions where id = p_session_id;
  if not found or v_s.status <> 'completed' then
    return jsonb_build_object('ok', false, 'reason', 'not_completed');
  end if;
  v_end := coalesce(v_s.ended_at, now());
  v_day := (v_end at time zone 'Asia/Taipei')::date;
  select count(*) into v_finished from public.session_rounds where session_id = p_session_id and status = 'finished';
  select sort into v_diamond from public.rank_tiers where code = 'diamond';
  select sort into v_master  from public.rank_tiers where code = 'master';

  for v_p in
    select sp.member_id, sp.seat, sp.final_score, sp.finish_rank, sp.rating_after
      from public.session_players sp
     where sp.session_id = p_session_id and sp.member_id is not null
  loop
    v_ev := '{}';

    /* ── 同一天的場數（台北日曆日，與當日暢打同一個判準）── */
    select count(distinct ts.id),
           count(distinct ts.id) filter (where sp2.final_score is not null),
           coalesce(bool_and(sp2.final_score > 0) filter (where sp2.final_score is not null), false)
      into v_n, v_scored, v_allpos
      from public.session_players sp2
      join public.table_sessions ts on ts.id = sp2.session_id
     where sp2.member_id = v_p.member_id and ts.status = 'completed' and ts.deleted_at is null
       and (coalesce(ts.ended_at, now()) at time zone 'Asia/Taipei')::date = v_day;
    if v_n >= 2 then v_ev := array_append(v_ev, 'day_sessions_2'); end if;
    if v_n >= 3 then v_ev := array_append(v_ev, 'day_sessions_3'); end if;
    if v_scored >= 2 and v_allpos then v_ev := array_append(v_ev, 'day_all_positive'); end if;

    /* ── 連續為正：只看有記積分的場（純娛樂是 null，不算也不打斷）── */
    if coalesce(v_p.final_score, 0) > 0 then
      select array_agg(fs order by e desc) into v_arr
        from (select sp2.final_score::bigint as fs, ts.ended_at as e
                from public.session_players sp2
                join public.table_sessions ts on ts.id = sp2.session_id
               where sp2.member_id = v_p.member_id and ts.status = 'completed' and ts.deleted_at is null
                 and sp2.final_score is not null
                 and (ts.id = p_session_id or ts.ended_at <= v_end)
               order by ts.ended_at desc limit 5) z;
      if coalesce(array_length(v_arr, 1), 0) >= 3 and v_arr[1] > 0 and v_arr[2] > 0 and v_arr[3] > 0 then
        v_ev := array_append(v_ev, 'streak_positive_3');
      end if;
      if coalesce(array_length(v_arr, 1), 0) >= 5 and v_arr[1] > 0 and v_arr[2] > 0 and v_arr[3] > 0 and v_arr[4] > 0 and v_arr[5] > 0 then
        v_ev := array_append(v_ev, 'streak_positive_5');
      end if;
    end if;

    /* ── 名次 ── */
    if v_p.finish_rank = 1 then
      v_ev := array_append(v_ev, 'session_first_place');
      select array_agg(fr order by e desc) into v_arr
        from (select sp2.finish_rank::bigint as fr, ts.ended_at as e
                from public.session_players sp2
                join public.table_sessions ts on ts.id = sp2.session_id
               where sp2.member_id = v_p.member_id and ts.status = 'completed' and ts.deleted_at is null
                 and sp2.finish_rank is not null
                 and (ts.id = p_session_id or ts.ended_at <= v_end)
               order by ts.ended_at desc limit 2) z;
      if coalesce(array_length(v_arr, 1), 0) >= 2 and v_arr[1] = 1 and v_arr[2] = 1 then
        v_ev := array_append(v_ev, 'streak_first_2');
      end if;
    end if;

    /* ── 單場桌上積分 ── */
    if v_p.final_score is not null then
      if v_p.final_score >= 1000  then v_ev := array_append(v_ev, 'score_1000');  end if;
      if v_p.final_score >= 3000  then v_ev := array_append(v_ev, 'score_3000');  end if;
      if v_p.final_score >= 6000  then v_ev := array_append(v_ev, 'score_6000');  end if;
      if v_p.final_score >= 10000 then v_ev := array_append(v_ev, 'score_10000'); end if;
    end if;

    /* ── 每一局（電子計分）── */
    if v_p.seat is not null then
      select count(*) filter (where h.winner_seat = v_p.seat and h.result in ('ron','tsumo') and h.tai_pattern >= 8),
             count(*) filter (where h.winner_seat = v_p.seat and h.result in ('ron','tsumo') and h.tai_pattern >= 8
                                and public.migi_slot_of(h.created_at) = 'late'),
             count(*) filter (where h.deal_in_seat = v_p.seat and h.result in ('ron','bao')),
             count(*) filter (where h.winner_seat = v_p.seat and h.dealer_seat = v_p.seat and h.result in ('ron','tsumo')),
             count(*) filter (where h.winner_seat = v_p.seat and h.dealer_seat = v_p.seat and h.result = 'tsumo'),
             coalesce(max(h.renzhuang) filter (where h.dealer_seat = v_p.seat and h.result <> 'kala'), 0),
             count(*) filter (where h.renzhuang >= 1 and h.winner_seat = v_p.seat
                                and h.winner_seat <> h.dealer_seat and h.result in ('ron','tsumo')),
             count(*)
        into v_big, v_late, v_dealin, v_dwin, v_dtsumo, v_renz, v_break, v_hands
        from public.hands h
       where h.session_id = p_session_id and h.status = 'confirmed';

      if v_late >= 1 then v_ev := array_append(v_ev, 'big_hand_late'); end if;
      if v_big  >= 2 then v_ev := array_append(v_ev, 'big_hand_twice'); end if;
      if v_big  >= 1 then
        v_prev_sid := null; v_prev_seat := null;
        select ts.id, sp2.seat into v_prev_sid, v_prev_seat
          from public.session_players sp2
          join public.table_sessions ts on ts.id = sp2.session_id
         where sp2.member_id = v_p.member_id and ts.status = 'completed' and ts.deleted_at is null
           and ts.id <> p_session_id and ts.ended_at < v_end
         order by ts.ended_at desc limit 1;
        if v_prev_sid is not null and exists (
             select 1 from public.hands h
              where h.session_id = v_prev_sid and h.status = 'confirmed' and h.winner_seat = v_prev_seat
                and h.result in ('ron','tsumo') and h.tai_pattern >= 8) then
          v_ev := array_append(v_ev, 'big_hand_2_sessions');
        end if;
      end if;
      if v_hands > 0 and v_dealin = 0 and v_s.planned_rounds is not null and v_finished >= v_s.planned_rounds then
        v_ev := array_append(v_ev, 'no_deal_in');
      end if;
      if v_dwin   >= 1 then v_ev := array_append(v_ev, 'dealer_won'); end if;
      if v_dtsumo >= 1 then v_ev := array_append(v_ev, 'dealer_tsumo'); end if;
      if v_renz   >= 2 then v_ev := array_append(v_ev, 'renzhuang_2'); end if;
      if v_renz   >= 5 then v_ev := array_append(v_ev, 'renzhuang_5'); end if;
      if v_renz   >= 8 then v_ev := array_append(v_ev, 'renzhuang_8'); end if;
      if v_break  >= 1 then v_ev := array_append(v_ev, 'break_dealer'); end if;
    end if;

    /* ── 每一將結束的累積積分與名次（純娛樂不算）── */
    if v_p.final_score is not null and v_p.seat is not null then
      v_g := null; v_c := null; v_k := null;
      with rr as (select id, round_no from public.session_rounds
                   where session_id = p_session_id and status = 'finished'),
           dd as (select rr.round_no, e.key::int as seat, sum(e.value::numeric)::bigint as gain
                    from public.hands h
                    join rr on rr.id = h.round_id
                   cross join lateral jsonb_each_text(h.score_delta) e
                   where h.status = 'confirmed'
                   group by rr.round_no, e.key::int),
           cc as (select round_no, seat, gain,
                         (sum(gain) over (partition by seat order by round_no))::bigint as cum
                    from dd),
           kk as (select c1.round_no, c1.seat, c1.gain, c1.cum,
                         (1 + (select count(*) from cc c2 where c2.round_no = c1.round_no and c2.cum > c1.cum))::bigint as place
                    from cc c1)
      select array_agg(kk.gain order by kk.round_no), array_agg(kk.cum order by kk.round_no), array_agg(kk.place order by kk.round_no)
        into v_g, v_c, v_k
        from kk where kk.seat = v_p.seat;
      v_nr := coalesce(array_length(v_c, 1), 0);

      if v_nr >= 1 and v_c[1] > 0 and v_k[1] = 1 then v_ev := array_append(v_ev, 'swing_first_lead'); end if;
      if v_nr >= 2 and v_c[1] > 0 and v_c[2] > 0 then v_ev := array_append(v_ev, 'swing_hold_second'); end if;
      if v_nr = 3 and v_k[2] <> 1 and v_k[3] = 1 then v_ev := array_append(v_ev, 'swing_third_decides'); end if;
      if v_nr >= 2 then
        v_ok := false;
        for i in 2 .. v_nr loop
          if v_c[i-1] < 0 and v_c[i] > 0 then v_ok := true; end if;
        end loop;
        if v_ok then v_ev := array_append(v_ev, 'swing_neg_to_pos'); end if;
        v_ok := true;
        for i in 1 .. v_nr loop
          if v_k[i] <> 1 then v_ok := false; end if;
        end loop;
        if v_ok then v_ev := array_append(v_ev, 'swing_lead_all'); end if;
        v_ok := true;
        for i in 2 .. v_nr loop
          if v_g[i] <= v_g[i-1] then v_ok := false; end if;
        end loop;
        if v_ok then v_ev := array_append(v_ev, 'swing_steady'); end if;
      end if;
      if v_nr = 3 and v_c[1] <= 0 and v_c[2] <= 0 and v_c[3] > 0 then v_ev := array_append(v_ev, 'swing_last_boarding'); end if;
      if v_nr = 3 and v_k[2] = 4 and v_k[3] = 1 then v_ev := array_append(v_ev, 'swing_comeback'); end if;
      if v_nr = 3 and v_c[1] > 0 and v_c[2] > 0 and v_c[3] > 0 then v_ev := array_append(v_ev, 'rounds_all_positive'); end if;
    end if;

    /* ── 單場段位分變動：跟自己上一場結算後的段位分比（第一場是定位賽，沒有上一場就不算）── */
    if v_p.rating_after is not null then
      v_prev_rating := null;
      select sp2.rating_after into v_prev_rating
        from public.session_players sp2
        join public.table_sessions ts on ts.id = sp2.session_id
       where sp2.member_id = v_p.member_id and ts.status = 'completed' and ts.deleted_at is null
         and ts.id <> p_session_id and sp2.rating_after is not null and ts.ended_at < v_end
       order by ts.ended_at desc limit 1;
      if v_prev_rating is not null and v_p.rating_after - v_prev_rating >= 30 then
        v_ev := array_append(v_ev, 'rating_jump_30');
      end if;
    end if;

    /* ── 同桌的人（看對方現在的段位；雀神看有沒有當過賽季冠軍）── */
    if exists (select 1 from public.session_players o
                 join public.members m on m.id = o.member_id
                 join public.rank_tiers t on t.code = public._rank_tier_of(m.rank)
                where o.session_id = p_session_id and o.member_id <> v_p.member_id and t.sort >= v_diamond) then
      v_ev := array_append(v_ev, 'table_with_diamond');
    end if;
    if exists (select 1 from public.session_players o
                 join public.members m on m.id = o.member_id
                 join public.rank_tiers t on t.code = public._rank_tier_of(m.rank)
                where o.session_id = p_session_id and o.member_id <> v_p.member_id and t.sort >= v_master) then
      v_ev := array_append(v_ev, 'table_with_master');
    end if;
    if exists (select 1 from public.session_players o
                 join public.season_champions c on c.member_id = o.member_id
                where o.session_id = p_session_id and o.member_id <> v_p.member_id) then
      v_ev := array_append(v_ev, 'table_with_champion');
    end if;

    foreach v_e in array v_ev loop
      perform public.fire_event_tx(v_p.member_id, v_e, 1, null, v_idem);
      v_fired := v_fired + 1;
    end loop;
  end loop;

  return jsonb_build_object('ok', true, 'fired', v_fired);
end $fn$;
revoke execute on function public._ach_session_events(uuid) from public, anon, authenticated;

-- ③ 段位寫入時的判定
create or replace function public.trg_members_rank_events()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_ot text; v_nt text; v_os int; v_ns int; v_bs int; v_ob int; v_nb int;
  v_idem text; t record;
begin
  if new.deleted_at is not null then return null; end if;
  begin
    v_ot := public._rank_tier_of(old.rank);
    v_nt := public._rank_tier_of(new.rank);
    select sort into v_os from public.rank_tiers where code = v_ot;
    select sort into v_ns from public.rank_tiers where code = v_nt;
    select sort into v_bs from public.rank_tiers where code = old.best_rank_tier;
    v_idem := 'rank:' || new.id::text || ':' || coalesce(new.rank, '') || ':' || coalesce(new.rating, 0)::text;

    -- 同階升級：級數 IV → III → II → I
    if v_ot is not null and v_ot = v_nt then
      v_ob := case when old.rank ~ ' IV$' then 1 when old.rank ~ ' III$' then 2 when old.rank ~ ' II$' then 3 when old.rank ~ ' I$' then 4 end;
      v_nb := case when new.rank ~ ' IV$' then 1 when new.rank ~ ' III$' then 2 when new.rank ~ ' II$' then 3 when new.rank ~ ' I$' then 4 end;
      if v_ob is not null and v_nb is not null and v_nb > v_ob then
        perform public.fire_event_tx(new.id, 'rank_band_up', 1, null, v_idem);
      end if;
    end if;

    -- 跨階：一次跳好幾階時，中間每一階都算到過
    if v_ns is not null and v_ns > coalesce(v_os, 0) then
      for t in select code from public.rank_tiers
                where sort > coalesce(v_os, 0) and sort <= v_ns and sort >= 2
                order by sort loop
        perform public.fire_event_tx(new.id, 'rank_reach_' || t.code, 1, null, v_idem);
      end loop;
    end if;

    -- 段位分門檻（達到就算，之後掉下去不收回）
    if coalesce(new.rating, 0) >= 300 then perform public.fire_event_tx(new.id, 'rating_300', 1, null, v_idem); end if;
    if coalesce(new.rating, 0) >= 600 then perform public.fire_event_tx(new.id, 'rating_600', 1, null, v_idem); end if;
    if coalesce(new.rating, 0) >= 900 then perform public.fire_event_tx(new.id, 'rating_900', 1, null, v_idem); end if;

    -- 回到巔峰：之前掉到最高階以下，這一次回到最高階
    if v_bs is not null and v_os is not null and v_ns is not null and v_os < v_bs and v_ns >= v_bs then
      perform public.fire_event_tx(new.id, 'rank_back_to_peak', 1, null, v_idem);
    end if;
  exception when others then null;   -- 成就失敗不可以擋住段位寫入
  end;
  return null;
end $fn$;
revoke execute on function public.trg_members_rank_events() from public, anon, authenticated;

drop trigger if exists trg_members_rank_events on public.members;
create trigger trg_members_rank_events
  after update of rank on public.members
  for each row execute function public.trg_members_rank_events();

-- ④ 保級成功：低段降階保護真的夾住時發事件（用線上全文插一段）
do $$
declare
  v_def    text := pg_get_functiondef('public.apply_session_rounds_tx(uuid,jsonb)'::regprocedure);
  v_anchor text := 'v_new := greatest(v_new, v_floor);';
  v_ins    text;
  v_n      int;
begin
  if v_def ~ '''rank_protected''' then return; end if;
  v_n := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_n <> 1 then
    raise exception '保級插入點應該剛好 1 處，實際 % 處 —— 線上版本跟預期不同，整份停下', v_n;
  end if;
  v_ins := $ins$if v_band = 'low' and v_new < v_floor then
          begin
            perform public.fire_event_tx(v_ids[i], 'rank_protected', 1, null, 'protect:' || p_session_id::text);
          exception when others then null;
          end;
        end if;
        $ins$;
  execute replace(v_def, v_anchor, v_ins || v_anchor);
end $$;

-- ⑤ 收桌：原本的成就事件之後，再跑第 2 批的判定（用線上全文插一段）
do $$
declare
  v_def    text := pg_get_functiondef('public.settle_session_tx(uuid,uuid,boolean)'::regprocedure);
  v_anchor text := '-- ── 收完保留給現場';
  v_ins    text;
  v_n      int;
begin
  if v_def ~ '_ach_session_events' then return; end if;
  v_n := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_n <> 1 then
    raise exception '收桌插入點應該剛好 1 處，實際 % 處 —— 線上版本跟預期不同，整份停下', v_n;
  end if;
  v_ins := $ins$/* 🆕 2026-09-30：成就第 2 批（牌局／局勢轉折／同桌／單場段位分）的判定。
     ⚠ 失敗不回滾收桌，但**不安靜吞掉**：寫一筆 ach_error 埋點，錯誤儀表看得到。 */
  begin
    perform public._ach_session_events(p_session_id);
  exception when others then
    begin
      perform public.log_app_event_tx(v_s.org_id, null, 'ach_error',
        jsonb_build_object('where', '_ach_session_events', 'session_id', p_session_id,
                           'code', sqlstate, 'message', left(sqlerrm, 300)),
        now(), v_s.store_id);
    exception when others then null;
    end;
  end;

  $ins$;
  execute replace(v_def, v_anchor, v_ins || v_anchor);
end $$;

-- ⑥ 回填：已經到過的階、已經打過的場（只有測試資料，但讓狀態一致）
do $$
declare r record; a record;
begin
  -- 跨階：最高段位以下每一階（銀牌起）
  for r in select m.id, bt.sort from public.members m join public.rank_tiers bt on bt.code = m.best_rank_tier
            where m.deleted_at is null and bt.sort >= 2 loop
    for a in select ac.code from public.achievements ac
               join public.rank_tiers t on ac.trigger ->> 'event' = 'rank_reach_' || t.code
              where ac.deleted_at is null and ac.is_active and t.sort >= 2 and t.sort <= r.sort loop
      perform public.ach_unlock_tx(r.id, a.code, 'backfill:2026-09-30:rank');
    end loop;
  end loop;
  -- 牌局常客／勝場收藏：寫進度（還不到解鎖門檻）
  for r in select sp.member_id,
                  count(distinct ts.id) as n,
                  count(distinct ts.id) filter (where sp.final_score > 0) as w
             from public.session_players sp
             join public.table_sessions ts on ts.id = sp.session_id
             join public.members m on m.id = sp.member_id and m.deleted_at is null
            where ts.status = 'completed' and ts.deleted_at is null
            group by sp.member_id loop
    if r.n > 0 then perform public.ach_progress_tx(r.member_id, 'game_01', r.n, 'backfill:2026-09-30:game_01'); end if;
    if r.w > 0 then perform public.ach_progress_tx(r.member_id, 'game_02', r.w, 'backfill:2026-09-30:game_02'); end if;
  end loop;
end $$;

/* ============================================================
   驗證（不 raise —— 這份要留下東西）
   ============================================================ */
do $$
declare
  v_msg text := ''; v_n int; v_m int; v_txt text; v_def text;
begin
  -- ① 53 枚、50 枚上架
  select count(*), count(*) filter (where is_active) into v_n, v_m
    from public.achievements where deleted_at is null and code ~ '^(game|swing|rank)_\d\d$';
  v_msg := v_msg || case when v_n = 53 and v_m = 50 then '✅' else '🔴' end
        || ' ① 主檔 ' || v_n || ' 枚、上架 ' || v_m || '（期望 53／50）' || E'\n';

  -- ② 沒上架的正好是那 3 枚
  select string_agg(code, ',' order by code) into v_txt
    from public.achievements where deleted_at is null and code ~ '^(game|swing|rank)_\d\d$' and not is_active;
  v_msg := v_msg || case when v_txt = 'game_25,game_26,rank_12' then '✅' else '🔴' end
        || ' ② 先不上架 ' || coalesce(v_txt, '∅') || '（期望 game_25,game_26,rank_12）' || E'\n';

  -- ③ 分級
  select string_agg(a.code || ':' || cnt || '/' || mx, ' ' order by a.code) into v_txt
    from (select achievement_id, count(*) cnt, max(threshold) mx from public.achievement_tiers group by 1) x
    join public.achievements a on a.id = x.achievement_id where a.code in ('game_01','game_02');
  v_msg := v_msg || case when v_txt = 'game_01:4/300 game_02:4/120' then '✅' else '🔴' end
        || ' ③ 分級 ' || coalesce(v_txt, '∅') || E'\n';

  -- ④ 三枚收藏家：門檻、群組、稱號
  select string_agg(code || ':' || (trigger->>'count') || ':' || (trigger->>'value') || ':' || coalesce(grants_title, '—'), ' ' order by code) into v_txt
    from public.achievements where code in ('game_27','swing_09','rank_17') and deleted_at is null;
  v_msg := v_msg || case when v_txt = 'game_27:10:牌局:牌桌老手 rank_17:5:段位:— swing_09:5:局勢轉折:打不死的小強' then '✅' else '🔴' end
        || ' ④ 收藏家 ' || coalesce(v_txt, '∅') || E'\n';

  -- ⑤ 每一枚上架的（收藏家除外）都有發射端；沒上架的 3 枚沒有（負對照）
  with ev as (
    select a.code, a.is_active, a.trigger ->> 'event' as e
      from public.achievements a
     where a.deleted_at is null and a.code ~ '^(game|swing|rank)_\d\d$' and not (a.trigger ? 'count')
  ), src as (
    select string_agg(pg_get_functiondef(p.oid), E'\n') as body
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
       and p.proname in ('_ach_session_events','trg_members_rank_events','apply_session_rounds_tx','settle_session_tx')
  )
  select count(*) filter (where ev.is_active and not has),
         count(*) filter (where not ev.is_active and not has)
    into v_n, v_m
    from (select ev.*, (src.body like '%''' || ev.e || '''%'
                        or (ev.e like 'rank_reach_%' and src.body like '%''rank_reach_''%'
                            and exists (select 1 from public.rank_tiers t where 'rank_reach_' || t.code = ev.e))) as has
            from ev, src) ev;
  v_msg := v_msg || case when v_n = 0 and v_m = 3 then '✅' else '🔴' end
        || ' ⑤ 上架但沒有發射端 ' || v_n || ' 枚（期望 0）· 沒上架且沒有發射端 ' || v_m || ' 枚（期望 3）' || E'\n';

  -- ⑥ 收桌與計分函式插進去了、各一次
  v_def := pg_get_functiondef('public.settle_session_tx(uuid,uuid,boolean)'::regprocedure);
  v_n := (length(v_def) - length(replace(v_def, 'perform public._ach_session_events(', ''))) / length('perform public._ach_session_events(');
  v_def := pg_get_functiondef('public.apply_session_rounds_tx(uuid,jsonb)'::regprocedure);
  v_m := (length(v_def) - length(replace(v_def, '''rank_protected''', ''))) / length('''rank_protected''');
  v_msg := v_msg || case when v_n = 1 and v_m = 1 then '✅' else '🔴' end
        || ' ⑥ 收桌呼叫判定 ' || v_n || ' 處、保級事件 ' || v_m || ' 處（期望各 1）' || E'\n';

  -- ⑦ 觸發器在
  select count(*) into v_n from pg_trigger where tgrelid = 'public.members'::regclass and tgname = 'trg_members_rank_events';
  v_msg := v_msg || case when v_n = 1 then '✅' else '🔴' end || ' ⑦ 觸發器 trg_members_rank_events 在' || E'\n';

  -- ⑧ 兩支新函式前端叫不到
  select count(*) into v_n from unnest(array['public._ach_session_events(uuid)', 'public.trg_members_rank_events()']) f
   where has_function_privilege('anon', f::regprocedure, 'execute') or has_function_privilege('authenticated', f::regprocedure, 'execute');
  v_msg := v_msg || case when v_n = 0 then '✅' else '🔴' end || ' ⑧ 新函式前端叫不到（' || v_n || ' 支叫得到，期望 0）' || E'\n';

  -- ⑨ 回填：銀牌 4 人拿到「升上銀牌熊」；牌局常客進度合計 52、勝場收藏合計 15（期望值 09-30 當場查的）
  select count(*) into v_n from public.member_achievements ma join public.achievements a on a.id = ma.achievement_id
   where a.code = 'rank_02' and ma.status = 'unlocked';
  select coalesce(sum(ma.current_value) filter (where a.code = 'game_01'), 0),
         coalesce(sum(ma.current_value) filter (where a.code = 'game_02'), 0)
    into v_m, v_def   -- v_def 借來放數字
    from public.member_achievements ma join public.achievements a on a.id = ma.achievement_id
   where a.code in ('game_01','game_02');
  v_msg := v_msg || case when v_n = 4 and v_m = 52 and v_def = '15' then '✅' else '🔴' end
        || ' ⑨ 回填：升上銀牌熊 ' || v_n || ' 人（期望 4）· 牌局常客合計 ' || v_m || '（期望 52）· 勝場收藏合計 ' || v_def || '（期望 15）';

  perform set_config('migi.v', v_msg, true);
end $$;
select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有驗證訊息') as "驗證";
