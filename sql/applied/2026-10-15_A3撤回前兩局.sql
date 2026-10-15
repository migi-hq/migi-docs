-- ════════════════════════════════════════════════════════════════════
-- 2026-10-15 A3（MIGI 高雄自由店）按錯了：回到第一局、沒扣分的狀態（使用者）
--
-- 那一場：39d6ea66-847a-40f8-ac3d-f32e85878051（23:44 開、約 3 將、第 1 將進行中）
--   座位 1 宋智仁、2 🐰🎀、3 哈那、4 昱
-- 已經記了兩局，都撤掉：
--   第 1 局  座位 2 胡、座位 4 放槍  ±180   b8f193ac-739f-49dc-90df-7df1cc0295a1
--   第 2 局  座位 4 胡、座位 2 放槍  ±180   64dd37c2-2d87-45e0-8c69-f0e779a82f87
-- 做法跟計分板自己的「撤銷上一局」（tbl_undo_last_tx）一樣：status → undone、記 undone_at，
-- 撤銷的局不算分；莊家、局數照「已確認的局」重算 ⇒ 回到第 1 將第 1 局、四家都是起始積分。
-- 沒有爆卡、沒有加時間，不用另外處理。
--
-- 🔒 保險：如果這段時間又多打了一局（或有一局在等確認），**整份不動**，只回報現況 ——
--   不可以把新打的那一局一起抹掉
-- ════════════════════════════════════════════════════════════════════
do $$
declare v_other int; v_n int;
begin
  select count(*) into v_other from hands
   where session_id = '39d6ea66-847a-40f8-ac3d-f32e85878051'
     and status in ('confirmed', 'pending')
     and id not in ('b8f193ac-739f-49dc-90df-7df1cc0295a1', '64dd37c2-2d87-45e0-8c69-f0e779a82f87');
  if v_other > 0 then
    perform set_config('migi.a3', '⚠ 沒有動：這段時間 A3 又多了 ' || v_other || ' 局（已確認或等確認中），請先跟我說', true);
  else
    update hands set status = 'undone', undone_at = now()
     where session_id = '39d6ea66-847a-40f8-ac3d-f32e85878051'
       and id in ('b8f193ac-739f-49dc-90df-7df1cc0295a1', '64dd37c2-2d87-45e0-8c69-f0e779a82f87')
       and status = 'confirmed';
    get diagnostics v_n = row_count;
    perform public._tbl_ping('39d6ea66-847a-40f8-ac3d-f32e85878051');   -- 四台平板立刻重讀，不用等
    perform set_config('migi.a3', '撤掉 ' || v_n || ' 局', true);
  end if;
end $$;

-- ════════════ 驗證（單一 SELECT）════════════
select current_setting('migi.a3', true) || E'\n' ||
       case when (select count(*) from hands where session_id = '39d6ea66-847a-40f8-ac3d-f32e85878051' and status in ('confirmed', 'pending')) = 0
            then '✅ A3 這一場已經沒有任何算分的局 ⇒ 回到第 1 將第 1 局、四家都是起始積分'
            else '🔴 A3 還有 ' || (select count(*) from hands where session_id = '39d6ea66-847a-40f8-ac3d-f32e85878051' and status in ('confirmed', 'pending')) || ' 局算分' end
       || E'\n' ||
       case when (select status from session_rounds where id = '6b1a4c72-de33-414f-9215-6d206f10c65d') = 'playing'
            then '✅ 第 1 將仍是進行中' else '🔴 第 1 將狀態不對' end
       || E'\n' ||
       case when (select status from table_sessions where id = '39d6ea66-847a-40f8-ac3d-f32e85878051') = 'open'
            then '✅ 這一場還開著（沒有收桌、沒有結算）' else '🔴 這一場狀態不對' end
       as "驗證";
