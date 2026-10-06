/* ============================================================
   LINE 推播：牌局結束卡片（2026-10-07）
   🔴 一定要排在 2026-10-05_LINE推播_加卡片版.sql 之後跑（這份會先檢查，沒跑就整份不動）

   ── 使用者拍板的規則（2026-10-06）────────────────────────
   · 約定的將數打完、成績算好那一刻就送（不等店員收桌）
   · 沒打完約定將數就收桌的，收桌補算成績時也送；「玩法」那一列寫實際打完幾將
   · 1 將都沒打完 ＝ 成績不算 ⇒ 不送
   · 卡片只講收到的人自己的成績：名次（最大）、桌上積分、段位分、目前段位、門市與桌號、玩法、同桌
   · 不寫升段與解鎖成就；最後一句「想回顧這場？App 有每一局的紀錄。」；按鈕「查看成績」開 App 成績頁
   📄 預覽：https://claude.ai/artifact/AJZ6MggxTuhp48hBak7qSg

   ── 改了什麼 ─────────────────────────────────────────
   ① 唯一索引 uq_app_notifications_settle_once：同一場、同一人，「牌局結算完成」通知只能有一則
   ② 觸發器 trg_session_players_settle_notify：名次從「沒有」變成「有」的那一刻，替整桌每一位建那則通知
      ⇒ 自動結算（最後一將打完）與收桌補算都會走到這一刻，不用改那兩支結算函式
      ⇒ settle_session_tx 收桌時原本那段 insert 撞到 ① 會被它自己的例外處理接住、整段略過 ——
        所以 App 裡那則通知**改成在成績算好時就出現**，不再等收桌，也不會出現兩則
      ⚠ 沒有名次的場次（一將都沒打完）不會觸發這裡，收桌時照舊由 settle_session_tx 建通知（App 裡照舊看得到），
        但推播在組卡片時發現沒有名次就略過（reason = no_result）
   ③ _push_enqueue：要推的通知多一種 settle
   ④ _push_signed／_push_settle_fields／_push_settle_text／_push_settle_flex：牌局結束卡片的內容
      🎯 段位分讀 session_players.score_points —— 平板「牌局結束」卡讀的就是這一欄
        （_tbl_state_for_device 的 rating_delta），兩邊數字才會一樣。
        ⚠ 那一欄名字叫 score 但裝的是段位分（CLAUDE.md 記過）；這裡就是拿它當段位分用，意思沒有借錯。
   ⑤ _push_messages：依通知種類分流（配桌湊滿照舊、牌局結束用新卡片）
   ⑥ push_claim_tx：「過期不送」分種類判斷 —— 配桌湊滿看房間狀態與開打時間；牌局結束只看是不是塞超過 6 小時

   ⚠ CREATE OR REPLACE、簽名不變的都不丟授權；新函式照 2026-09-29 的預設全關，只有 postgres／service_role 碰得到。
   ⚠ 驗證段只有一支 SELECT，不用 raise（硬規則 1.8）。跑完我會另外查一次線上。
   ============================================================ */

-- ⓪ 前置檢查：卡片版那份沒跑的話，這份整個不動（故意 raise ⇒ 什麼都不會留下）
do $$
begin
  if to_regprocedure('public._push_flex(uuid)') is null
     or to_regprocedure('public._push_messages(uuid)') is null then
    raise exception '請先跑 2026-10-05_LINE推播_加卡片版.sql，再跑這一份';
  end if;
end $$;

-- ① 同一場同一人只有一則「牌局結算完成」
create unique index if not exists uq_app_notifications_settle_once
  on public.app_notifications (member_id, ref_id) where type = 'settle';

