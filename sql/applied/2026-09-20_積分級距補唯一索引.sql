-- ============================================================
-- stake_levels 補 label 唯一索引（2026-09-20）
--
-- ### 🔴 先記一個決定，因為它讓這個索引可以寫得比原本嚴
-- 使用者 2026-09-20：**「積分全台統一，由總部統一管理；
--   要客製積分也由總部設定。」**
-- ⇒ 沒有任何人會在不知情的狀況下建出第二筆同名級距 ——
--   店長不能設，只有總部能設，而總部設的時候看得到現有清單。
--
-- 🎯 而還有一個更硬的理由：**label 本身就是底台的寫法**
--   （`50/20` ＝ 底 50 台 20）⇒ **同名不同值是一個會說謊的名字**，
--   那正是這個專案記過八次的病。要收得不一樣就叫 `60/25`，
--   沒有任何正當理由讓兩筆都叫 `50/20`。
--   ⚠ 唯一的例外是 `純娛樂`（名字不是底台），而它也只有一筆。
--
-- ⇒ 所以是**一個索引管全部**，不是分「全連鎖」與「店限定」兩個：
--     unique (org_id, label) where deleted_at is null
--
-- ### 起因
-- 2026-09-20 新增 60/20 與 100/50 時撈了約束與索引，發現
--   **這張表沒有任何 label 的唯一鍵**（只有 pkey 與兩個外鍵）
--   ⇒ 那份 SQL 必須用 `where not exists` 才能冪等，
--     而任何人手動 INSERT 一次就會靜默長出第二筆。
-- 🔴 症狀是看不出原因的那一種：積分選單出現**兩顆一模一樣的膠囊**，
--   沒有任何錯誤，而前端 `find(x => x.label === stake)` 會隨便挑一個。
--
-- ### ✅ 它順便關掉了一個待辦
-- `match.jsx` 用 **label 字串**當 key 回推級距（`buddies` 用 id）——
-- 原本要記成「哪天 label 不唯一就會壞」。
-- 有了這個索引，**label 在同一個 org 內永遠唯一** ⇒ 那個寫法從此是安全的，
-- 不必為了它去改前端。（形狀仍然不一致，但那是整齊問題不是正確性問題。）
--
-- ⚠ `if not exists` **只檢查名字不檢查定義**（CLAUDE.md 待辦 27.5：
--   `uq_buddy_pair` 就是這樣長出第二個一模一樣的索引）
--   ⇒ 驗證段把定義整段印出來，不要只問「在不在」。
--
-- 查證（動手前）：同 org 同 label 重複 0 組 · 店限定級距 0 筆 ⇒ 建得起來。
-- ⚠ 這份要留下 DDL ⇒ 驗證段最外層一個字都不准 raise（硬規則 1.8）。
--   裡面那幾格的 `raise` 是**故意用來回滾樣本**的，靠
--   `begin…exception` 的隱含 savepoint，碰不到外面的 DDL。
-- ============================================================

create unique index if not exists uq_stake_label
  on public.stake_levels (org_id, label)
  where deleted_at is null;


-- ============================================================
-- 驗證
-- ============================================================
do $$
declare
  v_msg   text := '';
  v_n     int;
  v_txt   text;
  v_org   uuid;
  v_store uuid;
