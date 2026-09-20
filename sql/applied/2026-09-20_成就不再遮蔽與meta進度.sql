-- ============================================================
-- ① 成就不再遮蔽（使用者指定）　② meta 的進度算得出來
-- 2026-09-20
--
-- ① **「任何未解鎖成就也不要寫隱藏條件，直接寫出來」**
--    線上只有 3 枚 silhouette：大四喜／字一色／天胡（都還沒開放）。
--    ⇒ 改成 visible。名稱與條件直接顯示，前端那個 `？？？` 與 ❓ 自然消失。
--    ⚠ **遮蔽機制保留不動** —— `visibility` 的三個值與
--      `get_my_achievements_tx` 的遮蔽邏輯都還在。
--      今天「沒有任何一枚是 silhouette」是**內容決定**，不是機制不存在。
--      拿掉程式碼會讓那個欄位說謊（CHECK 允許三個值卻只有兩個有意義）。
--
-- ② **進度條的分子**：meta（「解鎖 N 個 X 類成就」）的 `current_value`
--    從來沒有人維護 ⇒ 讀出來永遠是 0，畫成進度條就是**說謊**
--    （客人解了 4 枚，進度條寫 0 / 15）。
--    🔴 **不可以在讀取端重算一份計數** —— 那就是這個專案記過八次的
--      「同一個事實兩個答案」。⇒ 把 `ach_meta_tx` 裡那段 count 抽成函式，
--      判定與顯示**叫同一支**。
--
-- ⚠ 驗證段一個字都不准 raise（硬規則 1.8，這份要留下 DDL）。
-- ============================================================

-- ---------- ① 三枚不再遮 ----------
update achievements
   set visibility = 'visible', updated_at = now()
 where deleted_at is null and visibility = 'silhouette';

-- ---------- ② 計數抽成函式 ----------
/* 「這個人在某個範圍裡解鎖了幾枚**真**成就」。
   🔴 meta 不計入 meta —— 否則「解鎖 15 枚」會把自己算進去，那個名字會說謊。
   ⚠ `coalesce` 不可省：`trigger` 可為 null，而 `null ? 'count'` 是 null，
     `not null` 還是 null ⇒ 那一列會被整個濾掉（同 `NULL not in` 那一族）。
   ⚠ 認不得的 scope 回 **null 不是 0** —— 0 會讓呼叫端以為「數過了，是零」，
     而 null 說的是「這個 trigger 壞了」。兩者要分得開。 */
create or replace function public.ach_meta_count_tx(
  p_member uuid, p_scope text, p_value text)
returns bigint
language sql
stable
security definer
set search_path to 'public'
as $$
  select case when p_scope in ('ui_category','group_key') and p_value is not null then (
    select count(*)
      from member_achievements ma
      join achievements a2 on a2.id = ma.achievement_id
      join members m on m.id = ma.member_id
     where ma.member_id = p_member
       and ma.status = 'unlocked'
       and a2.org_id = m.org_id
       and a2.deleted_at is null
       and not coalesce(a2.trigger ? 'count', false)
       and case p_scope
             when 'ui_category' then a2.ui_category = p_value
             when 'group_key'   then a2.group_key   = p_value
             else false
           end
  ) end;
$$;

revoke execute on function public.ach_meta_count_tx(uuid, text, text) from public;
revoke execute on function public.ach_meta_count_tx(uuid, text, text) from anon, authenticated;

-- ---------- ③ ach_meta_tx 改用它 ----------
create or replace function public.ach_meta_tx(p_member uuid, p_idem text default null)
returns jsonb
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
       and trigger ? 'count'                       -- 🎯 有 count 就是 meta
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
    if v_scope is null or v_value is null or v_need is null or v_need <= 0 then
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
        'code', r.code, 'reason', 'bad_trigger', 'trigger', r.trigger));
      continue;
    end if;

    /* 🎯 計數改叫 `ach_meta_count_tx` —— 與讀取端（成就牆的進度條）同一支。
       各寫一份的症狀是「進度條說 4 / 15，而它在第 5 枚就解鎖了」，
       **而且兩邊都不會報錯**。 */
    v_got := public.ach_meta_count_tx(p_member, v_scope, v_value);

    -- null ＝ 那支函式認不得這個 scope ⇒ 與上面同一個處理，不可以當成 0
    if v_got is null then
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
        'code', r.code, 'reason', 'bad_trigger', 'trigger', r.trigger));
      continue;
    end if;

    -- 已經解鎖就不必再判（但上面的 count 仍然跑過，那是讀取端要的值）
    if exists (select 1 from member_achievements ma
                where ma.member_id = p_member and ma.achievement_id = r.id
                  and ma.status = 'unlocked') then
      continue;
    end if;

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

