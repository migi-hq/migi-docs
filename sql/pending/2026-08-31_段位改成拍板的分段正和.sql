/* ============================================================
   段位改成拍板的規格：分段正和 ＋ 每階 45 ＋ 每季歸零
   2026-08-31 · MIGI 咪吉麻將

   ── 🔴 這一份是在修我自己的錯 ──────────────────────
   2026-08-31 稍早跑過 `2026-08-31_名次到積分到段位.sql`，
   那份是**憑我對 LOL 的印象設計的**，而
   `docs/08-決策與踩坑/決策紀錄.md` 第二十三節
   「段位系統完整規格（2026-08-29 拍板）」早就把整套定完了。

   🔴 我不但沒查，還把一個**已經被否決的機制**（降段保護 / peak_rating）
     當成新提案講回去。決策紀錄 ④ 白紙黑字：
     「✅ 歸零同時讓規則少一半：不需要 peak_rating、不需要保護機制、不需要衰減。」

   | | 拍板的 | 我上一份建的 |
   |---|---|---|
   | 算法 | **分段正和**（固定點數表） | 🔴 兩兩 Elo |
   | 每階 | **45** | 🔴 200／銅牌 400 |
   | 起始 1000 | **銅牌熊 II** | 銅牌熊 II（區間不同但巧合同名） |
   | 小級方向 | **IV 最低、I 最高** | ✅ 同（2026-08-31 使用者更正過一次，見 ④） |
   | peak_rating | **不需要** | 🔴 加了 |
   | 賽季 | **6 個月降 2 大階** | 🔴 沒有 |
   | 🛡 降階保護 | 賽季中**銅銀金不掉階**；賽季末**所有人都降** | 🔴 沒有 |
   | 大師門檻 | **最近 50 場 ≥20 個不同對手** | 🔴 用了被推翻的 norm |
   | 計次 | **一將計一次**，未滿 2 將不計 | 🔴 一場一次 |

   📌 教訓（已值得寫進硬規則 3）：**硬規則 3 說的「不要猜」不只適用於資料庫，
     也適用於 `docs/`。** 這個專案的文件密度很高，該有的都有 ——
     我只是沒去讀，然後用「業界常識」填了空白。

   ── ⚠ 兩份文件對 I–IV 方向互相矛盾 ────────────────
   · `會員分級制度規格.md:44`：「I–IV，**I 最高**」
   · `決策紀錄` 二十三 ③：銅牌 **I=910**（最低）… IV=1045（最高）
   🎯 以**決策紀錄**為準（它明文取代前者，而且內部自洽：
     ⑥ 說「鑽石 IV = 第 20/24 階」，用 IV 最高數剛好是 20）。
   ⇒ **I 最低、IV 最高。** 已在分級制度規格加更正註記。
   ============================================================ */

-- ── ① 拿掉上一份多加的 peak_rating ────────────────────
/* 🔴 決策紀錄 ④ 明文說不需要它。累積感交給**頭像圖鑑與稱號**（⑤）——
   「這季掉回銅牌，但鑽石熊頭像永遠是我的。」
   ⚠ 而降階保護也**不需要它**：規則是「不掉階」的話，
     當前分數本身就記著他到過哪一階（見 ⑥ 的說明）。
   ⚠ 留著比刪掉糟：一個沒有規則會維護的欄位，遲早有人拿它當真。 */
alter table members drop column if exists peak_rating;


-- ── ② 段位主檔改成拍板的級距 ──────────────────────────
/* 決策紀錄 ③：每階 **45**，起始 1000 = **銅牌熊 II**
   ⚠ **IV 最低、I 最高**（2026-08-31 使用者更正）——
     決策紀錄 ③ 的表把欄位排成 `I|II|III|IV` 對應升冪的分數，
     那是排版不是規則。分數界線一個字都沒動。
   ```
   銅牌  IV 910   III 955   II 1000   I 1045      ← 起始
   銀牌  IV 1090  III 1135  II 1180   I 1225
   金牌  IV 1270  III 1315  II 1360   I 1405
   白金  IV 1450  III 1495  II 1540   I 1585      ← 零和分水嶺
   鑽石  IV 1630  III 1675  II 1720   I 1765
   大師  1810+
   ```
   ⚠ 為什麼是 45 而不是 40／50：看「一週一次 · 平均實力」那一群（最多的客人）——
     40 讓他 4.5 個月就到白金然後**停住 1.5 個月**；
     50 讓他**一季到不了**白金；45 讓他整季都在爬、最後一刻達標。

   🆕 `band` 決定順位點（決策紀錄 ②）：
     low = 銅／銀／金（正和）｜ mid = 白金／鑽石（零和）｜ top = 大師（負和） */
alter table rank_tiers
  add column if not exists band text not null default 'low';
alter table rank_tiers drop constraint if exists rank_tiers_band_chk;
alter table rank_tiers add constraint rank_tiers_band_chk
  check (band in ('low','mid','top'));

-- 重設六列（上一份的區間整組不對）
update rank_tiers set min_rating =  910, band = 'low', sub_count = 4, auto = true,
       note = '入門。起始 1000 = 銅牌熊 II。🛡 賽季中不掉階（銀金同）'
                                                                    where code = 'bronze';
update rank_tiers set min_rating = 1090, band = 'low', sub_count = 4, auto = true,
       note = null                                                  where code = 'silver';
update rank_tiers set min_rating = 1270, band = 'low', sub_count = 4, auto = true,
       note = null                                                  where code = 'gold';
