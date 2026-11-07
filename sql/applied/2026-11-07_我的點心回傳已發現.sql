/* ============================================================
   2026-11-07　get_my_snacks_tx 多回傳「已發現過哪些點心」
   ------------------------------------------------------------
   使用者：「已發現 0/4 是錯的，之前已經有餅乾」
   原因：會員 App 點心抽屜的「已發現 N / 4」是用「現在還有幾個 > 0」算的，
        餅乾全部餵完就變 0。「已發現」應該是「曾經拿到過」。
   做法：帳本 snack_grants 拿到是正數、用掉是負數 ⇒ 有任何一筆正數＝發現過。
        回傳多一個鍵 found（點心代號的陣列），原本四個數字的鍵不變（舊版 App 照常能用）。
   ⚠ 簽名不變 ⇒ CREATE OR REPLACE，授權不會掉（硬規則 2）。
   ============================================================ */

create or replace function public.get_my_snacks_tx()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_me uuid := public.current_member_id();
begin
  if v_me is null then
    raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000';
  end if;
  return (
    select jsonb_build_object(
             'cookie',   coalesce(sum(qty) filter (where kind = 'cookie'), 0),
             'milktea',  coalesce(sum(qty) filter (where kind = 'milktea'), 0),
             'pudding',  coalesce(sum(qty) filter (where kind = 'pudding'), 0),
             'tiramisu', coalesce(sum(qty) filter (where kind = 'tiramisu'), 0),
             /* 曾經拿到過的點心（有任何一筆正數）—— 點心抽屜「已發現 N / 4」用 */
             'found',    coalesce((select jsonb_agg(distinct g.kind order by g.kind)
                                     from snack_grants g
                                    where g.member_id = v_me and g.qty > 0), '[]'::jsonb))
      from snack_grants
     where member_id = v_me);
end $function$;

/* ── 驗證（單一 SELECT，不用 raise）────────────────────────── */
select string_agg(line, E'\n' order by ord) as "驗證" from (
  select 1 as ord,
    case when (select count(*) from pg_proc where proname = 'get_my_snacks_tx' and pronamespace = 'public'::regnamespace) = 1
      then '✅ ① get_my_snacks_tx 只有一個版本' else '🔴 ① 版本數不是 1' end as line
  union all select 2,
    case when pg_get_functiondef('public.get_my_snacks_tx()'::regprocedure) like '%''found''%'
      then '✅ ② 已經回傳 found（已發現過的點心）' else '🔴 ② 還沒有 found，這份沒有提交' end
  union all select 3,
    case when has_function_privilege('authenticated', 'public.get_my_snacks_tx()', 'execute')
      then '✅ ③ 登入的會員照樣叫得動' else '🔴 ③ authenticated 叫不動了' end
  union all select 4,
    '📌 ④ 帳本裡曾經拿到過點心的會員：' || (select count(distinct member_id) from snack_grants where qty > 0) || ' 位（他們打開抽屜時「已發現」至少是 1）'
) t;
