-- ============================================================
-- 成就 meta 判定 `ach_meta_tx`（2026-09-20）
--   「解鎖 15 個新手成就」「解鎖 10 個牌局類成就」那 27 枚。
--
-- 📄 清單 `docs/03-會員App與社交/成就系統企劃.md`
-- 📄 事件 `docs/03-會員App與社交/成就事件清單.md` §1 ③、§3、§5 ①
-- 📄 引擎 `sql/applied/2026-09-20_成就系統核心RPC.sql`（已上線，行為 11/11）
--
-- ============================================================
-- 🔴 寫之前撈了 fire_event_tx 與 ach_unlock_tx 的線上全文，撞到兩件事，
--    而它們讓做法跟《成就事件清單》原本的規劃不一樣。
-- ============================================================
--
-- ### ① 🔴 meta 會被 fire_event_tx **免費解鎖**，這是一個真的洞
-- `fire_event_tx` 的迴圈條件只有 `(trigger->>'event') = p_event`，
-- 然後依 `struct` 分流 —— meta 的 struct 是 `specific`／`prestige`
-- ⇒ 一旦匯入 27 枚 `{"event":"achievement_unlocked", …, "count":15}`，
--   **任何一次 `fire_event_tx(…, 'achievement_unlocked', …)` 都會把它們
--   全部無條件解鎖**，因為 `ach_unlock_tx` 根本不看 `count`。
-- ⚠ 而它不會報錯，只會讓客人一次拿到 27 枚成就。
-- ✅ 所以 `fire_event_tx` **必須**加一道守衛：`not (trigger ? 'count')`。
--   這不是優化，是那 27 枚能不能匯入的前提。
--
-- ### ② 🎯 meta 不計入 meta ⇒ 遞迴問題**整個消失**
-- 《成就事件清單》§1 ③ 規劃的是「只有非 meta 解鎖時才發事件」來擋遞迴。
-- 但真正的根因不是發不發事件，是**要不要把 meta 算進計數**：
-- ```
-- 「解鎖 15 個牌局類成就」若把另一枚 meta 也算進去
--   ⇒ 14 枚真的 ＋ 1 枚 meta 就達標 ⇒ **那個名字在說謊**
-- ```
-- ⇒ 計數一律排除 meta。而排除之後，**解鎖一枚 meta 不可能改變任何計數**
--   ⇒ 一趟就夠，不需要深度限制、不需要計數器、也不需要那條「只發非 meta」。
-- 🎯 比原規劃少一個機制，而且是**證得出來**的少，不是省略。
--
-- ### 🎯 做成「對帳」不是「流水」
-- 這支不吃事件、不記進度 —— 它每次把 27 枚重數一遍。
-- · **天生冪等**：重跑幾次都一樣（`ach_unlock_tx` 已解鎖回 `already`）
-- · **會自我修復**：漏算過、匯入過、改過門檻，下一次跑就補回來
-- ⚠ 代價是每次 O(27) 次計數查詢。以 MIGI 的量（一天幾百個事件）不值得優化，
--   而**一個會漂掉的計數器要花的除錯時間遠超過這個**。
--
-- ### ⚠ scope 認不得就跳過並且**報出來**
-- `scope` 只有 `ui_category` / `group_key` 兩個值（§3 明寫不要加第三個）。
-- 🔴 打錯字時**絕對不可以 fallback 成「算全部」** —— 那會讓那一枚
--   在客人解鎖第 15 個**任何**成就時就跳出來。
--   寧可不解鎖，而且讓它出現在回傳的 `skipped` 裡。
--
-- ⚠ 這份要留下 DDL ⇒ 驗證段一個字都不准 raise（硬規則 1.8）。
--   行為測試（造樣本、要回滾）另一份：
--   `sql/checks/2026-09-20_驗成就meta判定.sql`
-- ============================================================


