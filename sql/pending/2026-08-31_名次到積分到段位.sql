/* ============================================================
   名次 → 積分 → 段位　　2026-08-31 · MIGI 咪吉麻將

   使用者：「你先有虛擬排名 1~4，然後就會有積分，有積分就會有段位變化了。」
   → **不做整套牌譜**（那是 M5）。只做這條最短的鏈：
   ```
   每場每人的名次 1–4  →  Elo 分數  →  段位（六階 × I–IV）
   ```

   ── 🎯 動手前撈到的：缺的比想像中少 ────────────────
   | | 現況 |
   |---|---|
   | `session_players.finish_rank` | ✅ **早就存在**（integer） |
   | `chk_finish_rank` | ✅ **早就存在**：`null 或 1..4`（NOT VALID） |
   | `session_players.score_points` / `settled_at` | ✅ 也在 |
   | `get_my_games_tx` | ✅ **已經在讀 finish_rank** —— 成績頁的對局紀錄 |
   | 有名次的列 | 🔴 **0 / 5** —— 沒有任何東西寫它 |
   | `members` 上的積分欄位 | 🔴 **只有 `rank`（文字），沒有分數** |
   | `member_rating` / `season_champions` / `games` | 🔴 三張表都不存在 |
   | 會寫 `members.rank` 的函式 | 🔴 **0 支** —— 所以它從建立以來沒動過 |

   ── 制度依據（`docs/03-會員App與社交/會員分級制度規格.md`）──
   · 六階：銅／銀／金／白金／鑽石／大師熊，前五階各分 **I–IV**（I 最高）
   · **會掉段** —— 那是競技公信力的來源
   · 起始分 **1000**（銅牌熊中段），不從零爬
   · **純娛樂麻將也計段位**（積分級距規格鐵則 3：段位看順位，與玩多大無關）
   · 大師熊要 **norm**（official 賽事認證），不能純靠分數
   ⚠ 文件把「升降門檻、每階區間」標成 **TBD** —— 下面那組數字是**這份提的**，
     而且**刻意做成主檔表**：它一定會調（開幕三個月後發現鑽石熊太多），
     改一個數字就好，不用改函式也不用部署。

   ── 🎯 對照 LOL／傳說對決之後補的兩個欄位 ──────────
   使用者要求拿世界級排位系統檢驗。多數差異（賽季重置、不活躍衰減、
   連勝加成、隱藏 MMR）**現在做反而錯** —— 一個真實客人都還沒有。
   但有兩件是**不可回溯**的（硬規則 5.6 的複利那一格：今天不填，
   這段歷史就永遠沒有）：

   ① **`members.peak_rating`（生涯最高）**
      🔴 **畫面已經承諾了** —— 個人檔案「我的麻將足跡」那一列就寫著
        `銅牌熊 / 生涯最高`。沒有這個欄位的話它只能等於現在的段位，
        也就是**一掉段那個數字就開始說謊**。
        LOL 的 Peak Rank 是玩家最在意的數字之一。

   ② **`session_players.rating_after`（那一場打完是幾分）**
      成績頁要畫段位走勢圖（LOL 的 LP 曲線）就需要它。
      而 `finish_rank` 本來就要寫進那一列，**多寫一個整數是零成本**。

   ⏳ **刻意不做**：定位賽（前 N 場不顯示段位）、降段保護、賽季重置、
     不活躍衰減。前兩個是純規則隨時可加；後兩個要先有人在打才知道參數。

   ── 🔴 為什麼分數放 `members` 而不是新建 `member_rating` ──
   文件裡設計的是一張 `member_rating` 表。今天不建，理由：
   · 今天它只裝**一個整數**，而 `members` 已經有 `rank`（那個整數的顯示名）——
     **分開放的話它們可以不一致，放一起則不可能。**
   · 建一張只有一欄的表，就是第 N 個「建了沒人讀」。
   ⏳ **真的需要它的那一天是「賽季」**：雀神熊每季重置，
     那時要的是 `(member, season)` 兩個鍵，一個欄位裝不下。
     到那時 `members.rating` 會變成「生涯分數」，仍然有意義。

   ── ⚠ 誰能呼叫 ───────────────────────────────────────
   `apply_session_results_tx` **只給 service_role**。
   🔴 名次是**店員登記的事實**，不是客人可以宣告的東西 ——
     讓前端叫得動就等於「自己填自己第一名」。（同待辦 40 的稱號那個病。）
   ⏳ 店員登入（待辦 20）做好之後，POS 收桌時包一層 DEFINER 呼叫它。
   📌 在那之前就是從 Dashboard 手動跑 —— 這正是使用者說的「虛擬排名」。
   ⚠ 這**不是**開發旁路（硬規則 5.7）：它是正式的產品函式，只是還沒有介面。
     旁路是「繞過檢查的另一條路」，這裡沒有第二條路。
   ============================================================ */

