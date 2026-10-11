-- ============================================================
-- 牌局結束就更新個人成績，不用等收桌（2026-10-11 使用者）
--
-- 名次、段位分本來就在「約定的將數打完」那一刻自動結算（硬規則 13.9c），
-- 但下面四支只算「已收桌」的場次 ⇒ 成績頁、個人卡、全國排名要等店員按收桌才變：
--   _member_hand_counts     每一局的統計（胡牌率、自摸率、放槍率、局數排行）           1 處
--   _member_stats_core      成績頁：場數名次、勝率、連勝、各級距、對手段位、麻將足跡   6 處
--   _season_rank_rows_core  全國排名的場數                                           1 處
--   get_member_card_tx      個人卡上能不能「加牌咖」（同桌打過才能加）                 1 處
-- 改成跟對局紀錄（get_my_games_tx）同一個判斷：「已收桌，或這個人已經有名次」。
--   ⚠ 前三支本來就同時要求「有名次、有結算時間」，所以實際效果就是「算完成績就算」。
--   ⚠ 麻將足跡的「打了幾分鐘」看的是收桌時間（ended_at），還沒收桌的那一場分鐘數照舊不算 —— 那是事實不是漏算。
--
-- 做法：撈線上全文、把那一行換掉、檢查每支換掉的次數剛好等於上面的數字再執行（CREATE OR REPLACE，授權不變）。
--   次數不對就整份不執行（raise ⇒ 整個交易回滾，什麼都沒改 —— 這是故意的保險，不是驗證訊息）。
-- 行為測試另外跑 sql/checks/2026-10-11_驗成績不等收桌.sql（交易內把一場改回「還沒收桌」再算，最後回滾）。
-- ============================================================

do $$
declare
  r record;
  v_def text; v_new text; v_n int;
begin
  for r in
    select * from (values
      ('_member_hand_counts',    'and s.status     = ''completed''', 'and (s.status = ''completed'' or sp.finish_rank is not null)', 1),
      ('_member_stats_core',     'and s.status     = ''completed''', 'and (s.status = ''completed'' or sp.finish_rank is not null)', 6),
      ('_season_rank_rows_core', 'and s.status  = ''completed''',    'and (s.status = ''completed'' or sp.finish_rank is not null)', 1),
      ('get_member_card_tx',     'and s.status = ''completed''',     'and (s.status = ''completed'' or me.finish_rank is not null)', 1)
    ) t(fn, old_txt, new_txt, expect)
  loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = r.fn;
    v_n := (length(v_def) - length(replace(v_def, r.old_txt, ''))) / length(r.old_txt);
    if v_n <> r.expect then
      raise exception '% 預期換 % 處，實際找到 % 處 —— 整份不執行', r.fn, r.expect, v_n;
    end if;
    v_new := replace(v_def, r.old_txt, r.new_txt);
    execute v_new;
  end loop;
end $$;

-- ── 驗證（單一 SELECT）：每支版本數 1、換上的寫法出現次數對、舊寫法一處都不剩 ──
select string_agg(
         case when cnt = 1 and n_new = expect and n_old = 0
              then '✅ ' || fn || '（' || n_new || ' 處）'
              else '🔴 ' || fn || '：版本 ' || cnt || '、新寫法 ' || n_new || '／' || expect || '、舊寫法還有 ' || n_old end,
         E'\n' order by fn) as "驗證"
  from (
    select t.fn, t.expect,
           (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = t.fn) as cnt,
           (select count(*) from pg_proc p, regexp_matches(pg_get_functiondef(p.oid), 'status = ''completed'' or (sp|me)\.finish_rank is not null', 'g')
             where p.pronamespace = 'public'::regnamespace and p.proname = t.fn) as n_new,
           (select count(*) from pg_proc p, regexp_matches(pg_get_functiondef(p.oid), 'and s\.status\s+=\s+''completed''', 'g')
             where p.pronamespace = 'public'::regnamespace and p.proname = t.fn) as n_old
      from (values ('_member_hand_counts', 1), ('_member_stats_core', 6), ('_season_rank_rows_core', 1), ('get_member_card_tx', 1)) t(fn, expect)
  ) x;
