-- ════════════════════════════════════════════════════════════════════
-- 配桌列表的成員補回頭像欄位（2026-09-26）
--
-- 起因：使用者問「為何 POS 的頭像沒有同步」。
-- 查證：POS 畫頭像的地方，資料來源有五支 ——
--   get_session_tx / pos_member_detail_tx / pos_search_members_tx  ✅ 都有回頭像四欄
--   pos_queue_members_tx   ⚪ 沒有，但結帳頁預帶座位時會再叫 pos_member_detail_tx 補齊，所以畫面是對的
--   pos_list_queues_tx     🔴 沒有 ⇒ **配桌列表的座位卡每個人都畫成通用小熊**
-- ✅ 只補這一支的 members：avatar_source / avatar_photo_path / avatar_bear / avatar_url
--   （與 get_session_tx 同一組鍵，POS 的 <Avatar> 直接吃）。
--   隱藏的會員不用另外處理：後端已經把他的 avatar_source 換成 'hidden'，前端畫問號。
--
-- 🔴 其餘部分照 2026-09-26 撈到的線上版逐字保留；CREATE OR REPLACE、簽名不變 ⇒ 授權不會掉。
-- 最後一格「驗證」應該是 4 行 ✅（第 ④ 格在線上沒有等待中的房時會是 ⚪，那不是失敗）。
-- ════════════════════════════════════════════════════════════════════

create or replace function public.pos_list_queues_tx(p_org uuid, p_store uuid, p_before timestamp with time zone default null::timestamp with time zone, p_limit integer default 20)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with live as (
    /* 現在的事：全部回傳，**不分頁**。
       ⚠ 被截掉的話會出現「有一桌在等你結帳但它在第二頁」，
         而店員不會知道要去翻。 */
    select q.id
      from match_queues q
      left join table_sessions ts on ts.id = q.matched_session_id
     where q.org_id = p_org and q.store_id = p_store
       and (
         (q.status = 'waiting'
           and (q.expires_at is null or q.expires_at > now())
           and (q.open_at is null or q.open_at <= now()))
         or q.status = 'matched'
         or (q.status = 'seated' and ts.status = 'open' and ts.deleted_at is null)
       )
  ),
  history as (
    /* 已收桌的：新到舊，分頁。
       🔴 **配桌是延續的** —— 前兩位可能是上一班找到的，靠下一班完成，
         所以這裡**不可以有任何日／班的邊界**（2026-09-07 拿掉了 7 天窗口）。
       ⚠ `p_limit` 夾在 1..100：0 或負數會讓這一段整個消失，
         而症狀是「已完成分頁空的」，看不出是參數問題。 */
    select q.id
      from match_queues q
      join table_sessions ts on ts.id = q.matched_session_id
     where q.org_id = p_org and q.store_id = p_store
       and q.status = 'seated'
       and ts.status = 'completed' and ts.deleted_at is null
       and (p_before is null or ts.ended_at < p_before)
     order by ts.ended_at desc
     limit least(greatest(coalesce(p_limit, 20), 1), 100)
  ),
  picked as (select id from live union select id from history)
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', q.id,
    'status', q.status,
    'source', q.source,
    'stake_level_id', q.stake_level_id,
    'stake', sl.label,
    'game_type', q.game_type, 'flower', q.flower, 'rounds', q.rounds,
    'seats', q.seats,
    'play_at', q.play_at,
    'open_at', q.open_at,
    'recurring_freq', q.recurring_freq,
    'opener', mo.display_name,
    'session_id', q.matched_session_id, 'tags', q.tags,
    'table_label', tb.label,
    'seated_at', case when q.status = 'seated' then q.updated_at else null end,
    /* `auto` = 系統帶的／`manual` = 店員在 POS 按的。
       ⚠ 值不是 `auto` 的一律寫「已帶到 A3」不寫「系統自動」。 */
    'open_method', ts.open_method,
    /* ★ 2026-09-06：這個房還能不能被系統自動配。
       false ＝ 帶到的桌被取消過，之後由店員手動配（隨機／指定）。
       🔴 少了它，`matched` 且沒有桌的房前端**分不出**
         「排程等一下會配」與「在等我動手」。 */
    'auto_seat', q.auto_seat,
    /* 🔴 數的是「這桌收了幾份檯費」，**不要加 `left_at is null`** ——
       收桌時在座玩家一律被寫 `left_at`，那個條件會讓收桌那一刻
       掉回 0，配桌列表就對一個早就收齊的房喊「前往結帳」。
       ⚠ 也不要改成數 `order_id is not null`：暢打的人 order_id 是 null
       （那是「不用付」不是「還沒付」）。 */
    'paid_count', (
      select count(*) from session_players sp
       where sp.session_id = q.matched_session_id),
    'session_status', ts.status,
    'settled_at', ts.ended_at,
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'member_id', m.id, 'nickname', m.display_name,
        'rank', m.rank, 'title', m.title,
        'tier', coalesce(m.tier_override, m.tier),
        'joined_at', p.joined_at,
        'walk_in', p.join_source = 'pos_walkin',
        /* 頭像四欄（2026-09-26）：與 get_session_tx 同一組鍵，POS 的座位卡直接畫。
           少了它們，配桌列表上每個人都是通用小熊。 */
        'avatar_source', m.avatar_source,
        'avatar_photo_path', m.avatar_photo_path,
        'avatar_bear', m.avatar_bear,
        'avatar_url', m.avatar_url
      ) order by p.joined_at)
      from match_queue_players p
      join members m on m.id = p.member_id
      where p.queue_id = q.id and p.left_at is null), '[]'::jsonb)
    /* 排序：現在的事在前；已收桌的之間**依收桌時間新到舊**。
       ⚠ 舊版依 `play_at`（開打時間）—— 往回翻時順序會跳。 */
  ) order by (ts.status is distinct from 'completed') desc,
             (q.status = 'seated') desc,
             (q.status = 'matched') desc,
             ts.ended_at desc nulls last,
             q.play_at), '[]'::jsonb)
  from match_queues q
  join picked pk on pk.id = q.id
  left join stake_levels sl on sl.id = q.stake_level_id and sl.org_id = p_org
  left join members mo on mo.id = q.opened_by
  left join table_sessions ts on ts.id = q.matched_session_id
  left join tables tb on tb.id = ts.table_id
