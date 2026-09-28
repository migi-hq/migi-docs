/* ============================================================
   唯讀：線上的 tbl_confirm_hand_tx 是不是「全部確認才一次入帳」
   2026-09-28 · 使用者：「自摸三家都確認後分數才會變動，包牌也是」

   規則（2026-09-25 拍板，sql/applied/2026-09-25_自摸一家取消整局作廢.sql）：
     · 還有人沒按 ⇒ 只記 confirmed_seats，score_delta 不動
     · 最後一個人按 ⇒ score_delta = proposed_delta，一次入帳
   ⚠ applied/ 不是線上的鏡像（硬規則 3）⇒ 用 pg_get_functiondef 問線上本人。
   ⚠ 不用是非題掃「有沒有提到」（硬規則 3.5）：逐項印出命中的那一行讓人判讀。
   ============================================================ */

with f as (
  select pg_get_functiondef(p.oid) as def
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname = 'tbl_confirm_hand_tx'
)
select
  (select count(*) from f) as "版本數（應為 1）",
  -- ① 還沒到齊的那一支：應該只更新 confirmed_seats
  coalesce((select (regexp_match(def, '(update hands set confirmed_seats = v_ok where id = h\.id;)'))[1] from f),
           '🔴 找不到「只記 confirmed_seats」那一行') as "① 還沒到齊時",
  -- ② 到齊的那一支：score_delta 才等於 proposed_delta
  coalesce((select (regexp_match(def, '(set score_delta = h\.proposed_delta[^\n]*)'))[1] from f),
           '🔴 找不到「一次入帳」那一行') as "② 全部確認時",
  -- ③ 反向：有沒有別的地方在確認時就把分數加上去（逐行印出來判讀，註解無害）
  coalesce((select string_agg(l, E'\n') from f, regexp_split_to_table(def, E'\n') l
             where l ~ 'score_delta\s*=' and l !~ 'proposed_delta' and l !~ 'jsonb_object_agg'),
           '✅ 沒有其他寫入 score_delta 的地方') as "③ 其他寫分數的行";
