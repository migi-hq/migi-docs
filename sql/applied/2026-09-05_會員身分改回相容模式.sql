/* ============================================================
   🔴 回滾：會員身分守衛改成「相容模式」
   2026-09-05 · MIGI 咪吉麻將 · **先跑這一份，恢復服務**

   ── 發生什麼事 ────────────────────────────────────────
   `2026-09-05_會員身分改從JWT取.sql` 跑完之後，
   會員 App **很多畫面停在讀取中**。

   查證（不是猜的）：
   ```
   會員 session 最後發出   09-05 17:07（284 分鐘前，就是那次 LIFF 測試）
   之後                    一次都沒有再發過
   app_events 近 30 分錯誤  0 筆   ← rpcRead() 把失敗變成佔位畫面，不會 throw
   ```
   ⇒ 現在打開 App 的人**沒有 session** ⇒ 那 21 支全部 `not_authenticated`。

   ── 🔴 我的錯在順序，不在內容 ──────────────────────────
   我自己在那份 SQL 的檔頭寫著「**跑這份之前必須確認會員 App
   在真實裝置上每次開機都拿得到 session**」，並列出「一般瀏覽器
   要另外試一次」—— **而那一步沒做就跑了**。
   🎯 那份 SQL 的驗證段 8/8 全過，但驗的是「函式行為對不對」，
     **不是「真實使用者拿不拿得到 session」** —— 兩件事。

   ── 這一份做什麼 ──────────────────────────────────────
   把守衛從「拒絕」改成「**優先用 JWT，沒有才退回呼叫端送的值**」：
   ```
   改前：current_member_id() is null → raise
   改後：p_member_id := coalesce(current_member_id(), p_member_id)
   ```
   ⇒ 有 session 的人走 JWT（安全的那條），沒有的人維持原狀（App 能用）。

   ⚠ **這是暫時的，而且洞是開著的** —— 知道任何一個會員 uuid
     仍然查得到他的錢包。
   🔴 **不要讓它變成常態**：待辦 14 的收尾就是把 `coalesce` 拿掉，
     而那要等「每一條進入 App 的路都拿得到 session」被實測過。
   📌 `current_staff()` 排除會員 session 那一段**不回滾** ——
     它與這個問題無關，而且驗證段 ④ 證實了沒有誤傷 POS。
   ============================================================ */

do $rb$
declare
  r        record;
  v_def    text;
  v_new    text;
  v_done   int := 0;
  v_skip   int := 0;
  v_fail   text := '';
begin
  for r in
    select p.oid, p.proname
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.prokind = 'f'
       and p.proname in (
         'get_my_availability_tx','get_my_avatar_tx','get_my_games_tx','get_my_profile_tx',
         'get_my_rank_tx','get_my_stats_tx','get_wallet_tx','mark_app_active_tx',
         'save_app_state_tx','set_avatar_tx','set_my_about_tx','set_my_availability_tx',
         'set_my_baby_tile_tx','set_my_birthday_tx','set_my_home_store_tx','set_my_nickname_tx',
         'set_my_profile_basics_tx','set_my_sched_tx','set_my_see_score_tx','set_my_style_tx',
         'set_my_title_tx')
     order by p.proname
  loop
    v_def := pg_get_functiondef(r.oid);

    -- 冪等：已經是相容模式就跳過
    if v_def ~ 'coalesce\(\s*public\.current_member_id\(\)' then
      v_skip := v_skip + 1;
      continue;
    end if;

    /* 兩種形狀都要接：
       ① 19 支插進去的：`if public.current_member_id() is null then … end if;`
                        後面接 `p_member_id := public.current_member_id();`
       ② 2 支改寫的：   `v_me := public.current_member_id();`
                        `if v_me is null then … end if;`
                        `p_member_id := v_me;`
       ⚠ 一律用 `\s*` 吃掉換行與縮排 —— 定義裡是 CRLF。 */
    v_new := v_def;

    -- ① 先把「is null 就 raise」那三行整段拿掉
    v_new := regexp_replace(v_new,
      E'\\s*if\\s+public\\.current_member_id\\(\\)\\s+is\\s+null\\s+then\\s*raise\\s+exception\\s+''not_authenticated''\\s+using\\s+errcode\\s*=\\s*''28000'';\\s*end\\s+if;',
      '', 'gi');
    v_new := regexp_replace(v_new,
      E'\\s*if\\s+v_me\\s+is\\s+null\\s+then\\s*raise\\s+exception\\s+''not_authenticated''\\s+using\\s+errcode\\s*=\\s*''28000'';\\s*end\\s+if;',
      '', 'gi');

    -- ② 覆寫改成 coalesce
    v_new := regexp_replace(v_new,
      E'p_member_id\\s*:=\\s*public\\.current_member_id\\(\\);',
      'p_member_id := coalesce(public.current_member_id(), p_member_id);', 'gi');
    v_new := regexp_replace(v_new,
      E'p_member_id\\s*:=\\s*v_me;',
      'p_member_id := coalesce(v_me, p_member_id);', 'gi');

    if v_new = v_def then
      v_fail := v_fail || r.proname || ', ';
      continue;
    end if;

    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_fail <> '' then
    raise exception '🔴 這幾支改不動：% —— 整份回滾，不要留下改一半的狀態', v_fail;
  end if;
  perform set_config('migi.rb', v_done::text || ' 改成相容模式，' || v_skip::text || ' 已經是', true);
