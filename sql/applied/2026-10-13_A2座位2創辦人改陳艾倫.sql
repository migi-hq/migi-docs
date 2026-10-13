-- ============================================================
-- 一次性修正：A2 座位 2 一開始掛錯帳號（創辦人 本狩 岡五郎）→ 改成 陳艾倫，讓陳艾倫接著打
-- 2026-10-13 · MIGI 咪吉麻將
--
-- 使用者：「創辦人在 A2 的紀錄要改成陳艾倫」；順序：創辦人手機先關掉 → 陳艾倫加到主畫面配對 → 轉資料 → 陳艾倫接著打
--
-- 查證（2026-10-13 唯讀查詢）：
--   · 場次 a34c5ef8…（A2，配桌、3 將）座位 2 ＝ 創辦人 69016205…，已確認 12 局
--   · 錢：這個座位是「白」代付的（paid_by），創辦人自己沒有訂單、沒扣點數 ⇒ 改人不用動任何錢
--   · 分數：每一局記在「座位」上（hands.score_delta 的鍵是座位號）⇒ 換人之後 12 局照樣算給座位 2 ＝ 陳艾倫
--   · 陳艾倫 aadf83c6…：今天 16:19 註冊、不在這一場、不在配桌房 ⇒ 兩個唯一限制都不會撞
--   · session_players 上的觸發器只在「名次第一次寫進去」時發通知，改 member_id 不會誤發
--
-- 改三件事：
--   ① session_players 座位 2：member_id 創辦人 → 陳艾倫，device_id 清掉（解開創辦人那支手機）
--      ⇒ 陳艾倫配對好的手機打開時，後端看到「他坐在這一場、座位還沒綁裝置」就自動接上
--   ② 配桌房 3e8a791e… 的報名：創辦人 → 陳艾倫（App 的對局紀錄、配桌紀錄看的是這一份）
--   ③ 叫一次 _tbl_ping，讓 A2 的裝置立刻重新讀狀態
-- 手機裝置本身一律不動（座位 2 那支是創辦人自己的）。
--
-- ⚠ 條件寫在更新本身：只有「這一場還開著、座位 2 還是創辦人、陳艾倫不在這一場」才會改 ——
--   狀態不符就一列都不動，驗證段會照實說。
-- ============================================================

with sp as (
  update public.session_players p
     set member_id = 'aadf83c6-bf8d-4d2d-bcfc-e833acbbeb75', device_id = null
   where p.id = '1ae2a34f-8d4c-4346-9b81-df3aeb18b2fa'
     and p.session_id = 'a34c5ef8-b1fa-4f92-b0ea-8993a67cbc51'
     and p.seat = 2 and p.left_at is null
     and p.member_id = '69016205-afde-4036-95a6-5893c9d0e5fe'
     and exists (select 1 from public.table_sessions ts where ts.id = p.session_id and ts.status = 'open')
     and not exists (select 1 from public.session_players x
                      where x.session_id = p.session_id and x.member_id = 'aadf83c6-bf8d-4d2d-bcfc-e833acbbeb75')
  returning p.session_id
)
update public.match_queue_players q
   set member_id = 'aadf83c6-bf8d-4d2d-bcfc-e833acbbeb75'
 where q.queue_id = '3e8a791e-09d3-4d34-86cc-d545f8df121c'
   and q.member_id = '69016205-afde-4036-95a6-5893c9d0e5fe' and q.left_at is null
   and exists (select 1 from sp);

select public._tbl_ping('a34c5ef8-b1fa-4f92-b0ea-8993a67cbc51');


-- ============================================================
-- 驗證（單一 SELECT，不 raise）
-- ============================================================
select concat_ws(E'\n',
  case (select m.display_name from session_players sp join members m on m.id = sp.member_id
         where sp.id = '1ae2a34f-8d4c-4346-9b81-df3aeb18b2fa')
    when '陳艾倫' then '① ✅ A2 座位 2 改成陳艾倫'
    else '① 🔴 座位 2 沒改到（現在是 ' || coalesce((select m.display_name from session_players sp join members m on m.id = sp.member_id
                                                where sp.id = '1ae2a34f-8d4c-4346-9b81-df3aeb18b2fa'), '找不到') || '）' end,
  case when (select device_id from session_players where id = '1ae2a34f-8d4c-4346-9b81-df3aeb18b2fa') is null
       then '② ✅ 座位 2 已解開創辦人的手機，等陳艾倫的手機接上'
       else '② ℹ 座位 2 已經綁著一台裝置（陳艾倫的手機可能已經接上了）' end,
  case when exists (select 1 from match_queue_players where queue_id = '3e8a791e-09d3-4d34-86cc-d545f8df121c'
                     and member_id = 'aadf83c6-bf8d-4d2d-bcfc-e833acbbeb75' and left_at is null)
        and not exists (select 1 from match_queue_players where queue_id = '3e8a791e-09d3-4d34-86cc-d545f8df121c'
                     and member_id = '69016205-afde-4036-95a6-5893c9d0e5fe' and left_at is null)
       then '③ ✅ 配桌房的報名也改成陳艾倫' else '③ 🔴 配桌房沒改到' end,
  '④ ℹ A2 已確認 ' || (select count(*) from hands where session_id = 'a34c5ef8-b1fa-4f92-b0ea-8993a67cbc51' and status = 'confirmed')
    || ' 局（分數記在座位上，照樣算給座位 2）；陳艾倫名下配對好的手機 '
    || (select count(*) from table_devices where member_id = 'aadf83c6-bf8d-4d2d-bcfc-e833acbbeb75' and kind = 'phone' and is_active and revoked_at is null) || ' 支'
) as "驗證";
