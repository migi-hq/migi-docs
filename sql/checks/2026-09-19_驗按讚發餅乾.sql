/* ═══════════════════════════════════════════════════════════════════
   驗：按讚真的會發餅乾、而且刷不動
   2026-09-19 · 搭配 sql/applied/2026-09-19_按讚發小熊餅乾.sql
   ═══════════════════════════════════════════════════════════════════

   🔴 **這份會寫入，然後整份回滾**（結尾 `raise exception 'migi_rollback'`）。
   ⚠ 訊息只存進**變數**，等進到 exception 處理器才 `set_config` ——
     寫在 raise 之前會跟著回滾（硬規則 3.9，2026-09-19 同一天剛踩過一次）。

   ── 這份在問什麼 ────────────────────────────────────
   DDL 那份的驗證段只看得到「函式長什麼樣」。真正要問的是行為：
     · 按一次讚會不會發 1 個
     · **取消再按會不會再發一次**（刷點心最直覺的路）
     · 沒坐過那一桌的人能不能靠送 session_id 換餅乾
     · 前端能不能直接叫發放函式
   ⚠ 每一道牆都配**正對照**（硬規則 3.55：只驗「擋住了」的話，
     一支永遠不發的實作也會全綠）。
   ═══════════════════════════════════════════════════════════════════ */

do $$
declare
  v_org    uuid := '11111111-1111-1111-1111-111111111111';
  v_store  uuid;
  v_table  uuid;
  v_sess   uuid;
  v_me     uuid;
  v_other  uuid;
  v_out    uuid;   -- 沒坐過那一桌的第三人
  v_msg    text := '';
  v_n      int;
  v_cookie int;
