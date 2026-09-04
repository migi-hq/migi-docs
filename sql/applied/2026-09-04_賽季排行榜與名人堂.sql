/* ============================================================
   賽季排行榜與名人堂：`get_season_leaderboard_tx`
   2026-09-04 · MIGI · 待辦 33「排行榜／名人堂接真資料」

   ── 這一份在做什麼 ──────────────────────────────────
   一支給會員 App 的公開排行榜 RPC，回三樣東西：
   · `season`     本季資訊（借 `current_season_tx`）
   · `rows`       本季前 N 名（借 `season_rank_rows_tx`）
   · `champions`  名人堂 · 歷代雀神熊（`season_champions`）

   ============================================================
   🔴 一個差點寫進去的洞：**不可以回傳 `member_id`**
   ============================================================
   排行榜回 `member_id` 等於**公開發送一批會員 uuid**，而
   `get_wallet_tx` / `get_my_orders_tx` 今天仍然是
   **`anon` ＋ 前端送 `p_member_id`**（待辦 14 還沒做）
   ⇒ **任何人拿榜上的 id 就能看到那個人的餘額與完整消費明細。**

   ✅ 好消息是**根本不需要回**：前端點卡片開的
   `setHallCard({ ini, av, rank, … })` 本來就只用清單裡的資料，
   不會再查後端。
   ⚠ **待辦 14 做完之後也不要順手加回去** —— 排行榜是「這些人很強」，
     不是「這些人是誰」。名次不需要身分。

   ============================================================
   🎯 名次的定義只有一份：`season_rank_rows_tx`
   ============================================================
   它已經被 `get_my_stats_tx`（我在全國第幾）與
   `reset_season_ratings_tx`（賽季結算）共用。排行榜**必須用同一支** ——
   自己寫一份 `order by rating desc` 的話，會出現
   「我的成績頁說我第 3，排行榜說我第 4」而**兩邊都不算 bug**。

   ✅ 查證過它已經排除測試帳號（`mem.is_test = false`）與軟刪，
     而且母體是「這個視窗內至少打過一場**已結算**牌局的人」——
     不是全部會員（`members.rating` 是 NOT NULL DEFAULT 0，
     拿全部人排的話分母會變成「開過帳號的人數」）。

   ============================================================
   ⚠ 今天接上去會是**空的**，而那是正確的
   ============================================================
   ```
   本季有段位分的會員   4 個  →  其中**非測試 0 個**
   season_champions              **0 筆**
   ```
   · **排行榜**：上線後有真客人打牌就會有 ⇒ 空狀態是暫時的
   · **名人堂**：它是「歷代雀神熊」，需要**賽季結算過至少一次**，
     而本季（`2026H2`）到 **2027-01-01** 才結束
     ⇒ 🔴 **它必然空到 2027 年 1 月**，那不是「還沒接」是**規則本身**。
   → 前端的空狀態要說明**為什麼**空（「本季結束後產生第一位雀神熊」），
     那是**規則說明**不是「即將推出」。

   ============================================================
   🔴 驗證的陷阱：回 0 列同時是「正確」與「壞掉」的症狀
   ============================================================
   硬規則 3.55：**只驗「應該是 0」的那一半，等於沒驗。**
   → 所以驗證段有一格**正對照**：在交易內暫時把一個測試帳號
     `is_test` 設成 false，看它會不會**真的冒出來**，然後整段回滾。
   ⚠ 沒有那一格的話，一支 `select ... where false` 也會全部變綠。
   ============================================================ */

create or replace function public.get_season_leaderboard_tx(
  p_org_id uuid,
  p_limit  int default 10
) returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_season jsonb;
  v_rows   jsonb;
  v_champ  jsonb;
  v_n      int;
