/* ============================================================
   set_avatar_tx 加 `p_bear` —— 讓「選了哪一隻小熊」真的存下來
   2026-08-29

   ── 為什麼 ──────────────────────────────────────────
   🔴 現在「選了哪一隻小熊」**根本沒進資料庫**：
   ```
   rewards.jsx → useBearAvatar() → set_avatar_tx(member,'bear')   只存 source
               → setMyAvatarLocal(url, …)                          只寫 localStorage
   ```
   下次載入 `avatarSrc()` 回的是 `rankBearSrc(member.rank)` ——
   **段位對應的那一隻**。換一台裝置就變回去了。

   ── 頭像的十個選項，全部塞進現有的兩個 source 值 ──────
   | 選中 | avatar_source | avatar_bear | avatar_photo_path |
   |---|---|---|---|
   | 預設（通用小熊） | bear | **null** | — |
   | 段位熊 ×7 | bear | `'金牌熊'` | — |
   | LINE 大頭貼 | photo | — | `{id}/line.webp` |
   | 我的照片 | photo | — | `{id}/{時間戳}.webp` |

   ✅ **`members_avatar_source_chk`（只有 bear/photo）完全不用改。**

   🔴 **`avatar_bear = null` 的語意改變了**：
     舊：沒選過 → 依 `rank` 推導 → 段位熊
     新：**預設（通用小熊 `default-avatar.svg`）**
   ⚠ 那是刻意的 —— 新註冊會員的預設頭像是通用小熊，不是銅牌熊。
     現有四位測試會員的 `avatar_bear` 都是 null，所以他們會從
     銅牌熊變成通用小熊。**那正是預期的結果。**

   ── ⚠ 這支改簽名，所以要 DROP ────────────────────
   `CREATE OR REPLACE` 加參數會建出**多載**而不是取代（硬規則 2）。
   🔴 而 **DROP 會把 GRANT 一起丟掉** —— 檔案結尾一定要補回來。
   撈過現況：`anon` / `authenticated` / `service_role` 三個都有。
   ============================================================ */

drop function if exists public.set_avatar_tx(uuid, text, text);

