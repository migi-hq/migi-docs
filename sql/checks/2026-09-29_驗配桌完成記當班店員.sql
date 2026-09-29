-- 2026-09-29 驗配桌完成記當班店員（跑在 2026-09-29_配桌完成記當班店員.sql 之後）
-- ⚠ 交易內用真的店員身分（有 auth_uid 的總部／老闆）叫兩支 POS 函式、造配桌、改狀態，
--   最後 raise 'migi_rollback' 整個退掉 —— 門市的當班、配桌一列都不會留下。
-- ⚠ 訊息設在 exception 處理器裡（硬規則 3.9）；找不到樣本會出聲，不安靜跳過（硬規則 3.57）。

do $$
declare
  v_org uuid; v_store uuid; v_store2 uuid; v_stake uuid; v_staff uuid; v_auth uuid; v_other uuid;
  v_q uuid; v_q2 uuid; r jsonb; v uuid; v_since timestamptz; v_msg text := ''; v_n int;
  ok text := '✅ '; bad text := '🔴 ';
begin
  select id, auth_uid, org_id into v_staff, v_auth, v_org from staff
   where auth_uid is not null and deleted_at is null and role in ('hq', 'owner') limit 1;
  if v_staff is null then perform set_config('migi.t', '⚪ 找不到有登入身分的總部／老闆，這份測不了', false); return; end if;
  select id into v_store  from stores where org_id = v_org and is_test and deleted_at is null order by code limit 1;
  select id into v_store2 from stores where org_id = v_org and is_test and deleted_at is null and id <> v_store order by code limit 1;
  select id into v_stake  from stake_levels where deleted_at is null limit 1;
  if v_store is null or v_store2 is null or v_stake is null then
    perform set_config('migi.t', '⚪ 找不到兩間測試門市或積分級距，這份測不了', false); return;
  end if;
  select id into v_other from staff where deleted_at is null and id <> v_staff limit 1;

  -- 先把兩間測試店的當班清空，每一格從乾淨的前提開始（硬規則 3.57）
  update stores set on_duty_staff_id = null, on_duty_since = null where id in (v_store, v_store2);

  -- ── ① 沒有店員身分 ⇒ 被拒 ──
  perform set_config('request.jwt.claims', '', true);
  r := public.pos_set_on_duty_tx(v_store);
  v_msg := v_msg || (case when r ->> 'reason' = 'not_staff_of_store' then ok else bad end)
           || '① 沒有店員身分叫不動：' || coalesce(r ->> 'reason', r::text) || E'\n';

  -- ── ② 用店員身分登入這間店 ──
  perform set_config('request.jwt.claims', json_build_object('sub', v_auth::text, 'role', 'authenticated')::text, true);
  r := public.pos_set_on_duty_tx(v_store);
  select on_duty_staff_id, on_duty_since into v, v_since from stores where id = v_store;
  v_msg := v_msg || (case when (r ->> 'ok')::boolean and v = v_staff and v_since is not null then ok else bad end)
           || '② 登入後這間店的當班 ＝ 我' || E'\n';

  -- ③ 再叫一次（POS 每次開機都會叫）不會讓當班起點往後跳
  --    ⚠ 交易內 now() 永遠同一個值 ⇒ 不先把起點撥回去的話，函式有沒有改它都一樣，這一格會永遠綠
  update stores set on_duty_since = now() - interval '3 hours' where id = v_store;
  r := public.pos_set_on_duty_tx(v_store);
  v_msg := v_msg || (case when (select on_duty_since from stores where id = v_store) = now() - interval '3 hours' then ok else bad end)
           || '③ 重複叫不改當班起點' || E'\n';

  -- ── ④ 配桌湊滿那一刻 ⇒ 記下當班的我 ──
  -- ⚠ 玩法一定要明確填：欄位預設值是「16張」，而 match_queues_game_type_chk 只允許 台麻／美麻
  --   （NOT VALID 只放過舊資料，新的一列照擋）—— 第一次跑就是撞在這裡（硬規則 3.8.5：值從約束查，不猜）
  insert into match_queues (org_id, store_id, stake_level_id, play_at, status, game_type, flower)
  values (v_org, v_store, v_stake, now() + interval '2 hours', 'waiting', '台麻', '無花') returning id into v_q;
  update match_queues set status = 'matched', matched_at = now() where id = v_q;
  select credited_staff_id into v from match_queues where id = v_q;
  v_msg := v_msg || (case when v = v_staff then ok else bad end) || '④ 湊滿那一刻記下當班店員' || E'\n';

  -- ⑤ 帶桌 → 取消開桌退回 matched（人還夠）⇒ 不動
  update match_queues set status = 'seated' where id = v_q;
  update match_queues set status = 'matched' where id = v_q;
  select credited_staff_id into v from match_queues where id = v_q;
  v_msg := v_msg || (case when v = v_staff then ok else bad end) || '⑤ seated → matched 不改歸屬' || E'\n';

  -- ⑥ 退回 waiting ⇒ 清掉；下次湊滿再記
  update match_queues set status = 'waiting', matched_at = null where id = v_q;
  select credited_staff_id into v from match_queues where id = v_q;
  v_msg := v_msg || (case when v is null then ok else bad end) || '⑥ 退回 waiting 清掉歸屬' || E'\n';

  -- ⑦ 換到另一間店當班 ⇒ 原本那間自動清掉（一個人一次只在一間店）
  r := public.pos_set_on_duty_tx(v_store2);
  v_msg := v_msg || (case when (select on_duty_staff_id from stores where id = v_store) is null
                          and (select on_duty_staff_id from stores where id = v_store2) = v_staff then ok else bad end)
           || '⑦ 換店當班：原本那間清掉、新那間是我' || E'\n';

  -- ⑧ 原本那間現在沒人當班 ⇒ 再湊滿記成 null（算不到任何人，看得出來）
  update match_queues set status = 'matched', matched_at = now() where id = v_q;
  select credited_staff_id into v from match_queues where id = v_q;
  v_msg := v_msg || (case when v is null then ok else bad end) || '⑧ 那一刻沒人當班 ⇒ 記成 null' || E'\n';

  -- ⑨ 交班登出 ⇒ 清掉自己
  r := public.pos_clear_on_duty_tx();
  v_msg := v_msg || (case when (r ->> 'cleared')::int = 1 and (select on_duty_staff_id from stores where id = v_store2) is null then ok else bad end)
           || '⑨ 交班登出清掉自己的當班' || E'\n';

  -- ⑩ 🔴 負對照：下一位已經先登入了，上一位登出不可以把他清掉
  if v_other is null then
    v_msg := v_msg || '⚪ ⑩ 只有一位店員，測不了「登出只清自己」' || E'\n';
  else
    update stores set on_duty_staff_id = v_other, on_duty_since = now() where id = v_store;
    r := public.pos_clear_on_duty_tx();
    v_msg := v_msg || (case when (select on_duty_staff_id from stores where id = v_store) = v_other then ok else bad end)
             || '⑩ 負對照：登出不會清掉別人的當班' || E'\n';
    -- 而那一刻湊滿的配桌算給他
    insert into match_queues (org_id, store_id, stake_level_id, play_at, status, game_type, flower)
    values (v_org, v_store, v_stake, now() + interval '2 hours', 'waiting', '台麻', '無花') returning id into v_q2;
    update match_queues set status = 'matched', matched_at = now() where id = v_q2;
    v_msg := v_msg || (case when (select credited_staff_id from match_queues where id = v_q2) = v_other then ok else bad end)
             || '⑩-1 換人當班後湊滿的配桌算給新的那位' || E'\n';
  end if;

  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.t', v_msg, false);
  else
    perform set_config('migi.t', '🔴 中途失敗：' || sqlerrm || E'\n已經跑完的：\n' || coalesce(v_msg, ''), false);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有訊息') as "驗證";