-- ── ① 分數欄位 ────────────────────────────────────────
/* ⚠ `rating_games` 不是裝飾：Elo 的 K 值要看打過幾場
   （新手波動大、老手波動小），沒有它就只能全部用同一個 K，
   而那會讓打過 200 場的人被一場翻盤。 */
alter table members
  add column if not exists rating       integer not null default 1000,
  add column if not exists rating_games integer not null default 0,
  add column if not exists peak_rating  integer not null default 1000;

comment on column members.rating is
  '段位分數（類 Elo）。起始 1000＝銅牌熊中段。下限 800，不會再低。';
comment on column members.rating_games is
  '計入段位的場數。只用來決定 K 值，不是「打了幾場」的統計（那個看 session_players）。';
comment on column members.peak_rating is
  '生涯最高分。🔴 只增不減 —— 個人檔案的「生涯最高」讀它。掉段之後它仍然是真的。';

/* ⚠ 這一欄放在 `session_players` 而不是另建一張走勢表：
   那一列本來就代表「這個人在這一場」，分數是那一場的結果之一。 */
alter table session_players
  add column if not exists rating_after integer;
comment on column session_players.rating_after is
  '這一場結算後的段位分數。給成績頁畫走勢用（LOL 的 LP 曲線）。null = 還沒結算。';


-- ── ② 段位區間主檔 ────────────────────────────────────
/* 🎯 **做成資料不是程式碼。** 同 `member_tiers` 的教訓：
   折扣率原本寫在兩支函式裡各一份 case，改一邊忘另一邊就不一致而且不報錯。 */
create table if not exists rank_tiers (
  code        text primary key,
  label       text     not null,
  min_rating  integer  not null,
  sub_count   smallint not null default 4,   -- 分幾個小級（大師熊 = 1，不分）
  auto        boolean  not null default true, -- false = 不由分數自動給（要認證）
  sort        smallint not null,
  note        text
);
alter table rank_tiers enable row level security;
/* ⚠ **刻意 0 條 policy**：它只被 `rank_detail_tx`（DEFINER）讀。
   要給前端看的話另開一支 `list_rank_tiers_tx`，不要開表。 */

insert into rank_tiers (code, label, min_rating, sub_count, auto, sort, note) values
  ('bronze',   '銅牌熊',  800, 4, true,  1,
   '入門。區間刻意比其他階寬（400 分）—— 新手不該一兩場就掉出去'),
  ('silver',   '銀牌熊', 1200, 4, true,  2, null),
  ('gold',     '金牌熊', 1400, 4, true,  3, null),
  ('platinum', '白金熊', 1600, 4, true,  4, null),
  ('diamond',  '鑽石熊', 1800, 4, true,  5, '目前的自動上限 —— 大師熊要認證'),
  ('master',   '大師熊', 2000, 1, false, 6,
   'auto=false：文件明訂大師熊除了分數還要 norm（official 賽事達標 3 次），'
   '而 games.is_official 今天不存在。分數到了也只會停在鑽石熊 I。'
   '那是「還沒做」不是「壞了」—— 有了賽事系統再把 auto 改成 true。')
on conflict (code) do nothing;