-- ============================================================
-- ① ach_meta_tx
-- ============================================================
create or replace function public.ach_meta_tx(
  p_member uuid,
  p_idem   text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_org     uuid;
  r         record;
  v_scope   text;
  v_value   text;
  v_need    bigint;
  v_got     bigint;
  v_one     jsonb;
  v_unlocked jsonb := '[]'::jsonb;
  v_skipped  jsonb := '[]'::jsonb;
  v_checked int := 0;
begin
  select org_id into v_org from members where id = p_member and deleted_at is null;
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  for r in
    select id, code, trigger
      from achievements
     where org_id = v_org
       and deleted_at is null
       and is_active
       and trigger ? 'count'                       -- 🎯 有 count 就是 meta（§3 的判準）
       and (trigger->>'event') = 'achievement_unlocked'
       and (valid_from is null or now() >= valid_from)
       and (valid_to   is null or now() <  valid_to)
     order by sort, code
  loop
    v_checked := v_checked + 1;
    v_scope := r.trigger->>'scope';
    v_value := r.trigger->>'value';
    v_need  := nullif(r.trigger->>'count', '')::bigint;

    -- 🔴 認不得的 scope／缺值一律跳過並報出來，**不可以 fallback 成「算全部」**
    if v_scope is null or v_scope not in ('ui_category','group_key')
       or v_value is null or v_need is null or v_need <= 0 then
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
        'code', r.code, 'reason', 'bad_trigger', 'trigger', r.trigger));
      continue;
    end if;

    -- 已經解鎖就不必再數（省掉大部分的查詢，而且語意一樣）
    if exists (select 1 from member_achievements ma
                where ma.member_id = p_member and ma.achievement_id = r.id
                  and ma.status = 'unlocked') then
      continue;
    end if;

    select count(*) into v_got
      from member_achievements ma
      join achievements a2 on a2.id = ma.achievement_id
     where ma.member_id = p_member
       and ma.status = 'unlocked'
       and a2.org_id = v_org
       and a2.deleted_at is null
       -- 🔴 meta 不計入 meta（見檔頭 ②）。
       --    ⚠ `coalesce` 不可省：`trigger` 可為 null，而 `null ? 'count'` 是 null，
       --      `not null` 還是 null ⇒ **那一列會被整個濾掉**（同 `NULL not in` 那一族）。
       and not coalesce(a2.trigger ? 'count', false)
       and case v_scope
             when 'ui_category' then a2.ui_category = v_value
             when 'group_key'   then a2.group_key   = v_value
             else false
           end;

    if v_got >= v_need then
      v_one := public.ach_unlock_tx(
        p_member, r.code, coalesce(p_idem, 'meta') || ':' || r.code);
      v_unlocked := v_unlocked || jsonb_build_array(jsonb_build_object(
        'code', r.code, 'got', v_got, 'need', v_need, 'result', v_one));
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'checked', v_checked,
                            'unlocked', v_unlocked, 'skipped', v_skipped);
end $$;

-- 🔴 兩個方向都要收（硬規則 2.6b）：舊函式的 anon 來自 PUBLIC 繼承，
--   新建的來自 default privileges 的明確授權。收錯方向的症狀跟沒收一樣。
revoke execute on function public.ach_meta_tx(uuid, text) from public;
revoke execute on function public.ach_meta_tx(uuid, text) from anon, authenticated;
grant  execute on function public.ach_meta_tx(uuid, text) to service_role;


