-- 2026-10-18 牌咖頁「全部牌咖團」也列出自己已經加入的團（使用者：「點了全部，目前沒出現自己的牌咖團是為何？」）
--
-- 原因：search_teams_tx 刻意濾掉兩種團 —— 你已經在裡面的、不開放申請的。
--   頁名改成「全部牌咖團」之後，少了自己的團就是一句說錯的話。
-- 這一份只拿掉「你已經在裡面」那一道；不開放申請的團仍然不列（另外問使用者）。
-- 前端用自己的團清單判斷「已加入」（灰色膠囊、點了打開團的抽屜），後端不必多回欄位。
--
-- 簽名不變 ⇒ create or replace，授權（postgres／authenticated／service_role）不受影響。

create or replace function public.search_teams_tx(p_q text default null::text, p_limit integer default 20)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_me    uuid := public.current_member_id();
  v_org   uuid := public.current_org_id();
  v_store uuid;
  v_name  text;
  v_q     text := nullif(btrim(coalesce(p_q, '')), '');
  v_rows  jsonb;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  /* 🔴 「常去」有門檻，答不出來就回 null —— 畫面那一行整個不畫。
     在此之前這裡是「依場次數遞減取第一名」，也就是**去過一次也算常去**。
     ⚠ 這段說明**刻意不寫出那個舊寫法的字面**（硬規則 3.5）——
       驗證段要掃「舊寫法還在不在」，而 `pg_get_functiondef` 回的是
       含註解的全文，寫出來會讓那一格**永遠是紅的**，
       而一個永遠紅的檢查會讓人學會忽略紅色。 */
  v_store := public._member_home_store(v_me);
  select s.name into v_name from public.stores s where s.id = v_store;

  /* 2026-10-18：自己已經加入的團也列（頁名是「全部牌咖團」）。
     ⚠ 不開放申請的團照舊不列 —— 列出來只能顯示一顆按不了的「不開放」。 */
  select coalesce(jsonb_agg(card order by ord, cnt desc, nm), '[]'::jsonb)
    into v_rows
    from (
      select public._team_card(t.id) as card,
             case when v_store is not null and t.home_store_id = v_store then 0 else 1 end as ord,
             (select count(*) from public.team_members tm
               where tm.team_id = t.id and tm.left_at is null) as cnt,
             t.name as nm
        from public.teams t
       where t.org_id = v_org
         and t.deleted_at is null
         and t.join_policy <> 'closed'
         and (v_q is null or t.name ilike '%' || v_q || '%')
       limit greatest(1, least(coalesce(p_limit, 20), 50))
    ) s;

  return jsonb_build_object('ok', true, 'teams', v_rows,
                            'q', v_q,
                            'recommend_store_id',   case when v_q is null then v_store end,
                            'recommend_store_name', case when v_q is null then v_name end);
end $function$;

-- 驗證（單一 SELECT）
select
  case when (select count(*) from pg_proc where proname = 'search_teams_tx' and pronamespace = 'public'::regnamespace) = 1
       then '✅' else '🔴' end || ' ① 版本數 '
    || (select count(*) from pg_proc where proname = 'search_teams_tx' and pronamespace = 'public'::regnamespace) as "①",
  case when pg_get_functiondef('public.search_teams_tx(text,integer)'::regprocedure) !~ 'tm\.member_id\s*=\s*v_me'
       then '✅ ② 已經不濾掉自己加入的團' else '🔴 ② 還在濾自己加入的團' end as "②",
  case when pg_get_functiondef('public.search_teams_tx(text,integer)'::regprocedure) ~ 'join_policy\s*<>\s*''closed'''
       then '✅ ③ 不開放申請的團照舊不列' else '🔴 ③ 不開放的那一道不見了' end as "③",
  case when has_function_privilege('authenticated', 'public.search_teams_tx(text,integer)', 'execute')
        and not has_function_privilege('anon', 'public.search_teams_tx(text,integer)', 'execute')
       then '✅ ④ 授權不變（authenticated 有、anon 沒有）' else '🔴 ④ 授權變了' end as "④";
