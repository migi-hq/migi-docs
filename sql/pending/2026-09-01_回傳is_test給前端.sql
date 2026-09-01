/* ============================================================
   `register_member_tx` 與 `get_my_profile_tx` 回傳 `is_test` ＋ `live`
   2026-09-01 · MIGI　（待辦 37）

   ── 兩個欄位解決的是不同的一半 ──────────────────────
   | | 回答什麼 | 誰決定 |
   |---|---|---|
   | `is_test` | **這個人**是不是測試帳號 | 🔴 **人**（欄位 DEFAULT false） |
   | `live`    | **整間店**上線了沒有 | ✅ **事實**（`orgs.live_from`） |

   🔴 **只有 `is_test` 是不夠的**：它預設 false，所以**新的測試帳號
     預設會被當成真實客人**，而且沒有任何症狀 ——
     2026-08-29 就發生了（創辦人用 LIFF 註冊出 `山劍八舞澤`）。
   🎯 **而「還沒上線」不是猜的，是定義**：`live_from` 是 null 就是還沒開店，
     那時**沒有任何人是真實客人**。12 支 `v_real_*` 一直用這個事實。
   ⇒ 前端的判準變成 `!live || is_test`：
     · **上線前** → 一律測試，**沒有人需要記得標記任何帳號**
     · **上線後** → 只剩自己人那幾個要標一次

   ── 問題 ────────────────────────────────────────────
   `migi-web/src/lib/analytics.js` 用一份**寫死的 uuid 清單**判斷
   誰是測試帳號。資料庫早就有 `members.is_test`，但**沒有任何 RPC
   把它回傳給前端**，所以前端只能自己維護第二份真相 —— 而它會漂。

   🔴 **2026-09-01 就漂了一次**：創辦人 8/29 用 LIFF 註冊出
     `69016205 山劍八舞澤`（`is_test = true`），
     但那份清單不知道 ⇒ 他在 App 上的每一個動作都不算測試。
   🟢 今天零影響（`ANALYTICS.toGA4` 與 `toMeta` 都是 false，一筆都沒送出去），
     而 `app_events.is_test` 是 `log_app_event_tx` **寫入當下去查 members**
     推的，跟前端清單無關 —— 所以資料庫端也沒被汙染。
   🔴 **但 `toGA4` 改成 true 的那一刻它就變成洞**，而 GA4 的資料洗不掉，
     還會污染廣告受眾學習。→ 待辦 37 因此明訂「開 GA4 之前先做完這一項」。

   ── 🔴 為什麼兩支都要改（只改註冊那一支等於沒修）──────
   山劍八舞澤是**註冊完約一小時後**才被標成 `is_test = true` 的
   （`app_events` 裡 2 筆 false、632 筆 true，分界在 8/29 07:00）。
   ⇒ 只在註冊時回傳一次，那個值就是**註冊當下的快照，之後再也不會更新**，
     他仍然會被當成真實客人。
   → 同 CLAUDE.md 的快取鐵律：**只能有一個寫入點，而且要會自我校正。**
     `get_my_profile_tx` 每次被讀到，前端就順手校正一次（跟暱稱同一個做法）。

   ── ✅ 為什麼「怎麼區別真實帳號」不需要新機制 ──────────
   ```
   members.is_test  DEFAULT false
   register_member_tx  完全不碰它
   ```
   ⇒ **真實客人註冊 → 自動 false；測試帳號 → 要有人手動設 true。**
   資料庫本來就是唯一真相，這份 SQL 只是讓前端讀得到它。

   ✅ 兩支簽名都不變 → `CREATE OR REPLACE`，不掉 GRANT，前端可先部署。
   ⚠ 撈全文重建（硬規則：同一支要改三處以上不要堆 DO 區塊）。
   ============================================================ */

