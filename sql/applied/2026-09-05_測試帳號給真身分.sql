/* ============================================================
   測試帳號拿到「真的身分」，而不是一條旁路
   2026-09-05 · MIGI 咪吉麻將

   ── 這一份解決什麼 ────────────────────────────────────
   待辦 14 把身分改成「由 JWT 說了算」之後，
   **測試01～04 進不了會員 App** —— 它們沒有 `line_user_id`。
   而那不是 bug，是那個改動的重點：**身分不能由前端宣告**。

   ── 🔴 為什麼這不是「JWT 旁路」──────────────────────
   硬規則 5.7 明列「開發用的 JWT 旁路」永遠不要做。認真評估之後
   結論改變了，因為**我把需求歸錯類了**：
   ```
   🔴 旁路 = 繞過身分驗證（「給我一個 sub 就發 JWT」）
   ✅ 這份 = 讓測試帳號**有**一個真的身分
   ```
   做完之後：
   · 產品碼**零改動** —— Edge Function / 前端 / 那 21 支 RPC 一行都沒動
   · 走**完全一樣**的身分解析路徑：
     `JWT.app_metadata.line_user_id → migi_jwt_line_id() → current_member_id()`
   · 後端**分不出**這張 session 是測試帳號還是真客人 —— 它們是同一種東西
   · 認證由 **Supabase Auth 的密碼**負責（雜湊、比對、rate limit 全是它的）
     —— 那正是硬規則 5.7 說「一律用託管的」的意思，我們沒有自建任何東西
   🎯 判準很簡單：**旁路是「不用證明就給你身分」，這份是「給你一個要證明的身分」。**

   ⚠ **合成 id 用 `TEST-` 開頭，不是 `U`＋32 hex** ——
     LINE 只發後者（已查證：咖勁凱的是 `U` ＋ 32 個字元，長度 33），
     所以 `TEST-` 開頭**不可能與真的 LINE 帳號相撞**。
     📌 `members.line_user_id` 沒有格式 CHECK（2026-09-05 查證），
       只有兩個唯一索引，所以任何字串都合法。

   ── 🔴 你要先做的（這份 SQL 不會幫你建 auth user）──────
   ```
   Supabase Dashboard → Authentication → Users → Add user   ×4
     Email     test01@migi.invalid  …  test04@migi.invalid
     Password  你自己設（四個可以一樣，但要記得）
     ☑ Auto Confirm User          ← 🔴 不勾的話登不進去
   ```
   ⚠ **刻意不用 SQL 直接 insert `auth.users`** ——
     那張表的欄位是 GoTrue 的內部契約（`confirmation_token`／`aud`／
     `instance_id`…），跨版本會變，而**猜錯的症狀是「建好了但登不進去」**，
     不是報錯。🎯 讓 GoTrue 自己建，我們只補 `app_metadata`。
   ⚠ 少建一個就**整份停下來** —— 不留「兩個能登入、兩個不能」的半套狀態，
     那種狀態最難查，因為它看起來像「有時候會壞」。

   ⚠ `.invalid` 是 RFC 2606 保留給「保證不存在」的 TLD ——
     那幾個信箱永遠收不到信，也不可能被別人註冊走。

   ── ⚠ 上線之後這些帳號**留著**（使用者 2026-09-05 決定）──
   常設測試帳號是每個正式系統都有的東西。
   🔴 **但它需要一層今天還不存在的隔離**（查證結果）：
   ```
   排行榜      ✅ 已經濾掉測試會員
   配桌房間    🔴 沒濾  ← 真客人會看到「測試01 開的房」並報名進去
   最近同桌    🔴 沒濾
   牌咖清單    🔴 沒濾
   門市清單    🔴 沒濾  ← 但今天必須不濾：7 間門市全部 is_test
   ```
   ⇒ 那四道濾網已加進 `docs/09-環境流程/上線當天要設的東西.md`。
   ⚠ 不補的話，常設測試帳號會從「方便」變成「真客人看到假房間」。
   ============================================================ */

