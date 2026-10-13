-- ============================================================
-- POS 座位頁（四台平板的即時畫面）：客人改用手機計分時，也顯示他手機上的畫面
-- 2026-10-13 · MIGI 咪吉麻將
--
-- 使用者（A1 那桌，林政坤改用手機計分）：「沒有顯示手機畫面」
--   原因：pos_tbl_watch_tx 只撈「綁在這張桌的平板」（table_devices.table_id = 這張桌），
--   而手機是綁人不綁桌（table_id 是 null），靠「他坐在這一場」才連到這張桌 ⇒ 永遠撈不到。
--   A1-4 那台平板沒人坐，畫面只寫「四位都已經有裝置了」。
--
-- 改法：
--   · 多撈「這張桌現在那一場裡，綁在某位玩家身上的手機」，畫面資料一樣用 _tbl_state_for_device，
--     只是把那支手機的桌換成這張桌（同計分板自己讀狀態時的做法：手機坐 A1 就是 A1）
--   · POS 一次最多畫四格 ⇒ 有手機加進來、超過四台時，**沒人坐的平板讓出位置**（坐著人的一律保留）
--   · 排序：平板照編號（A1-1、A1-2…），手機排最後
-- 簽名不變（CREATE OR REPLACE），權限判斷一行不改。
-- ============================================================

create or replace function public.pos_tbl_watch_tx(p_table_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_store uuid; v_out jsonb;
begin
  /* 只有店員、而且要能看這間店。身分一律問 JWT（current_staff），不收前端傳的身分 */
  if (select staff_id from public.current_staff()) is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '只有店員可以看平板畫面');
  end if;
  select store_id into v_store from tables where id = p_table_id and deleted_at is null;
  if v_store is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這張桌');
  end if;
  if not public.has_store_access(v_store) then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '你不能看這間店的平板');
  end if;

  /* 這張桌的平板 ＋ 坐在這張桌那一場、綁在手機上的客人（2026-10-13）。
     bound ＝ 這台現在有沒有綁著一位在座的玩家；畫面資料跟那台裝置自己讀到的是同一份核心 */
  with sess as (
    select ts.id from table_sessions ts
     where ts.table_id = p_table_id and ts.status = 'open' and ts.deleted_at is null
  ), dev as (
    select d, false as phone,
           exists (select 1 from session_players sp, sess
                    where sp.session_id = sess.id and sp.device_id = d.id and sp.left_at is null) as bound
      from table_devices d
     where d.table_id = p_table_id and d.is_active
    union all
    select jsonb_populate_record(d, jsonb_build_object('table_id', p_table_id)), true, true
      from table_devices d
      join session_players sp on sp.device_id = d.id and sp.left_at is null
      join sess on sess.id = sp.session_id
     where d.kind = 'phone' and d.is_active and d.revoked_at is null
  ), ranked as (
    select dev.*, count(*) over () as n, count(*) filter (where bound) over () as nb,
           row_number() over (partition by bound order by (dev.d).label) as k
      from dev
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'device_id', (r.d).id, 'label', (r.d).label, 'last_seen_at', (r.d).last_seen_at,
           'state', public._tbl_state_for_device(r.d)) order by r.phone, (r.d).label), '[]'::jsonb)
    into v_out
    from ranked r
   -- 坐著人的一律留；超過四台時，沒人坐的平板只留得下剩下的位置
   where r.bound or r.n <= 4 or r.k <= greatest(4 - r.nb, 0);
  return jsonb_build_object('ok', true, 'devices', v_out);
end $function$;


-- ============================================================
-- 驗證（單一 SELECT，不 raise —— 硬規則 1.8）
--   ① 版本數 1、還是 DEFINER、權限判斷還在（not_staff／has_store_access）
--   ② 函式裡有撈手機（kind = 'phone'）
--   ③ 拿線上 A1 現在的樣子算一次（不經過店員檢查，直接用同一段條件）：
--      幾台平板、幾支綁著人的手機、最後會畫哪幾台
--   ⚠ 實際回傳要店員登入才叫得到，畫面請在 POS 座位頁看
-- ============================================================
with t as (select id, label from tables where label = 'A1' order by created_at limit 1),
sess as (select ts.id from table_sessions ts, t where ts.table_id = t.id and ts.status = 'open' and ts.deleted_at is null),
dev as (
  select d.label, false as phone,
         exists (select 1 from session_players sp, sess where sp.session_id = sess.id and sp.device_id = d.id and sp.left_at is null) as bound
    from table_devices d, t where d.table_id = t.id and d.is_active
  union all
  select d.label, true, true from table_devices d
    join session_players sp on sp.device_id = d.id and sp.left_at is null
    join sess on sess.id = sp.session_id
   where d.kind = 'phone' and d.is_active and d.revoked_at is null
), ranked as (
  select dev.*, count(*) over () as n, count(*) filter (where bound) over () as nb,
         row_number() over (partition by bound order by label) as k from dev
)
select concat_ws(E'\n',
  case when (select count(*) from pg_proc where proname = 'pos_tbl_watch_tx' and pronamespace = 'public'::regnamespace) = 1
        and (select prosecdef from pg_proc where proname = 'pos_tbl_watch_tx' and pronamespace = 'public'::regnamespace)
        and (select pg_get_functiondef('public.pos_tbl_watch_tx'::regproc) ~ 'not_staff' and pg_get_functiondef('public.pos_tbl_watch_tx'::regproc) ~ 'has_store_access')
       then '① ✅ 版本數 1、DEFINER、店員與門市檢查都在'
       else '① 🔴 函式不對' end,
  case when (select pg_get_functiondef('public.pos_tbl_watch_tx'::regproc) ~ 'd\.kind = ''phone''')
       then '② ✅ 會撈綁在玩家身上的手機'
       else '② 🔴 沒有撈手機' end,
  coalesce((select '③ ℹ A1：平板 ' || count(*) filter (where not phone) || ' 台、綁著人的手機 ' || count(*) filter (where phone) || ' 支 → 畫 '
                   || string_agg(label || case when phone then '（手機）' else '' end, '、' order by phone, label)
                        filter (where bound or n <= 4 or k <= greatest(4 - nb, 0))
              from ranked), '③ ⚪ 找不到 A1')
) as "驗證";
