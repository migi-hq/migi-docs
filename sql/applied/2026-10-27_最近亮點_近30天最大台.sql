/* ============================================================
   最近亮點：近 30 天胡過台數最大的那一局（個人頁 ＋ 他人個人卡）
   2026-10-27 · MIGI 咪吉麻將

   ── 起因 ────────────────────────────────────────────────
   使用者：「個人設定頁有一個近期最大的一手，沒實裝嗎」——
   會員 App 個人頁的「最近亮點」是寫死的空狀態；他人個人卡（限牌咖）的同一塊，後端一直回 'highlight', null。
   當時在等電子計分的每一局；計分板 09-25 起已經記了 3,662 局（10-27），可以接了。
   拍板（使用者「照妳建議」）：近 30 天、同台數取最近的、不寫誰放槍、數字鍵那幾局只顯示台數。

   ── 這份做四件事 ──────────────────────────────────────────
   ① _hand_tai_total(...)：「這一局幾台」**唯一一份**算法（成績頁、排行榜、亮點都用它）
      🔴 順手修一個漏洞：平板顯示的台數是「牌型台（已乘豹子）＋ 莊家台 × 豹子倍數」
        （migi-table rules.js：handDealerTai(...) * multOfPatterns(...)），
        而 _member_hand_counts 的莊家台**沒有乘豹子倍數** ⇒ 有豹子又有莊家台的局少算。10-27 查：豹子 10 局，其中 7 局有莊家台。
        ⇒ 成績頁「單局最大台」、排行榜「單局最大台數」那幾位會變大（變成跟平板一樣）。
   ② _member_hand_counts 改用 ①（其餘逐字照舊；簽名不變，CREATE OR REPLACE 不掉授權）
   ③ _member_highlight(org, member)：近 30 天（看那一局入帳時間）自己胡的局裡台數最大的一局，同台數取最近；
      場次條件跟 _member_hand_counts 一樣（有名次、有座位）。回台數、自摸／放槍、連莊、是不是莊家、
      牌型中文（不含「自摸」—— 結果那一欄已經講了；豹子寫「×N 倍」）、是不是數字鍵輸入、時間、門市、桌號。
      🔴 **不回放槍的人**（那是別人的事）。沒有就回 null。
   ④ 讀的地方：
      · get_my_highlight_tx()：自己個人頁讀（身分一律 current_member_id()）
      · get_member_card_tx：原本那行 'highlight', null 換成 ③；對方設「只有自己」看成績時仍然是 null
        （鎖住的陌生人／同團那兩條路本來就提早回傳，不會走到這一行）
   ============================================================ */

-- ① 這一局幾台（唯一一份）
create or replace function public._hand_tai_total(
  p_result text, p_tai_pattern int, p_patterns jsonb,
  p_winner smallint, p_deal_in smallint, p_dealer smallint, p_renzhuang smallint)
returns int
language sql
immutable
set search_path = public
as $$
  /* 牌型台（後端存的已經乘過豹子）＋ 莊家台 × 豹子倍數 —— 跟平板「莊 X 台」同一套：
     放槍看胡與放槍兩家有沒有莊家，自摸一律有；莊家台 ＝ 1 ＋ 2 × 連莊；豹子按 n 次 ⇒ ×(n＋1) */
  select coalesce(p_tai_pattern, 0)
       + case when p_result = 'tsumo'
                or (p_result = 'ron' and (p_winner = p_dealer or p_deal_in = p_dealer))
              then (1 + 2 * coalesce(p_renzhuang, 0))
                   * (1 + coalesce((select (x->>'n')::int from jsonb_array_elements(coalesce(p_patterns, '[]'::jsonb)) x
                                     where x->>'code' = 'baozi' limit 1), 0))
              else 0 end;
$$;

revoke execute on function public._hand_tai_total(text, int, jsonb, smallint, smallint, smallint, smallint) from public, anon, authenticated;

