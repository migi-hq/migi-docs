/* ============================================================
   ① 名次看「最後一將」，不是段位分加總
   ② 段位分記「實際變動」，不是夾之前的原始點數
   2026-09-06 · MIGI 咪吉麻將 · 使用者拍板

   ⚠ 兩件事改的是同一支函式（`apply_session_rounds_tx`），
     所以合併成一份 —— 分兩份的話第二份要對著剛改過的版本再做一次
     字串替換，而那是白白多一次會錯的機會。

   ══ ① 名次 ══════════════════════════════════════════════
   現在的收尾是：
   ```
   row_number() over (order by 本場段位分加總 desc, member_id)
   ```
   ⇒ **拿段位分的總和去排名次**，兩個問題：
   · 同分很常見（實例：兩個人都是 `15 + (−20) = −5`）
     ⇒ 誰第 3 誰第 4 由 **`member_id` 的字典序**決定，
       一條沒有人選過、而且完全看不見的規則
   · **名次與段位分本來就是兩件事**：
       名次   = 桌上分數的結果（累積的 ⇒ 最後一將結束就是整場結果）
       段位分 = 每一將依當將名次給點，然後加總

   → `finish_rank` 直接取**最後一將**的名次，`score_points` 維持加總。
   🎯 同分那個問題順帶消失 —— 最後一將的名次本來就是 1..4 的排列。

   ── 🎯 要保留的那個畫面（使用者拍板）──────────────────
   ```
   1 將第一　2 將第一　3 將第四   →   名次 第 4 名 ・ 段位分 +40
   ```
   **不是 bug，是這套設計的必然結果**，而且刻意保留：
   · **名次** 回答「這一場最後誰贏」
   · **段位分** 回答「三將裡你打得怎樣」（30+30−20 = +40）

   曾評估「段位分改成依最終名次給一次」（那樣是 −40，正負號永遠跟
   名次一致），**否決**，三個理由：
   ① 🔴 那樣 2 將與 3 將拿一樣多分，而 3 將多花 1.5 倍時間、
      檯費也多 50（`SVC-TBL-M2` 100 → `SVC-TBL-M3` 150）
      ⇒ **三重懲罰，沒有人會選 3 將**。要救就得再開一張
        「3 將專用點數表」—— 為了修一個偶發的畫面，引進一個
        每次開桌都會發生的問題，再用第二個機制去補它。
   ② 逐將是**三個樣本**，整場是一個。而那一次墊底通常來自一副大牌
      （放槍役滿／被自摸），運氣佔比高得多。
   ③ 那個矛盾**偶發不是系統性**：常常大輸的人本來就不可能常常
      在每一將的前面。
   → 畫面上用文案分開講，不要用規則去壓。

   📌 逐將加總順帶讓長度中性：時間 1.5 倍、檯費 1.5 倍、點數 1.5 倍
     ⇒ **每小時能拿的段位分兩種一樣**，沒有人會為了刷分挑長度。

   ══ ② 段位分記實際變動 ══════════════════════════════════
   🔴 降階保護是**逐將夾**的，但累計得點記的是**夾之前**的原始點數：
   ```
   v_new := v_new + v_pts;
   if 低段 then v_new := greatest(v_new, 該階下限);   ← rating 被夾住
   v_total := v_total + v_pts;                        ← 但這裡加原始 v_pts
   ```
   ⇒ 一個**剛好卡在階級下限**的銀牌熊，墊底時 rating 其實沒有掉，
     但 `score_points` 照樣記 −20。客人在 App 上會看到：
   ```
   段位分 −10        ← score_points
   段位走勢圖 +30    ← rating_after
   ```
   **同一頁兩個數字互相矛盾，而且不會報錯。**

   → `v_total` 改累加 **`v_new − v_prev`**（夾過之後的實際變動）。
   ⚠ 已知代價：本場得點會與 `rank_points` 表對不起來（那正是保護生效
     的意思）。**客人看到的數字應該就是他實際發生的事** —— 這是取捨，
     不是漏掉。
   📌 這也讓 `score_points` 名實相符了一半：它本來就該叫 `rating_delta`
     （M4 正名）。

   ── ⏳ M4 之後要再改一次（只有一段）────────────────────
   今天「最後一將的名次」是**桌上總分的代理指標** ——
   桌上分數在資料庫裡還沒有欄位。M4 電子計分接上之後：
     `finish_rank` 改成**依桌上總分排**，同分比座位（那時 `seat` 才有值）
   ⇒ 動的是收尾那一段，`score_points` 逐將加總**不變**。

   ⚠ 已經結算過的場次**不會回頭改** —— 冪等擋著，而且每一將的原始
     資料根本沒存，重算不出來。今天線上只有隨機資料，無所謂。
   ⚠ 簽名沒變 → `CREATE OR REPLACE`，不用 DROP、不掉 GRANT。
   ============================================================ */

