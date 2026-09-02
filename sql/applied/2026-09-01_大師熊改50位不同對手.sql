/* ============================================================
   大師熊：本季要跟 **50 個**不同的人打過（原本 20）
   2026-09-01 · MIGI

   ── 🔴 順便把那個數字從程式碼搬進主檔 ──────────────
   改之前它**同時寫在三個地方**：
   ```
   member_rank_tx          >= 20            ← 真正在判斷的
   段位怎麼算（級距表底下） 「20 位以上」      ← 客人看到的
   怎麼算分（教學第 5 步）  「20 位」×2       ← 客人看到的
   ```
   🔴 **一個規則三個副本，而它今天就改了一次** ——
     只改 SQL 的話畫面會繼續說 20，而且**不會有任何錯誤**。
     那正是這個專案一再踩的病（`TIER_LABEL`、`1810`、分類前綴⋯）。

   ✅ 所以這一份不只改數字，是把它變成**資料**：
   `rank_tiers.min_opponents`（只有大師熊有值，其餘 null）。
   · `member_rank_tx` 讀它
   · `list_rank_tiers_tx` 回傳它 → 兩處前端文案都從主檔拿
   🎯 同 `rank_sub_levels` 那次的收益：**下次調整只要改一格資料**。

   ── ⚠ 50 是門檻不是視窗（別跟舊規則混淆）──────────
   `50` 這個數字在 2026-08-31 之前是**視窗大小**
   （「最近 **50 場**的對手中有 ≥ 20 個不同的人」）。
   9/1 視窗改成「本季」之後那個 50 消失了，
   **今天的 50 是「不同對手人數」的門檻**，意思完全不同。
   📌 `member_rank_tx` 裡還有一個 `limit 50` —— 那是
     「一季都還沒建時退回舊行為」的 fallback，**跟這次無關，不要動**。
   ============================================================ */

alter table public.rank_tiers add column if not exists min_opponents int;

comment on column public.rank_tiers.min_opponents is
  '本季要遇過幾個不同的對手才給這個段位。null = 沒有這個條件（分數到了就給）。';

update public.rank_tiers set min_opponents = 50 where code = 'master';
update public.rank_tiers set min_opponents = null where code <> 'master';


-- ── member_rank_tx：門檻改讀主檔 ──────────────────────
create or replace function public.member_rank_tx(p_member_id uuid)
returns text language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_rating int; v_master int; v_opp int; v_org uuid; v_win timestamptz;
  v_need int;
begin
  select rating, org_id into v_rating, v_org
    from members where id = p_member_id and deleted_at is null;
  if v_rating is null then return null; end if;

  /* 🔴 門檻與人數條件**都從主檔讀**（2026-09-01）——
     在此之前 `>= 20` 是寫死的，而同一個數字在兩處前端文案裡也各有一份。 */
  select min_rating, coalesce(min_opponents, 0)
    into v_master, v_need
    from rank_tiers where code = 'master';

  if v_rating < v_master then
    return public.rank_from_rating(v_rating);
  end if;

  v_win := public.rating_window_start_tx(v_org);

  if v_win is not null then
    /* 本季（＝上次歸零之後）。**不設場次上限** ——
       視窗已經由時間界定，再加 limit 就是兩個規則管同一件事。 */
    with mine as (
      select session_id from session_players
       where member_id = p_member_id and finish_rank is not null
         and settled_at is not null and settled_at >= v_win
    )
    select count(distinct sp.member_id) into v_opp
      from session_players sp join mine l on l.session_id = sp.session_id
     where sp.member_id <> p_member_id;
  else
    /* 🔴 一季都還沒建 → 退回舊行為（最近 50 場），**不要一律不給**。
       「忘記建下一季」不該讓所有大師靜靜掉成鑽石。
       ⚠ 這個 `limit 50` 是**視窗大小**，跟上面的 `v_need`（對手人數門檻）
         **是兩件事**，數字剛好一樣是巧合。不要合併。 */
    with last50 as (
      select session_id from session_players
       where member_id = p_member_id and finish_rank is not null
       order by joined_at desc limit 50
    )
    select count(distinct sp.member_id) into v_opp
      from session_players sp join last50 l on l.session_id = sp.session_id
     where sp.member_id <> p_member_id;
  end if;

  return case when coalesce(v_opp,0) >= v_need
              then (select label from rank_tiers where code = 'master')
              else public.rank_from_rating(v_rating) end;   -- 卡在鑽石 I
end $function$;