begin
  select org_id into v_org   from stake_levels where deleted_at is null limit 1;
  select id     into v_store from stores        where deleted_at is null limit 1;

  -- ① 索引在，**而且 indisvalid**
  --    🔴 INVALID 的索引會存在、看得到、完全不擋，而且沒有任何症狀
  --      （CLAUDE.md 在 uq_members_line_user 那裡記過）
  select count(*) into v_n
    from pg_index i join pg_class c on c.oid = i.indexrelid
   where c.relname = 'uq_stake_label' and i.indisunique and i.indisvalid;
  v_msg := case when v_n = 1
    then '✅ ① uq_stake_label 在，而且 indisvalid'
    else '🔴 ① 有效的 uq_stake_label 有 ' || v_n || ' 個（應為 1）' end;

  -- ② 定義整段印出來讓人判讀（`if not exists` 只比名字，不比定義）
  v_msg := v_msg || E'\n' || coalesce(
    (select '　　' || indexdef from pg_indexes
      where schemaname = 'public' and tablename = 'stake_levels'
        and indexname = 'uq_stake_label'),
    '⚪ 這一格取不到（0 列）');   -- 字串 || NULL 會吃掉前面所有格（硬規則 3.555）

  -- ③ 🔴 正對照：真的去插一筆同名的全連鎖級距，必須被擋下來
  --    只驗「索引建起來了」的話，一個 INVALID 的索引也會讓 ① 以外全綠
  begin
    insert into stake_levels (org_id, store_id, label, base, tai, is_hygiene, sort_order, is_active)
    values (v_org, null, '純娛樂', 30, 10, true, 99, true);
    raise exception 'migi_not_blocked';   -- 沒被擋 ⇒ 自己丟，順便把那一筆回滾掉
  exception
    when unique_violation then
      v_msg := v_msg || E'\n' || '✅ ③ 同名的全連鎖級距被擋下來（23505）';
    when others then
      v_msg := v_msg || E'\n' || case when sqlerrm = 'migi_not_blocked'
        then '🔴 ③ 同名竟然插得進去 —— 索引沒有在擋（那一筆已隨 savepoint 回滾）'
        else '⚠ ③ 意外中斷：' || sqlstate || ' ' || sqlerrm end;
  end;

  -- ④ 🎯 這一格是這次改寫的重點：**店限定同名也要被擋**
  --    先前的兩個部分索引擋不到它（store_id 一個 null 一個有值 ⇒ 不衝突），
  --    而「總部統一管理」＋「label 就是底台」讓同名沒有任何正當用途。
  if v_store is null then
    v_msg := v_msg || E'\n' || '⚪ ④ 沒有門市可以取樣，這一格測不了';
  else
    begin
      insert into stake_levels (org_id, store_id, label, base, tai, is_hygiene, sort_order, is_active)
      values (v_org, v_store, '純娛樂', 30, 10, true, 99, false);
      raise exception 'migi_not_blocked';
    exception
      when unique_violation then
        v_msg := v_msg || E'\n' || '✅ ④ 店限定同名也被擋下來 —— label 在同一個 org 內唯一';
      when others then
        v_msg := v_msg || E'\n' || case when sqlerrm = 'migi_not_blocked'
          then '🔴 ④ 店限定同名插得進去 —— 前端用 label 當 key 仍然不安全（已回滾）'
          else '⚠ ④ 意外中斷：' || sqlstate || ' ' || sqlerrm end;
    end;
  end if;

  -- ⑤ 🔴 負對照：不同名的照樣插得進去
  --    過度阻擋跟沒擋一樣糟，而且更難發現（硬規則 3.55）
  --    ⚠ 這一格連「店限定」一起驗 —— 總部要能替某一間店開新級距
  if v_store is null then
    v_msg := v_msg || E'\n' || '⚪ ⑤ 沒有門市可以取樣，這一格測不了';
  else
    begin
      insert into stake_levels (org_id, store_id, label, base, tai, is_hygiene, sort_order, is_active)
      values (v_org, v_store, '_t_負對照 500/200', 500, 200, false, 99, false);
      raise exception 'migi_rollback';      -- 插成功 ⇒ 自己回滾
    exception
      when unique_violation then
        v_msg := v_msg || E'\n' || '🔴 ⑤ 不同名的店限定級距也被擋了 —— 這個索引管太寬';
      when others then
        v_msg := v_msg || E'\n' || case when sqlerrm = 'migi_rollback'
          then '✅ ⑤ 總部仍然開得了店限定的新級距（樣本已回滾）'
          else '⚠ ⑤ 意外中斷：' || sqlstate || ' ' || sqlerrm end;
    end;
  end if;

  -- ⑥ 既有 9 列一筆都沒被動到
  select count(*) into v_n from stake_levels where deleted_at is null;
  select string_agg(sort_order || '.' || label, ' ' order by sort_order) into v_txt
    from stake_levels where deleted_at is null;
  v_msg := v_msg || E'\n' || case when v_n = 9
    then '✅ ⑥ 仍然是 9 級，樣本全部回滾乾淨'
    else '🔴 ⑥ 變成 ' || v_n || ' 級 —— 有樣本沒回滾掉' end
    || E'\n' || '　　' || coalesce(v_txt, '⚪ 取不到');

  perform set_config('migi.verify', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify', true), ''), '🔴 沒有驗證訊息') as "驗證";
