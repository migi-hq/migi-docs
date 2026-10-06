/* ============================================================
   單則通知標成已讀（2026-10-07）

   起點：使用者回報配桌頁的「你的牌局結算完成」提示**看完了還一直在**。
   原因：配桌頁把所有 settle 通知都列成提示，沒有任何條件會讓它消失；
     而後端只有「全部標成已讀」（mark_notifs_read_tx）——
     按「查看」就全部標已讀的話，鈴鐺上其他沒看過的通知會一起被當成看過。
   ✅ 這一支只標**那一則**；前端改成配桌頁只列沒讀過的結算通知，按「查看 ›」就標掉它。

   🔴 身分照 2026-09-29 的規矩：只認登入的本人（current_member_id），只能標自己的通知。
   ⚠ 新函式預設全關（2026-09-29），這裡明確 grant 給 authenticated。
   ⚠ 驗證段只有一支 SELECT，不用 raise。
   ============================================================ */

create or replace function public.mark_notif_read_tx(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := public.current_member_id();
  v_n int;
begin
  if v_me is null then
    raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000';
  end if;
  update app_notifications
     set read_at = now()
   where id = p_id and member_id = v_me and read_at is null;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'marked', v_n);
end $$;
revoke execute on function public.mark_notif_read_tx(uuid) from public, anon;
grant  execute on function public.mark_notif_read_tx(uuid) to authenticated;

/* ── 驗證（單一 SELECT）──────────────────────────────────────
   ① 函式在、版本數 1
   ② 登入的人叫得動，沒登入的叫不動
   ③ 有「只認本人」那一段（比對程式，不比對註解）
   ④ 沒登入時直接呼叫會被擋（MCP／SQL Editor 沒有 JWT ⇒ 應該拿到「未登入」）—— 正對照：擋牆是活的 */
select concat_ws(E'\n',
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'mark_notif_read_tx') = 1
       then '✅ ① 函式在，版本數 1' else '🔴 ① 函式不在或有兩個版本' end,
  case when has_function_privilege('authenticated', 'public.mark_notif_read_tx(uuid)', 'execute')
        and not has_function_privilege('anon', 'public.mark_notif_read_tx(uuid)', 'execute')
       then '✅ ② 登入的人叫得動，沒登入的叫不動' else '🔴 ② 授權不對' end,
  case when pg_get_functiondef('public.mark_notif_read_tx(uuid)'::regprocedure) ~ 'member_id = v_me and read_at is null'
       then '✅ ③ 只標本人的、還沒讀過的那一則' else '🔴 ③ 找不到「只認本人」那一段' end
) as "驗證";
