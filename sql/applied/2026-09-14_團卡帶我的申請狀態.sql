/* ============================================================
   團卡多回一個 `my_request`：我跟這個團之間有沒有一筆還在談的
   2026-09-14
   ------------------------------------------------------------
   使用者：「牌咖團的申請 PILL 改『申請中』，顏色不要黑底白字，
   不然跟『加入』無法區別」。

   🔴 改文案之前先查了後端：`_team_card` **回不出這件事**。
     直接把字改成「申請中」的話，**一個從來沒申請過的團也會寫申請中** ——
     那是畫面說一件沒發生的事，比顏色分不出來更糟。

   🎯 而查的時候發現一個真的 bug，兩件事同一個根：
   ```
   申請完 → search_teams_tx 仍然列出那個團（它只濾掉「已經在裡面」的）
          → 按鈕仍然寫「申請」
          → 再按一次 → apply_team_tx 回 already_pending「你的申請正在等團長審核」
   ```
   ⇒ **一顆按下去一定失敗的按鈕**，而這個專案記過好幾次那比沒有更糟。

   ── 這份做什麼 ───────────────────────────────────
   `_team_card` 多回一個 `my_request`：`'apply'` / `'invite'` / `null`。
   ⚠ 簽名沒變，所以是 `CREATE OR REPLACE`，不用 DROP、不會掉 GRANT、
     前端沒部署也不會壞（多一個鍵，舊前端讀不到就當它不存在）。

   🔴 **回文字不回布林，因為那兩種的下一步完全相反**（撈 `apply_team_tx`
     全文確認的，不是推測）：
   ```
   apply   已經送出申請  → 再按一次必定回 already_pending    ⇒ 要擋
   invite  團長邀了我    → 按下去**當場入團**（它把邀請改成 accepted）⇒ 要鼓勵
   ```
   ⚠ 第一版我寫成布林 `my_pending`，而 `team_requests.kind` 的 CHECK 是
     `('apply','invite')` ⇒ **團長邀我的團會被畫成「申請中」**，
     而那顆按鈕其實按下去就進去了。**同一個錯的反面。**

   🔴 **必須自己算過期，不可以只看 `status = 'pending'`。**
     `_team_expire_requests` 是**被動**的（`apply_team_tx` 進來時才順手掃），
     所以一筆過了 `expires_at` 的申請會**一直停在 pending**。
     只看 status 的話畫面會永遠寫「申請中」並把按鈕鎖死，
     而那個團其實早就可以再申請了。
   📌 而這不是「同一件事判兩次」—— **線上已經有四支在這樣算**
     （`get_team_tx`／`list_my_teams_tx`／`list_notifications_tx`／
     `list_team_requests_tx` 都讀 `expires_at`）。這裡是跟上既有的判準，
     不是發明第二套。

   ⚠ 這張卡從此**與看的人有關**：同一個團，不同人拿到的 `my_request` 不同。
     📌 那不是新規矩 —— `crest_path` 早就會因為 `crest_blocked` 而變。
     ⚠ 但它確實讓這支函式不再是純粹的「團的資料」，
       所以日後要快取團卡時**不可以跨使用者共用**。
   ============================================================ */

