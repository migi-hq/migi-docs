-- ============================================================
-- tile_12「三個北風」的說明文案：四方風都有了 → 北風也到手了
--
-- 🔴 為什麼改：條件只是「胡牌時持有北風刻」，
--   拿到這枚的客人**不一定四種風都有** ⇒ 原文案是一句假話。
--   看起來是寫給東南西北四枚「依序看」的最後一句，
--   但成就是各自獨立解鎖的，客人看到的時候前面三枚可能一枚都沒有。
-- 🎯 新文案跟同組前三枚同一個語氣：
--   東風在手／南風也收齊了／西風湊成一組／北風也到手了
--
-- ⚠ 只改 description；name 與 condition_text 不動。
-- 🔴 冪等：用 code 當條件。
-- 硬規則 1.8：這份要留下 UPDATE ⇒ 驗證段一個字都不准 raise。
-- ============================================================

update public.achievements
   set description = '北風也到手了',
       updated_at  = now()
 where code = 'tile_12'
   and deleted_at is null;


-- ---------- 驗證段 ----------
do $$
declare
  v_msg text := '';
  v_n   int;
  v_t   text;
begin
  -- ① 改完的樣子
  select name || '｜' || description || '｜' || condition_text into v_t
    from public.achievements where code = 'tile_12' and deleted_at is null;
  v_msg := '① tile_12  ' || coalesce(v_t, '🔴 查不到');

  -- ② 舊文案全表都不在了
  select count(*) into v_n from public.achievements
   where deleted_at is null and description = '四方風都有了';
  v_msg := v_msg || E'\n② 舊文案還在的：' || v_n || case when v_n = 0 then '  ✅' else '  🔴' end;

  -- ③ 正對照：同組另外三枚風的文案不可以被動到
  select count(*) into v_n from public.achievements
   where code in ('tile_09', 'tile_10', 'tile_11')
     and description in ('東風在手', '南風也收齊了', '西風湊成一組');
  v_msg := v_msg || E'\n③ 東南西三枚原封不動：' || v_n || ' / 3' || case when v_n = 3 then '  ✅' else '  🔴' end;

  -- ④ 名稱與條件沒被動到
  select count(*) into v_n from public.achievements
   where code = 'tile_12' and name = '三個北風' and condition_text = '胡牌時持有北風刻';
  v_msg := v_msg || E'\n④ 名稱與條件原封不動：' || v_n || ' / 1' || case when v_n = 1 then '  ✅' else '  🔴' end;

  perform set_config('migi.north', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.north', true), ''), '🔴 沒有訊息') as "驗證";