create or replace function public.register_member_tx(
  p_org_id uuid, p_display_name text, p_phone text default null,
  p_line_user_id text default null, p_home_store_id uuid default null,
  p_created_by uuid default null
) returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_member   members%rowtype;
  v_existing uuid;
  v_action   text;
  v_name     text;
  v_cur_line text;
begin
  if p_org_id is null then
    raise exception 'org_id required';
  end if;

  v_name := public.migi_norm_nickname(coalesce(p_display_name, ''));
  if v_name = '' then
    raise exception 'display_name required';
  end if;

  if v_name ~* '(migi|官方|客服|店長|管理員|系統|admin)' then
    raise exception 'display_name_reserved';
  end if;

  if char_length(v_name) > 12 then
    raise exception 'display_name too long (max 12)';
  end if;

  /* ★ 2026-08-28：手機一律正規化後再用。
       🔴 uq_members_phone 是字串比對 —— 0912-345-678 與 0912345678
         會被當成兩個人，rebound 路徑就永遠走不到。
       ⚠ 查詢與寫入都要用正規化後的值，只做其中一邊等於沒做。 */
    if coalesce(trim(p_phone),'') <> '' then
      p_phone := public.migi_norm_phone(p_phone);
      if p_phone is null then
        raise exception 'phone_invalid';
      end if;
    end if;

  if coalesce(trim(p_phone),'') = '' and coalesce(trim(p_line_user_id),'') = '' then
    raise exception 'need phone or line_user_id';
  end if;

  -- 這個 LINE 帳號已經是某個會員 → 就是他，不新建
  if p_line_user_id is not null then
    select id into v_existing from members
      where org_id = p_org_id and line_user_id = p_line_user_id and deleted_at is null
      limit 1;
    if v_existing is not null then
      select * into v_member from members where id = v_existing;
      /* ★ 2026-09-01：回傳 `is_test`（待辦 37）。
         ⚠ 這條路是「老客人再進來」，而他的 is_test **可能是註冊之後才改的**
           —— 所以這裡回的是**現值**不是註冊當下的值。 */
      return jsonb_build_object('action','existing_line','member_id',v_member.id,
        'display_name',v_member.display_name,'phone',v_member.phone,
        'is_test',v_member.is_test);
    end if;
  end if;

  -- 手機對得上既有會員 → 綁上去，不新建。
  -- 🔴 這條路正是「先在櫃檯註冊、後來才用 LINE」的客人要走的，
  --   也是四個測試帳號接 LINE 時要走的。它不是例外，是正式流程的一部分。
  if p_phone is not null then
    select id into v_existing from members
      where org_id = p_org_id and phone = p_phone and deleted_at is null
      limit 1;
    if v_existing is not null then
      if p_line_user_id is not null then
        select line_user_id into v_cur_line from members where id = v_existing;

        /* ★ 2026-08-26：看 FOUND，不要無條件回報成功。
           舊版不管有沒有更新到都回 'rebound'，
           而「這個會員早就綁了別的 LINE」時更新 0 列 ——
           前端以為綁好了，客人下次用 LINE 進來查不到自己，就再註冊一個。 */
        if v_cur_line = p_line_user_id then
          v_action := 'existing_line';   -- 同一個人重試／併發，是他自己的帳號
        else
          /* 🔴 2026-08-30 堵 A3：手機對得上**不再自動綁**。
             不分「對方已綁別的 LINE」與「對方還沒綁」—— 對客人是同一件事：
             這支號碼屬於一個不是你的帳號。**一個字都不寫。**
             ⚠ 這條路**不回 `is_test`**（也不回 member_id）——
               那是別人的帳號，一個欄位都不該洩漏。 */
          return jsonb_build_object('action','phone_taken',
            'message','這支手機已經是 MIGI 會員了。請用原本的 LINE 帳號登入，或在櫃檯出示這個畫面由店員協助綁定。');
        end if;
      else
        v_action := 'existing_phone';
      end if;
      if v_action = 'existing_phone' then
        return jsonb_build_object('action','existing_phone',
          'message','這支手機已經是 MIGI 會員了，請用原本的 LINE 帳號登入，或洽櫃檯協助');
      end if;
      select * into v_member from members where id = v_existing;
      return jsonb_build_object('action',v_action,'member_id',v_member.id,
        'display_name',v_member.display_name,'phone',v_member.phone,
        'is_test',v_member.is_test);
    end if;
  end if;

  insert into members (org_id, display_name, phone, line_user_id, home_store_id, created_by)
  values (p_org_id, v_name, nullif(trim(p_phone),''), p_line_user_id, p_home_store_id, p_created_by)
  returning * into v_member;

  /* ⚠ 新建的一定是 `false`（欄位 DEFAULT false，這支完全不碰它）——
     **那正是「怎麼區別真實帳號」的答案**：真實客人自動 false，
     測試帳號要有人手動設 true。這裡照樣回傳，讓前端不必知道這個規則。 */
  return jsonb_build_object('action','created','member_id',v_member.id,
    'display_name',v_member.display_name,'phone',v_member.phone,
    'is_test',v_member.is_test);
