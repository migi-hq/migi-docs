-- ════════════════════════════════════════════════════════════════════
-- 唯讀：列出現在還開著的牌局裡「第 15 局」的完整紀錄（2026-10-30 現場回報：第 15 局只有一個中發白）
--
-- 用途：找出是哪一桌、那一局記了幾個中發白、四家分數各多少，才寫得出修正的 SQL。
-- 一列都不寫。整列用 to_jsonb 印出來，不猜欄位名稱（Supabase MCP 權杖過期，拿不到線上結構）。
-- ════════════════════════════════════════════════════════════════════

select to_jsonb(tb)                       as "桌",
       ts.id                              as "場次 id",
       r.id                               as "這一將 id",
       to_jsonb(r)                        as "這一將",
       to_jsonb(h)                        as "第 15 局（完整）",
       (select jsonb_agg(to_jsonb(sp) order by sp.sort)
          from public.scoring_patterns sp)  as "牌型主檔"
  from public.hands h
  join public.session_rounds r  on r.id = h.round_id
  join public.table_sessions ts on ts.id = r.session_id
  join public.tables tb         on tb.id = ts.table_id
 where ts.status = 'open'
   and h.hand_no = 15
 order by h.created_at desc;
