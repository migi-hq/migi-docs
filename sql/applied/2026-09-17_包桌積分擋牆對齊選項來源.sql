/* ═══════════════════════════════════════════════════════════════════
   包桌預約：積分級距的擋牆對齊「選項是怎麼來的」
   2026-09-17 · 使用者實機回報「那個積分級距不屬於這間門市」
   ═══════════════════════════════════════════════════════════════════

   🔴 **這是 2026-09-16 我自己加的擋牆造成的 regression，
     而它讓包桌從那一刻起就訂不出來。**

   兩支函式對「這個級距屬不屬於這間門市」用了**不同的判準**：

     list_stakes_tx      store_id = p_store  OR  store_id is null   ← 給選項
     create_booking_tx   store_id = p_store_id                       ← 檢查

   而線上**七個級距全部是 `store_id is null`（全連鎖）** ——
   純娛樂 / 10-10 / 30-10 / 50-20 / 100-20 / 200-50 / 300-100。
   ⇒ 選單上列出的每一個都**必定**被擋下。
   ⇒ 而前端的 `blocked` 是「有級距可選就必須選一個」
     ⇒ **包桌預約整個功能不可用**，而畫面只說「那個積分級距不屬於這間門市」。

   🎯 **教訓不是「條件寫錯」，是「選項與擋牆各寫一份判準」。**
     擋牆存在的目的是「前端換了門市卻沒重選級距」——
     那個目的完全成立，錯的是它沒有照抄 `list_stakes_tx` 的定義。
     這個專案記過很多次的同一族：**一件事兩份定義，寫下去的當下就是兩份。**

   ✅ 修法：擋牆用**與選項來源逐字相同**的條件。
   ✅ 順帶補上 `org_id` —— 舊版**完全沒驗 org**，
     也就是拿另一個 org 的級距 id 送進來會通過。
     今天只有一個 org 所以踩不到，**那是運氣不是設計**。

   ⚠ 簽名不變 ⇒ `CREATE OR REPLACE` ⇒ 不用 DROP、不會丟 GRANT（硬規則 2）。
   ⚠ 這份要留下 DDL ⇒ **驗證段一個字都不准 `raise`**（硬規則 1.8）。
     行為測試（要造樣本、要回滾）在另一份：
     `sql/checks/2026-09-17_驗包桌積分擋牆.sql`
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.create_booking_tx(
  p_store_id uuid,
  p_play_at timestamp with time zone,
  p_hours integer,
  p_table_count integer default 1,
  p_team_id uuid default null::uuid,
  p_party_size integer default null::integer,
  p_note text default null::text,
  p_game_type text default null::text,
  p_flower text default null::text,
  p_stake_level_id uuid default null::uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_me    uuid := public.current_member_id();
  v_org   uuid := public.current_org_id();
  v_cap   jsonb;
  v_id    uuid;
  v_name  text;
  v_tbl   uuid;
  v_label text;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_hours not in (2, 5, 24) then
    return jsonb_build_object('ok', false, 'reason', 'bad_hours', 'message', '時長只能選 2、5 或 24 小時');
  end if;
  if coalesce(p_table_count, 1) < 1 or p_table_count > 10 then
    return jsonb_build_object('ok', false, 'reason', 'bad_count', 'message', '桌數請填 1 到 10');
  end if;
  /* ⚠ 兩個新值照 `match_queues` 的允許值擋，訊息講人話不講欄位名。 */
  if p_game_type is not null and p_game_type not in ('台麻', '美麻') then
    return jsonb_build_object('ok', false, 'reason', 'bad_game_type', 'message', '牌規只能選台麻或美麻');
  end if;
  if p_flower is not null and p_flower not in ('無花', '有花') then
    return jsonb_build_object('ok', false, 'reason', 'bad_flower', 'message', '花牌只能選無花或有花');
  end if;

  /* 🔴 兩道時間牆，兩個不同的理由：
     · 太近 —— 店員來不及看到那筆預約，客人到了櫃檯還是要現場處理，
       而畫面已經跟他說「預約成功」了。**那是一個做不到的承諾。**
     · 太遠 —— 三個月後的事誰都說不準，而它會一路佔著容量。 */
  if p_play_at is null or p_play_at < now() + interval '30 minutes' then
    return jsonb_build_object('ok', false, 'reason', 'too_soon',
                              'message', '請至少提前 30 分鐘預約，現在要用請直接到櫃檯');
  end if;
  if p_play_at > now() + interval '90 days' then
    return jsonb_build_object('ok', false, 'reason', 'too_far', 'message', '最多只能預約 90 天內');
  end if;

  select s.name into v_name from public.stores s
   where s.id = p_store_id and s.org_id = v_org and s.deleted_at is null;
  if v_name is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_store', 'message', '找不到那間門市');
  end if;

  /* 🔴 **2026-09-17：條件對齊 `list_stakes_tx`（選單是那一支給的）。**
     舊版只認 `store_id = p_store_id`，而那一支**同時放行全連鎖的級距**
     （`store_id is null`）—— 線上七個級距全都是那一種
     ⇒ 選單上每一個都必定被擋，包桌整個訂不出來。

     ⚠ 這道牆本身是對的、要留著：它擋的是「換了門市卻沒重選級距」。
       錯的是它沒有照抄選項的定義。
     🎯 **判準一句話：擋牆要跟「這個選項是怎麼來的」用同一個條件。**
       兩邊各寫一份，寫下去的當下就是兩份。

     ✅ 順帶補 `org_id` —— 舊版完全沒驗，
       拿另一個 org 的級距 id 送進來會通過。今天只有一個 org
       所以踩不到，那是運氣不是設計。
     ⚠ 也補上 `is_active` 與 `deleted_at` —— 同樣是照抄那一支：
       停用的級距不該出現在選單上，也不該訂得出來。 */
  if p_stake_level_id is not null and not exists (
       select 1 from public.stake_levels sl
        where sl.id = p_stake_level_id
          and sl.org_id = v_org
          and sl.is_active = true
          and sl.deleted_at is null
          and (sl.store_id = p_store_id or sl.store_id is null)) then
    return jsonb_build_object('ok', false, 'reason', 'bad_stake',
                              'message', '那個積分級距不能用在這間門市');
  end if;

  /* 掛團的話，**我必須在那個團裡** —— 不然任何人都能用別人的團名訂位，
     而帳算在那個團頭上。 */
  if p_team_id is not null and not exists (
       select 1 from public.team_members tm
        join public.teams t on t.id = tm.team_id and t.deleted_at is null
       where tm.team_id = p_team_id and tm.member_id = v_me and tm.left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'not_member', 'message', '你不在那個牌咖團裡');
  end if;

  perform public._booking_expire(p_store_id);

  /* 🔴 同一組人同一個時段不要重複訂。
     判準是「同一個團」，沒有團就退回「同一個人」——
     而那正是 `team_id` 可空所帶來的兩種身分。 */
  if exists (
       select 1 from public.bookings k
        where k.store_id = p_store_id and k.status = 'booked'
          and (case when p_team_id is not null then k.team_id = p_team_id
                    else k.team_id is null and k.member_id = v_me end)
          and p_play_at < k.play_at + make_interval(hours => k.planned_hours)
          and k.play_at < p_play_at + make_interval(hours => p_hours)) then
    return jsonb_build_object('ok', false, 'reason', 'already_booked',
                              'message', '這個時段你已經有一筆預約了');
  end if;

  v_cap := public._booking_capacity(p_store_id, p_play_at, p_hours);
  if (v_cap->>'free')::int < p_table_count then
    return jsonb_build_object('ok', false, 'reason', 'no_capacity',
                              'message', '這個時段已經約滿了，換個時間試試');
  end if;

  /* 🔴 **訂的當下就配桌**（使用者 2026-09-16）。
     ⚠ 只有一桌才配 —— `bookings` 只有一個 `table_id` 欄位（見檔頭）。
     ⚠ 容量剛才已經確認夠了，所以正常情況一定挑得到；
       挑不到只會發生在「那一瞬間被別人拿走」，那時**不要失敗**，
       留 null 就好 —— 客人的預約仍然成立，桌號當天再安排。
       🎯 為了一個顯示用的欄位讓整筆預約失敗，是把次要的事當成主要的。 */
  if coalesce(p_table_count, 1) = 1 then
    v_tbl := public._booking_pick_table(p_store_id, p_play_at, p_hours);
  end if;

  insert into public.bookings (org_id, store_id, team_id, member_id,
                               play_at, planned_hours, table_count, party_size, note,
                               table_id, game_type, flower, stake_level_id)
  values (v_org, p_store_id, p_team_id, v_me,
          p_play_at, p_hours, coalesce(p_table_count, 1), p_party_size,
          nullif(btrim(coalesce(p_note, '')), ''),
          v_tbl, p_game_type, p_flower, p_stake_level_id)
  returning id into v_id;

  select tb.label into v_label from public.tables tb where tb.id = v_tbl;

  return jsonb_build_object('ok', true, 'booking_id', v_id, 'store_name', v_name,
                            'table_label', v_label,
                            'message', '已預約 ' || v_name);