create or replace function public._team_card(p_team_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $$
declare
  v_t      record;
  v_from   timestamptz;
  v_played int;
  v_month  int;
  v_cnt    int;
  v_me     uuid := public.current_member_id();
  v_req    text;
begin
  select t.*, s.name as store_name
    into v_t
    from public.teams t
    left join public.stores s on s.id = t.home_store_id
   where t.id = p_team_id and t.deleted_at is null;
  if not found then return null; end if;

  /* 「本月」用台北日曆月，與當日暢打同一個判準 ——
     系統裡不要有第二種「這個月是哪一段」。 */
  v_from := (date_trunc('month', (now() at time zone 'Asia/Taipei')) at time zone 'Asia/Taipei');

  select count(*), count(*) filter (where played_at >= v_from)
    into v_played, v_month
    from public._team_session_ids(p_team_id);

  select count(*) into v_cnt
    from public.team_members where team_id = p_team_id and left_at is null;

  /* 🆕 我跟這個團之間還在談的那一筆是什麼。
     ⚠ 沒登入時 `v_me` 是 null ⇒ 這段查不到東西 ⇒ 回 null，那是對的：
       沒有人登入就沒有人在申請。
     ⚠ **不需要 order by / limit**：`uq_team_request_pending
       (team_id, member_id) where status = 'pending'` 保證同一個人對同一個團
       最多只有一筆在談。
       🔴 我第一版寫了「兩種同時存在時邀請優先」的排序 —— 那在資料庫層
         **不可能發生**，而一段處理不可能情況的程式碼會讓下一個人
         以為它會發生。 */
  select r.kind into v_req
    from public.team_requests r
   where r.team_id = p_team_id and r.member_id = v_me
     and r.status = 'pending' and r.expires_at > now();

  return jsonb_build_object(
    'id',              v_t.id,
    'name',            v_t.name,
    'intro',           v_t.intro,
    'crest_emoji',     v_t.crest_emoji,
    'crest_path',      case when v_t.crest_blocked then null else v_t.crest_path end,
    'join_policy',     v_t.join_policy,
    'home_store_id',   v_t.home_store_id,
    'home_store_name', v_t.store_name,
    'monthly_goal',    v_t.monthly_goal,
    'member_limit',    v_t.member_limit,
    'member_count',    v_cnt,
    'played',          v_played,
    'month_played',    v_month,
    'my_request',      v_req,
    'created_at',      v_t.created_at);
end $$;

/* ============================================================
   驗證。🔴 一個 raise 都沒有 —— 這份要留下函式（硬規則 1.8）。
   ⚠ 行為（真的有一筆 pending 時會不會變 apply）要造樣本，
     那份在 `sql/checks/2026-09-14_驗團卡的申請狀態.sql`，
     它結尾會 `raise` 把樣本回滾掉。**兩份不可以合併。**
   ============================================================ */
do $$
declare v_msg text := '';
begin
  v_msg := '① 版本數（應為 1）：'
    || coalesce((select count(*)::text from pg_proc p
                  where p.pronamespace = 'public'::regnamespace
                    and p.proname = '_team_card'), '🔴 查不到');

  v_msg := v_msg || E'\n② 回傳鍵數（原本 14，加一個應為 15）：'
    || coalesce((select count(*)::text
         from jsonb_object_keys(coalesce(
           (select public._team_card(t.id) from public.teams t
             where t.deleted_at is null limit 1), '{}'::jsonb))), '⚪ 一個團都沒有');

  v_msg := v_msg || E'\n③ 新鍵在不在：'
    || coalesce((select (public._team_card(t.id) ? 'my_request')::text
                  from public.teams t where t.deleted_at is null limit 1), '⚪ 一個團都沒有');

  /* ④ 它現在的值。⚠ 用 Dashboard／MCP 跑時 `current_member_id()` 是 null，
     所以這一格**預期就是空的**；那不代表功能沒用 ——
     行為由 checks 那一份的正對照證明。 */
  v_msg := v_msg || E'\n④ 現在的值（用執行者的身分算，預期空白）：「'
    || coalesce((select (public._team_card(t.id) ->> 'my_request')
                  from public.teams t where t.deleted_at is null limit 1), '')
    || '」';

  /* ⑤ 正對照（硬規則 3.55）：直接問資料庫現在有幾筆還在談的。
     🔴 少了這一格，一支永遠回 null 的實作也會讓上面每一格變綠。 */
  v_msg := v_msg || E'\n⑤ 正對照 · 全站還沒過期的 pending：apply '
    || coalesce((select count(*)::text from public.team_requests
                  where status = 'pending' and expires_at > now() and kind = 'apply'), '🔴')
    || ' 筆　invite '
    || coalesce((select count(*)::text from public.team_requests
                  where status = 'pending' and expires_at > now() and kind = 'invite'), '🔴')
    || ' 筆　（過期沒掃到的：'
    || coalesce((select count(*)::text from public.team_requests
                  where status = 'pending' and expires_at <= now()), '🔴')
    || ' 筆 ← 這些現在會被正確當成沒有）';

  /* ⑥ 誰在用這張卡 —— 加一個鍵會影響的範圍。
     ⚠ 用 `like` 比對函式全文，樣式要跳脫底線（硬規則 3.5）。 */
  v_msg := v_msg || E'\n⑥ 呼叫 _team_card 的函式：'
    || coalesce((select string_agg(p.proname, '　' order by p.proname)
         from pg_proc p
        where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
          and p.proname <> '_team_card'
          and pg_get_functiondef(p.oid) like '%\_team\_card%'), '🔴 沒有人用它');

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
