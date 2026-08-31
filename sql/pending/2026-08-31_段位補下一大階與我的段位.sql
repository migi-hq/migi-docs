/* ============================================================
   段位：補「下一大階」＋ 一支給成績頁 Hero 用的
   2026-08-31 · MIGI 咪吉麻將

   ── 為什麼 ──────────────────────────────────────────
   成績頁的 Hero 現在整塊是寫死的：
   ```
   const SEASON_RANK = '金牌熊 II'          // 寫死
   「距離白金熊還差 180 分」                 // 寫死
   進度條 width: '64%'                       // 寫死
   ```
   而 `rank_detail_tx` 回的 `progress` / `to_next` 是**小級內**的，
   Hero 講的卻是**下一大階**（白金熊）—— 兩個不是同一件事。

   ── 🎯 為什麼 Hero 要用大階不用小級 ─────────────────
   LOL 的 LP 進度條是**小級內**的。但 MIGI 不一樣：
   **獎勵是小熊，而小熊只在大階換。**
   ⇒ 進度條要對齊「看得見的東西」，不然客人填滿一條進度條卻什麼都沒發生。

   ✅ 所以 Hero 的組合是：
   ```
   小熊圖   ← 當前大階
   標題     ← 金牌熊 II（小級給細顆粒的回饋，會比較常動）
   進度條   ← 往「白金熊」的進度（大階）
   副標     ← 距離白金熊還差 180 分
   ```
   ⚠ **進度條與副標必須是同一個維度** —— 一個講小級一個講大階的話，
     條滿了字還說「還差 180 分」，那看起來就是壞的。

   ── 改什麼 ──────────────────────────────────────────
   ① `rank_detail_tx` 多回三個：`next_tier` / `to_next_tier` / `tier_progress`
      ✅ 簽名沒變 → `CREATE OR REPLACE`，不用 DROP、不掉 GRANT
   ② 新增 `get_my_rank_tx(org, member)` —— 前端拿不到 rating，
      所以要一支「用 member 問我的段位」的。
      ⚠ 它走 `member_rank_tx`（含大師的對手多樣性），不是純 `rank_detail_tx`。
   ============================================================ */

-- ── ① rank_detail_tx 補下一大階 ───────────────────────
create or replace function public.rank_detail_tx(p_rating integer)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v int; t record; w numeric; step numeric; idx int; lo numeric; hi numeric;
  v_floor int; v_sub text; v_top boolean; v_next_label text;
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
    return jsonb_build_object('rank','銅牌熊 IV','tier','銅牌熊','sub','IV','band','low',
      'tier_min', 910, 'rating', v, 'progress', 0, 'to_next', null, 'at_top', true,
      'next_tier', null, 'to_next_tier', null, 'tier_progress', 0);
  end if;

  w    := (coalesce(t.next_min, t.min_rating + 180) - t.min_rating)::numeric;
  step := w / t.sub_count;
  idx  := least(t.sub_count, 1 + floor((v - t.min_rating) / step)::int);
  lo   := t.min_rating + (idx - 1) * step;
  hi   := lo + step;

  -- 🔴 IV 最低、I 最高
  v_sub := case when t.sub_count <= 1 then null
                else (array['IV','III','II','I'])[idx] end;
  v_top := (t.next_min is null and idx = t.sub_count);

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
    'progress', least(100, greatest(0, round((v - lo) / step * 100)))::int,
    'to_next',  case when v_top then null else ceil(hi - v)::int end,
    'at_top',   v_top,
    -- 🎯 大階：Hero 的進度條與副標用這一組（小熊在大階換）
    'next_tier',     v_next_label,
    'to_next_tier',  case when v_next_label is null then null
                          else greatest(0, (t.min_rating + w)::int - v) end,
    'tier_progress', case when v_next_label is null then 100
                          else least(100, greatest(0, round((v - t.min_rating) / w * 100)))::int end
  );
end $$;


-- ── ② 我的段位（成績頁 Hero 用）───────────────────────
/* 前端拿不到 rating（那是內部數字），所以要一支用 member 問的。
   ⚠ 走 `member_rank_tx` 而不是 `rank_detail_tx` ——
     大師熊要對手多樣性，只有它知道。
   ⚠ 回傳裡**沒有對手多樣性的細節**（打過幾個不同的人）——
     那是「他還差什麼」的資訊，等真的有人爬到 1810 再說。
     現在多回一個沒人讀的欄位只是擴大暴露面。 */
