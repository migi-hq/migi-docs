/* ============================================================
   2026-11-03 · 會員 App 頂條的碎片數（牌桌商城的貨幣）
   規則（docs/03-會員App與社交/桌邊背景皮膚.md「牌桌商城的貨幣：碎片」，使用者 2026-11-03 拍板）：
     · 胡牌的那一家，那一局選了的牌型裡，主檔台數 ≥ 2 的，一個牌型 1 個；同一個牌型按幾次算幾個（花槓 ×2 ＝ 2 個）
     · 1 台的牌型、豹子、莊家台、連莊不算；數字鍵那一局（沒有記牌型）自然拿不到
     · 好友練習賽不算（table_sessions.mode = 'friendly'）
     · 只算已入帳（hands.status = 'confirmed'）—— 撤銷（undone）、被取消（rejected）的局不算
     · 封測期間打的局一起算（同段位分、成就：封測成績上線後保留）

   ── 做法：從每一局即時算，不另存帳本 ──
   · 現在還沒有商城、碎片花不掉 ⇒ 手上的數 ＝ 拿到的數。從事實表算，永遠跟每一局對得上（同待辦 1 的 B 案）
   · 座位對到人：session_players.seat（換人上桌是改那一列的 member_id ⇒ 被換下的人打的局算接手的人，
     跟「分數全部算 A 的」同一個規則）
   · 局一入帳就算，不等收桌（打完一局回 App 就看得到）
   ⚠ 做商城那天：花掉的要記一張帳（誰、哪天、換了什麼、花幾個），手上的數 ＝ 這裡算的 − 花掉的。
     ⚠ 也要想一件事：判斷看主檔台數 ⇒ 哪天把某個牌型改成 1 台，過去拿到的也會一起變少，
       可能變得比花掉的還少。真的要改牌型台數之前，先把「拿到的」改成發的當下寫進帳本。

   ⚠ 新函式預設全關（硬規則 2.7）：_member_shards_earned 只給內部用；get_my_shards_tx 明確 grant 給 authenticated
   ============================================================ */

create or replace function public._member_shards_earned(p_member uuid)
returns integer
language sql
stable
security definer
set search_path to 'public'
as $function$
  /* 碎片「拿到幾個」的唯一一份算法。頂條、日後的商城都叫這一支，不要在別處再寫一份條件 */
  select coalesce(sum((p->>'n')::int), 0)::int
    from session_players sp
    join table_sessions s on s.id = sp.session_id
    join hands h          on h.session_id = sp.session_id and h.winner_seat = sp.seat
    cross join lateral jsonb_array_elements(coalesce(h.patterns, '[]'::jsonb)) p
    join scoring_patterns pt on pt.code = p->>'code'
   where sp.member_id = p_member
     and sp.seat is not null
     and s.deleted_at is null
     and s.status <> 'voided'
     and coalesce(s.mode, '') <> 'friendly'
     and h.status = 'confirmed'
     and h.result in ('ron', 'tsumo')
     and pt.tai >= 2
$function$;

create or replace function public.get_my_shards_tx()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_me uuid := public.current_member_id();
begin
  if v_me is null then
    raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000';
  end if;
  -- 還沒有商城：手上的 ＝ 拿到的
  return jsonb_build_object('shard', public._member_shards_earned(v_me));
end $function$;

revoke execute on function public._member_shards_earned(uuid) from public, anon, authenticated;
revoke execute on function public.get_my_shards_tx() from public, anon;
grant  execute on function public.get_my_shards_tx() to authenticated;

/* ── 驗證（單一 SELECT，不用 raise，硬規則 1.8）────────────────
   ② 正對照：所有會員加總 ＝ 直接從每一局算的總數（座位都對得到人的話兩者相同）；
     而且要 > 0（全部是 0 也會「相同」）
   ③ 好友練習賽與撤銷的局沒有被算進去（直接算一次「如果算進去會多幾個」，現在應該是 0 或多出來的數不在 ② 裡） */
with direct as (
  select coalesce(sum((p->>'n')::int), 0) as n
    from hands h
    join table_sessions s on s.id = h.session_id
    cross join lateral jsonb_array_elements(coalesce(h.patterns, '[]'::jsonb)) p
    join scoring_patterns pt on pt.code = p->>'code'
   where s.deleted_at is null and s.status <> 'voided' and coalesce(s.mode, '') <> 'friendly'
     and h.status = 'confirmed' and h.result in ('ron', 'tsumo') and pt.tai >= 2
), per as (
  select coalesce(sum(public._member_shards_earned(m.id)), 0) as n,
         count(*) filter (where public._member_shards_earned(m.id) > 0) as people
    from members m
)
select concat_ws(E'\n',
  case when (select count(*) from pg_proc where proname in ('_member_shards_earned', 'get_my_shards_tx') and pronamespace = 'public'::regnamespace) = 2
       then '✅ ① 兩支函式都在（各一個版本）' else '🔴 ① 函式數不對' end,
  case when (select n from per) = (select n from direct) and (select n from direct) > 0
       then '✅ ② 會員加總 ' || (select n from per) || ' ＝ 每一局直接算 ' || (select n from direct) || '（' || (select people from per) || ' 人有碎片）'
       else '🔴 ② 會員加總 ' || (select n from per) || '，每一局直接算 ' || (select n from direct) || ' —— 不一樣或是 0' end,
  case when has_function_privilege('authenticated', 'public.get_my_shards_tx()', 'execute')
        and not has_function_privilege('anon', 'public.get_my_shards_tx()', 'execute')
       then '✅ ③ get_my_shards_tx：登入的人叫得動、沒登入的叫不動' else '🔴 ③ get_my_shards_tx 權限不對' end,
  case when not has_function_privilege('authenticated', 'public._member_shards_earned(uuid)', 'execute')
        and not has_function_privilege('anon', 'public._member_shards_earned(uuid)', 'execute')
       then '✅ ④ _member_shards_earned 前端叫不到（可以查任何人的）' else '🔴 ④ _member_shards_earned 前端叫得到' end
) as "驗證";