end $function$;


/* ═══ 驗證段（不 raise，訊息走 set_config → 最後一支 SELECT）═══ */
do $$
declare
  v_msg  text := '';
  v_def  text;
  v_n    int;
  v_null int;
  v_ok   boolean;
begin
  /* ① 只有一個版本、是 DEFINER、search_path 有設 */
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'create_booking_tx';
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'create_booking_tx'
     and p.prokind = 'f' limit 1;
  v_msg := v_msg || case when v_n = 1 and v_def ilike '%security definer%'
                              and v_def ilike '%search_path%'
                         then '✅ ① 版本數 1 · DEFINER · search_path 有設'
                         else '🔴 ① 版本數 ' || v_n || '（或缺 DEFINER／search_path）' end;

  /* ② 新條件在裡面：同時認「這間店的」與「全連鎖的」
     ⚠ 掃的是**會產生行為的那一段**，不是中文說明（硬規則 3.5）。 */
  v_msg := v_msg || E'\n' || case
    when v_def ilike '%sl.store_id = p_store_id or sl.store_id is null%'
    then '✅ ② 擋牆已認全連鎖級距（與選單同一個條件）'
    else '🔴 ② 擋牆還是只認 store_id = p_store_id' end;

  /* ③ org 與停用也一起驗了 */
  v_msg := v_msg || E'\n' || case
    when v_def ilike '%sl.org_id = v_org%' and v_def ilike '%sl.is_active = true%'
    then '✅ ③ 順帶補上 org 與 is_active'
    else '🔴 ③ 少了 org 或 is_active' end;

  /* ④ 這次的起因：線上有幾個級距、其中幾個是全連鎖的
     🎯 這一格是**算式**不是期望值（硬規則 3.56）——
       它印出來的數字自己會解釋為什麼舊版一定失敗。 */
  select count(*), count(*) filter (where store_id is null)
    into v_n, v_null
    from public.stake_levels where is_active = true and deleted_at is null;
  v_msg := v_msg || E'\n' || '📌 ④ 線上可用級距 ' || v_n || ' 個，其中 '
                 || v_null || ' 個是全連鎖（store_id is null）'
                 || case when v_null = v_n then ' ← 全部都是，所以舊版每一個都會被擋'
                         else '' end;

  /* ⑤ 正對照（硬規則 3.55）：選項那一支到底回幾個
     —— 只驗「擋牆放行」不夠，要確認**選單真的列得出東西**，
       否則一支回空陣列的實作也會讓其他格變綠。 */
  select jsonb_array_length(public.list_stakes_tx(
           (select id from public.orgs limit 1),
           (select id from public.stores where deleted_at is null order by code limit 1)))
    into v_n;
  v_msg := v_msg || E'\n' || case when v_n > 0
    then '✅ ⑤ 正對照：選單那一支對第一間門市回 ' || v_n || ' 個級距'
    else '🔴 ⑤ 正對照：選單回 0 個 —— 那時客人根本選不到積分' end;

  /* ⑥ 負對照：一個**不存在的** id 仍然要被擋
     ⚠ 只驗「該過的過了」的話，一道**被整個拿掉**的牆也會全綠。 */
  select not exists (
    select 1 from public.stake_levels sl
     where sl.id = '00000000-0000-0000-0000-000000000000'::uuid
       and sl.is_active = true and sl.deleted_at is null)
    into v_ok;
  v_msg := v_msg || E'\n' || case when v_ok
    then '✅ ⑥ 負對照：不存在的級距 id 仍然找不到 ⇒ 照樣會被擋'
    else '🔴 ⑥ 負對照失敗' end;

  /* ⑦ GRANT 沒掉（`CREATE OR REPLACE` 不會丟，但驗一下才知道） */
  select has_function_privilege('authenticated', p.oid, 'execute') into v_ok
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'create_booking_tx'
     and p.prokind = 'f' limit 1;
  v_msg := v_msg || E'\n' || case when v_ok
    then '✅ ⑦ authenticated 仍然叫得動（前端沒被打壞）'
    else '🔴 ⑦ 授權掉了 —— 前端會 404' end;

  perform set_config('migi.verify_booking_stake', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify_booking_stake', true), ''),
                '🔴 沒有驗證訊息') as "驗證";