-- ② 名次一寫進去就建通知
create or replace function public._settle_notify_on_rank()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    insert into app_notifications (org_id, member_id, type, payload, ref_id)
    select ts.org_id, sp.member_id, 'settle',
           jsonb_build_object(
             'text',       '牌局結算完成',
             'session_id', ts.id,
             'store',      st.name,
             'stake',      sl.label,
             'at',         coalesce(ts.activated_at, ts.started_at)),   -- payload 跟 settle_session_tx 那段逐欄相同
           ts.id
      from (select distinct n.session_id
              from new_rows n join old_rows o on o.id = n.id
             where o.finish_rank is null and n.finish_rank is not null) x
      join table_sessions ts on ts.id = x.session_id
      join session_players sp on sp.session_id = ts.id and sp.org_id = ts.org_id and sp.member_id is not null
      left join stores       st on st.id = ts.store_id       and st.org_id = ts.org_id
      left join stake_levels sl on sl.id = ts.stake_level_id and sl.org_id = ts.org_id
    on conflict (member_id, ref_id) where type = 'settle' do nothing;
  exception when others then
    /* 通知失敗不可以讓成績回滾；但不安靜吞掉，留一筆錯誤給錯誤儀表 */
    begin
      perform public.log_app_event_tx(null, null, 'push_error',
        jsonb_build_object('where', '_settle_notify_on_rank', 'code', sqlstate, 'message', left(sqlerrm, 300)),
        now(), null);
    exception when others then null;
    end;
  end;
  return null;
end $$;
revoke execute on function public._settle_notify_on_rank() from public, anon, authenticated;

drop trigger if exists trg_session_players_settle_notify on public.session_players;
create trigger trg_session_players_settle_notify
  after update on public.session_players
  referencing old table as old_rows new table as new_rows
  for each statement execute function public._settle_notify_on_rank();

-- ③ 要推的通知種類
create or replace function public._push_enqueue()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_n int;
begin
  insert into notification_deliveries (org_id, notification_id, channel)
  select nr.org_id, nr.id, 'line'
    from new_rows nr
   where nr.type in ('table_ok', 'settle')   -- 🔴 白名單：要推哪一種通知就加在這裡（每一種都吃免費則數）
  on conflict (notification_id, channel) do nothing;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    perform _push_kick();
  end if;
  return null;
end $$;

-- ④ 牌局結束卡片的內容
-- 帶正負號的數字：+180、−120（用數學的減號，比連字號好讀）、0
create or replace function public._push_signed(p int)
returns text
language sql
immutable
as $$
  select case when p > 0 then '+' || p when p < 0 then '−' || abs(p) else '0' end
$$;
revoke execute on function public._push_signed(int) from public, anon, authenticated;

