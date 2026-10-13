-- ============================================================
-- 一次性修正：A2 這一桌設錯將數，2 將 → 3 將
-- 2026-10-13 · MIGI 咪吉麻將
--
-- 使用者：「現在有一桌打錯了 2將改成3將」
-- 查證（2026-10-13 唯讀查詢）：
--   · 開著的只有 A1（本來就是 3 將，打到第 2 將）與 A2（配桌、2 將、還沒開打）⇒ 是 A2
--   · A2：場次 a34c5ef8…，一將都還沒建、0 局；**還沒有任何客人結帳入座** ⇒ 沒收過檯費，不用退補
--     之後客人結帳時，檯費照新的將數算（配桌檯費 · 3 將 = 150）
--   · 配桌房 3e8a791e… 也記著將數（文字「2 將」，客人 App 看的是這一份）⇒ 兩邊一起改
--   · 兩張表上沒有會擋或會被牽連的觸發器（只有 updated_at、org、作廢回收那幾支）
--
-- ⚠ 條件寫在更新本身：只有「還開著、還是 2 將、一將都沒建、沒有人入座」才會改到 ——
--   跑之前狀態變了（客人剛好入座、開打了）就一列都不動，驗證段會照實說。
-- ============================================================

with s as (
  update public.table_sessions ts set planned_rounds = 3
   where ts.id = 'a34c5ef8-b1fa-4f92-b0ea-8993a67cbc51'
     and ts.status = 'open' and ts.planned_rounds = 2
     and not exists (select 1 from public.session_rounds r where r.session_id = ts.id)
     and not exists (select 1 from public.session_players sp where sp.session_id = ts.id and sp.left_at is null)
  returning ts.id
)
update public.match_queues mq set rounds = '3 將'
 where mq.id = '3e8a791e-09d3-4d34-86cc-d545f8df121c'
   and mq.matched_session_id in (select id from s);


-- ============================================================
-- 驗證（單一 SELECT，不 raise）
-- ============================================================
select concat_ws(E'\n',
  case (select planned_rounds from table_sessions where id = 'a34c5ef8-b1fa-4f92-b0ea-8993a67cbc51')
    when 3 then '① ✅ A2 這一場改成 3 將'
    else '① 🔴 沒改到（現在是 ' || coalesce((select planned_rounds::text from table_sessions where id = 'a34c5ef8-b1fa-4f92-b0ea-8993a67cbc51'), '找不到') || ' 將）—— 可能已經有人入座或開打了' end,
  case (select rounds from match_queues where id = '3e8a791e-09d3-4d34-86cc-d545f8df121c')
    when '3 將' then '② ✅ 配桌房也改成 3 將'
    else '② 🔴 配桌房沒改到（現在是 ' || coalesce((select rounds from match_queues where id = '3e8a791e-09d3-4d34-86cc-d545f8df121c'), '找不到') || '）' end,
  '③ ℹ 目前入座 ' || (select count(*) from session_players where session_id = 'a34c5ef8-b1fa-4f92-b0ea-8993a67cbc51' and left_at is null)
    || ' 人、已建 ' || (select count(*) from session_rounds where session_id = 'a34c5ef8-b1fa-4f92-b0ea-8993a67cbc51') || ' 將'
) as "驗證";