begin
  select id into v_store from stores where org_id = v_org order by created_at limit 1;
  select id into v_me    from members where org_id = v_org and is_test and deleted_at is null order by created_at limit 1;
  select id into v_other from members where org_id = v_org and is_test and deleted_at is null and id <> v_me order by created_at limit 1;
  select id into v_out   from members where org_id = v_org and deleted_at is null and id not in (v_me, v_other) limit 1;

  if v_store is null or v_me is null or v_other is null then
    v_msg := '⚪ 取不到樣本 —— 這一份測不了，不要當成通過';
    raise exception 'migi_rollback';
  end if;

  insert into tables (org_id, store_id, label, seats, auto_assign)
  values (v_org, v_store, 'ZZ-餅乾驗證', 4, false) returning id into v_table;

  insert into table_sessions (org_id, store_id, table_id, mode, status, started_at, activated_at)
  values (v_org, v_store, v_table, 'matched', 'open', now() - interval '2 hours', now() - interval '2 hours')
  returning id into v_sess;

  insert into session_players (org_id, session_id, member_id, charged_points, joined_at)
  values (v_org, v_sess, v_me, 100, now()), (v_org, v_sess, v_other, 100, now());

  /* ── ① 按一次讚 → 發 1 個 ───────────────────────── */
  perform public.like_player_tx(v_org, v_me, v_other, true, v_sess);
  select count(*) into v_n from snack_grants
   where member_id = v_me and reason = 'like' and ref_id = v_sess;
  v_msg := case when v_n = 1
    then '✅ ① 按讚發了 1 筆餅乾給按讚的人'
    else '🔴 ① 發放 ' || v_n || ' 筆（應該是 1）' end;

  /* ── ② 顯示值也跟著加（前端讀的是 bear.snacks）── */
  select coalesce((bear -> 'snacks' ->> 'cookie')::int, 0) into v_cookie
    from member_app_state where member_id = v_me;
  v_msg := v_msg || E'\n' || case when v_cookie >= 1
    then '✅ ② bear.snacks.cookie 跟著加了（現在 ' || v_cookie || '）'
    else '🔴 ② 帳本有了但顯示值沒加 —— 客人看不到那個餅乾' end;

  /* ── ③ 🔴 刷點心最直覺的路：取消再按 ──
     ⚠ 這一格是這份存在的主要理由。 */
  perform public.like_player_tx(v_org, v_me, v_other, false, v_sess);
  perform public.like_player_tx(v_org, v_me, v_other, true,  v_sess);
  select count(*) into v_n from snack_grants
   where member_id = v_me and reason = 'like' and ref_id = v_sess;
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '✅ ③ 取消再按**沒有**再發（冪等鍵擋住了，仍然 1 筆）'
    else '🔴 ③ 刷得動 —— 現在 ' || v_n || ' 筆' end;

  /* ── ④ 取消讚不收回（使用者定的規則）── */
  perform public.like_player_tx(v_org, v_me, v_other, false, v_sess);
  select coalesce((bear -> 'snacks' ->> 'cookie')::int, 0) into v_n
    from member_app_state where member_id = v_me;
  v_msg := v_msg || E'\n' || case when v_n = v_cookie
    then '✅ ④ 取消讚沒有收回餅乾（仍然 ' || v_n || '）'
    else '🔴 ④ 被收回了：' || v_cookie || ' → ' || v_n end;

  /* ── ⑤ 擋牆：沒坐過那一桌的人按讚不發 ──
     🔴 不擋的話，任意送一個 session_id 就能換餅乾。 */
  if v_out is null then
    v_msg := v_msg || E'\n⚪ ⑤ 找不到第三個會員，這一格測不了';
  else
    perform public.like_player_tx(v_org, v_out, v_other, true, v_sess);
    select count(*) into v_n from snack_grants where member_id = v_out;
    v_msg := v_msg || E'\n' || case when v_n = 0
      then '✅ ⑤ 沒坐過那一桌的人按讚**不發**餅乾（讚本身照樣成立）'
      else '🔴 ⑤ 刷得動 —— 送一個 session_id 就換到 ' || v_n || ' 筆' end;
  end if;

  /* ── ⑥ 沒有 session 的讚不發（獎勵綁在一場牌局上）── */
  perform public.like_player_tx(v_org, v_me, v_other, true, null);
  select count(*) into v_n from snack_grants where member_id = v_me;
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '✅ ⑥ 沒帶 session 的讚不發餅乾（仍然 1 筆）'
    else '🔴 ⑥ 不帶 session 也發得到 —— 上限規則就沒有意義了' end;

  /* ── ⑦ 正對照：換一個人按讚**要發得出來** ──
     🔴 少了這一格，一支永遠不發的實作會讓 ③⑤⑥ 全部變綠。 */
  perform public.like_player_tx(v_org, v_other, v_me, true, v_sess);
  select count(*) into v_n from snack_grants where member_id = v_other and ref_id = v_sess;
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '✅ ⑦ 另一個人按讚發得出來（擋牆不是全擋）'
    else '🔴 ⑦ 該發的沒發 —— 過度阻擋跟沒擋一樣糟' end;

  /* ── ⑧ 前端叫不動發放函式 ──
     ⚠ 用 `has_function_privilege` 就夠（這裡只問「授權在不在」）。 */
  v_msg := v_msg || E'\n' || case
    when not has_function_privilege('anon', 'public.grant_snack_tx(uuid,uuid,text,int,text,uuid,text)', 'execute')
     and not has_function_privilege('authenticated', 'public.grant_snack_tx(uuid,uuid,text,int,text,uuid,text)', 'execute')
    then '✅ ⑧ 前端（anon／authenticated）叫不動 grant_snack_tx'
    else '🔴 ⑧ 前端叫得動 —— 那就回到「前端說了算」' end;

  raise exception 'migi_rollback';

exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.verify_snack_behavior', v_msg, true);
  else
    perform set_config('migi.verify_snack_behavior',
      coalesce(v_msg, '') || E'\n🔴 中途炸了：' || sqlerrm, true);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.verify_snack_behavior', true), ''),
                '🔴 沒有驗證訊息') as "行為驗證（已全部回滾）";
