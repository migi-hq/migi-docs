/* ============================================================
   `list_tables_tx` 收掉 `players`　2026-09-01 · MIGI
   **待辦 35 的最後一步 —— 一個名字兩種形狀從此消失。**

   ── 這個病是什麼 ────────────────────────────────────
   ```
   list_match_queues_tx   'players' = count(*)   ← 數字
   list_tables_tx         'players' = count(*)   ← 數字
   get_my_active_queue_tx 'players' = [...]      ← 陣列
   get_my_games_tx        'players' = [...]      ← 陣列
   ```
   🔴 已經真的炸過：`app_error` 裡
   `(t.players || []).map is not a function` ×5（2026-08-22）。

   ⚠ **`(x || []).map` 只擋 null／undefined，擋不住「是數字」這種真值** ——
     數字原樣通過 `|| []`，然後 `.map` 直接炸。
     **`|| []` 給了一種「我防過了」的錯覺，那比完全沒防更危險。**

   ── expand → migrate → contract ───────────────────
   | | 什麼時候 | 做了什麼 |
   |---|---|---|
   | expand | 2026-08-29 | 補 `player_count`，**兩者並存** |
   | migrate | 2026-08-29 `aa363ac` | POS 的 `App.jsx:306` 改讀 `player_count` |
   | **contract** | **今天** | 拿掉 `players` |

   🎯 **中間那段並存的時間就是這套做法的全部意義** ——
     少了它，還在跑舊版的平板會讓桌況卡的人數**變成空白而且不報錯**。
   ✅ 已查證可以收：
   · `list_tables_tx` **只有 POS 在叫**（`migi-pos/src/lib/api.js:131`），
     migi-web 與 migi-admin 都沒有
   · POS 讀的是 `player_count`（`App.jsx:306`），全專案沒有任何地方
     從這支的回傳讀 `players`
   · `aa363ac` 在 `origin/main` 上而且上面還疊了一版
     ⇒ Cloudflare 早就部署過了

   ⚠ **`pos_add_queue_member_tx` 的 `players` 刻意不動** ——
     它回的是「加入之後現在幾人」，是**一次性的操作結果**不是清單欄位，
     而且從來沒有陣列版本。改它只是製造一次沒有收益的部署順序問題。

   ✅ 簽名不變 → `CREATE OR REPLACE`，不用 DROP、不掉 GRANT。
   ⚠ **撈全文重建**（硬規則：改三處以上不要堆 DO 區塊）。
   ============================================================ */

create or replace function public.list_tables_tx(p_org_id uuid, p_store_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', t.id, 'label', t.label, 'area', t.area, 'seats', t.seats,
      'is_active', t.is_active, 'note', t.note,

      -- ⚠ status 維持三值（off / use / idle），不新增 'hold'。
      --    舊版 POS 遇到沒見過的值會掉進「停用」分支畫成灰卡，比現況更糟。
      'status', case
                  when not t.is_active then 'off'
                  when ts.id is not null then 'use'
                  else 'idle' end,

      'session_id', ts.id,
      'started_at', ts.started_at,
      'planned_minutes', ts.planned_minutes,
      'stake_level_id', ts.stake_level_id,
      'mode', ts.mode,

      -- 在座人數：session_players 是**結帳成功後**才建立的，
      -- 所以「還沒有人結帳」與「還沒有人到」在這個系統裡是同一件事。
      /* ★ 2026-09-01 contract：`players` 已移除，只剩 `player_count`。
         🔴 **不要再加回一個叫 `players` 的東西** —— 這個名字在別的 RPC
           是陣列（`get_my_games_tx` / `get_my_active_queue_tx`），
           而混用已經真的炸過五次。**一個名字一個意思。**
         ⚠ 要回傳「有哪些人」的話請叫 `player_names`（比照 `queue_members`）。 */
      'player_count', coalesce(pl.n, 0),

      -- ── 預留中 ───────────────────────────────────────────
      -- 桌開著但一個人都還沒入座。畫面上必須跟「真的有人在打」分開，
      -- 否則店員會把現場客人推掉（見檔頭）。
      'is_hold', (ts.id is not null and coalesce(pl.n, 0) = 0),

      -- queue = 配桌湊滿自動佔的（客人還沒到，要等）
      -- setup = 店員按了開桌設定還沒結帳（他一分鐘前的動作，點進去繼續）
      'hold_kind', case
                     when ts.id is null or coalesce(pl.n, 0) > 0 then null
                     when mq.id is not null then 'queue'
                     else 'setup' end,

      'queue_id',       mq.id,
      'queue_play_at',  mq.play_at,
      -- 誰要來。⚠ 只算沒離開的（left_at is null）——
      -- 報名後又退出的人不該出現在「等一下會來這桌」的名單裡。
      'queue_members',  coalesce(mq.names, '[]'::jsonb),

      -- ── 現場專用 ─────────────────────────────────────────
      -- false = 這張桌不給系統自動配。是**店員的意思**，沒人改就不會變，
      -- 所以它是欄位不是算出來的（桌況本身仍然是每次從 table_sessions 算）。
      'auto_assign', t.auto_assign

    ) order by t.sort_order, t.label)
    from tables t

    left join lateral (
      select ts.* from table_sessions ts
       where ts.table_id = t.id and ts.status = 'open' and ts.deleted_at is null
       order by ts.started_at desc limit 1
    ) ts on true

    -- 在座人數獨立拉出來：is_hold 與 player_count 都要用，算兩次會有機會寫歪一次
    left join lateral (
      select count(*)::int as n
        from session_players sp
       where sp.session_id = ts.id
         and sp.left_at is null
    ) pl on true

    -- 這張桌是被哪一房配走的。matched_session_id 是 2026-08-23 那批補上的橋。
    left join lateral (
      select q.id, q.play_at,
             (select coalesce(jsonb_agg(m.display_name order by p.joined_at), '[]'::jsonb)
                from match_queue_players p
                join members m on m.id = p.member_id
               where p.queue_id = q.id and p.left_at is null) as names
        from match_queues q
       where q.matched_session_id = ts.id
       order by q.play_at desc
       limit 1
    ) mq on true

    where t.org_id = p_org_id and t.store_id = p_store_id and t.deleted_at is null
  ), '[]'::jsonb);
