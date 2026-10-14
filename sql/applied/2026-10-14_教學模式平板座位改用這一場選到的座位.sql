-- ============================================================
-- 2026-10-14 教學模式：平板的座位改用「這一場選到的座位」（不再一律用編號尾數）
-- ------------------------------------------------------------
-- 使用者回報：「A1 手機選教學模式，A1 平板沒同步；手機選自摸，平板也沒反應」
--
-- 原因（10-14 查線上）：A1 那一場的座位 ——
--   座位 1 ＝ 平板 A1-2、座位 2／3／4 ＝ 三支手機
-- 而 _tbl_practice_cfg 對平板**一律用編號尾數**當教學座位 ⇒ A1-2 扮演座位 2，跟坐座位 2 的手機撞在一起。
-- 手機先按「教學模式」當主持、把座位 2 登記成自己 ⇒ 平板收到後被「同一個座位只認一台」擋下、沒有加入
-- （只跳一則「這個座位已經在另一台計分板上」）⇒ 手機按自摸要等三家確認，平板不在教學裡，當然沒反應。
--
-- 修法（只改這一支，簽名不變 ⇒ CREATE OR REPLACE、授權不動）：
--   · 這台在這一場有座位（平板選了人、手機入座）⇒ 教學就扮演那個座位
--   · 平板在這一場沒有座位（還沒開桌、或開了還沒選人）⇒ 照舊用編號尾數；
--     但開了桌而那個座位已經有人用**別台裝置**在坐 ⇒ 不給座位（不參加教學），免得再撞
--   · 手機沒入座 ⇒ 照舊沒有（它沒有桌）
-- 其餘（頻道、固定玩法、積分、牌型清單）一字不改，照線上版（10-14 撈的 pg_get_functiondef）。
-- ============================================================

CREATE OR REPLACE FUNCTION public._tbl_practice_cfg(p_device table_devices, p_seat smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_seat smallint;
  v_channel text;
  v_stake jsonb;
  v_catalog jsonb;
begin
  /* 座位（2026-10-14 改）：這台在這一場有座位就用那個 —— 平板選了誰、手機坐哪裡；
     平板在這一場沒有座位時才用編號尾數 1～4（還沒開桌也能進教學，2026-10-13）。
     🔴 在此之前平板一律用編號尾數：A1-2 被座位 1 的人用時，教學裡卻扮演座位 2，跟座位 2 的手機撞在一起 */
  v_seat := coalesce(p_seat,
              case when p_device.kind = 'tablet' then (substring(p_device.label from '-([1-4])$'))::smallint end);
  if v_seat is null or p_device.table_id is null then return null; end if;

  /* 用編號尾數的平板：這張桌開著的那一場，那個座位已經有人用別台裝置在坐 ⇒ 這台不參加教學 */
  if p_seat is null and exists (
       select 1
         from session_players sp
         join table_sessions s on s.id = sp.session_id
        where s.table_id = p_device.table_id
          and s.status = 'open' and s.deleted_at is null
          and sp.seat = v_seat
          and sp.device_id is not null and sp.device_id <> p_device.id) then
    return null;
  end if;

  select t.practice_channel into v_channel from tables t where t.id = p_device.table_id;
  if v_channel is null then return null; end if;

  select jsonb_build_object('label', sl.label, 'base', sl.base, 'tai', sl.tai, 'hygiene', sl.is_hygiene,
                            'start_points', sl.start_points)
    into v_stake
    from stake_levels sl
   where sl.org_id = p_device.org_id and sl.is_active and sl.deleted_at is null and not sl.is_hygiene
     and (sl.store_id is null or sl.store_id = p_device.store_id)
   order by (sl.base = 50 and sl.tai = 20) desc, sl.sort_order
   limit 1;

  -- 牌型清單：跟開桌時同一個形狀；有花 ⇒ 全部牌型都列
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', p.code, 'label', p.label, 'tai', p.tai, 'max_count', p.max_count,
           'group', p.group_key, 'result_only', p.result_only, 'dealer_only', p.dealer_only,
           'conflicts', to_jsonb(p.conflicts)) order by p.sort), '[]'::jsonb)
    into v_catalog
    from scoring_patterns p
   where p.is_active;

  return jsonb_build_object(
    'channel', v_channel, 'seat', v_seat,
    'game_type', '台麻', 'flower', '有花', 'planned_rounds', 1,
    'stake', v_stake, 'patterns', v_catalog);
