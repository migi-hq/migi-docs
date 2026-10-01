/* ============================================================
   包桌續時：POS 讀取這一桌的續時狀態 · 2026-10-01
   POS 桌工作區要畫「誰要補、補幾份、四人名單」，而 _pkg_time 只給後端叫（前端叫不到）。
   ⇒ 包一層只給登入店員的唯讀函式，回傳**含會員 id** 的那一份（收款要用 id 去報價）。
   ⚠ 計分板那一側照舊走 tbl_state_tx（不含會員 id），兩邊讀的是同一份定義 _pkg_time。
   ============================================================ */

create or replace function public.pos_pkg_state_tx(p_session_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_pkg jsonb;
begin
  perform public._api_staff_only();   -- 從 API 進來的只有店員能叫
  v_pkg := public._pkg_time(p_session_id, true);
  if v_pkg is null then
    return jsonb_build_object('ok', false, 'reason', 'not_private', 'message', '這一場不是包桌');
  end if;
  return jsonb_build_object('ok', true) || v_pkg;
end $$;

revoke execute on function public.pos_pkg_state_tx(uuid) from public, anon;
grant  execute on function public.pos_pkg_state_tx(uuid) to authenticated;

-- 驗證（只讀狀態、不寫東西，不用 raise —— 硬規則 1.8）
do $$
declare v_msg text := ''; v_n int; v_r jsonb;
begin
  select count(*) into v_n from pg_proc where pronamespace = 'public'::regnamespace and proname = 'pos_pkg_state_tx';
  v_msg := v_msg || case when v_n = 1 then '✅' else '🔴' end || ' ① 函式存在，版本數 ' || v_n || E'\n';
  v_msg := v_msg || case when has_function_privilege('authenticated', 'public.pos_pkg_state_tx(uuid)', 'execute')
                          and not has_function_privilege('anon', 'public.pos_pkg_state_tx(uuid)', 'execute')
                     then '✅' else '🔴' end || ' ② 只給登入的人（anon 叫不到）' || E'\n';
  -- 負對照：配桌場次回 not_private（SQL Editor 沒有 API 身分，_api_staff_only 會放行）
  select public.pos_pkg_state_tx(ts.id) into v_r from table_sessions ts where ts.mode = 'matched' limit 1;
  v_msg := v_msg || case when v_r ->> 'reason' = 'not_private' then '✅' else '🔴' end
        || ' ③ 配桌場次回 ' || coalesce(v_r ->> 'reason', v_r::text, '（沒有配桌場次可測）');
  perform set_config('migi.pkgstate', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.pkgstate', true), ''), '🔴 沒有驗證訊息') as "驗證";
