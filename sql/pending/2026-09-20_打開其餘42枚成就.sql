/* 2026-09-20 · 打開其餘 42 枚成就（C 區 31 枚牌型 ＋ A 區 11 枚等功能的）

   🎯 **使用者拍板：全部打開，顯示成「未達成」。**
     理由是同一句話 ——「成就要讓人知道有什麼可以追」。

   🔴 **在此之前是兩套標準，而那是沒有人決定過的**：
     旗艦兩枚（等 M4）看得見，牌型 31 枚（也等 M4）卻藏起來。
     日後有人問「為什麼這枚看得到那枚看不到」，答案會是「沒有人決定過」。
     ⇒ 現在只有一套：**主檔裡的東西就會出現在牆上。**

   ⚠ **已知代價，而且是接受的**：這 42 枚今天一枚都解不開
     （發射端要等 M4 電子計分／打卡／抽獎／每週任務／券）。
     客人會看到一片灰徽章 —— 那正是「可以追的清單」該有的樣子。

   ⚠ **要在 `2026-09-20_匯入傳說兩枚與累積型進度.sql` 之後跑。**
     那一份先進來的話，總數才會是 62；順序反了第 ③ 格會紅，
     而**紅的原因會是順序不是資料**（硬規則 3.56：先懷疑期望值）。

   📌 這一份**沒有任何 DDL**，只有一句 UPDATE ——
     所以硬規則 1.8 那條（不可以 raise）照樣成立：驗證段一個 raise 都沒有。

   期望值的算式（硬規則 3.56，不要憑印象寫）：
     改之前   60 枚 ＋ 2 傳說 = 62 枚，其中 active 20（新手 18 ＋ 傳說 2）
     這次動   62 − 20 = **42 枚**（牌型 31 ＋ 新手 11）
     改之後   62 枚全部 active，關著的 0
*/

-- ---------- ① 打開 ----------
-- 🔴 `updated_at = now()` 不是裝飾 —— `now()` 在交易內是固定值，
--   所以它同時是「蓋時間戳」與「**替這次動到的列做記號**」，
--   下面第 ② 格就是靠它數出「這次真的動了幾枚」。
update achievements
   set is_active = true, updated_at = now()
 where not is_active
   and deleted_at is null;

-- ---------- ② 驗證 ----------
do $$
declare
  v_msg  text := '';
  v_txt  text;
  v_n    bigint;
begin
  -- ① 這次動到幾枚（期望 42）
  select count(*) into v_n from achievements where updated_at = now();
  v_msg := v_msg || case when v_n = 42
    then '✅ ① 這次打開 42 枚'
    else '🔴 ① 這次動到 ' || v_n || ' 枚，期望 42（牌型 31 ＋ 新手 11）' end;

  -- ② 🔴 負對照：這次只可以碰 is_active，不可以動到別的
  select count(*) into v_n
    from achievements
   where updated_at = now()
     and (visibility <> 'visible' or deleted_at is not null or not is_active);
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ② 動到的那批：全部 visible、沒有被誤刪、全部真的開了'
    else '🔴 ② 動到的那批有 ' || v_n || ' 枚狀態不對' end;

  -- ③ 🔴 負對照的另一半：原本就開著的 20 枚**不可以**被碰
  --    （`updated_at` 沒變 ⇒ 那句 where 真的有擋住它們）
  select count(*) into v_n
    from achievements
   where is_active and deleted_at is null and updated_at <> now();
  v_msg := v_msg || E'\n' || case when v_n = 20
    then '✅ ③ 原本就開著的 20 枚沒有被重寫'
    else '🔴 ③ 沒被碰的只有 ' || v_n || ' 枚，期望 20'
      || '（18 新手 ＋ 2 傳說 —— 不是 20 的話先確認傳說那份跑過了沒）' end;

  -- ④ 收尾狀態：關著的要歸零
  select count(*) into v_n from achievements where not is_active and deleted_at is null;
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ④ 關著的成就 0 枚'
    else '🔴 ④ 還有 ' || v_n || ' 枚關著' end;

  -- ⑤ 牆上實際會出現幾枚（照 `get_my_achievements_tx` 的過濾條件算）
  --   ⚠ 不可以直接叫那支 RPC —— 它要 `current_member_id()`，
  --     而 Dashboard 是 postgres 身分，會被 28000 拒絕。
  select count(*) into v_n
    from achievements
   where is_active and deleted_at is null
     and (valid_from is null or now() >= valid_from)
     and (valid_to   is null or now() <= valid_to);
  v_msg := v_msg || E'\n' || case when v_n = 62
    then '✅ ⑤ 成就牆會出現 62 枚'
    else '🔴 ⑤ 成就牆會出現 ' || v_n || ' 枚，期望 62' end;

  -- ⑥ 🔴 每一枚都要有解鎖條件 —— 畫面上那一列現在一律印出來，
  --    空的會變成「—」，而那對一枚「請你去追」的成就是一句廢話
  select count(*) into v_n
    from achievements
   where is_active and deleted_at is null
     and (condition_text is null or btrim(condition_text) = '');
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ⑥ 62 枚都有解鎖條件可以印'
    else '🔴 ⑥ 有 ' || v_n || ' 枚沒有 condition_text，詳情頁會印「—」' end;

  -- ⑦ 每一枚都要有事件，否則它**永遠**解不開（不是「等 M4」，是根本沒接線）
  select count(*) into v_n
    from achievements
   where is_active and deleted_at is null
     and (trigger is null or trigger->>'event' is null);
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ⑦ 62 枚都掛得上事件'
    else '🔴 ⑦ 有 ' || v_n || ' 枚沒有 trigger.event' end;

  -- ⑧ 牆上長什麼樣（給人看的，不是是非題）
  select string_agg(x.分類 || ' ' || x.n, '　' order by x.分類) into v_txt
    from (select ui_category as 分類, count(*) as n
            from achievements where is_active and deleted_at is null
           group by 1) x;
  v_msg := v_msg || E'\n⚪ ⑧ 分類：' || coalesce(v_txt, '（查不到）');

  select string_agg(x.稀有度 || ' ' || x.n, '　' order by x.ord) into v_txt
    from (select rarity as 稀有度, count(*) as n,
                 case rarity when 'legend' then 1 when 'epic' then 2
                             when 'rare' then 3 else 4 end as ord
            from achievements where is_active and deleted_at is null
           group by 1) x;
  v_msg := v_msg || E'\n⚪ ⑧ 稀有度：' || coalesce(v_txt, '（查不到）');

  perform set_config('migi.open_ach', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.open_ach', true), ''), '🔴 沒有訊息') as "驗證";
