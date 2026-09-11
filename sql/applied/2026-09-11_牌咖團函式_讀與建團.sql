/* ============================================================
   牌咖團 RPC 第一批：讀取四支 ＋ 建團／改團／團徽／解散
   2026-09-11 · 接在 `2026-09-11_牌咖團地基.sql`（已跑，8/8）之後

   加入流程（申請／邀請／回應／退團／移除／轉讓／失聯接管）在第二批。
   拆開的理由同上一份：**一次疊太多支，紅了分不出是哪一支的問題**。

   ⚠ 這份要留下函式，所以**整份不准 `raise`**（硬規則 1.8）。
     驗證段只跑**唯讀**的那幾支，而且是借一個真身分跑的（見下）。
     寫入路徑（建團、改團、解散）的行為測試在
     `sql/checks/2026-09-11_驗牌咖團建團與治理.sql`，那一份才會 raise 回滾。

   ── 🔴 身分一律從 JWT 取，不收 `p_member_id` ─────────
   今天全庫有 53 支函式的簽名帶著 `p_member_id`，**不要變成 54**。
   待辦 14 的盤點證明正式站的 JWT 是通的（`member_id_src` jwt / host=prod，
   `jwt_override` 是 0）。所以這一批一律：
   ```
   grant   execute to authenticated
   revoke  execute from anon, public          ← 兩個方向都要收（硬規則 2.6b）
   ```
   ⚠ **已知代價，講在前面**：某個客人的 Supabase session 沒發成功時，
     牌咖團整頁會 403，而其他頁（還走 anon ＋ 前端送 id）照常。
     那是**大聲失敗**，比「靜靜地拿到別人的資料」好，而且它會自己出現在
     `member_session` 那個探針上。

   ── 🔴 團員名冊刻意不回 `member_id` 給一般團員 ────────
   2026-09-04 建排行榜時定的原則：**名次不需要身分**，回傳 member uuid
   等於公開發送一批通行證（`get_wallet_tx` 今天仍是 anon ＋ 前端送 id）。
   名冊同理 —— 只有**團長**拿得到 id，因為只有他要按「移除」與「轉讓團長」。
   ⚠ 那一層在函式裡判斷，不是在前端隱藏。

   ── 🔴 名冊不顯示「他上次來店是什麼時候」 ────────────
   每一款手遊的公會名冊都有那一欄，因為那是團長決定踢誰的依據。
   **但這個系統不准。** 2026-08-26 為「常來時段」畫過一條線：
   對別人的單向側寫不給客人看，連本人都不給。牌咖卡的「上次同桌」
   能顯示是因為那是**兩個人共同的事實**。
   ⇒ 名冊給的是「本月一起打了幾場」，那仍然是共同事實。
   ============================================================ */


/* ─────────────────────────────────────────────────────────
   ① `_team_card` —— 團卡的唯一定義
   ───────────────────────────────────────────────────────── */
/* 我的團、找團、熱門榜、詳情頁 —— 四個地方要畫同一張卡。
   各抄一份的話，「人數」或「本月幾場」遲早會在某一頁算得不一樣，
   **而它不會報錯**（這個專案記過八次的同一族病）。

   🔴 `crest_path` 在被下架時一律回 null —— 下架只判斷一次，
     不要讓四個呼叫點各自記得檢查 `crest_blocked`。 */