-- ============================================================
-- ② fire_event_tx：加守衛 ＋ 收尾叫 ach_meta_tx
--    簽名不變 ⇒ CREATE OR REPLACE，不用 DROP，GRANT 不會掉
-- ============================================================
create or replace function public.fire_event_tx(
  p_member uuid, p_event text, p_delta bigint default 1,
  p_period_key text default null, p_idem text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  r record; v_res jsonb := '[]'::jsonb; v_one jsonb; v_idem text; v_org uuid;
  v_meta jsonb;
begin
  select org_id into v_org from members where id = p_member and deleted_at is null;
  if v_org is null then return jsonb_build_object('ok', false, 'reason', 'member_not_found'); end if;

  for r in
    select code, struct, requires_code
      from achievements
     where org_id = v_org
       and deleted_at is null
       and is_active
       and (trigger->>'event') = p_event
       -- 🔴 2026-09-20 加的守衛，而它不是優化是前提：
       --   meta 的 struct 也是 specific／prestige，少了這一行，
       --   一次 'achievement_unlocked' 事件會把 27 枚 meta **無條件全開**
       --   （ach_unlock_tx 根本不看門檻），而且不會報錯。
       --   帶門檻的那一類一律走 ach_meta_tx，不走這個泛用分流。
       and not (trigger ? 'count')
       and (valid_from is null or now() >= valid_from)
       and (valid_to   is null or now() <  valid_to)
     order by sort, code
  loop
    -- 前置依賴：沒解鎖前置就跳過（系列成就不會跳級）
    if r.requires_code is not null then
      if not exists (
        select 1 from member_achievements ma
          join achievements a2 on a2.id = ma.achievement_id
         where ma.member_id = p_member
           and a2.code = r.requires_code
           and ma.status = 'unlocked')
      then continue; end if;
    end if;

    -- 每個成就各自一把冪等鍵：同一個來源事件不會把同一枚重複計
    v_idem := coalesce(p_idem, 'evt') || ':' || p_event || ':' || r.code;

    if r.struct in ('specific','prestige') then
      v_one := public.ach_unlock_tx(p_member, r.code, v_idem);
    elsif r.struct = 'cumulative' then
      v_one := public.ach_progress_tx(p_member, r.code, p_delta, v_idem);
    elsif r.struct = 'streak' then
      if p_period_key is null then
        v_one := jsonb_build_object('ok', false, 'reason', 'period_key_required');
      else
        v_one := public.ach_streak_tx(p_member, r.code, p_period_key, true, v_idem);
      end if;
    else
      continue;
    end if;

    v_res := v_res || jsonb_build_array(
      jsonb_build_object('code', r.code, 'struct', r.struct, 'result', v_one));
  end loop;

  -- 🎯 收尾對一次帳。放這裡而不是要每個發射端自己叫，理由是
  --   **發射端不該知道 meta 存在** —— 那 12 支裡有一半是金流函式。
  -- ✅ 不會遞迴：meta 不計入 meta（見 ach_meta_tx 的註解），
  --   所以解鎖一枚 meta 不可能改變任何計數，一趟就夠。
  v_meta := public.ach_meta_tx(p_member, coalesce(p_idem, 'evt') || ':' || p_event);

  return jsonb_build_object('ok', true, 'event', p_event,
                            'matched', v_res, 'meta', v_meta);
end $$;


-- ============================================================
-- 驗證
-- ============================================================
do $$
declare
  v_msg text := '';
  v_n   int;
  v_txt text;
begin
  -- ① 函式在，而且只有一個版本（多載會讓呼叫端挑到別支）
  select count(*) into v_n from pg_proc
   where pronamespace='public'::regnamespace and proname='ach_meta_tx';
  v_msg := case when v_n = 1
    then '✅ ① ach_meta_tx 版本數 1'
    else '🔴 ① ach_meta_tx 有 ' || v_n || ' 個版本' end;

  -- ② 授權：**明確有沒有**與 **PUBLIC 有沒有**要分開印（硬規則 2.6b）
  --    只印 has_function_privilege 的話，收錯方向的症狀跟沒收一模一樣
  v_msg := v_msg || E'\n' || '　　授權：' || coalesce(
    (select string_agg(
       case when exists (
         select 1 from pg_proc p, aclexplode(p.proacl) a
          where p.pronamespace='public'::regnamespace and p.proname='ach_meta_tx'
            and a.grantee = case when g='PUBLIC' then 0 else g::regrole::oid end
            and a.privilege_type='EXECUTE')
       then g || '=有' else g || '=沒有' end, '　' order by ord)
     from unnest(array['anon','authenticated','service_role','PUBLIC'])
          with ordinality t(g, ord)),
    '⚪ 取不到');   -- 字串 || NULL 會吃掉前面所有格（硬規則 3.555）

  -- ③ 🔴 fire_event_tx 的守衛在不在 —— 逐行印出來判讀（硬規則 3.5）
  select trim(l) into v_txt
    from pg_proc p, lateral regexp_split_to_table(pg_get_functiondef(p.oid), E'\n') l
   where p.pronamespace='public'::regnamespace and p.proname='fire_event_tx'
     and l ~ 'trigger \? ''count'''
   limit 1;
  v_msg := v_msg || E'\n' || case when v_txt is not null
    then '✅ ③ fire_event_tx 有守衛：' || v_txt
    else '🔴 ③ fire_event_tx **沒有**那道守衛 —— 匯入 meta 之後會被免費全開' end;

  -- ④ fire_event_tx 真的會叫 ach_meta_tx
  select count(*) into v_n from pg_proc p
   where p.pronamespace='public'::regnamespace and p.proname='fire_event_tx'
     and pg_get_functiondef(p.oid) ~ '(perform|:=)\s*public\.ach_meta_tx';
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '✅ ④ fire_event_tx 收尾會呼叫 ach_meta_tx'
    else '🔴 ④ fire_event_tx 沒有呼叫 ach_meta_tx（' || v_n || '）' end;

  -- ⑤ ⚪ 今天有幾枚 meta —— 還沒匯入，所以這一格是「沒有資料」不是「通過」
  select count(*) into v_n from achievements
   where deleted_at is null and trigger ? 'count';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '⚪ ⑤ 目前 0 枚 meta（300 枚還沒匯入）—— 這一格現在測不出東西'
    else '✅ ⑤ 目前 ' || v_n || ' 枚 meta，ach_meta_tx 會逐枚對帳' end;

  -- ⑥ 🔴 負對照：其餘四支判定函式的授權沒被波及
  --    只驗「新的收緊了」的話，把別支一起收掉也會全綠（硬規則 3.55）
  select string_agg(p.proname || '=' ||
           case when exists (select 1 from aclexplode(p.proacl) a
                              where a.grantee = 'anon'::regrole::oid
                                and a.privilege_type='EXECUTE')
                then '🔴anon' else 'service_role only' end, '　' order by p.proname)
    into v_txt
    from pg_proc p
   where p.pronamespace='public'::regnamespace
     and p.proname in ('ach_unlock_tx','ach_progress_tx','ach_streak_tx','fire_event_tx');
  v_msg := v_msg || E'\n' || '　　⑥ 其餘判定函式：' || coalesce(v_txt, '⚪ 取不到')
    || E'\n' || '　　（`ach_pin_tx` 是唯一該給 anon 的，不在這一串裡）';

  perform set_config('migi.verify', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify', true), ''), '🔴 沒有驗證訊息') as "驗證";
