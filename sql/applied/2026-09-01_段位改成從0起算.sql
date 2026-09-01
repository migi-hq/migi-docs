/* ============================================================
   段位改成從 0 起算 ＋ 定位賽　2026-09-01 · MIGI

   ── 使用者拍板 ──────────────────────────────────────
   · 起始 **0 分** = 銅牌熊 IV（原本是 1000 分 = 銅牌熊 II）
   · **銅牌熊 IV → III 只要 5 分**，III 之後每小階維持 **45**
   · **定位賽（人生第一場）** 的順位點 = **+30 / +15 / +10 / +5**
   · 🔴 **低段（銅銀金）本身不動，仍然是 +30 / +15 / 0 / −20**
   · 中段與高段也不動

   🎯 **設計意圖**：定位賽第 4 名也 +5 ⇒ **任何人打完第一場都會從 IV 升到 III**。
     第一次玩的人拿到的不是一個數字，是**一個看得見的升級**。
   ⚠ 第二場開始就回到低段的 `+30/+15/0/−20` —— **第 4 名會扣 20**。
     定位賽是**入場的第一印象**，不是永久的保護傘。

   ── 新階梯 ──────────────────────────────────────────
   ```
   銅牌熊    0 ·   5 ·  50 ·  95      ← 大階寬 140（只有它不是 180）
   銀牌熊  140 · 185 · 230 · 275
   金牌熊  320 · 365 · 410 · 455
   白金熊  500 · 545 · 590 · 635
   鑽石熊  680 · 725 · 770 · 815
   大師熊  860 以上（另有對手多樣性條件）
   ```

   ── 🔴 「第一場」怎麼認定 ────────────────────────────
   用「**這個人有沒有結算過的場次**」判斷，**不是 `rating_games = 0`**。
   | 判準 | 為什麼不用 |
   |---|---|
   | `rating_games = 0` | 🔴 **每季歸零** ⇒ 每一季都會再送一次定位賽；<br>而且它是**逐將**遞增的 ⇒ 同一場的第 2 將就不算定位賽了 |
   | 有沒有結算過的場次 | ✅ 一生一次，**整場**都算定位賽 |
   ⚠ `finish_rank` 是**整場收尾**才寫的，所以在逐將迴圈裡
     這一場自己的列還是 null —— 判斷不會被自己汙染。

   ── 🔴 這一改動到三個原本「算出來」的東西 ────────────

   **① 小階門檻不能再用「區間平均切四段」算。**
   `rank_detail_tx` 現在是 `step = 大階寬 / 4`。
   銅牌寬 140 ÷ 4 = 35 ⇒ 會算成 0/35/70/105，**不是 0/5/50/95**。
   → 新增 `rank_sub_levels`，把小階門檻變成**資料**。
   ⚠ 存的是**相對於大階下限的位移**不是絕對值 ——
     這樣 `rank_tiers.min_rating` 仍然是唯一的真相，
     **兩者不可能對不起來**（存絕對值就會有第二個真相來源）。

   **② `sub_count` 從此沒有人讀** → 一併移除。
   留著就是「建了沒人讀」，而它現在還會**誤導**（看起來像門檻的來源）。

   **③ 「賽季末降 2 大階」不能再寫死 360。**
   原本可以寫死是因為**六個大階都是 180 寬**；現在銅牌是 140。
   → 改成 **`目前大階的 min − 往下兩階的 min`**，依他當下的段位算。
   ```
   鑽石 I 815 → 680−320=360 → 455 = 金牌 I     ✅ 剛好降兩階
   白金III 545 → 500−140=360 → 185 = 銀牌 III   ✅
   銀牌 IV 140 → 只剩一階可降 → 140−0=140 → 0   ✅ 夾在下限
   ```

   ── ✅ 為什麼現在改是零成本 ──────────────────────────
   ```
   會員 5 人 · 有段位的 0 人 · 有名次的 session_players 0 列
   ```
   **一場計分的牌局都還沒發生過。** 所有人 rating 一律重設為 0、
   rank 維持 null（未定位）—— 不需要換算任何歷史。
   🔴 電子計分一上線就再也沒有這個機會了。
   ============================================================ */

-- ① 階梯 ─────────────────────────────────────────────
update public.rank_tiers set min_rating = v.m
  from (values ('bronze',0),('silver',140),('gold',320),
               ('platinum',500),('diamond',680),('master',860)) as v(c,m)
 where rank_tiers.code = v.c;

