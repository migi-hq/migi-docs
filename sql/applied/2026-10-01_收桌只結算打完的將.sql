/* ============================================================
   收桌只結算打完的將 · 2026-10-01 · MIGI 咪吉麻將
   📄 使用者 2026-10-01 拍板：
     「3 將沒打完，先結算 2 將成績；2 將沒打完，先結算 1 將成績；1 將都沒打完，成績不算」

   ── 規則 ────────────────────────────────────────────────
   桌上積分      只算**打完的將**（含咔啦碰）；沒打完的那一將不算
   名次          照打完的將的桌上積分排（同分座位小的在前，照舊）
   段位分        維持「至少 2 將」—— 只打完 1 將的場次**有名次、有桌上積分、沒有段位分**
                 理由：定位賽第 4 名每將 +5 × 最少 2 將 ＝ 剛好 10 分，保證新客人第一場升到銅牌熊 III；
                 1 將就算的話，第一場只拿 5 分升不了級，定位賽卻已經用掉（決策紀錄第二十三節）
   胡牌、牌型成就  **照算**，包含沒打完那一將裡胡的牌（事情確實發生了）
   一將都沒打完   成績不算（沒有名次、沒有積分、沒有段位分），**而且「完成一場牌局」這類成就也不發**

   ── 現況（改之前，2026-10-01 撈線上全文確認）─────────────
   · 名次與段位分本來就只算打完的將 ✅
   · 🔴 桌上積分把「沒打完那一將」也加進去
   · 🔴 只打完 1 將 ⇒ 段位分算不了 ⇒ 連名次與桌上積分都不寫（兩者綁在一起）
   · 🔴 一將都沒打完 ⇒ 名次不寫 ✅，但收桌照樣發「完成一場牌局」那一批成就

   ── 改法 ────────────────────────────────────────────────
   _score_settle_tx   ① 總分只加 status = finished 的將裡的局
                      ② 名次與桌上積分改成「打完 1 將就寫」（段位分那段不動，仍要 2 將）
   settle_session_tx  兩段成就（2026-09-20 那段與 2026-09-30 那段）只在「這場有名次」時才跑
                      ⇒ 判準沿用唯一的定義 _session_scored()
   ⚠ 改的是線上全文（pg_get_functiondef），錨點必須剛好出現一次，否則整份不執行。可重跑。
   🔴 2026-10-01 第一版跑失敗：同一支函式分兩步改，第一步加 `if`、第二步才加 `end if`，
     而工具每改一步就立刻重建 ⇒ 第一步做完時函式不完整 ⇒ 42601。（整份回滾，線上沒變，查證過。）
     ✅ 改成「同一支函式的所有改動先在文字上全部做完，最後只重建一次」。
   ============================================================ */

create or replace function pg_temp.patch_many(p_fn regprocedure, p_marker text, p_anchors text[], p_news text[])
returns text language plpgsql as $$
declare v_def text; v_n int; i int;
begin
  v_def := pg_get_functiondef(p_fn);
  if position(p_marker in v_def) > 0 then return p_fn::text || ' 已經改過'; end if;
  for i in 1 .. array_length(p_anchors, 1) loop
    v_n := (length(v_def) - length(replace(v_def, p_anchors[i], ''))) / length(p_anchors[i]);
    if v_n <> 1 then
      raise exception '% 的第 % 個錨點出現 % 次（要剛好 1 次），整份不執行：%', p_fn, i, v_n, left(p_anchors[i], 40);
    end if;
    v_def := replace(v_def, p_anchors[i], p_news[i]);
  end loop;
  execute v_def;   -- 所有改動都做完才重建一次 ⇒ 不會有半改的中間狀態
  return p_fn::text || ' 已改 ' || array_length(p_anchors, 1) || ' 處';
end $$;

