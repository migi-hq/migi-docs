/* ═══════════════════════════════════════════════════════════════════
   按讚發小熊餅乾：獎勵第一次有一條後端的路
   2026-09-19 · 使用者定規則：「一個讚 1 個，同一場最多 3 個」
   ═══════════════════════════════════════════════════════════════════

   🔴 **起點是一句已經寫在畫面上的承諾**：收桌結算那一頁寫著
     「覺得對方牌品好？給他個讚，可獲得小熊餅乾 1 個」——
     而點心今天存在 `member_app_state.bear.snacks`，
     由 `save_app_state_tx` **整包覆蓋**，也就是**前端說了算**。
   ⇒ 打開 devtools 就能塞 999 個餅乾，而那個承諾等於沒有意義。
   📌 同一族的病第二次：稱號的 `titles` 也是前端寫的（待辦 40）。
     那一條的原話是「守衛擋的是**前端有沒有先寫進去**，不是他有沒有達成」。

   ── 這份做三件事 ────────────────────────────────────
   ① `snack_grants` —— **append-only 的發放帳本**。
      🎯 不是「加一欄計數」：計數欄會漂、會被覆蓋，而且事後無從得知
        「這 8 個餅乾是怎麼來的」。帳本回答得出來，而且冪等鍵就長在上面。
      📌 形狀比照 `wallet_txns`（這個專案唯一一個做對的流水）。
   ② `grant_snack_tx` —— **唯一的發放入口**，帶冪等鍵。
      ⚠ 內部函式：anon／authenticated／PUBLIC 三個方向都收掉。
        前端**永遠不該**直接叫它（那就回到「前端說了算」）。
   ③ `like_player_tx` 按讚成功時發 1 個。

   ── 規則（使用者 2026-09-19 拍板）────────────────────
   · 一個讚 1 個餅乾，**同一場、同一個被讚的人只發一次**
   · 一場最多 3 個（同桌另外三人）—— 這是上面那條的自然結果，不另外算
   · **取消讚不收回** —— 收回會讓人學會「不要按讚」，而那顆讚的目的是鼓勵
   · 🔴 **沒有 session 就不發**：獎勵綁在一場牌局上，
     而且要**兩個人都真的坐過那一桌**，否則任意送一個 session_id 就能刷

   ⚠ 新表一律開 RLS 且**不給任何 policy** —— 這個專案 46 張表裡有 20 張
     是這個狀態，那是最安全的狀態不是漏掉（只有 SECURITY DEFINER 進得去）。
   ⚠ 這份要留下 DDL ⇒ 驗證段一個字都不准 raise（硬規則 1.8）。
     行為測試在 `sql/checks/2026-09-19_驗按讚發餅乾.sql`。
   ═══════════════════════════════════════════════════════════════════ */


/* ═══ ① 發放帳本 ═══════════════════════════════════════════════ */
create table if not exists public.snack_grants (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.orgs(id)    on delete restrict,
  member_id   uuid not null references public.members(id) on delete restrict,
  /* 四種點心與 `rewards.jsx` 的 `SNACKS` 逐字相同。
     ⚠ 加第五種時**這裡與前端要一起加** —— 白名單寫在兩邊是已知的代價，
       換來的是「前端塞一個不存在的點心」會當場失敗而不是靜靜寫進去。 */
  kind        text not null check (kind in ('cookie','milktea','pudding','tiramisu')),
  qty         int  not null check (qty > 0),
  /* 為什麼發。⚠ 這一欄的值會長出來（每日報到、每週任務、抽獎…），
     所以留 CHECK 不留 enum —— 加一個值只要改 CHECK，不用 migration。 */
  reason      text not null check (reason in ('like','daily','task','draw','admin')),
  ref_id      uuid,          -- like → session_id；日後其他來源各自的單據
  /* 🔴 冪等鍵是這張表的重點。按讚會被重複觸發（取消再按、兩台裝置、網路重試），
     而**發放不可以重複**。唯一索引讓那件事變成資料庫的保證，不是程式的自律。 */
  idem_key    text not null,
  created_at  timestamptz not null default now()
);

create unique index if not exists uq_snack_grants_idem on public.snack_grants (idem_key);
create index if not exists ix_snack_grants_member on public.snack_grants (member_id, created_at desc);

alter table public.snack_grants enable row level security;
/* ⚠ **刻意 0 條 policy**：這張表只給 SECURITY DEFINER 的函式進出。
   要讓客人看得到自己的發放紀錄時，那是加一條 `member_id = current_member_id()`
   的 SELECT policy，不是現在先開一條。 */


