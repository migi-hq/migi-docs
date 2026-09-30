/* ============================================================
   智慧計分板：爆卡與追加積分
   2026-09-30 · MIGI 咪吉麻將
   規則：docs/02-POS與開桌/桌邊記分板設計.md §3.7（使用者 09-30 拍板）

   · 一局要扣的比他剩的多 ⇒ 只扣到 0，胡的人只拿到實付的合計（整桌仍是零和）
   · 剩 0 ＝ 爆卡 ⇒ 爆卡的人自己決定：追加（自己選金額、不限次數）或不追加（整場結束、結算成績）
   · 純娛樂也會爆卡；但「爆卡」「讓對手爆卡」兩枚成就純娛樂不送（同其他積分類）
   · 成績 ＝ 最後剩的 − 起始 − 追加 ＝ 每一局得失的總和 ⇒ 現行成績算法不用改

   ── 做法 ─────────────────────────────────────────────
   ① session_busts：一列＝一次爆卡（哪一場、哪個座位、哪一局、誰胡的、決定）
   ② _tbl_balances(場次)：每個座位現在剩多少 ＝ 起始 ＋ 追加 ＋ 已生效的得失
   ③ hands 寫入前（trg_hands_bust_clamp）：有人在等決定就不准送；金額夾到付的人剩的那麼多
      —— 掛在表上而不是改送出函式：送出有咔啦碰／包牌／胡自摸三條寫入路徑，改函式一定會漏一條
   ④ hands 生效時（trg_hands_bust_detect）：誰歸零就記一列 pending；那一局被撤銷就作廢
   ⑤ tbl_bust_decide_tx(平板憑證, 金額)：> 0 追加；0 不追加 ⇒ 這一將標成打完並結算成績
   ⑥ tbl_state_tx 多回 extras／bust／session.ended_reason／session.bust_seat（插一段，其餘不動）
   ⑦ 成就：爆卡、讓對手爆卡接上發射端並上架

   ⚠ 已知限制：起始積分讀的是級距「現在」的值 —— 牌局進行中在後台改起始積分，這一桌每個人會一起變。
     後台那一頁要寫明「改了立刻影響正在打的桌」。
   ⚠ tbl_submit_hand_tx 回給送出那一台的 proposed_delta 是夾之前的數字；平板只看 ok、之後重讀狀態，
     畫面與入帳都是夾過的那一份。

   行為測試：sql/checks/2026-09-30_驗爆卡與追加積分.sql（交易內造平板、全部回滾）
   ============================================================ */

-- ① 爆卡紀錄
create table if not exists public.session_busts (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.orgs(id),
  session_id   uuid not null references public.table_sessions(id),
  seat         smallint not null check (seat between 1 and 4),
  hand_id      uuid references public.hands(id),
  by_seat      smallint check (by_seat between 1 and 4),
  decision     text not null default 'pending' check (decision in ('pending', 'added', 'ended', 'voided')),
  added_points integer,
  created_at   timestamptz not null default now(),
  decided_at   timestamptz,
  constraint session_busts_added_ck check ((decision = 'added') = (added_points is not null)
                                           and (added_points is null or added_points > 0))
);
create index if not exists idx_session_busts_session on public.session_busts(session_id);
create unique index if not exists uq_session_busts_pending on public.session_busts(session_id, seat) where decision = 'pending';
alter table public.session_busts enable row level security;   -- 0 policy：只有 DEFINER 函式進得去
revoke all on table public.session_busts from anon, authenticated;
comment on table public.session_busts is
  '智慧計分板的爆卡紀錄：一列＝某座位某一局之後積分歸零。decision：pending 等本人決定／added 追加（added_points）／ended 不追加、整場結束／voided 那一局被撤銷。by_seat＝胡的人（放槍或自摸造成的才有）。';

