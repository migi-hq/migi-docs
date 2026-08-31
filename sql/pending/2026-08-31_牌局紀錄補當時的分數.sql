/* ============================================================
   `get_my_games_tx` 補「那一場之後是幾分」　2026-08-31 · MIGI

   ── 為什麼 ──────────────────────────────────────────
   成績頁要畫**段位走勢圖**（本季每一場之後的分數連成一條線）。
   資料本來就在 `session_players.rating_after`，只是這支沒回傳。

   🔴 **老實說：這個欄位是 2026-08-31 我自己加的，而當時我給的理由是編的。**
     我在檔頭寫「成績頁要畫段位走勢圖就需要它」——
     **那時候沒有任何人說過要做走勢圖**，我是從對 LOL 的印象推出一個需求，
     再用那個需求去合理化一個欄位。
     📌 那正是 CLAUDE.md 反覆記的「建了沒人讀」，而我一邊引用那條規則一邊犯它。
   ✅ 今天使用者決定要做走勢圖，所以它**現在才真的有讀者**。

   ── ⚠ 為什麼不另開一支「走勢」RPC ────────────────────
   成績頁**本來就已經呼叫 `get_my_games_tx(50)`** 了。
   多兩個欄位 = **零額外請求**；另開一支則是同一份資料查兩次，
   而且兩支的「哪些場次算數」邏輯會各寫一份 —— 那一定會漂。

   ── 改什麼 ──────────────────────────────────────────
   `mine` CTE 多帶兩欄，輸出多兩個鍵：
     `my_rating_after`（那一場結算後的段位分數）
     `settled_at`（什麼時候結算的 —— 走勢圖的 X 軸）
   ✅ 簽名沒變 → `CREATE OR REPLACE`，不用 DROP、不掉 GRANT、前端可先部署。

   ⚠ **撈全文重建，不用 DO 區塊打補丁**（硬規則：同一支要改三處以上就重建）。
   ⚠ M4／電子計分之前這兩個欄位**全部是 null** —— 那是預期的，不是壞掉。
   ============================================================ */

create or replace function public.get_my_games_tx(
  p_org_id uuid, p_member_id uuid, p_limit integer default 20
) returns jsonb
language sql stable security definer set search_path to 'public'
as $function$
  with mine as (
    -- 從「我坐過的位子」反查場次 —— 不需要知道那桌是怎麼開的。
    -- （配桌與開桌的關聯在 match_queues.matched_session_id，這裡用不到）
    select s.id, s.mode, s.store_id, s.stake_level_id,
           s.game_type, s.flower, s.planned_rounds,
           s.started_at, s.activated_at, s.ended_at,
           sp.finish_rank      as my_rank,
           sp.score_points     as my_score,
           sp.charged_points   as my_charged,
           sp.fee_waived_amount as my_waived,
           sp.seat             as my_seat,
           -- ★ 2026-08-31：走勢圖用。M4 之前是 null。
           sp.rating_after     as my_rating_after,
           sp.settled_at       as my_settled_at
      from session_players sp
      join table_sessions s on s.id = sp.session_id
     where sp.member_id = p_member_id
       and sp.org_id    = p_org_id
       and s.org_id     = p_org_id
       and s.deleted_at is null
       and s.status     = 'completed'
     order by s.ended_at desc nulls last
     limit greatest(coalesce(p_limit, 20), 1)
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'session_id', m.id,
      -- table_sessions.mode ∈ matched / private，就是配桌 vs 包桌
      'kind',   case when m.mode = 'private' then 'package' else 'match' end,
      -- 已收桌但還沒結算戰績 → pending；有名次 → settled
      -- （M4 之前全部都是 pending，那是預期的）
      'status', case when m.my_rank is not null then 'settled' else 'pending' end,
      'store',      st.name,
      'addr',       st.address,
      'game_type',  m.game_type,
      'flower',     m.flower,
      'rounds',     m.planned_rounds,     -- 整數，「幾將」由前端組字
      'stake',      sl.label,             -- 積分級距顯示名，例如 50/20、純娛樂麻將
      -- 開打時間用 activated_at（帶桌／真正開打），沒有才退回 started_at（開桌）
      'started_at', coalesce(m.activated_at, m.started_at),
      'ended_at',   m.ended_at,
      'duration_minutes',
        case when m.ended_at is not null
             then greatest(0, (extract(epoch from
                    (m.ended_at - coalesce(m.activated_at, m.started_at))) / 60)::int)
             else null end,
      'my_rank',          m.my_rank,      -- M4 之前是 null
      'my_score',         m.my_score,     -- M4 之前是 null
      'my_charged_points', m.my_charged,
      'my_fee_waived',     m.my_waived,   -- 暢打／店員／店長特調免收的金額
      'my_seat',           m.my_seat,
      /* ★ 2026-08-31 新增：走勢圖的兩個座標。
         ⚠ `settled_at` 不能用 `ended_at` 代替 —— 收桌與結算是兩個動作
           （名次可能是之後才登記的），而走勢圖畫的是**分數變動的時間**。 */
      'my_rating_after',   m.my_rating_after,
      'settled_at',        m.my_settled_at,
      'players', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'member_id',    p.member_id,
                 'nickname',     mem.display_name,
                 'rank',         mem.rank,
                 'avatar_url',        mem.avatar_url,
                 'avatar_source',     mem.avatar_source,
                 'avatar_photo_path', mem.avatar_photo_path,
                 'avatar_bear',       mem.avatar_bear,
                 'title',        mem.title,
                 'seat',         p.seat,
                 'finish_rank',  p.finish_rank,
                 'score_points', p.score_points,
                 'is_me',        p.member_id = p_member_id
               ) order by coalesce(p.finish_rank, 99), p.seat nulls last, p.joined_at)
          from session_players p
          join members mem on mem.id = p.member_id
         where p.session_id = m.id), '[]'::jsonb)
    ) order by m.ended_at desc nulls last
  ), '[]'::jsonb)
  from mine m
  left join stores       st on st.id = m.store_id       and st.org_id = p_org_id
  left join stake_levels sl on sl.id = m.stake_level_id and sl.org_id = p_org_id
