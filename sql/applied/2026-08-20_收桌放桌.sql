-- 【待執行】收桌結算第一版：關場次 + 放桌
-- ============================================================
-- 🔴 這支不是新功能，是**目前開不了店的等級**。
--   有人結過帳坐上去之後，那張桌再也放不出來：
--     void_session_tx          有在座玩家就拒絕（has_players）
--     cleanup_empty_sessions_tx 只清沒人入座的
--     TablePage.jsx:109        「收桌結算」按鈕只 flash「尚未開放」
--   而 uq_sessions_open_table 鎖住 table_id。
--   → 開幕當天第一輪打完就沒桌可開。
--
-- 【文件錯了，實測才知道】
--   CLAUDE.md 待辦 3 寫「settle_session_tx 仍是空殼」。**不是。**
--   線上版本已經在做 status='completed' / ended_at / fee_points。
--   真正的問題是它 **SECURITY INVOKER** ——
--   POS 用 anon 沒有 auth session，RLS 會把那個 UPDATE 過濾成 0 列，
--   **而且不報錯**：函式照樣回 {session_id, total_points: 0}。
--   「跑了、回了、什麼都沒發生」正是硬規則 4 要防的那種 bug。
--   → 這也是為什麼不能靠檔案或文件判斷線上現況（硬規則 3）。
--
-- 【放桌不需要額外動作】
--   uq_sessions_open_table 是部分索引：
--     UNIQUE (table_id) WHERE status = 'open' AND deleted_at IS NULL
--   所以 status 一改成 completed，那張桌就退出索引、可以重新開桌。
--
-- 【第一版刻意不做的】
--   尾款、包桌超時補收、發票、消費累積 —— 都在第二版。
--   現在檯費是**入座時一次收清**，不做尾款也能營運；
--   但不做放桌就開不了店，所以先切這一刀。
--   已拍板的規則記在 CLAUDE.md，實作時照那個走：
--     · 包桌超時 → 收桌時補收到實際級距
--     · 發票     → 維持每筆結帳各一張，收桌不碰發票
--     · 消費累積 → 實付金額 payable
--
-- 【為什麼沒有「未結帳就不給收桌」的擋牆】
--   session_players 的每一列都是在 checkout 成功之後才建立的
--   （join_session_tx 走完 checkout_tx 才 insert），
--   所以系統裡**不存在「已入座但未付款」的狀態**。
--   持有暢打的人 order_id 是 null，但那是「不用付」不是「還沒付」。
--   拿 order_id is null 當未付款判準會把暢打的人擋在桌上下不來。
--
-- 【簽名改了，依硬規則 2 先 DROP】
--   舊：settle_session_tx(p_session_id uuid)  INVOKER
--   新：settle_session_tx(p_session_id uuid, p_staff_id uuid)  DEFINER
-- ============================================================

drop function if exists public.settle_session_tx(uuid);

create or replace function public.settle_session_tx(
  p_session_id uuid,
  p_staff_id   uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_s      record;
  v_total  bigint;
  v_left   int;
begin
  select * into v_s
    from table_sessions
   where id = p_session_id and deleted_at is null;

  if v_s.id is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found',
      'message', '場次不存在');
  end if;

  -- 冪等：重複按不該報錯，也不該再動一次 ended_at。
  -- 店員在網路慢的時候按兩下是常態，第二下應該是「已經收好了」。
  if v_s.status = 'completed' then
    return jsonb_build_object('ok', true, 'already_settled', true,
      'session_id', p_session_id, 'table_id', v_s.table_id,
      'ended_at', v_s.ended_at, 'total_points', v_s.fee_points);
  end if;

  if v_s.status <> 'open' then
    return jsonb_build_object('ok', false, 'reason', 'session_not_open',
      'message', '此場次已作廢，無法收桌', 'status', v_s.status);
  end if;

  -- 在座的人一律標記離座。left_at 是「這個人什麼時候離開這張桌」，
  -- 收桌就是所有人同時離開 —— 不寫的話桌況的在座人數會永遠停在那個數字。
  update session_players
     set left_at = now()
   where session_id = p_session_id
     and left_at is null;
  get diagnostics v_left = row_count;

  -- 本桌實扣點數合計。charged_points 在入座/加購當下就寫好了，
  -- 這裡只是彙總，不重新計價 —— 收桌不該是第二個計價的地方。
  select coalesce(sum(charged_points), 0) into v_total
    from session_players
   where session_id = p_session_id;

  update table_sessions
     set status     = 'completed',
         ended_at   = now(),
         fee_points = v_total,
         updated_at = now(),
         updated_by = coalesce(p_staff_id, updated_by)
   where id = p_session_id;

  return jsonb_build_object('ok', true,
    'session_id',    p_session_id,
    'table_id',      v_s.table_id,
    'players_left',  v_left,
    'total_points',  v_total,
    'ended_at',      now());
end $function$;

comment on function public.settle_session_tx(uuid, uuid) is
  '收桌：關閉場次並釋放桌位。status→completed 之後 uq_sessions_open_table（部分索引）自動放行，那張桌可重新開桌。在座玩家一律寫 left_at。冪等：已收桌回 already_settled。不重新計價 —— 檯費在入座時已收清；尾款、超時補收、發票、消費累積屬第二版。';

grant execute on function public.settle_session_tx(uuid, uuid) to anon, authenticated;

-- ============================================================
-- 驗證（單一 SELECT）
--   前四欄 true / 1 / 0。
--   第五欄是煙霧測試：不存在的場次要回 session_not_found，
--   代表函式真的跑得起來（CREATE FUNCTION 不檢查函式體，硬規則 7）。
--   最後一欄是現在卡住的桌 —— 那就是收桌功能上線後要處理的存量。
-- ============================================================
with fns as (
  select p.oid, p.prosecdef,
         pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'settle_session_tx' and p.prokind = 'f'
)
select
  (select count(*) from fns)                                              as 版本數,
  (select bool_and(prosecdef) from fns)                                   as 是DEFINER,
  (select count(*) from fns where args = 'p_session_id uuid')             as 舊單參數版殘留,
  (select bool_or(args = 'p_session_id uuid, p_staff_id uuid') from fns)  as 新簽名正確,
  (public.settle_session_tx('00000000-0000-0000-0000-000000000000'::uuid)
     ->> 'reason')                                                        as 煙霧測試,
  (select jsonb_agg(jsonb_build_object(
            'store', st.name, 'table', t.label,
            'opened', to_char(s.started_at at time zone 'Asia/Taipei', 'MM/DD HH24:MI'),
            'players', (select count(*) from session_players sp
                         where sp.session_id = s.id and sp.left_at is null))
            order by st.name, t.label)
     from table_sessions s
     join tables t  on t.id = s.table_id
     join stores st on st.id = s.store_id
    where s.status = 'open' and s.deleted_at is null)                     as 目前開著的桌;
