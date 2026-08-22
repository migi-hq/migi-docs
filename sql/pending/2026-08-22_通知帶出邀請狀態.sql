-- 【待執行】list_notifications_tx 帶出邀請的處理狀態
-- ============================================================
-- 問題
--   接受牌咖邀請之後，重新載入通知頁那則又變回「待處理」並長出兩顆按鈕，
--   可以再按一次。
--
-- 原因不是「忘了標記」
--   respond_buddy_invite_tx **已經有**把那則通知標成已讀（read_at = now()），
--   而且有把 buddy_invites.status 改成 accepted / rejected。
--   缺的是**讀取端沒有把那個狀態帶出來** —— 前端只拿到 unread，
--   看不出這則已經回覆過了。
--
-- 【為什麼不加 app_notifications.handled_at 欄位】
--   狀態的真相已經在 buddy_invites.status（pending / accepted / rejected），
--   那本來就是它的職責。通知只是「告訴你有這件事」的**指標**。
--   再存一份就有兩個真相，而兩份狀態遲早會不同步
--   —— 例如日後從別的入口回覆邀請（牌咖頁也有接受按鈕），
--   那條路不會記得去更新通知列。
--
--   → 讀取時 join 出來，永遠正確；寫入端一行都不用動。
--   這正是通知系統規格 §0「三個軸獨立」的具體實現：
--       read_at        管已讀   （在 app_notifications）
--       invites.status 管已處理 （在 buddy_invites）
--
-- 【ref_id 的慣例】
--   buddy_req 的 ref_id **存的是邀請人的 member_id**，不是邀請單的 id。
--   （respond_buddy_invite_tx 裡的 `and ref_id = p_inviter` 就是這個約定。）
--   所以 join 用 inviter_id = n.ref_id、invitee_id = n.member_id。
--   同一對人可能邀請過多次（拒絕後再邀），取**最新一筆**。
--
-- 【table_req 不在這次範圍】
--   table_invites 表不存在（CLAUDE.md 待辦 6），沒有狀態可查，
--   所以它回 null，前端維持當成待處理。這是現況不是這支造成的。
--
-- 🔴 順帶發現，本檔不修，只記錄：
--   respond_buddy_invite_tx 在 p_accept 為真時**無條件** insert mahjong_buddies，
--   不檢查那筆 pending 邀請是否真的存在（UPDATE 匹配 0 列也照樣往下跑）。
--   加上它是 DEFINER 且 invitee / inviter 都由前端傳入，
--   等於**任何人都能讓任意兩個會員變成牌咖**，不需要有人先發邀請。
--   與「能改別人暱稱、讀別人消費明細」同一個根 —— CLAUDE.md 待辦 14。
-- ============================================================

create or replace function public.list_notifications_tx(p_org_id uuid, p_member uuid)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', n.id, 'type', n.type, 'payload', n.payload, 'ref_id', n.ref_id,
      'unread', (n.read_at is null), 'created_at', n.created_at,
      /* 這則邀請回覆了沒。null = 不適用（純告知類）或查不到對應邀請。
         前端把 null 與 'pending' 都當成待處理。 */
      'invite_status', case when n.type = 'buddy_req' then (
        select bi.status
          from buddy_invites bi
         where bi.inviter_id = n.ref_id
           and bi.invitee_id = n.member_id
         order by bi.created_at desc
         limit 1
      ) end
    ) order by n.created_at desc)
    from app_notifications n
    where n.member_id = p_member and n.org_id = p_org_id
      and n.created_at > now() - interval '30 days'
  ), '[]'::jsonb);
end $function$;

comment on function public.list_notifications_tx(uuid, uuid) is
  '通知中心資料源。invite_status 由 buddy_invites 即時 join 出來，不在 app_notifications 另存一份 —— 兩份狀態遲早不同步。ref_id 對 buddy_req 而言是邀請人的 member_id。';

-- ============================================================
-- 驗證（單一 SELECT）
--   ★ 第三欄是重點：已經回覆過的 buddy_req 應該帶出 accepted / rejected，
--     還沒回覆的是 pending。全部都是 null 就代表 join 沒對上。
-- ============================================================
select
  m.display_name                                                          as 會員,
  (select count(*) from public.app_notifications n
    where n.member_id = m.id)                                             as 通知數,
  (select jsonb_agg(jsonb_build_object(
            'type', e ->> 'type',
            'unread', e -> 'unread',
            'invite_status', e -> 'invite_status')
          order by e ->> 'type')
     from jsonb_array_elements(
            public.list_notifications_tx(m.org_id, m.id)) e
    where e ->> 'type' = 'buddy_req')                                     as 邀請類通知,
  (select jsonb_object_agg(bi.status, bi.n)
     from (select status, count(*) as n from public.buddy_invites
            where invitee_id = m.id group by status) bi)                  as 我收到的邀請狀態
from public.members m
where m.is_test = true and m.deleted_at is null
order by m.display_name;