-- ── ③ 分數 → 段位（含進度）────────────────────────────
/* 🔴 **小級由區間自己切出來，不另外設定。**
   四個小級 = 把 `[min_rating, 下一階 min_rating)` 平均分四段，**I 是最高的那一段**。
   → 只要調 `min_rating`，小級跟著動，**不可能對不上**。
     另外存一份小級門檻就是第二個真相來源。

   例（目前這組數字）：
   ```
   銅牌熊 800–1199（每級 100）  IV 800  III 900  II 1000  I 1100
   銀牌熊 1200–1399（每級 50）  IV 1200 III 1250 II 1300  I 1350
   ```
   ⇒ **起始分 1000 = 銅牌熊 II**，符合文件說的「銅牌熊中段」。

   ── 🎯 `progress` 是對照 LOL 補的（那是最便宜的一項）──
   LOL 的 LP 進度條是最強的動機來源，而區間資料本來就在主檔裡，
   **多算一個百分比就有**。沒有它的話客人只看得到「金牌熊 III」，
   看不出離下一級還有多遠。

   ⚠ 低於 800 一律當 800（顯示銅牌熊 IV）。分數本身也在 ⑤ 夾住 ——
     掉到 600 跟掉到 800 在畫面上長得一模一樣，
     那個差別只會讓人**永遠爬不回來**而且看不出為什麼。 */
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
    select label, min_rating, sub_count,
           lead(min_rating) over (order by min_rating) as next_min
      from rank_tiers where auto
  ) x
   where v >= x.min_rating
   order by x.min_rating desc limit 1;

  if t.label is null then
    -- 主檔被清空之類的異常。回一個不會讓前端當掉的形狀，而不是 null。
    return jsonb_build_object('rank', '銅牌熊 IV', 'tier', '銅牌熊', 'sub', 'IV',
      'rating', v, 'progress', 0, 'to_next', null, 'at_top', true);
  end if;

  /* ⚠ 最高的自動階（鑽石熊）沒有 next_min，寬度用 200 補 ——
     跟它下面幾階一樣寬。不補的話 step 會是 0 然後除零。 */
  w    := (coalesce(t.next_min, t.min_rating + 200) - t.min_rating)::numeric;
  step := w / t.sub_count;
  idx  := least(t.sub_count, 1 + floor((v - t.min_rating) / step)::int);
  lo   := t.min_rating + (idx - 1) * step;
  hi   := lo + step;

  v_sub := case when t.sub_count <= 1 then null
                else (array['IV','III','II','I'])[idx] end;
  -- 已經在最高階的最高小級 → 沒有下一級可以去（除非認證升大師熊）
  v_top := (t.next_min is null and idx = t.sub_count);

  return jsonb_build_object(
    'rank',     case when v_sub is null then t.label else t.label || ' ' || v_sub end,
    'tier',     t.label,
    'sub',      v_sub,
    'rating',   v,
    -- 本小級內的進度 0–100。⚠ 夾住上限：分數可以超過最高階很多
    'progress', least(100, greatest(0, round((v - lo) / step * 100)))::int,
    -- 還差幾分升下一小級。至頂時是 null（不是 0 —— 0 會被讀成「就快到了」）
    'to_next',  case when v_top then null else ceil(hi - v)::int end,
    'at_top',   v_top
  );
end $$;

/* 🔴 **只有一份實作。** 這一支只是把 `rank_detail_tx` 的 `rank` 取出來 ——
   兩邊各寫一次切小級的算式，就是第二個真相來源，而它們一定會有一天對不上。 */
create or replace function public.rank_from_rating(p_rating integer)
returns text
language sql stable
as $$ select public.rank_detail_tx(p_rating) ->> 'rank' $$;


-- ── ④ 結算一場：寫名次 → 算分 → 更新段位 ──────────────
/* ── Elo 怎麼算多人局 ──────────────────────────────
   四人局不是一對一，所以用**兩兩對戰的平均**（多人 Elo 的標準做法）：
   ```
   對每一個對手 j：  期望 E = 1 / (1 + 10^((Rj - Ri)/400))
                     實得 S = 名次比他好 → 1，比他差 → 0
   Δi = K × Σ(S - E) / (人數 - 1)
   ```
   🎯 這個算法的好處是**贏強者加得多、輸弱者扣得多**，而且
     三人局與四人局用同一條式子（除以人數−1 就自動歸一）。

   K 值：**打過 20 場以內用 32，之後用 16**。
   ⚠ 全部用同一個 K 的話，打過 200 場的人會被一場翻盤 ——
     那讓段位失去「累積實力」的意義。

   ⚠ **名次必須是 1..n 且不重複**（不接受並列）。
     並列在四人麻將裡沒有意義，而允許它會讓 S 出現 0.5，
     那是另一套規則，要就明確設計，不要靠預設行為。

   ⚠ **零和有一個例外：分數下限 800。** 有人被夾住時，
     那一場的總分會比開打前多一點。這是刻意換來的
     （不夾的話掉進深坑的人永遠爬不回來），但要知道它在那裡。 */