/* 小階門檻：**相對於大階下限的位移**。
   ⚠ 存位移不存絕對值 —— `rank_tiers.min_rating` 仍是唯一真相，
     日後調整大階下限時這張表不用跟著改。 */
create table if not exists public.rank_sub_levels (
  tier_code  text    not null references public.rank_tiers(code) on delete cascade,
  sub        text    not null,          -- IV / III / II / I（IV 最低）
  offset_pts int     not null,          -- 距離該大階下限幾分
  sort       int     not null,          -- 1=IV … 4=I
  primary key (tier_code, sub),
  constraint rank_sub_levels_offset_chk check (offset_pts >= 0),
  constraint rank_sub_levels_sub_chk    check (sub in ('IV','III','II','I'))
);
alter table public.rank_sub_levels enable row level security;   -- 0 條 policy，同 rank_tiers

insert into public.rank_sub_levels (tier_code, sub, offset_pts, sort)
select t.code, v.sub, v.off, v.sort
  from public.rank_tiers t
 cross join (values
   /* 🔴 銅牌熊第一階只要 5 分 —— **這一條就是「第一場一定升級」的來源**。
      定位賽第 4 名 +5，兩將 +10 ⇒ 穩穩踏上 III。
      改這個數字等於改那個承諾。 */
   ('IV', 0, 1), ('III', 5, 2), ('II', 50, 3), ('I', 95, 4)
 ) as v(sub, off, sort)
 where t.code = 'bronze'
on conflict (tier_code, sub) do update set offset_pts = excluded.offset_pts;

insert into public.rank_sub_levels (tier_code, sub, offset_pts, sort)
select t.code, v.sub, v.off, v.sort
  from public.rank_tiers t
 cross join (values
   ('IV', 0, 1), ('III', 45, 2), ('II', 90, 3), ('I', 135, 4)
 ) as v(sub, off, sort)
 where t.code in ('silver','gold','platinum','diamond')   -- ⚠ 大師熊不分小階
on conflict (tier_code, sub) do update set offset_pts = excluded.offset_pts;

-- ② sub_count 從此沒有人讀 ────────────────────────────
alter table public.rank_tiers drop column if exists sub_count;

-- ③ 定位賽的順位點（新的一個 band）────────────────────
/* 🔴 **低段 `low` 一個字都不動**（+30/+15/0/−20）。
     定位賽是**額外一組**，只在人生第一場套用。
   ⚠ `rank_points` 沒有 band 的 CHECK（只有 PK），所以加一組是免費的。
   📌 它是四組裡唯一**沒有負數**的 —— 那正是它存在的理由。 */
insert into public.rank_points (band, place, points)
values ('placement',1,30), ('placement',2,15), ('placement',3,10), ('placement',4,5)
on conflict (band, place) do update set points = excluded.points;

-- ④ 起始分數 ─────────────────────────────────────────
alter table public.members alter column rating set default 0;
/* ⚠ 全部重設。查證過：有段位的 0 人、有名次的 session_players 0 列
     ⇒ 沒有任何歷史需要換算。`rank` 本來就是 null（未定位），不動它。 */
update public.members set rating = 0, rating_games = 0 where rating <> 0;


-- ⑤ rank_detail_tx：小階門檻改讀主檔 ──────────────────
create or replace function public.rank_detail_tx(p_rating integer)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v int; t record; w numeric; idx int; lo int; hi int;
  v_floor int; v_sub text; v_top boolean; v_next_label text; v_nsub int;