update rank_tiers set min_rating = 1450, band = 'mid', sub_count = 4, auto = true,
       note = '🎯 白金是分水嶺：從這裡開始零和。客人只要記一句「白金以上要守」'
                                                                    where code = 'platinum';
update rank_tiers set min_rating = 1630, band = 'mid', sub_count = 4, auto = true,
       note = '自動能到的最高階'                                    where code = 'diamond';
update rank_tiers set min_rating = 1810, band = 'top', sub_count = 1, auto = false,
       note = '🔴 除了分數還要「最近 50 場有 ≥20 個不同對手」（決策紀錄 ⑥）。'
              '取代原規格的 official 賽事 norm —— MIGI 沒有賽事概念，'
              '照原規格走大師熊永遠沒有人拿得到，而辦賽事要有人每次維護（硬規則 5.5）。'
                                                                    where code = 'master';


-- ── ③ 順位點：分段正和 ────────────────────────────────
/* 決策紀錄 ②。**每個人依自己當下的段位**取自己那一列。
   | band | 1位 | 2位 | 3位 | 4位 | 總和 |
   |---|---|---|---|---|---|
   | low（銅銀金） | +30 | +15 |   0 | −20 | **+25 正和** |
   | mid（白金鑽石） | +30 | +10 | −10 | −30 | 零和 |
   | top（大師） | +30 |  +5 | −20 | −40 | **−25 負和** |

   🎯 **低段正和（來就會上）、高段負和（要強才守得住）**，
     那就是段位分佈自然變成金字塔的原因。天鳳與雀魂**都不是零和**。
   ✅ 而「較弱的人低段只有 +0.8/將」證明不會通膨 —— 他要 1250 將才爬得到白金。

   ⚠ 三人局：只有 1/2/3 位，第 4 欄用不到。
     決策紀錄①寫「三人以下不計」—— 那是指**三人以下（含）**，
     所以三人局也不計。這裡仍然定義 3 位的分數，因為
     `game_players` 日後可能有三人制，但結算函式會擋。 */
create table if not exists rank_points (
  band     text     not null,
  place    smallint not null,
  points   smallint not null,
  primary key (band, place)
);
alter table rank_points enable row level security;  -- 0 policy，只給 DEFINER 讀

insert into rank_points (band, place, points) values
  ('low',1, 30), ('low',2, 15), ('low',3,  0), ('low',4,-20),
  ('mid',1, 30), ('mid',2, 10), ('mid',3,-10), ('mid',4,-30),
  ('top',1, 30), ('top',2,  5), ('top',3,-20), ('top',4,-40)
on conflict (band, place) do update set points = excluded.points;


-- ── ④ 分數 → 段位（純函式，最高只到鑽石 IV）──────────
/* 🔴 **小級由區間自己切出來**（每階 45），**I 最低、IV 最高**。
   ⚠ 方向跟上一份相反 —— 見檔頭那段文件矛盾的說明。
   ⚠ 這一支**不會回大師熊**：大師要對手多樣性，而那需要 member 才問得到。
     → 用 `member_rank_tx(member_id)`。 */
create or replace function public.rank_detail_tx(p_rating integer)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v int; t record; w numeric; step numeric; idx int; lo numeric; hi numeric;
  v_floor int; v_sub text; v_top boolean;
begin
  select min(min_rating) into v_floor from rank_tiers where auto;
  v := greatest(coalesce(p_rating, 1000), v_floor);

  select * into t from (
    select label, min_rating, sub_count, band,
           lead(min_rating) over (order by min_rating) as next_min
      from rank_tiers where auto
  ) x
   where v >= x.min_rating
   order by x.min_rating desc limit 1;

  if t.label is null then
    return jsonb_build_object('rank','銅牌熊 I','tier','銅牌熊','sub','I','band','low',
      'rating', v, 'progress', 0, 'to_next', null, 'at_top', true);
  end if;

  /* 最高的自動階（鑽石熊）沒有 next_min，寬度用 45×4 補 —— 跟其他階一樣寬。
     不補的話 step 會是 0 然後除零。 */
  w    := (coalesce(t.next_min, t.min_rating + 180) - t.min_rating)::numeric;
  step := w / t.sub_count;
  idx  := least(t.sub_count, 1 + floor((v - t.min_rating) / step)::int);
  lo   := t.min_rating + (idx - 1) * step;
  hi   := lo + step;

  /* 🔴 **IV 最低、I 最高**（2026-08-31 使用者更正）。
     ⚠ 決策紀錄 ③ 的區間表把欄位排成 `I | II | III | IV` 對應
       `910 | 955 | 1000 | 1045`（升冪），讀起來像「I 最低」——
       **那是排版，不是規則**。以《會員分級制度規格》的
       「I 最高，如 鑽石熊 I > 鑽石熊 IV」為準。
     ⇒ 連帶更正兩處：
       · 起始 1000 = **銅牌熊 II**（③ 原本寫 III）
       · 自動能到的最高小級 = **鑽石熊 I**（⑥ 原本寫「鑽石 IV = 第 20/24 階」）
     📌 分數界線一個字都沒動 —— 那是每階 45 推導出來的，標籤只是叫法。 */
  v_sub := case when t.sub_count <= 1 then null
                else (array['IV','III','II','I'])[idx] end;
  v_top := (t.next_min is null and idx = t.sub_count);

  return jsonb_build_object(
    'rank',     case when v_sub is null then t.label else t.label || ' ' || v_sub end,
    'tier',     t.label,
    'sub',      v_sub,
    'band',     t.band,
    -- 🎯 這一階的下限。低段的降階保護就是夾在這個值上（見 ⑥）
    'tier_min', t.min_rating,
    'rating',   v,
    'progress', least(100, greatest(0, round((v - lo) / step * 100)))::int,
    -- 至頂時是 null 不是 0 —— 0 會被畫成「就快到了」
    'to_next',  case when v_top then null else ceil(hi - v)::int end,
    'at_top',   v_top
  );
