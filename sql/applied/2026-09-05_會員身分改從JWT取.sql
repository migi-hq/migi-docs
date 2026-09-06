/* ============================================================
   待辦 14 第二半：會員端 21 支 RPC 改成從 JWT 取身分
   2026-09-05 · MIGI 咪吉麻將

   ── 這一份修的洞 ──────────────────────────────────────
   在此之前會員端用 anon key，身分靠**前端送 `p_member_id`**
   ⇒ **知道任何一個會員 uuid 就能查他的錢包與完整消費明細**
     （買了什麼、花多少、什麼時間在店裡）。

   ✅ 第一半（`line-login` 的 `whoami` 順便發 Supabase session）
     2026-09-05 17:07 實機驗證通過：
     ```
     auth.users  line-u368caa…@member.migi.invalid
                 app_metadata.line_user_id ✅   migi_kind = member ✅
     current_member_id()  → 「咖勁凱」 ✅
     current_org_id()     → 11111111-… ✅
     沒有 JWT 時          → null ✅（正對照）
     ```

   ── 🔴 範圍：21 支，不是 CLAUDE.md 寫的「約 70 支」──────
   前端叫的 50 支裡，23 支收 `p_member_id`。**其中兩支要排除**：

   | 排除的 | 為什麼 |
   |---|---|
   | `get_my_orders_tx` | 🔴 **POS 也在叫，而且是查別人的**（會員查詢頁的「最近消費」，`migi-pos/src/lib/api.js:359`）。它名字叫 `my`，用途卻是「某位會員的」—— 覆寫身分會讓店員看到**自己的**消費 |
   | `log_app_event_tx` | 🔴 **POS 也在叫**（`analytics.js:124`）。而且埋點**不該硬失敗** —— 記錄壞掉不應該讓功能壞掉 |

   ⚠ 我一度寫下「這 23 支每一支都是會員自己的資料」——**那句話是錯的**，
     是掃了 `migi-pos/src` 才發現。**先查再說**（硬規則 3）。

   ── 做法：覆寫參數，不改簽名 ──────────────────────────
   與 2026-09-04 對 POS 那 14 支用過的是同一招：
   在函式體 `begin` 之後插入守衛與覆寫。
   ⇒ **簽名不動、前端一行不用改、不用 DROP、不會掉 GRANT、沒有部署順序。**

   🔴 **但與店員那次有一個關鍵差異**：
   ```
   店員：查不到 → null      （會員 App 也叫那些函式，硬擋會弄壞儲值）
   會員：查不到 → **拒絕**   （回 null 等於洞還開著）
   ```
   ⇒ 這一批用 `raise exception 'not_authenticated'`。

   ⚠ **`p_org_id` 刻意不動**（44 支收它）。
     身分鎖住之後，前端送錯的 org 只會**查不到東西**，不是安全問題
     —— 而少動 23 個地方就少 23 個出錯的機會。

   ── ⚠ 跑這份之前必須確認的事 ──────────────────────────
   🔴 **會員 App 在真實裝置上每次開機都拿得到 session。**
     跑完之後沒有 session 的人就叫不動這 21 支了。
     · LIFF 內（在 LINE 裡開）—— 2026-09-05 已驗
     · **一般瀏覽器開 `app.migi.tw`** —— 走 `liff.login()` 導向，
       是**另一條路**，要另外試一次
   ============================================================ */


-- ══════════════════════════════════════════════════════
-- ① 兩支 SQL 函式先改寫成 plpgsql
-- ══════════════════════════════════════════════════════
/* 🔴 SQL 函式**沒辦法 `raise`** —— 只能靠 `where` 條件讓它回空，
     而**回空且不報錯**正是這個專案一再記錄的最糟形狀
     （硬規則 4：RLS 濾成空陣列且不報錯 / 3.55：回 0 列同時是
      「正確阻擋」與「東西寫壞了」的症狀）。
   🎯 所以改寫成 plpgsql。**函式體一個字都沒改**，只是包一層
     `return ( … );` 並在前面加守衛 —— 那讓 diff 很小、也很好審。 */