end;
$function$;


-- ── `get_my_profile_tx`：讓快取會自我校正 ──────────────
create or replace function public.get_my_profile_tx(p_org_id uuid, p_member_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare v jsonb;
begin
  select jsonb_build_object(
    'id', m.id, 'nickname', m.display_name,
    /* ★ 2026-08-30：改回完整號碼（原本是 left(4)||'***'||right(3)）。
       遮罩答不出「這是我的哪一支」，而那是這一列唯一的用途。 */
    'phone', m.phone,
    'phone_verified', (m.phone_verified_at is not null),
    'rank', m.rank, 'title', m.title,
    'likes_count', m.likes_count, 'avatar_url', m.avatar_url,
    -- ★ 2026-08-29：頭像有三個來源，只回 avatar_url 的話
    --   個人檔案永遠畫段位熊（而且不會報錯）。
    'avatar_source', m.avatar_source,
    'avatar_photo_path', m.avatar_photo_path,
    'avatar_bear', m.avatar_bear,
    'tier', m.tier,
    'app_state', coalesce(s.bear, '{}'::jsonb),
    'titles_unlocked', coalesce(s.titles, '[]'::jsonb),
    'about', m.about,
    'sched', m.sched,
    'style', m.style,
    -- ★ 2026-08-26 新增。生日招待是已承諾的權益，
    --   而在這之前前端讀不到現值，填完看起來像沒存成功。
    'birthday', m.birthday, 'gender', m.gender,
    'see_score', m.see_score,
    'baby_tile', m.baby_tile,
    'home_store_id', m.home_store_id,
    'home_store_name', st.name,
    /* ★ 2026-09-01：`is_test`（待辦 37）。
       🔴 **這一個才是真正解決問題的那一個。**
         只在註冊時回傳的話，值會停在註冊當下 ——
         而創辦人是註冊完一小時後才被標成測試的。
       ⚠ 前端要把它當成「每次讀到就覆蓋本機快取」，
         同 CLAUDE.md 的快取鐵律：只能有一個寫入點，而且要會自我校正。
       ⚠ 它不是 PII，也不影響畫面 —— 純粹是埋點要不要送出去的閘門。 */
    'is_test', m.is_test,
    /* ★ 2026-09-01：**上線了沒有**。
       🔴 **這一格解決的是 `is_test` 解決不了的那一半。**
         `is_test` 是**人做的決定**（預設 false），所以**新的測試帳號
         預設會被當成真實客人**，而那沒有任何症狀。
       🎯 但「還沒上線」不是猜的，是定義：
       ```
       orgs.live_from is null  ⇒  還沒開店  ⇒  現在沒有任何人是真實客人
       ```
       那正是 12 支 `v_real_*` 一直在用的同一個事實
       （`created_at >= coalesce(live_from,'infinity')`）——
       這裡只是讓前端也吃得到它。
       ⇒ 前端的判準變成 `還沒上線 || is_test`：
         · **上線前**：不管誰、有沒有標記，一律是測試 ⇒ **沒有人需要記得**
         · **上線後**：只剩自己人那幾個帳號要標一次
       ⚠ **fail-safe 的方向是對的**：忘了標，頂多是上線後自己的操作
         進了 GA4；而不是上線前幾個月的開發噪音全部進去。 */
    'live', (o.live_from is not null and now() >= o.live_from)
  ) into v
  from members m
  left join member_app_state s on s.member_id = m.id
  left join stores st on st.id = m.home_store_id
  /* ⚠ `join` 不是 `left join`：`members.org_id` 是 NOT NULL 且有外鍵，
     org 一定存在。用 left join 反而會讓「org 不見了」變成靜默的 null。 */
  join orgs o on o.id = m.org_id
  where m.id = p_member_id and m.org_id = p_org_id and m.deleted_at is null;
  if v is null then raise exception '會員不存在'; end if;
  return v;
end $function$;


-- ── 驗證 ───────────────────────────────────────────────
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_out text := ''; r jsonb; p jsonb; v_id uuid;
begin
  begin
    ---- ① 新註冊 → is_test = false ---------------------
    r := public.register_member_tx(v_org, '測新客', '0987000111', 'U_test_newbie');
    v_id := (r->>'member_id')::uuid;
    v_out := v_out || E'\n' || '① 新註冊 → is_test = false' || E'\t' ||
      case when r->>'action' = 'created' and (r->>'is_test')::boolean = false
           then '✅ created ／ false（真實客人自動就是 false）'
           else '🔴 ' || r::text end;

    ---- ② 事後標成測試 → 再進來要拿到 true --------------
    /* 🔴 **這一格是整份 SQL 的重點。** 創辦人就是註冊完一小時後才被標記的，
       只回註冊當下的值等於沒修。 */
    update members set is_test = true where id = v_id;
    r := public.register_member_tx(v_org, '測新客', '0987000111', 'U_test_newbie');
    v_out := v_out || E'\n' || '② 🎯 事後標成測試 → 再登入拿到 true' || E'\t' ||
      case when r->>'action' = 'existing_line' and (r->>'is_test')::boolean = true
           then '✅ existing_line ／ true（回的是現值不是註冊當下）'
           else '🔴 ' || r::text end;

    ---- ③ get_my_profile_tx 也要回 ---------------------
    p := public.get_my_profile_tx(v_org, v_id);
    v_out := v_out || E'\n' || '③ 🎯 個人檔案也回 is_test（快取自我校正）' || E'\t' ||
      case when (p->>'is_test')::boolean = true then '✅ true'
           else '🔴 ' || coalesce(p->>'is_test','(沒有這個鍵)') end;

    /* 🔴 **正對照：改回 false 也要跟著變。**
       少了這一格，一個「寫死回 true」的實作會讓 ②③ 都變綠。 */
    update members set is_test = false where id = v_id;
    p := public.get_my_profile_tx(v_org, v_id);
    v_out := v_out || E'\n' || '④ 正對照：改回 false 也跟著變' || E'\t' ||
      case when (p->>'is_test')::boolean = false then '✅ false'
           else '🔴 ' || coalesce(p->>'is_test','null') || ' —— 大概寫死了' end;

    ---- ⑤ 正對照：不該洩漏的路徑仍然不洩漏 --------------
    /* `phone_taken` 是「這支號碼屬於一個不是你的帳號」——
       那是別人的帳號，`member_id` 與 `is_test` 一個都不該回。 */
    r := public.register_member_tx(v_org, '測搶號', '0987000111', 'U_test_other');
    v_out := v_out || E'\n' || '⑤ 正對照：phone_taken 仍然不洩漏任何欄位' || E'\t' ||
      case when r->>'action' = 'phone_taken'
                and not (r ? 'member_id') and not (r ? 'is_test')
           then '✅ 只有 action 與 message'
           else '🔴 ' || r::text end;

    ---- ⑥ 正對照：兩支的原有欄位一個都沒少 --------------
    v_out := v_out || E'\n' || '⑥ 正對照：個人檔案原有 24 個鍵都在' || E'\t' ||
      case when p ?& array['id','nickname','phone','phone_verified','rank','title',
                           'likes_count','avatar_url','avatar_source','avatar_photo_path',
                           'avatar_bear','tier','app_state','titles_unlocked','about',
                           'sched','style','birthday','gender','see_score','baby_tile',
                           'home_store_id','home_store_name']
           then '✅ 都在（共 ' || (select count(*) from jsonb_object_keys(p)) || ' 個）'
           else '🔴 掉了' end;
    v_out := v_out || E'\n' || '⑦ 正對照：註冊回傳原有欄位都在' || E'\t' ||
      (select case when x ?& array['action','member_id','display_name','phone']
                   then '✅ 都在' else '🔴 掉了' end
         from (select public.register_member_tx(v_org,'測乙客',null,'U_test_b') as x) t);

    ---- ⑧ 授權 -----------------------------------------
    v_out := v_out || E'\n' || '⑧ 正對照：兩支的授權沒被動到' || E'\t' ||
      (select case when count(*) filter (where has_anon) = 2
                   then '✅ 兩支的 anon 都還在'
                   else '🔴 只有 ' || count(*) filter (where has_anon) || ' 支' end
         from (select exists (select 1 from aclexplode(p.proacl) a
                               where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE') as has_anon
                 from pg_proc p where p.pronamespace='public'::regnamespace
                  and p.proname in ('register_member_tx','get_my_profile_tx')) z);

    ---- ⑨⑩⑪ `live`：上線了沒有 -------------------------
    /* 🔴 這一組驗的是 `is_test` **解決不了的那一半**：
       `is_test` 預設 false ⇒ 新的測試帳號預設會被當成真實客人。
       而「還沒上線」不是猜的 —— `live_from` 是 null 就是還沒開店。 */
    p := public.get_my_profile_tx(v_org, v_id);
    v_out := v_out || E'\n' || '⑨ live_from 是 null → live = false' || E'\t' ||
      case when (p->>'live')::boolean = false
           then '✅ false（上線前一律當測試，沒有人需要記得標記）'
           else '🔴 ' || coalesce(p->>'live','(沒有這個鍵)') end;

    /* 🔴 **正對照缺一不可**：只驗「null → false」的話，
       一支「永遠回 false」的實作也會過，而那會讓上線之後
       **每一個真實客人都被當成測試** —— 症狀是 GA4 永遠沒有資料。 */
    update orgs set live_from = now() - interval '1 day' where id = v_org;
    p := public.get_my_profile_tx(v_org, v_id);
    v_out := v_out || E'\n' || '⑩ 🎯 正對照：設成昨天 → live = true' || E'\t' ||
      case when (p->>'live')::boolean = true then '✅ true'
           else '🔴 ' || coalesce(p->>'live','null') || ' —— 大概寫死 false 了' end;

    /* ⚠ 未來日期也要是 false —— 「設好了但還沒到」跟「沒設」是同一件事。
       這一格防的是把條件寫成 `live_from is not null` 而忘了比時間。 */
    update orgs set live_from = now() + interval '3 days' where id = v_org;
    p := public.get_my_profile_tx(v_org, v_id);
    v_out := v_out || E'\n' || '⑪ 正對照：設成三天後 → 還是 false' || E'\t' ||
      case when (p->>'live')::boolean = false then '✅ false（時間也要比，不是只看有沒有值）'
           else '🔴 true —— 大概只判斷了 is not null' end;

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.istest', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.istest', true), E'\n')) as x
 where coalesce(x,'') <> '';
