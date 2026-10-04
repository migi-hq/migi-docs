/* ============================================================
   POS 桌況多回「要店員過去處理的事」· 2026-10-04
   📄 使用者 2026-10-02～04：POS 店員提醒（預覽 docs/_資產/POS店員提醒_預覽.html，「都照妳建議」）
     有人爆卡等決定／等確認超過 3 分鐘／平板超過 1 分鐘沒回報 ⇒ 桌況卡片標出來，店員掃一眼就知道哪桌有事。

   list_tables_tx 多回四樣**事實**，門檻（3 分鐘、1 分鐘）留在 POS 那一份（migi-pos/src/lib/tabletAlerts.js）：
     pending_since    這一場正在等確認的那一局是幾點送出的（沒有 ⇒ null）
     pending_waiting  還沒按確認、也還沒取消的人（名字陣列；沒有 ⇒ []）
     bust_name        爆卡還沒決定追加或結束的那一位（成績算完就不再等 ⇒ null，跟平板同一個判斷）
     device_seen      這張桌每一台還在用的平板最後回報時間 [{label, last_seen_at}]（沒開桌 ⇒ []）
   🎯 為什麼回時間不回「是不是太久」：門檻只有一份定義（POS 座位頁那一格也要用同一個判斷），
     後端也算一份的話，日後改門檻只改一邊就會變成兩種答案而且不報錯。
   ⚠ 名字用 members.display_name —— 跟平板畫面、桌況其他名字同一個來源（隱藏的會員本來就會是問號）。
   ⚠ 陣列欄位一律 coalesce 成空陣列再比對：`座位 = any(null)` 是 null，`not null` 也是 null ⇒ 那個人會安靜地被漏掉。
   ⚠ 改的是線上全文，錨點必須剛好出現一次（可重跑）。CREATE OR REPLACE、簽名不變 ⇒ 授權不會掉。
   ⚠ status 照舊三值（off／use／idle），舊版 POS 看不到新欄位就當沒有。
   ============================================================ */

do $$
declare
  v_def text;
  v_old text := $a$      'game_over', (ts.id is not null and public._session_scored(ts.id)),$a$;
  v_new text := $b$      'game_over', (ts.id is not null and public._session_scored(ts.id)),
      /* 要店員過去處理的事（2026-10-04）：只回事實，門檻（3 分鐘、1 分鐘）在 POS 那一份 */
      'pending_since', (select min(h.created_at) from hands h where h.session_id = ts.id and h.status = 'pending'),
      'pending_waiting', (select coalesce(jsonb_agg(m.display_name order by sp.seat), '[]'::jsonb)
                            from hands h
                            join session_players sp on sp.session_id = h.session_id and sp.left_at is null
                                 and sp.seat = any(coalesce(h.need_confirm, '{}'::smallint[]))
                                 and not (sp.seat = any(coalesce(h.confirmed_seats, '{}'::smallint[])))
                                 and not (sp.seat = any(coalesce(h.cancelled_seats, '{}'::smallint[])))
                            join members m on m.id = sp.member_id
                           where h.session_id = ts.id and h.status = 'pending'),
      'bust_name', case when ts.id is null or public._session_scored(ts.id) then null else
                     (select m.display_name from session_busts b
                        join session_players sp on sp.session_id = b.session_id and sp.seat = b.seat and sp.left_at is null
                        join members m on m.id = sp.member_id
                       where b.session_id = ts.id and b.decision = 'pending' order by b.seat limit 1) end,
      'device_seen', case when ts.id is null then '[]'::jsonb else
                       (select coalesce(jsonb_agg(jsonb_build_object('label', d.label, 'last_seen_at', d.last_seen_at)
                                                  order by d.label), '[]'::jsonb)
                          from table_devices d where d.table_id = t.id and d.is_active) end,$b$;
  v_n int;
begin
  v_def := pg_get_functiondef('public.list_tables_tx(uuid,uuid)'::regprocedure);
  if position('''device_seen''' in v_def) > 0 then
    return;   -- 已經改過（可重跑）
  end if;
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_n <> 1 then
    raise exception 'list_tables_tx 的錨點出現 % 次（要剛好 1 次），整份不執行', v_n;
  end if;
  execute replace(v_def, v_old, v_new);
end $$;

/* ── 驗證（單一 SELECT；不用 raise，硬規則 1.8）──
   行為（自己造一局等確認、一筆爆卡，看桌況有沒有說對人）在 sql/checks/2026-10-04_驗桌況回傳要店員處理的事.sql
   ③ 正對照：有配對平板的那一張桌，device_seen 的筆數要等於那張桌還在用的平板數（只驗「空的」的話，永遠回 [] 也會綠）
   ④ 反向：空桌的四樣都要是空的 */
with
fn as (select count(*) as n from pg_proc where pronamespace = 'public'::regnamespace and proname = 'list_tables_tx'),
df as (select pg_get_functiondef('public.list_tables_tx(uuid,uuid)'::regprocedure) as d),
dv as (   -- 一張開著場次、而且有配對平板的桌
  select t.org_id, t.store_id, t.id as table_id,
         (select count(*) from table_devices d where d.table_id = t.id and d.is_active) as n
    from tables t
   where exists (select 1 from table_sessions s where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
     and exists (select 1 from table_devices d where d.table_id = t.id and d.is_active)
   limit 1),
r1 as (select jsonb_array_length(x -> 'device_seen') as got, dv.n
         from dv, jsonb_array_elements(public.list_tables_tx(dv.org_id, dv.store_id)) x where (x ->> 'id')::uuid = dv.table_id),
anyst as (select org_id, store_id from tables where deleted_at is null and is_active limit 1),
r2 as (select count(*) filter (where x ->> 'session_id' is null) as idle,
              count(*) filter (where x ->> 'session_id' is null and (x ->> 'pending_since' is not null
                                 or jsonb_array_length(x -> 'pending_waiting') > 0 or x ->> 'bust_name' is not null
                                 or jsonb_array_length(x -> 'device_seen') > 0)) as bad,
              count(*) filter (where not (x ? 'pending_since' and x ? 'pending_waiting' and x ? 'bust_name' and x ? 'device_seen')) as nokey
         from anyst a, jsonb_array_elements(public.list_tables_tx(a.org_id, a.store_id)) x)
select concat_ws(E'\n',
  case when (select n from fn) = 1 then '✅ ① list_tables_tx 版本數 1' else '🔴 ① 版本數 ' || (select n from fn) end,
  case when (select d from df) ~ '''pending_since''' and (select d from df) ~ '''pending_waiting'''
        and (select d from df) ~ '''bust_name''' and (select d from df) ~ '''device_seen'''
       then '✅ ② 函式體多了四樣（pending_since／pending_waiting／bust_name／device_seen）' else '🔴 ② 函式體沒有改到' end,
  coalesce((select case when got = n then '✅ ③ 有平板的那一張桌：device_seen ' || got || ' 筆 ＝ 平板 ' || n || ' 台'
                        else '🔴 ③ device_seen ' || got || ' 筆，但那張桌有 ' || n || ' 台平板' end from r1),
           '⚪ ③ 現在沒有「開著場次又有配對平板」的桌，這一格測不了'),
  coalesce((select case when nokey = 0 and bad = 0 then '✅ ④ 每一張桌都有四個鍵；空桌 ' || idle || ' 張四樣都是空的'
                        else '🔴 ④ 缺鍵的桌 ' || nokey || ' 張、空桌卻有值的 ' || bad || ' 張' end from r2),
           '⚪ ④ 測不了')
) as "驗證";
