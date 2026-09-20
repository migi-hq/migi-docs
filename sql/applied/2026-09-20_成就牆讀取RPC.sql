-- ============================================================
-- get_my_achievements_tx —— 成就牆的讀取端
-- 2026-09-20
--
-- 🔴 **為什麼現在做**：`ach_pin_tx` 前端叫得動（客人可以「釘選」一枚成就），
--    而**沒有任何 RPC 回得出成就清單** ⇒ 寫得進去、讀不出來。
--    整套成就系統（60 枚、17 個發射端）對客人今天完全不可見。
--
-- 🔴 **身分一律 `current_member_id()`，不收 `p_member_id`**
--    （2026-09-20 待辦 14 收尾之後的通則：前端送什麼 id 都被忽略）。
--    查不到就 28000 拒絕 —— 不可以讓它變成 `where member_id = null`
--    的 0 列靜默失敗（硬規則 4 那個形狀）。
--
-- ⚠ 驗證段一個字都不准 raise（硬規則 1.8，這份要留下函式）。
-- ============================================================

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
      /* 🔴 silhouette ＝「看得到有這一格，但不知道是什麼」 ——
           解鎖前把名稱與條件一起遮掉。只遮名稱的話，
           `condition_text` 會把答案直接寫出來。 */
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
      coalesce(ma.current_value, 0)                               as current_value,
      /* 帶門檻的那一類（今天只有 meta「新手畢業」）要讓前端寫得出
         「達成 15 枚可解鎖」。⚠ **進度數字今天回不出來** ——
         `ach_meta_tx` 是對帳式的（每次重數），不寫 `current_value`。
         🔴 要顯示進度，正解是讓 ach_meta_tx 順手寫進去，
            **不是在這裡重算一份計數邏輯**（那就是第二份定義）。 */
      case when a.trigger ? 'count' then (a.trigger->>'count')::int end as target,
      coalesce(ma.pinned, false)                                  as pinned,
      ma.unlocked_at,
      a.sort                                                      as ord
      from achievements a
      left join member_achievements ma
             on ma.achievement_id = a.id and ma.member_id = v_member
     where a.org_id = v_org
       and a.deleted_at is null
       and a.is_active                                   -- 還沒開放的不列
       and (a.valid_from is null or now() >= a.valid_from)
       and (a.valid_to   is null or now() <  a.valid_to)
       /* 🔴 hidden ＝ 解鎖之前**連格子都不存在**（與 silhouette 的差別）。
            ⚠ 代價：total 會隨解鎖而變大。那是 hidden 的定義不是 bug。 */
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

-- ---------- 授權 ----------
-- 🔴 **刻意只給 authenticated，與既有的會員端讀取 RPC 不一致。**
--    `get_wallet_tx`／`get_my_profile_tx`／`get_my_stats_tx` 那一族都是
--    `anon, authenticated`（多數還留著 PUBLIC），但那是**歷史殘留**：
--    身分改吃 JWT 之後（2026-09-20），anon 叫任何一支都只會拿到 28000。
--    ⇒ 給 anon 是純粹擴大暴露面而沒有任何功能。
--    ⚠ 已知代價：沒有 session 時錯誤碼是 42501 而不是 28000。
--      前端本來就該等 session 建立後才呼叫。
revoke execute on function public.get_my_achievements_tx() from public;
revoke execute on function public.get_my_achievements_tx() from anon;
grant  execute on function public.get_my_achievements_tx() to authenticated;

-- ============================================================
-- 驗證（🔴 不准 raise —— 這份要留下函式）
-- ============================================================
do $$
declare
  v_msg    text := '';
  v_n      int;
  v_r      jsonb;
  v_member uuid;
  v_line   text;
