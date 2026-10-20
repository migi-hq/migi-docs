-- ════════════════════════════════════════════════════════════════
-- 2026-10-21 通知「已接受你的牌咖邀請」改畫對方頭像（原本掉回預設小熊）
-- ────────────────────────────────────────────────────────────────
-- 起因：使用者問「通知的小圖還有什麼類別用預設小熊」。查九種通知：
--   牌局四種 → 牌局圖；牌咖團三種 → 加入牌咖團徽章；想加你為牌咖 → 對方頭像
--   🔴 接受牌咖邀請（13 筆）→ 後端沒查頭像 ⇒ 前端畫預設小熊
-- 那一種的 ref_id 本來就是接受的人（線上 13/13 筆 ref_id ＝ payload.from_id），
-- 所以只在 actor 那段多一行，前端不用改（它已經是「有 actor 就畫頭像」）。
-- ⚠ CREATE OR REPLACE、簽名不變 ⇒ 授權照舊，不用補 grant。
-- ════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.list_notifications_tx(p_org_id uuid, p_member uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
  p_member := public.current_member_id();
  if p_member is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', n.id, 'type', n.type, 'payload', n.payload, 'ref_id', n.ref_id,
      'unread', (n.read_at is null), 'done', (n.done_at is not null), 'created_at', n.created_at,
      /* 這則邀請回覆了沒。null = 不適用（純告知類）或查不到對應邀請。
         前端把 null 與 'pending' 都當成待處理。 */
      'invite_status', case
        when n.type = 'buddy_req' then (
          select bi.status
            from buddy_invites bi
           where bi.inviter_id = n.ref_id
             and bi.invitee_id = n.member_id
           order by bi.created_at desc
           limit 1)
        /* 🆕 團的申請與邀請。`ref_id` 直接就是 team_requests.id。
           ⚠ 過期的要說「過期」不要說「待處理」—— 清理是在別的動作
             順手做的（沒有排程），所以這裡一定會看到還沒被收掉的 pending。 */
        when n.type = 'team_req' then (
          select case when r.status = 'pending' and r.expires_at <= now()
                      then 'expired' else r.status end
            from team_requests r
           where r.id = n.ref_id)
        end,
      /* 2026-10-20：這則通知「是誰」的頭像（前端畫真的頭像，不再一律預設小熊）
           牌咖邀請 ref_id ＝ 邀請人；接受了你的牌咖邀請 ref_id ＝ 接受的人（2026-10-21 補）；
           入團申請（給團長）＝ 申請的人；入團邀請（給被邀的人）＝ 邀請的人。
           其他類型沒有「誰」，回 null */
      'actor', (
        select jsonb_build_object('avatar_url', a.avatar_url, 'avatar_bear', a.avatar_bear,
                                  'avatar_source', a.avatar_source, 'avatar_photo_path', a.avatar_photo_path,
                                  'rank', a.rank)
          from members a
         where a.id = case
                 when n.type = 'buddy_req' then n.ref_id
                 when n.type = 'buddy_ok' then n.ref_id
                 when n.type = 'team_req' then (
                   select case when r.kind = 'invite' then r.created_by else r.member_id end
                     from team_requests r where r.id = n.ref_id)
               end)
    ) order by n.created_at desc)
    from app_notifications n
    where n.member_id = p_member and n.org_id = p_org_id
      and n.created_at > now() - interval '30 days'
  ), '[]'::jsonb);
end $function$;

-- ── 驗證（單一 SELECT，不 raise）──────────────────────────────────
select
  case when pg_get_functiondef('public.list_notifications_tx'::regproc)
            ~ 'when n\.type = ''buddy_ok'' then n\.ref_id'
       then '✅ ① 接受牌咖邀請那一行在函式裡' else '🔴 ① 沒改到' end
  || E'\n' ||
  case when (select count(*) from pg_proc where proname = 'list_notifications_tx' and pronamespace = 'public'::regnamespace) = 1
       then '✅ ② 只有一個版本' else '🔴 ② 出現多載' end
  || E'\n' ||
  case when has_function_privilege('authenticated', 'public.list_notifications_tx(uuid,uuid)', 'execute')
       then '✅ ③ 登入的會員叫得動（授權沒丟）' else '🔴 ③ authenticated 沒有執行權' end
  || E'\n' ||
  '📌 ④ 接受牌咖邀請的通知 ' || (select count(*) from app_notifications where type = 'buddy_ok')
  || ' 筆，其中查得到對方的 ' || (select count(*) from app_notifications n
                                 where n.type = 'buddy_ok' and exists (select 1 from members m where m.id = n.ref_id))
  || ' 筆（兩個數字一樣 ＝ 全部都會畫頭像）'
  as "驗證";
