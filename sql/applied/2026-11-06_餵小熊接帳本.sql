/* ============================================================
   2026-11-06 · 餵小熊接上帳本：扣點心、加成長值、升級，全部由後端算
     使用者：「餵小熊的區域要接回來」（封測期間獎勵頁只先放出 3D 小熊，數值卡與點心櫃還藏著）

   ── 為什麼不能直接把畫面放出來 ──
   · 數值卡的餅乾數讀 member_app_state.bear.snacks（舊的顯示值），頂條讀帳本 snack_grants
     ⇒ 放出來會是「頂條 12、這裡 ×0」
   · 餵食只改畫面：前端自己算成長值與等級，再用 save_app_state_tx 整包存回去
     ⇒ 等級是前端說了算（硬規則 5.8），而等級日後會解鎖任務與獎勵

   ── 這份做三件事 ──
   ① 新增 feed_bear_tx(點心種類, 數量, 冪等鍵)：同一個交易裡
        扣點心（叫既有的 consume_snack_tx，帳本、冪等鍵都沿用）→ 加成長值 → 滿 100 升一級
      成長值只有這裡一份：小熊餅乾 10、珍珠奶茶 15、焦糖布丁 25、提拉米蘇 50（跟前端點心櫃寫的一樣）
      網路重試送同一把冪等鍵 ⇒ 不會扣兩次、也不會加兩次成長值
   ② save_app_state_tx 不再接受 lv、grow（同 2026-09-19 不再接受 snacks）——只存小熊名字這類他自己的選擇
      參數簽名不變，舊版前端照送不會壞，送了也被忽略
   ③ 把 101 隻小熊的「Lv1、成長 60%」改成「Lv1、成長 0%」
      60% 是前端寫死的示範初始值（查過：帳本裡餵食 0 筆，沒有任何一隻是真的養出來的）

   · 身分一律 current_member_id()，前端叫得到 ⇒ 明確 grant 給 authenticated（硬規則 2.7）
   · 行為測試另外一份：sql/checks/2026-11-06_驗餵小熊.sql（交易內造樣本、最後回滾）
   ============================================================ */

