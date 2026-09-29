-- ════════════════════════════════════════════════════════════════════
-- 2026-09-29 match_queues.game_type 的預設值改成「台麻」（使用者決定：實務上 99% 都是台麻）
--
-- 之前：預設值是「16張」，而 match_queues_game_type_chk 只允許 台麻／美麻（NOT VALID ⇒ 舊資料放過、新資料照擋）
--       ⇒ 任何沒指定玩法的新增都會失敗，錯誤訊息是「違反約束」，看不出原因。
--       2026-09-29 行為測試（驗配桌完成記當班店員）就撞在這裡。
-- 之後：沒指定玩法 ⇒ 台麻。
--
-- ⚠ 已知取捨（使用者同意）：某支函式漏傳玩法時，客人選美麻會默默變成台麻、不報錯。
--   現有的配桌函式都會明確傳玩法，所以今天沒有這種路徑；新寫配桌相關的函式時仍然要明確傳。
-- ⚠ 不會打壞任何現有函式：預設值「16張」本來就過不了約束 ⇒ 靠預設值的寫法今天全部會失敗，
--   改完它們反而會成功。
-- ⚠ 舊資料裡的「16張」不動（這份只管以後）；第 ③ 格印出來有幾筆，要清另外處理。
-- ⚠ 檔名沿用第一版的「拿掉預設值」—— 同日改成預設台麻，以檔頭為準。
-- ⚠ 這份要留下東西 ⇒ 驗證段不 raise（硬規則 1.8）。
-- ════════════════════════════════════════════════════════════════════

alter table public.match_queues alter column game_type set default '台麻';

comment on column public.match_queues.game_type is
  '玩法：台麻／美麻（match_queues_game_type_chk）。預設台麻（2026-09-29 換掉原本不合法的「16張」；實務上 99% 是台麻）。
   ⚠ 預設值會讓「漏傳玩法」變成台麻而不報錯 —— 新寫配桌相關的函式仍要明確傳。';

-- 驗證（單一 SELECT，不 raise）
do $$
declare v text := ''; d text; nn text; n int; t text; ok text := '✅ '; bad text := '🔴 ';
begin
  select column_default, is_nullable into d, nn from information_schema.columns
   where table_schema = 'public' and table_name = 'match_queues' and column_name = 'game_type';
  v := v || (case when d like '''台麻''%' then ok else bad end) || '① game_type 預設值是台麻（' || coalesce(d, 'null') || '）' || E'\n';
  v := v || (case when nn = 'NO' then ok else bad end) || '② game_type 仍是必填（NOT NULL）' || E'\n';

  select string_agg(g || ' ' || c || ' 筆', '、') into t
    from (select game_type as g, count(*) as c from match_queues
           where game_type not in ('台麻', '美麻') group by 1 order by 1) x;
  v := v || '👀 ③ 舊資料裡不合法的玩法：' || coalesce(t, '（沒有）') || '（這份不動它們）' || E'\n';

  -- 負對照：約束還在（改預設不該碰到它）
  select count(*) into n from pg_constraint
   where conrelid = 'public.match_queues'::regclass and conname = 'match_queues_game_type_chk';
  v := v || (case when n = 1 then ok else bad end) || '④ 負對照：玩法的約束還在' || E'\n';

  perform set_config('migi.v', v, true);
end $$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有訊息') as "驗證";
