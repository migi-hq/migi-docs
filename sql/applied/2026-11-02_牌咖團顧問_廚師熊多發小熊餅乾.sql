/* ============================================================
   牌咖團顧問：廚師熊 —— 每打完一場，每人多 1 個小熊餅乾
   2026-11-02 · 寫入（migration）· 在 Supabase Dashboard 的 SQL Editor 執行

   ── 規則（照選顧問彈窗泡泡上寫的「每人多 1 個小熊餅乾」）──
   · 什麼時候發：這一場的名次寫進去那一刻（finish_rank 從空變成有值），
     跟「牌局結算完成」通知同一個時間點 —— 打完約定將數的自動結算、收桌補算都會經過這裡
   · 發給誰：整桌 4 位都是同一團、而那一團的顧問是廚師熊 ⇒ 四個人各 1 個
     「哪一團」用商人熊同一份定義 _advisor_table_team（四人共同的團有兩個以上時挑最早湊齊的那一團）
     ⇒ 四人同時在一個商人熊團、一個廚師熊團時，只會拿到其中一種加成，兩邊不會打架
   · 不發：好友練習賽（mode = friendly，那邊不發任何獎勵）；一將都沒打完（沒有名次，不會進到這裡）
   · 每場每人最多 1 個：冪等鍵 chef:<場次>:<會員>，重算名次、隨機名次再寫一次都不會重發
   · 沒有門市限制：商人熊限直營店是因為那是真的少收錢；餅乾沒有成本

   ── 做法 ──
   · 不改任何結算函式：掛一個 session_players 的觸發器（同 trg_session_players_settle_notify 的寫法）
     ⇒ 所有會寫名次的路徑一次涵蓋，日後多一條路也不用記得回來改
   · 發放走既有的 grant_snack_tx（帳本 snack_grants，2026-09-19 建）—— 不自己 insert
   · 發放失敗不可以讓成績回滾，但不安靜吞掉：記一筆 advisor_error 給錯誤儀表（① 用後綴 _error 掃得到）

   ⚠ snack_grants.reason 有 CHECK，這份把 'chef' 加進去
   ============================================================ */

-- ① 發放原因多一種
alter table public.snack_grants drop constraint snack_grants_reason_check;
alter table public.snack_grants add constraint snack_grants_reason_check
  check (reason = any (array['like', 'daily', 'task', 'draw', 'admin', 'feed', 'chef']));

-- ② 名次寫進去那一刻，看這桌是不是廚師熊團
create or replace function public._chef_perk_on_rank()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r record;
  v_team record;
  v_members uuid[];
  m uuid;
begin
  for r in
    select distinct ts.id as session_id, ts.org_id
      from new_rows n
      join old_rows o on o.id = n.id
      join table_sessions ts on ts.id = n.session_id
     where o.finish_rank is null and n.finish_rank is not null
       and coalesce(ts.mode, '') <> 'friendly'
  loop
    begin
      select array_agg(distinct sp.member_id) into v_members
        from session_players sp
       where sp.session_id = r.session_id and sp.member_id is not null;

      select * into v_team from public._advisor_table_team(r.org_id, v_members);

      if v_team.advisor = 'chef' then
        foreach m in array v_members loop
          perform public.grant_snack_tx(r.org_id, m, 'cookie', 1, 'chef', r.session_id,
                                        'chef:' || r.session_id::text || ':' || m::text);
        end loop;
      end if;
    exception when others then
      begin
        perform public.log_app_event_tx(null, null, 'advisor_error',
          jsonb_build_object('where', '_chef_perk_on_rank', 'session_id', r.session_id,
                             'code', sqlstate, 'message', left(sqlerrm, 300)),
          now(), null);
      exception when others then null;
      end;
    end;
  end loop;
  return null;
end $function$;

revoke execute on function public._chef_perk_on_rank() from public, anon, authenticated;

drop trigger if exists trg_session_players_chef_perk on public.session_players;
create trigger trg_session_players_chef_perk
  after update on public.session_players
  referencing old table as old_rows new table as new_rows
  for each statement execute function public._chef_perk_on_rank();

/* ── 驗證（單一 SELECT，不 raise）──────────────────────────── */
select
  case when pg_get_constraintdef((select oid from pg_constraint where conname = 'snack_grants_reason_check'
                                    and conrelid = 'public.snack_grants'::regclass)) like '%''chef''%'
       then '✅' else '🔴' end || ' ① 發放原因收 chef'
  || E'\n' ||
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = '_chef_perk_on_rank') = 1
       then '✅' else '🔴' end || ' ② _chef_perk_on_rank 一個版本'
  || E'\n' ||
  case when exists (select 1 from pg_trigger where tgname = 'trg_session_players_chef_perk'
                     and tgrelid = 'public.session_players'::regclass and tgenabled <> 'D')
       then '✅' else '🔴' end || ' ③ 觸發器掛在 session_players 上而且啟用'
  || E'\n' ||
  case when not has_function_privilege('anon', 'public._chef_perk_on_rank()', 'execute')
        and not has_function_privilege('authenticated', 'public._chef_perk_on_rank()', 'execute')
       then '✅' else '🔴' end || ' ④ 前端叫不到這支'
  || E'\n' ||
  case when exists (select 1 from pg_trigger where tgname = 'trg_session_players_settle_notify'
                     and tgrelid = 'public.session_players'::regclass)
       then '✅' else '🔴' end || ' ⑤ 結算通知的觸發器沒被動到（負對照）'
  || E'\n' ||
  case when pg_get_functiondef('public._chef_perk_on_rank()'::regprocedure) ~ '_advisor_table_team'
       then '✅' else '🔴' end || ' ⑥ 同團判斷用商人熊同一份 _advisor_table_team'
  as "驗證";
