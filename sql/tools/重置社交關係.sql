-- 【測試工具】清空測試會員之間的社交關係，讓牌咖流程可以重跑
-- 可重複執行，不是 migration。
-- ============================================================
-- 用途：牌咖邀請只能測一次 —— 接受過就變成牌咖、拒絕過就留下紀錄，
-- 對方從此不再出現在「最近同桌」。這支把狀態清回原點。
--
-- 【為什麼要清這四樣】
--   list_recent_players_tx（「最近同桌」的資料源）的條件是：
--       ① 一天內同桌過
--       ② **還不是牌咖**（mahjong_buddies 沒有有效列）
--       ③ **沒有送出過 pending 邀請**（buddy_invites）
--   所以只清通知沒有用 —— 人不會回到清單裡。
--   member_blocks 也要清：封鎖會擋掉邀請。
--
-- 🔴 **不清 session_players。**
--   那是「他們同桌過」的證據，清掉之後「最近同桌」就空了，
--   測試02 再也找不到 測試01 —— 而 App **沒有會員搜尋**，
--   加牌咖的唯一入口就是「最近同桌」（產品規則：關係從實體同桌開始）。
--   ⚠ `重置測試資料.sql` 會刪 session_players，兩支不要連著跑；
--     真的跑了就要重新開一桌讓他們同座。
--
-- 🔴 **同桌紀錄只有 1 天效期**（函式裡寫死 `interval '1 day'`）。
--   昨天開的桌今天就過期了。驗證段最後一欄會直接告訴你還找不找得到人。
--
-- 【mahjong_buddies 用硬刪除不用軟刪除】
--   那張表有 deleted_at，正式解除牌咖應該是軟刪除。
--   但這裡是重置工具：軟刪除留下的列可能撞到 uq_buddies 唯一索引
--   （2026-08-26 更正：原本寫 uq_buddy_pair，那個是重複建的、已刪除。
--     擋重複的是 M0 建的 uq_buddies，定義一模一樣，行為不變。）
--   （唯一索引不在 pg_constraint 裡，查不到條件，不賭）。
--   測試資料直接刪乾淨最安全。
-- ============================================================

-- ① 通知（含已讀的 buddy_ok，不清的話舊紀錄會混淆判讀）
delete from public.app_notifications
 where member_id in (select id from public.members where is_test = true);

-- ② 邀請 —— **所有狀態**，不只 pending。
--    accepted / rejected 留著不影響 list_recent_players_tx（它只看 pending），
--    但會讓你分不清這次的結果是哪一輪產生的。
delete from public.buddy_invites
 where inviter_id in (select id from public.members where is_test = true)
   and invitee_id in (select id from public.members where is_test = true);

-- ③ 已成立的牌咖關係（雙向都刪）
delete from public.mahjong_buddies
 where member_id in (select id from public.members where is_test = true)
   and buddy_id  in (select id from public.members where is_test = true);

-- ④ 黑名單 —— 封鎖會擋掉邀請
delete from public.member_blocks
 where blocker_id in (select id from public.members where is_test = true)
   and blocked_id in (select id from public.members where is_test = true);

-- ============================================================
-- 驗證（單一 SELECT）
--   前四欄應該全部是 0。
--   ★ 最後兩欄才是重點：「最近同桌」有沒有人。
--     空的話代表一天內沒有同桌紀錄 —— 要先用 POS 開一桌，
--     讓兩位測試會員都入座結帳（不用收桌），人才會出現。
-- ============================================================
select
  m.display_name                                                          as 會員,
  (select count(*) from public.app_notifications n
    where n.member_id = m.id)                                             as 通知,
  (select count(*) from public.buddy_invites bi
    where bi.inviter_id = m.id or bi.invitee_id = m.id)                   as 邀請,
  (select count(*) from public.mahjong_buddies b
    where b.member_id = m.id)                                             as 牌咖,
  (select count(*) from public.member_blocks bl
    where bl.blocker_id = m.id)                                           as 黑名單,
  -- 一天內同桌過的人（不含自己）；這是「最近同桌」的原料
  (select count(distinct o.member_id)
     from public.session_players sp
     join public.session_players o
       on o.session_id = sp.session_id and o.member_id <> sp.member_id
    where sp.member_id = m.id
      and sp.created_at > now() - interval '1 day')                       as 一天內同桌人數,
  -- 實際呼叫函式：這就是 App 裡「最近同桌」會列出來的名單
  (select jsonb_agg(e ->> 'nickname')
     from jsonb_array_elements(
            public.list_recent_players_tx(m.org_id, m.id)) e)             as 最近同桌名單
from public.members m
where m.is_test = true and m.deleted_at is null
order by m.display_name;
