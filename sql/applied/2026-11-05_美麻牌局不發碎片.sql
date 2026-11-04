/* ============================================================
   美麻牌局不發碎片（2026-11-05 使用者：「要排除美麻牌局發碎片」）

   改兩處，同一個條件：場次的 game_type 是「美麻」⇒ 沒有碎片。
   ① trg_hands_shards（入帳時發碎片的觸發器）：美麻跟好友練習賽一樣，整場不發
      —— 撤銷那一段不動：以前發過的局被撤銷，照樣收回
   ② _tbl_state_for_device 的 pending.shards：美麻回 0 ⇒ 計分板「這局獲得 N 個碎片」不畫
      （my_shards 讀帳本，帳本沒有就不畫，不用另外改）

   game_type 是 null 的舊場次算台麻（同計分板 supported 的判斷 coalesce(game_type, '台麻')）。

   ③ 收回以前美麻發出去的（2026-11-05 使用者：「美麻不發 定案，之前發的收回」）
      只有 10-09 那一場（其餘 17 場美麻都是 8 月作廢的測試桌，一局都沒入帳）：
        Y 22、Jun 21、yuhsin 16、澤 11，共 70 個；四人都還沒在商城花過（11-05 查）
      帳本只能新增 ⇒ 每人補一筆 reason = 'admin' 的負數，原本那幾筆不動
      · 數量 ＝ 那個人在美麻場次「hand ＋ hand_undo」的淨額，跑的當下才算（不寫死 70）
      · idem_key 'mahjong_us_revoke:<場次>:<會員>' ⇒ 重跑不會扣兩次
      · 🔴 收回之後有人會變成負數（代表這段時間已經花掉了）⇒ 整份中止、什麼都不改，回報給我再決定
   ============================================================ */

-- ① 入帳時發碎片的觸發器（全文照線上版，只在 v_ok 加一個條件）
create or replace function public.trg_hands_shards()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_qty    int;
  v_member uuid;
  v_ok     boolean;
begin
  -- 入帳：變成 confirmed 的那一刻（新增時就是 confirmed 也算）
  if new.status = 'confirmed'
     and (tg_op = 'INSERT' or old.status is distinct from 'confirmed')
     and new.result in ('ron', 'tsumo') then
    -- 好友練習賽、美麻（2026-11-05）都不發
    select (s.deleted_at is null and s.status <> 'voided' and coalesce(s.mode, '') <> 'friendly'
            and coalesce(s.game_type, '台麻') <> '美麻')
      into v_ok
      from table_sessions s where s.id = new.session_id;
    if coalesce(v_ok, false) then
      v_qty := public._hand_shards(new.patterns);
      if v_qty > 0 then
        -- 給「這一刻」坐在胡牌位置的人（換人上桌之後也不會跟著位置走）
        select sp.member_id into v_member
          from session_players sp
         where sp.session_id = new.session_id and sp.seat = new.winner_seat
         limit 1;
        if v_member is not null then
          insert into shard_grants (org_id, member_id, qty, reason, ref_id, idem_key)
          values (new.org_id, v_member, v_qty, 'hand', new.id, 'hand:' || new.id)
          on conflict (idem_key) do nothing;
        end if;
      end if;
    end if;
  end if;

  -- 撤銷：從 confirmed 變成別的狀態 ⇒ 把那一局發的收回（記給當初拿到的那一位）
  if tg_op = 'UPDATE' and old.status = 'confirmed' and new.status is distinct from 'confirmed' then
    insert into shard_grants (org_id, member_id, qty, reason, ref_id, idem_key)
    select g.org_id, g.member_id, -g.qty, 'hand_undo', g.ref_id, 'hand_undo:' || new.id
      from shard_grants g
     where g.idem_key = 'hand:' || new.id
    on conflict (idem_key) do nothing;
  end if;

  return null;
end $function$;

-- ② 計分板待確認那一局的碎片數：美麻回 0（撈線上全文、只換一個錨點；找不到就整份中止）
do $$
declare
  v_def text := pg_get_functiondef('public._tbl_state_for_device'::regproc);
  v_old text := 'case when h.result in (''ron'', ''tsumo'') and coalesce(s.mode, '''') <> ''friendly'' then public._hand_shards';
  v_new text := 'case when h.result in (''ron'', ''tsumo'') and coalesce(s.mode, '''') <> ''friendly'''
                || ' and coalesce(s.game_type, ''台麻'') <> ''美麻'' then public._hand_shards';
begin
  if v_def like '%<> ''美麻'' then public._hand_shards%' then
    raise exception '已經改過了，不要重跑';
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception '錨點不是剛好一處（先跑 2026-11-05_計分板回傳碎片數.sql 了嗎？），先撈全文看';
  end if;
  execute replace(v_def, v_old, v_new);
end $$;

