-- ============================================================
-- 2026-10-17 會員 App「手機計分板」：重按不再作廢上一組，沿用同一組配對碼
-- MIGI 咪吉麻將
--
-- 起因：A2 兩位新客人（Min、竣瑋）今晚各產生了 2～3 組碼、一組都沒用掉。
--   原本每按一次就換一組新的、上一組立刻作廢 ⇒ 客人把帶著碼 A 的連結加到主畫面後，
--   回 App 再按一次（覺得沒反應）就產生碼 B、碼 A 作廢 ⇒ 從主畫面打開自動送出碼 A 失敗，
--   格子被清空，看起來就是「要我輸入」，而 App 不顯示碼 ⇒ 卡住。
--
-- 改成：自己產生、還沒用掉、剩不到 1 小時以上的那一組 ⇒ 直接回同一組（同一個碼、同一個連結）。
--   只有沒有可用的一組（或剩不到 1 小時）才產生新的，那時才把舊的作廢。
--   ⇒ 按幾次都是同一組，主畫面圖示帶著的碼永遠是有效的那一組。
-- ⚠ 成桌卡片、後台發、平板發的碼不受影響（只看 self_issued）。
-- ⚠ 簽名不變 ⇒ CREATE OR REPLACE，授權（postgres／service_role／authenticated）保留。
-- ============================================================

create or replace function public.my_phone_code_tx()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_me uuid := public.current_member_id();
  v_org uuid;
  v_code text;
  v_exp timestamptz;
begin
  if v_me is null then
    raise exception '未登入，請從 LINE 重新開啟' using errcode = '28000';
  end if;
  select org_id into v_org from members where id = v_me;

  -- 還有可用的一組就沿用（2026-10-17：重按不作廢，主畫面帶著的那組才不會失效）
  select c.code, c.expires_at into v_code, v_exp
    from table_phone_codes c
   where c.member_id = v_me and c.self_issued and c.used_at is null
     and c.expires_at > now() + interval '1 hour'
   order by c.created_at desc
   limit 1;

  if v_code is null then
    -- 沒有可用的（或快過期）才換一組新的；舊的那幾組這時才作廢
    update table_phone_codes set expires_at = now()
     where member_id = v_me and self_issued and used_at is null and expires_at > now();

    v_exp := now() + interval '24 hours';
    v_code := public._tbl_new_phone_code(v_org, v_me, null, null, null, v_exp);
    update table_phone_codes set self_issued = true
     where code = v_code and member_id = v_me and used_at is null and expires_at = v_exp;
  end if;

  return jsonb_build_object('ok', true, 'code', v_code, 'expires_at', v_exp,
    'url', 'https://table.migi.tw/?install=1&code=' || v_code);
end $function$;

-- 驗證（單一 SELECT；不 raise —— 硬規則 1.8，跑完我會另外查一次線上）
select concat_ws(E'\n',
  (select case when count(*) = 1 then '✅ ① 只有 1 個版本' else '🔴 ① 有 ' || count(*) || ' 個版本' end
     from pg_proc where proname = 'my_phone_code_tx'),
  (select case when p.prosecdef then '✅ ② 仍是 SECURITY DEFINER' else '🔴 ② 變成 INVOKER 了' end
     from pg_proc p where p.proname = 'my_phone_code_tx'),
  (select case
            when has_function_privilege('authenticated', p.oid, 'execute')
             and not exists (select 1 from aclexplode(p.proacl) a where a.privilege_type = 'EXECUTE' and a.grantee in (0, 'anon'::regrole::oid))
            then '✅ ③ 登入的人叫得動；anon 與 PUBLIC 都沒有'
            else '🔴 ③ 授權跑掉了：' || coalesce((select string_agg(coalesce(nullif(a.grantee::regrole::text, '-'), 'PUBLIC'), ',') from aclexplode(p.proacl) a where a.privilege_type = 'EXECUTE'), '（空）')
          end
     from pg_proc p where p.proname = 'my_phone_code_tx'),
  (select case when pg_get_functiondef(p.oid) ~ 'expires_at > now\(\) \+ interval ''1 hour'''
                and pg_get_functiondef(p.oid) ~ 'if v_code is null then'
               then '✅ ④ 新版：有可用的一組就沿用'
               else '🔴 ④ 還是舊版（每按一次就換）' end
     from pg_proc p where p.proname = 'my_phone_code_tx'),
  -- 正對照：今晚那兩組（Min、竣瑋）應該還有效 —— 這份只換函式、不碰資料
  (select '📌 ⑤ 今晚還有效、沒用掉的自己產生碼：' || count(*) || ' 組（預期至少 2，客人用掉了會變少）'
     from table_phone_codes c join members m on m.id = c.member_id
    where m.display_name in ('Min', '竣瑋') and c.self_issued and c.used_at is null and c.expires_at > now())
) as "驗證";