/* ═══ ② 唯一的發放入口 ═══════════════════════════════════════════
   回 `{ ok, granted, kind, qty, total }`；`granted=false` 代表這一筆
   之前發過了（冪等），**不是錯誤**。 */
create or replace function public.grant_snack_tx(
  p_org_id uuid, p_member_id uuid, p_kind text, p_qty int,
  p_reason text, p_ref_id uuid, p_idem_key text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_id    uuid;
  v_total int;
begin
  if p_member_id is null or p_kind is null or coalesce(p_qty, 0) <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_args');
  end if;

  /* 冪等：同一把鑰匙只發一次。
     ⚠ 用 `on conflict do nothing` ＋ 看 `returning` 有沒有回值 ——
       先 select 再 insert 會在併發下發兩次（兩個請求同時查到「還沒發」）。 */
  insert into snack_grants (org_id, member_id, kind, qty, reason, ref_id, idem_key)
  values (p_org_id, p_member_id, p_kind, p_qty, p_reason, p_ref_id, p_idem_key)
  on conflict (idem_key) do nothing
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('ok', true, 'granted', false, 'reason', 'already_granted');
  end if;

  /* 點心的**顯示值**仍然住在 `member_app_state.bear.snacks`（前端在讀那裡）。
     🔴 但從今天起它是**帳本的結果**不是來源 —— 要對帳就數 `snack_grants`。
     ⏳ 下一步（另一份 SQL）是讓 `save_app_state_tx` 不再接受 snacks，
       否則前端仍然可以整包覆蓋掉這個值。**那一步才是真正關上門的一步。** */
  insert into member_app_state (member_id, org_id, bear, titles, updated_at)
  values (p_member_id, p_org_id,
          jsonb_build_object('snacks', jsonb_build_object(p_kind, p_qty)),
          '[]'::jsonb, now())
  on conflict (member_id) do update set
    bear = jsonb_set(
             coalesce(member_app_state.bear, '{}'::jsonb),
             array['snacks', p_kind],
             to_jsonb(
               coalesce((member_app_state.bear -> 'snacks' ->> p_kind)::int, 0) + p_qty
             ),
             true),
    updated_at = now();

  select coalesce((bear -> 'snacks' ->> p_kind)::int, 0) into v_total
    from member_app_state where member_id = p_member_id;

  return jsonb_build_object('ok', true, 'granted', true,
    'kind', p_kind, 'qty', p_qty, 'total', v_total);
end $function$;

/* 🔴 內部函式，兩個方向都要收（硬規則 2.6b）：
   舊函式的 anon 來自 PUBLIC 繼承、新函式來自 default privileges 的明確授權，
   只收一邊完全沒有效果而且不會報錯。 */
revoke execute on function public.grant_snack_tx(uuid, uuid, text, int, text, uuid, text) from public;
revoke execute on function public.grant_snack_tx(uuid, uuid, text, int, text, uuid, text) from anon, authenticated;
grant  execute on function public.grant_snack_tx(uuid, uuid, text, int, text, uuid, text) to service_role;


/* ═══ ③ 按讚時發 ═══════════════════════════════════════════════
   ⚠ 簽名不變 ⇒ CREATE OR REPLACE，前端照舊呼叫（只是要開始送 p_session）。 */
create or replace function public.like_player_tx(p_org_id uuid, p_liker uuid, p_target uuid, p_on boolean, p_session uuid default null::uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_today_like uuid;
  v_both       int;
begin
  if p_liker = p_target then raise exception '不能讚自己'; end if;
  -- 找今天(台北營業日)對同一人的讚
  select id into v_today_like from member_likes
   where liker_id = p_liker and target_id = p_target
     and (p_session is not null and session_id = p_session
          or p_session is null and (created_at at time zone 'Asia/Taipei')::date = (now() at time zone 'Asia/Taipei')::date)
   limit 1;
  if p_on then
    if v_today_like is not null then return; end if;  -- 已讚過，冪等
    insert into member_likes(org_id, liker_id, target_id, session_id)
    values (p_org_id, p_liker, p_target, p_session);
    update members set likes_count = likes_count + 1 where id = p_target;

    /* 🆕 2026-09-19：按讚發小熊餅乾 1 個（使用者定的規則）。
       🔴 **兩道門，缺一不可**：
         ① 沒有 session 不發 —— 獎勵綁在一場牌局上，
            「同一場最多 3 個」這條規則才有意義。
         ② **兩個人都要真的坐過那一桌** —— 否則隨便送一個 session_id
            就能對任何人按讚換餅乾，而那是刷點心的門。
       ⚠ 上限 3 個是**自然結果**不是另外算的：一場只有另外三個人，
         而冪等鍵綁 (session, liker, target) ⇒ 每個人最多發一次。
       ⚠ 取消讚**不收回**（帳本 append-only）——
         收回會讓人學會不要按讚，而那顆讚的目的是鼓勵。
       ⚠ 發放失敗不可以讓按讚整個失敗：讚已經進去了，
         而客人看到的是「按了沒反應」。所以吞例外。 */
    if p_session is not null then
      select count(*) into v_both
        from session_players sp
       where sp.session_id = p_session
         and sp.member_id in (p_liker, p_target);
      if v_both = 2 then
        begin
          perform public.grant_snack_tx(
            p_org_id, p_liker, 'cookie', 1, 'like', p_session,
            'like:' || p_session::text || ':' || p_liker::text || ':' || p_target::text);
        exception when others then null;
        end;
      end if;
    end if;
  else
    if v_today_like is null then return; end if;
    delete from member_likes where id = v_today_like;
    update members set likes_count = greatest(0, likes_count - 1) where id = p_target;
  end if;
end $function$;


/* ═══ 驗證段（不 raise）═══════════════════════════════════════ */
do $$
declare
  v_msg text := '';
  v_def text;
  v_n   int;
  v_a   boolean;
  v_p   boolean;
begin
  /* ① 表與兩個索引 */
  select count(*) into v_n from information_schema.tables
   where table_schema = 'public' and table_name = 'snack_grants';
  v_msg := case when v_n = 1 then '✅ ① snack_grants 建好了' else '🔴 ① 表不存在' end;

  select count(*) into v_n from pg_indexes
   where schemaname = 'public' and tablename = 'snack_grants'
     and indexname in ('uq_snack_grants_idem', 'ix_snack_grants_member');
  v_msg := v_msg || E'\n' || case when v_n = 2
    then '✅ ② 冪等索引與查詢索引都在'
    else '🔴 ② 索引只有 ' || v_n || '／2 —— 少了冪等索引就會重複發' end;

  /* ③ RLS 開著而且 0 條 policy（這張表只給 DEFINER 進出）*/
  select count(*) into v_n from pg_policies where schemaname = 'public' and tablename = 'snack_grants';
  v_msg := v_msg || E'\n' || case
    when (select relrowsecurity from pg_class where oid = 'public.snack_grants'::regclass) and v_n = 0
    then '✅ ③ RLS 開著且 0 條 policy（最安全的狀態）'
    else '🔴 ③ RLS 沒開或有 policy（' || v_n || ' 條）' end;

  /* ④ 發放函式兩個方向都收了 */
  select exists (select 1 from aclexplode(coalesce(p.proacl,'{}')) a
                  where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE'),
         (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                  where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
    into v_a, v_p
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'grant_snack_tx';
  v_msg := v_msg || E'\n' || case when not v_a and not v_p
    then '✅ ④ grant_snack_tx：anon ✗、PUBLIC ✗（前端叫不動，只能經由按讚那條路）'
    else '🔴 ④ grant_snack_tx 還叫得動 —— anon明確=' || v_a || ' PUBLIC=' || v_p end;

  /* ⑤ 按讚那支真的接上了，而且兩道門都在 */
  v_def := pg_get_functiondef('public.like_player_tx(uuid,uuid,uuid,boolean,uuid)'::regprocedure);
  v_msg := v_msg || E'\n' || case
    when v_def ilike '%grant_snack_tx%'
     and v_def ilike '%session_players%'
     and v_def ilike '%p_session is not null%'
    then '✅ ⑤ 按讚會發餅乾，而且「要有 session」與「兩人都坐過」兩道門都在'
    else '🔴 ⑤ 少了發放或少了擋牆 —— 那是刷點心的門' end;

  /* ⑥ 負對照：按讚那支**沒有**在取消時扣回餅乾（使用者定的規則）*/
  v_msg := v_msg || E'\n' || case
    when v_def not ilike '%delete from snack_grants%'
     and v_def not ilike '%qty * -1%'
    then '✅ ⑥ 取消讚不收回餅乾（帳本 append-only）'
    else '🔴 ⑥ 有人加了收回的邏輯 —— 那與 2026-09-19 的決定相反' end;

  /* ⑦ 現況：目前發出去幾個（這份跑完應該還是 0 —— 要有人真的按一次讚）*/
  select count(*) into v_n from snack_grants;
  v_msg := v_msg || E'\n📌 ⑦ 目前發放紀錄 ' || v_n
        || ' 筆（這份只是讓它從此會發；前端要開始送 p_session 才會真的發）';

  perform set_config('migi.verify_snack', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify_snack', true), ''), '🔴 沒有驗證訊息') as "驗證";
