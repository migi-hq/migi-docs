/* ============================================================
   ① 管理後台：設定每個積分級距的起始積分
   ② 智慧計分板的牌局紀錄：帶出「追加積分 +N」與「不追加、牌局結束」
   2026-09-30 · MIGI 咪吉麻將
   行為測試：sql/checks/2026-09-30_驗起始積分後台與追加積分紀錄.sql（跑完這份再跑）

   使用者 09-30：「各級距的起始積分應該由後台管理設定」——
   現在的值是建欄位時回填的「底 × 20」（stake_levels.start_points），沒有任何畫面可以改。
   起始積分決定智慧計分板每人開局有多少積分、多快會爆卡（桌邊記分板設計.md §3.7）。

   · admin_list_stake_levels_tx()：全部級距（含停用），外加「現在有幾桌正在用」
   · admin_set_stake_start_points_tx(級距, 起始積分)：只改起始積分
     —— 名稱、底、台、純娛樂這幾項**刻意不開放**：改底台會讓正在打的桌下一局算法變掉，
       而且報表按級距分組，那是另一件事
   · 權限同會員等級頁：can('stake.write')（今天＝總部）；操作者從登入身分取，不收參數
   ⚠ 起始積分是**即時讀的**：正在打的桌，每個人手上的積分會跟著變 ⇒ 畫面上要寫明，
     回傳也帶「有幾桌正在用」讓後台能提醒
   ============================================================ */

create or replace function public.admin_list_stake_levels_tx()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare v_org uuid;
begin
  if not public.can('stake.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限查看積分級距');
  end if;
  v_org := public.current_org_id();
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', sl.id, 'label', sl.label, 'base', sl.base, 'tai', sl.tai,
             'is_hygiene', sl.is_hygiene, 'is_active', sl.is_active,
             'start_points', sl.start_points,
             'store', st.name,                 -- null ＝ 全部門市共用
             'open_tables', (select count(*) from public.table_sessions ts
                              where ts.stake_level_id = sl.id and ts.status = 'open' and ts.deleted_at is null),
             'updated_at', sl.updated_at)
           order by sl.sort_order, sl.label)
      from public.stake_levels sl
      left join public.stores st on st.id = sl.store_id
     where sl.org_id = v_org and sl.deleted_at is null), '[]'::jsonb));
end $fn$;
revoke execute on function public.admin_list_stake_levels_tx() from public, anon;
grant  execute on function public.admin_list_stake_levels_tx() to authenticated;

create or replace function public.admin_set_stake_start_points_tx(p_id uuid, p_start_points integer)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_org uuid; v_staff uuid; v_open int;
begin
  if not public.can('stake.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限修改起始積分');
  end if;
  v_org := public.current_org_id();
  v_staff := (select staff_id from public.current_staff());
  if p_start_points is null or p_start_points < 1 or p_start_points > 9999999 then
    return jsonb_build_object('ok', false, 'reason', 'bad_points', 'message', '起始積分要在 1 到 9,999,999 之間');
  end if;
  update public.stake_levels
     set start_points = p_start_points, updated_at = now(), updated_by = v_staff   -- 🔴 操作者從登入身分取
   where id = p_id and org_id = v_org and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個級距');
  end if;
  select count(*) into v_open from public.table_sessions
   where stake_level_id = p_id and status = 'open' and deleted_at is null;
  return jsonb_build_object('ok', true, 'id', p_id, 'start_points', p_start_points, 'open_tables', v_open);
end $fn$;
revoke execute on function public.admin_set_stake_start_points_tx(uuid, integer) from public, anon;
grant  execute on function public.admin_set_stake_start_points_tx(uuid, integer) to authenticated;

/* ============================================================
   ② tbl_state_tx 多回一個 bust_log（追加／不追加的紀錄，新的在前）

   🔴 **刻意不塞進原本的 log**：舊版平板的 logRow() 會把那種列當成一局去畫
     （沒有 result ⇒ 掉進流局那一支，印出「連莊 undefined」）。
     另開一個鍵，舊版直接忽略它 ⇒ 前後端誰先上都不會壞。
   · round_no／wind／hand_no 取自「造成爆卡的那一局」⇒ 紀錄頁的「第 N 將」「X 風圈」篩選照樣能用
   · 只列 added 與 ended；pending（還在等他決定）畫面上已經有等待提示，voided（那一局被撤銷）不是發生過的事
   · 做法：撈線上全文、在固定的一行後面插入，錨點必須剛好出現一次；已經有 bust_log 就不重插（可以重跑）
   ============================================================ */