create or replace function public.apply_session_results_tx(
  p_session_id uuid,
  p_results    jsonb   -- [{"member_id":"…","finish_rank":1}, …]
) returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_org    uuid;
  v_ids    uuid[];
  v_ranks  int[];
  v_rate   int[] := '{}';
  v_games  int[] := '{}';
  v_delta  int[] := '{}';
  n int; i int; j int;
  v_k numeric; v_s numeric; v_new int; v_r int; v_g int;
  v_out jsonb := '[]'::jsonb;
begin
  select org_id into v_org from table_sessions
   where id = p_session_id and deleted_at is null;
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found');
  end if;

  select array_agg((x->>'member_id')::uuid order by ord),
         array_agg((x->>'finish_rank')::int order by ord)
    into v_ids, v_ranks
    from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) with ordinality as t(x, ord);

  n := coalesce(array_length(v_ids, 1), 0);
  if n < 2 or n > 4 then
    return jsonb_build_object('ok', false, 'reason', 'bad_player_count', 'n', n);
  end if;

  -- 同一個人不可以出現兩次
  if (select count(distinct u) from unnest(v_ids) u) <> n then
    return jsonb_build_object('ok', false, 'reason', 'duplicate_member');
  end if;

  /* 名次必須剛好是 1..n。
     ⚠ 只檢查「不重複」不夠 —— (1,2,4) 也不重複，但那代表少了一個人。 */
  if (select array_agg(x order by x) from unnest(v_ranks) x)
     is distinct from (select array_agg(g order by g) from generate_series(1, n) g) then
    return jsonb_build_object('ok', false, 'reason', 'bad_ranks');
  end if;

  for i in 1..n loop
    -- 這個人一定要真的坐過這一桌
    if not exists (select 1 from session_players
                    where session_id = p_session_id and member_id = v_ids[i]) then
      return jsonb_build_object('ok', false, 'reason', 'not_in_session',
        'member_id', v_ids[i]);
    end if;

    /* 冪等：已經結算過就不要再算一次。
       🔴 沒有這一道的話，重按一次會**再扣一次分**，
         而那完全看不出來 —— 分數本來就會動。 */
    if exists (select 1 from session_players
                where session_id = p_session_id and member_id = v_ids[i]
                  and finish_rank is not null) then
      return jsonb_build_object('ok', false, 'reason', 'already_applied');
    end if;

    select rating, rating_games into v_r, v_g
      from members where id = v_ids[i] and org_id = v_org and deleted_at is null;
    if v_r is null then
      return jsonb_build_object('ok', false, 'reason', 'member_not_found',
        'member_id', v_ids[i]);
    end if;
    v_rate  := array_append(v_rate, v_r);
    v_games := array_append(v_games, v_g);
  end loop;

  /* 先全部算完再寫 —— 不然前面的人更新後的分數會影響後面的人的期望值，
     而那等於「名次填寫的順序會改變結果」。 */
  for i in 1..n loop
    v_k := case when v_games[i] < 20 then 32 else 16 end;
    v_s := 0;
    for j in 1..n loop
      if i <> j then
        v_s := v_s
             + (case when v_ranks[i] < v_ranks[j] then 1.0 else 0.0 end)
             - 1.0 / (1.0 + power(10.0, (v_rate[j] - v_rate[i])::numeric / 400.0));
      end if;
    end loop;
    v_delta := array_append(v_delta, round(v_k * v_s / (n - 1))::int);
  end loop;

  for i in 1..n loop
    v_new := greatest(800, v_rate[i] + v_delta[i]);   -- ⚠ 下限見上面的說明

    update session_players
       set finish_rank = v_ranks[i], settled_at = now(), rating_after = v_new
     where session_id = p_session_id and member_id = v_ids[i];

    update members
       set rating       = v_new,
           rating_games = v_games[i] + 1,
           -- 🔴 生涯最高只增不減 —— 那正是它跟 rating 的差別
           peak_rating  = greatest(coalesce(peak_rating, 1000), v_new),
           rank         = public.rank_from_rating(v_new)
     where id = v_ids[i];

    v_out := v_out || jsonb_build_object(
      'member_id', v_ids[i], 'finish_rank', v_ranks[i],
      'rating_before', v_rate[i], 'delta', v_delta[i], 'rating_after', v_new,
      'rank', public.rank_from_rating(v_new));
  end loop;

  return jsonb_build_object('ok', true, 'players', v_out);