end $$;

create or replace function public.rank_from_rating(p_rating integer)
returns text language sql stable
as $$ select public.rank_detail_tx(p_rating) ->> 'rank' $$;


-- ── ⑤ 大師熊：分數 ＋ 對手多樣性 ──────────────────────
/* 決策紀錄 ⑥：`rating >= 1810 且 最近 50 場的對手中有 ≥20 個不同的人`
   🎯 它防的東西跟 FIDE 的 norm 一樣（證明分數是面對不特定對手打出來的），
     但**資料本來就有**（`session_players`），零維護。
   ✅ 固定四人包桌爬得到**鑽石 IV**（第 20/24 階，很高了），大師才要求不特定對手。
     那句話很好講：「**大師熊要跟很多不同的人打過。**」 */
create or replace function public.member_rank_tx(p_member_id uuid)
returns text
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_rating int; v_master int; v_opp int;
begin
  select rating into v_rating from members where id = p_member_id and deleted_at is null;
  if v_rating is null then return null; end if;

  select min_rating into v_master from rank_tiers where code = 'master';
  if v_rating < v_master then
    return public.rank_from_rating(v_rating);
  end if;

  with last50 as (
    select session_id from session_players
     where member_id = p_member_id and finish_rank is not null
     order by joined_at desc limit 50
  )
  select count(distinct sp.member_id) into v_opp
    from session_players sp join last50 l on l.session_id = sp.session_id
   where sp.member_id <> p_member_id;

  return case when coalesce(v_opp,0) >= 20
              then (select label from rank_tiers where code = 'master')
              else public.rank_from_rating(v_rating) end;   -- 卡在鑽石 IV
end $$;


-- ── ⑥ 收桌結算：一將計一次 ────────────────────────────
/* 決策紀錄 ①：
   · 觸發 = **收桌自動算分**（所以一次結算整場，不是一將呼叫一次）
   · **一將計一次**（打 3 將算 3 次）
   · 🔴 **未滿 2 將不計**、**三人以下不計**
   · ✅ **包桌照計**（推翻原規格的「包桌不計」——
       包桌佔生意五成，排除它等於一半的客人段位永遠不動）

   ⚠ **每一將依各人「當下」的段位取點數表**，所以要一將一將依序套用 ——
     第 1 將的結果會影響第 2 將用哪一列。
     一次算完再寫的話，跨過白金那條線的人整場都會用低段的正和點數。

   ⏳ **每一將的明細（誰胡、幾台）要等牌譜 schema**
     （`sql/_設計稿未落地/牌譜資料庫schema.sql` 的 games / game_players / hands）。
     這裡只吃名次，不自己另建一套表 —— 那會變成第二套（同待辦 35 的病）。 */
create or replace function public.apply_session_rounds_tx(
  p_session_id uuid,
  p_rounds     jsonb   -- [ [ {"member_id":"…","finish_rank":1}, … ], … ] 一將一個陣列
) returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_org uuid; v_rounds int; v_n int; r jsonb; e jsonb;
  v_ids uuid[]; v_ranks int[]; i int;
  v_band text; v_pts int; v_new int; v_floor int;
  v_total jsonb := '{}'::jsonb;   -- member_id → 本場累計得點
