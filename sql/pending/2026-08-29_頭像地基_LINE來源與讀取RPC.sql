/* ============================================================
   頭像地基：加入 LINE 這個來源 ＋ 補一支讀取 RPC ＋ 清掉一個洞
   2026-08-29

   ── 三個來源，各自存在哪 ────────────────────────────
   | avatar_source | 圖從哪來 | 欄位 | 要簽名嗎 |
   |---|---|---|---|
   | `bear` | 內建小熊造型 | `avatar_bear`（null = 通用預設熊） | 不用（打包在前端） |
   | `photo` | 客人上傳 | `avatar_photo_path` | 🔴 要（私有 bucket） |
   | **`line`** ← 這次新增 | LINE 大頭貼 | **`avatar_url`** | 不用（LINE 公開 CDN） |

   ✅ `avatar_url` 不是新欄位，也不是隨便挑的 ——
     **`get_my_profile_tx` / `list_buddies_tx` / `get_my_active_queue_tx` /
     `list_blocks_tx` 四支清單 RPC 早就在回傳它**，只是一直是 null。

   ── 🔴 為什麼 LINE 頭像不能讓前端送 ────────────────
   直覺是 `liff.getProfile()` 拿 `pictureUrl` 再送給後端。**那不行** ——
   那個值是前端說的，等於「任何人可以把任何網址寫進任何人的頭像」。
   🎯 正解：**LINE 的 `/oauth2/v2.1/verify` 回傳的 payload 裡就有 `picture`**，
     跟 `sub` 是同一份、同一次驗簽。所以 Edge Function 自己取得出來。
   → `set_line_avatar_tx` 因此**只授權 `service_role`**（見檔尾授權段）。

   ── 這份做四件事 ────────────────────────────────────
   ① 🔴 刪掉 `set_my_avatar_tx` —— **死碼而且是洞**
   ② CHECK 加 `'line'`
   ③ `set_avatar_tx` 加 `'line'` 分支
   ④ 補 `set_line_avatar_tx`（service_role）與 `get_my_avatar_tx`（anon）
   ============================================================ */


/* ── ① 刪掉 set_my_avatar_tx ────────────────────────
   ```
   set_my_avatar_tx(p_org_id, p_member_id, p_avatar)
     → update members set avatar_url = p_avatar where id = p_member_id
   授權：anon 也叫得動
   ```
   🔴 **任何人可以把任意文字寫進任何人的 `avatar_url`。**
   ✅ 而且它是死碼：唯一的包裝 `lib/profile.js:setMyAvatar()`
     **整個前端一次都沒有被呼叫**（已 grep 三個 repo 確認）。
   ⚠ 它是上一代的寫法（一欄裝一個網址），新的是
     `set_avatar_tx`（source ＋ 三個來源各自的欄位）。
     **同一件事兩代並存**，同 `wallet_txns.type`（待辦 12）那個病。 */
drop function if exists public.set_my_avatar_tx(uuid, uuid, text);


/* ── ② CHECK 加 'line' ──────────────────────────────
   原本：CHECK (avatar_source = ANY (ARRAY['bear','photo']))
   ⚠ 現有 5 個會員全部是 `bear`，所以放寬不會有任何列違反。 */
alter table members drop constraint if exists members_avatar_source_chk;
alter table members add constraint members_avatar_source_chk
  check (avatar_source = any (array['bear', 'photo', 'line']));


/* ── ③ set_avatar_tx 加 'line' 分支 ─────────────────
   ⚠ 簽名沒變 ⇒ `CREATE OR REPLACE`，不用 DROP、不會掉 GRANT（硬規則 2）。
   ⚠ 撈的是**線上版全文**（`pg_get_functiondef`）改的，不是拿 applied/ 的檔案
     當基準（硬規則 3）。 */
create or replace function public.set_avatar_tx(
  p_member_id uuid, p_source text, p_path text default null, p_bear text default null)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_blocked boolean;
  v_line    text;
  v_bear    text := nullif(btrim(coalesce(p_bear, '')), '');