begin
  select min(min_rating) into v_floor from rank_tiers where auto;
  v := greatest(coalesce(p_rating, v_floor), v_floor);

  select * into t from (
    select code, label, min_rating, band,
           lead(min_rating) over (order by min_rating) as next_min
      from rank_tiers where auto
  ) x
   where v >= x.min_rating
   order by x.min_rating desc limit 1;

  if t.label is null then
    /* 到不了這裡（v 已經夾在 floor 之上），但保留一個不會說謊的回覆。
       ⚠ 不要在這裡寫死「銅牌熊 IV／910」—— 那正是 2026-09-01 改階梯時
         最容易被忘記的地方（舊版真的寫死了 910）。改成查主檔。 */
    select label, min_rating into t.label, t.min_rating
      from rank_tiers where auto order by min_rating limit 1;
    return jsonb_build_object('rank', t.label || ' IV','tier',t.label,'sub','IV','band','low',
      'tier_min', t.min_rating, 'rating', v, 'progress', 0, 'to_next', null, 'at_top', true,
      'next_tier', null, 'to_next_tier', null, 'tier_progress', 0);
  end if;

  w := (coalesce(t.next_min, t.min_rating + 180) - t.min_rating)::numeric;

  /* 🔴 小階門檻**從 `rank_sub_levels` 讀，不要再用「區間平均切四段」** ——
     銅牌熊是 0/5/50/95，除以 4 會算成 0/35/70/105。 */
  select s.sort, s.sub, t.min_rating + s.offset_pts
    into idx, v_sub, lo
    from rank_sub_levels s
   where s.tier_code = t.code and t.min_rating + s.offset_pts <= v
   order by s.offset_pts desc limit 1;

  select count(*) into v_nsub from rank_sub_levels where tier_code = t.code;

  if v_sub is null then          -- 不分小階的大階
    idx := 1; lo := t.min_rating; hi := (t.min_rating + w)::int;
  else
    -- 下一個小階的門檻；已經是最高小階就用大階上界
    select coalesce(min(t.min_rating + s2.offset_pts), (t.min_rating + w)::int)
      into hi
      from rank_sub_levels s2
     where s2.tier_code = t.code and s2.sort > idx;
  end if;

  v_top := (t.next_min is null and idx = greatest(v_nsub, 1));

  /* 下一個**大階**的名字。
     ⚠ 這裡要看**全部**的階（含 `auto=false` 的大師熊）——
       客人爬到鑽石 I 之後，下一個目標仍然叫「大師熊」，
       只是它需要對手多樣性。**看得到但要多做一件事**，
       跟「看不到目標」是完全不同的體驗。 */
  select label into v_next_label from rank_tiers
   where min_rating > t.min_rating order by min_rating limit 1;

  return jsonb_build_object(
    'rank',     case when v_sub is null then t.label else t.label || ' ' || v_sub end,
    'tier',     t.label,
    'sub',      v_sub,
    'band',     t.band,
    'tier_min', t.min_rating,
    'rating',   v,
    -- 小級內的進度（細顆粒，會比較常動）
    'progress', case when hi > lo
                     then least(100, greatest(0, round((v - lo)::numeric / (hi - lo) * 100)))::int
                     else 0 end,
    'to_next',  case when v_top then null else greatest(0, hi - v) end,
    'at_top',   v_top,
    -- 🎯 大階：Hero 的進度條與副標用這一組（小熊在大階換）
    'next_tier',     v_next_label,
    'to_next_tier',  case when v_next_label is null then null
                          else greatest(0, (t.min_rating + w)::int - v) end,
    'tier_progress', case when v_next_label is null then 100
                          else least(100, greatest(0, round((v - t.min_rating) / w * 100)))::int end
  );
end $function$;


-- ⑥ list_rank_tiers_tx：小階改讀主檔、順位點多一組 ────
create or replace function public.list_rank_tiers_tx()
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select jsonb_build_object(
    'tiers', (
      select jsonb_agg(jsonb_build_object(
        'code', t.code, 'label', t.label, 'band', t.band,
        'min_rating', t.min_rating, 'auto', t.auto,
        /* 小級由低到高：IV / III / II / I
           ⚠ 絕對門檻 = 大階下限 ＋ 位移。前端只拿到算好的絕對值，
             **不要讓它自己加** —— 那就是第二份算法。 */
        'subs', coalesce((
          select jsonb_agg(jsonb_build_object('sub', s.sub, 'min', t.min_rating + s.offset_pts)
                   order by s.sort)
            from rank_sub_levels s where s.tier_code = t.code), '[]'::jsonb)
      ) order by t.sort)
      from rank_tiers t),
    /* ⚠ 排序要含 `placement`，而且它排**最前面** ——
         那是客人遇到的第一組數字。漏掉的話它會掉到 `else` 跟 top 混在一起。 */
    'points', (
      select jsonb_agg(jsonb_build_object('band', band, 'place', place, 'points', points)
               order by case band when 'placement' then 0 when 'low' then 1
                                  when 'mid' then 2 else 3 end, place)
        from rank_points)
  );
$function$;