create or replace function public.get_my_avatar_tx(p_member_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_me uuid;
begin
  v_me := public.current_member_id();
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  p_member_id := v_me;

  return (
    select jsonb_build_object(
             'ok', true,
             'avatar_source',     m.avatar_source,
             'avatar_photo_path', m.avatar_photo_path,
             'avatar_bear',       m.avatar_bear,
             'avatar_url',        m.avatar_url,
             'avatar_blocked',    m.avatar_blocked,
             'rank',              m.rank)
      from members m
     where m.id = p_member_id and m.deleted_at is null
  );
end $function$;


create or replace function public.get_my_games_tx(p_org_id uuid, p_member_id uuid, p_limit integer default 20)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_me uuid;
begin
  v_me := public.current_member_id();
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  p_member_id := v_me;

  return (
    with mine as (
      -- 從「我坐過的位子」反查場次 —— 不需要知道那桌是怎麼開的。
      -- （配桌與開桌的關聯在 match_queues.matched_session_id，這裡用不到）
      select s.id, s.mode, s.store_id, s.stake_level_id,
             s.game_type, s.flower, s.planned_rounds,
             s.started_at, s.activated_at, s.ended_at,
             sp.finish_rank      as my_rank,
             sp.score_points     as my_score,
             sp.charged_points   as my_charged,
             sp.fee_waived_amount as my_waived,
             sp.seat             as my_seat,
             -- ★ 2026-08-31：走勢圖用。M4 之前是 null。
             sp.rating_after     as my_rating_after,
             sp.settled_at       as my_settled_at
        from session_players sp
        join table_sessions s on s.id = sp.session_id
       where sp.member_id = p_member_id
         and sp.org_id    = p_org_id
         and s.org_id     = p_org_id
         and s.deleted_at is null
         and s.status     = 'completed'
       order by s.ended_at desc nulls last
       limit greatest(coalesce(p_limit, 20), 1)
    )
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'session_id', m.id,
        -- table_sessions.mode ∈ matched / private，就是配桌 vs 包桌
        'kind',   case when m.mode = 'private' then 'package' else 'match' end,
        -- 已收桌但還沒結算戰績 → pending；有名次 → settled
        -- （M4 之前全部都是 pending，那是預期的）
        'status', case when m.my_rank is not null then 'settled' else 'pending' end,
        'store',      st.name,
        'addr',       st.address,
        'game_type',  m.game_type,
        'flower',     m.flower,
        'rounds',     m.planned_rounds,     -- 整數，「幾將」由前端組字
        'stake',      sl.label,             -- 積分級距顯示名，例如 50/20、純娛樂麻將
        -- 開打時間用 activated_at（帶桌／真正開打），沒有才退回 started_at（開桌）
        'started_at', coalesce(m.activated_at, m.started_at),
        'ended_at',   m.ended_at,
        'duration_minutes',
          case when m.ended_at is not null
               then greatest(0, (extract(epoch from
                      (m.ended_at - coalesce(m.activated_at, m.started_at))) / 60)::int)
               else null end,
        'my_rank',          m.my_rank,      -- M4 之前是 null
        'my_score',         m.my_score,     -- M4 之前是 null
        'my_charged_points', m.my_charged,
        'my_fee_waived',     m.my_waived,   -- 暢打／店員／店長特調免收的金額
        'my_seat',           m.my_seat,
        /* ★ 2026-08-31 新增：走勢圖的兩個座標。
           ⚠ `settled_at` 不能用 `ended_at` 代替 —— 收桌與結算是兩個動作
             （名次可能是之後才登記的），而走勢圖畫的是**分數變動的時間**。 */
        'my_rating_after',   m.my_rating_after,
        'settled_at',        m.my_settled_at,
        'players', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'member_id',    p.member_id,
                   'nickname',     mem.display_name,
                   'rank',         mem.rank,
                   'avatar_url',        mem.avatar_url,
                   'avatar_source',     mem.avatar_source,
                   'avatar_photo_path', mem.avatar_photo_path,
                   'avatar_bear',       mem.avatar_bear,
                   'title',        mem.title,
                   'seat',         p.seat,
                   'finish_rank',  p.finish_rank,
                   'score_points', p.score_points,
                   'is_me',        p.member_id = p_member_id
                 ) order by coalesce(p.finish_rank, 99), p.seat nulls last, p.joined_at)
            from session_players p
            join members mem on mem.id = p.member_id
           where p.session_id = m.id), '[]'::jsonb)
      ) order by m.ended_at desc nulls last
    ), '[]'::jsonb)
    from mine m
    left join stores       st on st.id = m.store_id       and st.org_id = p_org_id
    left join stake_levels sl on sl.id = m.stake_level_id and sl.org_id = p_org_id
  );