do $t$
declare
  v_out   text := '';
  v_miss  text := '';
  -- 測試會員的暱稱 → [合成 id, auth 信箱]
  -- 📌 四個暱稱 2026-09-05 逐字查證過（硬規則 3：不猜取樣）
  c_map constant jsonb := jsonb_build_object(
    '測試測試測試測試測試測試', jsonb_build_array('TEST-01', 'test01@migi.invalid'),
    '測試02',                   jsonb_build_array('TEST-02', 'test02@migi.invalid'),
    '測試03',                   jsonb_build_array('TEST-03', 'test03@migi.invalid'),
    '測試04',                   jsonb_build_array('TEST-04', 'test04@migi.invalid'));
  k text; v_line text; v_email text; v_mid uuid; v_msg text;
begin
  ---- 前置：四個 auth user 都建好了嗎 --------------------
  for k in select jsonb_object_keys(c_map) loop
    v_email := c_map -> k ->> 1;
    if not exists (select 1 from auth.users u where u.email = v_email) then
      v_miss := v_miss || v_email || ', ';
    end if;
  end loop;

  if v_miss <> '' then
    /* 🔴 `raise` 的格式字串必須是**字面常值**，不是運算式：
       · 相鄰的 `'...' '...'` **不會**自動接起來（2026-09-04 踩過）
       · 改用 `'...' || '...'` 也不行 —— `syntax error at or near "||"`
       ⇒ 要多行訊息就**先組進變數**，再 `raise exception '%', v_msg`。 */
    v_msg := '🔴 這些 auth user 還沒建：' || rtrim(v_miss, ', ')
          || E'\n→ Dashboard → Authentication → Users → Add user'
          || E'\n→ 記得勾 Auto Confirm User，然後重跑這一份。';
    raise exception '%', v_msg;
  end if;

  ---- ① 給會員合成的 line_user_id ------------------------
  for k in select jsonb_object_keys(c_map) loop
    v_line  := c_map -> k ->> 0;
    v_email := c_map -> k ->> 1;

    select id into v_mid from members
     where display_name = k and deleted_at is null limit 1;
    if v_mid is null then
      raise exception '🔴 找不到會員「%」—— 取樣就錯了，不要往下跑', k;
    end if;

    /* 🔴 已經綁了**別的** line_user_id 就停下來 ——
       那代表這個帳號綁了真的 LINE，覆蓋掉會讓那個人登不進去。
       ⚠ 冪等：已經是同一個值則不算衝突，下面的 update 也不會動它。 */
    perform 1 from members
     where id = v_mid and line_user_id is not null and line_user_id <> v_line;
    if found then
      raise exception '🔴 會員「%」已經綁了別的 line_user_id —— 不覆蓋，請人工確認', k;
    end if;

    update members set line_user_id = v_line, updated_at = now()
     where id = v_mid and line_user_id is distinct from v_line;

    ---- ② auth user 的 app_metadata 帶上同一個 id --------
    /* 🔴 **一定要 `app_metadata` 不是 `user_metadata`** ——
       後者客戶端自己就能改（`supabase.auth.updateUser({ data: … })`），
       而 `migi_jwt_line_id()` 讀的就是這個 claim
       ⇒ 寫錯等於「輸入任何 line_user_id 就能變成他」。
       ⚠ 用 `||` **合併**不是覆寫 —— GoTrue 自己會放 provider／providers，
         整個蓋掉會弄壞它（2026-09-04 已知它甚至會回頭改寫 provider）。 */
    update auth.users u
       set raw_app_meta_data = coalesce(u.raw_app_meta_data, '{}'::jsonb)
             || jsonb_build_object('line_user_id', v_line, 'migi_kind', 'member')
     where u.email = v_email;

    v_out := v_out || E'\n' || k || E'\t' || v_line || '　→　' || v_email;
  end loop;

  perform set_config('migi.t', v_out, true);
end $t$;


-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
do $v$
declare
  v_out text := ''; v_n int; v_uid uuid; v_line text; v_name text;