create or replace function public._team_card(p_team_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_t      record;
  v_from   timestamptz;
  v_played int;
  v_month  int;
  v_cnt    int;
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

  return jsonb_build_object(
    'id',              v_t.id,
    'name',            v_t.name,
    'intro',           v_t.intro,
    'crest_emoji',     v_t.crest_emoji,
    'crest_path',      case when v_t.crest_blocked then null else v_t.crest_path end,
    'join_policy',     v_t.join_policy,
    'home_store_id',   v_t.home_store_id,
    'home_store_name', v_t.store_name,
    'monthly_goal',    v_t.monthly_goal,
    'member_limit',    v_t.member_limit,
    'member_count',    v_cnt,
    'played',          v_played,
    'month_played',    v_month,
    'created_at',      v_t.created_at);
end $$;

revoke execute on function public._team_card(uuid) from public;
revoke execute on function public._team_card(uuid) from anon, authenticated;


/* ─────────────────────────────────────────────────────────
   ② list_my_teams_tx —— 牌咖團分頁的「我的牌咖團」
   ───────────────────────────────────────────────────────── */
create or replace function public.list_my_teams_tx()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me   uuid := public.current_member_id();
  v_rows jsonb;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  select coalesce(jsonb_agg(x order by x->>'joined_at'), '[]'::jsonb)
    into v_rows
    from (
      select public._team_card(tm.team_id)
             || jsonb_build_object(
                  'my_role',   tm.role,
                  'joined_at', tm.joined_at,
                  /* 待審核筆數只有團長看得到 —— 一般團員看到一個數字
                     卻按不下去，那比沒有更糟。 */
                  'pending_count',
                  case when tm.role = 'leader' then (
                    select count(*) from public.team_requests r
                     where r.team_id = tm.team_id and r.status = 'pending'
                       and r.kind = 'apply' and r.expires_at > now())
                  else 0 end) as x
        from public.team_members tm
        join public.teams t on t.id = tm.team_id and t.deleted_at is null
       where tm.member_id = v_me and tm.left_at is null
    ) s;

  return jsonb_build_object('ok', true, 'teams', v_rows);
end $$;


/* ─────────────────────────────────────────────────────────
   ③ get_team_tx —— 團詳情
   ───────────────────────────────────────────────────────── */
/* ⚠ 非團員也叫得動，但**只拿得到團卡，拿不到名冊** ——
   找團那頁點進去要看得到「這個團長什麼樣」，而名冊是團內的事。
   遊戲的公會列表也是這個分法：看得到公會卡，看不到成員清單。 */
create or replace function public.get_team_tx(p_team_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me      uuid := public.current_member_id();
  v_card    jsonb;
  v_role    text;
  v_from    timestamptz;
  v_members jsonb;
  v_pending int := 0;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  v_card := public._team_card(p_team_id);
  if v_card is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;

  select tm.role into v_role
    from public.team_members tm
   where tm.team_id = p_team_id and tm.member_id = v_me and tm.left_at is null;

  if v_role is null then
    return jsonb_build_object('ok', true, 'team', v_card, 'my_role', null, 'members', '[]'::jsonb);
  end if;

  v_from := (date_trunc('month', (now() at time zone 'Asia/Taipei')) at time zone 'Asia/Taipei');

  select coalesce(jsonb_agg(x order by x->>'role', x->>'joined_at'), '[]'::jsonb)
    into v_members
    from (
      select jsonb_build_object(
               /* 🔴 只有團長拿得到 member_id，理由見檔頭。 */
               'member_id', case when v_role = 'leader' then tm.member_id else null end,
               'is_me',     tm.member_id = v_me,
               'nickname',  m.display_name,
               'rank',      m.rank,
               'title',     m.title,
               'role',      tm.role,
               'joined_at', tm.joined_at,
               /* 本月貢獻 ＝ 這個月算進團戰績的場次裡，他坐過幾場。
                  ⚠ 用同一支 `_team_session_ids`，不要在這裡另外寫一份判定。 */
               'month_contrib', (
                 select count(*) from public._team_session_ids(p_team_id) ts
                  where ts.played_at >= v_from
                    and exists (select 1 from public.session_players sp
                                 where sp.session_id = ts.session_id
                                   and sp.member_id = tm.member_id))) as x
        from public.team_members tm
        join public.members m on m.id = tm.member_id
       where tm.team_id = p_team_id and tm.left_at is null
    ) s;

  if v_role = 'leader' then
    select count(*) into v_pending
      from public.team_requests r
     where r.team_id = p_team_id and r.status = 'pending'
       and r.kind = 'apply' and r.expires_at > now();
  end if;

  return jsonb_build_object('ok', true, 'team', v_card, 'my_role', v_role,
                            'members', v_members, 'pending_count', v_pending);
end $$;


/* ─────────────────────────────────────────────────────────
   ④ search_teams_tx —— 找團／推薦給你
   ───────────────────────────────────────────────────────── */
/* 🔴 `closed` 的團完全不出現在這一頁。
   那是「不接受申請」的意思，列出來只會讓人按了被拒絕 ——
   而一個按下去一定失敗的按鈕比沒有那個團更糟。
   ⇒ closed 的團只能靠團長邀請加入，那是它存在的目的。

   沒有關鍵字時的排序理由是「你常去的門市」，而**那句話會印在畫面上**
   （`buddies.jsx:166` 已經有「推薦給你 · 你常去自由店」）。
   ⚠ 所以排序理由一定要與畫面那句話一致，不可以私下改成別的。 */
create or replace function public.search_teams_tx(p_q text default null,
                                                  p_limit int default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me    uuid := public.current_member_id();
  v_org   uuid := public.current_org_id();
  v_store uuid;
  v_name  text;
  v_q     text := nullif(btrim(coalesce(p_q, '')), '');
  v_rows  jsonb;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  /* 我最常去的門市。沒有場次紀錄的新客人回 null，那時就純粹依人數排。 */
  select ts.store_id into v_store
    from public.session_players sp
    join public.table_sessions ts on ts.id = sp.session_id
   where sp.member_id = v_me and ts.deleted_at is null
   group by ts.store_id
   order by count(*) desc
   limit 1;

  select s.name into v_name from public.stores s where s.id = v_store;

  select coalesce(jsonb_agg(card order by ord, cnt desc, nm), '[]'::jsonb)
    into v_rows
    from (
      select public._team_card(t.id) as card,
             case when v_store is not null and t.home_store_id = v_store then 0 else 1 end as ord,
             (select count(*) from public.team_members tm
               where tm.team_id = t.id and tm.left_at is null) as cnt,
             t.name as nm
        from public.teams t
       where t.org_id = v_org
         and t.deleted_at is null
         and t.join_policy <> 'closed'
         /* 已經在裡面的團不要出現在找團頁 —— 按下去只會回「你已經在團裡」。 */
         and not exists (select 1 from public.team_members tm
                          where tm.team_id = t.id and tm.member_id = v_me and tm.left_at is null)
         and (v_q is null or t.name ilike '%' || v_q || '%')
       limit greatest(1, least(coalesce(p_limit, 20), 50))
    ) s;

  return jsonb_build_object('ok', true, 'teams', v_rows,
                            'q', v_q,
                            /* 前端靠這兩個決定要不要印「推薦給你 · 你常去 OO」。
                               ⚠ 有搜尋時不要再說「推薦給你」—— 那是沒搜尋時的排序理由
                                 （`buddies.jsx:165` 的註解已經寫過這件事）。 */
                            'recommend_store_id',   case when v_q is null then v_store end,
                            'recommend_store_name', case when v_q is null then v_name end);
end $$;


/* ─────────────────────────────────────────────────────────
   ⑤ list_hot_teams_tx —— 熱門牌咖團榜
   ───────────────────────────────────────────────────────── */
/* 🔴 依**人數**排，場數只當同票時的第二順位。
   那是 `buddies.jsx:219` 那行註解本來就寫的排序理由（「比人數＝人氣」），
   而 2026-09-11 使用者確認牌咖團等同公會 ⇒ 人數是對的指標。
   ⚠ 這裡**不排除 closed** —— 熱門榜是「這些團很熱鬧」不是「你可以加入」，
     而前端對 closed 的團不畫「申請」鈕。 */
create or replace function public.list_hot_teams_tx(p_limit int default 5)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org  uuid := public.current_org_id();
  v_rows jsonb;
begin
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  select coalesce(jsonb_agg(card order by cnt desc, played desc, nm), '[]'::jsonb)
    into v_rows
    from (
      select public._team_card(t.id) as card,
             (select count(*) from public.team_members tm
               where tm.team_id = t.id and tm.left_at is null) as cnt,
             (select count(*) from public._team_session_ids(t.id)) as played,
             t.name as nm
        from public.teams t
       where t.org_id = v_org and t.deleted_at is null
       order by cnt desc, played desc, t.name
       limit greatest(1, least(coalesce(p_limit, 5), 20))
    ) s;

  return jsonb_build_object('ok', true, 'teams', v_rows);
end $$;


/* ─────────────────────────────────────────────────────────
   ⑥ create_team_tx
   ───────────────────────────────────────────────────────── */
create or replace function public.create_team_tx(p_name          text,
                                                 p_crest_emoji   text default null,
                                                 p_intro         text default null,
                                                 p_join_policy   text default 'approval',
                                                 p_home_store_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me   uuid := public.current_member_id();
  v_org  uuid := public.current_org_id();
  v_name text := btrim(coalesce(p_name, ''));
  v_lead int;
  v_join int;
  v_id   uuid;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  if char_length(v_name) < 2 or char_length(v_name) > 20 then
    return jsonb_build_object('ok', false, 'reason', 'bad_name', 'message', '團名請取 2 到 20 個字');
  end if;
  if coalesce(p_join_policy, 'approval') not in ('open', 'approval', 'closed') then
    return jsonb_build_object('ok', false, 'reason', 'bad_policy', 'message', '加入方式不正確');
  end if;
  if p_home_store_id is not null and not exists (
       select 1 from public.stores s
        where s.id = p_home_store_id and s.org_id = v_org and s.deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'bad_store', 'message', '找不到那間門市');
  end if;

  /* 兩道護欄，都不是產品規則是防洗版。
     ⚠ 數字放在這裡而不是設定表 —— 今天沒有人要調它，
       建一張設定表就是第 N 個「建了沒人讀」。 */
  select count(*) into v_lead from public.team_members tm
    join public.teams t on t.id = tm.team_id and t.deleted_at is null
   where tm.member_id = v_me and tm.left_at is null and tm.role = 'leader';
  if v_lead >= 3 then
    return jsonb_build_object('ok', false, 'reason', 'too_many_leading',
                              'message', '你已經是 3 個牌咖團的團長了');
  end if;

  select count(*) into v_join from public.team_members tm
    join public.teams t on t.id = tm.team_id and t.deleted_at is null
   where tm.member_id = v_me and tm.left_at is null;
  if v_join >= 10 then
    return jsonb_build_object('ok', false, 'reason', 'too_many_teams',
                              'message', '你已經加入 10 個牌咖團了');
  end if;

  begin
    insert into public.teams (org_id, name, crest_emoji, intro, join_policy,
                              home_store_id, created_by)
    values (v_org, v_name, nullif(btrim(coalesce(p_crest_emoji, '')), ''),
            nullif(btrim(coalesce(p_intro, '')), ''),
            coalesce(p_join_policy, 'approval'), p_home_store_id, v_me)
    returning id into v_id;
  exception when unique_violation then
    /* 🔴 這一格靠 `uq_teams_name` 擋，不是靠先查一次再插入 ——
       先查再插有競態，兩個人同時建同名團會兩個都成功。 */
    return jsonb_build_object('ok', false, 'reason', 'name_taken',
                              'message', '已經有人用這個團名了，換一個吧');
  end;

  insert into public.team_members (org_id, team_id, member_id, role)
  values (v_org, v_id, v_me, 'leader');

  return jsonb_build_object('ok', true, 'team', public._team_card(v_id), 'my_role', 'leader');
end $$;


/* ─────────────────────────────────────────────────────────
   ⑦ update_team_tx —— 團長改團名／簡介／加入方式／主場／月目標
   ───────────────────────────────────────────────────────── */
/* ⚠ 參數的 null 一律是「這一項不改」。要**清空**簡介請送空字串。
   🔴 團徽不在這裡（見 ⑧）—— 照片與 emoji 是互斥的兩種來源，
     混進一支什麼都能改的函式裡，遲早會出現「兩個都設了，畫面該聽誰的」。 */
create or replace function public.update_team_tx(p_team_id       uuid,
                                                 p_name          text default null,
                                                 p_intro         text default null,
                                                 p_join_policy   text default null,
                                                 p_home_store_id uuid default null,
                                                 p_clear_store   boolean default false,
                                                 p_monthly_goal  int  default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me   uuid := public.current_member_id();
  v_org  uuid := public.current_org_id();
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = v_me
                    and tm.left_at is null and tm.role = 'leader') then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以修改');
  end if;

  if p_name is not null and (v_name is null or char_length(v_name) > 20 or char_length(v_name) < 2) then
    return jsonb_build_object('ok', false, 'reason', 'bad_name', 'message', '團名請取 2 到 20 個字');
  end if;
  if p_join_policy is not null and p_join_policy not in ('open', 'approval', 'closed') then
    return jsonb_build_object('ok', false, 'reason', 'bad_policy', 'message', '加入方式不正確');
  end if;
  if p_monthly_goal is not null and (p_monthly_goal < 1 or p_monthly_goal > 999) then
    return jsonb_build_object('ok', false, 'reason', 'bad_goal', 'message', '本月目標請填 1 到 999');
  end if;
  if p_home_store_id is not null and not exists (
       select 1 from public.stores s
        where s.id = p_home_store_id and s.org_id = v_org and s.deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'bad_store', 'message', '找不到那間門市');
  end if;

  begin
    update public.teams t
       set name          = coalesce(v_name, t.name),
           intro         = case when p_intro is null then t.intro
                                else nullif(btrim(p_intro), '') end,
           join_policy   = coalesce(p_join_policy, t.join_policy),
           home_store_id = case when p_clear_store then null
                                else coalesce(p_home_store_id, t.home_store_id) end,
           monthly_goal  = coalesce(p_monthly_goal, t.monthly_goal),
           updated_at    = now()
     where t.id = p_team_id and t.deleted_at is null;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'reason', 'name_taken',
                              'message', '已經有人用這個團名了，換一個吧');
  end;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;

  return jsonb_build_object('ok', true, 'team', public._team_card(p_team_id));
end $$;


/* ─────────────────────────────────────────────────────────
   ⑧ set_team_crest_tx —— 團徽（emoji 或照片，互斥）
   ───────────────────────────────────────────────────────── */
/* 使用者 2026-09-11 決定：**團徽可以上傳照片，而且不審核。**
   那是他的決定，照做。這裡只保留「出事時下架得掉」的能力。

   🔴 `p_path` 由**伺服器**決定，前端沒有機會指定 ——
     上傳走與頭像完全相同的一條路：
     ① Edge Function 發簽名上傳網址（路徑由它產 UUID）
     ② 前端直傳 Storage
     ③ 才呼叫這一支把路徑寫進來
     ⚠ Storage 的 policy 已經全部清空（寫入只剩 service_role），
       所以前端**沒有別條路**可以寫進那個 bucket。
     📌 Edge Function 與 bucket 在下一批，這一支先在這裡，
       因為它是「路徑要寫到哪」的唯一答案。

   ⚠ 兩者互斥：設 emoji 會把照片清掉，設照片會把 emoji 留著當 fallback
     （照片載不出來時畫面還有東西可畫）。兩個都不給＝清空。 */
create or replace function public.set_team_crest_tx(p_team_id uuid,
                                                    p_emoji   text default null,
                                                    p_path    text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me    uuid := public.current_member_id();
  v_emoji text := nullif(btrim(coalesce(p_emoji, '')), '');
  v_path  text := nullif(btrim(coalesce(p_path,  '')), '');
  v_blk   boolean;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = v_me
                    and tm.left_at is null and tm.role = 'leader') then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以換團徽');
  end if;

  if v_emoji is not null and char_length(v_emoji) > 8 then
    return jsonb_build_object('ok', false, 'reason', 'bad_emoji', 'message', '團徽圖示太長了');
  end if;

  select t.crest_blocked into v_blk from public.teams t
   where t.id = p_team_id and t.deleted_at is null;
  if v_blk is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;
  /* 比照 `members.avatar_blocked`：被下架過就不能再傳照片，但 emoji 可以換。 */
  if v_blk and v_path is not null then
    return jsonb_build_object('ok', false, 'reason', 'crest_blocked',
                              'message', '這個團的自訂團徽已停用，請改用圖示');
  end if;

  update public.teams
     set crest_path  = case when v_emoji is not null then null else v_path end,
         crest_emoji = coalesce(v_emoji, crest_emoji),
         updated_at  = now()
   where id = p_team_id and deleted_at is null;

  return jsonb_build_object('ok', true, 'team', public._team_card(p_team_id));
end $$;


/* ─────────────────────────────────────────────────────────
   ⑨ disband_team_tx —— 解散
   ───────────────────────────────────────────────────────── */
/* ⚠ 軟刪，不真的 delete —— `team_members` 的歷史是場次判定的依據，
   刪掉之後「那幾場到底算不算」就永遠答不出來了。
   🔴 解散要把三件事一起做完，少做一件都會留下說謊的資料：
     ① 團標記刪除　② 所有人標記離開並寫理由　③ 還在談的申請／邀請全部取消 */
create or replace function public.disband_team_tx(p_team_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := public.current_member_id();
  v_n  int;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = v_me
                    and tm.left_at is null and tm.role = 'leader') then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以解散');
  end if;

  update public.teams set deleted_at = now(), updated_at = now()
   where id = p_team_id and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'already_gone', 'message', '這個團已經解散了');
  end if;

  update public.team_members
     set left_at = now(), left_reason = 'disband'
   where team_id = p_team_id and left_at is null;
  get diagnostics v_n = row_count;

  update public.team_requests
     set status = 'cancelled', decided_by = v_me, decided_at = now()
   where team_id = p_team_id and status = 'pending';

  return jsonb_build_object('ok', true, 'left', v_n);
end $$;


/* ─────────────────────────────────────────────────────────
   ⑩ 授權：一律只給 authenticated
   ───────────────────────────────────────────────────────── */
/* 🔴 兩個方向都要收（硬規則 2.6b）：
   · 新建的函式吃 default privileges ⇒ anon 是**明確授權** ⇒ `revoke from anon`
   · 舊的管理函式是從 PUBLIC 繼承        ⇒ `revoke from public`
   只收一邊時看到的症狀跟沒收一模一樣。 */
do $$
declare
  v_sig text;
begin
  foreach v_sig in array array[
    'public.list_my_teams_tx()',
    'public.get_team_tx(uuid)',
    'public.search_teams_tx(text, int)',
    'public.list_hot_teams_tx(int)',
    'public.create_team_tx(text, text, text, text, uuid)',
    'public.update_team_tx(uuid, text, text, text, uuid, boolean, int)',
    'public.set_team_crest_tx(uuid, text, text)',
    'public.disband_team_tx(uuid)'
  ] loop
    execute format('revoke execute on function %s from public', v_sig);
    execute format('revoke execute on function %s from anon', v_sig);
    execute format('grant  execute on function %s to authenticated', v_sig);
  end loop;
end $$;


/* ============================================================
   驗證
   🔴 整段不准 raise（硬規則 1.8）—— 這份要留下八支函式。
   ⚠ 所以這裡**只跑唯讀的那四支**，而且是借一個真身分跑的：
     `set_config('request.jwt.claims', ...)` 讓 `current_member_id()`
     解析得出來，函式體才會真的走完（硬規則 7）。
     **全程零寫入** —— 沒有 insert，所以不需要回滾。
   ⚠ 寫入路徑（建團／改團／團徽／解散）的行為測試在
     `sql/checks/2026-09-11_驗牌咖團建團與治理.sql`。
   ============================================================ */
do $$
declare
  v_msg  text := '';
  v_n    int;
  v_line text;
  v_r    jsonb;
begin
  /* ① 八支都建立了，而且每一支只有一個版本
     🔴 「版本數」要驗 —— 改簽名沒先 DROP 會建出多載版本，
       而前端叫到哪一支是不確定的（硬規則 2）。 */
  select count(*) into v_n
    from pg_proc where pronamespace = 'public'::regnamespace
     and proname in ('list_my_teams_tx','get_team_tx','search_teams_tx','list_hot_teams_tx',
                     'create_team_tx','update_team_tx','set_team_crest_tx','disband_team_tx',
                     '_team_card');
  v_msg := v_msg || case when v_n = 9
    then '① ✅ 九支函式都在，而且各只有一個版本（八支對外 ＋ _team_card）'
    else '① 🔴 函式共 ' || v_n || ' 支，預期 9 —— 大於 9 表示建出了多載版本' end;

  /* ② 授權：八支對外的都只給 authenticated
     🔴 用 aclexplode 分「明確授權」與「PUBLIC 繼承」——
       `has_function_privilege` 分不出這兩種（硬規則 2.6）。 */
  select count(*) into v_n
    from pg_proc p
    left join lateral aclexplode(p.proacl) a on true
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('list_my_teams_tx','get_team_tx','search_teams_tx','list_hot_teams_tx',
                       'create_team_tx','update_team_tx','set_team_crest_tx','disband_team_tx')
     and (a.grantee = 'anon'::regrole::oid or a.grantee = 0)
     and a.privilege_type = 'EXECUTE';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '② ✅ 八支都收掉了 anon 與 PUBLIC'
    else '② 🔴 還有 ' || v_n || ' 筆 anon／PUBLIC 的執行權' end;

  select count(*) into v_n
    from pg_proc p
    join lateral aclexplode(p.proacl) a on true
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('list_my_teams_tx','get_team_tx','search_teams_tx','list_hot_teams_tx',
                       'create_team_tx','update_team_tx','set_team_crest_tx','disband_team_tx')
     and a.grantee = 'authenticated'::regrole::oid
     and a.privilege_type = 'EXECUTE';
  v_msg := v_msg || E'\n' || case when v_n = 8
    then '③ ✅ 八支都授權給 authenticated（正對照 —— 沒有連前端一起關掉）'
    else '③ 🔴 只有 ' || v_n || '/8 授權給 authenticated —— 牌咖團整頁會 403' end;

  /* ④ 內部的兩支不可以給前端 */
  select count(*) into v_n
    from pg_proc p
    left join lateral aclexplode(p.proacl) a on true
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('_team_card', '_team_session_ids')
     and (a.grantee = 'anon'::regrole::oid or a.grantee = 0
          or a.grantee = 'authenticated'::regrole::oid)
     and a.privilege_type = 'EXECUTE';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '④ ✅ _team_card 與 _team_session_ids 前端都叫不到'
    else '④ 🔴 內部函式被授權出去了（' || v_n || ' 筆）' end;

  /* ⑤⑥⑦ 借一個真身分實際跑唯讀那幾支（硬規則 7）。
     🔴 不借身分的話它們一律回 not_logged_in ⇒ 函式體根本沒走到，
       而那種「跑過了」證明不了任何事。
     ⚠ 模擬的是今天的形狀：還沒發 Supabase JWT 時 `sub` 直接就是
       LINE user id（`migi_jwt_line_id()` 的第 ② 條路）。 */
  select m.line_user_id into v_line
    from public.members m
   where m.line_user_id is not null and m.deleted_at is null
   order by m.created_at
   limit 1;

  if v_line is null then
    v_msg := v_msg || E'\n⑤⑥⑦ 🔴 找不到任何綁了 LINE 的會員 —— 這三格測不了，'
                   || '而「測不了」不等於「通過」';
  else
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_line, 'role', 'authenticated')::text, true);

    v_r := public.list_my_teams_tx();
    v_msg := v_msg || E'\n' || case when (v_r->>'ok')::boolean
      then '⑤ ✅ list_my_teams_tx 跑得動，回 '
           || jsonb_array_length(v_r->'teams') || ' 個團（還沒有團，0 是對的）'
      else '⑤ 🔴 list_my_teams_tx 回 ' || coalesce(v_r->>'reason','(沒有 reason)') end;

    v_r := public.search_teams_tx(null, 20);
    v_msg := v_msg || E'\n' || case when (v_r->>'ok')::boolean
      then '⑥ ✅ search_teams_tx 跑得動，推薦門市＝'
           || coalesce(v_r->>'recommend_store_name', '(這位會員沒有場次紀錄)')
      else '⑥ 🔴 search_teams_tx 回 ' || coalesce(v_r->>'reason','(沒有 reason)') end;

    v_r := public.list_hot_teams_tx(5);
    v_msg := v_msg || E'\n' || case when (v_r->>'ok')::boolean
      then '⑦ ✅ list_hot_teams_tx 跑得動，回 '
           || jsonb_array_length(v_r->'teams') || ' 個團'
      else '⑦ 🔴 list_hot_teams_tx 回 ' || coalesce(v_r->>'reason','(沒有 reason)') end;

    /* ⑧ 負對照：沒有身分時要回 not_logged_in，不是靜靜回空清單。
       🔴 少了這一格，一支「永遠回空陣列」的實作會讓 ⑤⑥⑦ 全部變綠。 */
    perform set_config('request.jwt.claims', '', true);
    v_r := public.list_my_teams_tx();
    v_msg := v_msg || E'\n' || case when coalesce(v_r->>'reason','') = 'not_logged_in'
      then '⑧ ✅ 負對照：沒有身分時明確回 not_logged_in（不是假裝成功回空清單）'
      else '⑧ 🔴 沒有身分卻回 ' || coalesce(v_r::text, 'null') end;
  end if;

  /* ⑨ 這份是唯讀的驗證，確認它真的沒寫進任何東西。 */
  select count(*) into v_n from public.teams;
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '⑨ ✅ 驗證段沒有建出任何團（這一份全程唯讀）'
    else '⑨ ⚠ 現在有 ' || v_n || ' 個團 —— 若不是你自己建的，回頭看驗證段' end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