do $mig$
declare
  v_def text;
  v_new text;
  v_step int := 0;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'apply_session_rounds_tx' and p.prokind = 'f';

  if v_def is null then raise exception '找不到 apply_session_rounds_tx'; end if;
  v_new := v_def;

  /* ── A. 宣告一個 v_prev（記這一將**加分之前**的 rating）───── */
  v_new := replace(v_new,
    'v_band text; v_pts int; v_new int; v_floor int;',
    'v_band text; v_pts int; v_new int; v_floor int; v_prev int;');
  if v_new = v_def then raise exception '🔴 A 沒替換到：declare 區塊跟預期不同'; end if;
  v_step := 1;

  /* ── B. 在加分之前先記下來 ─────────────────────────────
     ⚠ 一定要在 `v_new := v_new + v_pts` **之前**，
       而且在夾之前 —— 夾之後的差值才是「實際發生了什麼」。 */
  v_new := regexp_replace(v_new,
    '\n(\s*)v_new := v_new \+ v_pts;',
    E'\n\\1v_prev := v_new;              -- 這一將加分前的 rating\n\\1v_new := v_new + v_pts;');
  if position('v_prev := v_new;' in v_new) = 0 then
    raise exception '🔴 B 沒替換到：找不到 v_new := v_new + v_pts';
  end if;
  v_step := 2;

  /* ── C. 累計得點改記實際變動 ───────────────────────────── */
  v_new := regexp_replace(v_new,
    'v_total := jsonb_set\(v_total, array\[v_ids\[i\]::text\],\s*to_jsonb\(coalesce\(\(v_total ->> v_ids\[i\]::text\)::int, 0\) \+ v_pts\)\);',
    '/* 🔴 記**實際變動**（`v_new - v_prev`）不是原始點數 `v_pts`。' || chr(10) ||
    '         降階保護把 rating 夾住時，那一將實際上沒有掉那麼多 ——' || chr(10) ||
    '         記原始點數的話，畫面上的「段位分」會與段位走勢圖矛盾。' || chr(10) ||
    '         ⚠ 代價：本場得點會與 rank_points 表對不起來，' || chr(10) ||
    '           而那正是保護生效的意思。2026-09-06 使用者拍板。 */' || chr(10) ||
    '      v_total := jsonb_set(v_total, array[v_ids[i]::text],' || chr(10) ||
    '        to_jsonb(coalesce((v_total ->> v_ids[i]::text)::int, 0) + (v_new - v_prev)));');
  if position('(v_new - v_prev)' in v_new) = 0 then
    raise exception '🔴 C 沒替換到：累計得點那一段跟預期不同';
  end if;
  v_step := 3;

  /* ── D. 收尾改成「最後一將的名次」─────────────────────
     🎯 **外層迴圈跑完之後，`v_ids` / `v_ranks` 裝的就是最後一將** ——
       它們在每一將開頭被重新 select 進來，不需要另外記一份。
     ⚠ 用非貪婪從 `for e, i in` 抓到第一個 `end loop;` ——
       函式裡還有別的 `end loop;`，貪婪比對會把整段吃掉。 */
  v_new := regexp_replace(v_new,
    'for e, i in[\s\S]*?end loop;',
$new$for i in 1 .. v_n loop
    update session_players sp
       set finish_rank  = v_ranks[i],
           score_points = coalesce((v_total ->> v_ids[i]::text)::int, 0),
           settled_at   = now(),
           rating_after = (select rating from members where id = v_ids[i])
     where sp.session_id = p_session_id and sp.member_id = v_ids[i];

    update members set rank = public.member_rank_tx(id) where id = v_ids[i];
  end loop;$new$);
  if position('for i in 1 .. v_n loop' in v_new) = 0 then
    raise exception '🔴 D 沒替換到：收尾那一段跟預期不同';
  end if;

  /* ── E. 說明也要換，不然註解會說一件事、程式做另一件 ───── */
  v_new := regexp_replace(v_new,
    '/\* 整場收尾[\s\S]*?牌譜 schema。 \*/',
$c$/* 整場收尾（2026-09-06 改）：
     · `finish_rank`  = **最後一將**的名次
     · `score_points` = 每一將**實際變動**的加總（夾過降階保護之後）

     🔴 在此之前 finish_rank 是「段位分加總的排名」，那有兩個錯：
       ① 同分時由 `member_id` 字典序決定，一條看不見的規則
       ② 名次與段位分是兩件事 —— 名次來自桌上分數（累積的，
          所以最後一將結束就是整場結果），段位分是每將給點再加總
     ⇒ 現在會出現「第 4 名但段位分是正的」，**那是對的**：
       他前面幾將贏了、最後一將墊底。

     ⚠ 每一將的名次仍然沒有存下來（這一格裝不下），要等牌譜 schema。
     ⚠ `v_ids` / `v_ranks` 在迴圈結束後就是最後一將的值 —— 不用另外記。
     ⏳ M4 接上桌上分數之後，`finish_rank` 改成依桌上總分排、
       同分比座位；`score_points` 不變。 */$c$);

  execute v_new;