create or replace function public.feed_bear_tx(p_kind text, p_qty integer default 1, p_idem_key text default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_me    uuid := public.current_member_id();
  v_org   uuid;
  v_per   int;
  v_eat   jsonb;
  v_bear  jsonb;
  v_lv    int;
  v_grow  int;
  v_up    int := 0;
begin
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;

  /* 每一種點心給多少成長值 —— 全系統只有這一份（前端點心櫃那幾個數字只是顯示） */
  v_per := case p_kind when 'cookie' then 10 when 'milktea' then 15 when 'pudding' then 25 when 'tiramisu' then 50 end;
  if v_per is null or coalesce(p_qty, 0) < 1 or p_qty > 99 then
    return jsonb_build_object('ok', false, 'reason', 'bad_args', 'message', '這個點心不能餵');
  end if;

  select org_id into v_org from members where id = v_me;

  /* 先把這隻小熊的那一列鎖住，連點兩下「全部餵」才不會兩個請求各加一次 */
  insert into member_app_state (member_id, org_id, bear, titles, updated_at)
  values (v_me, v_org, jsonb_build_object('lv', 1, 'grow', 0), '[]'::jsonb, now())
  on conflict (member_id) do nothing;
  perform 1 from member_app_state where member_id = v_me for update;

  /* 扣點心：沿用 consume_snack_tx（帳本、點心不夠、冪等鍵都在那裡） */
  v_eat := public.consume_snack_tx(v_org, v_me, p_kind, p_qty, null, p_idem_key);
  if not coalesce((v_eat ->> 'ok')::boolean, false) then
    return v_eat || jsonb_build_object('ok', false);
  end if;

  select bear into v_bear from member_app_state where member_id = v_me;
  v_lv   := greatest(1, coalesce((v_bear ->> 'lv')::int, 1));
  v_grow := greatest(0, coalesce((v_bear ->> 'grow')::int, 0));

  /* 同一把冪等鍵重送（網路重試）：點心沒有再扣 ⇒ 成長值也不能再加，回現在的樣子就好 */
  if coalesce((v_eat ->> 'spent')::boolean, false) then
    v_grow := v_grow + v_per * p_qty;
    while v_grow >= 100 loop v_grow := v_grow - 100; v_lv := v_lv + 1; v_up := v_up + 1; end loop;
    update member_app_state
       set bear = coalesce(bear, '{}'::jsonb) || jsonb_build_object('lv', v_lv, 'grow', v_grow),
           updated_at = now()
     where member_id = v_me;
  end if;

  return jsonb_build_object('ok', true,
    'spent', coalesce((v_eat ->> 'spent')::boolean, false),
    'added', case when coalesce((v_eat ->> 'spent')::boolean, false) then v_per * p_qty else 0 end,
    'lv', v_lv, 'grow', v_grow, 'lv_up', v_up,
    'kind', p_kind, 'total', coalesce((v_eat ->> 'total')::int, 0));
end $function$;

revoke execute on function public.feed_bear_tx(text, integer, text) from public, anon;
grant  execute on function public.feed_bear_tx(text, integer, text) to authenticated;

/* ② save_app_state_tx：lv、grow 跟 snacks 一樣，一律用資料庫裡現有的 */
create or replace function public.save_app_state_tx(p_org_id uuid, p_member_id uuid, p_bear jsonb, p_titles jsonb default null::jsonb)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。 */
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  if pg_column_size(p_bear) > 8192 then raise exception 'bear state 過大'; end if;

  /* 🔴 2026-09-19：`snacks` 一律忽略 —— 點心是獎勵，來源只有發放／消耗那兩支。
     🔴 2026-09-22：**稱號參數一律忽略**（待辦 40）。
     🔴 2026-11-06：**lv、grow 一律忽略** —— 只有 feed_bear_tx 會改它們（餵了才會長大）。
       這支只存他自己的選擇（小熊名字）。參數留在簽名裡只是為了舊版前端不 404。 */
  insert into member_app_state(member_id, org_id, bear, titles, updated_at)
  values (p_member_id, p_org_id,
          (coalesce(p_bear, '{}'::jsonb) - 'snacks' - 'lv' - 'grow') || jsonb_build_object('lv', 1, 'grow', 0),
          '[]'::jsonb, now())
  on conflict (member_id) do update set
    bear = (coalesce(excluded.bear, '{}'::jsonb) - 'snacks' - 'lv' - 'grow')
           || jsonb_build_object(
                'snacks', coalesce(member_app_state.bear -> 'snacks', '{}'::jsonb),
                'lv',     coalesce(member_app_state.bear -> 'lv', '1'::jsonb),
                'grow',   coalesce(member_app_state.bear -> 'grow', '0'::jsonb)),
    updated_at = now();
end $function$;

/* ③ 示範初始值歸零（只動「Lv1、60%」那種；真的被餵過的不會是這個組合，而且帳本餵食 0 筆） */
update member_app_state
   set bear = bear || jsonb_build_object('grow', 0), updated_at = now()
 where bear ->> 'lv' = '1' and bear ->> 'grow' = '60';

/* ── 驗證（單一 SELECT）── */
select concat_ws(E'\n',
  case when to_regprocedure('public.feed_bear_tx(text, integer, text)') is not null
       then '✅ ① feed_bear_tx 建好了' else '🔴 ① feed_bear_tx 不存在' end,
  case when has_function_privilege('authenticated', 'public.feed_bear_tx(text, integer, text)', 'execute')
        and not exists (select 1 from aclexplode(coalesce((select proacl from pg_proc where oid = 'public.feed_bear_tx(text, integer, text)'::regprocedure), '{}')) a
                         where a.grantee in (0, 'anon'::regrole::oid) and a.privilege_type = 'EXECUTE')
       then '✅ ② 登入的會員叫得到，沒登入（anon）與 PUBLIC 叫不到'
       else '🔴 ② 授權不對' end,
  case when has_function_privilege('authenticated', 'public.save_app_state_tx(uuid, uuid, jsonb, jsonb)', 'execute')
       then '✅ ③ save_app_state_tx 前端照樣叫得到（重建沒有丟掉授權）' else '🔴 ③ save_app_state_tx 前端叫不到了' end,
  case when (select count(*) from member_app_state where bear ->> 'lv' = '1' and bear ->> 'grow' = '60') = 0
       then '✅ ④ 示範初始值歸零了：Lv1、0% 的小熊 ' || (select count(*) from member_app_state where bear ->> 'lv' = '1' and bear ->> 'grow' = '0') || ' 隻（改之前查過是 101）'
       else '🔴 ④ 還有 ' || (select count(*) from member_app_state where bear ->> 'lv' = '1' and bear ->> 'grow' = '60') || ' 隻是 Lv1、60%' end,
  '⚪ 餵食的行為（扣點心、加成長值、升級、重送不重複、點心不夠）請另外跑 sql/checks/2026-11-06_驗餵小熊.sql'
) as "驗證";
