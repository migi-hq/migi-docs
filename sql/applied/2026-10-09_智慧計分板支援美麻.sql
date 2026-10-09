-- ============================================================
-- 智慧計分板支援美麻（2026-10-09，使用者：「馬上改，記分板也支援美麻」）
--
-- 起因：A1 開了一場「美麻・有花」，平板擋在「這桌是美麻，記分板目前只支援台麻」。
-- 擋的地方有四處，全部改成「台麻或美麻都放行」：
--   _tbl_state_for_device   回給平板的 supported 旗標
--   tbl_submit_hand_tx      送一局
--   tbl_bonus_tx            分紅
--   tbl_set_order_tx        定座位
--
-- ⚠ 計分規則沿用台麻那一套（台數、底、自摸、包牌、咔啦碰、分紅都一樣）——
--   美麻若有不同的算法，要另外談，這一份只拿掉擋牆。
-- ⚠ table_sessions.game_type 的 CHECK 只收台麻／美麻 ⇒ 改完之後實際上每一桌都放行；
--   判斷仍寫成「在這兩種裡面」而不是整個拿掉，日後多一種玩法時它會自己擋下來。
--
-- 做法：讀線上全文 → 只換那幾行 → CREATE OR REPLACE（簽名不變，授權不會掉）。
-- 任何一支沒換到就整份停下來（那是故意不要提交的那一種，見硬規則 1.8）。
-- ============================================================

do $$
declare
  v_def text;
  v_new text;
begin
  -- ① 平板的 supported 旗標
  v_def := pg_get_functiondef('public._tbl_state_for_device(table_devices)'::regprocedure);
  v_new := replace(v_def, $q$'supported', coalesce(s.game_type, '台麻') = '台麻',$q$,
                          $q$'supported', coalesce(s.game_type, '台麻') in ('台麻', '美麻'),$q$);
  if v_new = v_def then raise exception '_tbl_state_for_device 沒有換到'; end if;
  execute v_new;

  -- ②③④ 三支寫入函式的擋牆與錯誤訊息
  for v_def in
    select pg_get_functiondef(p) from unnest(array[
      'public.tbl_submit_hand_tx(text,text,smallint,jsonb)'::regprocedure,
      'public.tbl_bonus_tx(text,smallint,integer)'::regprocedure,
      'public.tbl_set_order_tx(text,uuid,uuid,uuid)'::regprocedure]) as p
  loop
    v_new := replace(v_def, $q$if coalesce(s.game_type, '台麻') <> '台麻' then$q$,
                            $q$if coalesce(s.game_type, '台麻') not in ('台麻', '美麻') then$q$);
    if v_new = v_def then raise exception '有一支寫入函式的擋牆沒有換到'; end if;
    v_new := replace(v_new, '記分板目前只支援台麻', '記分板目前只支援台麻與美麻');
    execute v_new;
  end loop;
end $$;

-- ── 驗證（單一 SELECT；提交之後仍要另外查一次線上）──
select string_agg(x, E'\n' order by x) as "驗證"
from (
  select case when pg_get_functiondef(p.oid) ~ $q$'supported', coalesce\(s\.game_type, '台麻'\) in \('台麻', '美麻'\)$q$
              then '✅ ' else '🔴 ' end || p.proname || '：平板旗標' as x
    from pg_proc p where p.oid = 'public._tbl_state_for_device(table_devices)'::regprocedure
  union all
  select case when pg_get_functiondef(p.oid) ~ $q$not in \('台麻', '美麻'\) then$q$
               and pg_get_functiondef(p.oid) !~ $q$<> '台麻' then$q$
              then '✅ ' else '🔴 ' end || p.proname || '：擋牆'
    from pg_proc p
   where p.oid in ('public.tbl_submit_hand_tx(text,text,smallint,jsonb)'::regprocedure,
                   'public.tbl_bonus_tx(text,smallint,integer)'::regprocedure,
                   'public.tbl_set_order_tx(text,uuid,uuid,uuid)'::regprocedure)
  union all
  -- 授權沒有掉（CREATE OR REPLACE 不會動授權；這一格是正對照）
  select case when has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute')
              then '✅ ' else '🔴 ' end || p.proname || '：平板叫得動'
    from pg_proc p
   where p.oid in ('public.tbl_submit_hand_tx(text,text,smallint,jsonb)'::regprocedure,
                   'public.tbl_bonus_tx(text,smallint,integer)'::regprocedure,
                   'public.tbl_set_order_tx(text,uuid,uuid,uuid)'::regprocedure)
) v;
