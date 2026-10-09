-- ============================================================
-- A1 第 1 將第 17 局改牌型（2026-10-10，使用者：這一局改成「混一色 ＋ 三元牌 ×1 ＋ 全紅，豹子 ×3 倍」，總分 510）
--
-- 那一局  80c99d25-61b4-4c98-abd1-301335e04a73（00:37:58 送出、yuhsin 確認）
--         Y（座位 1）胡、yuhsin（座位 3）放槍；莊家是 Jun（座位 2），連莊 0 ⇒ 不牽涉莊家台
-- 原本    字一色 ＋ 小三元 ＋ 風牌 ×3 ＝ 23 台 → 50 ＋ 23 × 20 ＝ 510（點錯牌型，金額剛好一樣）
-- 改成    混一色 4 ＋ 三元牌 1 ＋ 全紅 1 ＝ 6 台，豹子按 2 次（×3），整筆含底一起乘
--         →（50 ＋ 6 × 20）× 3 ＝ 510 ⇒ **金額不變，只改牌型與台數**
--
-- 寫法照 tbl_submit_hand_tx 存的形狀：patterns 是 [{code, n}]、tai_pattern 存乘過豹子的牌型台數（6 × 3 ＝ 18）、
-- proposed_delta 與 score_delta 一樣（已確認的局）。
-- 不動 status ⇒ 不會觸發爆卡偵測（那個觸發器只在改 status 時跑）。這場還沒結算，成就也還沒發。
-- 🔴 先確認那一局還是原本的內容才改；對不上就整份停下來（故意不要提交的那一種）。
-- ⚠ 要在「豹子連底一起乘」那一份之後跑（之後重開的話，平板才會把它畫成 3 底 18 台）。
-- ============================================================

do $$
declare
  v_hand constant uuid := '80c99d25-61b4-4c98-abd1-301335e04a73';
  h public.hands;
  v_n int;
begin
  select * into h from hands where id = v_hand;
  if not found then raise exception '找不到那一局'; end if;
  if h.status <> 'confirmed' or h.tai_pattern <> 23 or (h.score_delta ->> '1')::int <> 510 or (h.score_delta ->> '3')::int <> -510 then
    raise exception '那一局已經不是原本的內容（狀態 %、台數 %），停下來不改', h.status, h.tai_pattern;
  end if;
  if h.dealer_seat in (1, 3) then raise exception '莊家牽涉其中，台數要重算，停下來'; end if;
  if (select status from table_sessions where id = h.session_id) <> 'open' then
    raise exception '這場已經收桌，成績算過了，不能只改這一局';
  end if;
  if (select count(*) from scoring_patterns where code in ('hunyise', 'triplet_dragon', 'quanhong', 'baozi') and is_active) <> 4 then
    raise exception '主檔少了要用的牌型';
  end if;

  update hands
     set patterns       = '[{"code":"hunyise","n":1},{"code":"triplet_dragon","n":1},{"code":"quanhong","n":1},{"code":"baozi","n":2}]'::jsonb,
         tai_pattern    = 18,
         proposed_delta = '{"1":510,"2":0,"3":-510,"4":0}'::jsonb,
         score_delta    = '{"1":510,"2":0,"3":-510,"4":0}'::jsonb
   where id = v_hand;
  get diagnostics v_n = row_count;
  if v_n <> 1 then raise exception '沒有改到那一局'; end if;

  perform public._tbl_ping(h.session_id);   -- 四台平板重新拉狀態
end $$;

-- ── 驗證（單一 SELECT）──
select
  (select tai_pattern from hands where id = '80c99d25-61b4-4c98-abd1-301335e04a73')                     as "台數（應為 18）",
  (select score_delta from hands where id = '80c99d25-61b4-4c98-abd1-301335e04a73')::text               as "分數（應為 1:510 3:-510）",
  (select string_agg(p.label || case when x.n > 1 then '×' || x.n else '' end, '、')
     from hands h, jsonb_to_recordset(h.patterns) as x(code text, n int)
     join scoring_patterns p on p.code = x.code
    where h.id = '80c99d25-61b4-4c98-abd1-301335e04a73')                                                as "牌型",
  (select string_agg(k || ':' || t, ' ' order by k) from (
     select k, sum((h.score_delta ->> k)::int) t from hands h, unnest(array['1','2','3','4']) k
      where h.session_id = 'e6e51224-d54c-4836-b54a-ec00330498f8' and h.status = 'confirmed' group by k) s)
                                                                                                        as "各家累計（金額沒變，應與改之前相同）";