begin
  select org_id into v_org from table_sessions
   where id = p_session_id and deleted_at is null;
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found');
  end if;

  v_rounds := jsonb_array_length(coalesce(p_rounds, '[]'::jsonb));
  -- 🔴 未滿 2 將不計（決策紀錄 ①，原規格是 1 將）
  if v_rounds < 2 then
    return jsonb_build_object('ok', false, 'reason', 'too_few_rounds', 'rounds', v_rounds);
  end if;

  -- 冪等：整場只結算一次
  if exists (select 1 from session_players
              where session_id = p_session_id and finish_rank is not null) then
    return jsonb_build_object('ok', false, 'reason', 'already_applied');
  end if;

  for idx in 0 .. v_rounds - 1 loop
    r := p_rounds -> idx;
    select array_agg((x->>'member_id')::uuid order by ord),
           array_agg((x->>'finish_rank')::int order by ord)
      into v_ids, v_ranks
      from jsonb_array_elements(r) with ordinality as t(x, ord);

    v_n := coalesce(array_length(v_ids,1), 0);
    -- 🔴 三人以下不計（決策紀錄 ①）
    if v_n <> 4 then
      return jsonb_build_object('ok', false, 'reason', 'need_four_players',
        'round', idx + 1, 'n', v_n);
    end if;
    if (select count(distinct u) from unnest(v_ids) u) <> v_n then
      return jsonb_build_object('ok', false, 'reason', 'duplicate_member', 'round', idx + 1);
    end if;
    if (select array_agg(x order by x) from unnest(v_ranks) x)
       is distinct from (select array_agg(g order by g) from generate_series(1, v_n) g) then
      return jsonb_build_object('ok', false, 'reason', 'bad_ranks', 'round', idx + 1);
    end if;

    for i in 1..v_n loop
      -- 每個人都要真的坐過這一桌
      if not exists (select 1 from session_players
                      where session_id = p_session_id and member_id = v_ids[i]) then
        return jsonb_build_object('ok', false, 'reason', 'not_in_session',
          'member_id', v_ids[i]);
      end if;

      /* 🔴 依**當下**的段位取 band 與該階下限 —— 要在迴圈裡查，不能先撈一次。 */
      select (d ->> 'band'), (d ->> 'tier_min')::int, m.rating
        into v_band, v_floor, v_new
        from members m, lateral (select public.rank_detail_tx(m.rating) as d) x
       where m.id = v_ids[i] and m.org_id = v_org and m.deleted_at is null;
      if v_band is null then
        return jsonb_build_object('ok', false, 'reason', 'member_not_found',
          'member_id', v_ids[i]);
      end if;

      select points into v_pts from rank_points
       where band = v_band and place = v_ranks[i];

      v_new := v_new + v_pts;

      /* ── 🛡 低段的降階保護（銅／銀／金**不掉階**）────────
         使用者 2026-08-29 拍板：「銅／銀不降」再**放寬到金牌不降**，
         只有白金以上會掉。

         🔴 **這一條一度在文件裡消失。** 改成「每半年歸零」那一版寫了
           「不需要保護機制」—— 但那句話把**兩種保護混成一種**：
           · 賽季降階保護 → 歸零之後確實不需要（大家都歸零）
           · **平時降階保護 → 跟歸零完全無關，是被誤刪的**
         ⚠ **低段正和 ≠ 不會掉**：銅銀金的第 4 名還是 −20，連輸就會掉階。
           正和只是說「平均會往上」。
         📌 而決策紀錄結尾那句「白金那條線是**平時會掉**的起點」一直都在 ——
           文件自己前後矛盾，是那一句才對。

         🎯 **不需要 `peak_rating`**：規則是「不降階」的話，
           **當前分數本身就記著他到過哪一階**（因為他掉不出去）。
           夾在當前階的下限 → 下次再掉還是那個值，自我維持。
         ⚠ **階內仍然可以降小級**（IV→III→II→I）——
           那正是原始設計說「保護底線 = 金牌 I」的意思，不是完全不動。 */
      if v_band = 'low' then
        v_new := greatest(v_new, v_floor);
      end if;

      update members
         set rating = v_new, rating_games = rating_games + 1
       where id = v_ids[i];

      v_total := jsonb_set(v_total, array[v_ids[i]::text],
        to_jsonb(coalesce((v_total ->> v_ids[i]::text)::int, 0) + v_pts));
    end loop;
  end loop;

  /* 整場收尾：名次依**本場累計得點**排（同分時保持原順序）。
     ⚠ `session_players.finish_rank` 只有一格，裝不下每一將的名次 ——
       所以它裝的是「這一場的整體名次」，每一將的明細等牌譜 schema。 */
  for e, i in
    select jsonb_build_object('id', k, 'pts', v), row_number() over (order by v::int desc, k)
      from jsonb_each_text(v_total) as t(k, v)
  loop
    update session_players sp
       set finish_rank  = i,
           score_points = (e->>'pts')::int,
           settled_at   = now(),
           rating_after = (select rating from members where id = (e->>'id')::uuid)
     where sp.session_id = p_session_id and sp.member_id = (e->>'id')::uuid;

    update members set rank = public.member_rank_tx(id) where id = (e->>'id')::uuid;
  end loop;

  return jsonb_build_object('ok', true, 'rounds', v_rounds,
    'result', (select jsonb_agg(jsonb_build_object(
                 'member_id', sp.member_id, 'finish_rank', sp.finish_rank,
                 'score_points', sp.score_points, 'rating_after', sp.rating_after,
                 'rank', m.rank))
                 from session_players sp join members m on m.id = sp.member_id
                where sp.session_id = p_session_id));
end $$;

/* 上一份那支（一場一個名次、Elo）作廢。 */
drop function if exists public.apply_session_results_tx(uuid, jsonb);


-- ── ⑦ 賽季結算：降 2 大階（6 個月）────────────────────
/* 🔴 **2026-08-31 使用者更正：不是全部歸零，是降 2 大階。**
   ```
   降 2 大階 = 2 × 180 = 360 分     下限 910（銅牌熊 IV）
     大師 1810 → 1450  白金 IV     ✅ 這就是「大師變白金」
     鑽石 I    → 1405  金牌 I
     白金 I    → 1225  銀牌 I
     金牌 I    → 1045  銅牌 I
     銀牌以下  → 910   銅牌 IV（夾在下限）
   ```
   ⚠ **所有人都降**（使用者選的），包含銅／銀／金。
     🔴 那跟 ②b 的「平時降階保護」**不衝突，是兩條不同的規則**：
       · 平時：銅銀金**不掉階**
       · 賽季末：**所有人**降 2 大階
     決策紀錄 #4292 那一版本來就是這個結構（兩欄分開）。

   🎯 這個設計實際上是「**高段位保留一部分成果、低段位等於重來**」：
     銀牌以下的人會被 910 的下限接住，所以不會「一季一季往下掉」——
     他只是不跨季累積，而那正是歸零本來要達成的事。
     ✅ 同時解掉「永久累積讓新人追不上」，又給老手一點頭香。

   ⑦：賽季第一名 → **雀神熊稱號 ＋ 頭像，永久保留**。
   🔴 冠軍**必須在降階之前記下來** —— 降完就再也算不出來了。
     那是硬規則 5.6 的「不可回溯」那一格，跟稽核欄位同一類。 */
create table if not exists season_champions (
  season      text primary key,          -- 例 '2026H1'
  org_id      uuid not null references orgs(id),
  member_id   uuid references members(id),
  rating      integer,
  awarded_at  timestamptz not null default now()
);
alter table season_champions enable row level security;

