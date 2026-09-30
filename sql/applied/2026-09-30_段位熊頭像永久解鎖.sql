/* ============================================================
   段位熊頭像：升到過就永久保留，解鎖由後端說了算
   2026-09-30 · MIGI 咪吉麻將

   ── 為什麼 ─────────────────────────────────────────────
   使用者拍板：段位熊頭像「曾經升到過就一直能用」，換季降段不收回。
   在此之前：
     · 解鎖規則只活在前端（`unlockedBearCount(目前段位)`），
       而每季結束段位固定降 2 大階 ⇒ 鑽石熊頭像每季一定被收回
     · `set_avatar_tx` 完全不檢查 ⇒ 直接打 RPC 就能換上任何一隻
     · 雀神熊不是段位（rank_tiers 只有 6 階），是賽季冠軍 ——
       前端寫「段位含雀神就解鎖」⇒ 永遠解不開
     · 頭像圖鑑主頁寫死「2 / 12」、切頁寫死「5 / 7」，三處三個答案

   ── 做了什麼 ───────────────────────────────────────────
   ① members.best_rank_tier —— 曾經到過的最高段位（rank_tiers.code）
   ② _rank_tier_of(段位文字) —— 「銀牌熊 III」→ silver，唯一一份對照
   ③ 觸發器：members.rank 每次變動，最高段位只升不降
      （段位的寫入有好幾條路：每場結算、換季降階、補名次 ——
        掛在表上一次涵蓋，不改那幾支函式）
   ④ 回填：目前段位、歷來每場結算後的段位分、賽季快照，三者取最高
   ⑤ _member_bear_unlocks(會員) —— 解鎖了哪幾隻，**全系統只有這一份**
        段位熊：best_rank_tier 以下（含）全部；沒有段位的人至少有銅牌熊
        雀神熊：當過任何一季的冠軍（season_champions）
   ⑥ get_my_avatar_tx 多回 unlocked_bears；**身分只認 JWT**
      （原本沒登入時會退回前端送的 id ⇒ 給一個 uuid 就讀得到別人的頭像與段位）
   ⑦ set_avatar_tx：選段位熊時檢查有沒有解鎖；其他造型鍵照舊不擋
      （原註解寫的「造型清單是內容、會增加，不做白名單」那個設計保留 ——
        只管 rank_tiers 裡的那幾隻與雀神熊）
   ⑧ 兩支都收回 anon 與 PUBLIC（會員 App 登入後是 authenticated）

   ⚠ 回填會讓每個會員的 updated_at 變成執行當下（set_updated_at 觸發器），
     只有 5 個會員、全部是測試帳號，接受。

   行為測試：sql/checks/2026-09-30_驗段位熊頭像解鎖.sql（交易內造樣本、全部回滾）
   ============================================================ */

-- ① 曾經到過的最高段位
alter table public.members
  add column if not exists best_rank_tier text references public.rank_tiers(code);
comment on column public.members.best_rank_tier is
  '曾經到過的最高段位（rank_tiers.code）。只升不降，由觸發器維護；段位熊頭像的解鎖以它為準，換季降段不收回。';

-- ② 段位文字 → 段位代碼（「銀牌熊 III」→ silver）
create or replace function public._rank_tier_of(p_rank text)
returns text
language sql
stable
set search_path to 'public'
as $$
  select t.code
    from public.rank_tiers t
   where p_rank is not null
     and p_rank like t.label || '%'
   order by t.sort desc
   limit 1
$$;
revoke execute on function public._rank_tier_of(text) from public, anon, authenticated;

-- ③ 觸發器：最高段位只升不降
create or replace function public.trg_members_best_rank()
returns trigger
language plpgsql
set search_path to 'public'
as $$
declare
  v_new  text := public._rank_tier_of(new.rank);
  v_newo int;
  v_best int;
begin
  if v_new is null then return new; end if;
  select sort into v_newo from public.rank_tiers where code = v_new;
  select sort into v_best from public.rank_tiers where code = new.best_rank_tier;
  if v_best is null or v_newo > v_best then
    new.best_rank_tier := v_new;
  end if;
  return new;
end $$;
revoke execute on function public.trg_members_best_rank() from public, anon, authenticated;

drop trigger if exists trg_members_best_rank on public.members;
create trigger trg_members_best_rank
  before insert or update of rank on public.members
  for each row execute function public.trg_members_best_rank();

-- ④ 回填：目前段位、歷來每場之後的段位分、賽季快照，三者取最高
update public.members m
   set best_rank_tier = x.code
  from (
    select m2.id,
           (select t.code
              from public.rank_tiers t
             where t.code in (
                     public._rank_tier_of(m2.rank),
                     public._rank_tier_of(case when h.hi is not null then public.rank_from_rating(h.hi) end),
                     public._rank_tier_of(case when s.hi is not null then public.rank_from_rating(s.hi) end))
             order by t.sort desc
             limit 1) as code
      from public.members m2
      left join lateral (select max(sp.rating_after) as hi from public.session_players sp where sp.member_id = m2.id) h on true
      left join lateral (select max(ss.rating)       as hi from public.season_standings ss where ss.member_id = m2.id) s on true
  ) x
 where x.id = m.id
   and x.code is not null
   and m.best_rank_tier is distinct from x.code;