end $mig$;

/* ── 驗證 ────────────────────────────────────────────────
   🎯 樣本在交易內自己造（硬規則 3.57），最後整段回滾。
   ⚠ 訊息設在 exception 處理器裡（硬規則 3.9）。 */
do $v$
declare
  v_org uuid; v_store uuid; v_tbl uuid; v_sid uuid; v_sid2 uuid;
  v_ids uuid[]; v_r jsonb;
  v_a_rank int; v_a_pts int; v_ranks int[];
  v_floor int; v_r1_before int; v_r1_after int; v_r1_pts int;
  v_msg text := '';
begin
  select o.id into v_org from orgs o limit 1;
  select s.id into v_store from stores s
   where s.org_id = v_org and exists (select 1 from tables t where t.store_id = s.id) limit 1;
  select t.id into v_tbl from tables t
   where t.store_id = v_store and t.deleted_at is null
     and not exists (select 1 from table_sessions x
                      where x.table_id = t.id and x.status = 'open' and x.deleted_at is null)
   limit 1;
  select array_agg(m.id) into v_ids
    from (select id from members where org_id = v_org and deleted_at is null and is_test
           order by created_at limit 4) m;

  if v_tbl is null or coalesce(array_length(v_ids,1),0) <> 4 then
    v_msg := '🔴 ⓪ 造不出樣本 —— 這份驗證等於沒跑，不要當成通過';
    raise exception 'migi_rollback';
  end if;

  insert into table_sessions (org_id, store_id, table_id, mode, planned_rounds, status)
  values (v_org, v_store, v_tbl, 'matched', 2, 'open') returning id into v_sid;
  insert into session_players (org_id, session_id, member_id)
  select v_org, v_sid, unnest(v_ids);

  /* ═══ ① 名次看最後一將 ═══
     🎯 **刻意造出使用者講的那個情境**：第 1 位第一將拿第 1、最後一將墊底。
       ⇒ 名次應該是 **4**，段位分應該是**正的**。
     🔴 只驗「名次是 1..4 的排列」的話**舊版也會過** —— 這一格才是分水嶺。 */
  v_r := apply_session_rounds_tx(v_sid, jsonb_build_array(
    jsonb_build_array(
      jsonb_build_object('member_id', v_ids[1], 'finish_rank', 1),
      jsonb_build_object('member_id', v_ids[2], 'finish_rank', 2),
      jsonb_build_object('member_id', v_ids[3], 'finish_rank', 3),
      jsonb_build_object('member_id', v_ids[4], 'finish_rank', 4)),
    jsonb_build_array(
      jsonb_build_object('member_id', v_ids[1], 'finish_rank', 4),
      jsonb_build_object('member_id', v_ids[2], 'finish_rank', 3),
      jsonb_build_object('member_id', v_ids[3], 'finish_rank', 2),
      jsonb_build_object('member_id', v_ids[4], 'finish_rank', 1))));

  select sp.finish_rank, sp.score_points into v_a_rank, v_a_pts
    from session_players sp
   where sp.session_id = v_sid and sp.member_id = v_ids[1];
  select array_agg(sp.finish_rank order by sp.finish_rank) into v_ranks
    from session_players sp where sp.session_id = v_sid;

  v_msg :=
       case when (v_r ->> 'ok')::boolean then '✅ ① 結算成功' else '🔴 ① 結算失敗：' || coalesce(v_r ->> 'reason','?') end
    || E'\n② 第一將第 1、最後一將第 4 → 名次 = ' || coalesce(v_a_rank::text,'null')
    || case when v_a_rank = 4 then '　✅ 看的是最後一將'
            else '　🔴 應該是 4（舊版依總分會排成 2 或 3）' end
    /* ③ 🎯 正對照：**分數不可以跟著名次走**。
         ⚠ 只驗②的話，一支「名次與分數一起改成看最後一將」的實作也會過，
           而那會把前面幾將的得點整個丟掉。 */
    || E'\n③ 同一位的段位分 = ' || coalesce(v_a_pts::text,'null')
    || case when v_a_pts > 0 then '　✅ 是正的（加總沒被名次帶走）'
            else '　🔴 加總不對 —— 第一將的 +30 不見了' end
    || E'\n④ 名次 = ' || coalesce(v_ranks::text,'（沒有）')
    || case when v_ranks = array[1,2,3,4] then '　✅ 仍然是 1..4 的排列' else '　🔴 不是排列' end;

  /* ═══ ② 段位分記實際變動 ═══
     把第 1 位的 rating **壓到他那一階的下限**，再讓他兩將都墊底。
     ⇒ 降階保護生效 ⇒ rating 不該掉 ⇒ 段位分應該是 **0**（不是 −40）。 */
  select (public.rank_detail_tx(m.rating) ->> 'tier_min')::int
    into v_floor from members m where m.id = v_ids[1];
  update members set rating = v_floor where id = v_ids[1];
  select rating into v_r1_before from members where id = v_ids[1];

  select t.id into v_tbl from tables t
   where t.store_id = v_store and t.deleted_at is null
     and not exists (select 1 from table_sessions x
                      where x.table_id = t.id and x.status = 'open' and x.deleted_at is null)
   limit 1;
  insert into table_sessions (org_id, store_id, table_id, mode, planned_rounds, status)
  values (v_org, v_store, v_tbl, 'matched', 2, 'open') returning id into v_sid2;
  insert into session_players (org_id, session_id, member_id)
  select v_org, v_sid2, unnest(v_ids);

  perform apply_session_rounds_tx(v_sid2, jsonb_build_array(
    jsonb_build_array(
      jsonb_build_object('member_id', v_ids[1], 'finish_rank', 4),
      jsonb_build_object('member_id', v_ids[2], 'finish_rank', 1),
      jsonb_build_object('member_id', v_ids[3], 'finish_rank', 2),
      jsonb_build_object('member_id', v_ids[4], 'finish_rank', 3)),
    jsonb_build_array(
      jsonb_build_object('member_id', v_ids[1], 'finish_rank', 4),
      jsonb_build_object('member_id', v_ids[2], 'finish_rank', 1),
      jsonb_build_object('member_id', v_ids[3], 'finish_rank', 2),
      jsonb_build_object('member_id', v_ids[4], 'finish_rank', 3))));

  select rating into v_r1_after from members where id = v_ids[1];
  select sp.score_points into v_r1_pts
    from session_players sp
   where sp.session_id = v_sid2 and sp.member_id = v_ids[1];

  v_msg := v_msg
    || E'\n⑤ 卡在下限的人兩將都墊底：rating ' || v_r1_before || ' → ' || v_r1_after
    || case when v_r1_after = v_r1_before then '　✅ 降階保護生效（沒掉）'
            else '　⚠ 掉了 —— 那他本來就不在下限上，這一格測不到' end
    || E'\n⑥ 他的段位分 = ' || coalesce(v_r1_pts::text,'null')
    || case when v_r1_after = v_r1_before and v_r1_pts = 0
              then '　✅ 記的是實際變動（舊版會記 −40）'
            when v_r1_after = v_r1_before
              then '　🔴 應該是 0 —— 還在記夾之前的原始點數'
            else '　⚠ 保護沒生效，這一格無效' end
    /* ⑦ 🎯 正對照：**沒被夾到的人不可以受影響**。
         第 2 位兩將都第一，該拿滿 +60。
       ⚠ 少了這一格，一支「把所有人的得點都寫 0」的實作也會讓⑥變綠。 */
    || E'\n⑦ 沒被夾到的人（兩將都第一）= '
    || coalesce((select sp.score_points::text from session_players sp
                  where sp.session_id = v_sid2 and sp.member_id = v_ids[2]), 'null')
    || case when (select sp.score_points from session_players sp
                   where sp.session_id = v_sid2 and sp.member_id = v_ids[2]) = 60
            then '　✅ 拿滿 +60（沒被誤傷）'
            else '　🔴 應該是 60' end;

  /* ⑧ 🎯 冪等沒被改壞 */
  v_msg := v_msg || E'\n⑧ 再結算一次：'
        || case when coalesce(apply_session_rounds_tx(v_sid, '[]'::jsonb) ->> 'reason', '')
                     in ('too_few_rounds', 'already_applied')
                then '✅ 擋住了' else '🔴 沒擋住' end;

  raise exception 'migi_rollback';

exception when others then
  perform set_config('migi.v',
    v_msg || case when sqlerrm = 'migi_rollback' then ''
                  else E'\n🔴 驗證途中拋錯：' || sqlerrm end, true);
end $v$;

select current_setting('migi.v', true) as 驗證結果;
