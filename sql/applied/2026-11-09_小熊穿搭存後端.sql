/* ============================================================
   小熊穿什麼存後端
   2026-11-09 使用者：「穿了甚麼存後端嗎?」→「做」

   ① member_app_state 加一欄 outfit jsonb（{ head, neck, hand, feet }，值是配件代碼或沒有這個鍵）
      🔴 刻意不放進 bear：bear 是前端整包送來的（save_app_state_tx），放在裡面就能自己送一包
        穿上沒拿到的配件，繞過「贏一場才有毛線帽」。獨立一欄只有 set_my_outfit_tx 寫得進去
   ② set_my_outfit_tx(p_outfit)：存整套穿搭。每一件都要是自己擁有的（_member_closet），否則整筆拒絕、什麼都不改
      部位只收 head／neck／hand／feet；「某件配件屬於哪個部位」在前端（lib/closet.jsx 的 slot），後端只管擁有
   ③ get_my_closet_tx 多回 outfit：只留目前還擁有的那幾件（配件日後若被收回，讀的時候自動脫掉，不會穿著自己沒有的東西）

   ⚠ 新函式預設前端叫不到（硬規則 2.7）⇒ 明確 grant 給 authenticated；身分一律 current_member_id()
   ⚠ 行為測試另一份：sql/checks/2026-11-09_驗小熊穿搭存後端.sql（要造樣本、會 raise 回滾，所以不放在這份 —— 硬規則 1.8）
   ============================================================ */

-- ①
alter table public.member_app_state add column if not exists outfit jsonb not null default '{}'::jsonb;
comment on column public.member_app_state.outfit is
  '小熊穿搭 { head, neck, hand, feet } → 配件代碼。只有 set_my_outfit_tx 會寫（每件都檢查擁有）；不要併進 bear（bear 是前端整包送來的）。';

-- ②
create or replace function public.set_my_outfit_tx(p_outfit jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid; v_org uuid; k text; v text; v_clean jsonb := '{}'::jsonb;
begin
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  select org_id into v_org from members where id = v_me and deleted_at is null;

  if p_outfit is null or jsonb_typeof(p_outfit) <> 'object' then
    return jsonb_build_object('ok', false, 'reason', 'bad_args', 'message', '穿搭格式不對');
  end if;

  for k, v in select key, value #>> '{}' from jsonb_each(p_outfit) loop
    if k not in ('head', 'neck', 'hand', 'feet') then
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
end $$;
revoke execute on function public.set_my_outfit_tx(jsonb) from public;
revoke execute on function public.set_my_outfit_tx(jsonb) from anon;
grant execute on function public.set_my_outfit_tx(jsonb) to authenticated;

-- ③ get_my_closet_tx 多回 outfit（簽名不變，CREATE OR REPLACE 不掉 GRANT；本體以 2026-11-09 建立的那一版為準，只加 outfit）
create or replace function public.get_my_closet_tx()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_me uuid; v_org uuid; v_owned jsonb; v_how jsonb; v_outfit jsonb;
begin
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  select org_id into v_org from members where id = v_me and deleted_at is null;

  select coalesce(jsonb_agg(jsonb_build_object('item', c.item, 'source', c.source, 'got_at', c.got_at) order by c.got_at nulls last), '[]'::jsonb)
    into v_owned from public._member_closet(v_me) c;

  /* 還沒拿到、而且看得到的成就會送的那幾件：點反灰的配件時告訴客人要做什麼
     ⚠ 隱藏或剪影的成就不列 —— 列了等於把隱藏條件講出來（同 get_my_titles_tx） */
  select coalesce(jsonb_agg(jsonb_build_object('item', a.grants_closet, 'achievement', a.name, 'condition', a.condition_text)
                            order by a.sort, a.code), '[]'::jsonb)
    into v_how
    from achievements a
   where a.org_id = v_org and a.deleted_at is null and a.is_active
     and a.grants_closet is not null and a.visibility = 'visible'
     and not exists (select 1 from public._member_closet(v_me) c where c.item = a.grants_closet);

  /* 穿搭：只留目前還擁有的那幾件（配件日後若被收回，讀的時候自動脫掉） */
  select coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb)
    into v_outfit
    from member_app_state s, jsonb_each(s.outfit) e
   where s.member_id = v_me
     and exists (select 1 from public._member_closet(v_me) c where c.item = e.value #>> '{}');

  return jsonb_build_object('owned', v_owned, 'how', v_how, 'outfit', coalesce(v_outfit, '{}'::jsonb));
end $$;

-- ============================================================
-- 驗證（單一 SELECT；不用 raise —— 硬規則 1.8）
-- ============================================================
select
  (select case when exists (select 1 from information_schema.columns where table_schema='public' and table_name='member_app_state'
                              and column_name='outfit' and is_nullable='NO')
          then '✅ ① member_app_state.outfit 欄位（NOT NULL）' else '🔴 ① outfit 欄位不在或可為空' end) as "①",
  (select case when count(*) = 1 then '✅ ② set_my_outfit_tx 一個版本' else '🔴 ② set_my_outfit_tx 版本數 ' || count(*) end
     from pg_proc where proname = 'set_my_outfit_tx' and pronamespace = 'public'::regnamespace) as "②",
  (select case when pg_get_functiondef('public.get_my_closet_tx()'::regprocedure) ~ '''outfit'', coalesce\(v_outfit'
          then '✅ ③ get_my_closet_tx 回傳 outfit' else '🔴 ③ get_my_closet_tx 沒有回 outfit' end) as "③",
  /* ④ 授權兩支都看兩個方向（硬規則 2.6） */
  (select case when has_function_privilege('authenticated', 'public.set_my_outfit_tx(jsonb)', 'EXECUTE')
               and not has_function_privilege('anon', 'public.set_my_outfit_tx(jsonb)', 'EXECUTE')
               and has_function_privilege('authenticated', 'public.get_my_closet_tx()', 'EXECUTE')
               and not has_function_privilege('anon', 'public.get_my_closet_tx()', 'EXECUTE')
          then '✅ ④ 授權：兩支都只給登入的人' else '🔴 ④ 授權不對' end) as "④",
  /* ⑤ 正對照：存檔函式沒有把新欄位蓋掉的寫法（它們只更新自己那一欄）——
     掃「會整列覆寫 member_app_state」的寫法：update 時 set outfit 的只能是 set_my_outfit_tx */
  (select case when count(*) = 0 then '✅ ⑤ 除了 set_my_outfit_tx，沒有別的函式寫 outfit'
               else '🔴 ⑤ 還有函式寫 outfit：' || string_agg(p.proname, '、') end
     from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and p.proname <> 'set_my_outfit_tx'
      and pg_get_functiondef(p.oid) ~ 'outfit\s*=\s*excluded') as "⑤";
