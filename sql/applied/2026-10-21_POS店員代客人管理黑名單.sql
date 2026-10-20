-- ════════════════════════════════════════════════════════════════
-- 2026-10-21 POS 會員資料：店員可以替客人加入／移出黑名單（比照會員 App 的黑名單）
-- ────────────────────────────────────────────────────────────────
-- 使用者：「POS 每個會員的個人資料新增黑名單功能，比照目前 App 黑名單同等功能，任何店員都能操作」
--   ⚠ 這是會員自己的封鎖名單（member_blocks：不想跟某某同桌），**不是封鎖帳號** ——
--     封鎖帳號仍然是管理後台的事，POS 不做。
-- 做法：block_member_tx／unblock_member_tx 比照 list_blocks_tx 早就在用的寫法 ——
--   · 店員登入（current_staff() 查得到）⇒ 可以替指定的客人（p_blocker）操作，
--     但兩個人都必須是店員所屬機構的會員（p_org_id 一律改用 current_org_id()，不信前端）
--   · 其他人 ⇒ 照舊只認登入的本人，前端送的 p_blocker 一律忽略
-- 稽核：member_blocks 新增 created_by_staff_id（店員代加的才有值，客人自己加的是 null）。
--   值由 current_staff() 解析，不收前端參數。移出沒有留紀錄（那一列直接刪掉，同 App）。
-- ⚠ CREATE OR REPLACE、簽名不變 ⇒ 授權照舊。封鎖之後的效果完全同 App（配桌互相避開、解除牌咖、作廢邀請），
--   因為走的就是同一支函式。
-- ════════════════════════════════════════════════════════════════

alter table public.member_blocks
  add column if not exists created_by_staff_id uuid references public.staff(id);
comment on column public.member_blocks.created_by_staff_id is
  '店員在 POS 替客人加入黑名單時記下是哪位店員（current_staff 解析，不收前端）；客人自己在 App 加的是 null';

CREATE OR REPLACE FUNCTION public.block_member_tx(p_org_id uuid, p_blocker uuid, p_blocked uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me    uuid := public.current_member_id();
  v_staff uuid := (select staff_id from public.current_staff() limit 1);
begin
  /* 【2026-10-21】店員替**別的**客人操作才走這一條。
     ⚠ 店員本人也是會員：他在會員 App 封鎖別人時 p_blocker 是他自己 ⇒ 走下面會員那條，
       不記成「店員代加」，不然稽核欄位會說一件沒發生的事。 */
  if v_staff is not null and p_blocker is not null and p_blocker is distinct from v_me then
    p_org_id := public.current_org_id();   -- 機構一律用登入身分的，不信前端
    if p_blocked is null then raise exception '請先選好要加入黑名單的人'; end if;
    if not exists (select 1 from members where id = p_blocker and org_id = p_org_id and deleted_at is null)
       or not exists (select 1 from members where id = p_blocked and org_id = p_org_id and deleted_at is null) then
      raise exception '找不到這位會員';
    end if;
  else
    -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
    v_staff := null;
    p_blocker := v_me;
    if p_blocker is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  end if;
  if p_blocker = p_blocked then raise exception '不能封鎖自己'; end if;

  insert into member_blocks(org_id, blocker_id, blocked_id, created_by_staff_id)
  values (p_org_id, p_blocker, p_blocked, v_staff)
  on conflict (blocker_id, blocked_id) do nothing;

  -- 作廢雙方之間所有 pending 牌咖邀請（兩個方向）
  update buddy_invites set status='rejected', responded_at=now()
   where org_id=p_org_id and status='pending'
     and ((inviter_id=p_blocker and invitee_id=p_blocked)
       or (inviter_id=p_blocked and invitee_id=p_blocker));

  -- ★ 一併解除已成立的牌咖關係（雙向軟刪除，同 remove_buddy_tx 邏輯）
  update mahjong_buddies set deleted_at = now()
   where org_id = p_org_id and deleted_at is null
     and ((member_id = p_blocker and buddy_id = p_blocked)
       or (member_id = p_blocked and buddy_id = p_blocker));

  -- 清掉雙方之間相關的未讀通知（牌咖/桌邀），避免黑了還躺著已作廢的邀請
  update app_notifications set read_at=now()
   where org_id=p_org_id and read_at is null
     and type in ('buddy_req','table_req')
     and ((member_id=p_blocker and (payload->>'from_id')=p_blocked::text)
       or (member_id=p_blocked and (payload->>'from_id')=p_blocker::text));
end $function$;

CREATE OR REPLACE FUNCTION public.unblock_member_tx(p_org_id uuid, p_blocker uuid, p_blocked uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me uuid := public.current_member_id();
begin
  -- 【2026-10-21】店員替別的客人操作（同 block_member_tx 的判斷）；機構一律用登入身分的
  if exists (select 1 from public.current_staff()) and p_blocker is not null and p_blocker is distinct from v_me then
    p_org_id := public.current_org_id();
  else
    -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
    p_blocker := v_me;
    if p_blocker is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  end if;
  delete from member_blocks
   where org_id=p_org_id and blocker_id=p_blocker and blocked_id=p_blocked;
end $function$;

-- ── 驗證（單一 SELECT，不 raise）──────────────────────────────────
select
  case when exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'member_blocks' and column_name = 'created_by_staff_id')
       then '✅ ① member_blocks 有 created_by_staff_id' else '🔴 ① 欄位沒加到' end
  || E'\n' ||
  case when pg_get_functiondef('public.block_member_tx(uuid,uuid,uuid)'::regprocedure) ~ 'current_staff\(\)'
        and pg_get_functiondef('public.block_member_tx(uuid,uuid,uuid)'::regprocedure) ~ 'created_by_staff_id'
        and pg_get_functiondef('public.unblock_member_tx(uuid,uuid,uuid)'::regprocedure) ~ 'current_staff\(\)'
       then '✅ ② 加入／移出都認得店員' else '🔴 ② 函式沒改到' end
  || E'\n' ||
  case when pg_get_functiondef('public.block_member_tx(uuid,uuid,uuid)'::regprocedure) ~ 'current_member_id\(\)'
        and pg_get_functiondef('public.unblock_member_tx(uuid,uuid,uuid)'::regprocedure) ~ 'current_member_id\(\)'
       then '✅ ③ 不是店員的照舊只認登入的本人' else '🔴 ③ 會員那條路不見了' end
  || E'\n' ||
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
              and proname in ('block_member_tx', 'unblock_member_tx')) = 2
        and has_function_privilege('authenticated', 'public.block_member_tx(uuid,uuid,uuid)', 'execute')
        and has_function_privilege('authenticated', 'public.unblock_member_tx(uuid,uuid,uuid)', 'execute')
       then '✅ ④ 各一個版本、登入的人叫得動' else '🔴 ④ 出現多載或授權不見了' end
  || E'\n' ||
  '📌 ⑤ 現有黑名單 ' || (select count(*) from member_blocks) || ' 筆（舊的 created_by_staff_id 都是 null，正常）'
  as "驗證";