-- ③ 收回以前美麻發出去的碎片
do $$
declare v_neg text;
begin
  with owed as (
    select g.org_id, g.member_id, h.session_id, sum(g.qty)::int as q
      from public.shard_grants g
      join public.hands h on h.id = g.ref_id
      join public.table_sessions s on s.id = h.session_id
     where s.game_type = '美麻' and g.reason in ('hand', 'hand_undo')
     group by 1, 2, 3 having sum(g.qty) > 0)
  select string_agg(m.display_name || '（剩 ' || bal.t || '、要收 ' || o.q || '）', '、')
    into v_neg
    from owed o join public.members m on m.id = o.member_id
    cross join lateral (select coalesce(sum(x.qty), 0) t from public.shard_grants x where x.member_id = o.member_id) bal
   where bal.t < o.q
     and not exists (select 1 from public.shard_grants y
                      where y.idem_key = 'mahjong_us_revoke:' || o.session_id || ':' || o.member_id);
  if v_neg is not null then
    raise exception '收回之後會變負數（已經花掉了）：%。整份中止、什麼都沒改', v_neg;
  end if;

  insert into public.shard_grants (org_id, member_id, qty, reason, ref_id, idem_key)
  select o.org_id, o.member_id, -o.q, 'admin', o.session_id,
         'mahjong_us_revoke:' || o.session_id || ':' || o.member_id
    from (select g.org_id, g.member_id, h.session_id, sum(g.qty)::int as q
            from public.shard_grants g
            join public.hands h on h.id = g.ref_id
            join public.table_sessions s on s.id = h.session_id
           where s.game_type = '美麻' and g.reason in ('hand', 'hand_undo')
           group by 1, 2, 3 having sum(g.qty) > 0) o
  on conflict (idem_key) do nothing;
end $$;

/* ── 驗證（單一 SELECT）──
   ⚠ 這裡看到的是交易內的狀態；跑完之後我會另外查一次線上（硬規則 1.8） */
select string_agg(項, E'\n' order by n) as "驗證" from (
  select 1 as n, case when pg_get_functiondef('public.trg_hands_shards'::regproc) ~ 'coalesce\(s\.game_type, ''台麻''\) <> ''美麻'''
                      then '✅ ① 發碎片的觸發器排除美麻' else '🔴 ① 觸發器沒有美麻條件' end as 項
  union all
  select 2, case when pg_get_functiondef('public.trg_hands_shards'::regproc) ~ '''friendly'''
                  and pg_get_functiondef('public.trg_hands_shards'::regproc) ~ 'hand_undo'
                 then '✅ ② 好友練習賽排除、撤銷收回都還在' else '🔴 ② 原本的條件不見了' end
  union all
  select 3, case when exists (select 1 from pg_trigger where tgname = 'trg_hands_shards' and tgrelid = 'hands'::regclass and tgenabled <> 'D')
                 then '✅ ③ 觸發器還掛在 hands 上、啟用中' else '🔴 ③ 觸發器不見或停用' end
  union all
  select 4, case when pg_get_functiondef('public._tbl_state_for_device'::regproc) ~ '''美麻'' then public\._hand_shards'
                  and pg_get_functiondef('public._tbl_state_for_device'::regproc) ~ '''my_shards'', \(select'
                 then '✅ ④ 計分板待確認那一局美麻回 0，my_shards 還在' else '🔴 ④ 計分板那支沒改到' end
  union all
  select 5, case when (select count(*) from pg_proc where proname in ('trg_hands_shards', '_tbl_state_for_device')
                        and pronamespace = 'public'::regnamespace) = 2
                 then '✅ ⑤ 兩支都只有一個版本' else '🔴 ⑤ 版本數不對' end
  union all
  /* ⑥ 收回：美麻場次的碎片淨額歸零（期望：發出 70、收回 70、淨額 0） */
  select 6, (select case when coalesce(sum(g.qty), 0) = 0 and count(*) filter (where g.reason = 'admin') > 0
                         then '✅ ⑥ 美麻場次碎片淨額 0：發出 ' || sum(g.qty) filter (where g.qty > 0)
                              || '、收回 ' || -sum(g.qty) filter (where g.reason = 'admin')
                         else '🔴 ⑥ 美麻場次碎片淨額 ' || coalesce(sum(g.qty), 0) || '（收回 '
                              || count(*) filter (where g.reason = 'admin') || ' 筆）' end
               from public.shard_grants g
               join public.table_sessions s on s.id = g.ref_id
                 or s.id = (select h.session_id from public.hands h where h.id = g.ref_id)
              where s.game_type = '美麻')
  union all
  /* ⑦ 四個人收回之後的碎片總數，沒有人是負的 */
  select 7, coalesce((select '✅ ⑦ 收回後：' || string_agg(m.display_name || ' ' || t.tot, '、' order by m.display_name)
                         || case when bool_or(t.tot < 0) then E'\n  🔴 有人變成負數' else '' end
                        from (select g.member_id, (select sum(x.qty) from public.shard_grants x where x.member_id = g.member_id) tot
                                from public.shard_grants g where g.idem_key like 'mahjong_us_revoke:%') t
                        join public.members m on m.id = t.member_id), '🔴 ⑦ 沒有收回的紀錄')
) v;