end $function$;


-- ── 驗證 ───────────────────────────────────────────────
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_out text := ''; v_store uuid; v_tbl uuid; v_st uuid;
  a uuid; b uuid; one jsonb; arr jsonb;
begin
  begin
    select id into v_store from stores where org_id = v_org limit 1;

    ---- ① 空桌：鍵在不在 --------------------------------
    arr := public.list_tables_tx(v_org, v_store);
    one := arr -> 0;
    v_out := v_out || E'\n' || '① players 已消失、player_count 還在' || E'\t' ||
      case when not (one ? 'players') and (one ? 'player_count')
           then '✅ 收掉了' else '🔴 players=' || (one ? 'players')::text
                || ' player_count=' || (one ? 'player_count')::text end;

    /* 🔴 **正對照缺一不可**：一支「整個回 `[]`」的壞函式，
       上面那一格會因為 `one` 是 null 而**不會噴錯也不會變紅**
       （`null ? 'players'` 是 null，不是 true）。
       所以要先確認它真的回了東西。 */
    v_out := v_out || E'\n' || '② 正對照：真的有回桌子（不是空陣列）' || E'\t' ||
      case when jsonb_array_length(arr) > 0
           then '✅ ' || jsonb_array_length(arr) || ' 張桌'
           else '🔴 0 張 —— 上面那一格等於沒驗' end;

    /* ⚠ **19 是實際數出來的，不是我推的** —— 交付前用 MCP 查了
       `count(*) from jsonb_object_keys(list_tables_tx(...)->0)` = **20**。
       我第一版憑印象寫 16，那會讓這一格紅得莫名其妙，
       而我接著會去懷疑那個「拿掉一個鍵」的動作。
       📌 同這個 session 前面兩次：**函式是對的，是期望值算錯。** */
    v_out := v_out || E'\n' || '③ 正對照：其餘 19 個鍵一個都沒少' || E'\t' ||
      case when (select count(*) from jsonb_object_keys(one)) = 19
           then '✅ 19 個鍵'
           else '🔴 ' || (select count(*) from jsonb_object_keys(one))
                || ' 個（改之前 20 − players = 19）' end;

    ---- ④ 有人在座時人數要對 ----------------------------
    select id into v_tbl from tables
     where org_id = v_org and store_id = v_store and deleted_at is null
       and not exists (select 1 from table_sessions s
                        where s.table_id = tables.id and s.status = 'open'
                          and s.deleted_at is null)
     limit 1;
    insert into table_sessions (org_id, store_id, table_id, mode, status)
      values (v_org, v_store, v_tbl, 'private', 'open') returning id into v_st;
    insert into members (org_id, display_name) values (v_org, '測甲') returning id into a;
    insert into members (org_id, display_name) values (v_org, '測乙') returning id into b;
    insert into session_players (org_id, session_id, member_id)
      values (v_org, v_st, a), (v_org, v_st, b);

    select x into one from jsonb_array_elements(public.list_tables_tx(v_org, v_store)) x
     where x->>'session_id' = v_st::text;
    v_out := v_out || E'\n' || '④ 兩個人在座 → player_count = 2' || E'\t' ||
      case when (one->>'player_count')::int = 2 then '✅ 2'
           else '🔴 ' || coalesce(one->>'player_count','null') end;

    /* 🎯 `is_hold` 與 `player_count` 用的是同一個 `pl.n` ——
       改動這一段時它們必須一起對，不然「預留中」會亂標。 */
    v_out := v_out || E'\n' || '⑤ 有人在座 → is_hold = false' || E'\t' ||
      case when (one->>'is_hold')::boolean = false and one->>'hold_kind' is null
           then '✅ false ／ hold_kind = null'
           else '🔴 is_hold=' || coalesce(one->>'is_hold','?')
                || ' hold_kind=' || coalesce(one->>'hold_kind','null') end;

    ---- ⑥ 正對照：沒人在座時「預留中」還認得出來 ---------
    delete from session_players where session_id = v_st;
    select x into one from jsonb_array_elements(public.list_tables_tx(v_org, v_store)) x
     where x->>'session_id' = v_st::text;
    v_out := v_out || E'\n' || '⑥ 正對照：沒人在座 → is_hold=true／setup' || E'\t' ||
      case when (one->>'is_hold')::boolean and one->>'hold_kind' = 'setup'
                and (one->>'player_count')::int = 0
           then '✅ true ／ setup ／ 0'
           else '🔴 is_hold=' || coalesce(one->>'is_hold','?')
                || ' hold_kind=' || coalesce(one->>'hold_kind','null') end;

    ---- ⑦ 全庫確認 --------------------------------------
    /* 🔴 掃全庫的禁字只能用**會產生行為的東西**（硬規則 3.5）。
       這裡掃的是 `'players'` 這個 **jsonb 鍵字面值**（帶引號），
       不是欄位名 —— 而且**限定在會回傳桌況的那一支**，
       不要掃全庫：`get_my_games_tx` 的 `'players'` 是陣列，那是對的。 */
    v_out := v_out || E'\n' || '⑦ list_tables_tx 全文不再有 ''players''' || E'\t' ||
      (select case when pg_get_functiondef(oid) like '%''players''%'
                   then '🔴 還有' else '✅ 沒有了' end
         from pg_proc where pronamespace = 'public'::regnamespace and proname = 'list_tables_tx');

    /* 🔴 **這一格才是「一個名字一個意思」真正的驗收**：
       數字版的 `players` 全部消失，陣列版的原封不動。 */
    v_out := v_out || E'\n' || '⑧ 還有哪些函式回數字版 players' || E'\t' ||
      (select coalesce(string_agg(proname, '、' order by proname), '✅ 一支都沒有')
         from pg_proc p
        where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
          and p.proname in ('list_tables_tx','list_match_queues_tx')
          and pg_get_functiondef(p.oid) like '%''players''%');
    v_out := v_out || E'\n' || '⑨ 正對照：陣列版的 players 沒被誤傷' || E'\t' ||
      (select case when count(*) = 2 then '✅ 兩支都還在（get_my_games_tx／get_my_active_queue_tx）'
                   else '🔴 只剩 ' || count(*) || ' 支' end
         from pg_proc p
        where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
          and p.proname in ('get_my_games_tx','get_my_active_queue_tx')
          and pg_get_functiondef(p.oid) like '%''players''%');

    v_out := v_out || E'\n' || '⑩ 正對照：DEFINER 與 anon 授權沒被動到' || E'\t' ||
      (select case when p.prosecdef and exists (select 1 from aclexplode(p.proacl) x
                        where x.grantee = 'anon'::regrole::oid and x.privilege_type = 'EXECUTE')
                   then '✅ DEFINER ／ anon 有' else '🔴 有東西被改到' end
         from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'list_tables_tx');

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.tbl', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.tbl', true), E'\n')) as x
 where coalesce(x,'') <> '';
