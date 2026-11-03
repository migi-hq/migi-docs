/* ============================================================
   我的小熊餅乾數：會員 App 頂條（通知鈴鐺左邊）讀這一支
   2026-11-03 · 寫入（migration）· 在 Supabase Dashboard 的 SQL Editor 執行

   ── 為什麼另開一支，不讀 member_app_state.bear.snacks ──
   · 正本是帳本 snack_grants（2026-09-19 起；扣餅乾的 consume_snack_tx 也是看帳本）
   · bear.snacks 只是顯示用的副本，而它**對不上**：2026-11-03 查 22 位有餅乾的會員，4 位的副本是空的
     （grant_snack_tx 用 jsonb_set 寫 snacks.cookie，bear 裡還沒有 snacks 這一層時 jsonb_set 不會幫忙建，等於沒寫）
   ⇒ 頂條直接從帳本加總，不碰副本

   ── 規則 ──
   · 身分一律 current_member_id()，不收會員 id 參數
   · 回四種點心各幾個（沒有的回 0）；隱藏中的會員打不開 App，不用另外處理
   ============================================================ */

create or replace function public.get_my_snacks_tx()
returns jsonb
language plpgsql
stable
security definer
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
             'tiramisu', coalesce(sum(qty) filter (where kind = 'tiramisu'), 0))
      from snack_grants
     where member_id = v_me);
end $function$;

revoke execute on function public.get_my_snacks_tx() from public, anon;
grant execute on function public.get_my_snacks_tx() to authenticated;

/* ── 驗證（單一 SELECT，不 raise）──────────────────────────── */
select
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'get_my_snacks_tx') = 1
       then '✅' else '🔴' end || ' ① get_my_snacks_tx 一個版本'
  || E'\n' ||
  case when has_function_privilege('authenticated', 'public.get_my_snacks_tx()', 'execute')
       then '✅' else '🔴' end || ' ② 登入的會員叫得動'
  || E'\n' ||
  case when not has_function_privilege('anon', 'public.get_my_snacks_tx()', 'execute')
       then '✅' else '🔴' end || ' ③ 沒登入叫不動'
  || E'\n' ||
  case when (select prosecdef from pg_proc where oid = 'public.get_my_snacks_tx()'::regprocedure)
       then '✅' else '🔴' end || ' ④ DEFINER（帳本表 0 policy，要靠它讀）'
  as "驗證";
