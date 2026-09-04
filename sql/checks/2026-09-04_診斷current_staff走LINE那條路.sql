/* ============================================================
   診斷：`current_staff()` 走 LINE 那條路為什麼回不出來
   2026-09-04 · MIGI · 唯讀（只有 select 與 set_config）

   ── 症狀 ──────────────────────────────────────────────
   `2026-09-04_操作者身分改從JWT取.sql` 的驗證段：
   ```
   ① 14 支都改到了                    ✅
   ④ 送假的 staff_id 會被忽略          🔴 變成 null —— 身分沒解析出來
   ⑤ 記到的是解析出來的那個人           🔴 對不到 staff
   ⑥ 沒有 staff 身分 → null，不報錯     ✅
   ```
   ⇒ **插入成功了**（① 證明那一行真的在函式體裡），
     但**執行時 `current_staff()` 回 0 列**。

   🎯 **關鍵線索**：上一份 SQL（堵住換綁與提權）的 ⑦ **是通的**，
     而那次的 claims 是**總部的 `auth_uid`（uuid）** ——
     走的是 `s.auth_uid = migi_jwt_uuid()` 那條路。
     這次用的是 **LINE user id**，走 `m.line_user_id = migi_jwt_line_id()`。
   ⇒ **問題在第二條路，不是在插入。**

   ⚠ 這一支要在 **Dashboard** 跑：MCP 的唯讀 user 叫不動
     `migi_jwt_uuid` / `migi_jwt_line_id`（今天收成只給 authenticated）。
   ============================================================ */

do $$
declare
  v_out text := '';
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_line text; v_mid uuid; v_sid uuid; v_auth uuid; v_r record; v_n int;
begin
  /* ① 取樣：跟那份 SQL 用**完全一樣**的條件。
     🔴 先確認取到的是誰 —— 取樣錯的話後面全部沒有意義
       （上一份的 ⑦⑧ 就是這樣安靜地跳過的）。 */
  select m.line_user_id, m.id, s.id, s.auth_uid
    into v_line, v_mid, v_sid, v_auth
    from members m join staff s on s.member_id = m.id
   where m.line_user_id is not null and s.deleted_at is null and m.deleted_at is null
   limit 1;

  v_out := v_out || E'\n① 取樣到的\t' ||
    coalesce('member=' || (select display_name from members where id = v_mid)
             || '　staff=' || (select name from staff where id = v_sid)
             || '　role=' || (select role from staff where id = v_sid), '🔴 什麼都沒取到');

  v_out := v_out || E'\n② 那列 staff 的 auth_uid\t' ||
    coalesce(v_auth::text, '（null）');
  v_out := v_out || E'\n③ 那個 member 的 line_user_id 長度\t' ||
    coalesce(length(v_line)::text || ' 字元　開頭：' || left(v_line, 3) || '…', '🔴 null');

  ---- 設成那個 LINE 身分 -------------------------------
  perform set_config('request.jwt.claims',
    '{"sub":' || to_json(v_line)::text || '}', true);

  v_out := v_out || E'\n④ auth.jwt() 讀得到嗎\t' ||
    coalesce(left(auth.jwt()::text, 60), '🔴 null —— GUC 沒吃到');
  v_out := v_out || E'\n⑤ auth.jwt() ->> ''sub''\t' ||
    coalesce(left(auth.jwt() ->> 'sub', 20) || '…', '🔴 null');
  v_out := v_out || E'\n⑥ migi_jwt_uuid()（應該是 null）\t' ||
    coalesce(public.migi_jwt_uuid()::text, '✅ null');
  v_out := v_out || E'\n⑦ 🎯 migi_jwt_line_id()（應該等於 ③）\t' ||
    case when public.migi_jwt_line_id() = v_line then '✅ 一樣'
         when public.migi_jwt_line_id() is null then '🔴 null —— 就是這裡斷的'
         else '🔴 不一樣：' || left(public.migi_jwt_line_id(), 20) end;

  ---- ⑧ 手動跑一次 current_staff() 的 where -------------
  /* 🎯 **不呼叫函式，直接跑它的查詢** ——
     那樣可以分辨「函式壞了」與「條件不成立」。 */
  select count(*) into v_n
    from staff s
    left join members m on m.id = s.member_id and m.deleted_at is null
   where s.deleted_at is null
     and (s.auth_uid = public.migi_jwt_uuid()
       or m.line_user_id = public.migi_jwt_line_id());
  v_out := v_out || E'\n⑧ 🎯 手動跑 current_staff() 的條件\t' ||
    v_n || ' 列' || case when v_n = 0 then ' 🔴 條件不成立' else ' ✅' end;

  ---- ⑨ 拆開來看是哪一條不成立 -------------------------
  select count(*) into v_n from staff s
   where s.deleted_at is null and s.auth_uid = public.migi_jwt_uuid();
  v_out := v_out || E'\n⑨ 　└ 只看 auth_uid 那條\t' || v_n || ' 列（LINE 身分下本來就該是 0）';

  select count(*) into v_n
    from staff s join members m on m.id = s.member_id and m.deleted_at is null
   where s.deleted_at is null and m.line_user_id = public.migi_jwt_line_id();
  v_out := v_out || E'\n⑩ 🎯 　└ 只看 line_user_id 那條\t' ||
    v_n || ' 列' || case when v_n = 0 then ' 🔴 **問題在這裡**' else ' ✅' end;

  ---- ⑪ 真的呼叫函式 -----------------------------------
  select * into v_r from public.current_staff();
  v_out := v_out || E'\n⑪ current_staff() 實際回傳\t' ||
    coalesce(v_r.name || '（' || v_r.role || '）', '🔴 0 列');

  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.dbg', v_out, true);
exception when others then
  perform set_config('migi.dbg', v_out || E'\n🔴 炸了\t' || sqlerrm, true);
end $$;

select split_part(x, E'\t', 1) as 檢查,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.dbg', true), E'\n')) as x
 where coalesce(x,'') <> '';