-- ⑦ apply_session_rounds_tx：人生第一場走定位賽 ────────
create or replace function public.apply_session_rounds_tx(p_session_id uuid, p_rounds jsonb)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
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

      /* ── 🎓 定位賽：人生第一場 ────────────────────────
         使用者 2026-09-01 拍板：第一場用 `+30/+15/+10/+5`，
         **第 4 名也 +5** ⇒ 打完一定會從銅牌熊 IV 升到 III。
         第一次玩的人拿到的不是一個數字，是**一個看得見的升級**。

         🔴 **判準是「有沒有結算過的場次」，不是 `rating_games = 0`。**
           · `rating_games` **每季歸零** ⇒ 會變成每季都送一次定位賽
           · 它是**逐將**遞增的 ⇒ 同一場的第 2 將就不算定位賽了，
             而那會讓「第一場」這個承諾在 2 將制下**只兌現一半**
         ⚠ `finish_rank` 是**整場收尾**才寫的，所以這一場自己的列
           在這個迴圈裡還是 null —— 判斷不會被自己汙染。
         ⚠ 排除 `p_session_id` 是保險：就算日後有人改成逐將寫入，
           這一行仍然成立。 */
      if not exists (select 1 from session_players sp2
                      where sp2.member_id = v_ids[i]
                        and sp2.finish_rank is not null
                        and sp2.session_id <> p_session_id) then
        v_band := 'placement';
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
           那正是原始設計說「保護底線 = 金牌 I」的意思，不是完全不動。
         ⚠ `placement` 也夾一次：它沒有負數所以是空操作，
           但**不寫的話這一行就依賴「placement 永遠沒有負數」這個假設**。 */
      if v_band in ('low', 'placement') then
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
end $function$;


-- ⑧ reset_season_ratings_tx：降 N 大階改成依段位算 ────
create or replace function public.reset_season_ratings_tx(
  p_org_id uuid, p_season text, p_drop_tiers integer default 2
) returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_champ uuid; v_rating int; v_n int; v_floor int;
begin
  if not exists (select 1 from rank_seasons
                  where org_id = p_org_id and code = p_season) then
    return jsonb_build_object('ok', false, 'reason', 'season_not_found');
  end if;

  if exists (select 1 from season_champions
              where org_id = p_org_id and season = p_season) then
    return jsonb_build_object('ok', false, 'reason', 'season_already_closed');
  end if;

  /* 🔴 先記冠軍再降階。順序反了就永遠沒有這一季的雀神。 */
  select m.id, m.rating into v_champ, v_rating
    from members m
   where m.org_id = p_org_id and m.deleted_at is null and not m.is_test
     and m.rank is not null
     and m.rating >= (select min_rating from rank_tiers where code = 'master')
     and public.member_rank_tx(m.id) = (select label from rank_tiers where code = 'master')
   order by m.rating desc, m.rating_games desc
   limit 1;

  insert into season_champions (season, org_id, member_id, rating)
  values (p_season, p_org_id, v_champ, v_rating);

  select min(min_rating) into v_floor from rank_tiers where auto;

  /* 🔴 **不能再寫死「大階寬 × 2」** —— 那個寫法能成立是因為
     六個大階以前都是 180 寬。2026-09-01 之後銅牌是 140。
     → 扣的分數 = **他目前大階的下限 − 往下 N 階的下限**，
       所以「降 2 大階」對每個人都真的是降 2 大階。
     ⚠ 往下不足 N 階時用最低階（＝一路掉到底），再由 `greatest(v_floor,…)` 夾住。 */
  with tiers as (
    select min_rating, row_number() over (order by min_rating) as rn
      from rank_tiers where auto
  ), mine as (
    select m.id, m.rating,
           (select t.rn from tiers t where t.min_rating <= m.rating
             order by t.min_rating desc limit 1) as rn
      from members m
     where m.org_id = p_org_id and m.deleted_at is null and m.rank is not null
  ), calc as (
    select mine.id,
           greatest(v_floor, mine.rating - (
             (select t.min_rating from tiers t where t.rn = mine.rn)
             - (select t2.min_rating from tiers t2
                 where t2.rn = greatest(1, mine.rn - p_drop_tiers))
           )) as new_rating
      from mine
  )
  update members m
     set rating       = c.new_rating,
         rating_games = 0,
         rank         = public.rank_from_rating(c.new_rating)
    from calc c
   where m.id = c.id;
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'season', p_season,
    'champion', v_champ, 'champion_rating', v_rating,
    'drop_tiers', p_drop_tiers, 'floor', v_floor, 'affected_members', v_n);
