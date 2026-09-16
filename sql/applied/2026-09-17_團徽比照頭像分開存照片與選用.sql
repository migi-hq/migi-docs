/* ═══════════════════════════════════════════════════════════════════
   團徽比照頭像：「存著的照片」與「現在用哪一種」分開
   2026-09-17 · 使用者實機回報
   ═══════════════════════════════════════════════════════════════════

   使用者：「上傳照片後無法選擇預設，套用按鈕也不見了」。

   🔴 根因是**資料結構**，不是畫面：
     頭像有兩個欄位 ——
       avatar_photo_path   存著的那張照片
       avatar_source       現在用哪一種（bear / photo / line）
     ⇒ 照片可以留著、同時選用小熊，按「套用」才切換。
     團徽**只有一個** `crest_path`：照片存在就等於正在用
     ⇒「選預設」只能做成**刪掉照片**，而「套用」沒有東西可以套用。
     09-17 稍早我照著那個結構把套用拿掉了 —— 那是順著薄弱的結構做，
     而使用者要的是頭像那一套（硬規則 5.5：結構太薄弱時要直接說）。

   ✅ 補一個 `teams.crest_source`（'default' | 'photo'），語意與 `avatar_source` 相同：
     · 上傳（`set_team_crest_tx`）**只存照片**，不改 source
     · 「套用」走新的 `set_team_crest_source_tx` 切換 source
     · 刪照片（團長 `clear_team_crest_tx`、總部 `admin_remove_team_crest_tx`）
       順便把 source 切回 default —— 否則下次一上傳就自動生效，繞過套用

   🎯 **所有畫團徽的地方一行都不用改**：`_team_card` 的 `crest_path` 改成
     「**正在用的那張**」（source = photo 才給），另外多回 `crest_photo_path`
     （存著的那張，只有換團徽抽屜要讀）與 `crest_source`。
     📌 同頭像：名冊與卡片只問「現在長什麼樣」，只有抽屜要知道「存了什麼」。

   ⚠ 回填：已經有照片的團 → source = photo（它們今天就是在用照片，不能因為
     加欄位就變回預設）。
   ⚠ 這份要留下 DDL ⇒ 驗證段一個字都不准 raise（硬規則 1.8）。
   ⚠ `_team_card`／`clear_team_crest_tx`／`admin_remove_team_crest_tx`
     簽名都不變 ⇒ CREATE OR REPLACE、不丟 GRANT。新函式自己收授權（硬規則 2.6b）。
   ═══════════════════════════════════════════════════════════════════ */

-- ① 欄位 ＋ 允許值
alter table public.teams
  add column if not exists crest_source text not null default 'default';

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'teams_crest_source_check'
                    and conrelid = 'public.teams'::regclass) then
    alter table public.teams
      add constraint teams_crest_source_check check (crest_source in ('default', 'photo'));
  end if;
end $$;

comment on column public.teams.crest_source is
  '團徽現在用哪一種：default（預設團徽／舊團的圖示）或 photo（crest_path 那張照片）。'
  '與 members.avatar_source 同一個形狀：照片可以存著但不使用，按「套用」才切換。';

-- ② 回填：今天有照片的團，今天就是在用照片
update public.teams
   set crest_source = 'photo'
 where crest_path is not null and crest_source = 'default';