end $function$;


-- ══════════════════════════════════════════════════════
-- ② 其餘 19 支 plpgsql：在 begin 之後插入守衛
-- ══════════════════════════════════════════════════════
/* ⚠ **這一段是冪等的**（2026-09-04 那份不是，重跑會再插一行）。
     判準是「函式體裡已經有 `p_member_id :=`」就跳過。 */
do $mig$
declare
  r        record;
  v_def    text;
  v_new    text;
  v_done   int := 0;
  v_skip   int := 0;
  v_fail   text := '';
  c_guard  constant text :=
    E'\n  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。\n' ||
    E'     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid\n' ||
    E'     就能看他的錢包與消費明細。\n' ||
    E'     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。\n' ||
    E'     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */\n' ||
    E'  if public.current_member_id() is null then\n' ||
    E'    raise exception ''not_authenticated'' using errcode = ''28000'';\n' ||
    E'  end if;\n' ||
    E'  p_member_id := public.current_member_id();\n';
begin
  for r in
    select p.oid, p.proname
      from pg_proc p
      join pg_language l on l.oid = p.prolang
     where p.pronamespace = 'public'::regnamespace
       and p.prokind = 'f'
       and l.lanname = 'plpgsql'
       and p.proname in (
         'get_my_availability_tx','get_my_profile_tx','get_my_rank_tx','get_my_stats_tx',
         'get_wallet_tx','mark_app_active_tx','save_app_state_tx','set_avatar_tx',
         'set_my_about_tx','set_my_availability_tx','set_my_baby_tile_tx','set_my_birthday_tx',
         'set_my_home_store_tx','set_my_nickname_tx','set_my_profile_basics_tx','set_my_sched_tx',
         'set_my_see_score_tx','set_my_style_tx','set_my_title_tx')
     order by p.proname
  loop
    v_def := pg_get_functiondef(r.oid);

    -- 冪等：已經有覆寫就跳過
    if v_def ~ 'p_member_id\s*:=' then
      v_skip := v_skip + 1;
      continue;
    end if;

    /* 🔴 只換**第一個獨立成行的 `begin`**（沒有 g 旗標 ⇒ 只換一次）。
       ⚠ 用「整行只有 begin」而不是 `\mbegin\M` —— 後者會打到
         中文註解裡的字，或 `begin` 出現在別的位置。
       ⚠ 定義裡是 CRLF，所以 `\r?` 不可省。 */
    if v_def !~ E'\r?\nbegin\r?\n' then
      v_fail := v_fail || r.proname || '（找不到獨立成行的 begin）, ';
      continue;
    end if;
    v_new := regexp_replace(v_def, E'(\r?\nbegin\r?\n)', '\1' || c_guard, '');

    execute v_new;
    v_done := v_done + 1;
  end loop;

  if v_fail <> '' then
    raise exception '🔴 有函式插不進去：% —— 整份回滾，不要留下改一半的狀態', v_fail;
  end if;
  perform set_config('migi.mig', v_done::text || '/' || (v_done + v_skip)::text, true);
end $mig$;