begin
  if p_source not in ('bear','photo','line') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_source');
  end if;

  select avatar_blocked, avatar_url into v_blocked, v_line
    from members where id = p_member_id;
  if v_blocked is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  /* ⚠ 只擋長度，**不擋內容**。
     小熊清單是**內容**不是狀態（同硬規則 10 的分法），日後會增加；
     加白名單的話每新增一隻造型就要跑一次 migration。
     壞值的後果很輕微：前端的 `rankBearSrc()` 找不到就 fallback 回銅牌熊。 */
  if v_bear is not null and char_length(v_bear) > 20 then
    return jsonb_build_object('ok', false, 'reason', 'bear_too_long');
  end if;

  if p_source = 'photo' then
    if v_blocked then
      return jsonb_build_object('ok', false, 'reason', 'upload_blocked',
        'message', '你的自訂頭像功能已被停用，請洽門市人員');
    end if;
    if p_path is null then
      return jsonb_build_object('ok', false, 'reason', 'path_required');
    end if;
    -- ★ 路徑必須位於自己的資料夾底下：{member_id}/xxxxx.webp
    --   （原版就有，保留 —— 它擋掉「把頭像指向別人的檔案」）
    if p_path not like (p_member_id::text || '/%') then
      return jsonb_build_object('ok', false, 'reason', 'path_not_owned');
    end if;

    /* ⚠ 切到照片時**不動 avatar_bear** —— 那是「小熊要哪一隻」的記憶，
       之後切回小熊時要用得到。切走不該把它忘掉。 */
    update members
       set avatar_source = 'photo', avatar_photo_path = p_path,
           avatar_photo_at = now(), updated_at = now()
     where id = p_member_id;

  elsif p_source = 'line' then
    /* 🔴 `avatar_blocked` 也要擋 LINE。
       那個旗標的意思是「這個人放過不適當的自訂圖像」，
       而 LINE 大頭貼同樣是他自己選的圖 ——
       只擋上傳的話，把同一張圖換到 LINE 上就繞過去了，
       那個處分等於沒有。 */
    if v_blocked then
      return jsonb_build_object('ok', false, 'reason', 'upload_blocked',
        'message', '你的自訂頭像功能已被停用，請洽門市人員');
    end if;
    /* ⚠ 還沒同步過就不能選 —— 否則畫面會是一個空頭像，
       而客人只會覺得「壞了」。要他先按同步。 */
    if v_line is null then
      return jsonb_build_object('ok', false, 'reason', 'line_avatar_missing',
        'message', '還沒取得你的 LINE 頭像，請先按同步');
    end if;
    -- ⚠ 同樣不動 avatar_bear / avatar_photo_path，三個來源可以互相切回去
    update members
       set avatar_source = 'line', updated_at = now()
     where id = p_member_id;

  else
    /* 切到小熊：照片保留不刪，之後可隨時切換回來。
       ★ 同時記住是哪一隻（null = 預設的通用小熊）。 */
    update members
       set avatar_source = 'bear', avatar_bear = v_bear, updated_at = now()
     where id = p_member_id;
  end if;

  return jsonb_build_object('ok', true, 'source', p_source, 'bear', v_bear);
end $function$;


/* ── ④a set_line_avatar_tx —— 只有 Edge Function 叫得動 ──
   🔴 **不授權 anon**。它寫的是一個網址，而網址是「別人看得到的內容」——
     開給 anon 等於「任何人可以把任意圖片掛到任何會員的頭像上」。
   ⚠ 即使只有 service_role，仍然擋一次網域：
     那是零成本的第二道，而且**萬一哪天 Edge Function 寫錯欄位，
     這裡會擋下來而不是靜靜放行**（同 line-login 自己再比一次 aud）。 */
create or replace function public.set_line_avatar_tx(p_member_id uuid, p_url text)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_url text := nullif(btrim(coalesce(p_url, '')), '');
begin
  if v_url is null then
    return jsonb_build_object('ok', false, 'reason', 'url_required');
  end if;

  /* ⚠ 只認 LINE 自己的 CDN。用「主機結尾是 .line-scdn.net」而不是寫死
     `profile.line-scdn.net` —— LINE 實際上會用 profile / obs 等多個子網域，
     寫太死的話同步會壞掉而且**看起來像 LINE 換頭像沒生效**。 */
  if v_url !~ '^https://[a-z0-9-]+\.line-scdn\.net/' then
    return jsonb_build_object('ok', false, 'reason', 'url_not_line');
  end if;

  update members
     set avatar_url = v_url, updated_at = now()
   where id = p_member_id and deleted_at is null;

  /* 🔴 `update ... where` 之後一定要看 FOUND ——
     `register_member_tx` 就是漏了這一步而謊報成功（2026-08-26 修）。 */
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  return jsonb_build_object('ok', true, 'avatar_url', v_url);
end $function$;