begin
  ---- ① 四個會員都有合成 id ------------------------------
  select count(*) into v_n from members
   where line_user_id like 'TEST-%' and deleted_at is null;
  v_out := v_out || E'\n① 四個測試會員有合成 id' || E'\t' ||
    case when v_n = 4 then '✅ 4/4' else '🔴 只有 ' || v_n || '/4' end;

  ---- ② auth user 的 app_metadata 接得回會員 -------------
  select count(*) into v_n
    from auth.users u
    join members m on m.line_user_id = u.raw_app_meta_data ->> 'line_user_id'
                  and m.deleted_at is null
   where u.email like 'test0%@migi.invalid';
  v_out := v_out || E'\n② auth user 接得回會員' || E'\t' ||
    case when v_n = 4 then '✅ 4/4' else '🔴 只有 ' || v_n || '/4' end;

  ---- ③ 🎯 用測試01 的 JWT 實際解析一次 ------------------
  /* 🔴 「欄位設對了」不等於「身分解析得出來」——
     只有真的用那組 claims 查一次算數（硬規則 7）。 */
  select u.id, u.raw_app_meta_data ->> 'line_user_id' into v_uid, v_line
    from auth.users u where u.email = 'test01@migi.invalid';

  if v_uid is null then
    /* ⚠ 取樣失敗要**出聲**，不要安靜跳過 ——
       2026-09-04 就發生過「那一格沒出現而我以為全過」。 */
    v_out := v_out || E'\n③ 🎯 用 test01 的 JWT 解析' || E'\t' || '🔴 取樣失敗：找不到 test01 的 auth user';
  else
    perform set_config('request.jwt.claims', json_build_object(
      'sub', v_uid::text, 'role', 'authenticated',
      'app_metadata', json_build_object('line_user_id', v_line, 'migi_kind','member'))::text, true);

    select display_name into v_name from members where id = public.current_member_id();
    v_out := v_out || E'\n③ 🎯 用 test01 的 JWT 解析' || E'\t' ||
      case when v_name is not null then '✅ 解析到「' || v_name || '」' else '🔴 解析不到' end;

    ---- ④ 🎯 正對照：這張 session 不是店員 ---------------
    /* 只驗「會員解析得到」的話，一支把所有人都當成同一個人的實作也會綠。 */
    select count(*) into v_n from public.current_staff();
    v_out := v_out || E'\n④ 🎯 正對照：測試 session 不是店員' || E'\t' ||
      case when v_n = 0 then '✅ 0 列' else '🔴 回了 ' || v_n || ' 列' end;
  end if;

  perform set_config('request.jwt.claims', '', true);

  ---- ⑤ 🎯 正對照：沒有兩個會員共用同一個 line_user_id ---
  select count(*) into v_n from members m1
    join members m2 on m1.line_user_id = m2.line_user_id and m1.id <> m2.id
   where m1.deleted_at is null and m2.deleted_at is null;
  v_out := v_out || E'\n⑤ 🎯 正對照：沒有重複的 line_user_id' || E'\t' ||
    case when v_n = 0 then '✅ 0 組' else '🔴 有 ' || v_n || ' 組重複' end;

  ---- ⑥ 🎯 正對照：真的 LINE 帳號沒被動到 ----------------
  /* 期望值當場查出來的：現在有 1 個真的（`U` ＋ 32 字元）。
     ⚠ 不用暱稱比對 —— 暱稱可以改，而這一格要問的是「真 id 還在嗎」。 */
  select count(*) into v_n from members
   where line_user_id like 'U%' and length(line_user_id) = 33 and deleted_at is null;
  v_out := v_out || E'\n⑥ 🎯 正對照：真 LINE 帳號沒被覆蓋' || E'\t' ||
    case when v_n = 1 then '✅ 1 個，原封不動' else '🔴 變成 ' || v_n || ' 個' end;

  ---- ⑦ ⏳ 上線前還沒補的濾網（提醒，不是失敗）-----------
  v_out := v_out || E'\n⑦ ⏳ 上線前要補的濾網' || E'\t' ||
    '配桌房間／最近同桌／牌咖清單／門市清單 —— 見上線清單';

  perform set_config('migi.v', v_out, true);
end $v$;

select split_part(x, E'\t', 1) as 項目,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(
         coalesce(current_setting('migi.t', true), '') ||
         coalesce(current_setting('migi.v', true), ''), E'\n')) as x
 where coalesce(x, '') <> '';
