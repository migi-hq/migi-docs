-- 【測試工具】塞一組涵蓋所有狀態的通知
-- 可重複執行，不是 migration。
-- ============================================================
-- 為什麼需要：通知要靠別人觸發（有人加你牌咖、揪你入桌、牌局結算），
-- 一個人自己測不出來。這支直接把資料塞好。
--
-- **每一位測試會員都會拿到同一組**，所以不管你登入的是哪一個都看得到。
-- 寄件者從其他測試會員裡挑，不會出現「自己邀請自己」。
--
-- 涵蓋的狀態（對照 docs/03-會員App與社交/通知系統規格.md）：
--   待處理 × 未讀   buddy_req（5 分鐘前）、table_req（8 分鐘前）
--   待處理 × 已讀   buddy_req（1 小時前）← **驗證「已讀 ≠ 已處理」的那一則**
--   告知   × 未讀   buddy_ok（3 小時前）
--   告知   × 已讀   table_ok（5 小時前）、settle（昨天）、table_expired（3 天前）
--   → 未讀 3 則（鈴鐺應顯示 3）、日期分三組（今天 / 昨天 / 更早）
--
-- 【重點欄位】
--   unread **不是欄位**，是 list_notifications_tx 算出來的：`read_at is null`。
--   所以「已讀」= read_at 給值，「未讀」= read_at 留 null。
--
--   payload 要有 from_name / from_id / text ——
--   前端 social.js 的 fetchNotifs 就是讀這三個鍵。
--   from_id 尤其重要：按「接受」時 respondBuddyReq(n.from_id, true) 用它當 inviter。
--
-- 【buddy_invites 一定要一起建】
--   沒有對應的 pending 邀請，按「接受」會失敗 ——
--   通知只是「告訴你有這件事」，真正的狀態在 buddy_invites。
--   ⚠ 先 DELETE 再 INSERT：那張表可能有「防重複 pending」的唯一索引
--     （唯一索引不在 pg_constraint 裡，查不到，所以不賭 ON CONFLICT）。
--
-- 【table_req 的接受目前是空的】
--   social.js 的 respondTableReq 只有 track + emitSocial，沒有後端動作
--   （table_invites 表不存在，見 CLAUDE.md 待辦 6）。
--   所以它按下去只會有前端反應 —— 這一版是拿來測 UI 的，符合預期。
-- ============================================================

-- ① 清掉測試會員的既有通知與 pending 邀請（可重複執行）
delete from public.app_notifications
 where member_id in (select id from public.members where is_test = true);

delete from public.buddy_invites
 where invitee_id in (select id from public.members where is_test = true)
   and inviter_id in (select id from public.members where is_test = true)
   and status = 'pending';

-- ② 每位測試會員各插一組。
--    寄件者用「下一位測試會員」輪轉，保證不會自己邀自己。
with m as (
  select id, org_id, display_name,
         row_number() over (order by display_name) as rn,
         count(*) over () as n
    from public.members
   where is_test = true and deleted_at is null
),
pairs as (
  select me.id as me_id, me.org_id, me.display_name as me_name,
         a.id as a_id, a.display_name as a_name,   -- 寄件者 1
         b.id as b_id, b.display_name as b_name,   -- 寄件者 2
         c.id as c_id, c.display_name as c_name    -- 寄件者 3
    from m me
    join m a on a.rn = (me.rn % me.n) + 1
    join m b on b.rn = ((me.rn + 1) % me.n) + 1
    join m c on c.rn = ((me.rn + 2) % me.n) + 1
)
insert into public.app_notifications(org_id, member_id, type, payload, read_at, created_at)
select org_id, me_id, type, payload, read_at, created_at from pairs
cross join lateral (values
  -- ── 待處理 × 未讀 ──
  ('buddy_req',
   jsonb_build_object('from_name', a_name, 'from_id', a_id,
                      'text', a_name || ' 想加你為牌咖'),
   null::timestamptz, now() - interval '5 minutes'),
  ('table_req',
   jsonb_build_object('from_name', b_name, 'from_id', b_id,
                      'text', b_name || ' 邀你入桌'),
   null::timestamptz, now() - interval '8 minutes'),
  -- ── 待處理 × 已讀（驗證「已讀不等於已處理」：底色回白但按鈕還在）──
  ('buddy_req',
   jsonb_build_object('from_name', c_name, 'from_id', c_id,
                      'text', c_name || ' 想加你為牌咖'),
   now() - interval '30 minutes', now() - interval '1 hour'),
  -- ── 告知 × 未讀 ──
  ('buddy_ok',
   jsonb_build_object('from_name', a_name, 'from_id', a_id,
                      'text', '你和 ' || a_name || ' 成為牌咖了'),
   null::timestamptz, now() - interval '3 hours'),
  -- ── 告知 × 已讀（今天 / 昨天 / 更早各一，測日期分組）──
  ('table_ok',
   jsonb_build_object('from_name', b_name, 'from_id', b_id,
                      'text', '你已加入 ' || b_name || ' 的牌桌'),
   now() - interval '4 hours', now() - interval '5 hours'),
  ('settle',
   jsonb_build_object('text', '你的牌局結算完成'),
   now() - interval '20 hours', now() - interval '1 day' - interval '2 hours'),
  ('table_expired',
   jsonb_build_object('text', '你的牌局已過期，沒有湊滿人數'),
   now() - interval '2 days', now() - interval '3 days')
) as v(type, payload, read_at, created_at);

-- ③ 兩則 buddy_req 要有對應的 pending 邀請，否則按「接受」會失敗
with m as (
  select id, org_id, display_name,
         row_number() over (order by display_name) as rn,
         count(*) over () as n
    from public.members
   where is_test = true and deleted_at is null
)
insert into public.buddy_invites(org_id, inviter_id, invitee_id, status, created_at)
select me.org_id, s.id, me.id, 'pending', now() - interval '5 minutes'
  from m me
  join m s on s.rn in ((me.rn % me.n) + 1, ((me.rn + 2) % me.n) + 1)
 where s.id <> me.id
   -- 已經是牌咖的就不重發（邀請會被後端擋掉，留著只是雜訊）
   and not exists (
     select 1 from public.buddy_invites bi
      where bi.inviter_id = s.id and bi.invitee_id = me.id
        and bi.status = 'pending');

-- ============================================================
-- 驗證（單一 SELECT）
--   每位測試會員應該都是：通知 7 則、未讀 3 則、待處理 pending 邀請 2 筆。
--   ★ 鈴鐺應顯示 3；「待處理」區應有 3 則（兩則 buddy_req + 一則 table_req）。
-- ============================================================
select
  m.display_name                                                          as 會員,
  (select count(*) from public.app_notifications n
    where n.member_id = m.id)                                             as 通知數,
  (select count(*) from public.app_notifications n
    where n.member_id = m.id and n.read_at is null)                       as 未讀數,
  (select count(*) from public.app_notifications n
    where n.member_id = m.id and n.type in ('buddy_req','table_req'))     as 待處理數,
  (select count(*) from public.buddy_invites bi
    where bi.invitee_id = m.id and bi.status = 'pending')                 as 可接受的邀請,
  (select jsonb_agg(e ->> 'type' order by e ->> 'type')
     from jsonb_array_elements(
            public.list_notifications_tx(m.org_id, m.id)) e)              as 讀取函式回傳
from public.members m
where m.is_test = true and m.deleted_at is null
order by m.display_name;