-- ══════════════════════════════════════════════════════
-- ③ current_staff() 排除會員 App 的 session
-- ══════════════════════════════════════════════════════
/* 🔴 **2026-09-05 驗證時發現的，而我原本斷言相反。**
   會員 session 建立之後，`current_staff()` 的 ② LINE 那條會match ——
   因為它問的是「這個 LINE 帳號有沒有掛在 staff 上」，
   而創辦人的答案就是**有**。

   ⚠ **那不是提權**（同一個人本來就是店員），
     **是最小權限被破壞**：會員 App 的 session 帶著它不需要的權力。
   🔴 而且是這次改動造成的 —— 在此之前會員 App 沒有 JWT，那裡回空。

   | | |
   |---|---|
   | 今天影響 | 1 個人（創辦人） |
   | 上線後 | **每一個用會員 App 的店員** |
   | 為什麼在意 | 會員 App 是 LIFF、攻擊面比 POS 大 |

   🎯 修法是**收窄**不是重寫：排除 `app_metadata.migi_kind = 'member'` 的 session。
     那個欄位是 `line-login` 發 session 時寫的，只有 service_role 能寫。
   ⚠ **刻意不拿掉 ② LINE 那條 OR**（雖然 `staff-login` 現在會綁 `auth_uid`
     所以它看起來多餘）—— 那是動承重牆，而我只有推理沒有測試。
     🔴 收窄的失敗是**大聲的**（店員登不進 POS），拿掉 OR 的失敗是安靜的。 */
create or replace function public.current_staff()
returns table(staff_id uuid, member_id uuid, store_id uuid, role text, name text)
language sql stable security definer set search_path to 'public'
as $function$
  select s.id, s.member_id, s.store_id, s.role, s.name
    from staff s
    -- ⚠ LEFT JOIN 不是 INNER：總部那條路的 staff.member_id 是 null，
    --   INNER JOIN 會把整列濾掉，而那正是 2026-08-23 修掉的 bug。
    left join members m
           on m.id = s.member_id
          and m.deleted_at is null
   where s.deleted_at is null
     /* 🔴 會員 App 的 session 不算店員身分（2026-09-05）。
        ⚠ 用 `is distinct from` 不是 `<>` —— 沒有這個 claim 時是 null，
          而 `null <> 'member'` 的結果是 **null 不是 true**
          ⇒ 會把**所有店員**擋在外面（同硬規則：NULL not in (…) 那個坑）。 */
     and coalesce(auth.jwt() -> 'app_metadata' ->> 'migi_kind', '') is distinct from 'member'
     and (
       -- ① 總部：Supabase Auth Email 帳號 → staff.auth_uid
       s.auth_uid = public.migi_jwt_uuid()
       -- ② 店員：LINE → members.line_user_id
       or m.line_user_id = public.migi_jwt_line_id()
     )
   -- 一個人可能在多店有 staff 列 → 取權限最高的那一列。
   -- ⚠ `owner` 與 `hq` 同級（`can()` 也是這樣看），所以並列第 1。
   order by case s.role when 'hq' then 1 when 'owner' then 1
                        when 'manager' then 2 else 3 end
   limit 1;
$function$;


-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
do $v$
declare
  v_out text := '';
  v_member_uid uuid; v_staff_uid uuid; v_line text;
  v_n int; v_err text;