create or replace function public.get_my_rank_tx(p_org_id uuid, p_member_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_rating int; v_games int; v_d jsonb; v_rank text;
begin
  select rating, rating_games into v_rating, v_games
    from members
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
  if v_rating is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  v_d := public.rank_detail_tx(v_rating);
  v_rank := public.member_rank_tx(p_member_id);

  /* 🔴 `member_rank_tx` 可能回「大師熊」而 `rank_detail_tx` 回「鑽石熊 I」——
     那不是矛盾，是**對手多樣性通過了**。以 `member_rank_tx` 為準。 */
  return v_d || jsonb_build_object('ok', true, 'rank', v_rank, 'games', v_games);
end $$;

grant execute on function public.get_my_rank_tx(uuid, uuid) to anon, authenticated, service_role;


-- ── ③ 驗證 ────────────────────────────────────────────
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_out text := ''; m uuid; d jsonb;
begin
  begin
    d := public.rank_detail_tx(1360);   -- 金牌熊 II（金牌 1270–1449）
    v_out := v_out || E'\n' || '① 1360 的下一大階是白金熊' || E'\t' ||
      case when d->>'next_tier' = '白金熊' then '✅ 白金熊'
           else '🔴 ' || coalesce(d->>'next_tier','null') end;
    /* 金牌 1270 起、寬 180 → 下一大階在 1450。1450 − 1360 = 90。 */
    v_out := v_out || E'\n' || '② 1360 距離白金熊還差 90 分' || E'\t' ||
      case when (d->>'to_next_tier')::int = 90 then '✅ 90'
           else '🔴 ' || coalesce(d->>'to_next_tier','null') end;
    /* (1360−1270)/180 = 50% */
    v_out := v_out || E'\n' || '③ 1360 的大階進度是 50%' || E'\t' ||
      case when (d->>'tier_progress')::int = 50 then '✅ 50%'
           else '🔴 ' || coalesce(d->>'tier_progress','null') end;
    /* 🔴 正對照：小級的那一組**不可以跟著變成大階的值**。
       1360 是金牌熊 II 的起點（II = 1360–1404）→ 小級進度 0、還差 45。
       兩組如果一樣，代表我把舊的欄位覆蓋掉了。 */
    v_out := v_out || E'\n' || '④ 正對照：小級那一組仍然是 0% / 45 分' || E'\t' ||
      case when (d->>'progress')::int = 0 and (d->>'to_next')::int = 45
           then '✅ 0% / 45（跟大階那組不同）'
           else '🔴 ' || (d->>'progress') || '% / ' || coalesce(d->>'to_next','null') end;

    /* 🎯 鑽石 I 的下一大階要是**大師熊**（`auto=false` 也要看得到目標）。
       ⚠ 只看 `auto` 的話這裡會是 null —— 客人爬到頂就看不到下一個目標了。 */
    d := public.rank_detail_tx(1765);
    v_out := v_out || E'\n' || '⑤ 鑽石 I 看得到「大師熊」這個目標' || E'\t' ||
      case when d->>'next_tier' = '大師熊' then '✅ 大師熊'
           else '🔴 ' || coalesce(d->>'next_tier','null') end;

    ---- get_my_rank_tx ---------------------------------------
    insert into members (org_id, display_name) values (v_org,'測段位') returning id into m;
    d := public.get_my_rank_tx(v_org, m);
    v_out := v_out || E'\n' || '⑥ 新會員 1000 分 → 銅牌熊 II' || E'\t' ||
      case when d->>'rank' = '銅牌熊 II' and (d->>'games')::int = 0
           then '✅ 銅牌熊 II · 0 場'
           else '🔴 ' || coalesce(d->>'rank','?') || ' · ' || coalesce(d->>'games','?') end;

    /* 🔴 正對照：分數到 1810 但沒有對手多樣性 → **仍然是鑽石熊 I**。
       `get_my_rank_tx` 要以 `member_rank_tx` 為準，不能直接用 rank_detail_tx。 */
    update members set rating = 1900 where id = m;
    d := public.get_my_rank_tx(v_org, m);
    v_out := v_out || E'\n' || '⑦ 1900 分但沒對手多樣性 → 鑽石熊 I' || E'\t' ||
      case when d->>'rank' = '鑽石熊 I' then '✅ 鑽石熊 I（大師要多樣性）'
           else '🔴 ' || coalesce(d->>'rank','?') end;

    v_out := v_out || E'\n' || '⑧ 查不到的人（該擋）' || E'\t' ||
      case when public.get_my_rank_tx(v_org, gen_random_uuid())->>'reason' = 'member_not_found'
           then '✅ member_not_found' else '🔴 竟然回了東西' end;

    v_out := v_out || E'\n' || '⑨ 授權：anon 讀得到（Hero 要用）' || E'\t' ||
      (select case when count(*) = 1 then '✅ 有' else '🔴 沒有' end
         from pg_proc p
        where p.pronamespace='public'::regnamespace and p.proname='get_my_rank_tx'
          and exists (select 1 from aclexplode(p.proacl) x
                       where x.grantee='anon'::regrole::oid and x.privilege_type='EXECUTE'));

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.rank3', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.rank3', true), E'\n')) as x
 where coalesce(x,'') <> '';