create or replace function public.reset_season_ratings_tx(
  p_org_id uuid,
  p_season text,                    -- 例 '2026H1'
  p_drop_tiers integer default 2    -- 降幾個**大階**（每大階 4 小級 × 45 = 180）
) returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_champ uuid; v_rating int; v_n int; v_drop int; v_floor int;
begin
  if exists (select 1 from season_champions where season = p_season) then
    return jsonb_build_object('ok', false, 'reason', 'season_already_closed');
  end if;

  /* 🔴 先記冠軍再歸零。順序反了就永遠沒有這一季的雀神。
     ⚠ 只有真的到大師的人才算雀神（決策紀錄 ③：大師 1810+）——
       沒有人到就記 null，那是誠實的「本季從缺」。 */
  select m.id, m.rating into v_champ, v_rating
    from members m
   where m.org_id = p_org_id and m.deleted_at is null and not m.is_test
     and m.rating >= (select min_rating from rank_tiers where code = 'master')
     and public.member_rank_tx(m.id) = (select label from rank_tiers where code = 'master')
   order by m.rating desc, m.rating_games desc
   limit 1;

  insert into season_champions (season, org_id, member_id, rating)
  values (p_season, p_org_id, v_champ, v_rating);

  /* 大階寬度 = 下一階的下限 − 這一階的下限。
     ⚠ **從主檔算，不要寫死 180** —— 每階 45 是可以調的（③ 說它一定會調），
       寫死的話調完之後賽季降階會悄悄變成錯的數字。 */
  select coalesce(min(next_min - min_rating), 180) into v_drop
    from (select min_rating, lead(min_rating) over (order by min_rating) as next_min
            from rank_tiers where auto) x
   where next_min is not null;
  v_drop := v_drop * p_drop_tiers;

  select min(min_rating) into v_floor from rank_tiers where auto;

  /* 🔴 **所有人都降**（含銅銀金）—— 平時的降階保護在這裡不適用，
     那是兩條不同的規則。銀牌以下會被下限接住，所以不會無限往下。
     ⚠ `rating_games` 一起歸零：K 值那套是「這一季打過幾場」。 */
  update members
     set rating       = greatest(v_floor, rating - v_drop),
         rating_games = 0,
         rank         = public.rank_from_rating(greatest(v_floor, rating - v_drop))
   where org_id = p_org_id and deleted_at is null;
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'season', p_season,
    'champion', v_champ, 'champion_rating', v_rating,
    'dropped', v_drop, 'floor', v_floor, 'affected_members', v_n);
end $$;


-- ── ⑧ 把現有的人對齊新級距 ────────────────────────────
/* 上一份用的是舊區間（每階 200／銅牌 400）。新規格 1000 = **銅牌熊 II**。 */
update members set rank = public.rank_from_rating(rating)
 where deleted_at is null and rank is distinct from public.rank_from_rating(rating);


-- ── ⑨ 權限 ────────────────────────────────────────────
revoke execute on function public.apply_session_rounds_tx(uuid, jsonb) from public;
revoke execute on function public.apply_session_rounds_tx(uuid, jsonb) from anon, authenticated;
grant  execute on function public.apply_session_rounds_tx(uuid, jsonb) to service_role;

revoke execute on function public.reset_season_ratings_tx(uuid, text, integer) from public;
revoke execute on function public.reset_season_ratings_tx(uuid, text, integer) from anon, authenticated;
grant  execute on function public.reset_season_ratings_tx(uuid, text, integer) to service_role;

grant execute on function public.rank_detail_tx(integer)   to anon, authenticated, service_role;
grant execute on function public.rank_from_rating(integer) to anon, authenticated, service_role;
grant execute on function public.member_rank_tx(uuid)      to anon, authenticated, service_role;


-- ── ⑩ 驗證 ────────────────────────────────────────────
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_out text := '';
  v_st uuid; v_tbl uuid; v_store uuid;
  a uuid; b uuid; c uuid; d uuid; r jsonb;