end $function$;


-- ── 驗證 ───────────────────────────────────────────────
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_out text := ''; d jsonb; v_st uuid; v_st2 uuid; v_tbl uuid; v_store uuid;
  a uuid; b uuid; c uuid; e uuid;
begin
  begin
    ---- 階梯本身 ----------------------------------------
    v_out := v_out || E'\n' || '① 六個大階下限' || E'\t' ||
      (select case when string_agg(min_rating::text, '/' order by sort) = '0/140/320/500/680/860'
                   then '✅ 0/140/320/500/680/860'
                   else '🔴 ' || string_agg(min_rating::text, '/' order by sort) end
         from rank_tiers);

    v_out := v_out || E'\n' || '② 銅牌熊 = 0/5/50/95' || E'\t' ||
      (select case when string_agg((t.min_rating + s.offset_pts)::text, '/' order by s.sort) = '0/5/50/95'
                   then '✅ 0/5/50/95'
                   else '🔴 ' || string_agg((t.min_rating + s.offset_pts)::text, '/' order by s.sort) end
         from rank_sub_levels s join rank_tiers t on t.code = s.tier_code
        where s.tier_code = 'bronze');

    /* 🔴 **正對照**：其餘大階必須還是等寬 45。
       只驗銅牌的話，一個「把所有大階都改成 0/5/50/95」的錯誤照樣會綠。 */
    v_out := v_out || E'\n' || '③ 正對照：銀牌熊 = 140/185/230/275' || E'\t' ||
      (select case when string_agg((t.min_rating + s.offset_pts)::text, '/' order by s.sort) = '140/185/230/275'
                   then '✅ 每階 45'
                   else '🔴 ' || string_agg((t.min_rating + s.offset_pts)::text, '/' order by s.sort) end
         from rank_sub_levels s join rank_tiers t on t.code = s.tier_code
        where s.tier_code = 'silver');

    v_out := v_out || E'\n' || '④ 大師熊不分小階' || E'\t' ||
      (select case when count(*) = 0 then '✅ 0 列' else '🔴 ' || count(*) || ' 列' end
         from rank_sub_levels where tier_code = 'master');

    ---- 分界 --------------------------------------------
    v_out := v_out || E'\n' || '⑤ 分界：0→IV　4→IV　5→III　49→III　50→II' || E'\t' ||
      case when public.rank_from_rating(0)  = '銅牌熊 IV'
            and public.rank_from_rating(4)  = '銅牌熊 IV'
            and public.rank_from_rating(5)  = '銅牌熊 III'
            and public.rank_from_rating(49) = '銅牌熊 III'
            and public.rank_from_rating(50) = '銅牌熊 II'
           then '✅ 五個邊界都對'
           else '🔴 ' || public.rank_from_rating(0) || '／' || public.rank_from_rating(4)
                || '／' || public.rank_from_rating(5) || '／' || public.rank_from_rating(49)
                || '／' || public.rank_from_rating(50) end;

    /* 🔴 **860 分要回「鑽石熊 I」不是「大師熊」。**
       `rank_tiers.master.auto = false`，而 `rank_detail_tx` 只看 `where auto`
       ⇒ **它永遠不會回大師熊**，那是設計不是 bug：
       大師還要「本季 ≥20 個不同對手」，**只有 `member_rank_tx` 給得出來**。
       ⚠ 我第一版把這一格寫成期望「大師熊」，它紅了，而**函式是對的** ——
         2026-09-01 這是第三次期望值算錯（前兩次：btree_gist 的函式數、
         桌況的鍵數）。**紅的時候先懷疑期望值，不要先改函式。** */
    v_out := v_out || E'\n' || '⑥ 正對照：139→銅I　140→銀IV　815→鑽I' || E'\t' ||
      case when public.rank_from_rating(139) = '銅牌熊 I'
            and public.rank_from_rating(140) = '銀牌熊 IV'
            and public.rank_from_rating(815) = '鑽石熊 I'
           then '✅ 三個都對'
           else '🔴 ' || public.rank_from_rating(139) || '／' || public.rank_from_rating(140)
                || '／' || public.rank_from_rating(815) end;

    /* 🎯 真正的不變式：**分數再高，光靠分數也只到鑽石熊 I。** */
    v_out := v_out || E'\n' || '⑥b 分數到頂也不會自己變成大師熊' || E'\t' ||
      case when public.rank_from_rating(860)  = '鑽石熊 I'
            and public.rank_from_rating(9999) = '鑽石熊 I'
           then '✅ 860 與 9999 都是鑽石熊 I（大師要對手多樣性）'
           else '🔴 ' || public.rank_from_rating(860) || '／' || public.rank_from_rating(9999) end;

    ---- 順位點 ------------------------------------------
    v_out := v_out || E'\n' || '⑦ 定位賽 +30/+15/+10/+5' || E'\t' ||
      (select case when string_agg(points::text, '/' order by place) = '30/15/10/5'
                   then '✅ 30/15/10/5' else '🔴 ' || string_agg(points::text, '/' order by place) end
         from rank_points where band = 'placement');
    /* 🔴 **這一格是這次改動最容易做錯的地方** ——
       我第一版真的把低段改成了 +30/+15/+10/+5。低段必須原封不動。 */
    v_out := v_out || E'\n' || '⑧ 🔴 低段原封不動 +30/+15/0/−20' || E'\t' ||
      (select case when string_agg(points::text, '/' order by place) = '30/15/0/-20'
                   then '✅ 30/15/0/−20'
                   else '🔴 ' || string_agg(points::text, '/' order by place) || ' —— 低段不該被改' end
         from rank_points where band = 'low');
    v_out := v_out || E'\n' || '⑨ 正對照：中段與高段也沒被動到' || E'\t' ||
      (select case when string_agg(band || place::text || '=' || points, ' ' order by band, place)
                        = 'mid1=30 mid2=10 mid3=-10 mid4=-30 top1=30 top2=5 top3=-20 top4=-40'
                   then '✅ 兩段都原封不動'
                   else '🔴 ' || string_agg(band || place::text || '=' || points, ' ' order by band, place) end
         from rank_points where band in ('mid','top'));

    ---- 🎓 定位賽真的跑一次 ------------------------------
    select id into v_store from stores where org_id = v_org limit 1;
    select id into v_tbl   from tables where org_id = v_org limit 1;
    insert into members (org_id, display_name) values (v_org,'測甲') returning id into a;
    insert into members (org_id, display_name) values (v_org,'測乙') returning id into b;
    insert into members (org_id, display_name) values (v_org,'測丙') returning id into c;
    insert into members (org_id, display_name) values (v_org,'測丁') returning id into e;

    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
      values (v_org, v_store, v_tbl, 'private', 'completed', now()) returning id into v_st;
    insert into session_players (org_id, session_id, member_id)
      select v_org, v_st, x from unnest(array[a,b,c,e]) x;
    perform public.apply_session_rounds_tx(v_st, (
      select jsonb_agg(jsonb_build_array(
        jsonb_build_object('member_id',a,'finish_rank',1),
        jsonb_build_object('member_id',b,'finish_rank',2),
        jsonb_build_object('member_id',c,'finish_rank',3),
        jsonb_build_object('member_id',e,'finish_rank',4)))
      from generate_series(1,2)));

    v_out := v_out || E'\n' || '⑩ 第一場（2 將）四個人' || E'\t' ||
      (select string_agg(m.display_name || ' ' || m.rating || '分 ' || m.rank, '　' order by m.display_name)
         from members m where m.id in (a,b,c,e));
    /* 🎯 **這一格是整份 SQL 的重點。** */
    v_out := v_out || E'\n' || '⑪ 🎯 連第 4 名都升到銅牌熊 III' || E'\t' ||
      (select case when m.rank = '銅牌熊 III' and m.rating = 10
                   then '✅ 10 分 · 銅牌熊 III（+5 × 2 將）'
                   else '🔴 ' || m.rating || ' 分 ' || coalesce(m.rank,'null') end
         from members m where m.id = e);

    /* 🔴 **正對照：第二場就不是定位賽了。**
       少了這一格，一個「永遠用 placement」的錯誤會讓 ⑩⑪ 全綠 ——
       而那個錯誤的後果是**低段永遠不會扣分**，也就是這次改動最怕的事。 */
    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
      values (v_org, v_store, v_tbl, 'private', 'completed', now()) returning id into v_st2;
    insert into session_players (org_id, session_id, member_id)
      select v_org, v_st2, x from unnest(array[a,b,c,e]) x;
    perform public.apply_session_rounds_tx(v_st2, (
      select jsonb_agg(jsonb_build_array(
        jsonb_build_object('member_id',a,'finish_rank',1),
        jsonb_build_object('member_id',b,'finish_rank',2),
        jsonb_build_object('member_id',c,'finish_rank',3),
        jsonb_build_object('member_id',e,'finish_rank',4)))
      from generate_series(1,2)));
    v_out := v_out || E'\n' || '⑫ 🔴 正對照：第二場第 4 名吃 −20×2，夾在 0' || E'\t' ||
      (select case when m.rating = 0
                   then '✅ 10 − 40 → 夾在 0（不是 placement 的 +10）'
                   else '🔴 ' || m.rating || ' 分 —— 第二場還在用定位賽' end
         from members m where m.id = e);
    v_out := v_out || E'\n' || '⑬ 正對照：第二場第 1 名吃低段 +30×2' || E'\t' ||
      (select case when m.rating = 60 + 60 then '✅ 60 + 60 = 120'
                   else '🔴 ' || m.rating || ' 分（定位 +30×2=60，低段 +30×2=60）' end
         from members m where m.id = a);

    ---- 降 2 大階 ---------------------------------------
    update members set rating = 815, rank = public.rank_from_rating(815) where id = a; -- 鑽石 I
    update members set rating = 545, rank = public.rank_from_rating(545) where id = b; -- 白金 III
    update members set rating = 140, rank = public.rank_from_rating(140) where id = c; -- 銀牌 IV
    insert into rank_seasons (code, org_id, label, starts_at, ends_at)
      values ('T測試', v_org, '測試季', '2025-01-01+08', '2025-07-01+08');
    perform public.reset_season_ratings_tx(v_org, 'T測試', 2);

    v_out := v_out || E'\n' || '⑭ 鑽石 I 815 → 金牌 I 455' || E'\t' ||
      (select case when rating = 455 and rank = '金牌熊 I' then '✅ 455 · 金牌熊 I'
                   else '🔴 ' || rating || ' · ' || coalesce(rank,'null') end from members where id = a);
    v_out := v_out || E'\n' || '⑮ 白金 III 545 → 銀牌 III 185' || E'\t' ||
      (select case when rating = 185 and rank = '銀牌熊 III' then '✅ 185 · 銀牌熊 III'
                   else '🔴 ' || rating || ' · ' || coalesce(rank,'null') end from members where id = b);
    v_out := v_out || E'\n' || '⑯ 銀牌 IV 140 → 夾在下限 0' || E'\t' ||
      (select case when rating = 0 and rank = '銅牌熊 IV' then '✅ 0 · 銅牌熊 IV'
                   else '🔴 ' || rating || ' · ' || coalesce(rank,'null') end from members where id = c);

    ---- 收尾 --------------------------------------------
    v_out := v_out || E'\n' || '⑰ members.rating 預設 0' || E'\t' ||
      coalesce((select case when column_default = '0' then '✅ 0' else '🔴 ' || column_default end
                  from information_schema.columns
                 where table_schema='public' and table_name='members' and column_name='rating'), '🔴 找不到');
    v_out := v_out || E'\n' || '⑱ sub_count 已移除' || E'\t' ||
      (select case when count(*) = 0 then '✅ 沒有了' else '🔴 還在' end
         from information_schema.columns
        where table_schema='public' and table_name='rank_tiers' and column_name='sub_count');
    v_out := v_out || E'\n' || '⑲ 正對照：list_rank_tiers_tx 還答得出來' || E'\t' ||
      (select case when jsonb_array_length(public.list_rank_tiers_tx()->'tiers') = 6
                    and (public.list_rank_tiers_tx()->'tiers'->0->'subs'->1->>'min') = '5'
                    and jsonb_array_length(public.list_rank_tiers_tx()->'points') = 16
                   then '✅ 6 階、銅牌 III = 5、四組順位點共 16 列'
                   else '🔴 ' || (public.list_rank_tiers_tx()->'tiers'->0->'subs')::text end);

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.rank0', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.rank0', true), E'\n')) as x
 where coalesce(x,'') <> '';