-- ---------- ④ 讀取端：meta 回真的進度 ----------
create or replace function public.get_my_achievements_tx()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_member uuid;
  v_org    uuid;
  v_rows   jsonb;
  v_total  int;
  v_done   int;
begin
  v_member := public.current_member_id();
  if v_member is null then
    raise exception '未登入，無法讀取成就' using errcode = '28000';
  end if;

  select org_id into v_org from members where id = v_member and deleted_at is null;
  if v_org is null then
    raise exception '會員不存在' using errcode = '28000';
  end if;

  select coalesce(jsonb_agg(x order by x.ord, x.code), '[]'::jsonb),
         count(*)::int,
         count(*) filter (where x.status = 'unlocked')::int
    into v_rows, v_total, v_done
  from (
    select
      a.code,
      case when a.visibility = 'silhouette'
                and coalesce(ma.status, 'locked') <> 'unlocked'
           then '？？？' else a.name end                          as name,
      case when a.visibility = 'silhouette'
                and coalesce(ma.status, 'locked') <> 'unlocked'
           then null else a.description end                       as description,
      case when a.visibility = 'silhouette'
                and coalesce(ma.status, 'locked') <> 'unlocked'
           then null else a.condition_text end                    as condition_text,
      a.ui_category                                               as category,
      a.rarity,
      a.group_key,
      a.is_signature                                              as signature,
      (a.visibility = 'silhouette'
        and coalesce(ma.status, 'locked') <> 'unlocked')          as masked,
      coalesce(ma.status, 'locked')                               as status,
      /* 🎯 **進度的分子**。兩種來源，而它們是不同的機制：
           cumulative  `ach_progress_tx` 一路累加，值就在 member_achievements
           meta        沒有人累加 ⇒ **當下數一次**，與 ach_meta_tx 同一支函式
         ⚠ 不可以只讀 `current_value`：meta 那一類永遠是 0，
           畫成進度條就是對客人說謊（他解了 4 枚，條說 0 / 15）。 */
      case when a.trigger ? 'count'
           then coalesce(public.ach_meta_count_tx(
                  v_member, a.trigger->>'scope', a.trigger->>'value'), 0)
           else coalesce(ma.current_value, 0) end                 as current_value,
      case when a.trigger ? 'count' then (a.trigger->>'count')::int end as target,
      coalesce(ma.pinned, false)                                  as pinned,
      ma.unlocked_at,
      a.sort                                                      as ord
      from achievements a
      left join member_achievements ma
             on ma.achievement_id = a.id and ma.member_id = v_member
     where a.org_id = v_org
       and a.deleted_at is null
       and a.is_active
       and (a.valid_from is null or now() >= a.valid_from)
       and (a.valid_to   is null or now() <  a.valid_to)
       and not (a.visibility = 'hidden'
                and coalesce(ma.status, 'locked') <> 'unlocked')
  ) x;

  return jsonb_build_object(
    'ok', true,
    'total', v_total,
    'unlocked', v_done,
    'achievements', v_rows
  );
end $$;

revoke execute on function public.get_my_achievements_tx() from public;
revoke execute on function public.get_my_achievements_tx() from anon;
grant  execute on function public.get_my_achievements_tx() to authenticated;

-- ============================================================
-- 驗證（🔴 不准 raise）
-- ============================================================
do $$
declare
  v_msg    text := '';
  v_n      int;
  v_member uuid;
  v_line   text;
  v_r      jsonb;
  v_meta   jsonb;