end $rb$;


-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
do $v$
declare
  v_out text := '';
  v_uid uuid; v_line text; v_n int; v_ok boolean;
begin
  v_out := v_out || E'\n⓪ 這次改了' || E'\t' || coalesce(current_setting('migi.rb', true), '(沒有紀錄)');

  ---- ① 🔴 最重要：沒有 JWT 時要能用（那正是壞掉的症狀）------
  perform set_config('request.jwt.claims', '', true);
  begin
    v_ok := (public.get_my_avatar_tx(
      (select id from members where deleted_at is null order by created_at limit 1)
    ) ->> 'ok') = 'true';
    v_out := v_out || E'\n① 🔴 沒有 JWT 時 App 能用' || E'\t' ||
      case when v_ok then '✅ 回得出資料 —— 服務恢復' else '🔴 仍然回空' end;
  exception when others then
    v_out := v_out || E'\n① 🔴 沒有 JWT 時 App 能用' || E'\t' || '🔴 仍然被擋：' || sqlerrm;
  end;

  ---- ② 🎯 正對照：有 JWT 時仍然以 JWT 為準（不是退回沒防護）--
  /* 只驗「沒 JWT 能用」的話，一支**完全沒有守衛**的實作也會綠。 */
  select u.id, u.raw_app_meta_data ->> 'line_user_id' into v_uid, v_line
    from auth.users u where u.email like 'line-%@member.migi.invalid' limit 1;

  if v_uid is null then
    v_out := v_out || E'\n② 🎯 正對照' || E'\t' || '🔴 取樣失敗：找不到會員 auth user';
  else
    perform set_config('request.jwt.claims', json_build_object(
      'sub', v_uid::text, 'role', 'authenticated',
      'app_metadata', json_build_object('line_user_id', v_line, 'migi_kind','member'))::text, true);
    /* 送一個**不存在**的 id：有 JWT 時必須回自己的資料（覆寫仍生效）。 */
    v_out := v_out || E'\n② 🎯 正對照：有 JWT 仍以 JWT 為準' || E'\t' ||
      case when (public.get_my_avatar_tx('00000000-0000-0000-0000-000000000000'::uuid) ->> 'ok') = 'true'
           then '✅ 送假 id 仍回自己的' else '🔴 JWT 被忽略了' end;
  end if;

  ---- ③ 🎯 正對照：current_staff() 的收窄沒有被回滾掉 --------
  select count(*) into v_n from public.current_staff();
  v_out := v_out || E'\n③ 🎯 正對照：會員 session 仍不是店員' || E'\t' ||
    case when v_n = 0 then '✅ 0 列（那一段沒被回滾）' else '🔴 回了 ' || v_n || ' 列' end;

  ---- ④ 掃全庫：21 支都是相容模式了嗎 ----------------------
  perform set_config('request.jwt.claims', '', true);
  select count(*) into v_n
    from pg_proc p
   where p.pronamespace='public'::regnamespace and p.prokind='f'
     and p.proname in (
       'get_my_availability_tx','get_my_avatar_tx','get_my_games_tx','get_my_profile_tx',
       'get_my_rank_tx','get_my_stats_tx','get_wallet_tx','mark_app_active_tx',
       'save_app_state_tx','set_avatar_tx','set_my_about_tx','set_my_availability_tx',
       'set_my_baby_tile_tx','set_my_birthday_tx','set_my_home_store_tx','set_my_nickname_tx',
       'set_my_profile_basics_tx','set_my_sched_tx','set_my_see_score_tx','set_my_style_tx',
       'set_my_title_tx')
     and pg_get_functiondef(p.oid) ~ 'coalesce\(\s*public\.current_member_id\(\)';
  v_out := v_out || E'\n④ 21 支都是相容模式' || E'\t' ||
    case when v_n = 21 then '✅ 21/21' else '🔴 只有 ' || v_n || '/21' end;

  ---- ⑤ 🎯 正對照：raise 已經清乾淨（不能留半套）------------
  select count(*) into v_n
    from pg_proc p
   where p.pronamespace='public'::regnamespace and p.prokind='f'
     and pg_get_functiondef(p.oid) ~ 'not_authenticated';
  v_out := v_out || E'\n⑤ 🎯 正對照：沒有殘留的 raise' || E'\t' ||
    case when v_n = 0 then '✅ 0 支' else '🔴 還有 ' || v_n || ' 支會拒絕' end;

  perform set_config('migi.v', v_out, true);
end $v$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.v', true), E'\n')) as x
 where coalesce(x, '') <> '';
