/* ============================================================
   團徽照片：bucket ＋ 三支給上傳流程用的函式
   2026-09-11 · 使用者決定「團徽要能上傳照片，**不用審核**」

   ⚠ 這份要留下東西，所以整份不准 `raise`（硬規則 1.8）。

   ── 🔴 為什麼團徽自己一個 bucket ────────────────────
   `file_size_limit`、`allowed_mime_types`、`public` 這三樣是
   **bucket 層的設定**，同一個 bucket 裡改不了。
   ⇒ 做一個通用的 `uploads` 會被迫取最寬鬆的一組，
     而頭像那道 512 KB 的牆會**安靜地消失**。

   判準是「**誰擁有它、什麼時候該消失**」，不是「它畫的是什麼」：
   ```
   member-avatars  會員的臉        512 KB   會員刪帳號時該清
   team-crests     團的識別        512 KB   團解散時該清      ← 這一批
   store-photos    店家的內容      5 MB     總部管理
   （日後）打卡照片 會員的行為紀錄  要更大   有量，保留期限才是真問題
   ```
   ⚠ 塞進 `member-avatars` 的話那個名字會裝兩件事 ——
     這個專案記過八次的同一族病，而 bucket 名字**改不了**（路徑跟著它）。

   ── 三支函式，而「誰能換團徽」只有一份定義 ────────────
   ```
   _is_team_leader        內部，誰都叫不到
   set_team_crest_tx      會員 App 叫（JWT 身分）      ← 改成呼叫上面那支
   team_crest_guard_tx    Edge Function 叫（service_role）
   clear_team_crest_tx    Edge Function 叫（service_role）
   ```
   🔴 後兩支**收 `p_member_id`**，那是刻意的而且安全：
     Edge Function 手上只有驗過簽的 LINE `sub`，**沒有會員 JWT**
     ⇒ `current_member_id()` 在它的呼叫裡一定是 null。
     同 `get_staff_by_line_tx` 的先例 —— 只授權給 `service_role`，
     anon 與 authenticated 都叫不動。
   ⚠ 所以它們**不算**待辦 14 那 53 支「信前端」的一員。

   ── ⚠ 已知缺口，寫下來不修 ──────────────────────────
   換一張新團徽時，**舊的檔案會變成孤兒**（頭像也一樣，
   `social.js:477` 的註解就寫著「交給日後的清理排程」）。
   解散團的時候同理。
   🎯 今天無所謂；**打卡照片一上線就會變成真的成本**，因為那個有量。
     清理排程要做的時候一次涵蓋三個 bucket，不要為團徽單獨做一個。
   ============================================================ */


/* ─────────────────────────────────────────────────────────
   ① bucket
   ───────────────────────────────────────────────────────── */
/* 設定與 `member-avatars` 逐項相同：公開、512 KB、只收 webp 與 jpeg。
   🔴 `public = true` 是刻意的，理由與頭像那次一樣（`social.js:418`）：
     私有 bucket 要簽名網址，而**開了 SELECT 就能 `.list()`** ——
     資料夾名是 team_id，等於把全部團的 id 交出去。
     代價用**隨機檔名**補（路徑由 Edge Function 產 UUID，猜不到）。
   ⚠ webp 與 jpeg 兩種，不收 png —— iOS 的 canvas 不支援 webp 編碼會退回
     JPEG（2026-08-29 實機打臉過），但沒有任何路徑會產生 png。 */
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('team-crests', 'team-crests', true, 524288,
        array['image/webp', 'image/jpeg'])
on conflict (id) do nothing;

/* 🔴 **刻意不加任何 storage policy。**
   沒有 policy ⇒ 寫入只剩 `service_role` ⇒ 只有 Edge Function 進得去。
   那正是頭像那次把四條 policy 全部清掉的結論：
   會員 App 用 anon key 沒有 auth session，policy 裡沒有 `auth.uid()`
   可以比對 ⇒ 寫不出「只能動自己的檔案」
   ⇒ 在那之前**任何人可以覆蓋、刪掉任何人的頭像**。 */


/* ─────────────────────────────────────────────────────────
   ② 「誰能換團徽」的唯一定義
   ───────────────────────────────────────────────────────── */
create or replace function public._is_team_leader(p_team_id uuid, p_member_id uuid)
returns boolean
language sql
stable
as $$
  select exists (
    select 1 from public.team_members tm
     join public.teams t on t.id = tm.team_id and t.deleted_at is null
    where tm.team_id = p_team_id and tm.member_id = p_member_id
      and tm.left_at is null and tm.role = 'leader');
$$;

revoke execute on function public._is_team_leader(uuid, uuid) from public;
revoke execute on function public._is_team_leader(uuid, uuid) from anon, authenticated;


/* ─────────────────────────────────────────────────────────
   ③ set_team_crest_tx 改成呼叫上面那支
   ───────────────────────────────────────────────────────── */