begin
  /* ⚠ 上限保護：前端送 100000 的話這支會把整個榜撈出來。
     `least` 而不是 raise —— 那是筆誤不是攻擊，靜靜收斂即可。 */
  v_n := greatest(1, least(coalesce(p_limit, 10), 100));

  v_season := public.current_season_tx(p_org_id);

  /* 🔴 沒有進行中的賽季時 **不要回 `ok:false`** ——
     那是**正常狀態**（兩季之間的空檔），不是錯誤。
     回空清單讓前端畫空狀態就好。 */
  if v_season is null then
    return jsonb_build_object('ok', true, 'season', null,
                              'rows', '[]'::jsonb, 'champions', '[]'::jsonb);
  end if;

  /* 本季排行。`p_to` 給 null = 沒有上限（現場排名），
     與 `get_my_stats_tx` 算「我在全國第幾」時同一個用法。 */
  select coalesce(jsonb_agg(x order by x.rank_no), '[]'::jsonb) into v_rows
    from (
      select r.rank_no, r.rating, r.games,
             m.display_name        as name,
             public.rank_from_rating(r.rating) as rank_label
             -- 🔴 **沒有 member_id**，理由見檔頭
        from public.season_rank_rows_tx(
               p_org_id, (v_season ->> 'starts_at')::timestamptz, null) r
        join members m on m.id = r.member_id
       order by r.rank_no
       limit v_n
    ) x;

  /* 名人堂：歷代雀神熊。
     ⚠ `season_champions` 的資料來自 `reset_season_ratings_tx`，
       而那支用的是已經排除測試帳號的 `season_rank_rows_tx` ——
       但這裡**再擋一次**：主檔可能被手動塞過，而排行榜是對外的。 */
  select coalesce(jsonb_agg(x order by x.awarded_at desc), '[]'::jsonb) into v_champ
    from (
      select c.season, c.rating, c.awarded_at,
             s.label               as season_label,
             m.display_name        as name,
             public.rank_from_rating(c.rating) as rank_label
        from season_champions c
        join members m on m.id = c.member_id
                      and m.deleted_at is null
                      and m.is_test = false
        left join rank_seasons s on s.org_id = c.org_id and s.code = c.season
       where c.org_id = p_org_id
       order by c.awarded_at desc
       limit 20
    ) x;

  return jsonb_build_object(
    'ok', true, 'season', v_season, 'rows', v_rows, 'champions', v_champ);
end;
$function$;

comment on function public.get_season_leaderboard_tx(uuid, int) is
  '公開的賽季排行榜與名人堂。名次借 season_rank_rows_tx（唯一定義）。'
  '🔴 刻意不回傳 member_id —— 那在待辦 14 完成前等於通行證。';

/* ✅ **這一支給 anon** —— 它是公開排行榜，而會員 App 用 anon key。
   ⚠ 但仍然要走 `revoke public` ＋ 明確 `grant anon`（硬規則 2.6b 兩個方向），
     不要靠 PUBLIC 繼承 —— 那是預設值不是決定。 */
revoke execute on function public.get_season_leaderboard_tx(uuid, int) from public;
grant  execute on function public.get_season_leaderboard_tx(uuid, int)
  to anon, authenticated, service_role;


