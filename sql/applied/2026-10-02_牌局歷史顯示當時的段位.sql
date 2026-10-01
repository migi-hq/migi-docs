/* ============================================================
   牌局歷史：段位改成「那一場打完時的段位」· 2026-10-02
   📄 使用者 2026-10-02：「全照妳建議」

   會員 App 的牌局歷史（get_my_games_tx／get_game_tx 都經過 _game_row）每位玩家的 rank
   原本讀 members.rank（現在的段位）⇒ 一年前那場會被今天的段位蓋掉。

   世界級的分法（chess.com 棋譜寫的是當時的等級分、天鳳牌譜記當時的段位）：
     這個人是誰（頭像、暱稱、稱號）  ⇒ 現在的（照舊）
     那一場發生了什麼（名次、積分、段位）⇒ 當下的

   新規則（rank 這個鍵名不變，前端一行不用改）：
     被隱藏的帳號            ⇒ null（頭像與名字已經變問號；保險箱裡沒有段位，原本會照樣露出來）
     那一場有 rating_after   ⇒ rank_from_rating(rating_after)＝那一場打完時的段位
     還在打（場次 open）      ⇒ 現在的段位（還沒結束，「當時」就是現在）
     其餘（收了桌卻沒有段位分，例如只打 1 將）⇒ null（不知道就不猜）

   📌 查證過（2026-10-02）：
     · members.rank 與 rank_from_rating(members.rating) 格式相同、5 位會員全部一致
     · 收過桌的 52 筆 session_players 都有 rating_after；沒有的 6 筆都是 open 的場次
     · members.avatar_source 是 NOT NULL 預設 bear ⇒ 頭像元件不會退回「照 rank 挑熊」，
       改成當時的段位不會讓頭像變成當時那隻熊
   ⚠ 改的是線上全文（不是 sql/applied 的檔），錨點必須剛好出現一次；CREATE OR REPLACE、簽名不變 ⇒ 授權不會掉。
   ============================================================ */

do $$
declare
  v_def text;
  v_old text := $a$'rank',         mem.rank,$a$;
  v_new text := $b$/* 段位是「那一場的事實」：打完時的段位（2026-10-02）。被隱藏的人不顯示；還在打就是現在的；
                  收了桌卻沒有段位分（只打 1 將）就不顯示 —— 不知道當時是什麼，不猜 */
               'rank',         case when mem.hidden_at is not null then null
                                    when p.rating_after is not null then public.rank_from_rating(p.rating_after)
                                    when m.status = 'open' then mem.rank
                                    else null end,$b$;
  v_n int;
begin
  v_def := pg_get_functiondef('public._game_row(uuid,uuid,uuid)'::regprocedure);
  if position('public.rank_from_rating(p.rating_after)' in v_def) > 0 then
    return;   -- 已經改過（可重跑）
  end if;
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_n <> 1 then
    raise exception '_game_row 的錨點出現 % 次（要剛好 1 次），整份不執行', v_n;
  end if;
  execute replace(v_def, v_old, v_new);
end $$;

/* ── 驗證（單一 SELECT；不用 raise，硬規則 1.8）──
   ③ 正對照：找一位「打完時的段位」跟「現在的段位」不同的玩家，看回傳的是哪一個；
     找不到這種樣本就印 ⚪（不假裝通過）。_game_row 是 STABLE、只讀，在 SELECT 裡叫它不會寫入任何東西 */
with
fn as (select count(*) as n from pg_proc where pronamespace = 'public'::regnamespace and proname = '_game_row'),
df as (select pg_get_functiondef('public._game_row(uuid,uuid,uuid)'::regprocedure) as d),
diff as (   -- 打完時的段位 ≠ 現在的段位
  select sp.session_id, sp.member_id, sp.org_id, public.rank_from_rating(sp.rating_after) as 當時, m.rank as 現在
    from session_players sp join members m on m.id = sp.member_id
   where sp.rating_after is not null and m.hidden_at is null
     and public.rank_from_rating(sp.rating_after) is distinct from m.rank
   limit 1),
got as (
  select d.當時, d.現在,
         (select x ->> 'rank' from jsonb_array_elements(public._game_row(d.org_id, d.session_id, d.member_id) -> 'players') x
           where x ->> 'member_id' = d.member_id::text) as 回傳
    from diff d),
op as (     -- 還在打的場次：回傳要等於現在的段位
  select m.rank as 現在,
         (select x ->> 'rank' from jsonb_array_elements(public._game_row(sp.org_id, sp.session_id, sp.member_id) -> 'players') x
           where x ->> 'member_id' = sp.member_id::text) as 回傳
    from session_players sp join table_sessions s on s.id = sp.session_id join members m on m.id = sp.member_id
   where s.status = 'open' and s.deleted_at is null and m.hidden_at is null
   limit 1),
gr as (     -- 授權沒有被動到（CREATE OR REPLACE 不會掉，仍然驗一次）
  select string_agg(coalesce(r.rolname, 'PUBLIC'), ',' order by r.rolname) as who
    from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a left join pg_roles r on r.oid = a.grantee
   where p.pronamespace = 'public'::regnamespace and p.proname = '_game_row' and a.privilege_type = 'EXECUTE')
select concat_ws(E'\n',
  case when (select n from fn) = 1 then '✅ ① _game_row 版本數 1' else '🔴 ① 版本數 ' || (select n from fn) end,
  case when (select d from df) ~ 'public\.rank_from_rating\(p\.rating_after\)' and (select d from df) ~ 'mem\.hidden_at is not null then null'
       then '✅ ② 段位改讀那一場的 rating_after，被隱藏的人不顯示' else '🔴 ② 函式體沒有改到' end,
  coalesce((select case when 回傳 = 當時 then '✅ ③ 打完時的段位：回傳「' || 回傳 || '」（現在是「' || coalesce(現在, '未定位') || '」）'
                        else '🔴 ③ 回傳「' || coalesce(回傳, 'null') || '」，應為打完時的「' || 當時 || '」' end from got),
           '⚪ ③ 找不到「打完時段位 ≠ 現在段位」的樣本，這一格測不了'),
  coalesce((select case when 回傳 is not distinct from 現在 then '✅ ④ 還在打的場次：回傳現在的段位「' || coalesce(回傳, '未定位') || '」'
                        else '🔴 ④ 還在打的場次回傳「' || coalesce(回傳, 'null') || '」，應為現在的「' || coalesce(現在, 'null') || '」' end from op),
           '⚪ ④ 現在沒有還在打的場次，這一格測不了'),
  case when (select who from gr) = 'postgres,service_role' then '✅ ⑤ 授權沒變（只有後端叫得到）' else '🔴 ⑤ 授權變了：' || coalesce((select who from gr), '（空）') end
) as "驗證";
