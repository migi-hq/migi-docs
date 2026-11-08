/* ============================================================
   成就送小熊配件：第一次贏得牌局（onboarding_12）送「毛線帽」
   2026-11-09 使用者：「贏一場的成就，新增獎勵：毛線帽」

   做法照稱號那一套（_member_titles）：
   ① achievements 加一欄 grants_closet（完成這枚成就送哪件配件，值是前端 lib/closet.jsx 的配件代碼）
   ② 誰擁有哪幾件 ＝ 從「解鎖了哪些成就」算出來（_member_closet），**不另存一份擁有清單**
      ⇒ 已經解鎖 onboarding_12 的 96 人，跑完這份就直接有毛線帽，不用補發
   ③ get_my_closet_tx()：會員 App 讀這支（擁有的 ＋ 還沒拿到的要完成哪一枚成就）
   ④ 解鎖一枚會送配件的成就時，發事件 bear_item_granted ⇒ 成就「第一個配件」（onboarding_15）
      —— 那枚成就一直在等這個事件，而在此之前全系統沒有任何東西會發它（0 人解鎖）
      做在 member_achievements 的觸發器上，不改 ach_unlock_tx：解鎖有好幾條路（單次、累積、meta），觸發器一個地方全涵蓋
   ⑤ 補發 ④：已經解鎖 onboarding_12 的人，補發一次 bear_item_granted（冪等鍵固定，重跑不會重複）

   ⚠ 配件永久：跟稱號一樣，成就日後下架，已經拿到的人不收回（_member_closet 刻意不過濾 deleted_at／is_active）
   ⚠ 新函式預設前端叫不到（硬規則 2.7）⇒ get_my_closet_tx 明確 grant 給 authenticated；身分一律 current_member_id()
   ⚠ grants_closet 只檢查格式不檢查清單：配件清單在前端（內容美術），每加一件就改 CHECK 等於把內容寫進 schema
   ============================================================ */

-- ① 欄位
alter table public.achievements add column if not exists grants_closet text;
do $$ begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.achievements'::regclass and conname = 'achievements_grants_closet_fmt') then
    alter table public.achievements add constraint achievements_grants_closet_fmt
      check (grants_closet is null or grants_closet ~ '^[a-z][a-z0-9_]{0,30}$');
  end if;
end $$;
comment on column public.achievements.grants_closet is
  '解鎖這枚成就送的小熊配件代碼（對應 migi-web lib/closet.jsx 的 CLOSET_ITEMS.key）。擁有清單由 _member_closet 從解鎖紀錄算出，不另存。';

update public.achievements set grants_closet = 'beanie', updated_at = now()
 where org_id = '11111111-1111-1111-1111-111111111111' and code = 'onboarding_12';

-- ② 誰擁有哪幾件（唯一一份定義）
create or replace function public._member_closet(p_member uuid)
returns table(item text, source text, got_at timestamptz)
language sql stable security definer set search_path = public as $$
  /* 配件永久：刻意不過濾 a.deleted_at／a.is_active（成就下架不收回，同 _member_titles） */
  select distinct on (a.grants_closet) a.grants_closet, '成就「' || a.name || '」', ma.unlocked_at
    from member_achievements ma
    join achievements a on a.id = ma.achievement_id
   where ma.member_id = p_member and ma.status = 'unlocked'
     and a.grants_closet is not null
   order by a.grants_closet, ma.unlocked_at nulls last
$$;
revoke execute on function public._member_closet(uuid) from public;
revoke execute on function public._member_closet(uuid) from anon, authenticated;

-- ③ 會員 App 讀這支
create or replace function public.get_my_closet_tx()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_me uuid; v_org uuid; v_owned jsonb; v_how jsonb;
begin
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  select org_id into v_org from members where id = v_me and deleted_at is null;

  select coalesce(jsonb_agg(jsonb_build_object('item', c.item, 'source', c.source, 'got_at', c.got_at) order by c.got_at nulls last), '[]'::jsonb)
    into v_owned from public._member_closet(v_me) c;

  /* 還沒拿到、而且看得到的成就會送的那幾件：點反灰的配件時告訴客人要做什麼
     ⚠ 隱藏或剪影的成就不列 —— 列了等於把隱藏條件講出來（同 get_my_titles_tx） */
  select coalesce(jsonb_agg(jsonb_build_object('item', a.grants_closet, 'achievement', a.name, 'condition', a.condition_text)
                            order by a.sort, a.code), '[]'::jsonb)
    into v_how
    from achievements a
   where a.org_id = v_org and a.deleted_at is null and a.is_active
     and a.grants_closet is not null and a.visibility = 'visible'
     and not exists (select 1 from public._member_closet(v_me) c where c.item = a.grants_closet);

  return jsonb_build_object('owned', v_owned, 'how', v_how);
end $$;
revoke execute on function public.get_my_closet_tx() from public;
revoke execute on function public.get_my_closet_tx() from anon;
grant execute on function public.get_my_closet_tx() to authenticated;