-- ② 每一局統計改用 ①（只換台數那一段，其餘照 2026-10-14 的線上版逐字）
create or replace function public._member_hand_counts(p_org_id uuid, p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_member_ids uuid[] DEFAULT NULL::uuid[], p_to timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS TABLE(member_id uuid, hands integer, hu integer, tsumo integer, deal_in integer, max_tai integer, max_renzhuang integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  /* 每一局（電子計分）的唯一定義。成績頁與賽季排行榜都叫這一支，不要再在別處寫一份。
     場次：已收桌、有名次、有座位（座位號在一場裡代表同一個人）。
     局：只算已入帳、真的打完一把的 —— 胡、自摸、流局、包牌；咔啦碰與分紅是中途另外收分，不是一局。
     p_from     null ＝ 不限時間（生涯）；給值 ＝ 結算時間在那之後（本季）
     p_to       null ＝ 不限；給值 ＝ 結算時間在那之前（不含）—— 歷史累積數據依日期篩選用（2026-10-14）
     p_member_ids null ＝ 這個機構所有人
     2026-10-27：一局幾台改叫 _hand_tai_total（唯一一份；莊家台也乘豹子倍數，跟平板一樣） */
  with mine as (
    select sp.member_id, sp.session_id, sp.seat
      from session_players sp
      join table_sessions s on s.id = sp.session_id
     where sp.org_id    = p_org_id
       and s.org_id     = p_org_id
       and s.deleted_at is null
       and (s.status = 'completed' or sp.finish_rank is not null)
       and sp.finish_rank is not null
       and sp.settled_at  is not null
       and sp.seat is not null
       and (p_from is null or sp.settled_at >= p_from)
       and (p_to   is null or sp.settled_at <  p_to)
       and (p_member_ids is null or sp.member_id = any(p_member_ids))
  ), hh as (
    select m.member_id, h.result, h.renzhuang,
           public._hand_tai_total(h.result, h.tai_pattern, h.patterns,
                                  h.winner_seat, h.deal_in_seat, h.dealer_seat, h.renzhuang) as tai_total,
           coalesce(h.winner_seat = m.seat, false)  as won,
           coalesce(h.deal_in_seat = m.seat, false) as dealt_in,
           coalesce(h.dealer_seat = m.seat, false)  as is_dealer
      from mine m
      join hands h on h.session_id = m.session_id
     where h.status = 'confirmed'
       and h.result in ('tsumo', 'ron', 'draw', 'bao')
  )
  select hh.member_id,
         count(*)::int,
         (count(*) filter (where won and result in ('tsumo', 'ron')))::int,
         (count(*) filter (where won and result = 'tsumo'))::int,
         (count(*) filter (where dealt_in and result = 'ron'))::int,
         (max(tai_total) filter (where won and result in ('tsumo', 'ron')))::int,
         (max(renzhuang) filter (where is_dealer))::int
    from hh
   group by hh.member_id
$function$;

-- ③ 近 30 天最大台的一局
create or replace function public._member_highlight(p_org_id uuid, p_member_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with mine as (
    select sp.session_id, sp.seat, s.store_id, s.table_id
      from session_players sp
      join table_sessions s on s.id = sp.session_id
     where sp.org_id = p_org_id and s.org_id = p_org_id
       and sp.member_id = p_member_id
       and s.deleted_at is null
       and sp.finish_rank is not null
       and sp.settled_at is not null
       and sp.seat is not null
  ), best as (
    select h.*, m.seat as my_seat, m.store_id, m.table_id,
           public._hand_tai_total(h.result, h.tai_pattern, h.patterns,
                                  h.winner_seat, h.deal_in_seat, h.dealer_seat, h.renzhuang) as tai_total,
           coalesce(h.confirmed_at, h.created_at) as at
      from mine m
      join hands h on h.session_id = m.session_id
     where h.status = 'confirmed'
       and h.result in ('tsumo', 'ron')
       and h.winner_seat = m.seat
       and coalesce(h.confirmed_at, h.created_at) >= now() - interval '30 days'
     order by tai_total desc, coalesce(h.confirmed_at, h.created_at) desc
     limit 1
  )
  select jsonb_build_object(
           'tai',       b.tai_total,
           'result',    b.result,
           'renzhuang', coalesce(b.renzhuang, 0),
           'is_dealer', b.dealer_seat = b.my_seat,
           'manual',    coalesce(b.manual_tai, false),
           'at',        b.at,
           'store',     st.name,
           'table',     tb.label,
           'patterns',  coalesce((
              select jsonb_agg(
                       case when x->>'code' = 'baozi' then coalesce(sp.label, '豹子') || ' ×' || ((x->>'n')::int + 1) || ' 倍'
                            when coalesce((x->>'n')::int, 1) > 1 then coalesce(sp.label, x->>'code') || ' ×' || (x->>'n')
                            else coalesce(sp.label, x->>'code') end
                       order by sp.sort nulls last)
                from jsonb_array_elements(coalesce(b.patterns, '[]'::jsonb)) x
                left join scoring_patterns sp on sp.code = x->>'code'
               where x->>'code' <> 'zimo'), '[]'::jsonb))
    from best b
    left join stores st on st.id = b.store_id
    left join tables tb on tb.id = b.table_id;
$$;

revoke execute on function public._member_highlight(uuid, uuid) from public, anon, authenticated;

-- ④-1 自己個人頁讀
create or replace function public.get_my_highlight_tx()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_mem uuid := public.current_member_id();
begin
  if v_mem is null then
    raise exception '未登入，請重新打開 App' using errcode = '28000';
  end if;
  return jsonb_build_object('ok', true,
    'highlight', public._member_highlight(public.current_org_id(), v_mem));
end $$;

revoke execute on function public.get_my_highlight_tx() from public, anon;
grant  execute on function public.get_my_highlight_tx() to authenticated;

-- ④-2 他人個人卡：把那一行 null 換成 ③（只換那一行；找不到就整份退回，不留半套）
do $$
declare
  v_def text := pg_get_functiondef('public.get_member_card_tx'::regproc);
  v_new text;
begin
  v_new := replace(v_def,
    $old$'highlight',  null);$old$,
    $new$'highlight',  case when t.see_score = '只有自己' and v_rel <> 'self' then null
                         else public._member_highlight(v_org, p_target) end);$new$);
  v_new := replace(v_new,
    '/* 最近亮點（最大台的一手）要等電子計分的每一局資料（hands），接上之前一律 null。 */',
    '/* 最近亮點：近 30 天胡過最大台的一局（_member_highlight，2026-10-27）；對方設「只有自己」看成績時一樣不給。 */');
  if v_new = v_def or v_new !~ '_member_highlight\(v_org, p_target\)' then
    raise exception '找不到 get_member_card_tx 裡 highlight 那一行，整份退回（請找開發者重新撈線上版）';
  end if;
  execute v_new;
end $$;

-- ============================================================
-- 驗證（單一 SELECT；不用 raise 印訊息 —— 硬規則 1.8）
-- ============================================================
do $$
declare
  v_msg  text := '';
  v_n    int;
  v_m    int;
  v_k    int;
  v_ex   jsonb;
begin
  -- ① 新函式都在
  select count(*) into v_n from pg_proc where pronamespace = 'public'::regnamespace
     and proname in ('_hand_tai_total', '_member_highlight', 'get_my_highlight_tx');
  v_msg := v_msg || case when v_n = 3 then '✅' else '🔴' end || ' ① 新函式 ' || v_n || E' 支（要 3）\n';

  -- ② 兩個讀的地方都真的呼叫了（問「有沒有呼叫」，不是「有沒有提到」）
  select count(*) into v_n from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname in ('get_member_card_tx', 'get_my_highlight_tx')
     and pg_get_functiondef(p.oid) ~ 'public\._member_highlight\(';
  select count(*) into v_m from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname in ('_member_hand_counts', '_member_highlight')
     and pg_get_functiondef(p.oid) ~ 'public\._hand_tai_total\(';
  v_msg := v_msg || case when v_n = 2 and v_m = 2 then '✅' else '🔴' end
        || ' ② 叫亮點的 ' || v_n || ' 支、叫共用台數的 ' || v_m || E' 支（都要 2）\n';

  -- ③ 共用台數算法改前改後：沒有豹子的局一局都不能變；有豹子又有莊家台的才會變大、不可以變小
  select count(*) filter (where old_t <> new_t and not has_baozi),
         count(*) filter (where new_t > old_t and has_baozi),
         count(*) filter (where new_t < old_t)
    into v_n, v_m, v_k
    from (select coalesce(h.tai_pattern, 0)
                 + case when h.result = 'tsumo' or (h.result = 'ron' and (h.winner_seat = h.dealer_seat or h.deal_in_seat = h.dealer_seat))
                        then 1 + 2 * coalesce(h.renzhuang, 0) else 0 end as old_t,
                 public._hand_tai_total(h.result, h.tai_pattern, h.patterns, h.winner_seat, h.deal_in_seat, h.dealer_seat, h.renzhuang) as new_t,
                 coalesce(h.patterns, '[]'::jsonb) @> '[{"code":"baozi"}]' as has_baozi
            from hands h where h.status = 'confirmed' and h.result in ('tsumo', 'ron')) x;
  v_msg := v_msg || case when v_n = 0 and v_k = 0 and v_m > 0 then '✅' else '🔴' end
        || ' ③ 改算法：沒有豹子卻變了 ' || v_n || ' 局（要 0）、變小 ' || v_k || ' 局（要 0）、豹子局變大 ' || v_m || E' 局（要 > 0，10-27 查是 7）\n';

  -- ④ 正對照：近 30 天至少有一位會員拿得到亮點；印一個例子
  select count(*) into v_n
    from (select distinct sp.member_id, sp.org_id from session_players sp
           where sp.finish_rank is not null and sp.settled_at > now() - interval '30 days') m
   where public._member_highlight(m.org_id, m.member_id) is not null;
  select public._member_highlight(sp.org_id, sp.member_id) into v_ex
    from session_players sp
   where sp.finish_rank is not null and sp.settled_at > now() - interval '30 days'
     and public._member_highlight(sp.org_id, sp.member_id) is not null
   limit 1;
  v_msg := v_msg || case when v_n > 0 then '✅' else '🔴' end
        || ' ④ 近 30 天有亮點的會員 ' || v_n || ' 位（要 > 0）例：'
        || coalesce((v_ex->>'tai') || ' 台 ' || (v_ex->>'result') || ' ' || (v_ex->'patterns')::text, '（沒有）') || E'\n';

  -- ⑤ 授權：個人頁那支給登入的人；三支後端用的前端叫不到；anon／PUBLIC 都叫不到
  select count(*) into v_n
    from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('_hand_tai_total', '_member_highlight', 'get_my_highlight_tx')
     and a.privilege_type = 'EXECUTE'
     and (a.grantee in (0, 'anon'::regrole::oid)
          or (p.proname <> 'get_my_highlight_tx' and a.grantee = 'authenticated'::regrole::oid));
  select count(*) into v_m from pg_proc p where p.pronamespace = 'public'::regnamespace
     and p.proname = 'get_my_highlight_tx' and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  v_msg := v_msg || case when v_n = 0 and v_m = 1 then '✅' else '🔴' end
        || ' ⑤ 不該叫得到的 ' || v_n || ' 個（要 0）、個人頁那支登入的人叫得到 ' || v_m || '（要 1）';

  perform set_config('migi.v', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 驗證段沒有跑到') as "驗證";
