/* ═══════════════════════════════════════════════════════════════════
   驗：前端塞不進點心了，而餵食仍然扣得動
   2026-09-19 · 搭配 sql/applied/2026-09-19_點心改由後端說了算.sql
   ═══════════════════════════════════════════════════════════════════

   🔴 會寫入，跑完整份回滾。訊息只存變數，等 exception 處理器才 set_config
     （硬規則 3.9 —— 同一天已經踩過一次）。

   ⚠ 每一道牆都配正對照（硬規則 3.55）：
     擋住前端寫點心 ＋ **小熊等級與名字仍然存得進去**；
     餘額不足擋下 ＋ **餘額夠的時候真的扣得動**。
   ═══════════════════════════════════════════════════════════════════ */

do $$
declare
  v_org   uuid := '11111111-1111-1111-1111-111111111111';
  v_me    uuid;
  v_out   jsonb;
  v_msg   text := '';
  v_n     int;
  v_before int;
  v_bear  jsonb;
begin
  select id into v_me from members where org_id = v_org and is_test and deleted_at is null order by created_at limit 1;
  if v_me is null then
    v_msg := '⚪ 取不到測試會員 —— 這一份測不了，不要當成通過';
    raise exception 'migi_rollback';
  end if;

  select coalesce((bear -> 'snacks' ->> 'cookie')::int, 0) into v_before
    from member_app_state where member_id = v_me;

  /* ── ① 前端塞點心：塞不進去 ──
     模擬前端呼叫（送一個誇張的數字）。 */
  perform public.save_app_state_tx(v_org, v_me,
    jsonb_build_object('lv', 7, 'grow', 42, 'name', '驗證熊',
                       'snacks', jsonb_build_object('cookie', 999)));
  select coalesce((bear -> 'snacks' ->> 'cookie')::int, 0) into v_n
    from member_app_state where member_id = v_me;
  v_msg := case when v_n = v_before
    then '✅ ① 前端送 cookie=999 塞不進去（仍然 ' || v_n || '）'
    else '🔴 ① 被塞進去了：' || v_before || ' → ' || v_n end;

  /* ── ② 正對照：小熊的等級與名字**要存得進去** ──
     🔴 少了這一格，一支「整包拒絕」的實作也會讓 ① 變綠，
       而那會讓客人改不了小熊名字。 */
  select bear into v_bear from member_app_state where member_id = v_me;
  v_msg := v_msg || E'\n' || case
    when (v_bear ->> 'lv') = '7' and (v_bear ->> 'name') = '驗證熊'
    then '✅ ② 等級與名字照樣存得進去（前端說了算的部分沒被波及）'
    else '🔴 ② 連小熊狀態都存不進去了：' || left(coalesce(v_bear::text, 'null'), 100) end;

  /* ── ③ 餘額不足：擋下 ──
     ⚠ 帳本此刻是 0 筆（測試會員的 90 個是舊的前端值，不在帳本裡），
       所以這裡一定不足 —— 這正好也證明了「餘額看帳本不看顯示值」。 */
  v_out := public.consume_snack_tx(v_org, v_me, 'cookie', 1);
  v_msg := v_msg || E'\n' || case
    when coalesce((v_out->>'ok')::boolean, true) = false and v_out->>'reason' = 'insufficient'
    then '✅ ③ 帳本沒有餘額時餵食被擋（顯示值 ' || v_before || ' 個也沒用）'
    else '🔴 ③ 沒擋住：' || left(v_out::text, 120) end;

  /* ── ④ 正對照：先發再餵，扣得動 ── */
  perform public.grant_snack_tx(v_org, v_me, 'cookie', 3, 'admin', null, 'verify:' || v_me::text);
  v_out := public.consume_snack_tx(v_org, v_me, 'cookie', 2);
  v_msg := v_msg || E'\n' || case
    when coalesce((v_out->>'ok')::boolean, false) and (v_out->>'spent')::boolean
     and (v_out->>'total')::int = 1
    then '✅ ④ 發 3 個、餵掉 2 個，帳本餘額剩 1'
    else '🔴 ④ 扣不動或數字不對：' || left(v_out::text, 140) end;

  /* ── ⑤ 顯示值跟著動（前端讀的是 bear.snacks）── */
  select coalesce((bear -> 'snacks' ->> 'cookie')::int, 0) into v_n
    from member_app_state where member_id = v_me;
  v_msg := v_msg || E'\n' || case when v_n = v_before + 3 - 2
    then '✅ ⑤ 顯示值跟著加減（' || v_before || ' → ' || v_n || '）'
    else '🔴 ⑤ 顯示值沒跟上：預期 ' || (v_before + 1) || '，實際 ' || v_n end;

  /* ── ⑥ 餵食之後前端再存一次檔，**不可以把點心覆蓋回去** ──
     🎯 這是最容易漏的一格：前端的 600ms debounce 會在餵完之後存檔，
       而它手上那份 snacks 是舊的。 */
  perform public.save_app_state_tx(v_org, v_me,
    jsonb_build_object('lv', 7, 'grow', 52, 'snacks', jsonb_build_object('cookie', v_before + 3)));
  select coalesce((bear -> 'snacks' ->> 'cookie')::int, 0) into v_n
    from member_app_state where member_id = v_me;
  v_msg := v_msg || E'\n' || case when v_n = v_before + 1
    then '✅ ⑥ 餵完之後前端存檔沒有把點心覆蓋回去（仍然 ' || v_n || '）'
    else '🔴 ⑥ 被前端的舊值蓋回去了：' || v_n end;

  /* ── ⑦ 帳本對得起來：sum(qty) = 發放 3 − 消耗 2 ── */
  select coalesce(sum(qty), 0) into v_n from snack_grants where member_id = v_me and kind = 'cookie';
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '✅ ⑦ 帳本 sum(qty) = 1（3 發放 − 2 消耗）'
    else '🔴 ⑦ 帳本對不起來：' || v_n end;

  raise exception 'migi_rollback';

exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.verify_snack_lock_behavior', v_msg, true);
  else
    perform set_config('migi.verify_snack_lock_behavior',
      coalesce(v_msg, '') || E'\n🔴 中途炸了：' || sqlerrm, true);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.verify_snack_lock_behavior', true), ''),
                '🔴 沒有驗證訊息') as "行為驗證（已全部回滾）";