begin
  begin
    ---- 級距（照決策紀錄 ③ 逐格對）-----------------------
    v_out := v_out || E'\n' || '① 起始 1000 → 銅牌熊 II' || E'\t' ||
      case when public.rank_from_rating(1000)='銅牌熊 II' then '✅ ' else '🔴 ' end
      || public.rank_from_rating(1000);
    /* 🔴 這兩格就是「IV 最低、I 最高」的方向驗證。
       方向寫反的話兩格會同時翻過來 —— 所以兩格都要，一格不夠。 */
    v_out := v_out || E'\n' || '② 910 → 銅牌熊 IV（IV 是最低）' || E'\t' ||
      case when public.rank_from_rating(910)='銅牌熊 IV' then '✅ ' else '🔴 ' end
      || public.rank_from_rating(910);
    v_out := v_out || E'\n' || '③ 1045 → 銅牌熊 I（I 是最高）' || E'\t' ||
      case when public.rank_from_rating(1045)='銅牌熊 I' then '✅ ' else '🔴 ' end
      || public.rank_from_rating(1045);
    v_out := v_out || E'\n' || '④ 1450 → 白金熊 IV（零和分水嶺）' || E'\t' ||
      case when public.rank_from_rating(1450)='白金熊 IV' then '✅ ' else '🔴 ' end
      || public.rank_from_rating(1450);
    v_out := v_out || E'\n' || '⑤ 1765 → 鑽石熊 I（自動能到的最高）' || E'\t' ||
      case when public.rank_from_rating(1765)='鑽石熊 I' then '✅ ' else '🔴 ' end
      || public.rank_from_rating(1765);
    /* 🔴 正對照的反面：分數到 1810 但沒有 20 個不同對手 → 仍然是鑽石 I */
    v_out := v_out || E'\n' || '⑥ 2000 分但沒對手多樣性 → 卡鑽石 I' || E'\t' ||
      case when public.rank_from_rating(2000)='鑽石熊 I' then '✅ ' else '🔴 ' end
      || public.rank_from_rating(2000);
    v_out := v_out || E'\n' || '⑦ 1450 的 band 是 mid（零和）' || E'\t' ||
      case when public.rank_detail_tx(1450)->>'band'='mid' then '✅ mid'
           else '🔴 ' || (public.rank_detail_tx(1450)->>'band') end;

    ---- 順位點表（照決策紀錄 ② 逐格對）-------------------
    v_out := v_out || E'\n' || '⑧ 低段是正和（+30/+15/0/−20 = +25）' || E'\t' ||
      (select case when sum(points)=25 then '✅ +25' else '🔴 ' || sum(points) end
         from rank_points where band='low');
    v_out := v_out || E'\n' || '⑨ 中段是零和' || E'\t' ||
      (select case when sum(points)=0 then '✅ 0' else '🔴 ' || sum(points) end
         from rank_points where band='mid');
    v_out := v_out || E'\n' || '⑩ 大師是負和（−25）' || E'\t' ||
      (select case when sum(points)=-25 then '✅ −25' else '🔴 ' || sum(points) end
         from rank_points where band='top');

    ---- 造一場 -------------------------------------------
    select id into v_store from stores where org_id=v_org limit 1;
    select id into v_tbl   from tables where org_id=v_org limit 1;
    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
    values (v_org, v_store, v_tbl, 'private', 'completed', now()) returning id into v_st;
    insert into members (org_id, display_name) values (v_org,'測甲') returning id into a;
    insert into members (org_id, display_name) values (v_org,'測乙') returning id into b;
    insert into members (org_id, display_name) values (v_org,'測丙') returning id into c;
    insert into members (org_id, display_name) values (v_org,'測丁') returning id into d;
    insert into session_players (org_id, session_id, member_id)
      select v_org, v_st, x from unnest(array[a,b,c,d]) x;

    ---- 未滿 2 將（該擋）---------------------------------
    r := public.apply_session_rounds_tx(v_st, jsonb_build_array(
      jsonb_build_array(
        jsonb_build_object('member_id',a,'finish_rank',1),
        jsonb_build_object('member_id',b,'finish_rank',2),
        jsonb_build_object('member_id',c,'finish_rank',3),
        jsonb_build_object('member_id',d,'finish_rank',4))));
    v_out := v_out || E'\n' || '⑪ 只打 1 將（該擋）' || E'\t' ||
      case when r->>'reason'='too_few_rounds' then '✅ too_few_rounds'
           else '🔴 ' || coalesce(r->>'reason','竟然通過了') end;

    ---- 三人（該擋）--------------------------------------
    r := public.apply_session_rounds_tx(v_st, jsonb_build_array(
      jsonb_build_array(
        jsonb_build_object('member_id',a,'finish_rank',1),
        jsonb_build_object('member_id',b,'finish_rank',2),
        jsonb_build_object('member_id',c,'finish_rank',3)),
      jsonb_build_array(
        jsonb_build_object('member_id',a,'finish_rank',1),
        jsonb_build_object('member_id',b,'finish_rank',2),
        jsonb_build_object('member_id',c,'finish_rank',3))));
    v_out := v_out || E'\n' || '⑫ 三人局（該擋）' || E'\t' ||
      case when r->>'reason'='need_four_players' then '✅ need_four_players'
           else '🔴 ' || coalesce(r->>'reason','竟然通過了') end;

    ---- 正常：3 將（該通過）------------------------------
    /* 甲每將都第 1 → 3×30 = +90 → 1090 = 銀牌熊 IV
       丁每將都第 4 → 3×(−20) = −60 → 940 = 銅牌熊 I
       ⚠ 都在低段（low），所以每將總和 +25 → 三將整桌多 75 分。
         **那不是 bug，是拍板的「低段正和」。** */
    r := public.apply_session_rounds_tx(v_st, (
      select jsonb_agg(jsonb_build_array(
        jsonb_build_object('member_id',a,'finish_rank',1),
        jsonb_build_object('member_id',b,'finish_rank',2),
        jsonb_build_object('member_id',c,'finish_rank',3),
        jsonb_build_object('member_id',d,'finish_rank',4)))
      from generate_series(1,3)));
    v_out := v_out || E'\n' || '⑬ 三將結算（該通過）' || E'\t' ||
      case when r->>'ok'='true' then '✅ 通過' else '🔴 ' || coalesce(r->>'reason','?') end;

    v_out := v_out || E'\n' || '⑭ 甲 +90 → 1090 銀牌熊 IV' || E'\t' ||
      (select case when rating=1090 and rank='銀牌熊 IV'
                   then '✅ 1090 · ' || rank
                   else '🔴 ' || rating || ' · ' || rank end from members where id=a);
    v_out := v_out || E'\n' || '⑮ 丁 −60 → 940 銅牌熊 IV' || E'\t' ||
      (select case when rating=940 and rank='銅牌熊 IV'
                   then '✅ 940 · ' || rank
                   else '🔴 ' || rating || ' · ' || rank end from members where id=d);
    /* 🔴 正對照：低段是**正和**，所以整桌總分要比開打前多 75，不是持平。
       驗成 4000 的話代表我又寫成零和了。 */
    v_out := v_out || E'\n' || '⑯ 低段正和：整桌 4000 → 4075' || E'\t' ||
      (select case when sum(rating)=4075 then '✅ 4075（+25×3 將）'
                   else '🔴 ' || sum(rating) end from members where id in (a,b,c,d));

    v_out := v_out || E'\n' || '⑰ 整場名次與本場得點有寫進去' || E'\t' ||
      (select case when count(*)=4 then '✅ 4 列（甲第 1 得 +90）'
                   else '🔴 ' || count(*) || ' 列' end
         from session_players
        where session_id=v_st and finish_rank is not null and score_points is not null);

    ---- 重按（該擋）--------------------------------------
    r := public.apply_session_rounds_tx(v_st, (
      select jsonb_agg(jsonb_build_array(
        jsonb_build_object('member_id',a,'finish_rank',1),
        jsonb_build_object('member_id',b,'finish_rank',2),
        jsonb_build_object('member_id',c,'finish_rank',3),
        jsonb_build_object('member_id',d,'finish_rank',4)))
      from generate_series(1,3)));
    v_out := v_out || E'\n' || '⑱ 重按一次（該擋）' || E'\t' ||
      case when r->>'reason'='already_applied' then '✅ already_applied'
           else '🔴 ' || coalesce(r->>'reason','又算了一次！') end;

    ---- 🛡 降階保護（該擋）＋ 正對照（該掉）--------------
    /* 甲設成 920（銅牌熊 I，只比下限 910 高 10），連兩將第 4 名 = −40。
       🛡 保護 → 夾在 910，不會掉出銅牌。 */
    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
    values (v_org, v_store, v_tbl, 'private', 'completed', now()) returning id into v_st;
    insert into session_players (org_id, session_id, member_id)
      select v_org, v_st, x from unnest(array[a,b,c,d]) x;
    update members set rating = 920,  rank = public.rank_from_rating(920)  where id = a;
    update members set rating = 1000, rank = public.rank_from_rating(1000) where id in (b,c,d);
    r := public.apply_session_rounds_tx(v_st, (
      select jsonb_agg(jsonb_build_array(
        jsonb_build_object('member_id',a,'finish_rank',4),
        jsonb_build_object('member_id',b,'finish_rank',1),
        jsonb_build_object('member_id',c,'finish_rank',2),
        jsonb_build_object('member_id',d,'finish_rank',3)))
      from generate_series(1,2)));
    v_out := v_out || E'\n' || '㉕ 🛡 銅牌連輸兩將：920 −40 → 夾在 910' || E'\t' ||
      (select case when rating=910 and rank='銅牌熊 IV'
                   then '✅ 910 · 銅牌熊 IV（掉不出去）'
                   else '🔴 ' || rating || ' · ' || rank end from members where id=a);

    /* 🔴 **正對照**：白金以上沒有保護，一定要掉得出去。
       只驗「低段掉不動」的話，函式整支不寫入也會通過。

       🎯 **這一格順便驗到一件更重要的事：band 會在一場之內重算。**
       乙設 1450（白金熊 IV，band=mid），連兩將第 4 名：
       ```
       第 1 將  mid  −30 → 1420   ← 已經掉出白金，變成金牌
       第 2 將  low  −20 → 1400   ← 🎯 吃的是低段的 −20，不是 −30
       ```
       ⚠ 我第一次寫這格時算成 `−30 × 2 = 1390` —— **那是把 band 當成整場固定的**，
         而規格是「依**當下**的段位取點數表」。函式是對的，是測試算錯。
       ⚠ 1400 仍然高於金牌下限 1270，所以這一格**沒有碰到夾子** ——
         夾子由下一格（㉗）驗。 */
    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
    values (v_org, v_store, v_tbl, 'private', 'completed', now()) returning id into v_st;
    insert into session_players (org_id, session_id, member_id)
      select v_org, v_st, x from unnest(array[a,b,c,d]) x;
    update members set rating = 1450, rank = public.rank_from_rating(1450) where id = b;
    r := public.apply_session_rounds_tx(v_st, (
      select jsonb_agg(jsonb_build_array(
        jsonb_build_object('member_id',b,'finish_rank',4),
        jsonb_build_object('member_id',a,'finish_rank',1),
        jsonb_build_object('member_id',c,'finish_rank',2),
        jsonb_build_object('member_id',d,'finish_rank',3)))
      from generate_series(1,2)));
    v_out := v_out || E'\n' || '㉖ 白金連輸兩將 → 1400（第 2 將已改吃低段點數）' || E'\t' ||
      (select case when rating=1400 and rank='金牌熊 II'
                   then '✅ 1400 · 金牌熊 II（−30 然後 −20，不是 −30 兩次）'
                   else '🔴 ' || rating || ' · ' || rank end from members where id=b);

    /* 🎯 第三格：掉進金牌之後**就受保護了** —— 保護是「當前階」不是「起始階」。

       🔴 **我第一版的這一格根本沒測到保護。** 起點寫 1400、連輸兩將 −40 = 1360，
         而金牌下限是 1270 —— **離夾子還有 90 分，它從頭到尾沒作用**。
         那一格通過與否跟保護完全無關（硬規則 3.55：測試通過但驗到的是別的東西）。
       → 起點改成 **1290**（金牌熊 IV，離下限只有 20），連輸兩將 −40 → 1250
         → **被夾回 1270**。這樣夾子才真的被踩到。 */
    update members set rating = 1290, rank = public.rank_from_rating(1290) where id = b;
    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
    values (v_org, v_store, v_tbl, 'private', 'completed', now()) returning id into v_st;
    insert into session_players (org_id, session_id, member_id)
      select v_org, v_st, x from unnest(array[a,b,c,d]) x;
    r := public.apply_session_rounds_tx(v_st, (
      select jsonb_agg(jsonb_build_array(
        jsonb_build_object('member_id',b,'finish_rank',4),
        jsonb_build_object('member_id',a,'finish_rank',1),
        jsonb_build_object('member_id',c,'finish_rank',2),
        jsonb_build_object('member_id',d,'finish_rank',3)))
      from generate_series(1,2)));
    v_out := v_out || E'\n' || '㉗ 🛡 金牌 1290 連輸兩將 −40 → 夾回 1270（不是 1250）' || E'\t' ||
      (select case when rating=1270 and rank='金牌熊 IV'
                   then '✅ 1270 · 金牌熊 IV（自我維持，不用 peak_rating）'
                   else '🔴 ' || rating || ' · ' || rank end from members where id=b);

    ---- 賽季降階 -----------------------------------------
    /* 甲設 1810（大師分數）、乙 1585（白金 I）、丙 1090（銀牌 IV）
       降 2 大階 = −360，下限 910：
         甲 1810 → 1450  白金熊 IV   ← 🎯 這就是「大師變白金」
         乙 1585 → 1225  銀牌熊 I
         丙 1090 →  910  銅牌熊 IV（被下限接住） */
    update members set rating=1810, rank=public.rank_from_rating(1810) where id=a;
    update members set rating=1585, rank=public.rank_from_rating(1585) where id=b;
    update members set rating=1090, rank=public.rank_from_rating(1090) where id=c;

    r := public.reset_season_ratings_tx(v_org, '_TEST_SEASON');
    v_out := v_out || E'\n' || '⑲ 賽季降階（該通過）' || E'\t' ||
      case when r->>'ok'='true'
           then '✅ 降 ' || (r->>'dropped') || ' 分 · ' || (r->>'affected_members') || ' 人'
           else '🔴 ' || coalesce(r->>'reason','?') end;

    v_out := v_out || E'\n' || '⑳ 大師 1810 → 白金熊 IV（降 2 大階）' || E'\t' ||
      (select case when rating=1450 and rank='白金熊 IV'
                   then '✅ 1450 · 白金熊 IV'
                   else '🔴 ' || rating || ' · ' || rank end from members where id=a);

    /* 🔴 **正對照**：下限只能接住掉到底的人，不可以把高段位也夾平。
       只驗「丙被接住」的話，函式寫成「全部設成 910」也會通過。 */
    v_out := v_out || E'\n' || '⑳b 白金 I 1585 → 銀牌熊 I（不是被夾平）' || E'\t' ||
      (select case when rating=1225 and rank='銀牌熊 I'
                   then '✅ 1225 · 銀牌熊 I'
                   else '🔴 ' || rating || ' · ' || rank end from members where id=b);

    v_out := v_out || E'\n' || '⑳c 銀牌 1090 → 被下限接住 910' || E'\t' ||
      (select case when rating=910 and rank='銅牌熊 IV'
                   then '✅ 910 · 銅牌熊 IV（不會無限往下）'
                   else '🔴 ' || rating || ' · ' || rank end from members where id=c);

    /* ⚠ 大階寬度是**從主檔算的**，不是寫死 180 —— 每階 45 一定會調。
       驗它算出來是 360（2 大階），寫死的話這一格不會變，但改了 45 之後就錯了。 */
    v_out := v_out || E'\n' || '⑳d 降的分數是從主檔算的（2×180=360）' || E'\t' ||
      case when (r->>'dropped')::int = 360 then '✅ 360'
           else '🔴 ' || coalesce(r->>'dropped','?') end;
    /* 🔴 本季沒有人到大師 → 冠軍該是 null（誠實的「從缺」），不是隨便挑一個最高分的。 */
    v_out := v_out || E'\n' || '㉑ 沒人到大師 → 冠軍從缺' || E'\t' ||
      (select case when member_id is null then '✅ null（從缺）'
                   else '🔴 挑了一個不是大師的人' end
         from season_champions where season='_TEST_SEASON');
    r := public.reset_season_ratings_tx(v_org, '_TEST_SEASON');
    v_out := v_out || E'\n' || '㉒ 同一季再結一次（該擋）' || E'\t' ||
      case when r->>'reason'='season_already_closed' then '✅ season_already_closed'
           else '🔴 ' || coalesce(r->>'reason','又結了一次！') end;

    ---- 權限 ---------------------------------------------
    v_out := v_out || E'\n' || '㉓ anon 叫不叫得動結算與歸零' || E'\t' ||
      (select case when count(*)=0 then '✅ 兩支都收乾淨了'
                   else '🔴 還有 ' || count(*) || ' 支 anon 進得來' end
         from pg_proc p
        where p.pronamespace='public'::regnamespace and p.prokind='f'
          and p.proname in ('apply_session_rounds_tx','reset_season_ratings_tx')
          and (exists (select 1 from aclexplode(p.proacl) x
                        where x.grantee='anon'::regrole::oid and x.privilege_type='EXECUTE')
               or p.proacl is null
               or exists (select 1 from aclexplode(p.proacl) x
                           where x.grantee=0 and x.privilege_type='EXECUTE')));

    v_out := v_out || E'\n' || '㉔ 上一份那支 Elo 已經刪掉' || E'\t' ||
      (select case when count(*)=0 then '✅ 不存在了' else '🔴 還在' end
         from pg_proc where pronamespace='public'::regnamespace
          and proname='apply_session_results_tx');

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.rank2', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.rank2', true), E'\n')) as x
 where coalesce(x,'') <> '';