-- ⑤ 解鎖了哪幾隻（全系統唯一一份）
create or replace function public._member_bear_unlocks(p_member uuid)
returns text[]
language sql
stable
set search_path to 'public'
as $$
  select array(
           select t.code
             from public.rank_tiers t
            where t.sort <= coalesce(
                    (select bt.sort
                       from public.members m
                       join public.rank_tiers bt on bt.code = m.best_rank_tier
                      where m.id = p_member), 1)
            order by t.sort)
      || case when exists (select 1 from public.season_champions c where c.member_id = p_member)
              then array['quegod'] else array[]::text[] end
$$;
revoke execute on function public._member_bear_unlocks(uuid) from public, anon, authenticated;

-- ⑥ 讀自己的頭像：多回 unlocked_bears；身分只認 JWT（簽名不變，前端照樣送的 id 被忽略）
create or replace function public.get_my_avatar_tx(p_member_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_me uuid;
begin
  v_me := public.current_member_id();
  if v_me is null then
    raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000';
  end if;

  return (
    select jsonb_build_object(
             'ok', true,
             'avatar_source',     m.avatar_source,
             'avatar_photo_path', m.avatar_photo_path,
             'avatar_bear',       m.avatar_bear,
             'avatar_url',        m.avatar_url,
             'avatar_blocked',    m.avatar_blocked,
             'rank',              m.rank,
             /* 解鎖了哪幾隻段位熊（含雀神熊），前端的圖鑑與選頭像抽屜都讀這一份 */
             'unlocked_bears',    to_jsonb(public._member_bear_unlocks(m.id)))
      from members m
     where m.id = v_me and m.deleted_at is null
  );
end $function$;

-- ⑦ 換頭像：選段位熊時要已解鎖。用線上全文插一段，其餘一個字不動
do $$
declare
  v_def    text := pg_get_functiondef('public.set_avatar_tx(uuid,text,text,text)'::regprocedure);
  v_anchor text := '/* 切到小熊：照片保留不刪';
  v_check  text;
  v_n      int;
begin
  if v_def ~ 'reason'', ''bear_locked''' then
    return;   -- 已經插過（重跑不重複插）
  end if;
  v_n := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_n <> 1 then
    raise exception '插入點應該剛好 1 處，實際 % 處 —— 線上版本跟預期不同，整份停下', v_n;
  end if;
  v_check := $chk$/* 段位熊與雀神熊要已解鎖才能選（曾經升到過就永久保留，2026-09-30）。
       ⚠ 只管 rank_tiers 裡的那幾隻與雀神熊；其他造型鍵照舊不擋（見上面「只擋長度」那段）。 */
    if v_bear is not null
       and (v_bear = 'quegod' or exists (select 1 from public.rank_tiers t where t.code = v_bear))
       and not (v_bear = any (public._member_bear_unlocks(p_member_id))) then
      return jsonb_build_object('ok', false, 'reason', 'bear_locked',
        'message', '這隻小熊還沒解鎖');
    end if;
    $chk$;
  execute replace(v_def, v_anchor, v_check || v_anchor);
end $$;

-- ⑧ 收回 anon 與 PUBLIC，留給登入的會員
revoke execute on function public.get_my_avatar_tx(uuid) from public, anon;
revoke execute on function public.set_avatar_tx(uuid, text, text, text) from public, anon;
grant  execute on function public.get_my_avatar_tx(uuid) to authenticated;
grant  execute on function public.set_avatar_tx(uuid, text, text, text) to authenticated;

/* ============================================================
   驗證（不 raise —— 硬規則 1.8：這份要留下東西）
   ============================================================ */
do $$
declare
  v_msg  text := '';
  v_n    int;
  v_txt  text;
  v_fn   text;
  v_oid  oid;
  v_anon boolean; v_pub boolean; v_auth boolean;
begin
  -- ① 欄位在、有外鍵
  select count(*) into v_n from information_schema.columns
   where table_schema = 'public' and table_name = 'members' and column_name = 'best_rank_tier';
  v_msg := v_msg || case when v_n = 1 then '✅' else '🔴' end || ' ① members.best_rank_tier 欄位在' || E'\n';

  -- ② 對照：五種寫法各對一次（含「白金」不可以被「金牌」吃掉）
  v_txt := coalesce(public._rank_tier_of('銅牌熊 III'), '∅') || ',' ||
           coalesce(public._rank_tier_of('金牌熊 I'), '∅')   || ',' ||
           coalesce(public._rank_tier_of('白金熊 II'), '∅')  || ',' ||
           coalesce(public._rank_tier_of('大師熊'), '∅')     || ',' ||
           coalesce(public._rank_tier_of(null), '∅');
  v_msg := v_msg || case when v_txt = 'bronze,gold,platinum,master,∅' then '✅' else '🔴' end
        || ' ② 段位對照 ' || v_txt || '（期望 bronze,gold,platinum,master,∅）' || E'\n';

  -- ③ 回填：期望 銅牌 1 人（測試03）、銀牌 4 人；沒有人低於目前段位
  select string_agg(t, ', ' order by t) into v_txt
    from (select coalesce(best_rank_tier, '∅') || '×' || count(*) as t
            from public.members where deleted_at is null group by best_rank_tier) z;
  select count(*) into v_n
    from public.members m
    join public.rank_tiers cur on cur.code = public._rank_tier_of(m.rank)
    left join public.rank_tiers best on best.code = m.best_rank_tier
   where m.deleted_at is null and (best.sort is null or best.sort < cur.sort);
  v_msg := v_msg || case when v_n = 0 and coalesce(v_txt, '') = 'bronze×1, silver×4' then '✅' else '🔴' end
        || ' ③ 回填 ' || coalesce(v_txt, '（沒有資料）') || '（期望 bronze×1, silver×4）· 低於目前段位 ' || v_n || ' 人' || E'\n';

  -- ④ 觸發器在
  select count(*) into v_n from pg_trigger
   where tgrelid = 'public.members'::regclass and tgname = 'trg_members_best_rank' and not tgisinternal;
  v_msg := v_msg || case when v_n = 1 then '✅' else '🔴' end || ' ④ 觸發器 trg_members_best_rank 在' || E'\n';

  -- ⑤ 解鎖清單：銀牌的人拿到 bronze,silver；銅牌的人只有 bronze（期望值見 ③）
  select coalesce(string_agg(distinct array_to_string(public._member_bear_unlocks(id), ','), ' / '
                             order by array_to_string(public._member_bear_unlocks(id), ',')), '∅') into v_txt
    from public.members where deleted_at is null;
  v_msg := v_msg || case when v_txt = 'bronze / bronze,silver' then '✅' else '🔴' end
        || ' ⑤ 解鎖清單 ' || v_txt || '（期望 bronze / bronze,silver）' || E'\n';

  -- ⑥ set_avatar_tx 插進去了、只插一次
  v_txt := pg_get_functiondef('public.set_avatar_tx(uuid,text,text,text)'::regprocedure);
  v_n := (length(v_txt) - length(replace(v_txt, 'bear_locked', ''))) / length('bear_locked');
  v_msg := v_msg || case when v_n = 1 then '✅' else '🔴' end || ' ⑥ set_avatar_tx 有解鎖檢查（' || v_n || ' 處，期望 1）' || E'\n';

  -- ⑦ get_my_avatar_tx 回 unlocked_bears、不再退回前端送的 id
  v_txt := pg_get_functiondef('public.get_my_avatar_tx(uuid)'::regprocedure);
  v_msg := v_msg || case when v_txt ~ 'unlocked_bears' and v_txt !~ 'coalesce\(v_me' then '✅' else '🔴' end
        || ' ⑦ get_my_avatar_tx 回 unlocked_bears、身分只認 JWT' || E'\n';

  -- ⑧ 授權：兩支都 anon 明確沒有、PUBLIC 沒有、authenticated 有（兩個方向都印）
  foreach v_fn in array array['public.get_my_avatar_tx(uuid)', 'public.set_avatar_tx(uuid,text,text,text)'] loop
    v_oid := v_fn::regprocedure;
    select exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = v_oid and a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE') into v_anon;
    select (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')) into v_pub from pg_proc p where p.oid = v_oid;
    select has_function_privilege('authenticated', v_oid, 'execute') into v_auth;
    v_msg := v_msg || case when not v_anon and not v_pub and v_auth then '✅' else '🔴' end
          || ' ⑧ ' || v_fn || '  anon ' || case when v_anon then '有' else '無' end
          || ' · PUBLIC ' || case when v_pub then '有' else '無' end
          || ' · authenticated ' || case when v_auth then '有' else '無' end || E'\n';
  end loop;

  -- ⑨ 內部函式前端叫不到
  select count(*) into v_n from unnest(array['public._rank_tier_of(text)', 'public._member_bear_unlocks(uuid)']) f
   where has_function_privilege('authenticated', f::regprocedure, 'execute')
      or has_function_privilege('anon', f::regprocedure, 'execute');
  v_msg := v_msg || case when v_n = 0 then '✅' else '🔴' end || ' ⑨ 兩支內部函式前端叫不到（' || v_n || ' 支叫得到，期望 0）';

  perform set_config('migi.v', v_msg, true);
end $$;
select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有驗證訊息') as "驗證";
