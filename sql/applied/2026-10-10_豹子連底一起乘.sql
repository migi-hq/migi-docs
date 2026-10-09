-- ============================================================
-- 豹子改成「整筆都乘（含底）」（2026-10-10，使用者：第 17 局總分應該是 510）
--
-- 早上上線的版本是「牌型台數 ＋ 莊家台 × 倍數，底不乘」（2026-10-10_智慧計分板豹子.sql）。
-- 使用者核對第 17 局時改成連底一起乘：
--   每一份 ＝（底 ＋ 每台 ×（牌型台數 ＋ 莊家台））× 倍數
--   例：底 50、每台 20、6 台、豹子 ×3 →（50 ＋ 6 × 20）× 3 ＝ 510
-- 寫法上等於「底 × 倍數 ＋ 每台 ×（乘過的牌型台數 ＋ 莊家台 × 倍數）」——
--   hands.tai_pattern 照舊存乘過的牌型台數，畫面寫成「N 底 M 台」（N ＝ 倍數）就加得起來。
--
-- 只換 tbl_submit_hand_tx 的一行（讀線上全文；那一行要剛好出現一次）。
-- ⚠ 三份一起改：平板 lib/rules.js、教學 lib/engine.js（同日已改）。
-- ============================================================

do $$
declare
  v_def text; v_new text; v_cnt int;
  a constant text := 'v_pay := v_base + v_unit * (v_tai + case when v_winner = v_dealer or i = v_dealer then v_extra * v_mult else 0 end);';
  b constant text := 'v_pay := v_base * v_mult + v_unit * (v_tai + case when v_winner = v_dealer or i = v_dealer then v_extra * v_mult else 0 end);   -- 豹子連底一起乘（2026-10-10）';
begin
  v_def := pg_get_functiondef('public.tbl_submit_hand_tx(text,text,smallint,jsonb)'::regprocedure);
  v_cnt := (length(v_def) - length(replace(v_def, a, ''))) / length(a);
  if v_cnt <> 1 then raise exception '算每一份的那一行出現 % 次，停下來', v_cnt; end if;
  v_new := replace(v_def, a, b);
  execute v_new;
end $$;

-- ── 驗證（單一 SELECT）──
select string_agg(x, E'\n' order by x) as "驗證"
from (
  select (case when d ~ 'v_pay := v_base \* v_mult \+ v_unit \* \(v_tai \+ case when v_winner = v_dealer or i = v_dealer then v_extra \* v_mult'
               then '✅' else '🔴' end) || ' ① 底也乘倍數' as x
    from (select pg_get_functiondef('public.tbl_submit_hand_tx(text,text,smallint,jsonb)'::regprocedure) d) f
  union all
  select (case when d !~ 'v_pay := v_base \+ v_unit \* \(v_tai \+ case when v_winner' then '✅' else '🔴' end) || ' ② 舊寫法已經不在'
    from (select pg_get_functiondef('public.tbl_submit_hand_tx(text,text,smallint,jsonb)'::regprocedure) d) f
  union all
  -- 正對照：包牌那一行不吃豹子，應該維持原樣
  select (case when d ~ 'v_pay := v_base \+ v_unit \* \(c_bao_tai' then '✅' else '🔴' end) || ' ③ 包牌的算法沒被動到'
    from (select pg_get_functiondef('public.tbl_submit_hand_tx(text,text,smallint,jsonb)'::regprocedure) d) f
  union all
  select (case when has_function_privilege('anon', 'public.tbl_submit_hand_tx(text,text,smallint,jsonb)'::regprocedure, 'execute')
               then '✅' else '🔴' end) || ' ④ 平板仍叫得動'
  union all
  select (case when count(*) = 1 then '✅' else '🔴' end) || ' ⑤ 只有一個版本（' || count(*) || '）'
    from pg_proc where pronamespace = 'public'::regnamespace and proname = 'tbl_submit_hand_tx'
) v;
