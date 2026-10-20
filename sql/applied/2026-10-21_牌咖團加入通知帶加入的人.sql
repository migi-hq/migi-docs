-- ════════════════════════════════════════════════════════════════
-- 2026-10-21 牌咖團「某某加入了」「某某用邀請連結加入了」通知記下是誰，通知中心畫他的頭像
-- ────────────────────────────────────────────────────────────────
-- 使用者指定這五種用真實頭像（邀你入桌是同日追加的）：
--   邀你入桌（table_req）               邀請人早就存在 payload.from_id，只差通知清單去查 ⇒ 第 ④ 段
--   想加入、邀請你加入（team_req）   後端早就帶了 actor，只是前端統一畫成徽章 ⇒ 改前端就好
--   加入了、用邀請連結加入了（team_ok） 後端只存名字、沒存是誰 ⇒ 這一份補
-- 做法：發通知時 ref_id 從 null 改成加入的那個人（三個地方，各改一個參數），
--      list_notifications_tx 的 actor 多認 team_ok 的 ref_id。
--   · 其他 team_ok（申請通過、副團長、團長交接、接任）ref_id 照舊是 null ⇒ 沒有 actor ⇒ 前端照畫徽章
--   · 查過：沒有任何函式或前端讀 team_ok 的 ref_id（前端只拿 team_req 的去回覆）
-- 舊的 4 筆一併補上：用「那個團裡同名的團員」對，4 筆都只對到一位。
-- ⚠ 三支函式用「撈線上全文 → 只換那一個參數 → 重建」，簽名不變 ⇒ 授權照舊。
--   換不到就不重建（不 raise，硬規則 1.8），驗證段會亮紅。
-- ════════════════════════════════════════════════════════════════

do $$
declare
  v_def text; v_new text;
begin
  -- ① 直接加入（開放加入的團）：通知團長，ref ＝ 我
  v_def := pg_get_functiondef('public.apply_team_tx(uuid)'::regprocedure);
  v_new := replace(v_def, $q$v_name || ' 加入了 ' || v_t.name, p_team_id, v_t.name, null);$q$,
                          $q$v_name || ' 加入了 ' || v_t.name, p_team_id, v_t.name, v_me);$q$);
  if v_new <> v_def then execute v_new; end if;

  -- ② 用邀請連結加入：通知團長，ref ＝ 我
  v_def := pg_get_functiondef('public.redeem_team_invite_tx(text)'::regprocedure);
  v_new := replace(v_def, $q$v_name || ' 用邀請連結加入了 ' || v_t.name, v_t.id, v_t.name, null);$q$,
                          $q$v_name || ' 用邀請連結加入了 ' || v_t.name, v_t.id, v_t.name, v_me);$q$);
  if v_new <> v_def then execute v_new; end if;

  -- ③ 答應團長的邀請：通知團長，ref ＝ 答應的人
  v_def := pg_get_functiondef('public.respond_team_request_tx(uuid,boolean)'::regprocedure);
  v_new := replace(v_def, $q$v_name || ' 加入了 ' || v_t.name, v_t.id, v_t.name, null);$q$,
                          $q$v_name || ' 加入了 ' || v_t.name, v_t.id, v_t.name, v_r.member_id);$q$);
  if v_new <> v_def then execute v_new; end if;
end $$;