$function$;


-- ── 驗證（交易內造資料 → 測 → 回滾）────────────────────
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_out text := ''; v_st uuid; v_tbl uuid; v_store uuid;
  a uuid; b uuid; c uuid; d uuid; g jsonb; one jsonb;
begin
  begin
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

    /* 🔴 **先驗「還沒結算」那一格**：M4 之前兩個欄位都該是 null，
       而 `status` 要是 `pending`。少了這一格的話，
       「函式根本沒回這兩個鍵」跟「回了但值是 null」分不出來。 */
    one := public.get_my_games_tx(v_org, a, 10) -> 0;
    v_out := v_out || E'\n' || '① 還沒結算：兩個鍵都在但都是 null' || E'\t' ||
      case when (one ? 'my_rating_after') and (one ? 'settled_at')
                and one->>'my_rating_after' is null and one->>'settled_at' is null
                and one->>'status' = 'pending'
           then '✅ 鍵在、值 null、status=pending'
           else '🔴 ' || coalesce(one->>'status','?') || ' / '
                || coalesce(one->>'my_rating_after','(沒有這個鍵)') end;

    ---- 結算兩將（甲全部第 1）--------------------------------
    perform public.apply_session_rounds_tx(v_st, (
      select jsonb_agg(jsonb_build_array(
        jsonb_build_object('member_id',a,'finish_rank',1),
        jsonb_build_object('member_id',b,'finish_rank',2),
        jsonb_build_object('member_id',c,'finish_rank',3),
        jsonb_build_object('member_id',d,'finish_rank',4)))
      from generate_series(1,2)));

    one := public.get_my_games_tx(v_org, a, 10) -> 0;
    /* 甲兩將都第 1，低段 +30 × 2 → 1060 */
    v_out := v_out || E'\n' || '② 結算後 my_rating_after = 1060' || E'\t' ||
      case when (one->>'my_rating_after')::int = 1060 then '✅ 1060'
           else '🔴 ' || coalesce(one->>'my_rating_after','null') end;
    v_out := v_out || E'\n' || '③ settled_at 有值（走勢圖的 X 軸）' || E'\t' ||
      case when one->>'settled_at' is not null then '✅ 有'
           else '🔴 null —— 走勢圖畫不出來' end;
    v_out := v_out || E'\n' || '④ status 變成 settled' || E'\t' ||
      case when one->>'status' = 'settled' then '✅ settled'
           else '🔴 ' || coalesce(one->>'status','?') end;

    /* 🔴 **正對照：其餘欄位一個都不能少。**
       這支是撈全文重建的 —— 漏抄一段的話上面那三格照樣會過。 */
    v_out := v_out || E'\n' || '⑤ 正對照：原有的鍵一個都沒少' || E'\t' ||
      case when (select count(*) from jsonb_object_keys(one)) = 20
           then '✅ 20 個鍵'
           else '🔴 ' || (select count(*) from jsonb_object_keys(one)) || ' 個（原本 18 ＋ 新增 2）' end;
    v_out := v_out || E'\n' || '⑥ 正對照：players 裡的頭像四欄還在' || E'\t' ||
      case when (one->'players'->0) ?& array['avatar_url','avatar_source','avatar_photo_path','avatar_bear']
           then '✅ 四欄都在' else '🔴 掉了' end;
    v_out := v_out || E'\n' || '⑦ 正對照：模式／揮發性／授權沒被動到' || E'\t' ||
      (select case when p.prosecdef and p.provolatile='s' and p.prolang=(select oid from pg_language where lanname='sql')
                    and exists (select 1 from aclexplode(p.proacl) x
                                 where x.grantee='anon'::regrole::oid and x.privilege_type='EXECUTE')
                   then '✅ DEFINER／STABLE／sql／anon 有'
                   else '🔴 有東西被改到' end
         from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='get_my_games_tx');

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.games2', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.games2', true), E'\n')) as x
 where coalesce(x,'') <> '';
