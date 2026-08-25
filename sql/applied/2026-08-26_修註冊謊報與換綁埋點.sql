/* ============================================================
   修：註冊會謊報綁定成功 ＋ 換綁事件沒有測試隔離
   2026-08-26 · 兩支簽名都不變 → CREATE OR REPLACE，不會丟 GRANT

   ✅ 已執行並驗證通過（2026-08-26）
      兩支都是 DEFINER／anon ✅、版本數各 1（簽名沒變）、
      register 有 line_conflict 分支、rebind 已改走 log_app_event_tx、
      煙霧測試正確拋「display_name required」。

   📌 第 ⑤ 段（索引使用次數）的結果**不能照字面讀**：
      uq_members_line_user 0 次、uq_members_line 2 次、idx_members_org 0 次。
      🔴 「0 次」不代表沒用，代表**還沒被用到** ——
        目前 0 個會員綁 LINE，依 line_user_id 查的路徑從來沒真的執行過；
        而 members 只有 4 列，規劃器一律 seq scan，
        **索引統計在這個規模下沒有分辨力**。
      → 索引這題只能用設計意圖回答，不能用使用統計。見檔頭 ③。

   ── ① register_member_tx 會謊報 ──────────────────────
   線上版：
       update members set line_user_id = p_line_user_id
         where id = v_existing and line_user_id is null;
       v_action := 'rebound';

   `and line_user_id is null` 是**對的守衛**（不覆蓋既有綁定），
   但**不管有沒有更新到，都回報 'rebound'**。

   🔴 情境：客人的手機對上了，但那個會員早就綁了**另一個** LINE 帳號
     → 更新 0 列 → 前端以為綁好了，實際沒有。
     而那正是「同一個人兩個帳號」（待辦 15）最可能發生的入口 ——
     客人以為綁好了，下次用 LINE 進來查不到自己，就再註冊一個。

   → 改成看 `FOUND`，分三種結果：
       更新到          → 'rebound'
       本來就綁同一個  → 'existing_line'（其實是同一個人，不是衝突）
       綁了別的        → 'line_conflict' ＋ 中文說明

   ⚠ 不回傳對方的 line_user_id —— 那是別人的識別碼。
     只講「已綁定另一個 LINE 帳號」，處理方式是店員用
     rebind_line_user_tx 人工介入（那支要 p_staff_id，本來就是給人用的）。

   ── ② rebind_line_user_tx 的稽核事件沒有測試隔離 ────────
   線上版直接 insert app_events：
       insert into app_events(org_id, member_id, event, props, created_at)
   → 沒走 log_app_event_tx、沒給 store_id、**is_test 走預設 false**
   → 測試會員的換綁事件會被標成營運事件。

   ⚠ 這正是 2026-08-26 早上修的那一類（只是換一個入口）。
   → 改成呼叫 log_app_event_tx，它會從 member 推 is_test。
   ✅ 事件名 'line_rebind' 本來就符合 `^[a-z][a-z0-9_]{0,49}$`，不用改。

   ── ③ 兩個 UNIQUE 索引不是冗餘，是兩個矛盾的意圖 ────────
   （這一份不改它，只把查證結果記下來 —— 見驗證段 ⑤⑥）
     · `uq_members_line (org_id, line_user_id)` 來自 M0 地基，
       註解寫「**同 org 內**不重複」→ 原始設計允許跨 org 同一個 LINE 帳號。
     · `uq_members_line_user (line_user_id)` 全域唯一 ——
       🔴 **sql/ 裡完全找不到，是直接在 Dashboard 手動建的**，沒留紀錄。
   而全域那個**可能是必要的**：`current_org_id()` 是
       select org_id from members where line_user_id = auth.jwt()->>'sub'
   —— 它假設一個 line_user_id 只對應一個會員。允許跨 org 的話，
   整套 RLS 的地基會回傳不確定的那一列。
   📌 結論：MIGI 的設計是「**一個 LINE 帳號只能屬於一個 org**」。
     那是決定不是意外，該進決策紀錄。
   ============================================================ */