/* ⚠ 簽名完全沒變 ⇒ `CREATE OR REPLACE` ⇒ 不用 DROP、不掉 GRANT。
   改的只有中間那段判斷，讓「誰能換團徽」在系統裡只有一份定義。
   🔴 少了這一步，同一件事會有三份寫法（這一支、guard、clear），
     而三份會漂，漂掉不報錯 —— 只會變成「App 裡改得動、上傳卻被擋」。 */
create or replace function public.set_team_crest_tx(p_team_id uuid,
                                                    p_emoji   text default null,
                                                    p_path    text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me    uuid := public.current_member_id();
  v_emoji text := nullif(btrim(coalesce(p_emoji, '')), '');
  v_path  text := nullif(btrim(coalesce(p_path,  '')), '');
  v_blk   boolean;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if not public._is_team_leader(p_team_id, v_me) then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以換團徽');
  end if;

  if v_emoji is not null and char_length(v_emoji) > 8 then
    return jsonb_build_object('ok', false, 'reason', 'bad_emoji', 'message', '團徽圖示太長了');
  end if;

  select t.crest_blocked into v_blk from public.teams t
   where t.id = p_team_id and t.deleted_at is null;
  if v_blk is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;
  if v_blk and v_path is not null then
    return jsonb_build_object('ok', false, 'reason', 'crest_blocked',
                              'message', '這個團的自訂團徽已停用，請改用圖示');
  end if;

  /* 🔴 路徑一定要**在這個團自己的資料夾底下**。
     少了這一道，前端可以送別的團的路徑進來
     ⇒ 「換自己的團徽」變成「把別人的圖掛到自己團上」，
     而且它不會報錯。Edge Function 產的路徑本來就是 `{team_id}/…`，
     所以這道牆對正常流程完全沒有感覺。 */
  if v_path is not null and v_path not like (p_team_id::text || '/%') then
    return jsonb_build_object('ok', false, 'reason', 'bad_path', 'message', '團徽路徑不正確');
  end if;

  update public.teams
     set crest_path  = case when v_emoji is not null then null else v_path end,
         crest_emoji = coalesce(v_emoji, crest_emoji),
         updated_at  = now()
   where id = p_team_id and deleted_at is null;

  return jsonb_build_object('ok', true, 'team', public._team_card(p_team_id));
end $$;


/* ─────────────────────────────────────────────────────────
   ④ team_crest_guard_tx —— 給 Edge Function 問「他能不能傳」
   ───────────────────────────────────────────────────────── */
create or replace function public.team_crest_guard_tx(p_team_id uuid, p_member_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_blk boolean;
begin
  select t.crest_blocked into v_blk from public.teams t
   where t.id = p_team_id and t.deleted_at is null;
  if v_blk is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;
  if not public._is_team_leader(p_team_id, p_member_id) then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以換團徽');
  end if;
  if v_blk then
    return jsonb_build_object('ok', false, 'reason', 'crest_blocked',
                              'message', '這個團的自訂團徽已停用，請改用圖示');
  end if;
  return jsonb_build_object('ok', true);
end $$;


/* ─────────────────────────────────────────────────────────
   ⑤ clear_team_crest_tx —— 清欄位並回傳要刪的檔案
   ───────────────────────────────────────────────────────── */
/* 🎯 順序是「先清資料庫、再刪檔案」（2026-08-29 頭像那個 bug 的結論）：
     先刪檔案失敗 → 欄位指向不存在的檔案（**看得見、會壞畫面**）
     先清欄位失敗 → 孤兒檔案（看不見、不影響任何東西）
   ⚠ 要刪哪一個檔案由**這一支回傳**，不採信 Edge Function 送來的路徑
     —— 那又會變成「刪別人的檔案」。 */
create or replace function public.clear_team_crest_tx(p_team_id uuid, p_member_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_old text;
begin
  if not public._is_team_leader(p_team_id, p_member_id) then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以換團徽');
  end if;

  select t.crest_path into v_old from public.teams t
   where t.id = p_team_id and t.deleted_at is null;

  update public.teams set crest_path = null, updated_at = now()
   where id = p_team_id and deleted_at is null;

  return jsonb_build_object('ok', true, 'path', v_old);
end $$;


/* ─────────────────────────────────────────────────────────
   ⑥ 授權
   ───────────────────────────────────────────────────────── */
/* 🔴 後兩支**只給 service_role**。它們收 `p_member_id`，
   而那個參數只有在「呼叫端是我們自己的伺服器」時才安全。
   ⚠ 兩個方向都要收（硬規則 2.6b）——
     新建的函式吃 default privileges，anon 是**明確授權**不是 PUBLIC 繼承。 */
do $$
declare v_sig text;
begin
  foreach v_sig in array array[
    'public.team_crest_guard_tx(uuid, uuid)',
    'public.clear_team_crest_tx(uuid, uuid)'
  ] loop
    execute format('revoke execute on function %s from public', v_sig);
    execute format('revoke execute on function %s from anon, authenticated', v_sig);
    execute format('grant  execute on function %s to service_role', v_sig);
  end loop;
end $$;


/* ============================================================
   驗證（唯讀，不准 raise）
   ============================================================ */
do $$
declare
  v_msg text := '';
  v_n   int;
  v_b   record;
  v_r   jsonb;
begin
  /* ① bucket 的三個設定要與頭像一致 */
  select b.public, b.file_size_limit, b.allowed_mime_types into v_b
    from storage.buckets b where b.id = 'team-crests';
  if v_b is null then
    v_msg := '① 🔴 bucket `team-crests` 沒有建出來';
  else
    v_msg := '① ' || case
      when v_b.public and v_b.file_size_limit = 524288
       and v_b.allowed_mime_types @> array['image/webp','image/jpeg']
      then '✅ bucket 建好了：公開 · 512 KB · webp/jpeg（與 member-avatars 逐項相同）'
      else '🔴 bucket 的設定不對：public=' || v_b.public
           || ' limit=' || coalesce(v_b.file_size_limit::text,'null')
           || ' mime=' || coalesce(array_to_string(v_b.allowed_mime_types,','),'null') end;
  end if;

  /* ② 🔴 這個 bucket 不可以有任何 storage policy。
     有的話就等於把寫入開回給前端，而那正是頭像那次清掉四條的原因。 */
  select count(*) into v_n from pg_policies
   where schemaname = 'storage' and tablename = 'objects'
     and (qual ilike '%team-crests%' or with_check ilike '%team-crests%');
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '② ✅ 沒有任何針對這個 bucket 的 storage policy（寫入只剩 service_role）'
    else '② 🔴 有 ' || v_n || ' 條 policy 指名這個 bucket —— 前端可能寫得進去' end;

  /* ③ 四支函式都在 */
  select count(*) into v_n from pg_proc
   where pronamespace = 'public'::regnamespace
     and proname in ('_is_team_leader','set_team_crest_tx','team_crest_guard_tx','clear_team_crest_tx');
  v_msg := v_msg || E'\n' || case when v_n = 4
    then '③ ✅ 四支都在，各只有一個版本'
    else '③ 🔴 共 ' || v_n || ' 支，預期 4' end;

  /* ④ set_team_crest_tx 真的改成呼叫共用那支了
     🔴 沒改成功的話，「誰能換團徽」會有兩份定義，而它不會報錯。 */
  v_msg := v_msg || E'\n' || case
    when position('_is_team_leader' in
           pg_get_functiondef('public.set_team_crest_tx(uuid,text,text)'::regprocedure)) > 0
    then '④ ✅ set_team_crest_tx 改成呼叫 _is_team_leader（判斷只有一份）'
    else '④ 🔴 它還留著自己那份團長判斷 —— 三份定義遲早會漂' end;

  /* ⑤ 授權：兩支 service_role 專用的，anon 與 authenticated 都要是 0 */
  select count(*) into v_n
    from pg_proc p left join lateral aclexplode(p.proacl) a on true
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('team_crest_guard_tx','clear_team_crest_tx','_is_team_leader')
     and (a.grantee = 'anon'::regrole::oid or a.grantee = 0
          or a.grantee = 'authenticated'::regrole::oid)
     and a.privilege_type = 'EXECUTE';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '⑤ ✅ 三支內部／伺服器專用的函式，前端一支都叫不到'
    else '⑤ 🔴 有 ' || v_n || ' 筆給了 anon 或 authenticated' end;

  select count(*) into v_n
    from pg_proc p join lateral aclexplode(p.proacl) a on true
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('team_crest_guard_tx','clear_team_crest_tx')
     and a.grantee = 'service_role'::regrole::oid and a.privilege_type = 'EXECUTE';
  v_msg := v_msg || E'\n' || case when v_n = 2
    then '⑥ ✅ 兩支都授權給 service_role（正對照 —— 沒有連 Edge Function 一起關掉）'
    else '⑥ 🔴 只有 ' || v_n || '/2 給了 service_role —— 上傳會整條斷掉' end;

  /* ⑦ 實際執行一次（硬規則 7）。
     ⚠ 用不存在的團與不存在的人 ⇒ 正確答案是 not_found，
       那證明函式體真的走到而且欄位名都對得上。 */
  v_r := public.team_crest_guard_tx('00000000-0000-0000-0000-000000000000'::uuid,
                                    '00000000-0000-0000-0000-000000000000'::uuid);
  v_msg := v_msg || E'\n' || case when coalesce(v_r->>'reason','') = 'not_found'
    then '⑦ ✅ guard 跑得動，不存在的團回 not_found'
    else '⑦ 🔴 預期 not_found，實際 ' || coalesce(v_r::text,'null') end;

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