/* ── ④b get_my_avatar_tx —— 取代直接查表 ──────────────
   🔴 **這一支存在的理由是硬規則 4。**
   `lib/avatar.js` 與 `lib/social.js` 現在都用
   `supabase.from('members').select('avatar_source, …')`，
   而 `members` 的 RLS 是 `org_id = current_org_id()`。
   會員 App 用 anon key、沒有 auth session ⇒ `current_org_id()` 回 null
   ⇒ **查回空陣列而且不報錯**。
   → 也就是整套頭像的讀取端**從來沒有運作過**，
     只是因為還沒有人有照片，所以看不出來。

   ⚠ `p_member_id` 是前端傳的，所以任何人都查得到任何人的頭像設定 ——
     那是待辦 14 既有的問題，**不因這支而變糟**：
     這些欄位本來就會出現在 `list_buddies_tx` 那類清單裡（頭像是公開的）。
     刻意**不回傳** `avatar_blocked` 以外的任何個資。 */
create or replace function public.get_my_avatar_tx(p_member_id uuid)
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select jsonb_build_object(
           'ok', true,
           'avatar_source',     m.avatar_source,
           'avatar_photo_path', m.avatar_photo_path,
           'avatar_bear',       m.avatar_bear,
           'avatar_url',        m.avatar_url,
           'avatar_blocked',    m.avatar_blocked,
           'rank',              m.rank)
    from members m
   where m.id = p_member_id and m.deleted_at is null;
$function$;


/* ── 授權 ────────────────────────────────────────────
   🔴 **`anon` 有兩條路進來，兩條都要收**（2026-08-29 第一次跑只收了一條）。

   | 來源 | 誰是這樣 | 要怎麼收 |
   |---|---|---|
   | **PUBLIC 繼承** —— Postgres 建函式的預設 | 那 12 支管理函式（硬規則 2.6） | `revoke from public` |
   | **default privileges 明確授權** | **在 `public` schema 新建的每一支** | `revoke from anon` |

   Supabase 在這個專案設了：
   ```sql
   alter default privileges in schema public
     grant execute on functions to anon, authenticated, service_role;
   ```
   ⇒ **每一支新函式一建立就是 anon 叫得動的**，而且是明確授權。

   🎯 所以第一次跑的時候，`revoke ... from public` 成功了（PUBLIC 那一行確實消失），
     但驗證仍然回「anon=🔴 有」—— 兩者同時發生而且都不是 bug。
     ⚠ 這跟上一次剛好相反：那次收了 anon 卻沒效果（因為來源是 PUBLIC），
       這次收了 PUBLIC 卻沒效果（因為來源是明確授權）。
     🔴 **`has_function_privilege` 對兩種都回 true，分不出來** ——
       它能驗結果，不能拿來判斷「要收哪一個」。 */
revoke execute on function public.set_line_avatar_tx(uuid, text) from public;
revoke execute on function public.set_line_avatar_tx(uuid, text) from anon, authenticated;
grant  execute on function public.set_line_avatar_tx(uuid, text) to service_role;

revoke execute on function public.get_my_avatar_tx(uuid) from public;
grant  execute on function public.get_my_avatar_tx(uuid) to anon, authenticated, service_role;


/* ============================================================
   驗證（單一 SELECT）

   🎯 **靜態檢查不夠 —— 要真的執行一次**（硬規則 7：
     `CREATE FUNCTION` 不檢查函式體，「跑完沒報錯」不等於「函式能用」）。
   → ③ 是一組交易內的行為測試，做完回滾。

   ⚠ **測試的 raise 不可以往外拋** —— Supabase SQL Editor 是單一交易，
     拋出去會把上面整份 DDL 一起回滾掉。
     所以用 `BEGIN … EXCEPTION` 的隱含 savepoint 接住。
   ⚠ 訊息**設在 exception 處理器裡**（硬規則 3.9）——
     `set_config(..., true)` 寫在 raise 之前會跟著被回滾，最後印出空白。
     PL/pgSQL 的變數不受交易回滾影響，所以先存進變數再在處理器裡吐出來。
   ============================================================ */
do $$
declare
  v_id   uuid := '69016205-afde-4036-95a6-5893c9d0e5fe';   -- 創辦人（Jim）
  v_msg  text := '';
  r      jsonb;
  v_src  text; v_bear text; v_url text;