end $$;


-- ── ⑤ 既有會員的段位對齊分數 ──────────────────────────
/* 🔴 現在每個人都是 `'銅牌熊 I'`（欄位預設值），
   而 rating 1000 對應的是 **銅牌熊 II** —— 不對齊的話，
   第一場打完分數只動一點點，段位卻會「莫名其妙掉一級」。
   ⚠ 那種掉級是**這次回填造成的**，不是他打輸的，
     但客人看到的是「我打了一場就掉段」。 */
update members set rank = public.rank_from_rating(rating)
 where deleted_at is null and rank is distinct from public.rank_from_rating(rating);


-- ── ⑥ 權限 ────────────────────────────────────────────
/* 🔴 硬規則 2.6 ＋ 2.6b：**兩個方向都要收**（PUBLIC 繼承 ＋ 明確授權）。 */
revoke execute on function public.apply_session_results_tx(uuid, jsonb) from public;
revoke execute on function public.apply_session_results_tx(uuid, jsonb) from anon, authenticated;
grant  execute on function public.apply_session_results_tx(uuid, jsonb) to service_role;

/* ⚠ 這兩支**刻意留給 anon**：它們只做一件事 —— 把一個整數換成段位。
   沒有會員資料、沒有 PII、拿不到任何別人的東西。
   📌 明著 grant 是因為「沒有明講的預設」正是硬規則 2.6b 那個坑的來源。 */
grant execute on function public.rank_detail_tx(integer)   to anon, authenticated, service_role;
grant execute on function public.rank_from_rating(integer) to anon, authenticated, service_role;


-- ── ⑦ 驗證（交易內造資料 → 測 → 回滾）────────────────
/* 🔴 **每一道擋牆都配一個正對照**（硬規則 3.55）——
   「該擋的擋了」與「函式整支壞了」長得一模一樣。 */
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_out text := '';
  v_st uuid; v_tbl uuid; v_store uuid;
  a uuid; b uuid; c uuid; d uuid;
  r jsonb;