create or replace function public.set_avatar_tx(
  p_member_id uuid,
  p_source    text,
  p_path      text default null,
  p_bear      text default null      -- ★ 新增：小熊造型名稱。null = 預設（通用小熊）
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_blocked boolean;
  v_bear    text := nullif(btrim(coalesce(p_bear, '')), '');
begin
  if p_source not in ('bear','photo') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_source');
  end if;

  select avatar_blocked into v_blocked from members where id = p_member_id;
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
  else
    /* 切到小熊：照片保留不刪，之後可隨時切換回來。
       ★ 同時記住是哪一隻（null = 預設的通用小熊）。 */
    update members
       set avatar_source = 'bear', avatar_bear = v_bear, updated_at = now()
     where id = p_member_id;
  end if;

  return jsonb_build_object('ok', true, 'source', p_source, 'bear', v_bear);
end $function$;

/* 🔴 DROP 把 GRANT 丟掉了，補回來（撈過現況，原本就是這三個）。 */
grant execute on function public.set_avatar_tx(uuid, text, text, text)
  to anon, authenticated, service_role;


/* ============================================================
   驗證（單一 SELECT）

   ── 該看到什麼 ──────────────────────────────────────
   ① 版本數 = 1（沒有建出多載 —— 那正是 DROP 要防的）
   ② 三個角色的 EXECUTE 都在（DROP 之後有補回來）
   ③ 🎯 四個子測試，含正對照（硬規則 3.55）：
      · 選段位熊 → avatar_bear 真的存進去了
      · 選預設   → avatar_bear 被清成 null
      · 切到照片 → **avatar_bear 不受影響**（那是刻意的）
      · 太長的值 → 擋下
   ④ 回滾乾淨：四位會員的 avatar_bear 仍全部是 null
   ============================================================ */

do $$
declare
  v_m uuid := 'd73fdac2-d6b9-4b8a-bcff-b19c2786056f';
  v_msg text := '';
  r jsonb;
  v_bear text; v_src text; v_path text;
begin
  begin
    -- ① 選段位熊
    r := set_avatar_tx(v_m, 'bear', null, '金牌熊');
    select avatar_bear, avatar_source into v_bear, v_src from members where id = v_m;
    v_msg := '① 選「金牌熊」→ ok=' || coalesce(r->>'ok','?')
          || '　存進去的 avatar_bear=' || coalesce(quote_literal(v_bear),'null')
          || case when v_bear = '金牌熊' then '　✅' else '　🔴 沒存到' end;

    -- ② 切到照片：avatar_bear 不該被清掉
    r := set_avatar_tx(v_m, 'photo', v_m::text || '/測試.webp', null);
    select avatar_bear, avatar_source, avatar_photo_path into v_bear, v_src, v_path
      from members where id = v_m;
    v_msg := v_msg || E'\n② 切到照片 → source=' || coalesce(v_src,'?')
          || '　avatar_bear=' || coalesce(quote_literal(v_bear),'null')
          || case when v_bear = '金牌熊' then '　✅ 小熊的記憶保住了'
                  else '　🔴 被清掉了（切走不該忘記）' end;

    -- ③ 🎯 正對照：切回「預設」→ avatar_bear 必須變成 null
    r := set_avatar_tx(v_m, 'bear', null, null);
    select avatar_bear into v_bear from members where id = v_m;
    v_msg := v_msg || E'\n③ 選「預設」→ avatar_bear=' || coalesce(quote_literal(v_bear),'null')
          || case when v_bear is null then '　✅ 清成 null（= 通用小熊）'
                  else '　🔴 應該要是 null' end;

    -- ④ 太長的值要擋下
    r := set_avatar_tx(v_m, 'bear', null, repeat('熊', 21));
    v_msg := v_msg || E'\n④ 21 個字的造型名 → ok=' || coalesce(r->>'ok','?')
          || '　reason=' || coalesce(r->>'reason','（無）')
          || case when (r->>'reason') = 'bear_too_long' then '　✅ 擋下'
                  else '　🔴 沒擋' end;

    raise exception 'rollback_on_purpose';
  exception
    when others then
      -- 硬規則 3.9：訊息一律設在處理器裡，設在 raise 之前會跟著被回滾
      if sqlerrm = 'rollback_on_purpose' then
        perform set_config('migi.bear', v_msg, true);
      else
        perform set_config('migi.bear', v_msg || E'\n🔴 拋錯：' || sqlerrm, true);
      end if;
  end;
end $$;

select 序, 項目, 內容 from (

  select 1 as 序, '① 版本數（應為 1，多載代表 DROP 沒生效）' as 項目,
         (select count(*)::text from pg_proc p
           where p.pronamespace='public'::regnamespace and p.prokind='f'
             and p.proname='set_avatar_tx') as 內容

  union all
  select 2, '② 授權（DROP 會丟 GRANT，要三個都在）',
         (select 'anon=' || case when has_function_privilege('anon', p.oid, 'execute') then '✅' else '🔴 掉了' end
              || '　authenticated=' || case when has_function_privilege('authenticated', p.oid, 'execute') then '✅' else '🔴 掉了' end
              || '　service_role=' || case when has_function_privilege('service_role', p.oid, 'execute') then '✅' else '🔴 掉了' end
            from pg_proc p
           where p.pronamespace='public'::regnamespace and p.prokind='f'
             and p.proname='set_avatar_tx')

  union all
  select 3, '③ 新簽名',
         (select pg_get_function_arguments(p.oid) from pg_proc p
           where p.pronamespace='public'::regnamespace and p.prokind='f'
             and p.proname='set_avatar_tx')

  union all
  select 4, '④ 四個子測試',
         coalesce(current_setting('migi.bear', true), '🔴 測試區塊沒執行')

  union all
  select 5, '⑤ 回滾乾淨（avatar_bear 應全部是 null）',
         (select string_agg(display_name || '　avatar_bear=' || coalesce(avatar_bear,'null')
                 || '　source=' || avatar_source, E'\n' order by created_at)
            from members where deleted_at is null)

) x order by 序;