-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
do $$
declare
  v_out text := '';
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_r jsonb; v_n int; v_mid uuid;
begin
  begin
    ---- ① 基本形狀 -------------------------------------
    v_r := public.get_season_leaderboard_tx(v_org, 10);
    v_out := v_out || E'\n' || '① 回得出三個區塊' || E'\t' ||
      case when (v_r ? 'season') and (v_r ? 'rows') and (v_r ? 'champions')
           then '✅ season／rows／champions' else '🔴 ' || v_r::text end;

    v_out := v_out || E'\n' || '② 本季資訊' || E'\t' ||
      coalesce((v_r -> 'season' ->> 'label') || ' · 還有 ' ||
               (v_r -> 'season' ->> 'days_left') || ' 天', '🔴 沒有進行中的賽季');

    v_out := v_out || E'\n' || '③ 目前榜上人數（今天應該是 0）' || E'\t' ||
      jsonb_array_length(v_r -> 'rows')::text ||
      case when jsonb_array_length(v_r -> 'rows') = 0
           then ' —— ✅ 非測試會員 0 個，符合預期' else '' end;

    v_out := v_out || E'\n' || '④ 名人堂筆數（必然是 0 到 2027-01）' || E'\t' ||
      jsonb_array_length(v_r -> 'champions')::text ||
      case when jsonb_array_length(v_r -> 'champions') = 0
           then ' —— ✅ 本季還沒結算過' else '' end;

    ---- ⑤ 🔴 正對照：讓它「應該有資料」，看會不會冒出來 ----
    /* 🎯 **這一格是整份驗證的重點**（硬規則 3.55）。
       ③④ 回 0 同時是「正確」與「整支寫壞了」的症狀 ——
       兩者長得一模一樣。所以要**故意製造一筆該出現的資料**。
       ⚠ 挑一個**真的打過已結算牌局**的測試帳號，暫時把 is_test 關掉。
         整段會回滾，那個旗標不會真的變。 */
    select sp.member_id into v_mid
      from session_players sp
      join table_sessions s on s.id = sp.session_id
      join members m on m.id = sp.member_id
     where sp.org_id = v_org and s.status = 'completed'
       and sp.finish_rank is not null and sp.settled_at is not null
       and m.is_test and m.deleted_at is null
       and sp.settled_at >= (v_r -> 'season' ->> 'starts_at')::timestamptz
     limit 1;

    if v_mid is null then
      v_out := v_out || E'\n' || '⑤ 🔴 正對照' || E'\t' ||
        '⚠ 找不到本季有已結算牌局的測試帳號 —— **這一格沒驗到，不要當成通過**';
    else
      update members set is_test = false where id = v_mid;
      v_r := public.get_season_leaderboard_tx(v_org, 10);
      v_n := jsonb_array_length(v_r -> 'rows');
      v_out := v_out || E'\n' || '⑤ 🎯 正對照：關掉一個 is_test 就冒出來' || E'\t' ||
        case when v_n > 0
             then '✅ ' || v_n || ' 列（' || (v_r -> 'rows' -> 0 ->> 'name') ||
                  ' · #' || (v_r -> 'rows' -> 0 ->> 'rank_no') ||
                  ' · ' || (v_r -> 'rows' -> 0 ->> 'rating') || ' 分 · ' ||
                  (v_r -> 'rows' -> 0 ->> 'rank_label') || '）'
             else '🔴 還是 0 列 —— 那 ③ 的 0 不代表正確，這支可能是壞的' end;

      ---- ⑥ 🔴 沒有洩漏 member_id -----------------------
      v_out := v_out || E'\n' || '⑥ 🔴 rows 裡沒有 member_id（那是通行證）' || E'\t' ||
        case when not ((v_r -> 'rows' -> 0) ? 'member_id') then '✅ 沒有這個鍵'
             else '🔴 洩漏了 —— 拿它就能查別人的錢包' end;

      ---- ⑦ 段位名稱轉得出來 ---------------------------
      v_out := v_out || E'\n' || '⑦ 段位名稱有轉（不是 null）' || E'\t' ||
        case when (v_r -> 'rows' -> 0 ->> 'rank_label') is not null
             then '✅ ' || (v_r -> 'rows' -> 0 ->> 'rank_label') else '🔴 null' end;

      ---- ⑧ p_limit 的上限保護 -------------------------
      v_r := public.get_season_leaderboard_tx(v_org, 100000);
      v_out := v_out || E'\n' || '⑧ p_limit 送 100000 不會炸' || E'\t' ||
        '✅ 回 ' || jsonb_array_length(v_r -> 'rows') || ' 列（內部收斂到 100）';
    end if;

    ---- ⑨ 授權 -----------------------------------------
    v_out := v_out || E'\n' || '⑨ anon 明確授權、PUBLIC 已收' || E'\t' ||
      (select case when a and not p then '✅'
                   else '🔴 anon=' || a || ' public=' || p end
         from (select
                 exists (select 1 from aclexplode(coalesce(pr.proacl,'{}')) x
                          where x.grantee='anon'::regrole::oid and x.privilege_type='EXECUTE') a,
                 (pr.proacl is null or exists (select 1 from aclexplode(pr.proacl) x
                          where x.grantee=0 and x.privilege_type='EXECUTE')) p
                from pg_proc pr where pr.pronamespace='public'::regnamespace
                 and pr.proname='get_season_leaderboard_tx') z);

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.lb', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.lb', true), E'\n')) as x
 where coalesce(x,'') <> '';