-- ④ 解鎖會送配件的成就 ⇒ 發 bear_item_granted
create or replace function public.trg_member_achievements_closet()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_item text; v_code text;
begin
  if new.status = 'unlocked' and (tg_op = 'INSERT' or old.status is distinct from 'unlocked') then
    select a.grants_closet, a.code into v_item, v_code from achievements a where a.id = new.achievement_id;
    if v_item is not null then
      begin
        perform public.fire_event_tx(new.member_id, 'bear_item_granted', 1, null, 'closet:' || v_code || ':' || new.member_id::text);
      exception when others then null;   -- 同 trg_members_achievements：成就事件失敗不可以讓解鎖本身失敗
      end;
    end if;
  end if;
  return null;
end $$;
revoke execute on function public.trg_member_achievements_closet() from public;
revoke execute on function public.trg_member_achievements_closet() from anon, authenticated;
drop trigger if exists trg_member_achievements_closet on public.member_achievements;
create trigger trg_member_achievements_closet
  after insert or update of status on public.member_achievements
  for each row execute function public.trg_member_achievements_closet();

-- ⑤ 補發：已經解鎖 onboarding_12 的人補一次 bear_item_granted（冪等鍵跟觸發器同一個格式，重跑不重複）
do $$ declare r record; begin
  for r in select ma.member_id, a.code
             from member_achievements ma join achievements a on a.id = ma.achievement_id
            where ma.status = 'unlocked' and a.grants_closet is not null loop
    perform public.fire_event_tx(r.member_id, 'bear_item_granted', 1, null, 'closet:' || r.code || ':' || r.member_id::text);
  end loop;
end $$;

-- ============================================================
-- 驗證（單一 SELECT；不用 raise —— 硬規則 1.8）
-- 期望值當場算：onboarding_12 已解鎖的人數 ＝ 擁有毛線帽的人數 ＝ onboarding_15 已解鎖的人數
-- ============================================================
select
  (select case when exists (select 1 from information_schema.columns where table_schema='public' and table_name='achievements' and column_name='grants_closet')
          then '✅' else '🔴' end) || ' ① achievements.grants_closet 欄位' as "①",
  (select case when grants_closet = 'beanie' then '✅ ② onboarding_12「' || name || '」送 beanie' else '🔴 ② onboarding_12 的 grants_closet = ' || coalesce(grants_closet, 'null') end
     from achievements where org_id = '11111111-1111-1111-1111-111111111111' and code = 'onboarding_12') as "②",
  (with won as (select ma.member_id from member_achievements ma join achievements a on a.id = ma.achievement_id
                 where a.code = 'onboarding_12' and ma.status = 'unlocked'),
        has as (select w.member_id from won w where exists (select 1 from public._member_closet(w.member_id) c where c.item = 'beanie'))
   select case when (select count(*) from won) = (select count(*) from has) and (select count(*) from won) > 0
               then '✅ ③ 贏過的 ' || (select count(*) from won) || ' 人都擁有毛線帽'
               else '🔴 ③ 贏過 ' || (select count(*) from won) || ' 人，擁有毛線帽 ' || (select count(*) from has) || ' 人' end) as "③",
  (select case when (select count(*) from member_achievements ma join achievements a on a.id = ma.achievement_id where a.code = 'onboarding_12' and ma.status = 'unlocked')
                  = (select count(*) from member_achievements ma join achievements a on a.id = ma.achievement_id where a.code = 'onboarding_15' and ma.status = 'unlocked')
          then '✅ ④ 「第一個配件」補發到同樣人數：' || (select count(*) from member_achievements ma join achievements a on a.id = ma.achievement_id where a.code = 'onboarding_15' and ma.status = 'unlocked')
          else '🔴 ④ 「第一個配件」解鎖 ' || (select count(*) from member_achievements ma join achievements a on a.id = ma.achievement_id where a.code = 'onboarding_15' and ma.status = 'unlocked') || ' 人' end) as "④",
  /* ⑤ 正對照：沒贏過的人不可以有毛線帽（過度發放跟沒發一樣糟） */
  (select case when count(*) = 0 then '✅ ⑤ 沒贏過的人都沒有毛線帽' else '🔴 ⑤ 沒贏過卻有毛線帽：' || count(*) || ' 人' end
     from members m
    where m.deleted_at is null
      and not exists (select 1 from member_achievements ma join achievements a on a.id = ma.achievement_id
                       where ma.member_id = m.id and a.code = 'onboarding_12' and ma.status = 'unlocked')
      and exists (select 1 from public._member_closet(m.id) c where c.item = 'beanie')) as "⑤",
  /* ⑥ 授權兩個方向都看（硬規則 2.6）：前端讀的那支 authenticated 有、anon 沒有；內部兩支前端都沒有 */
  (select case when has_function_privilege('authenticated', 'public.get_my_closet_tx()', 'EXECUTE')
               and not has_function_privilege('anon', 'public.get_my_closet_tx()', 'EXECUTE')
               and not has_function_privilege('authenticated', 'public._member_closet(uuid)', 'EXECUTE')
               and not has_function_privilege('anon', 'public._member_closet(uuid)', 'EXECUTE')
          then '✅ ⑥ 授權：get_my_closet_tx 只給登入的人，_member_closet 前端叫不到'
          else '🔴 ⑥ 授權不對' end) as "⑥",
  (select case when exists (select 1 from pg_trigger where tgname = 'trg_member_achievements_closet' and not tgisinternal)
          then '✅ ⑦ 觸發器 trg_member_achievements_closet 在' else '🔴 ⑦ 觸發器不在' end) as "⑦";