$function$;

-- ── 驗證（只讀，不 raise ⇒ 不會回滾上面的 DDL）──
do $$
declare v text := ''; n int; d text; st uuid; r jsonb; mm jsonb;
begin
  select count(*) into n from pg_proc where pronamespace = 'public'::regnamespace and proname = 'pos_list_queues_tx';
  v := v || case when n = 1 then '✅' else '🔴' end || ' ① 版本數 ' || n || '（應為 1）' || E'\n';

  d := pg_get_functiondef('public.pos_list_queues_tx(uuid,uuid,timestamptz,integer)'::regprocedure);
  v := v || case when d ~ '''avatar_source'', m\.avatar_source' and d ~ '''avatar_photo_path'', m\.avatar_photo_path'
                  and d ~ '''avatar_bear'', m\.avatar_bear' and d ~ '''avatar_url'', m\.avatar_url'
                 then '✅' else '🔴' end || ' ② 成員資料有頭像四欄' || E'\n';

  v := v || case when has_function_privilege('authenticated', 'public.pos_list_queues_tx(uuid,uuid,timestamptz,integer)', 'execute')
                 then '✅' else '🔴' end || ' ③ POS（authenticated）仍然叫得動' || E'\n';

  -- ④ 正對照：真的叫一次，逐店找到「回傳裡有成員」的那一間，看成員身上真的有那四個鍵
  --   ⚠ 配桌列表只回進行中與已收桌的房 ⇒ 不能隨便挑一間有成員的店（可能全是過期的房）
  declare so record;
  begin
    for so in select distinct org_id, store_id from match_queues loop
      r := public.pos_list_queues_tx(so.org_id, so.store_id, null, 100);
      select e -> 'members' -> 0 into mm from jsonb_array_elements(r) e
       where jsonb_array_length(e -> 'members') > 0 limit 1;
      exit when mm is not null;
    end loop;
  end;
  if mm is null then
    v := v || '⚪ ④ 配桌列表現在沒有任何帶成員的房，這一格測不了（不是失敗）' || E'\n';
  else
    v := v || case when mm ? 'avatar_source' and mm ? 'avatar_photo_path' and mm ? 'avatar_bear' and mm ? 'avatar_url'
                   then '✅' else '🔴' end
           || ' ④ 實際回傳的成員有頭像四欄（樣本：' || coalesce(mm ->> 'nickname', '?')
           || '，來源 ' || coalesce(mm ->> 'avatar_source', 'null') || '）' || E'\n';
  end if;

  perform set_config('migi.v', v, true);
end $$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有訊息') as "驗證";
