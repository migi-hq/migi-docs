-- ============================================================
-- 智慧計分板：教學模式改成「一套預設、任何時候都能進」
-- 2026-10-13 · MIGI 咪吉麻將
--
-- 使用者：「還沒開桌前 也放個教學按鈕」→「你就用一個預設共用教學模式 不管開不開桌 任何時間都能點入 用最精簡的方式寫」
--
-- 教學模式本身一筆都不寫資料庫（牌局在主持那台平板的記憶體裡，四位玩家固定「教學帳號01～04」）。
-- 原本它借「這一場」的三樣東西，所以沒開桌就進不去；這一份改成不借：
--   ① 頻道：每張桌一個固定的教學頻道 tables.practice_channel（隨機產生，猜不到）
--   ② 座位：平板用編號尾數（A1-1 → 1 … A1-4 → 4）；客人的手機用它選到的座位（沒入座就沒有）
--   ③ 玩法與積分：固定 台麻・有花（全部牌型都看得到）・1 將・50/20（找不到就用排序最前面的非純娛樂級距）
-- 後端只負責把這三樣交給平板：狀態裡多一個 practice_cfg（有開桌、沒開桌都有）。
--
-- 做法：_tbl_state_for_device 很長，**不整支重寫** —— 只在兩個 return 各插一行 practice_cfg。
--   替換用那兩處的完整原文；任一處對不上（線上被改過）就整份回滾，不會改到一半。
--   ⚠ 鍵名刻意不叫 practice：前端已經用 data.practice 當「現在是教學模式」的旗標。
-- ============================================================

-- ① 每張桌一個固定的教學頻道
alter table public.tables add column if not exists practice_channel text not null
  default ('practice-' || replace(gen_random_uuid()::text, '-', ''));

-- ②③ 教學模式的固定設定
create or replace function public._tbl_practice_cfg(p_device public.table_devices, p_seat smallint)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_seat smallint;
  v_channel text;
  v_stake jsonb;
  v_catalog jsonb;
begin
  -- 座位：平板看編號尾數 1～4；手機看它在這一場選到的座位
  v_seat := case when p_device.kind = 'tablet' then (substring(p_device.label from '-([1-4])$'))::smallint
                 else p_seat end;
  if v_seat is null or p_device.table_id is null then return null; end if;

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

revoke execute on function public._tbl_practice_cfg(public.table_devices, smallint) from public;
revoke execute on function public._tbl_practice_cfg(public.table_devices, smallint) from anon, authenticated;

-- _tbl_state_for_device 的兩個 return 各插一行 practice_cfg
do $$
declare
  v_def text := replace(pg_get_functiondef('public._tbl_state_for_device'::regproc), E'\r\n', E'\n');   -- 線上存的換行是 \r\n，比對前先統一
  -- 沒開桌那一個
  v_old1 text := $o$      'session', null);$o$;
  v_new1 text := $n$      'session', null,
      'practice_cfg', public._tbl_practice_cfg(d, null));   -- 🎓 教學模式的固定設定（2026-10-13）$n$;
  -- 有開桌那一個（插在包桌續時那一行前面；那一行後面還接著它自己的註解，不要動到）
  v_old2 text := $o$    'pkg', public._pkg_time(s.id, false),$o$;
  v_new2 text := $n$    'practice_cfg', public._tbl_practice_cfg(d, v_my_seat),   -- 🎓 教學模式的固定設定（2026-10-13）
    'pkg', public._pkg_time(s.id, false),$n$;
begin
  -- 守衛：兩處都要剛好一處，否則整份不執行（寧可回滾也不要改到一半）
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 then
    raise exception '_tbl_state_for_device 的兩個 return 對不上，整份不執行';
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end $$;


-- ============================================================
-- 驗證（單一 SELECT，不 raise —— 硬規則 1.8）
--   ① 每張桌都有教學頻道，而且互不相同
--   ② _tbl_state_for_device 版本數 1、兩個 return 都帶 practice_cfg
--   ③ 新函式前端叫不到（只有內部用）
--   ④ 拿線上一台編號 -1～-4 結尾的平板試：座位 = 尾數、積分有值、牌型有值
--   ⑤ 負對照：編號不是 -1～-4 結尾 → 不給；手機沒入座（座位 null）→ 不給
-- ============================================================
with tab as (
  select d from table_devices d
   where d.kind = 'tablet' and d.label ~ '-[1-4]$' and d.table_id is not null
   order by d.label limit 1
), r as (
  select (tab.d).label as label, public._tbl_practice_cfg(tab.d, null) as j from tab
)
select concat_ws(E'\n',
  case when (select count(*) = count(distinct practice_channel) and bool_and(practice_channel like 'practice-%') from tables)
       then '① ✅ 每張桌都有自己的教學頻道（' || (select count(*) from tables) || ' 張）'
       else '① 🔴 教學頻道有缺或重複' end,
  case when (select count(*) from pg_proc where proname = '_tbl_state_for_device' and pronamespace = 'public'::regnamespace) = 1
        and (select (length(x) - length(replace(x, '''practice_cfg'', public._tbl_practice_cfg(d, ', ''))) /
                    length('''practice_cfg'', public._tbl_practice_cfg(d, ')
               from (select pg_get_functiondef('public._tbl_state_for_device'::regproc) as x) y) = 2
       then '② ✅ 有開桌、沒開桌兩個回傳都帶 practice_cfg'
       else '② 🔴 _tbl_state_for_device 沒改到（或不是兩處）' end,
  case when not has_function_privilege('anon', 'public._tbl_practice_cfg(public.table_devices, smallint)', 'execute')
        and not has_function_privilege('authenticated', 'public._tbl_practice_cfg(public.table_devices, smallint)', 'execute')
       then '③ ✅ 前端叫不到 _tbl_practice_cfg'
       else '③ 🔴 _tbl_practice_cfg 前端叫得到' end,
  coalesce((select case
      when (j ->> 'seat')::int = (substring(label from '-([1-4])$'))::int
       and j -> 'stake' ->> 'label' is not null
       and jsonb_array_length(j -> 'patterns') > 0
       and j ->> 'channel' like 'practice-%'
      then '④ ✅ ' || label || '：座位 ' || (j ->> 'seat') || '、積分 ' || (j -> 'stake' ->> 'label')
           || '、牌型 ' || jsonb_array_length(j -> 'patterns') || ' 個'
      else '④ 🔴 ' || label || ' 拿到的不對：' || left(coalesce(j::text, 'null'), 200) end
    from r), '④ ⚪ 線上沒有編號 -1～-4 結尾的平板，這一格測不了'),
  coalesce((select case
      when public._tbl_practice_cfg(jsonb_populate_record(t.d, jsonb_build_object('label', 'X-9')), null) is null
       and public._tbl_practice_cfg(jsonb_populate_record(t.d, jsonb_build_object('kind', 'phone')), null) is null
       and public._tbl_practice_cfg(jsonb_populate_record(t.d, jsonb_build_object('kind', 'phone')), 2::smallint) ->> 'seat' = '2'
      then '⑤ ✅ 負對照：編號不對、手機沒入座 → 不給；手機入座第 2 位 → 座位 2'
      else '⑤ 🔴 負對照不對' end
    from tab t), '⑤ ⚪ 測不了')
) as "驗證";