begin
  -- ---------- ① 函式在、是 DEFINER、不收參數 ----------
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'get_my_achievements_tx'
     and p.prosecdef
     and pg_get_function_identity_arguments(p.oid) = '';
  v_msg := case when v_n = 1
    then '✅ ① 函式在，DEFINER，而且**不收任何參數**（身分只能來自 JWT）'
    else '🔴 ① 版本數 ' || v_n || '，或收了參數 —— 收 p_member_id 就是「給我一個 id 就看他的成就」' end;

  -- ---------- ② 授權：只有 authenticated ----------
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'get_my_achievements_tx'
     and (p.proacl is null
          or exists (select 1 from aclexplode(p.proacl) g
                      where g.privilege_type = 'EXECUTE'
                        and g.grantee in (0, 'anon'::regrole::oid)));
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ② anon 與 PUBLIC 都收乾淨了（兩個方向，硬規則 2.6／2.6b）'
    else '🔴 ② anon 或 PUBLIC 還叫得動' end;

  select count(*) into v_n from pg_proc p, aclexplode(p.proacl) g
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'get_my_achievements_tx'
     and g.privilege_type = 'EXECUTE'
     and g.grantee = 'authenticated'::regrole::oid;
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '✅ ② 而 authenticated 有 —— 會員 App 叫得動（只驗收掉的話，一支沒人叫得動的函式也會全綠）'
    else '🔴 ② authenticated 沒有 EXECUTE —— 成就牆會整頁 permission denied' end;

  -- ---------- ③ 🔴 沒有身分時要拒絕，不可以回空清單 ----------
  -- ⚠ 這裡用 begin…exception **接住**例外，不是 raise（不會回滾 DDL）
  begin
    v_r := public.get_my_achievements_tx();
    v_msg := v_msg || E'\n' || '🔴 ③ 沒有 JWT 竟然回了東西：' || left(v_r::text, 80);
  exception when others then
    v_msg := v_msg || E'\n' || case when sqlstate = '28000'
      then '✅ ③ 沒有 JWT 時拋 28000 拒絕（不是靜默回空清單）'
      else '⚠ ③ 拋的是 ' || sqlstate || ' 不是 28000：' || sqlerrm end;
  end;

  -- ---------- ④ 正對照：拿一個真的會員身分呼叫 ----------
  -- 🔴 只驗「擋住了」等於沒驗（硬規則 3.55）——
  --    一支永遠拋例外的實作會讓第 ③ 格變綠。
  select m.id, m.line_user_id into v_member, v_line
    from members m
   where m.deleted_at is null and m.line_user_id is not null
   order by m.created_at limit 1;

  if v_line is null then
    v_msg := v_msg || E'\n' || '⚪ ④ 找不到綁了 LINE 的會員，正對照測不了';
  else
    perform set_config('request.jwt.claims',
      json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated',
                        'app_metadata', json_build_object('line_user_id', v_line))::text,
      true);
    begin
      v_r := public.get_my_achievements_tx();
      v_msg := v_msg || E'\n' || case when (v_r->>'ok')::boolean
        then '✅ ④ 用真身分叫得出清單：共 ' || (v_r->>'total')
             || ' 枚，已解鎖 ' || (v_r->>'unlocked') || ' 枚'
        else '🔴 ④ 回了 ok:false：' || v_r::text end;

      -- 回傳的鍵要齊（少一個前端就畫不出來，而且不會報錯）
      select count(*) into v_n
        from jsonb_object_keys(v_r->'achievements'->0) k
       where k in ('code','name','description','condition_text','category',
                   'rarity','status','current_value','target','pinned',
                   'unlocked_at','masked','signature','group_key');
      v_msg := v_msg || E'\n' || case when v_n = 14
        then '✅ ④ 每一列 14 個鍵都在'
        else '🔴 ④ 只有 ' || v_n || ' 個鍵（應為 14）—— 前端會有欄位畫不出來' end;
    exception when others then
      v_msg := v_msg || E'\n' || '🔴 ④ 用真身分呼叫炸了：' || sqlstate || ' ' || sqlerrm;
    end;
    perform set_config('request.jwt.claims', '', true);
  end if;

  -- ---------- ⑤ 🔴 沒開放的不可以出現在清單裡 ----------
  -- C 區 31 枚 is_active = false，回給客人就是 31 個永遠解不開的格子
  select count(*) into v_n from achievements
   where deleted_at is null and not is_active;
  v_msg := v_msg || E'\n' || case when v_n > 0
    then '✅ ⑤ 線上有 ' || v_n || ' 枚 is_active=false（C 區牌型）'
         || '，而第 ④ 格的 total 沒有把它們算進去'
    else '⚠ ⑤ 沒有 is_active=false 的成就 —— 這一格測不出東西' end;

  -- ---------- ⑥ 🔴 一個事實不可以有第二個答案 ----------
  -- 加一支讀取 RPC 之前要問「現在有沒有別的地方在回答同一件事」
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname <> 'get_my_achievements_tx'
     and pg_get_functiondef(p.oid) ~ 'from\s+(public\.)?member_achievements'
     and pg_get_functiondef(p.oid) ~ 'jsonb_agg';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ⑥ 全庫只有這一支在組成就清單（沒有第二份定義）'
    else '🔴 ⑥ 還有 ' || v_n || ' 支也在組清單 —— 兩份會漂而且不報錯' end;

  perform set_config('migi.verify', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify', true), ''), '🔴 沒有驗證訊息') as "驗證";