-- ③ 團卡：crest_path 改成「正在用的那張」，另外回存著的那張
create or replace function public._team_card(p_team_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_t      record;
  v_from   timestamptz;
  v_played int;
  v_month  int;
  v_cnt    int;
  v_me     uuid := public.current_member_id();
  v_req    text;
begin
  select t.*, s.name as store_name
    into v_t
    from public.teams t
    left join public.stores s on s.id = t.home_store_id
   where t.id = p_team_id and t.deleted_at is null;
  if not found then return null; end if;

  /* 「本月」用台北日曆月，與當日暢打同一個判準 ——
     系統裡不要有第二種「這個月是哪一段」。 */
  v_from := (date_trunc('month', (now() at time zone 'Asia/Taipei')) at time zone 'Asia/Taipei');

  select count(*), count(*) filter (where played_at >= v_from)
    into v_played, v_month
    from public._team_session_ids(p_team_id);

  select count(*) into v_cnt
    from public.team_members where team_id = p_team_id and left_at is null;

  /* 我跟這個團之間還在談的那一筆是什麼。
     ⚠ 沒登入時 `v_me` 是 null ⇒ 這段查不到東西 ⇒ 回 null，那是對的。
     ⚠ 不需要 order by / limit：部分唯一索引保證同一人對同一團最多一筆在談。 */
  select r.kind into v_req
    from public.team_requests r
   where r.team_id = p_team_id and r.member_id = v_me
     and r.status = 'pending' and r.expires_at > now();

  return jsonb_build_object(
    'id',              v_t.id,
    'name',            v_t.name,
    'intro',           v_t.intro,
    'crest_emoji',     v_t.crest_emoji,
    /* 🔴 2026-09-17：`crest_path` 是**正在用的那張** —— source 是 photo 才給。
       所有畫團徽的地方（名冊、團卡、熱門榜、成功卡）都只讀這一欄，
       所以「照片存著但選用預設」時它們自動畫預設，一行都不用改。
       ⚠ 被總部下架（crest_blocked）時仍然一律 null。 */
    'crest_path',      case when v_t.crest_blocked or v_t.crest_source <> 'photo'
                            then null else v_t.crest_path end,
    /* 存著的那張（不管有沒有在用）—— 只有換團徽抽屜要讀。 */
    'crest_photo_path', case when v_t.crest_blocked then null else v_t.crest_path end,
    'crest_source',    v_t.crest_source,
    'join_policy',     v_t.join_policy,
    'home_store_id',   v_t.home_store_id,
    'home_store_name', v_t.store_name,
    'monthly_goal',    v_t.monthly_goal,
    'member_limit',    v_t.member_limit,
    'member_count',    v_cnt,
    'played',          v_played,
    'month_played',    v_month,
    'my_request',      v_req,
    'created_at',      v_t.created_at);
end $function$;


-- ④ 新：切換「現在用哪一種」（抽屜的「套用」）
create or replace function public.set_team_crest_source_tx(p_team_id uuid, p_source text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_me   uuid := public.current_member_id();
  v_path text;
  v_blk  boolean;
begin
  /* 身分一律從 JWT 解析，不收 p_member_id（CLAUDE.md 待辦 14 的通則）。 */
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_source is null or p_source not in ('default', 'photo') then
    return jsonb_build_object('ok', false, 'reason', 'bad_source', 'message', '團徽選項不正確');
  end if;
  if not public._is_team_leader(p_team_id, v_me) then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以換團徽');
  end if;

  select t.crest_path, t.crest_blocked into v_path, v_blk
    from public.teams t where t.id = p_team_id and t.deleted_at is null;
  if v_blk is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;

  /* 選照片要**真的有一張**，而且沒被總部停用 ——
     否則會切到一個畫不出來的狀態（卡片退回預設，而抽屜顯示選了照片）。 */
  if p_source = 'photo' and v_path is null then
    return jsonb_build_object('ok', false, 'reason', 'no_photo', 'message', '還沒有上傳照片');
  end if;
  if p_source = 'photo' and v_blk then
    return jsonb_build_object('ok', false, 'reason', 'crest_blocked',
                              'message', '這個團的自訂團徽已停用');
  end if;

  update public.teams
     set crest_source = p_source, updated_at = now()
   where id = p_team_id and deleted_at is null;

  return jsonb_build_object('ok', true, 'team', public._team_card(p_team_id));
end $function$;

/* 🔴 新建的函式預設是 anon 明確授權（硬規則 2.6b）——兩個方向都收。
   團長操作只給登入的人（authenticated）。 */
revoke execute on function public.set_team_crest_source_tx(uuid, text) from public;
revoke execute on function public.set_team_crest_source_tx(uuid, text) from anon;
grant  execute on function public.set_team_crest_source_tx(uuid, text) to authenticated, service_role;


-- ⑤ 團長刪照片：順便切回 default
create or replace function public.clear_team_crest_tx(p_team_id uuid, p_member_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_old text;
begin
  if not public._is_team_leader(p_team_id, p_member_id) then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以換團徽');
  end if;

  select t.crest_path into v_old from public.teams t
   where t.id = p_team_id and t.deleted_at is null;

  /* 🔴 兩個欄位一起清才是「回到預設」。
     只清照片的話，設過圖示的團會退回那個圖示而不是預設團徽。
     🔴 2026-09-17：**source 也一起切回 default** —— 否則照片刪掉之後
       source 還停在 photo，下次一上傳就自動生效，繞過「套用」。
     ⚠ `crest_blocked` **不在這裡碰**：那是總部下架違規團徽用的旗標。 */
  update public.teams
     set crest_path = null, crest_emoji = null, crest_source = 'default', updated_at = now()
   where id = p_team_id and deleted_at is null;

  /* 回傳舊路徑讓 Edge Function 去刪 storage 的檔案 ——
     路徑由這裡給，不採信呼叫端送的。 */
  return jsonb_build_object('ok', true, 'path', v_old);
end $function$;


-- ⑥ 總部下架：同樣切回 default
create or replace function public.admin_remove_team_crest_tx(p_team_id uuid, p_reason text default null::text, p_block boolean default false)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_old text;
begin
  if not public.can('member.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限');
  end if;

  select t.crest_path into v_old from public.teams t
   where t.id = p_team_id and t.deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;

  /* 🔴 2026-09-17：source 一起切回 default（理由同 clear_team_crest_tx）。 */
  update public.teams
     set crest_path = null,
         crest_source = 'default',
         crest_blocked = coalesce(p_block, false) or crest_blocked,
         updated_at = now()
   where id = p_team_id;

  /* ⚠ 只回「本來有沒有照片」，不回路徑 —— 路徑是 Storage 的公開網址。 */
  return jsonb_build_object('ok', true, 'had_photo', v_old is not null,
                            'blocked', coalesce(p_block, false), 'reason_note', p_reason);
end $function$;


/* ═══ 驗證段（不 raise，訊息走 set_config → 最後一支 SELECT）═══ */
do $$
declare
  v_msg text := '';
  v_n   int;
  v_ok  boolean;
  v_oid oid;
begin
  /* ① 欄位與允許值 */
  select count(*) into v_n from information_schema.columns
   where table_schema = 'public' and table_name = 'teams' and column_name = 'crest_source'
     and is_nullable = 'NO';
  select exists (select 1 from pg_constraint
                  where conname = 'teams_crest_source_check'
                    and conrelid = 'public.teams'::regclass) into v_ok;
  v_msg := v_msg || case when v_n = 1 and v_ok
    then '✅ ① teams.crest_source 在（NOT NULL ＋ 允許值 default／photo）'
    else '🔴 ① 欄位或允許值沒建好' end;

  /* ② 回填：有照片卻還是 default 的團應該是 0
     📌 同時印總數 —— 0 可能是「全部回填了」也可能是「本來就沒有照片」（硬規則 3.55）。 */
  select count(*) into v_n from public.teams
   where crest_path is not null and crest_source = 'default' and deleted_at is null;
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ② 有照片的團都是 photo（有照片的團共 '
         || (select count(*) from public.teams where crest_path is not null and deleted_at is null)
         || ' 個）'
    else '🔴 ② 還有 ' || v_n || ' 個有照片的團停在 default —— 它們會突然變回預設團徽' end;

  /* ③ 團卡多回兩個鍵，而且 crest_path 看 source */
  select pg_get_functiondef('public._team_card(uuid)'::regprocedure) ilike '%crest_photo_path%'
     and pg_get_functiondef('public._team_card(uuid)'::regprocedure) ilike '%crest_source <> ''photo''%'
    into v_ok;
  v_msg := v_msg || E'\n' || case when v_ok
    then '✅ ③ 團卡：crest_path 只給正在用的、另回 crest_photo_path／crest_source'
    else '🔴 ③ 團卡沒改到' end;

  /* ④ 新函式：DEFINER、登入的人叫得動、anon 明確與 PUBLIC 都沒有（兩個方向都驗，硬規則 2.6） */
  select p.oid into v_oid from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'set_team_crest_source_tx' and p.prokind = 'f';
  if v_oid is null then
    v_msg := v_msg || E'\n🔴 ④ set_team_crest_source_tx 不存在';
  else
    v_msg := v_msg || E'\n' || case
      when (select prosecdef from pg_proc where oid = v_oid)
       and exists (select 1 from aclexplode((select proacl from pg_proc where oid = v_oid)) a
                    where a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE')
       and not exists (select 1 from aclexplode((select proacl from pg_proc where oid = v_oid)) a
                        where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
       and not exists (select 1 from aclexplode((select proacl from pg_proc where oid = v_oid)) a
                        where a.grantee = 0 and a.privilege_type = 'EXECUTE')
      then '✅ ④ set_team_crest_source_tx：DEFINER · authenticated 有 · anon 明確無 · PUBLIC 無'
      else '🔴 ④ 新函式的 DEFINER 或授權不對' end;
  end if;

  /* ⑤ 兩支刪照片的函式都會把 source 切回 default */
  select pg_get_functiondef('public.clear_team_crest_tx(uuid,uuid)'::regprocedure) ilike '%crest_source = ''default''%'
     and pg_get_functiondef('public.admin_remove_team_crest_tx(uuid,text,boolean)'::regprocedure) ilike '%crest_source = ''default''%'
    into v_ok;
  v_msg := v_msg || E'\n' || case when v_ok
    then '✅ ⑤ 團長刪照片、總部下架都會切回 default'
    else '🔴 ⑤ 有一支刪照片的函式沒切回 default —— 下次上傳會繞過套用' end;

  /* ⑥ 正對照：舊的呼叫點沒被打壞（set_team_crest_tx 與 get_team_tx 授權還在） */
  select has_function_privilege('authenticated', 'public.set_team_crest_tx(uuid,text,text)', 'execute')
     and has_function_privilege('authenticated', 'public.get_team_tx(uuid)', 'execute')
    into v_ok;
  v_msg := v_msg || E'\n' || case when v_ok
    then '✅ ⑥ 上傳與讀團詳情的授權都還在'
    else '🔴 ⑥ 既有函式的授權掉了' end;

  perform set_config('migi.verify_crest_source', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify_crest_source', true), ''),
                '🔴 沒有驗證訊息') as "驗證";