begin
  ---- 取樣 ------------------------------------------------
  /* 🔴 取樣錯了那一格會「不出現」而不是變紅（2026-09-04 踩過）
     —— 所以找不到就出聲，不要 if ... then 安靜跳過。 */
  select u.id, u.raw_app_meta_data ->> 'line_user_id' into v_member_uid, v_line
    from auth.users u where u.email like 'line-%@member.migi.invalid' limit 1;
  select u.id into v_staff_uid
    from auth.users u where u.email like 'line-%@staff.migi.invalid' limit 1;

  if v_member_uid is null or v_staff_uid is null then
    perform set_config('migi.v',
      E'🔴 取樣失敗\t找不到會員或店員的 auth user —— 下面的結果不要解讀', true);
    return;
  end if;

  v_out := v_out || E'\n⓪ 改了幾支' || E'\t' ||
           coalesce(current_setting('migi.mig', true), '(沒有紀錄)') || '（其餘是已經改過的）';

  ---- ① 會員身分：叫得動而且拿到自己的資料 ----------------
  perform set_config('request.jwt.claims', json_build_object(
    'sub', v_member_uid::text, 'role', 'authenticated',
    'app_metadata', json_build_object('line_user_id', v_line, 'migi_kind', 'member'))::text, true);

  /* 🎯 **故意送一個不存在的 member_id** —— 如果覆寫有效，
     回來的必須是**自己的**資料而不是空的。
     ⚠ 那正是「只驗回傳不是 null」抓不到的東西：沒有覆寫的話
       這個假 id 會查不到人 ⇒ 回 null ⇒ 這一格就會紅。 */
  v_out := v_out || E'\n① 送假 id 仍回自己的頭像' || E'\t' ||
    case when (public.get_my_avatar_tx('00000000-0000-0000-0000-000000000000'::uuid) ->> 'ok') = 'true'
         then '✅ 覆寫生效（前端送什麼都沒用）'
         else '🔴 回了空 —— 覆寫沒生效' end;

  v_out := v_out || E'\n② 錢包也是自己的' || E'\t' ||
    case when public.get_wallet_tx('00000000-0000-0000-0000-000000000000'::uuid, 3) is not null
         then '✅ 有回傳' else '🔴 null' end;

  ---- ③ 🎯 正對照：會員 session 不再是店員 ----------------
  /* 🔴 只驗「會員叫得動」的話，一支**完全沒有守衛**的實作也會全綠。 */
  select count(*) into v_n from public.current_staff();
  v_out := v_out || E'\n③ 🎯 正對照：會員 session 不是店員' || E'\t' ||
    case when v_n = 0 then '✅ 0 列' else '🔴 仍然回了 ' || v_n || ' 列' end;

  ---- ④ 🎯 正對照：店員 session 還是店員（不可以被誤傷）----
  perform set_config('request.jwt.claims', json_build_object(
    'sub', v_staff_uid::text, 'role', 'authenticated',
    'app_metadata', json_build_object('line_user_id', v_line))::text, true);
  select count(*) into v_n from public.current_staff();
  v_out := v_out || E'\n④ 🎯 正對照：店員 session 仍是店員' || E'\t' ||
    case when v_n = 1 then '✅ 1 列 —— 沒有誤傷 POS'
         else '🔴 回了 ' || v_n || ' 列，POS 會登不進去' end;

  ---- ⑤ 🎯 正對照：沒有 JWT 一律拒絕 ----------------------
  /* 🔴 **這一格才是這份 SQL 的重點。** 前四格全綠但這一格紅，
     代表洞根本沒補起來。 */
  perform set_config('request.jwt.claims', '', true);
  begin
    perform public.get_my_avatar_tx('00000000-0000-0000-0000-000000000000'::uuid);
    v_out := v_out || E'\n⑤ 🎯 正對照：沒有 JWT 時' || E'\t' || '🔴 竟然沒被擋住';
  exception when others then
    get stacked diagnostics v_err = message_text;
    v_out := v_out || E'\n⑤ 🎯 正對照：沒有 JWT 時' || E'\t' ||
      case when v_err = 'not_authenticated' then '✅ 被擋住（not_authenticated）'
           else '🟡 被擋住但訊息是：' || v_err end;
  end;

  ---- ⑥ 掃全庫：這 21 支都有守衛了嗎 ----------------------
  /* ⚠ 數量與授權這兩類的期望值一律當場查（硬規則 3.56）。 */
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
     and pg_get_functiondef(p.oid) ~ 'current_member_id\(\)';
  v_out := v_out || E'\n⑥ 21 支都有守衛' || E'\t' ||
    case when v_n = 21 then '✅ 21/21' else '🔴 只有 ' || v_n || '/21' end;

  ---- ⑦ 🎯 正對照：刻意排除的兩支**不可以**被改到 --------
  /* 🔴 `get_my_orders_tx` 被改到的話，POS 的會員查詢會顯示**店員自己的**消費。
     `log_app_event_tx` 被改到的話，POS 的埋點會全部失敗。
     ⚠ 兩者都**不會報錯**，所以一定要驗。 */
  select count(*) into v_n
    from pg_proc p
   where p.pronamespace='public'::regnamespace and p.prokind='f'
     and p.proname in ('get_my_orders_tx','log_app_event_tx')
     and pg_get_functiondef(p.oid) ~ 'current_member_id\(\)';
  v_out := v_out || E'\n⑦ 🎯 正對照：排除的兩支沒被動到' || E'\t' ||
    case when v_n = 0 then '✅ 0 支（POS 不受影響）'
         else '🔴 有 ' || v_n || ' 支被改到了' end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.v', v_out, true);
end $v$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.v', true), E'\n')) as x
 where coalesce(x, '') <> '';