-- ② 每個座位現在剩多少
create or replace function public._tbl_balances(p_session_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_object_agg(g.s::text, coalesce(st.sp, 0) + coalesce(x.extra, 0) + coalesce(y.tot, 0))
    from generate_series(1, 4) as g(s)
    cross join (select sl.start_points as sp
                  from public.table_sessions ts
                  left join public.stake_levels sl on sl.id = ts.stake_level_id
                 where ts.id = p_session_id) st
    left join (select b.seat, sum(b.added_points) as extra
                 from public.session_busts b
                where b.session_id = p_session_id and b.decision = 'added'
                group by b.seat) x on x.seat = g.s
    left join (select e.key::int as seat, sum(e.value::int) as tot
                 from public.hands h, jsonb_each_text(h.score_delta) e
                where h.session_id = p_session_id and h.status = 'confirmed'
                group by e.key::int) y on y.seat = g.s
$$;
revoke execute on function public._tbl_balances(uuid) from public, anon, authenticated;

-- ③ 寫入一局之前：爆卡中不准送；金額夾到付的人剩的那麼多
create or replace function public.trg_hands_bust_clamp()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_bal jsonb; v_d jsonb; v_payers smallint[]; v_recvs smallint[];
  i smallint; j int; v_owe int; v_have int; v_pay int; v_got int; v_left int;
begin
  if exists (select 1 from public.session_busts b where b.session_id = new.session_id and b.decision = 'pending')
     and not public._session_scored(new.session_id) then
    raise exception '有人積分歸零，等待決定是否追加積分' using errcode = 'P0001';
  end if;
  if new.proposed_delta is null then return new; end if;

  v_bal := public._tbl_balances(new.session_id);
  v_d := new.proposed_delta;
  select coalesce(array_agg(k::smallint order by k) filter (where v < 0), '{}'),
         coalesce(array_agg(k::smallint order by k) filter (where v > 0), '{}')
    into v_payers, v_recvs
    from (select e.key as k, e.value::int as v from jsonb_each_text(v_d) e) z;

  if coalesce(array_length(v_recvs, 1), 0) = 1 then
    -- 一個收款人（胡／自摸／咔啦碰）：每個付的人最多付自己剩的，收的人拿實付合計
    v_got := 0;
    foreach i in array v_payers loop
      v_owe  := -((v_d ->> i::text)::int);
      v_have := greatest(0, coalesce((v_bal ->> i::text)::int, 0));
      v_pay  := least(v_owe, v_have);
      v_d := jsonb_set(v_d, array[i::text], to_jsonb(-v_pay));
      v_got := v_got + v_pay;
    end loop;
    v_d := jsonb_set(v_d, array[v_recvs[1]::text], to_jsonb(v_got));
  elsif coalesce(array_length(v_payers, 1), 0) = 1 and coalesce(array_length(v_recvs, 1), 0) > 1 then
    -- 包牌：一個人付三家；付不夠就照比例分，最後一家拿餘數（總和不差 1 分）
    i := v_payers[1];
    v_owe  := -((v_d ->> i::text)::int);
    v_have := greatest(0, coalesce((v_bal ->> i::text)::int, 0));
    if v_have < v_owe then
      v_left := v_have;
      for j in 1 .. array_length(v_recvs, 1) loop
        if j = array_length(v_recvs, 1) then
          v_pay := v_left;
        else
          v_pay := floor((v_d ->> v_recvs[j]::text)::numeric * v_have / v_owe)::int;
        end if;
        v_d := jsonb_set(v_d, array[v_recvs[j]::text], to_jsonb(v_pay));
        v_left := v_left - v_pay;
      end loop;
      v_d := jsonb_set(v_d, array[i::text], to_jsonb(-v_have));
    end if;
  end if;

  new.proposed_delta := v_d;
  if new.status = 'confirmed' then new.score_delta := v_d; end if;
  return new;
end $fn$;
revoke execute on function public.trg_hands_bust_clamp() from public, anon, authenticated;

drop trigger if exists trg_hands_bust_clamp on public.hands;
create trigger trg_hands_bust_clamp
  before insert on public.hands
  for each row execute function public.trg_hands_bust_clamp();

-- ④ 一局生效時：誰歸零就等他決定；那一局被撤銷就作廢
create or replace function public.trg_hands_bust_detect()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_bal jsonb; g int;
begin
  if new.status = 'confirmed' and old.status is distinct from 'confirmed' then
    v_bal := public._tbl_balances(new.session_id);
    for g in 1 .. 4 loop
      if coalesce((v_bal ->> g::text)::int, 1) <= 0
         and not exists (select 1 from public.session_busts b
                          where b.session_id = new.session_id and b.seat = g and b.decision = 'pending') then
        insert into public.session_busts (org_id, session_id, seat, hand_id, by_seat)
        values (new.org_id, new.session_id, g, new.id,
                case when new.result in ('ron', 'tsumo') and new.winner_seat is distinct from g then new.winner_seat end);
      end if;
    end loop;
  elsif old.status = 'confirmed' and new.status is distinct from 'confirmed' then
    update public.session_busts set decision = 'voided', decided_at = now()
     where hand_id = new.id and decision = 'pending';
  end if;
  return null;
end $fn$;
revoke execute on function public.trg_hands_bust_detect() from public, anon, authenticated;

drop trigger if exists trg_hands_bust_detect on public.hands;
create trigger trg_hands_bust_detect
  after update of status on public.hands
  for each row execute function public.trg_hands_bust_detect();

-- ⑤ 爆卡的人決定
create or replace function public.tbl_bust_decide_tx(p_token text, p_amount integer)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  d public.table_devices; s public.table_sessions; v_me smallint; b public.session_busts;
begin
  d := public._tbl_device(p_token);
  select * into s from public.table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  select seat into v_me from public.session_players
   where session_id = s.id and device_id = d.id and left_at is null;
  if public._session_scored(s.id) then
    return jsonb_build_object('ok', false, 'reason', 'scored', 'message', '這場的成績已經結算');
  end if;

  select * into b from public.session_busts
   where session_id = s.id and decision = 'pending'
   order by seat limit 1 for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_bust', 'message', '現在沒有人爆卡');
  end if;
  if v_me is null or b.seat <> v_me then
    return jsonb_build_object('ok', false, 'reason', 'not_yours', 'message', '只有爆卡的人可以決定');
  end if;

  if coalesce(p_amount, 0) > 0 then
    if p_amount > 9999999 then
      return jsonb_build_object('ok', false, 'reason', 'bad_amount', 'message', '追加的積分太多了');
    end if;
    update public.session_busts
       set decision = 'added', added_points = p_amount, decided_at = now()
     where id = b.id;
    perform public._tbl_ping(s.id);
    return jsonb_build_object('ok', true, 'added', p_amount);
  end if;

  -- 不追加 ⇒ 整場結束
  update public.session_busts set decision = 'ended', decided_at = now() where id = b.id;
  update public.session_busts set decision = 'voided', decided_at = now()   -- 同一局一起歸零的其他人不用再決定
   where session_id = s.id and decision = 'pending';
  update public.session_rounds set status = 'finished', finished_at = now()
   where session_id = s.id and status = 'playing';
  -- 結算成績：規則同「打完自動結算」（約定 2 將以上才算；已經算過就不算）
  if coalesce(s.planned_rounds, 0) >= 2 and not public._session_scored(s.id) then
    begin
      perform public._score_settle_tx(s.id);
    exception when others then null;   -- 不可以讓結算失敗把「結束」一起回滾；收桌會補算
    end;
  end if;
  perform public._tbl_ping(s.id);
  return jsonb_build_object('ok', true, 'ended', true);
end $fn$;
revoke execute on function public.tbl_bust_decide_tx(text, integer) from public;
grant  execute on function public.tbl_bust_decide_tx(text, integer) to anon, authenticated;   -- 平板用 anon 金鑰 ＋ 平板憑證（同其他 tbl_ 函式）

-- ⑥ 讀狀態：多回追加、在等誰、爆卡結束（用線上全文插兩段，其餘不動）
do $$
declare
  v_def text := pg_get_functiondef('public.tbl_state_tx(text)'::regprocedure);
  a1 text := $a$'supported', coalesce(s.game_type, '台麻') = '台麻')$a$;
  a2 text := $a$'rating_delta', (select$a$;
  v_n1 int; v_n2 int;
begin
  if v_def ~ 'ended_reason' then return; end if;
  v_n1 := (length(v_def) - length(replace(v_def, a1, ''))) / length(a1);
  v_n2 := (length(v_def) - length(replace(v_def, a2, ''))) / length(a2);
  if v_n1 <> 1 or v_n2 <> 1 then
    raise exception '讀狀態的插入點應該各 1 處，實際 % 與 % 處 —— 線上版本跟預期不同，整份停下', v_n1, v_n2;
  end if;
  v_def := replace(v_def, a1, $b$'supported', coalesce(s.game_type, '台麻') = '台麻',
      /* 💥 爆卡不追加 ⇒ 整場提前結束（2026-09-30） */
      'ended_reason', case when exists (select 1 from public.session_busts b
                                         where b.session_id = s.id and b.decision = 'ended') then 'bust' end,
      'bust_seat', (select b.seat from public.session_busts b
                     where b.session_id = s.id and b.decision = 'ended' order by b.decided_at limit 1))$b$);
  v_def := replace(v_def, a2, $b$/* 💥 追加（座位 → 總額）與「現在在等誰決定」；成績算完就不再等（2026-09-30） */
    'extras', (select coalesce(jsonb_object_agg(x.seat::text, x.tot), '{}'::jsonb)
                 from (select b.seat, sum(b.added_points) as tot from public.session_busts b
                        where b.session_id = s.id and b.decision = 'added' group by b.seat) x),
    'bust', case when public._session_scored(s.id) then null else
              (select jsonb_build_object('seat', b.seat, 'hand_id', b.hand_id)
                 from public.session_busts b
                where b.session_id = s.id and b.decision = 'pending' order by b.seat limit 1) end,
    'rating_delta', (select$b$);
  execute v_def;
end $$;

-- ⑦ 成就：爆卡、讓對手爆卡（純娛樂不送 —— final_score 是 null）
do $$
declare
  v_def text := pg_get_functiondef('public._ach_session_events(uuid)'::regprocedure);
  v_anchor text := '/* ── 單場段位分變動';
  v_n int;
begin
  if v_def ~ '''bust_other''' then return; end if;
  v_n := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_n <> 1 then
    raise exception '成就判定的插入點應該剛好 1 處，實際 % 處', v_n;
  end if;
  execute replace(v_def, v_anchor, $ins$/* ── 爆卡（純娛樂不算，同其他積分類；撤銷掉的那一局不算）── */
    if v_p.final_score is not null and v_p.seat is not null then
      if exists (select 1 from public.session_busts b
                  where b.session_id = p_session_id and b.seat = v_p.seat and b.decision <> 'voided') then
        v_ev := array_append(v_ev, 'bust');
      end if;
      if exists (select 1 from public.session_busts b
                  where b.session_id = p_session_id and b.by_seat = v_p.seat and b.decision <> 'voided') then
        v_ev := array_append(v_ev, 'bust_other');
      end if;
    end if;

    $ins$ || v_anchor);
end $$;
update public.achievements set is_active = true, updated_at = now()
 where code in ('game_25', 'game_26') and deleted_at is null and not is_active;

/* ============================================================
   驗證（不 raise —— 這份要留下東西）
   ============================================================ */
do $$
declare
  v_msg text := ''; v_n int; v_m int; v_txt text; v_fn text; v_oid oid;
  v_anon boolean; v_pub boolean; v_auth boolean;
begin
  -- ① 表：RLS 開、0 policy、前端沒有任何表權限
  select count(*) into v_n from pg_policies where schemaname = 'public' and tablename = 'session_busts';
  select count(*) into v_m from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'session_busts' and grantee in ('anon', 'authenticated');
  v_msg := v_msg || case when (select relrowsecurity from pg_class where oid = 'public.session_busts'::regclass) and v_n = 0 and v_m = 0
                         then '✅' else '🔴' end
        || ' ① session_busts：RLS 開、policy ' || v_n || ' 條、前端表權限 ' || v_m || ' 項（期望 0／0）' || E'\n';

  -- ② 兩個觸發器
  select string_agg(tgname, ',' order by tgname) into v_txt from pg_trigger
   where tgrelid = 'public.hands'::regclass and tgname in ('trg_hands_bust_clamp', 'trg_hands_bust_detect');
  v_msg := v_msg || case when v_txt = 'trg_hands_bust_clamp,trg_hands_bust_detect' then '✅' else '🔴' end
        || ' ② hands 觸發器 ' || coalesce(v_txt, '∅') || E'\n';

  -- ③ 平板叫得動決定函式（anon ＋ authenticated），PUBLIC 沒有
  v_oid := 'public.tbl_bust_decide_tx(text,integer)'::regprocedure;
  select exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = v_oid and a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE') into v_anon;
  select (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')) into v_pub from pg_proc p where p.oid = v_oid;
  select has_function_privilege('authenticated', v_oid, 'execute') into v_auth;
  v_msg := v_msg || case when v_anon and v_auth and not v_pub then '✅' else '🔴' end
        || ' ③ tbl_bust_decide_tx  anon ' || case when v_anon then '有' else '無' end
        || ' · authenticated ' || case when v_auth then '有' else '無' end
        || ' · PUBLIC ' || case when v_pub then '有' else '無' end || '（期望 有／有／無）' || E'\n';

  -- ④ 內部函式前端叫不到
  select count(*) into v_n from unnest(array['public._tbl_balances(uuid)', 'public.trg_hands_bust_clamp()', 'public.trg_hands_bust_detect()']) f
   where has_function_privilege('anon', f::regprocedure, 'execute') or has_function_privilege('authenticated', f::regprocedure, 'execute');
  v_msg := v_msg || case when v_n = 0 then '✅' else '🔴' end || ' ④ 內部函式前端叫不到（' || v_n || ' 支叫得到，期望 0）' || E'\n';

  -- ⑤ 讀狀態插進去了，而且平板仍叫得動（CREATE OR REPLACE 不掉授權）
  v_txt := pg_get_functiondef('public.tbl_state_tx(text)'::regprocedure);
  v_msg := v_msg || case when v_txt ~ '''ended_reason''' and v_txt ~ '''extras''' and v_txt ~ '''bust'', case'
                              and has_function_privilege('anon', 'public.tbl_state_tx(text)'::regprocedure, 'execute')
                         then '✅' else '🔴' end || ' ⑤ tbl_state_tx 回 extras／bust／ended_reason，anon 仍叫得動' || E'\n';

  -- ⑥ 成就判定接上、兩枚上架
  v_txt := pg_get_functiondef('public._ach_session_events(uuid)'::regprocedure);
  select count(*) into v_n from public.achievements where code in ('game_25', 'game_26') and is_active and deleted_at is null;
  v_msg := v_msg || case when v_txt ~ '''bust''\)' and v_txt ~ '''bust_other''' and v_n = 2 then '✅' else '🔴' end
        || ' ⑥ 爆卡成就：判定已接、上架 ' || v_n || ' 枚（期望 2）' || E'\n';

  -- ⑦ 目前線上沒有任何一列（新表，而且所有牌局都還沒爆過）
  select count(*) into v_n from public.session_busts;
  v_msg := v_msg || case when v_n = 0 then '✅' else '🔴' end || ' ⑦ session_busts 現有 ' || v_n || ' 列（期望 0）';

  perform set_config('migi.v', v_msg, true);
end $$;
select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有驗證訊息') as "驗證";