end $function$;

-- ============================================================
-- 驗證（單一 SELECT；不 raise，硬規則 1.8）。樣本現場挑（硬規則 3.57）：
--   ①② 開著的場次裡「有座位的平板」；③ 同一張桌、編號尾數撞到別台裝置座位的平板（A1 那種）；
--   ④ 沒有開著的場次的桌上的平板（正對照：照舊用編號尾數）
-- ============================================================
with tab as (     -- dev 保留 table_devices 的型別，才能直接傳進函式
  select d as dev, d.id, d.table_id, d.label from table_devices d
   where d.kind = 'tablet' and d.is_active and d.revoked_at is null and d.table_id is not null
     and d.label ~ '-[1-4]$'
), seated as (     -- 這一場有座位的平板
  select t.dev, t.label, sp.seat
    from tab t join session_players sp on sp.device_id = t.id
    join table_sessions s on s.id = sp.session_id and s.status = 'open' and s.deleted_at is null
   limit 1
), clash as (      -- 編號尾數那個座位被別台裝置坐走、自己在這一場沒有座位的平板
  select t.dev, t.label from tab t
   where not exists (select 1 from session_players sp join table_sessions s on s.id = sp.session_id
                      where sp.device_id = t.id and s.status = 'open' and s.deleted_at is null)
     and exists (select 1 from session_players sp join table_sessions s on s.id = sp.session_id
                  where s.table_id = t.table_id and s.status = 'open' and s.deleted_at is null
                    and sp.seat = (substring(t.label from '-([1-4])$'))::smallint
                    and sp.device_id is not null and sp.device_id <> t.id)
   limit 1
), idle as (       -- 桌上沒有開著的場次
  select t.dev, t.label from tab t
   where not exists (select 1 from table_sessions s where s.table_id = t.table_id and s.status = 'open' and s.deleted_at is null)
   limit 1
)
select
  coalesce((select case when (public._tbl_practice_cfg(dev, seat) ->> 'seat')::int = seat
                        then '✅ ① 有座位的平板教學扮演自己的座位（' || label || ' → ' || seat || '）'
                        else '🔴 ① ' || label || ' 座位 ' || seat || '，教學卻是 ' || coalesce(public._tbl_practice_cfg(dev, seat) ->> 'seat', 'null') end
              from seated), '⚪ ① 現在沒有選了人的平板') as "①",
  coalesce((select case when public._tbl_practice_cfg(dev, null) is null
                        then '✅ ② ' || label || ' 編號尾數的座位被別台坐了 ⇒ 不參加教學'
                        else '🔴 ② ' || label || ' 仍然拿到座位 ' || (public._tbl_practice_cfg(dev, null) ->> 'seat') end
              from clash), '⚪ ② 現在沒有撞座位的平板') as "②",
  coalesce((select case when (public._tbl_practice_cfg(dev, null) ->> 'seat')::int = (substring(label from '-([1-4])$'))::int
                        then '✅ ③ 沒開桌的平板照舊用編號尾數（' || label || '）'
                        else '🔴 ③ ' || label || ' 拿到 ' || coalesce(public._tbl_practice_cfg(dev, null) ->> 'seat', 'null') end
              from idle), '⚪ ③ 每張桌都開著') as "③",
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = '_tbl_practice_cfg') = 1
       then '✅' else '🔴' end || ' ④ 只有一個版本' as "④";
