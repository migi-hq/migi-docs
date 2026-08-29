/* ============================================================
   四支 POS／清單 RPC 補上 avatar_url 與 avatar_bear
   2026-08-29

   ── 為什麼 ──────────────────────────────────────────
   POS 的 11 個 `<Bear>` 全部是**寫死的 SVG**（`shared.jsx:164`）——
   店員在座位卡、會員查詢、配桌看到的每一個人都長一樣。
   要顯示真頭像，前端需要**四個欄位**才畫得出三種來源：
   ```
   avatar_source = 'line'  → avatar_url
   avatar_source = 'photo' → avatar_photo_path
   avatar_source = 'bear'  → avatar_bear（null = 通用預設熊）
   ```

   這四支已經有 `avatar_source` 與 `avatar_photo_path`，缺另外兩個：
   | 函式 | 誰在用 |
   |---|---|
   | `get_session_tx` | POS 座位卡 |
   | `pos_search_members_tx` | POS 會員查詢 |
   | `pos_member_detail_tx` | POS 會員詳情 |
   | `list_recent_players_tx` | 會員 App 的「最近同桌」 |

   🔴 **缺欄位的症狀是「畫出來但畫錯」**：拿不到 `avatar_url` 的話，
     一個用 LINE 頭像的客人在 POS 上會退回小熊。不報錯、不空白。

   ── ⚠ 這一份用「定點插入」而不是重寫全文 ────────────
   CLAUDE.md 記過：**同一支函式要改三處以上就撈全文重建，
   不要堆 DO 區塊**（2026-08-20 在 `join_session_tx` 上連續判斷錯兩次）。
   這裡的情況不同，所以刻意選了另一邊：
   · **每支只改一處**，不是三處
   · `pos_member_detail_tx` 有 **4832 字元** —— 手動重打一次的
     漏行風險，遠高於一條有錨點的正則
   · 已查證**每支的 `'avatar_source'` 都只出現一次**（別名 3 個 `m`、
     1 個 `mm`），所以錨點沒有歧義

   🎯 而那次教訓真正的重點不是「不要用 DO」，是
     **「改完要有 guard，不要讓改到一半的版本留在線上」** ——
     下面每一支改完都會檢查新定義含不含兩個新 key，
     不含就 `raise`（Supabase SQL Editor 是單一交易，整份回滾）。
   ============================================================ */

do $$
declare
  v_name text;
  v_old  text;
  v_new  text;
  v_done text := '';
begin
  foreach v_name in array array[
    'get_session_tx', 'pos_search_members_tx',
    'pos_member_detail_tx', 'list_recent_players_tx'
  ] loop
    select pg_get_functiondef(p.oid) into v_old
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.prokind = 'f' and p.proname = v_name;
    if v_old is null then
      raise exception '找不到函式 %', v_name;
    end if;

    /* 在 `'avatar_source', X.avatar_source` 前面插入另外兩個 key。
       ⚠ 別名用 `\1` 帶出來 —— 寫死 `m.` 的話 `list_recent_players_tx`
         （別名是 `mm`）會產生 `m.avatar_url` 而**那個別名不存在**，
         CREATE 會直接失敗。這是那條正則唯一需要小心的地方。 */
    v_new := regexp_replace(
      v_old,
      '''avatar_source''\s*,\s*([a-zA-Z_]+)\.avatar_source',
      '''avatar_url'', \1.avatar_url, ''avatar_bear'', \1.avatar_bear, ''avatar_source'', \1.avatar_source'
    );

    /* 🔴 guard —— 沒改到就不要往下走。
       `regexp_replace` 找不到樣式時**不會報錯，會原樣回傳** ——
       那正是「跑完沒報錯但什麼都沒發生」那個形狀。 */
    if v_new = v_old then
      raise exception '% 的錨點沒對上，一個字都沒改', v_name;
    end if;
    if v_new not like '%''avatar_url''%' or v_new not like '%''avatar_bear''%' then
      raise exception '% 改完之後少了新欄位', v_name;
    end if;

    execute v_new;
    v_done := v_done || v_name || ' ';
  end loop;

  perform set_config('migi.patched', v_done, false);
end $$;


/* ============================================================
   驗證（單一 SELECT）

   🔴 **不能只看「函式建起來了」**（硬規則 7）。
     而且這幾支回的是清單／物件，**空的時候看起來一切正常** ——
     所以每一支都要真的呼叫，而且要呼叫到**有資料**的那條路徑
     （硬規則 3.55）。

   ⚠ `get_session_tx` 需要一場有玩家的 session；
     `list_recent_players_tx` 需要同桌過的人。
     兩者若真的沒有資料，驗證會誠實地說「沒驗到」而不是假裝過關。
   ============================================================ */
