/* ============================================================
   桌被取消時不再通知客人
   2026-09-06 · MIGI 咪吉麻將 · 使用者指定

   ── 拿掉哪一則 ────────────────────────────────────────
   `trg_session_voided_release_queue` 在「店員取消開桌」時，會對房裡
   每一位客人插一則 `system` 通知：
       「原本安排的桌取消了，店員會幫你重新安排」
   （更早的版本寫「已幫你回到配桌等待」，資料庫裡還有那種舊列。）

   🎯 **拿掉的理由**：那則通知**沒有要客人做任何事**，而他多半
     還沒出門、也不知道原本被安排到哪一張桌 —— 換一張對他來說
     什麼都沒變。配桌頁本來就會顯示現在的狀態。
   ⚠ 通知的成本不是零：每一則都會佔掉鈴鐺上的紅點，而紅點多了
     就沒有人會去看 —— 那時**真的重要的那一則也一起失效**。

   ── 🔴 只拿掉這一則，流局那則留著 ─────────────────────
   同一支觸發器的 `else` 分支（過了開打時間還沒人來）會發
   `table_expired`「人數不足，本場流局」——**那則要留**：
   它是**結果**（這局不會打了），客人需要知道，而且不會再有下文。

   ⚠ 簽名沒變（觸發器函式）→ `CREATE OR REPLACE`，不用重掛觸發器。
   ============================================================ */

do $mig$
declare
  v_def text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'trg_session_voided_release_queue';

  if v_def is null then raise exception '找不到 trg_session_voided_release_queue'; end if;

  /* 把那一段 insert 整段換成註解。

     🔴 **PostgreSQL 的貪婪性是「整個 RE」一起決定的，不是各自獨立。**
       官方文件：混用貪婪與非貪婪量詞時，整體比對長度依**整個 RE**
       的屬性決定，而那個屬性來自**第一個量詞**。
     ⚠ 第一版寫成 `…\)\s*select…''system''[\s\S]*?;` ——
       開頭那個 `\s*` 是**貪婪**的 ⇒ 整個 RE 變貪婪
       ⇒ 後面的 `[\s\S]*?` 一路吃到**最後一個 `;`**，
         把 else 分支、`end loop`、`return new` 全部刪掉。
     🎯 幸好 plpgsql 立刻報 `syntax error at end of input` —— **fail loud**。
       但那個錯誤訊息指的是「函式不完整」，完全指不到 regex。
     → 規矩：**一個 pattern 裡不要混用貪婪與非貪婪**。這裡全部用 `*?`。 */
  v_new := regexp_replace(v_def,
    'insert into app_notifications[\s\S]*?''system''[\s\S]*?;',
    '/* 🔴 2026-09-06 拿掉「原本安排的桌取消了」那則通知（使用者指定）。'
    || chr(10) || '         它沒有要客人做任何事，而他多半還沒出門、也不知道原本'
    || chr(10) || '         被安排到哪一張桌 —— 換一張對他來說什麼都沒變。'
    || chr(10) || '       ⚠ 通知會佔掉鈴鐺的紅點，紅點多了真的重要的那則也會失效。'
    || chr(10) || '       ⚠ 下面 else 分支的「流局」通知**要留** —— 那是結果，'
    || chr(10) || '         客人需要知道而且不會再有下文。 */');

  if v_new = v_def then
    raise exception '🔴 沒有替換到 —— 線上版本跟預期不同，先撈出來看';
  end if;

  /* 🔴 **換完先檢查有沒有砍過頭，再 execute。**
     上面那個貪婪陷阱就是靠 plpgsql 的語法錯誤才被發現的 ——
     但那要等到 `execute` 才會炸，而且訊息指不到原因。
     這三行把它提前到「還看得懂」的時候。 */
  if v_new !~ '''table_expired''' then raise exception '🔴 砍過頭：流局那則通知不見了'; end if;
  if v_new !~ 'auto_seat = false'  then raise exception '🔴 砍過頭：放桌邏輯不見了'; end if;
  if v_new !~ 'end loop;'          then raise exception '🔴 砍過頭：迴圈的結尾不見了'; end if;

  execute v_new;
end $mig$;

/* ── 驗證 ────────────────────────────────────────────────
   ⚠ 掃函式內文時禁字要用「**會產生行為的東西**」（硬規則 3.5）——
     這裡用 `'system'` 這個字面值，不是「通知」兩個字
     （後者在我自己寫的註解裡就有）。 */
select
  /* ① 那一則不見了 */
  case when (select count(*) from pg_proc p
              where p.pronamespace = 'public'::regnamespace
                and p.proname = 'trg_session_voided_release_queue'
                and pg_get_functiondef(p.oid) ~ '''system''') = 0
       then '✅ ① 取消開桌不再發通知'
       else '🔴 ① 還在' end as ①不再通知,

  /* ② 🎯 正對照：**流局那則要還在**。
     ⚠ 少了這一格，一支「把兩個 insert 都刪掉」的實作也會讓①變綠。 */
  case when (select count(*) from pg_proc p
              where p.pronamespace = 'public'::regnamespace
                and p.proname = 'trg_session_voided_release_queue'
                and pg_get_functiondef(p.oid) ~ '''table_expired''') = 1
       then '✅ ② 流局通知還在（沒有連它一起刪掉）'
       else '🔴 ② 流局通知也不見了' end as ②流局仍會通知,

  /* ③ 🎯 正對照：**放桌那段邏輯沒被動到**。
     那才是這支觸發器真正的工作 —— 通知只是附帶的。 */
  case when (select count(*) from pg_proc p
              where p.pronamespace = 'public'::regnamespace
                and p.proname = 'trg_session_voided_release_queue'
                and pg_get_functiondef(p.oid) ~ 'auto_seat = false') = 1
       then '✅ ③ 取消後改手動那段還在'
       else '🔴 ③ 被改壞了' end as ③放桌邏輯沒動,

  /* ④ 觸發器本身還掛著（改函式不該影響它，但確認一次不用錢） */
  (select case when count(*) = 1 then '✅ ④ 觸發器仍掛在 table_sessions 上'
               else '🔴 ④ 觸發器不見了' end
     from pg_trigger t
    where not t.tgisinternal
      and t.tgfoid = 'public.trg_session_voided_release_queue'::regproc) as ④觸發器還在;
