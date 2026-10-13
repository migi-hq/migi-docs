-- ============================================================
-- 智慧計分板：數字鍵模式自摸時，自動加自摸的台數
-- 2026-10-13 · MIGI 咪吉麻將
--
-- 使用者：「按數字鍵盤 要把自摸算進去（就不用再按一次）」
--   原本：數字鍵打的數字就是全部牌型台數，自摸不自動帶（10-12 的規則）⇒ 客人要自己把自摸那 1 台算進去
--   現在：自摸時 ＝ 打的數字 ＋ 自摸的台數（牌型主檔 zimo，現在是 1 台）；放槍胡照舊只算打的數字
--   · 莊家台照舊由系統加；牌型清單照舊是空的（manual_tai = true，不觸發牌型成就）
--   · 上限 99 檢查的是打的那個數字（自摸時實際台數最多 100）
--
-- 只換 tbl_submit_hand_tx 裡兩處文字（檔頭說明那一行、數字鍵算台數那兩行），其餘一個字都不改；
-- 對不上就整份不執行。⚠ 原文換行先統一成 \n（2026-10-13 卡片那份就是因為貼上變 \r\n 而比對不到）。
-- 前端（選牌型頁的數字鍵合計、教學引擎 engine.js）同一批改，規則兩份要一致。
-- ============================================================

do $$
declare
  v_def text := replace(pg_get_functiondef('public.tbl_submit_hand_tx'::regproc), E'\r\n', E'\n');
  v_old1 text := $a$其餘自動帶自摸 1 台。數字鍵模式不自動帶）$a$;
  v_new1 text := $a$其餘自動帶自摸 1 台。數字鍵模式也自動加自摸的台數，2026-10-13）$a$;
  v_old2 text := $b$    /* 數字鍵模式：台數就是打的那個數字，沒有牌型、沒有豹子、不自動帶自摸 */
    v_tai := p_manual_tai;$b$;
  v_new2 text := $b$    /* 數字鍵模式：台數就是打的那個數字，沒有牌型、沒有豹子。
       自摸時自動加自摸的台數（2026-10-13 使用者：按數字鍵要把自摸算進去，不用再按一次）；牌型清單照舊是空的 */
    v_tai := p_manual_tai + case when p_result = 'tsumo'
               then coalesce((select zp.tai from scoring_patterns zp where zp.code = 'zimo' and zp.is_active), 0)
               else 0 end;$b$;
begin
  v_old2 := replace(v_old2, E'\r\n', E'\n');
  v_new2 := replace(v_new2, E'\r\n', E'\n');
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 then
    raise exception 'tbl_submit_hand_tx 對不上，整份不執行';   -- 守衛：寧可回滾也不要改到一半
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end $$;


-- ============================================================
-- 驗證（單一 SELECT，不 raise —— 硬規則 1.8）
--   ① 版本數 1、還是 DEFINER
--   ② 數字鍵那一段有加自摸（舊版會紅 —— 正對照）
--   ③ 授權沒掉：anon 照舊叫得到（平板用的是 anon ＋ 平板憑證；CREATE OR REPLACE 本來就不會掉，這格是保險）
--   ④ 牌型主檔的自摸現在是幾台（就是會加的那個數字）
-- ============================================================
select concat_ws(E'\n',
  case when (select count(*) from pg_proc where proname = 'tbl_submit_hand_tx' and pronamespace = 'public'::regnamespace) = 1
        and (select prosecdef from pg_proc where proname = 'tbl_submit_hand_tx' and pronamespace = 'public'::regnamespace)
       then '① ✅ 版本數 1、DEFINER' else '① 🔴 版本不對' end,
  case when (select pg_get_functiondef('public.tbl_submit_hand_tx'::regproc) ~ 'v_tai := p_manual_tai \+ case when p_result = ''tsumo''')
       then '② ✅ 數字鍵自摸會加自摸的台數' else '② 🔴 沒改到' end,
  case when has_function_privilege('anon', 'public.tbl_submit_hand_tx(text, text, smallint, jsonb, integer)', 'execute')
       then '③ ✅ 平板照樣叫得到' else '③ 🔴 平板叫不到了' end,
  '④ ℹ 牌型主檔的自摸 = ' || coalesce((select tai::text from scoring_patterns where code = 'zimo' and is_active), '（沒有）') || ' 台'
) as "驗證";
