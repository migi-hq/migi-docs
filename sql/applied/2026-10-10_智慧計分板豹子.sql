-- ============================================================
-- 智慧計分板「豹子」（2026-10-10，使用者：牌型新增豹子按鈕，按 1 次所有台數 ×2，按 2 次 ×3）
--
-- 乘的範圍（使用者選的）：**牌型台數 ＋ 莊家台** 一起乘，**底不乘**。
--   例：底 100、每台 20，胡 5 台，莊家台 1 台，豹子 1 次 → (5 + 1) × 2 = 12 台 → 100 + 12 × 20 = 340
--
-- ① scoring_patterns 新增 baozi：0 台、最多 2 次、special 組、排在 MIGI 後面；胡牌與自摸都能選
-- ② tbl_submit_hand_tx（讀線上全文，只換四處）：
--    · 宣告多一個倍數 v_mult（預設 1）
--    · 迴圈讀到豹子時記下倍數 ＝ 1 ＋ 次數
--    · 自摸自動帶完、算錢之前：牌型台數 × 倍數（hands.tai_pattern 存的是乘過的）
--    · 每一份的莊家台也 × 倍數
--   包牌、咔啦碰、流局、分紅不吃牌型，不受影響。
--
-- ⚠ 計分規則三份一起改（CLAUDE.md 待辦 51）：這支、平板預覽 lib/rules.js、教學模式 lib/engine.js（同日已改）。
-- ⚠ 任何一處對不上（找不到或出現不只一次）就整份停下來（故意不要提交的那一種，見硬規則 1.8）。
-- ============================================================

insert into scoring_patterns (code, label, tai, max_count, group_key, needs_flower, result_only, dealer_only,
                              conflicts, achievement_event, sort, is_active, note)
values ('baozi', '豹子', 0, 2, 'special', false, null, false,
        '{}', null, 430, true,
        '本身 0 台；按 1 次「牌型台數 ＋ 莊家台」×2、按 2 次 ×3，底不乘（2026-10-10 使用者）');

do $$
declare
  v_def text;
  v_new text;
  -- 這段文字在全文裡出現幾次（一定要剛好 1 次才換）
  n_of constant text := 'select (length($1) - length(replace($1, $2, ''''))) / length($2)';
  v_cnt int;
  a text; b text;
begin
  v_def := pg_get_functiondef('public.tbl_submit_hand_tx(text,text,smallint,jsonb)'::regprocedure);
  v_new := v_def;

  -- ⓐ 宣告
  a := 'v_n int; v_tai int := 0; v_extra int;';
  b := 'v_n int; v_tai int := 0; v_extra int; v_mult int := 1;';
  execute n_of into v_cnt using v_new, a;
  if v_cnt <> 1 then raise exception 'ⓐ 宣告那一行出現 % 次', v_cnt; end if;
  v_new := replace(v_new, a, b);

  -- ⓑ 迴圈裡記下豹子倍數
  a := 'v_tai := v_tai + p.tai * v_n;';
  b := 'v_tai := v_tai + p.tai * v_n;' || chr(13) || chr(10)
    || '    if p.code = ''baozi'' then v_mult := 1 + v_n; end if;   -- 豹子：倍數 ＝ 1 ＋ 次數（2026-10-10）';
  execute n_of into v_cnt using v_new, a;
  if v_cnt <> 1 then raise exception 'ⓑ 加總牌型台數那一行出現 % 次', v_cnt; end if;
  v_new := replace(v_new, a, b);

  -- ⓒ 算錢之前把牌型台數乘上倍數（自摸自動帶的那 1 台也一起乘）
  a := '/* 每個付款人付：底 ＋ 台 ×（牌型台數 ＋ 莊家台）；';
  b := 'v_tai := v_tai * v_mult;   -- 豹子：牌型台數一起乘（含自動帶的自摸），存進 tai_pattern 的就是乘過的' || chr(13) || chr(10)
    || '  /* 每個付款人付：底 ＋ 台 ×（牌型台數 ＋ 莊家台）；';
  execute n_of into v_cnt using v_new, a;
  if v_cnt <> 1 then raise exception 'ⓒ 算錢那段開頭出現 % 次', v_cnt; end if;
  v_new := replace(v_new, a, b);

  -- ⓓ 莊家台也乘倍數（底不乘）
  a := 'v_pay := v_base + v_unit * (v_tai + case when v_winner = v_dealer or i = v_dealer then v_extra else 0 end);';
  b := 'v_pay := v_base + v_unit * (v_tai + case when v_winner = v_dealer or i = v_dealer then v_extra * v_mult else 0 end);';
  execute n_of into v_cnt using v_new, a;
  if v_cnt <> 1 then raise exception 'ⓓ 算每一份的那一行出現 % 次', v_cnt; end if;
  v_new := replace(v_new, a, b);

  execute v_new;
end $$;

-- ── 驗證（單一 SELECT；提交之後仍要另外查一次線上）──
select string_agg(x, E'\n' order by x) as "驗證"
from (
  select (case when count(*) = 1 then '✅' else '🔴' end) || ' ① 主檔有豹子：'
         || coalesce(max(label || ' · ' || tai || ' 台 · 最多 ' || max_count || ' 次 · ' || group_key || ' · 排序 ' || sort), '（沒有）') as x
    from scoring_patterns where code = 'baozi' and is_active
  union all
  select (case when d ~ 'v_mult int := 1;' then '✅' else '🔴' end) || ' ② 宣告了倍數'
    from (select pg_get_functiondef('public.tbl_submit_hand_tx(text,text,smallint,jsonb)'::regprocedure) d) f
  union all
  select (case when d ~ $q$if p\.code = 'baozi' then v_mult := 1 \+ v_n; end if;$q$ then '✅' else '🔴' end) || ' ③ 讀到豹子記下倍數'
    from (select pg_get_functiondef('public.tbl_submit_hand_tx(text,text,smallint,jsonb)'::regprocedure) d) f
  union all
  select (case when d ~ 'v_tai := v_tai \* v_mult;' then '✅' else '🔴' end) || ' ④ 牌型台數乘倍數'
    from (select pg_get_functiondef('public.tbl_submit_hand_tx(text,text,smallint,jsonb)'::regprocedure) d) f
  union all
  select (case when d ~ 'then v_extra \* v_mult else 0 end' then '✅' else '🔴' end) || ' ⑤ 莊家台乘倍數'
    from (select pg_get_functiondef('public.tbl_submit_hand_tx(text,text,smallint,jsonb)'::regprocedure) d) f
  union all
  -- 授權沒有掉（CREATE OR REPLACE 不動授權；正對照）
  select (case when has_function_privilege('anon', 'public.tbl_submit_hand_tx(text,text,smallint,jsonb)'::regprocedure, 'execute')
                and has_function_privilege('authenticated', 'public.tbl_submit_hand_tx(text,text,smallint,jsonb)'::regprocedure, 'execute')
               then '✅' else '🔴' end) || ' ⑥ 平板仍叫得動'
  union all
  select (case when count(*) = 1 then '✅' else '🔴' end) || ' ⑦ 送一局的函式只有一個版本（' || count(*) || '）'
    from pg_proc where pronamespace = 'public'::regnamespace and proname = 'tbl_submit_hand_tx'
) v;