begin
  -- ---------- ① 沒有任何一枚還在遮 ----------
  select count(*) into v_n from achievements
   where deleted_at is null and visibility = 'silhouette';
  v_msg := case when v_n = 0
    then '✅ ① silhouette 歸零（3 枚牌型改成 visible，名稱與條件直接顯示）'
    else '🔴 ① 還有 ' || v_n || ' 枚在遮' end;

  -- ---------- ② 🔴 負對照：遮蔽**機制**要留著 ----------
  -- 只驗「沒有人在遮」的話，把那段邏輯整個刪掉也會全綠
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'get_my_achievements_tx'
     and pg_get_functiondef(p.oid) ~ 'silhouette';
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '✅ ② 遮蔽邏輯還在（今天沒人用是**內容決定**，不是機制不存在）'
    else '🔴 ② 遮蔽邏輯被刪掉了 —— visibility 那個欄位會變成說謊' end;

  -- ---------- ③ 計數只有一份定義 ----------
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname <> 'ach_meta_count_tx'
     and pg_get_functiondef(p.oid) ~ 'not coalesce\(a2\.trigger \? ''count''';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ③ 「數已解鎖幾枚」全庫只有 ach_meta_count_tx 一份'
    else '🔴 ③ 還有 ' || v_n || ' 支自己數一份 —— 判定與顯示會漂' end;

  -- ---------- ④ 計數函式不給前端 ----------
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'ach_meta_count_tx'
     and (p.proacl is null
          or exists (select 1 from aclexplode(p.proacl) g
                      where g.privilege_type = 'EXECUTE'
                        and g.grantee in (0, 'anon'::regrole::oid, 'authenticated'::regrole::oid)));
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ④ ach_meta_count_tx 收乾淨了（它吃 p_member，不該讓前端直接叫）'
    else '🔴 ④ 前端叫得動 —— 那等於「給我一個 id 就數他解鎖幾枚」' end;

  -- ---------- ⑤ 認不得的 scope 回 null 不是 0 ----------
  select m.id into v_member from members m where m.deleted_at is null limit 1;
  v_msg := v_msg || E'\n' || case
    when public.ach_meta_count_tx(v_member, 'categoryyy', 'game') is null
    then '✅ ⑤ 壞掉的 scope 回 null（不是 0）—— 呼叫端分得出「壞了」與「是零」'
    else '🔴 ⑤ 壞 scope 回了數字 —— 那會讓一枚 meta 憑空解鎖' end;

  -- ---------- ⑥ 正對照：真的數得出來 ----------
  v_msg := v_msg || E'\n' || '⚪ ⑥ 現在 onboarding 類已解鎖 '
    || coalesce(public.ach_meta_count_tx(v_member, 'ui_category', 'onboarding')::text, '?')
    || ' 枚（線上今天是 0，因為 member_achievements 是空的）';

  -- ---------- ⑦ 讀取端：meta 那一列的 current_value 走新路徑 ----------
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'get_my_achievements_tx'
     and pg_get_functiondef(p.oid) ~ 'ach_meta_count_tx';
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '✅ ⑦ 讀取端的進度分子改叫同一支函式（不是只讀 current_value）'
    else '🔴 ⑦ 讀取端沒接上 —— meta 的進度條會永遠停在 0' end;

  -- ---------- ⑧ 拿真身分叫一次，看回傳形狀沒壞 ----------
  select m.id, m.line_user_id into v_member, v_line
    from members m
   where m.deleted_at is null and m.line_user_id is not null
   order by m.created_at limit 1;
  if v_line is null then
    v_msg := v_msg || E'\n' || '⚪ ⑧ 找不到綁了 LINE 的會員，正對照測不了';
  else
    perform set_config('request.jwt.claims',
      json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated',
                        'app_metadata', json_build_object('line_user_id', v_line))::text,
      true);
    begin
      v_r := public.get_my_achievements_tx();
      select x into v_meta
        from jsonb_array_elements(v_r->'achievements') x
       where x->>'code' = 'onboarding_29';
      v_msg := v_msg || E'\n' || case when (v_r->>'ok')::boolean and v_meta is not null
        then '✅ ⑧ 叫得出清單（' || (v_r->>'total') || ' 枚），而新手畢業那一列回 '
             || (v_meta->>'current_value') || ' / ' || (v_meta->>'target')
        else '🔴 ⑧ 回傳壞了或找不到 meta 那一列：' || left(v_r::text, 120) end;
      -- 🔴 遮蔽拿掉之後，不可以還有任何一列是 masked
      select count(*) into v_n
        from jsonb_array_elements(v_r->'achievements') x
       where (x->>'masked')::boolean;
      v_msg := v_msg || E'\n' || case when v_n = 0
        then '✅ ⑧ 回傳裡沒有任何一列 masked（前端那個 ？？？ 與 ❓ 不會再出現）'
        else '🔴 ⑧ 還有 ' || v_n || ' 列 masked' end;
    exception when others then
      v_msg := v_msg || E'\n' || '🔴 ⑧ 用真身分呼叫炸了：' || sqlstate || ' ' || sqlerrm;
    end;
    perform set_config('request.jwt.claims', '', true);
  end if;

  perform set_config('migi.verify', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify', true), ''), '🔴 沒有驗證訊息') as "驗證";