do $$
declare
  v_def text; v_new text; v_n int;
  v_anchor text := $a$'log', coalesce(v_log, '[]'::jsonb), 'patterns', v_catalog,$a$;
  v_add text := $b$
    /* 💥 追加積分／不追加結束的紀錄（2026-09-30）：另開一個鍵，不混進 log（舊版平板會畫壞） */
    'bust_log', (select coalesce(jsonb_agg(jsonb_build_object(
                   'id', b.id, 'seat', b.seat, 'decision', b.decision, 'added_points', b.added_points,
                   'round_no', r.round_no, 'wind', h.wind, 'hand_no', h.hand_no, 'at', b.decided_at)
                   order by b.decided_at desc), '[]'::jsonb)
                   from public.session_busts b
                   left join public.hands h on h.id = b.hand_id
                   left join public.session_rounds r on r.id = h.round_id
                  where b.session_id = s.id and b.decision in ('added', 'ended')),$b$;
begin
  v_def := pg_get_functiondef('public.tbl_state_tx(text)'::regprocedure);
  if position('''bust_log''' in v_def) > 0 then
    return;   -- 已經插過了
  end if;
  v_n := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_n <> 1 then
    -- 故意中止、整份不提交（錨點對不上就不可以亂插）
    raise exception '🔴 tbl_state_tx 的錨點出現 % 次（期望 1），整份不提交', v_n;
  end if;
  v_new := replace(v_def, v_anchor, v_anchor || v_add);
  execute v_new;
end $$;

/* ============================================================
   驗證（不 raise —— 這份要留下東西）
   ============================================================ */
do $$
declare v_msg text := ''; v_n int; v_fn text; v_oid oid; v_anon boolean; v_pub boolean; v_auth boolean; v_txt text;
begin
  -- ① 兩支授權：只有登入的人（anon、PUBLIC 都沒有）
  foreach v_fn in array array['public.admin_list_stake_levels_tx()', 'public.admin_set_stake_start_points_tx(uuid,integer)'] loop
    v_oid := v_fn::regprocedure;
    select exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = v_oid and a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE') into v_anon;
    select (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')) into v_pub from pg_proc p where p.oid = v_oid;
    select has_function_privilege('authenticated', v_oid, 'execute') into v_auth;
    v_msg := v_msg || case when not v_anon and not v_pub and v_auth then '✅' else '🔴' end
          || ' ① ' || v_fn || '  anon ' || case when v_anon then '有' else '無' end
          || ' · PUBLIC ' || case when v_pub then '有' else '無' end
          || ' · authenticated ' || case when v_auth then '有' else '無' end || E'\n';
  end loop;

  -- ② 兩支都自己問權限、改的那支從登入身分取操作者
  v_txt := pg_get_functiondef('public.admin_set_stake_start_points_tx(uuid,integer)'::regprocedure);
  v_msg := v_msg || case when v_txt ~ 'can\(''stake\.write''\)' and v_txt ~ 'current_staff\(\)'
                          and pg_get_functiondef('public.admin_list_stake_levels_tx()'::regprocedure) ~ 'can\(''stake\.write''\)'
                         then '✅' else '🔴' end || ' ② 兩支都檢查 stake.write，操作者取自 current_staff()' || E'\n';

  -- ③ 沒登入叫 ⇒ 被拒（can() 在沒有身分時回 false）
  select (public.admin_set_stake_start_points_tx(gen_random_uuid(), 100) ->> 'reason') into v_txt;
  v_msg := v_msg || case when v_txt = 'forbidden' then '✅' else '🔴' end || ' ③ 沒有身分改起始積分 → ' || coalesce(v_txt, '∅') || '（期望 forbidden）' || E'\n';

  -- ④ tbl_state_tx 帶 bust_log、只有一個版本、平板照樣叫得動（anon 在改之前就是明確授權，CREATE OR REPLACE 不會丟）
  v_oid := 'public.tbl_state_tx(text)'::regprocedure;
  v_txt := pg_get_functiondef(v_oid);
  select count(*) into v_n from pg_proc where pronamespace = 'public'::regnamespace and proname = 'tbl_state_tx';
  v_msg := v_msg || case when position('''bust_log''' in v_txt) > 0 and v_txt ~ 'from public\.session_busts b\s+left join public\.hands'
                          and v_n = 1 and has_function_privilege('anon', v_oid, 'execute')
                          and position('''log'', coalesce(v_log' in v_txt) > 0
                         then '✅' else '🔴' end
        || ' ④ tbl_state_tx：bust_log ' || case when position('''bust_log''' in v_txt) > 0 then '有' else '沒有' end
        || '、原本的 log 還在、版本數 ' || v_n || '（期望 1）、平板（anon）' || case when has_function_privilege('anon', v_oid, 'execute') then '叫得動' else '叫不動' end || E'\n';

  -- ⑤ 目前的值沒有被這份動到（它只建函式）
  select string_agg(label || ':' || start_points, ' ' order by sort_order, label) into v_txt from public.stake_levels where deleted_at is null;
  v_msg := v_msg || '　⑤ 目前的起始積分（參考，這份沒有改）：' || coalesce(v_txt, '∅');

  perform set_config('migi.v', v_msg, true);
end $$;
select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有驗證訊息') as "驗證";