begin
  begin
    ---- 段位對照（純函式，不用造資料）------------------------
    v_out := v_out || E'\n' || '① 起始 1000 → 銅牌熊 II' || E'\t' ||
      case when public.rank_from_rating(1000) = '銅牌熊 II' then '✅ ' else '🔴 ' end
      || public.rank_from_rating(1000);

    v_out := v_out || E'\n' || '② 1450 → 金牌熊 III' || E'\t' ||
      case when public.rank_from_rating(1450) = '金牌熊 III' then '✅ ' else '🔴 ' end
      || public.rank_from_rating(1450);

    v_out := v_out || E'\n' || '③ 500（低於下限）→ 銅牌熊 IV' || E'\t' ||
      case when public.rank_from_rating(500) = '銅牌熊 IV' then '✅ ' else '🔴 ' end
      || public.rank_from_rating(500);

    /* 🔴 這一格是**正對照的反面**：大師熊 auto=false，
       所以分數再高也只到鑽石熊 I。回「大師熊」代表 auto 沒被尊重。 */
    v_out := v_out || E'\n' || '④ 2500（大師熊要認證）→ 鑽石熊 I' || E'\t' ||
      case when public.rank_from_rating(2500) = '鑽石熊 I' then '✅ ' else '🔴 ' end
      || public.rank_from_rating(2500);

    ---- 進度條（對照 LOL 補的那一項）--------------------------
    /* 1000 在銅牌熊 II（1000–1099），剛好在起點 → 進度 0、還差 100 分。 */
    v_out := v_out || E'\n' || '⑤ 1000 的進度：0% · 還差 100' || E'\t' ||
      case when (public.rank_detail_tx(1000)->>'progress')::int = 0
            and (public.rank_detail_tx(1000)->>'to_next')::int = 100
           then '✅ 0 / 100'
           else '🔴 ' || (public.rank_detail_tx(1000)->>'progress')
                || ' / ' || coalesce(public.rank_detail_tx(1000)->>'to_next','null') end;

    /* 1050 在銅牌熊 II 的正中間 → 50%。 */
    v_out := v_out || E'\n' || '⑥ 1050 的進度：50%' || E'\t' ||
      case when (public.rank_detail_tx(1050)->>'progress')::int = 50
           then '✅ 50%' else '🔴 ' || (public.rank_detail_tx(1050)->>'progress') || '%' end;

    /* 🔴 至頂時 `to_next` 必須是 **null 不是 0** ——
       0 會被畫成「就快到了」，而實際是「這條路到此為止」。 */
    v_out := v_out || E'\n' || '⑦ 2500 至頂：to_next 是 null' || E'\t' ||
      case when public.rank_detail_tx(2500)->>'to_next' is null
            and (public.rank_detail_tx(2500)->>'at_top')::boolean
           then '✅ null ＋ at_top'
           else '🔴 ' || coalesce(public.rank_detail_tx(2500)->>'to_next','?') end;

    ---- 造一場四人局 ------------------------------------------
    select id into v_store from stores where org_id = v_org limit 1;
    select id into v_tbl   from tables where org_id = v_org limit 1;
    /* ⚠ 三個座標都是查證過的，不是猜的：
         · **沒有 `opened_at` 這個欄位**，是 `started_at`（而且有預設）
         · `mode` 是 NOT NULL 且沒預設，允許值只有 matched / private
       🔴 · `uq_sessions_open_table` 是 `(table_id) WHERE status='open'` 的部分唯一索引
           —— **同一張桌不能有兩個 open 場次**，而下面還要再造一場三人局。
           所以直接建 completed，**而那也比較像真的**：
           登記名次本來就是打完之後的事。 */
    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
    values (v_org, v_store, v_tbl, 'private', 'completed', now()) returning id into v_st;

    insert into members (org_id, display_name) values (v_org,'測甲') returning id into a;
    insert into members (org_id, display_name) values (v_org,'測乙') returning id into b;
    insert into members (org_id, display_name) values (v_org,'測丙') returning id into c;
    insert into members (org_id, display_name) values (v_org,'測丁') returning id into d;
    insert into session_players (org_id, session_id, member_id)
      select v_org, v_st, x from unnest(array[a,b,c,d]) x;

    ---- 名次不合法（該擋）------------------------------------
    r := public.apply_session_results_tx(v_st, jsonb_build_array(
      jsonb_build_object('member_id',a,'finish_rank',1),
      jsonb_build_object('member_id',b,'finish_rank',2),
      jsonb_build_object('member_id',c,'finish_rank',2),
      jsonb_build_object('member_id',d,'finish_rank',4)));
    v_out := v_out || E'\n' || '⑧ 名次重複（該擋）' || E'\t' ||
      case when r->>'reason' = 'bad_ranks' then '✅ bad_ranks'
           else '🔴 ' || coalesce(r->>'reason','竟然通過了') end;

    r := public.apply_session_results_tx(v_st, jsonb_build_array(
      jsonb_build_object('member_id',a,'finish_rank',1),
      jsonb_build_object('member_id',b,'finish_rank',2),
      jsonb_build_object('member_id',c,'finish_rank',3),
      jsonb_build_object('member_id',d,'finish_rank',5)));
    v_out := v_out || E'\n' || '⑨ 名次跳號 1/2/3/5（該擋）' || E'\t' ||
      case when r->>'reason' = 'bad_ranks' then '✅ bad_ranks'
           else '🔴 ' || coalesce(r->>'reason','竟然通過了') end;

    ---- 正常結算（該通過）------------------------------------
    r := public.apply_session_results_tx(v_st, jsonb_build_array(
      jsonb_build_object('member_id',a,'finish_rank',1),
      jsonb_build_object('member_id',b,'finish_rank',2),
      jsonb_build_object('member_id',c,'finish_rank',3),
      jsonb_build_object('member_id',d,'finish_rank',4)));
    v_out := v_out || E'\n' || '⑩ 四人同分結算（該通過）' || E'\t' ||
      case when r->>'ok' = 'true' then '✅ 通過' else '🔴 ' || coalesce(r->>'reason','?') end;

    /* 同分四人 → 第 1 名 +16、第 4 名 −16（K=32，兩兩期望都是 0.5）。
       ⚠ 這個數字是**算得出來的**不是抄回傳值：
         第 1 名贏 3 場，Σ(S−E) = 3 × 0.5 = 1.5，Δ = 32 × 1.5 / 3 = 16。 */
    v_out := v_out || E'\n' || '⑪ 同分局：第 1 名 +16、第 4 名 −16' || E'\t' ||
      (select case when (select rating from members where id=a) = 1016
                    and (select rating from members where id=d) = 984
                   then '✅ 1016 / 984'
                   else '🔴 ' || (select rating from members where id=a) || ' / '
                        || (select rating from members where id=d) end);

    v_out := v_out || E'\n' || '⑫ 加總是不是零和' || E'\t' ||
      (select case when sum(rating) = 4000 then '✅ 4000（沒有憑空生出分數）'
                   else '🔴 ' || sum(rating) end
         from members where id in (a,b,c,d));

    v_out := v_out || E'\n' || '⑬ 名次有沒有寫進 session_players' || E'\t' ||
      (select case when count(*) = 4 then '✅ 4 列都有名次與分數'
                   else '🔴 只有 ' || count(*) || ' 列' end
         from session_players
        where session_id = v_st and finish_rank is not null and rating_after is not null);

    v_out := v_out || E'\n' || '⑭ 段位有沒有跟著動' || E'\t' ||
      (select case when rank = public.rank_from_rating(rating)
                   then '✅ ' || rank || '（' || rating || ' 分）'
                   else '🔴 rank=' || rank || ' 但分數是 ' || rating end
         from members where id = a);

    /* 🔴 生涯最高：第 1 名升到 1016 → peak 跟著上去；
       第 4 名掉到 984 → **peak 必須留在 1000**，那正是它存在的意義。 */
    v_out := v_out || E'\n' || '⑮ 生涯最高：贏家跟著漲、輸家不倒退' || E'\t' ||
      (select case when (select peak_rating from members where id=a) = 1016
                    and (select peak_rating from members where id=d) = 1000
                   then '✅ 1016 / 1000'
                   else '🔴 ' || (select peak_rating from members where id=a) || ' / '
                        || (select peak_rating from members where id=d) end);

    ---- 重複結算（該擋）--------------------------------------
    r := public.apply_session_results_tx(v_st, jsonb_build_array(
      jsonb_build_object('member_id',a,'finish_rank',1),
      jsonb_build_object('member_id',b,'finish_rank',2),
      jsonb_build_object('member_id',c,'finish_rank',3),
      jsonb_build_object('member_id',d,'finish_rank',4)));
    v_out := v_out || E'\n' || '⑯ 重按一次（該擋）' || E'\t' ||
      case when r->>'reason' = 'already_applied' then '✅ already_applied'
           else '🔴 ' || coalesce(r->>'reason','又算了一次！') end;

    ---- 三人局也要能跑（正對照）------------------------------
    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
    values (v_org, v_store, v_tbl, 'private', 'completed', now()) returning id into v_st;
    insert into session_players (org_id, session_id, member_id)
      select v_org, v_st, x from unnest(array[a,b,c]) x;
    r := public.apply_session_results_tx(v_st, jsonb_build_array(
      jsonb_build_object('member_id',a,'finish_rank',1),
      jsonb_build_object('member_id',b,'finish_rank',2),
      jsonb_build_object('member_id',c,'finish_rank',3)));
    v_out := v_out || E'\n' || '⑰ 三人局（該通過）' || E'\t' ||
      case when r->>'ok' = 'true' then '✅ 通過' else '🔴 ' || coalesce(r->>'reason','?') end;

    ---- 權限 --------------------------------------------------
    v_out := v_out || E'\n' || '⑱ anon 叫不叫得動結算' || E'\t' ||
      (select case when count(*) = 0 then '✅ 收乾淨了' else '🔴 anon 進得來' end
         from pg_proc p
        where p.pronamespace='public'::regnamespace and p.prokind='f'
          and p.proname = 'apply_session_results_tx'
          and (exists (select 1 from aclexplode(p.proacl) x
                        where x.grantee='anon'::regrole::oid and x.privilege_type='EXECUTE')
               or p.proacl is null
               or exists (select 1 from aclexplode(p.proacl) x
                           where x.grantee=0 and x.privilege_type='EXECUTE')));

    raise exception 'migi_rollback';
  exception when others then
    -- ⚠ 硬規則 3.9：訊息一定要設在 exception 處理器裡，不然會跟著回滾
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.rank_test', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.rank_test', true), E'\n')) as x
 where coalesce(x,'') <> '';