begin
  begin
    -- T1：還沒同步過 LINE 頭像時，選 line 應該被擋
    r := set_avatar_tx(v_id, 'line');
    v_msg := v_msg || case when r->>'reason' = 'line_avatar_missing'
                           then '① 未同步時選 LINE　✅ 擋下（line_avatar_missing）'
                           else '① 未同步時選 LINE　🔴 竟然通過：' || r::text end;

    -- T2：🎯 正對照 —— 非 LINE 網域必須被拒
    r := set_line_avatar_tx(v_id, 'https://evil.example.com/x.png');
    v_msg := v_msg || E'\n' || case when r->>'reason' = 'url_not_line'
                           then '② 非 LINE 網域　　　✅ 擋下（url_not_line）'
                           else '② 非 LINE 網域　　　🔴 竟然通過：' || r::text end;

    -- T3：先記一隻小熊，等一下要證明切走不會忘記
    perform set_avatar_tx(v_id, 'bear', null, 'gold');

    -- T4：寫入 LINE 頭像
    r := set_line_avatar_tx(v_id, 'https://profile.line-scdn.net/0hTESTONLY');
    v_msg := v_msg || E'\n' || case when (r->>'ok')::boolean
                           then '③ 寫入 LINE 頭像　　✅ ok'
                           else '③ 寫入 LINE 頭像　　🔴 失敗：' || r::text end;

    -- T5：這次選 line 應該成功
    r := set_avatar_tx(v_id, 'line');
    select avatar_source, avatar_bear, avatar_url into v_src, v_bear, v_url
      from members where id = v_id;
    v_msg := v_msg || E'\n' || case when (r->>'ok')::boolean and v_src = 'line'
                           then '④ 切到 LINE 頭像　　✅ avatar_source=line'
                           else '④ 切到 LINE 頭像　　🔴 ' || coalesce(v_src,'null') || ' / ' || r::text end;

    -- T6：🎯 正對照 —— 切到 line 不可以把小熊的記憶清掉
    v_msg := v_msg || E'\n' || case when v_bear = 'gold'
                           then '⑤ 切走不忘記小熊　✅ avatar_bear 仍是 gold'
                           else '⑤ 切走不忘記小熊　🔴 變成 ' || coalesce(v_bear,'null') end;

    raise exception 'rollback_on_purpose';
  exception when others then
    if sqlerrm = 'rollback_on_purpose' then
      perform set_config('migi.avatar_test', v_msg, true);
    else
      perform set_config('migi.avatar_test',
        v_msg || E'\n🔴 測試中途拋錯：' || sqlerrm, true);
    end if;
  end;
end $$;

select 序, 項目, 內容 from (

  select 1 as 序, '① avatar_source 的允許值' as 項目,
         (select pg_get_constraintdef(c.oid) from pg_constraint c
            join pg_class t on t.oid = c.conrelid
           where t.relname = 'members' and c.conname = 'members_avatar_source_chk') as 內容

  union all
  /* ⚠ 同時印「能不能叫」與「授權從哪來」——
     只看 has_function_privilege 的話，收錯方向會看不出來（見授權段的說明）。 */
  select 2, '② 授權（set_line_avatar_tx 不可以有 anon）',
         (select string_agg(p.proname || '　anon=' ||
                   case when has_function_privilege('anon', p.oid, 'execute') then '🔴 有' else '✅ 無' end
                 || '（明確=' || case when exists (select 1 from aclexplode(coalesce(p.proacl,'{}')) a
                                        where a.grantee = 'anon'::regrole::oid and a.privilege_type='EXECUTE')
                                      then 'Y' else 'N' end
                 || '　PUBLIC=' || case when (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                                        where a.grantee = 0 and a.privilege_type='EXECUTE'))
                                      then 'Y' else 'N' end || '）'
                 || '　service_role=' ||
                   case when has_function_privilege('service_role', p.oid, 'execute') then '有' else '🔴 無' end,
                 E'\n' order by p.proname)
            from pg_proc p
           where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
             and p.proname in ('set_line_avatar_tx','get_my_avatar_tx','set_avatar_tx'))
         || E'\n  ⚠ get_my_avatar_tx 與 set_avatar_tx 要有 anon，set_line_avatar_tx 不可以有'

  union all
  select 3, '③ 🎯 行為測試（交易內執行後回滾）',
         coalesce(nullif(current_setting('migi.avatar_test', true), ''), '🔴 沒有拿到測試結果')

  union all
  select 4, '④ set_my_avatar_tx 應該已經不存在',
         case when exists (select 1 from pg_proc p
                            where p.pronamespace = 'public'::regnamespace
                              and p.proname = 'set_my_avatar_tx')
              then '🔴 還在' else '✅ 已刪除' end

  union all
  select 5, '⑤ 🎯 正對照：資料回滾了沒（創辦人應該還是 bear、avatar_url 還是 null）',
         (select 'avatar_source=' || coalesce(avatar_source,'null')
              || '　avatar_bear=' || coalesce(avatar_bear,'null')
              || '　avatar_url=' || coalesce(left(avatar_url,30),'null')
              || case when avatar_source = 'bear' and avatar_url is null
                      then '　✅ 測試沒有留下痕跡'
                      else '　🔴 測試資料留下來了' end
            from members where id = '69016205-afde-4036-95a6-5893c9d0e5fe')

) x order by 序;