-- ── list_rank_tiers_tx：把門檻回傳給前端 ──────────────
create or replace function public.list_rank_tiers_tx()
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select jsonb_build_object(
    'tiers', (
      select jsonb_agg(jsonb_build_object(
        'code', t.code, 'label', t.label, 'band', t.band,
        'min_rating', t.min_rating, 'auto', t.auto,
        /* ★ 2026-09-01：**對手人數門檻**。前端兩處文案（級距表底下那一行、
           教學第 5 步）都從這裡拿 —— 不要在前端寫死，
           那個數字今天就已經從 20 改成 50 一次了。 */
        'min_opponents', t.min_opponents,
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


-- ── 驗證 ───────────────────────────────────────────────
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_out text := ''; v_store uuid; v_tbl uuid; v_master int;
  me uuid; opp uuid; s uuid; i int; v_rank text; t jsonb;
begin
  begin
    v_out := v_out || E'\n' || '① 主檔：只有大師熊有門檻，值是 50' || E'\t' ||
      (select case when count(*) filter (where min_opponents = 50 and code='master') = 1
                    and count(*) filter (where min_opponents is not null) = 1
                   then '✅ 大師熊 50，其餘 null'
                   else '🔴 ' || string_agg(code||'='||coalesce(min_opponents::text,'null'), ' ' order by sort) end
         from rank_tiers);

    v_out := v_out || E'\n' || '② list_rank_tiers_tx 回得出來' || E'\t' ||
      (select case when (x->>'min_opponents')::int = 50 then '✅ 50'
                   else '🔴 ' || coalesce(x->>'min_opponents','(沒有這個鍵)') end
         from jsonb_array_elements(public.list_rank_tiers_tx()->'tiers') x
        where x->>'code' = 'master');

    ---- 真的跑一次 --------------------------------------
    select min_rating into v_master from rank_tiers where code = 'master';
    select id into v_store from stores where org_id = v_org limit 1;
    select id into v_tbl   from tables where org_id = v_org limit 1;
    insert into members (org_id, display_name, rating, rank)
      values (v_org, '測大師', v_master + 50, public.rank_from_rating(v_master + 50))
      returning id into me;

    /* 造 49 個不同對手（本季）。⚠ 差一個就不能是大師 —— 那是這一格的重點。 */
    for i in 1..49 loop
      insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
        values (v_org, v_store, v_tbl, 'private','completed', now()) returning id into s;
      insert into members (org_id, display_name) values (v_org,'測對手'||i) returning id into opp;
      insert into session_players (org_id, session_id, member_id, finish_rank, settled_at)
        values (v_org,s,me,1,now()), (v_org,s,opp,2,now());
    end loop;

    v_rank := public.member_rank_tx(me);
    v_out := v_out || E'\n' || '③ 🎯 49 個對手 → 還不是大師' || E'\t' ||
      case when v_rank <> (select label from rank_tiers where code='master')
           then '✅ ' || v_rank || '（差一個就不給）'
           else '🔴 竟然給了大師 —— 門檻沒生效' end;

    /* 🔴 **正對照**：第 50 個補上就要變大師。
       少了它，一個「永遠不給大師」的寫法也會讓 ③ 變綠。 */
    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
      values (v_org, v_store, v_tbl, 'private','completed', now()) returning id into s;
    insert into members (org_id, display_name) values (v_org,'測對手50') returning id into opp;
    insert into session_players (org_id, session_id, member_id, finish_rank, settled_at)
      values (v_org,s,me,1,now()), (v_org,s,opp,2,now());

    v_rank := public.member_rank_tx(me);
    v_out := v_out || E'\n' || '④ 🎯 正對照：第 50 個 → 大師熊' || E'\t' ||
      case when v_rank = (select label from rank_tiers where code='master')
           then '✅ 大師熊' else '🔴 ' || coalesce(v_rank,'null') end;

    /* 🔴 正對照：改主檔的值，判斷要跟著變 —— 證明它真的讀主檔而不是寫死 50。 */
    update rank_tiers set min_opponents = 80 where code = 'master';
    v_rank := public.member_rank_tx(me);
    v_out := v_out || E'\n' || '⑤ 🎯 正對照：主檔改 80 → 立刻退回鑽石' || E'\t' ||
      case when v_rank <> (select label from rank_tiers where code='master')
           then '✅ ' || v_rank || '（證明它讀主檔，不是寫死）'
           else '🔴 還是大師 —— 大概還寫死著' end;

    ---- 正對照：分數不夠的人不受影響 --------------------
    v_out := v_out || E'\n' || '⑥ 正對照：分數不夠的人根本不看對手數' || E'\t' ||
      /* 🔴 **期望值我第一版寫錯了**（硬規則 3.56，2026-09-01 第五次）：
         我寫 `500 → 白金熊 IV`，實際是**金牌熊 I** ——
         銅牌熊 III 從 5 改成 10 那一次，**每個大階邊界都 +5**，
         白金熊 IV 現在是 **505** 不是 500，而我用了改之前的數字。
         ⚠ 這正是 3.56 說的「門檻類的期望值一律當場查」。
         ✅ 改成驗**邊界前後兩個值**，比單點更能證明分界沒跑掉。 */
      case when public.rank_from_rating(504) = '金牌熊 I'
            and public.rank_from_rating(505) = '白金熊 IV'
           then '✅ 504 金牌熊 I ／ 505 白金熊 IV（那一段完全沒動）'
           else '🔴 ' || public.rank_from_rating(504) || ' ／ ' || public.rank_from_rating(505) end;
    v_out := v_out || E'\n' || '⑦ 正對照：授權沒被動到' || E'\t' ||
      (select case when count(*) filter (where has_anon) = 2 then '✅ 兩支的 anon 都在'
                   else '🔴 只有 ' || count(*) filter (where has_anon) || ' 支' end
         from (select exists (select 1 from aclexplode(p.proacl) a
                               where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE') as has_anon
                 from pg_proc p where p.pronamespace='public'::regnamespace
                  and p.proname in ('member_rank_tx','list_rank_tiers_tx')) z);

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.m50', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.m50', true), E'\n')) as x
 where coalesce(x,'') <> '';