-- ④ 通知清單：actor 多認 team_ok 的 ref_id
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
           入團申請（給團長）＝ 申請的人；入團邀請（給被邀的人）＝ 邀請的人；
           某某加入了團／用邀請連結加入了 ref_id ＝ 加入的人（2026-10-21 補，其他牌咖團告知類 ref_id 是 null）；
           邀你入桌 ＝ payload.from_id 的邀請人（ref_id 是那一房，2026-10-21 補）。
           其他類型沒有「誰」，回 null */
      'actor', (
        select jsonb_build_object('avatar_url', a.avatar_url, 'avatar_bear', a.avatar_bear,
                                  'avatar_source', a.avatar_source, 'avatar_photo_path', a.avatar_photo_path,
                                  'rank', a.rank)
          from members a
         where a.id = case
                 when n.type = 'buddy_req' then n.ref_id
                 when n.type = 'buddy_ok' then n.ref_id
                 when n.type = 'team_ok' then n.ref_id
                 when n.type = 'table_req' then (n.payload->>'from_id')::uuid
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

-- ⑤ 舊的「加入了」通知補上是誰（只補在那個團裡剛好一位同名的）
update public.app_notifications n
   set ref_id = (select tm.member_id from public.team_members tm
                   join public.members m on m.id = tm.member_id
                  where tm.team_id = (n.payload->>'team_id')::uuid
                    and m.display_name = n.payload->>'from_name')
 where n.type = 'team_ok' and n.ref_id is null
   and (n.payload->>'text') ~ '加入了 '
   and (select count(*) from public.team_members tm
          join public.members m on m.id = tm.member_id
         where tm.team_id = (n.payload->>'team_id')::uuid
           and m.display_name = n.payload->>'from_name') = 1;

-- ── 驗證（單一 SELECT，不 raise）──────────────────────────────────
select
  case when pg_get_functiondef('public.apply_team_tx(uuid)'::regprocedure) ~ $q$' 加入了 ' \|\| v_t\.name, p_team_id, v_t\.name, v_me\);$q$
       then '✅ ① 直接加入：通知記下加入的人' else '🔴 ① 直接加入沒改到' end
  || E'\n' ||
  case when pg_get_functiondef('public.redeem_team_invite_tx(text)'::regprocedure) ~ $q$用邀請連結加入了 ' \|\| v_t\.name, v_t\.id, v_t\.name, v_me\);$q$
       then '✅ ② 邀請連結加入：通知記下加入的人' else '🔴 ② 邀請連結加入沒改到' end
  || E'\n' ||
  case when pg_get_functiondef('public.respond_team_request_tx(uuid,boolean)'::regprocedure) ~ $q$v_t\.id, v_t\.name, v_r\.member_id\);$q$
       then '✅ ③ 答應邀請：通知記下加入的人' else '🔴 ③ 答應邀請沒改到' end
  || E'\n' ||
  case when pg_get_functiondef('public.list_notifications_tx'::regproc) ~ $q$when n\.type = 'team_ok' then n\.ref_id$q$
       and pg_get_functiondef('public.list_notifications_tx'::regproc) ~ $q$when n\.type = 'table_req' then \(n\.payload->>'from_id'\)::uuid$q$
       then '✅ ④ 通知清單會查加入的人、邀你入桌的人的頭像' else '🔴 ④ 通知清單沒改到' end
  || E'\n' ||
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
              and proname in ('apply_team_tx','redeem_team_invite_tx','respond_team_request_tx','list_notifications_tx')) = 4
        and has_function_privilege('authenticated', 'public.apply_team_tx(uuid)', 'execute')
        and has_function_privilege('authenticated', 'public.redeem_team_invite_tx(text)', 'execute')
        and has_function_privilege('authenticated', 'public.respond_team_request_tx(uuid,boolean)', 'execute')
        and has_function_privilege('authenticated', 'public.list_notifications_tx(uuid,uuid)', 'execute')
       then '✅ ⑤ 四支各一個版本、登入的會員都叫得動' else '🔴 ⑤ 出現多載或授權不見了' end
  || E'\n' ||
  '📌 ⑥ 舊的「加入了」通知：已補上是誰 '
  || (select count(*) from app_notifications where type = 'team_ok' and ref_id is not null and (payload->>'text') ~ '加入了 ')
  || ' 筆、還沒補的 '
  || (select count(*) from app_notifications where type = 'team_ok' and ref_id is null and (payload->>'text') ~ '加入了 ')
  || ' 筆（應該是 4 與 0）'
  as "驗證";