-- 唯一一份「這張卡片要講什麼」（文字版與卡片版共用，理由同 _push_fields）
create or replace function public._push_settle_fields(p_notif uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  n app_notifications%rowtype;
  v_sid uuid;
  sp record;
  s record;
  v_done int;
  v_others text;
  v_game text;
begin
  select * into n from app_notifications where id = p_notif;
  if n.id is null or n.type <> 'settle' then return null; end if;
  v_sid := coalesce((n.payload ->> 'session_id')::uuid, n.ref_id);

  select p.finish_rank, p.final_score, p.score_points into sp
    from session_players p
   where p.session_id = v_sid and p.member_id = n.member_id;
  if sp.finish_rank is null then return null; end if;   -- 沒有名次（一將都沒打完）⇒ 不送

  select ts.game_type, ts.flower, ts.planned_rounds,
         st.name as store, t.label as tbl,
         sl.label as stake, coalesce(sl.is_hygiene, false) as hyg,
         m.display_name as my_name, m.rank as my_rank
    into s
    from table_sessions ts
    left join stores       st on st.id = ts.store_id
    left join tables       t  on t.id  = ts.table_id
    left join stake_levels sl on sl.id = ts.stake_level_id
    left join members      m  on m.id  = n.member_id
   where ts.id = v_sid;

  select count(*) into v_done
    from session_rounds where session_id = v_sid and status = 'finished';

  -- 隱藏的會員名字已經是「隱藏的會員」（隱藏時就換掉了），這裡不用另外判斷
  select string_agg(m.display_name, '、' order by p.seat nulls last) into v_others
    from session_players p join members m on m.id = p.member_id
   where p.session_id = v_sid and p.member_id <> n.member_id;

  -- 玩法：打滿約定將數寫「3 將」；提早收桌寫「3 將（打完 2 將）」；計分桌補上級距，純娛樂不寫（桌上積分那一列已經寫了）
  v_game := concat_ws(' · ', s.game_type, s.flower,
              case when s.planned_rounds is null or v_done >= s.planned_rounds then v_done || ' 將'
                   else s.planned_rounds || ' 將（打完 ' || v_done || ' 將）' end,
              case when not s.hyg and s.stake is not null then '積分 ' || s.stake end);

  return jsonb_build_object(
    'test',    n.payload ->> 'test' = 'true',
    'style',   n.payload ->> 'style',
    'name',    s.my_name,
    'rank_no', sp.finish_rank,
    -- 桌上積分：純娛樂寫「純娛樂」（那一欄是 null 不是 0）
    'score',   case when s.hyg then '純娛樂'
                    when sp.final_score is not null then _push_signed(sp.final_score) end,
    -- 段位分：未滿 2 將不計（2026-10-01 拍板，只打 1 將「有名次沒段位分」）
    'rating',  case when v_done < 2 then '未滿 2 將，不計段位分'
                    when sp.score_points is not null then _push_signed(sp.score_points) end,
    'rating_short', case when v_done >= 2 and sp.score_points is not null then _push_signed(sp.score_points) end,
    'tier',    s.my_rank,
    'place',   coalesce(s.store, 'MIGI') || coalesce(' · ' || s.tbl || ' 桌', ''),
    'game',    nullif(v_game, ''),
    'others',  v_others,
    'url',     'https://liff.line.me/2011312117-Zuul0Ndo?tab=stats');   -- ?tab=stats：App 打開直接到成績頁（migi-web lib/deeplink.js）
end $$;
revoke execute on function public._push_settle_fields(uuid) from public, anon, authenticated;

-- 文字版（卡片版之外的退路，也給舊版推播程式用）
create or replace function public._push_settle_text(p_notif uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare f jsonb := _push_settle_fields(p_notif);
begin
  if f is null then return null; end if;
  return concat_ws(E'\n',
    case when (f ->> 'test')::boolean then '【推播測試】' end,
    coalesce((f ->> 'name') || '，', '') || '牌局結束，辛苦了！',
    '名次：第 ' || (f ->> 'rank_no') || ' 名',
    case when f ->> 'score'  is not null then '桌上積分：' || (f ->> 'score') end,
    case when f ->> 'rating' is not null then '段位分：' || (f ->> 'rating') end,
    case when f ->> 'tier'   is not null then '目前段位：' || (f ->> 'tier') end,
    '門市：' || (f ->> 'place'),
    case when f ->> 'game'   is not null then '玩法：' || (f ->> 'game') end,
    case when f ->> 'others' is not null then '同桌：' || (f ->> 'others') end,
    '想回顧這場？App 有每一局的紀錄。',
    '查看成績：' || (f ->> 'url'));
end $$;
revoke execute on function public._push_settle_text(uuid) from public, anon, authenticated;

-- 卡片版：樣式照配桌湊滿那張（標題列 #FAD6DC、按鈕 #2E2B2C 白字、灰字 #8B8582）
create or replace function public._push_settle_flex(p_notif uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  f jsonb := _push_settle_fields(p_notif);
  v_rows jsonb;
  v_alt text;
begin
  if f is null then return null; end if;

  -- 細項：一列「項目 → 內容」，沒有值的那一列整列不畫；桌上積分與段位分的數字用粗體
  select jsonb_agg(jsonb_build_object('type', 'box', 'layout', 'baseline', 'spacing', 'md', 'contents', jsonb_build_array(
           jsonb_build_object('type', 'text', 'text', k, 'size', 'sm', 'color', '#8B8582', 'flex', 3),
           jsonb_build_object('type', 'text', 'text', v, 'size', 'sm', 'color', '#2E2B2C', 'wrap', true, 'flex', 7,
                              'weight', case when bold then 'bold' else 'regular' end)))
         order by o)
    into v_rows
    from (values (1, '桌上積分', f ->> 'score',  (f ->> 'score')  ~ '^[+−0-9]'),
                 (2, '段位分',   f ->> 'rating', (f ->> 'rating') ~ '^[+−0-9]'),
                 (3, '目前段位', f ->> 'tier',   false),
                 (4, '門市',     f ->> 'place',  false),
                 (5, '玩法',     f ->> 'game',   false),
                 (6, '同桌',     f ->> 'others', false)) t(o, k, v, bold)
   where v is not null;

  -- 手機通知與聊天列表只看得到這一句（卡片本身不會出現在那裡）
  v_alt := case when (f ->> 'test')::boolean then '【推播測試】' else '' end
        || coalesce((f ->> 'name') || '，', '') || '牌局結束！第 ' || (f ->> 'rank_no') || ' 名'
        || coalesce(' · 段位分 ' || (f ->> 'rating_short'), '');

  return jsonb_build_object(
    'type', 'flex',
    'altText', left(v_alt, 400),
    'contents', jsonb_build_object(
      'type', 'bubble',
      'header', jsonb_build_object(
        'type', 'box', 'layout', 'vertical', 'backgroundColor', '#FAD6DC', 'paddingAll', '14px',
        'contents', jsonb_build_array(
          jsonb_build_object('type', 'text', 'text', 'MIGI 咪吉麻將', 'size', 'lg', 'weight', 'bold',
                             'color', '#2E2B2C', 'align', 'center'))
          || case when (f ->> 'test')::boolean
                  then jsonb_build_array(jsonb_build_object('type', 'text', 'text', '推播測試', 'size', 'xxs',
                                                            'color', '#2E2B2C', 'align', 'center'))
                  else '[]'::jsonb end),
      'body', jsonb_build_object('type', 'box', 'layout', 'vertical', 'paddingAll', '18px',
        'contents', jsonb_build_array(
          jsonb_build_object('type', 'text', 'text', coalesce((f ->> 'name') || '，', '') || '牌局結束，辛苦了！',
                             'size', 'sm', 'color', '#2E2B2C', 'wrap', true),
          jsonb_build_object('type', 'text', 'text', '本場名次', 'size', 'xs', 'color', '#8B8582', 'margin', 'lg'),
          jsonb_build_object('type', 'text', 'text', '第 ' || (f ->> 'rank_no') || ' 名', 'size', 'xxl', 'weight', 'bold',
                             'color', '#2E2B2C', 'margin', 'xs'),
          jsonb_build_object('type', 'separator', 'margin', 'lg', 'color', '#DED9D5'),
          jsonb_build_object('type', 'box', 'layout', 'vertical', 'spacing', 'sm', 'margin', 'lg',
                             'contents', coalesce(v_rows, '[]'::jsonb)),
          jsonb_build_object('type', 'separator', 'margin', 'lg', 'color', '#DED9D5'),
          jsonb_build_object('type', 'text', 'text', '想回顧這場？App 有每一局的紀錄。',
                             'size', 'xs', 'color', '#8B8582', 'wrap', true, 'margin', 'lg'))),
      'footer', jsonb_build_object('type', 'box', 'layout', 'vertical', 'paddingAll', '12px',
        'contents', jsonb_build_array(
          jsonb_build_object('type', 'button', 'style', 'primary', 'color', '#2E2B2C', 'height', 'sm',
            'action', jsonb_build_object('type', 'uri', 'label', '查看成績', 'uri', f ->> 'url'))))));
end $$;
revoke execute on function public._push_settle_flex(uuid) from public, anon, authenticated;

-- ⑤ 這一則送哪幾個框：依通知種類分流
create or replace function public._push_messages(p_notif uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_default text := 'card';          -- 🔴 2026-10-05 使用者選卡片版。要換就改這裡：'text'／'card'／'both'
  v_type text;
  v_style text;
  v_text text; v_flex jsonb;
begin
  select type, coalesce(nullif(payload ->> 'style', ''), v_default)
    into v_type, v_style
    from app_notifications where id = p_notif;

  if v_type = 'settle' then
    v_text := _push_settle_text(p_notif);
    if v_text is null then return null; end if;
    v_flex := _push_settle_flex(p_notif);
  else
    v_text := _push_text(p_notif);
    if v_text is null then return null; end if;
    v_flex := _push_flex(p_notif);
  end if;

  return case v_style
    when 'card' then jsonb_build_array(v_flex)
    when 'both' then jsonb_build_array(jsonb_build_object('type', 'text', 'text', v_text), v_flex)
    else jsonb_build_array(jsonb_build_object('type', 'text', 'text', v_text))
  end;
end $$;
revoke execute on function public._push_messages(uuid) from public, anon, authenticated;

-- ⑥ 取件：「過期不送」分種類判斷（其餘跟卡片版那份相同）
create or replace function public.push_claim_tx(p_key text, p_limit int default 20)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_out jsonb := '[]'::jsonb;
  r record;
  v_to text; v_gone boolean; v_qstatus text; v_qplay timestamptz; v_msgs jsonb; v_skip text;
begin
  if p_key is null or not exists (select 1 from vault.decrypted_secrets
                                   where name = 'push_worker_key' and decrypted_secret = p_key) then
    return '[]'::jsonb;
  end if;

  -- 卡在 sending 超過 5 分鐘（Edge Function 中途掛掉）→ 退回 pending。同一把 retry_key，LINE 不會重複送
  update notification_deliveries
     set status = 'pending', claimed_at = null, updated_at = now()
   where status = 'sending' and claimed_at < now() - interval '5 minutes';

  for r in
    select d.id, d.retry_key, n.id as nid, n.type, n.member_id, n.created_at as n_at, n.payload, n.ref_id
      from notification_deliveries d
      join app_notifications n on n.id = d.notification_id
     where d.status = 'pending' and d.next_try_at <= now()
     order by d.created_at
     limit greatest(1, least(coalesce(p_limit, 20), 50))
       for update of d skip locked
  loop
    v_skip := null;
    select m.line_user_id, (m.deleted_at is not null or m.hidden_at is not null)
      into v_to, v_gone
      from members m where m.id = r.member_id;

    v_qstatus := null; v_qplay := null;
    if r.type = 'table_ok' then
      select mq.status, mq.play_at into v_qstatus, v_qplay
        from match_queues mq where mq.id = coalesce((r.payload ->> 'queue_id')::uuid, r.ref_id);
    end if;

    if v_gone then
      v_skip := 'member_gone';
    elsif v_to is null then
      v_skip := 'no_line';
    elsif v_to !~ '^U[0-9a-f]{32}$' then
      v_skip := 'bad_line_id';                -- 測試帳號的假 id（TEST…）
    elsif coalesce(r.payload ->> 'test', '') <> 'true' and (
            r.n_at < now() - interval '6 hours'          -- 塞太久 —— 不要半夜補送昨天的事
            or (r.type = 'table_ok' and (                 -- 配桌湊滿：房取消了或牌局已經過了
                  v_qstatus is null or v_qstatus not in ('matched', 'seated')
                  or v_qplay < now() - interval '30 minutes'))) then
      v_skip := 'stale';
    end if;

    if v_skip is null then
      v_msgs := _push_messages(r.nid);
      if v_msgs is null then
        v_skip := case when r.type = 'settle' then 'no_result' else 'stale' end;   -- no_result：一將都沒打完，沒有成績
      end if;
    end if;

    if v_skip is not null then
      update notification_deliveries
         set status = 'skipped', reason = v_skip, updated_at = now()
       where id = r.id;
    else
      update notification_deliveries
         set status = 'sending', claimed_at = now(), attempts = attempts + 1, updated_at = now()
       where id = r.id;
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'id', r.id, 'to', v_to, 'retry_key', r.retry_key,
        'messages', v_msgs,
        'text', coalesce(_push_text(r.nid), _push_settle_text(r.nid))));   -- 舊版 Edge Function 只認 text，留著不會壞
    end if;
  end loop;

  return v_out;
end $$;
-- CREATE OR REPLACE 不會丟授權；照樣寫一次，驗證段會核對
revoke execute on function public.push_claim_tx(text, int) from public, anon, authenticated;
grant  execute on function public.push_claim_tx(text, int) to service_role;

/* ============================================================
   驗證（單一 SELECT，不 raise —— 硬規則 1.8）
   ⑤⑥ 借線上現成的結算通知試組卡片；找不到樣本就印 ⚪，不假裝通過（硬規則 3.57）
   觸發器的行為測試在 sql/checks/2026-10-07_驗牌局結束推播.sql（交易內造樣本、整個回滾）
   ============================================================ */
with ok as (   -- 有名次的結算通知
  select n.id from app_notifications n
    join session_players sp on sp.session_id = coalesce((n.payload ->> 'session_id')::uuid, n.ref_id)
                           and sp.member_id = n.member_id
   where n.type = 'settle' and sp.finish_rank is not null
   order by n.created_at desc limit 1
), nores as (  -- 沒有名次的結算通知（一將都沒打完就收桌）
  select n.id from app_notifications n
    join session_players sp on sp.session_id = coalesce((n.payload ->> 'session_id')::uuid, n.ref_id)
                           and sp.member_id = n.member_id
   where n.type = 'settle' and sp.finish_rank is null
   order by n.created_at desc limit 1
), tok as (
  select n.id from app_notifications n where n.type = 'table_ok' order by n.created_at desc limit 1
)
select concat_ws(E'\n',
  case when exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'uq_app_notifications_settle_once')
       then '✅ ① 同一場同一人只有一則結算通知（唯一索引在）' else '🔴 ① 唯一索引不在' end,
  case when exists (select 1 from pg_trigger where tgname = 'trg_session_players_settle_notify'
                     and tgrelid = 'public.session_players'::regclass and tgenabled = 'O')
       then '✅ ② 名次寫進去就建通知的觸發器在、而且開著' else '🔴 ② 觸發器不在或沒開' end,
  case when (select pg_get_functiondef(p.oid) from pg_proc p
              where p.pronamespace = 'public'::regnamespace and p.proname = '_push_enqueue')
            ~ 'nr\.type in \(''table_ok'', ''settle''\)'
       then '✅ ③ 要推的通知多了「牌局結算完成」' else '🔴 ③ 白名單沒有 settle' end,
  case when public._push_signed(180) = '+180' and public._push_signed(-120) = '−120' and public._push_signed(0) = '0'
       then '✅ ④ 正負號：+180 ／ −120 ／ 0' else '🔴 ④ 正負號不對' end,
  coalesce((select case when public._push_messages(ok.id) #>> '{0,type}' = 'flex'
                         and public._push_messages(ok.id) #>> '{0,contents,footer,contents,0,action,uri}' like '%?tab=stats'
                         and public._push_messages(ok.id) #>> '{0,altText}' like '%牌局結束！第 % 名%'
                        then '✅ ⑤ 牌局結束卡片組得出來，通知那一行：' || (public._push_messages(ok.id) #>> '{0,altText}')
                        else '🔴 ⑤ 牌局結束卡片缺東西' end from ok),
           '⚪ ⑤ 線上沒有「有名次」的結算通知可以試（行為測試那份會自己造）'),
  coalesce((select case when public._push_messages(nores.id) is null
                        then '✅ ⑥ 沒有名次的結算通知不組卡片（推播會略過，reason = no_result）'
                        else '🔴 ⑥ 沒有名次也組出卡片了' end from nores),
           '⚪ ⑥ 線上沒有「沒名次」的結算通知可以試'),
  coalesce((select case when public._push_messages(tok.id) #>> '{0,altText}' like '%你的牌局湊滿了！%'
                        then '✅ ⑦ 配桌湊滿的卡片沒被改壞：' || (public._push_messages(tok.id) #>> '{0,altText}')
                        else '🔴 ⑦ 配桌湊滿的卡片變了' end from tok),
           '⚪ ⑦ 線上沒有 table_ok 通知可以試'),
  (select case when has_function_privilege('service_role', 'public.push_claim_tx(text,int)', 'execute')
                and not has_function_privilege('anon', 'public.push_claim_tx(text,int)', 'execute')
                and not has_function_privilege('authenticated', 'public.push_claim_tx(text,int)', 'execute')
                and public.push_claim_tx('不是那把鑰匙', 5) = '[]'::jsonb
               then '✅ ⑧ 取件仍只有 service_role 叫得動，鑰匙不對拿到空陣列'
               else '🔴 ⑧ 取件的授權或鑰匙檢查壞了' end),
  (select case when count(*) = 5
                and not bool_or(has_function_privilege('anon', p.oid, 'execute'))
                and not bool_or(has_function_privilege('authenticated', p.oid, 'execute'))
               then '✅ ⑨ 五支新的內部函式前端都叫不到'
               else '🔴 ⑨ 新內部函式的數量或授權不對（應該 5 支）' end
     from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('_settle_notify_on_rank', '_push_signed', '_push_settle_fields', '_push_settle_text', '_push_settle_flex'))
) as "驗證";
