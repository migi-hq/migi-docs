-- 【這是什麼】唯讀盤點：確認每間門市各有哪些固定局範本與等待中的房。
-- 【何時讀】POS 與 App 看到的牌局對不起來時。
--
-- ═══ 現象 ═══
--   · App（MIGI 高雄自由店）：固定 2 局 —— 今天 21:00、8/25 20:00
--   · POS（配桌列表）：1 房 —— 純娛樂 · 8/24 00:00
--   兩邊沒有任何一局重疊。
--
-- 推測：**不是沒連動，是兩邊選的門市不同**。
--   POS 的門市存在 localStorage（getStoreId()），跟 App 的預設門市各走各的。
--   下面把「哪一局在哪一間店」列清楚就知道了。

select 項目, 結果
from (
  select 1 as ord, '門市清單' as 項目,
    coalesce((select string_agg(name || '　' || id::text, chr(10) order by name)
                from stores
               where org_id = '11111111-1111-1111-1111-111111111111'
                 and deleted_at is null), '（沒有門市）') as 結果

  union all select 2, '固定局範本在哪一間店',
    coalesce((select string_agg(
                s.name || '　' || r.frequency ||
                case when r.weekday is null then '' else ' 週' || substr('日一二三四五六', r.weekday + 1, 1) end ||
                ' ' || r.start_time::text ||
                '　' || case when r.enabled then '啟用' else '停用' end,
                chr(10) order by s.name, r.start_time)
                from recurring_tables r
                left join stores s on s.id = r.store_id), '（沒有範本）')

  union all select 3, '等待中的房在哪一間店',
    coalesce((select string_agg(
                s.name || '　[' || q.source || '] ' ||
                (q.play_at at time zone 'Asia/Taipei')::text ||
                '　開賣 ' || coalesce((q.open_at at time zone 'Asia/Taipei')::text, '(立刻)') ||
                case when q.open_at is null or q.open_at <= now() then '　✅ 看得到' else '　⏳ 還沒開賣' end,
                chr(10) order by s.name, q.play_at)
                from match_queues q
                left join stores s on s.id = q.store_id
               where q.status = 'waiting' and q.play_at > now()), '（沒有等待中的房）')

  union all select 4, '每間店各有幾張桌（POS 的門市一定有桌）',
    coalesce((select string_agg(s.name || ' → ' || n || ' 張', chr(10) order by s.name)
                from (select store_id, count(*) n from tables
                       where deleted_at is null group by store_id) t
                join stores s on s.id = t.store_id), '（沒有桌）')

  union all select 5, '已收桌的場次在哪一間店',
    coalesce((select string_agg(s.name || '　' ||
                (ts.ended_at at time zone 'Asia/Taipei')::text || '　入座 ' ||
                (select count(*) from session_players p where p.session_id = ts.id) || ' 人',
                chr(10) order by ts.ended_at desc)
                from table_sessions ts
                left join stores s on s.id = ts.store_id
               where ts.status = 'completed' and ts.deleted_at is null), '（沒有已收桌的場次）')

  union all select 9, '現在時間（台北）',
    (now() at time zone 'Asia/Taipei')::text
) x
order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
-- 第 2／3 項若分屬不同門市 → 確認「不是沒連動，是門市不同」。
--   POS 左上角沒有門市切換的話，它吃的是 localStorage 的 migi_store_id；
--   要換店得從「即時桌況」那邊切（POS 的門市選擇在那一頁）。
-- 第 4 項：POS 只能在「有桌」的門市運作。範本建在沒有桌的店，
--   之後「帶到桌」會找不到空桌 —— 那時才發現就晚了。
-- 第 3 項的「⏳ 還沒開賣」：客人看不到是**正常的**（lead_hours 還沒到），
--   但 POS 也看不到（list_match_queues_tx 同樣有 open_at 條件）。
--   店員要確認排程有沒有生出來，是去「固定局設定」看「待開放 N 場」。