/* ──────────────────────────────────────────────────────────
   ① register_member_tx
   ────────────────────────────────────────────────────────── */

create or replace function public.register_member_tx(
  p_org_id        uuid,
  p_display_name  text,
  p_phone         text default null,
  p_line_user_id  text default null,
  p_home_store_id uuid default null,
  p_created_by    uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
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

  v_name := trim(coalesce(p_display_name, ''));
  if v_name = '' then
    raise exception 'display_name required';
  end if;

  if char_length(v_name) > 12 then
    raise exception 'display_name too long (max 12)';
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
      return jsonb_build_object('action','existing_line','member_id',v_member.id,
        'display_name',v_member.display_name,'phone',v_member.phone);
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
        update members
           set line_user_id = p_line_user_id, updated_at = now()
         where id = v_existing and line_user_id is null;

        /* ★ 2026-08-26：看 FOUND，不要無條件回報成功。
           舊版不管有沒有更新到都回 'rebound'，
           而「這個會員早就綁了別的 LINE」時更新 0 列 ——
           前端以為綁好了，客人下次用 LINE 進來查不到自己，就再註冊一個。 */
        if not found then
          select line_user_id into v_cur_line from members where id = v_existing;
          if v_cur_line = p_line_user_id then
            -- 其實就是同一個人（併發或重試），不是衝突
            v_action := 'existing_line';
          else
            /* ⚠ 不回傳對方的 line_user_id —— 那是別人的識別碼。
               處理方式：店員用 rebind_line_user_tx 人工介入
               （那支要 p_staff_id，本來就是給人用的）。 */
            select * into v_member from members where id = v_existing;
            return jsonb_build_object(
              'action','line_conflict',
              'member_id', v_member.id,
              'display_name', v_member.display_name,
              'phone', v_member.phone,
              'message','這支手機的會員已綁定另一個 LINE 帳號，請洽櫃檯協助');
          end if;
        else
          v_action := 'rebound';
        end if;
      else
        v_action := 'existing_phone';
      end if;
      select * into v_member from members where id = v_existing;
      return jsonb_build_object('action',v_action,'member_id',v_member.id,
        'display_name',v_member.display_name,'phone',v_member.phone);
    end if;
  end if;

  insert into members (org_id, display_name, phone, line_user_id, home_store_id, created_by)
  values (p_org_id, v_name, nullif(trim(p_phone),''), p_line_user_id, p_home_store_id, p_created_by)
  returning * into v_member;

  return jsonb_build_object('action','created','member_id',v_member.id,
    'display_name',v_member.display_name,'phone',v_member.phone);
end;
$function$;


/* ──────────────────────────────────────────────────────────
   ② rebind_line_user_tx
   ────────────────────────────────────────────────────────── */

create or replace function public.rebind_line_user_tx(
  p_member_id         uuid,
  p_new_line_user_id  text,
  p_staff_id          uuid,
  p_reason            text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_old text; v_org uuid; v_taken uuid;
begin
  if p_new_line_user_id is null or length(trim(p_new_line_user_id)) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'line_user_id_required');
  end if;

  select line_user_id, org_id into v_old, v_org
    from members where id = p_member_id and deleted_at is null;
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  -- 新的 LINE 帳號若已被其他會員使用，必須先處理那一邊，不可直接覆蓋
  select id into v_taken from members
   where line_user_id = p_new_line_user_id and deleted_at is null and id <> p_member_id;
  if v_taken is not null then
    return jsonb_build_object('ok', false, 'reason', 'line_user_already_bound',
      'bound_member_id', v_taken,
      'message', '此 LINE 帳號已綁定其他會員，請先確認是否為同一人');
  end if;

  update members
     set line_user_id = p_new_line_user_id, updated_at = now()
   where id = p_member_id;

  /* 換綁是敏感操作，必須留下稽核軌跡（誰換的、何時、原因、換前換後）。
     ★ 2026-08-26：改走 log_app_event_tx，不再直接 insert app_events。
     🔴 舊版直接 insert 沒有給 is_test → 走預設 false
       → **測試會員的換綁事件會被標成營運事件**。
       log_app_event_tx 會從 member 推 is_test，這一類污染就不會發生。
     ✅ 事件名 'line_rebind' 本來就符合 `^[a-z][a-z0-9_]{0,49}$`。 */
  perform log_app_event_tx(
    p_org_id    => v_org,
    p_member_id => p_member_id,
    p_event     => 'line_rebind',
    p_props     => jsonb_build_object('old', v_old, 'new', p_new_line_user_id,
                                      'staff_id', p_staff_id, 'reason', p_reason),
    p_client_ts => now());

  return jsonb_build_object('ok', true, 'old_line_user_id', v_old,
    'new_line_user_id', p_new_line_user_id);
end $function$;


/* ============================================================
   驗證段（單一 SELECT）

   ⚠ 硬規則 7：要真的呼叫。兩支都用**不會留下資料**的路徑：
     · register：display_name 空字串 → 在碰任何表之前就 raise
     · rebind：member 不存在 → 回 ok:false，不寫任何東西
   ⚠ 硬規則 3.9：訊息一律設在 exception 處理器裡，
     設在成功路徑上再 raise 的話會被 savepoint 回滾掉（今天踩過）。
   ============================================================ */

do $$
begin
  begin
    perform register_member_tx(gen_random_uuid(), '   ');
    perform set_config('migi.s1', '🔴 空名字竟然通過了', true);
  exception when others then
    perform set_config('migi.s1', '✅ 正確拋錯：' || sqlerrm, true);
  end;
end $$;

select 序, 項目, 結果 from (

  select 0 as 序, '① 兩支的狀態' as 項目,
         string_agg(p.proname || '：' ||
                    (case when p.prosecdef then 'DEFINER' else '🔴 INVOKER' end) ||
                    '／anon ' ||
                    (case when has_function_privilege('anon', p.oid, 'EXECUTE')
                          then '✅' else '🔴 沒有' end), '　│　' order by p.proname) as 結果
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname in ('register_member_tx','rebind_line_user_tx')

  union all
  select 0, '② 版本數（簽名沒變的話各 1）',
         string_agg(t.nm || '：' || t.c::text, '　' order by t.nm)
    from (select p.proname as nm, count(*) as c
            from pg_proc p
           where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
             and p.proname in ('register_member_tx','rebind_line_user_tx')
           group by p.proname) t

  union all
  select 0, '③ register 有沒有真的看 FOUND',
         (case when exists (
                 select 1 from pg_proc p
                  where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
                    and p.proname = 'register_member_tx'
                    and pg_get_functiondef(p.oid) ilike '%line_conflict%')
               then '✅ 有 line_conflict 分支' else '🔴 沒有' end)

  union all
  select 0, '④ rebind 改走 log_app_event_tx 了嗎',
         (case when exists (
                 select 1 from pg_proc p
                  where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
                    and p.proname = 'rebind_line_user_tx'
                    and pg_get_functiondef(p.oid) ilike '%log_app_event_tx%')
               then '✅ 有' else '🔴 還是直接 insert app_events' end)

  union all
  /* ⑤⑥ 順帶把索引那件事查完（不改，只是要知道真相）。
        idx_scan 是決定性的證據：composite 那個到底有沒有被查詢用到，
        還是只當約束在那裡。 */
  select 1, '⑤ members 的索引使用次數',
         s.indexrelname || '：掃描 ' || s.idx_scan::text || ' 次'
    from pg_stat_user_indexes s
   where s.schemaname = 'public' and s.relname = 'members'

  union all
  select 2, '⑥ 煙霧測試（register 空名字）',
         coalesce(current_setting('migi.s1', true), '🔴 DO 區塊沒執行')

) x order by 序, 項目;