-- ①② 結算：總分只算打完的將；打完 1 將就寫名次與桌上積分（段位分那段不動）
select pg_temp.patch_many('public._score_settle_tx(uuid)'::regprocedure,
  '只算打完的將（含咔啦碰）',
  array[
    $a$-- 整場每個座位的總分（所有生效的，包含咔啦碰與沒打完的那一將）$a$,
    $a$where h2.session_id = p_session_id and h2.status = 'confirmed' group by 1) x;$a$,
    $a$-- ③ 名次與桌上積分：只在段位分真的算了才寫（兩者要嘛都有要嘛都沒有，同 placeholder）$a$,
    $a$  if v_rated then$a$],
  array[
    $b$-- 整場每個座位的總分：只算打完的將（含咔啦碰）；沒打完的那一將不算（2026-10-01 使用者拍板）$b$,
    $b$where h2.session_id = p_session_id and h2.status = 'confirmed'
             and exists (select 1 from session_rounds rr where rr.id = h2.round_id and rr.status = 'finished')
           group by 1) x;$b$,
    $b$-- ③ 名次與桌上積分：打完 1 將就寫（2026-10-01）。段位分仍要 2 將（上面那段），
  --   所以只打完 1 將的場次會「有名次、有桌上積分、沒有段位分」—— 那是拍板的結果，不是寫壞$b$,
    $b$  if v_nfin >= 1 then$b$]);

-- ③ 收桌：一將都沒打完（沒有名次）就不發成就 —— if 的頭與尾一次改完
select pg_temp.patch_many('public.settle_session_tx(uuid,uuid,boolean)'::regprocedure,
  '一將都沒打完就不發成就',
  array[
    $a$  /* 🆕 2026-09-20：成就事件（第 ③ 步）。$a$,
    $a$  -- ── 收完保留給現場$a$],
  array[
    $b$  /* 🆕 2026-10-01：一將都沒打完就不發成就（成績不算 ⇒「完成一場牌局」也不算）。
     判準沿用唯一的定義 _session_scored()；下面兩段成就到「收完保留給現場」之前都包在這個 if 裡 */
  if public._session_scored(p_session_id) then
  /* 🆕 2026-09-20：成就事件（第 ③ 步）。$b$,
    $b$  end if;   /* ↑ 2026-10-01：成就那兩段只在有名次時才跑 */

  -- ── 收完保留給現場$b$]);

-- ④ 驗證（只讀狀態、不寫東西，不用 raise —— 硬規則 1.8）
do $$
declare v_msg text := ''; v_d text; v_n int; v_ok boolean;
begin
  v_d := pg_get_functiondef('public._score_settle_tx(uuid)'::regprocedure);
  v_ok := v_d ~ 'rr\.status = ''finished''' and v_d ~ 'if v_nfin >= 1 then' and v_d !~ 'if v_rated then';
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end
        || ' ① 結算：總分只算打完的將、打完 1 將就寫名次' || E'\n';

  -- 段位分那段沒被動到：仍然要 2 將才呼叫
  v_ok := v_d ~ 'if v_nfin >= 2 then\s+v_res := public\.apply_session_rounds_tx';
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ② 段位分仍要 2 將（那段沒被動到）' || E'\n';

  v_d := pg_get_functiondef('public.settle_session_tx(uuid,uuid,boolean)'::regprocedure);
  v_ok := v_d ~ 'if public\._session_scored\(p_session_id\) then\s+/\* 🆕 2026-09-20'
      and v_d ~ 'end if;\s+/\* ↑ 2026-10-01：成就那兩段只在有名次時才跑 \*/\s+-- ── 收完保留給現場';
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ③ 收桌：成就只在有名次時才發（if 的頭尾都在對的位置）' || E'\n';

  select count(*) into v_n from pg_proc
   where pronamespace = 'public'::regnamespace and proname in ('_score_settle_tx', 'settle_session_tx');
  v_msg := v_msg || case when v_n = 2 then '✅' else '🔴' end || ' ④ 版本數 ' || v_n || '（應為 2，各一個）';

  perform set_config('migi.settle', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.settle', true), ''), '🔴 沒有驗證訊息') as "驗證";
