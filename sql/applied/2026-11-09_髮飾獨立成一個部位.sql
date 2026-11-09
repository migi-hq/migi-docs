/* ============================================================
   髮飾獨立成一個部位（hair）—— 2026-11-09 使用者：「髮飾獨立成一類，不跟頭部共用」
   ------------------------------------------------------------
   前端（migi-web closet.jsx）把六款髮飾（櫻花／大熊星／雪花／蝴蝶結／莓果／麻將）放到新部位 hair，
   ⇒ 可以毛線帽（head）＋ 一個髮飾（hair）一起戴。
   後端 set_my_outfit_tx 原本只收 head／neck／hand／feet，送 hair 會回 bad_slot ⇒ 這份把 hair 加進白名單。

   · 簽名不變（p_outfit jsonb）⇒ CREATE OR REPLACE，不會丟掉授權（硬規則 2）
   · 函式本體從線上 pg_get_functiondef 撈出來，只改部位白名單那一行（硬規則 3）
   · get_my_closet_tx 不用改：它讀回 outfit 時不看部位名，只留「目前還擁有」的那幾件
   · 松果髮夾（pinecone）同日從前端刪掉；查過沒有任何成就送它、沒有人穿著 ⇒ 後端不用動
   ⚠ 驗證段不用 raise（硬規則 1.8）
   ============================================================ */

create or replace function public.set_my_outfit_tx(p_outfit jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_me uuid; v_org uuid; k text; v text; v_clean jsonb := '{}'::jsonb;
begin
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  select org_id into v_org from members where id = v_me and deleted_at is null;

  if p_outfit is null or jsonb_typeof(p_outfit) <> 'object' then
    return jsonb_build_object('ok', false, 'reason', 'bad_args', 'message', '穿搭格式不對');
  end if;

  for k, v in select key, value #>> '{}' from jsonb_each(p_outfit) loop
    -- 部位白名單：前端 closet.jsx 的 NO_OUTFIT 是同一份清單，加新部位兩邊一起加（2026-11-09 加 hair 髮飾）
    if k not in ('head', 'hair', 'neck', 'hand', 'feet') then
      return jsonb_build_object('ok', false, 'reason', 'bad_slot', 'message', '沒有這個部位', 'slot', k);
    end if;
    continue when v is null or v = '';
    if not exists (select 1 from public._member_closet(v_me) c where c.item = v) then
      return jsonb_build_object('ok', false, 'reason', 'not_owned', 'message', '還沒拿到這件配件', 'item', v);
    end if;
    v_clean := v_clean || jsonb_build_object(k, v);
  end loop;

  insert into member_app_state (member_id, org_id, bear, titles, outfit, updated_at)
  values (v_me, v_org, '{}'::jsonb, '[]'::jsonb, v_clean, now())
  on conflict (member_id) do update set outfit = excluded.outfit, updated_at = now();

  return jsonb_build_object('ok', true, 'outfit', v_clean);
end $function$;

/* ── 驗證（單一 SELECT）── */
select
  case when (select count(*) from pg_proc where proname = 'set_my_outfit_tx' and pronamespace = 'public'::regnamespace) = 1
       then '✅' else '🔴' end || ' ① 只有一個版本（沒有多載）' || E'\n' ||
  case when pg_get_functiondef('public.set_my_outfit_tx(jsonb)'::regprocedure) ~ $$k not in \('head', 'hair', 'neck', 'hand', 'feet'\)$$
       then '✅' else '🔴' end || ' ② 部位白名單有 hair' || E'\n' ||
  case when has_function_privilege('authenticated', 'public.set_my_outfit_tx(jsonb)'::regprocedure, 'execute')
       then '✅' else '🔴' end || ' ③ 登入的會員叫得動（授權沒掉）' || E'\n' ||
  case when not exists (select 1 from aclexplode(coalesce((select proacl from pg_proc where oid = 'public.set_my_outfit_tx(jsonb)'::regprocedure), '{}')) a
                         where a.grantee in ('anon'::regrole::oid, 0) and a.privilege_type = 'EXECUTE')
       then '✅' else '🔴' end || ' ④ 沒登入的叫不動（anon 與 PUBLIC 都沒有）' || E'\n' ||
  case when (select prosecdef from pg_proc where oid = 'public.set_my_outfit_tx(jsonb)'::regprocedure)
       then '✅' else '🔴' end || ' ⑤ 仍是 SECURITY DEFINER'
  as "驗證";