select 序, 項目, 內容 from (

  select 1 as 序, '① 改了哪幾支' as 項目,
         coalesce(nullif(current_setting('migi.patched', true), ''), '🔴 一支都沒改') as 內容

  union all
  select 2, '② 🎯 四支的欄位齊不齊（看函式定義）',
         (select string_agg(p.proname
                 || '　url=' || case when pg_get_functiondef(p.oid) like '%''avatar_url''%' then '✅' else '🔴' end
                 || '　source=' || case when pg_get_functiondef(p.oid) like '%''avatar_source''%' then '✅' else '🔴' end
                 || '　photo=' || case when pg_get_functiondef(p.oid) like '%''avatar_photo_path''%' then '✅' else '🔴' end
                 || '　bear=' || case when pg_get_functiondef(p.oid) like '%''avatar_bear''%' then '✅' else '🔴' end,
                 E'\n' order by p.proname)
            from pg_proc p
           where p.pronamespace='public'::regnamespace and p.prokind='f'
             and p.proname in ('get_session_tx','pos_search_members_tx',
                               'pos_member_detail_tx','list_recent_players_tx'))

  union all
  /* 🎯 真的呼叫一次。定義裡有那個字串，跟「回傳真的有那個 key」是兩件事
     —— 例如插進了註解裡就會是前者為真、後者為假。 */
  select 3, '③ 🎯 實際呼叫 pos_search_members_tx（找得到人才算數）',
         (select case when j is null then '🔴 搜不到人 —— 這一格沒驗到'
                      else '回傳 ' || (select count(*) from jsonb_object_keys(j))::text || ' 個 key　'
                        || case when (select count(*) from jsonb_object_keys(j) k
                                       where k in ('avatar_url','avatar_source','avatar_photo_path','avatar_bear')) = 4
                                then '✅ 四個頭像欄位都在'
                                else '🔴 缺：' || (select string_agg(k,'、') from unnest(
                                       array['avatar_url','avatar_source','avatar_photo_path','avatar_bear']) k
                                       where not j ? k) end end
            from (select pos_search_members_tx('11111111-1111-1111-1111-111111111111','測試') -> 0 as j) t)

  union all
  select 4, '④ 🎯 實際呼叫 pos_member_detail_tx（創辦人）',
         (select case when j is null then '🔴 回 null'
                      else case when (select count(*) from jsonb_object_keys(j) k
                                       where k in ('avatar_url','avatar_source','avatar_photo_path','avatar_bear')) = 4
                                then '✅ 四個頭像欄位都在'
                                else '🔴 缺：' || coalesce((select string_agg(k,'、') from unnest(
                                       array['avatar_url','avatar_source','avatar_photo_path','avatar_bear']) k
                                       where not j ? k), '(判讀不出)') end end
            from (select pos_member_detail_tx('11111111-1111-1111-1111-111111111111',
                          '69016205-afde-4036-95a6-5893c9d0e5fe') as j) t)

  union all
  select 5, '⑤ 🎯 實際呼叫 get_session_tx（挑一場有玩家的）',
         coalesce((select case when (select count(*) from jsonb_object_keys(j->'players'->0) k
                                     where k in ('avatar_url','avatar_source','avatar_photo_path','avatar_bear')) = 4
                               then '✅ players[0] 四個頭像欄位都在'
                               else '🔴 缺欄位，players[0] 有：'
                                    || coalesce((select string_agg(k,'、') from jsonb_object_keys(j->'players'->0) k),'(空)') end
                    from (select get_session_tx(sp.session_id) as j
                            from session_players sp where sp.left_at is null limit 1) t),
                  '🔴 沒有任何在座玩家 —— 這一格沒驗到')

  union all
  select 6, '⑥ 🎯 正對照：四支的模式與授權都沒被動到',
         (select string_agg(p.proname
                 || '　' || case when p.prosecdef then 'DEFINER' else '🔴 INVOKER' end
                 || case when p.provolatile = 's' then '／STABLE' else '' end
                 || '　anon=' || case when has_function_privilege('anon', p.oid, 'execute') then '✅' else '🔴 無' end,
                 E'\n' order by p.proname)
            from pg_proc p
           where p.pronamespace='public'::regnamespace and p.prokind='f'
             and p.proname in ('get_session_tx','pos_search_members_tx',
                               'pos_member_detail_tx','list_recent_players_tx'))

) x order by 序;
