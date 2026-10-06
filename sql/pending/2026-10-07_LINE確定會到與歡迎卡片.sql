/* ============================================================
   LINE：配桌湊滿卡片加「地址」「積分」與「確定會到」按鈕＋加好友歡迎卡片（2026-10-07）
   📄 預覽：https://claude.ai/artifact/3HytBmMi9f9d7i4SoPyMRz
   配套：Edge Function `line-webhook`（supabase/functions/line-webhook/index.ts）—— 接收 LINE 送來的事件

   ── 使用者拍板（2026-10-07）──────────────────────────────
   · 湊滿卡片維持現行版，只多兩列：地址（點了開 Google 地圖）、積分（從玩法拆出來；純娛樂寫「純娛樂」）
   · 按鈕：黑色「確定會到」＋ 白框「查看牌局詳情」。**不做「不克前往」**；開打前也先不再提醒
   · 按了「確定會到」：記下來、官方帳號回一句；重複按不重複記，只回「已經收到囉」
   · 加好友歡迎卡片：「{LINE 名字}，歡迎加入！」／大字「你負責胡牌，其他交給 MIGI」／配桌、成績、獎勵三列／
     「第一次使用要先註冊，大約一分鐘。」／按鈕「開始使用 MIGI」

   ── 改了什麼 ─────────────────────────────────────────
   ① match_queue_players.attend_confirmed_at：客人在 LINE 按「確定會到」的時間（沒按是 null）
   ② _url_encode(text)：地址放進 Google 地圖網址前要編碼（Postgres 沒有內建）
   ③ _push_when_short(ts)：「今天 21:00」「明天 21:00」「10/8（四）21:00」—— 卡片與「確定會到」的回覆共用一份
   ④ _push_fields：多回 queue_id、addr、map_url、stake_label（積分一列用；純娛樂就是「純娛樂」）
   ⑤ _push_text：地址、積分各自一行（玩法不再接積分）
   ⑥ _push_flex：細項 門市／地址／桌號／玩法／積分／同桌；按鈕「確定會到」（postback）＋「查看牌局詳情」
   ⑦ line_attend_confirm_tx(line_user_id, queue_id)：按下「確定會到」—— 只給 service_role（接收程式）
      🔴 只認「這個 LINE 帳號的會員真的在那一房裡、而且房還沒結束」⇒ 卡片被轉傳給別人按，也記不到別人頭上
   ⑧ line_welcome_flex_tx(name)：歡迎卡片 —— 只給 service_role
   ⑨ pos_list_queues_tx_core：每個人多回 attend_confirmed（POS 座位卡畫「✓ 會到」）；其餘逐字照線上

   ⚠ 新函式照 2026-09-29 的預設全關；⑦⑧ 明確只給 service_role。
   ⚠ 驗證段只有一支 SELECT，不用 raise（硬規則 1.8）。跑完我會另外查一次線上。
   ============================================================ */

-- ① 確定會到的時間
alter table public.match_queue_players add column if not exists attend_confirmed_at timestamptz;
comment on column public.match_queue_players.attend_confirmed_at is
  '客人在 LINE 配桌湊滿卡片按「確定會到」的時間；沒按是 null。只由 line_attend_confirm_tx 寫入（2026-10-07）';

-- ② 網址編碼（RFC 3986：英數與 -_.~ 不編，其餘逐位元組 %XX）
create or replace function public._url_encode(p text)
returns text
language sql
immutable
as $$
  select coalesce(string_agg(
           case when (b between 48 and 57) or (b between 65 and 90) or (b between 97 and 122) or b in (45, 46, 95, 126)
                then chr(b)
                else '%' || upper(lpad(to_hex(b), 2, '0')) end,
           '' order by i), '')
    from (select i, get_byte(convert_to(coalesce(p, ''), 'UTF8'), i) as b
            from generate_series(0, octet_length(convert_to(coalesce(p, ''), 'UTF8')) - 1) as i) x
$$;
revoke execute on function public._url_encode(text) from public, anon, authenticated;

-- ③ 開打時間的短寫法（原本寫在 _push_fields 裡，抽出來給「確定會到」的回覆共用）
create or replace function public._push_when_short(p_at timestamptz)
returns text
language plpgsql
stable
as $$
declare
  v_d date;
  v_today date := (now() at time zone 'Asia/Taipei')::date;
begin
  if p_at is null then return '湊滿就開打'; end if;
  v_d := (p_at at time zone 'Asia/Taipei')::date;
  -- 「今天 21:00」中間空一格；「10/8（四）21:00」全形括號後面不再空格
  return case when v_d = v_today then '今天 '
              when v_d = v_today + 1 then '明天 '
              else to_char(v_d, 'FMMM/FMDD') || '（' ||
                   (array['日','一','二','三','四','五','六'])[extract(dow from v_d)::int + 1] || '）'
         end || to_char(p_at at time zone 'Asia/Taipei', 'HH24:MI');
end $$;
revoke execute on function public._push_when_short(timestamptz) from public, anon, authenticated;

-- ④ 配桌湊滿：唯一一份內容
create or replace function public._push_fields(p_notif uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  n app_notifications%rowtype;
  q record;
  v_tbl text; v_others text; v_when text; v_short text;
begin
  select * into n from app_notifications where id = p_notif;
  if n.id is null or n.type <> 'table_ok' then return null; end if;

  select mq.id, mq.play_at, mq.matched_session_id, s.name as store_name, s.address as store_addr,
         concat_ws(' · ', mq.game_type, mq.flower, mq.rounds) as game,
         case when sl.is_hygiene then sl.label else '積分 ' || sl.label end as stake,
         sl.label as stake_label,
         (select m.display_name from members m where m.id = n.member_id) as my_name
    into q
    from match_queues mq
    left join stores s on s.id = mq.store_id
    left join stake_levels sl on sl.id = mq.stake_level_id
   where mq.id = coalesce((n.payload ->> 'queue_id')::uuid, n.ref_id);
  if q.id is null then return null; end if;

  select t.label into v_tbl
    from table_sessions ts join tables t on t.id = ts.table_id
   where ts.id = q.matched_session_id and ts.status = 'open';

  -- 隱藏的會員名字已經是「隱藏的會員」（隱藏時就換掉了），這裡不用另外判斷
  select string_agg(m.display_name, '、' order by qp.joined_at) into v_others
    from match_queue_players qp join members m on m.id = qp.member_id
   where qp.queue_id = q.id and qp.left_at is null and qp.member_id <> n.member_id;

  v_short := _push_when_short(q.play_at);
  v_when := case when q.play_at is null then v_short else v_short || ' 開打' end;

  return jsonb_build_object(
    'test',     n.payload ->> 'test' = 'true',
    'style',    n.payload ->> 'style',
    'queue_id', q.id,
    'when',     v_when,
    'short',    v_short,
    'store',    coalesce(q.store_name, 'MIGI'),
    'addr',     nullif(q.store_addr, ''),
    'map_url',  case when nullif(q.store_addr, '') is not null
                     then 'https://www.google.com/maps/search/?api=1&query=' || _url_encode(q.store_addr) end,
    'table',    v_tbl,
    'place',    coalesce(q.store_name, 'MIGI') || coalesce(' · ' || v_tbl || ' 桌', ''),
    'others',   v_others,
    'name',     q.my_name,                                   -- 稱呼客人（參考業界通知：開頭先叫名字）
    'game',     nullif(q.game, ''),                          -- 台麻 · 無花 · 2 將
    'stake',    q.stake,                                     -- 「積分 50/20」（舊寫法，留給舊呼叫點）
    'stake_label', q.stake_label,                            -- 「50/20」；純娛樂的桌就是「純娛樂」
    'url',      'https://liff.line.me/2011312117-Zuul0Ndo?tab=match');   -- ?tab=match：App 打開直接到配桌頁（migi-web lib/deeplink.js）
end $$;
revoke execute on function public._push_fields(uuid) from public, anon, authenticated;

-- ⑤ 文字版
create or replace function public._push_text(p_notif uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare f jsonb := _push_fields(p_notif);
begin
  if f is null then return null; end if;
  return concat_ws(E'\n',
    case when (f ->> 'test')::boolean then '【推播測試】' end,
    coalesce((f ->> 'name') || '，', '') || '你的牌局湊滿了！',
    '時間：' || (f ->> 'when'),
    '地點：' || (f ->> 'place'),
    case when f ->> 'addr' is not null then '地址：' || (f ->> 'addr') end,
    case when f ->> 'game' is not null then '玩法：' || (f ->> 'game') end,
    case when f ->> 'stake_label' is not null then '積分：' || (f ->> 'stake_label') end,
    case when f ->> 'others' is not null then '同桌：' || (f ->> 'others') end,
    '請準時到店，到櫃檯報到就能入座。',
    '查看牌局詳情：' || (f ->> 'url'));
end $$;
revoke execute on function public._push_text(uuid) from public, anon, authenticated;

-- ⑥ 卡片版
create or replace function public._push_flex(p_notif uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  f jsonb := _push_fields(p_notif);
  v_rows jsonb;
  v_alt text;
begin
  if f is null then return null; end if;

  -- 細項：一列「項目 → 內容」，沒有值的那一列整列不畫；地址那一列點了開 Google 地圖
  select jsonb_agg(jsonb_build_object('type', 'box', 'layout', 'baseline', 'spacing', 'md', 'contents', jsonb_build_array(
           jsonb_build_object('type', 'text', 'text', k, 'size', 'sm', 'color', '#8B8582', 'flex', 2),
           case when link is not null
                then jsonb_build_object('type', 'text', 'text', v, 'size', 'sm', 'color', '#2A62C9', 'wrap', true, 'flex', 7,
                                        'decoration', 'underline',
                                        'action', jsonb_build_object('type', 'uri', 'label', '地圖', 'uri', link))
                else jsonb_build_object('type', 'text', 'text', v, 'size', 'sm', 'color', '#2E2B2C', 'wrap', true, 'flex', 7) end))
         order by o)
    into v_rows
    from (values (1, '門市', f ->> 'store',       null),
                 (2, '地址', f ->> 'addr',        f ->> 'map_url'),
                 (3, '桌號', coalesce((f ->> 'table') || ' 桌', '到店後櫃檯帶位'), null),
                 (4, '玩法', f ->> 'game',        null),
                 (5, '積分', f ->> 'stake_label', null),
                 (6, '同桌', f ->> 'others',      null)) t(o, k, v, link)
   where v is not null;

  -- 手機通知與聊天列表只看得到這一句（卡片本身不會出現在那裡）
  v_alt := case when (f ->> 'test')::boolean then '【推播測試】' else '' end
        || coalesce((f ->> 'name') || '，', '') || '你的牌局湊滿了！'
        || (f ->> 'short') || coalesce(' · ' || (f ->> 'table') || ' 桌', '');

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
          jsonb_build_object('type', 'text', 'text', coalesce((f ->> 'name') || '，', '') || '你的牌局湊滿了！',
                             'size', 'sm', 'color', '#2E2B2C', 'wrap', true),
          jsonb_build_object('type', 'text', 'text', '開打時間', 'size', 'xs', 'color', '#8B8582', 'margin', 'lg'),
          jsonb_build_object('type', 'text', 'text', f ->> 'short', 'size', 'xxl', 'weight', 'bold',
                             'color', '#2E2B2C', 'margin', 'xs'),
          jsonb_build_object('type', 'separator', 'margin', 'lg', 'color', '#DED9D5'),
          jsonb_build_object('type', 'box', 'layout', 'vertical', 'spacing', 'sm', 'margin', 'lg',
                             'contents', coalesce(v_rows, '[]'::jsonb)),
          jsonb_build_object('type', 'separator', 'margin', 'lg', 'color', '#DED9D5'),
          jsonb_build_object('type', 'text', 'text', '請準時到店，到櫃檯報到就能入座。',
                             'size', 'xs', 'color', '#8B8582', 'wrap', true, 'margin', 'lg'))),
      -- 按鈕：黑色「確定會到」（postback，接收程式 line-webhook 處理）＋ 白框「查看牌局詳情」
      --   ⚠ LINE 的按鈕沒有外框樣式，白框那顆用「有框的 box ＋ 動作」做
      'footer', jsonb_build_object('type', 'box', 'layout', 'vertical', 'paddingAll', '12px', 'spacing', 'sm',
        'contents', jsonb_build_array(
          jsonb_build_object('type', 'button', 'style', 'primary', 'color', '#2E2B2C', 'height', 'sm',
            'action', jsonb_build_object('type', 'postback', 'label', '確定會到',
                                         'data', 'attend:' || (f ->> 'queue_id'), 'displayText', '確定會到')),
          jsonb_build_object('type', 'box', 'layout', 'vertical', 'borderWidth', 'normal', 'borderColor', '#DED9D5',
            'cornerRadius', 'md', 'paddingAll', '9px',
            'action', jsonb_build_object('type', 'uri', 'label', '查看牌局詳情', 'uri', f ->> 'url'),
            'contents', jsonb_build_array(
              jsonb_build_object('type', 'text', 'text', '查看牌局詳情', 'size', 'sm', 'weight', 'bold',
                                 'color', '#2E2B2C', 'align', 'center')))))));
end $$;
revoke execute on function public._push_flex(uuid) from public, anon, authenticated;

-- ⑦ 按下「確定會到」
create or replace function public.line_attend_confirm_tx(p_line_user_id text, p_queue_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mid uuid;
  v_q record;
  v_tbl text;
  v_pid uuid;
  v_done timestamptz;
  v_short text;
begin
  select m.id into v_mid
    from members m
   where m.line_user_id = p_line_user_id and m.deleted_at is null and m.hidden_at is null
   limit 1;
  if v_mid is null then
    return jsonb_build_object('ok', false, 'reason', 'not_member',
      'reply', '找不到你的會員資料，請先在 App 註冊。');
  end if;

  select mq.id, mq.status, mq.play_at, mq.matched_session_id, s.name as store_name into v_q
    from match_queues mq left join stores s on s.id = mq.store_id
   where mq.id = p_queue_id;

  -- 🔴 只認真的在這一房裡、還沒離開的人（卡片被轉傳給別人按，記不到別人頭上）
  select qp.id, qp.attend_confirmed_at into v_pid, v_done
    from match_queue_players qp
   where qp.queue_id = p_queue_id and qp.member_id = v_mid and qp.left_at is null;
  if v_q.id is null or v_pid is null then
    return jsonb_build_object('ok', false, 'reason', 'not_in_queue',
      'reply', '這個牌局找不到你的報名，有問題請洽門市。');
  end if;

  if v_q.status not in ('matched', 'seated')
     or (v_q.play_at is not null and v_q.play_at < now() - interval '3 hours') then
    return jsonb_build_object('ok', false, 'reason', 'closed',
      'reply', '這個牌局已經結束或取消了。');
  end if;

  select t.label into v_tbl
    from table_sessions ts join tables t on t.id = ts.table_id
   where ts.id = v_q.matched_session_id and ts.status = 'open';
  v_short := _push_when_short(v_q.play_at);

  if v_done is not null then
    return jsonb_build_object('ok', true, 'already', true,
      'reply', '已經收到囉，' || v_short || ' 見！');
  end if;

  update match_queue_players set attend_confirmed_at = now() where id = v_pid;

  return jsonb_build_object('ok', true, 'already', false,
    'reply', '收到！' || v_short || ' 在 ' || coalesce(v_q.store_name, 'MIGI')
             || coalesce(' ' || v_tbl || ' 桌', '') || '見 🀄');
end $$;
revoke execute on function public.line_attend_confirm_tx(text, uuid) from public, anon, authenticated;
grant  execute on function public.line_attend_confirm_tx(text, uuid) to service_role;

-- ⑧ 加好友歡迎卡片
create or replace function public.line_welcome_flex_tx(p_name text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'type', 'flex',
    'altText', coalesce(nullif(p_name, '') || '，', '') || '歡迎加入 MIGI 咪吉麻將！',
    'contents', jsonb_build_object(
      'type', 'bubble',
      'header', jsonb_build_object(
        'type', 'box', 'layout', 'vertical', 'backgroundColor', '#FAD6DC', 'paddingAll', '14px',
        'contents', jsonb_build_array(
          jsonb_build_object('type', 'text', 'text', 'MIGI 咪吉麻將', 'size', 'lg', 'weight', 'bold',
                             'color', '#2E2B2C', 'align', 'center'))),
      'body', jsonb_build_object('type', 'box', 'layout', 'vertical', 'paddingAll', '18px',
        'contents', jsonb_build_array(
          jsonb_build_object('type', 'text', 'text', coalesce(nullif(p_name, '') || '，', '') || '歡迎加入！',
                             'size', 'sm', 'color', '#2E2B2C', 'wrap', true),
          jsonb_build_object('type', 'text', 'text', '你負責胡牌，', 'size', 'xl', 'weight', 'bold',
                             'color', '#2E2B2C', 'margin', 'lg'),
          jsonb_build_object('type', 'text', 'text', '其他交給 MIGI', 'size', 'xl', 'weight', 'bold',
                             'color', '#2E2B2C'),
          jsonb_build_object('type', 'separator', 'margin', 'lg', 'color', '#DED9D5'),
          jsonb_build_object('type', 'box', 'layout', 'vertical', 'spacing', 'sm', 'margin', 'lg',
            'contents', (select jsonb_agg(jsonb_build_object('type', 'box', 'layout', 'baseline', 'spacing', 'md',
                           'contents', jsonb_build_array(
                             jsonb_build_object('type', 'text', 'text', k, 'size', 'sm', 'color', '#8B8582', 'flex', 2),
                             jsonb_build_object('type', 'text', 'text', v, 'size', 'sm', 'color', '#2E2B2C', 'wrap', true, 'flex', 7)))
                           order by o)
                           from (values (1, '配桌', '線上報名，湊滿就用 LINE 通知你'),
                                        (2, '成績', '每一場的名次、積分都記下來'),
                                        (3, '獎勵', '升段位解鎖頭像，打牌累積成就')) t(o, k, v))),
          jsonb_build_object('type', 'separator', 'margin', 'lg', 'color', '#DED9D5'),
          jsonb_build_object('type', 'text', 'text', '第一次使用要先註冊，大約一分鐘。',
                             'size', 'xs', 'color', '#8B8582', 'wrap', true, 'margin', 'lg'))),
      'footer', jsonb_build_object('type', 'box', 'layout', 'vertical', 'paddingAll', '12px',
        'contents', jsonb_build_array(
          jsonb_build_object('type', 'button', 'style', 'primary', 'color', '#2E2B2C', 'height', 'sm',
            'action', jsonb_build_object('type', 'uri', 'label', '開始使用 MIGI',
                                         'uri', 'https://liff.line.me/2011312117-Zuul0Ndo'))))))
$$;
revoke execute on function public.line_welcome_flex_tx(text) from public, anon, authenticated;
grant  execute on function public.line_welcome_flex_tx(text) to service_role;

-- ⑨ POS 配桌列表：每個人多回 attend_confirmed（其餘逐字照線上 2026-10-07 版）
create or replace function public.pos_list_queues_tx_core(p_org uuid, p_store uuid, p_before timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 20)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with live as (
    /* 現在的事：全部回傳，**不分頁**。
       ⚠ 被截掉的話會出現「有一桌在等你結帳但它在第二頁」，
         而店員不會知道要去翻。 */
    select q.id
      from match_queues q
      left join table_sessions ts on ts.id = q.matched_session_id
     where q.org_id = p_org and q.store_id = p_store
       and (
         (q.status = 'waiting'
           and (q.expires_at is null or q.expires_at > now())
           and (q.open_at is null or q.open_at <= now()))
         or q.status = 'matched'
         or (q.status = 'seated' and ts.status = 'open' and ts.deleted_at is null)
       )
  ),
  history as (
    /* 已收桌的：新到舊，分頁。
       🔴 **配桌是延續的** —— 前兩位可能是上一班找到的，靠下一班完成，
         所以這裡**不可以有任何日／班的邊界**（2026-09-07 拿掉了 7 天窗口）。
       ⚠ `p_limit` 夾在 1..100：0 或負數會讓這一段整個消失，
         而症狀是「已完成分頁空的」，看不出是參數問題。 */
    select q.id
      from match_queues q
      join table_sessions ts on ts.id = q.matched_session_id
     where q.org_id = p_org and q.store_id = p_store
       and q.status = 'seated'
       and ts.status = 'completed' and ts.deleted_at is null
       and (p_before is null or ts.ended_at < p_before)
     order by ts.ended_at desc
     limit least(greatest(coalesce(p_limit, 20), 1), 100)
  ),
  picked as (select id from live union select id from history)
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', q.id,
    'status', q.status,
    'source', q.source,
    'stake_level_id', q.stake_level_id,
    'stake', sl.label,
    'game_type', q.game_type, 'flower', q.flower, 'rounds', q.rounds,
    'seats', q.seats,
    'play_at', q.play_at,
    'open_at', q.open_at,
    'recurring_freq', q.recurring_freq,
    'opener', mo.display_name,
    'session_id', q.matched_session_id, 'tags', q.tags,
    'table_label', tb.label,
    'seated_at', case when q.status = 'seated' then q.updated_at else null end,
    /* `auto` = 系統帶的／`manual` = 店員在 POS 按的。
       ⚠ 值不是 `auto` 的一律寫「已帶到 A3」不寫「系統自動」。 */
    'open_method', ts.open_method,
    /* ★ 2026-09-06：這個房還能不能被系統自動配。
       false ＝ 帶到的桌被取消過，之後由店員手動配（隨機／指定）。
       🔴 少了它，`matched` 且沒有桌的房前端**分不出**
         「排程等一下會配」與「在等我動手」。 */
    'auto_seat', q.auto_seat,
    /* 🔴 數的是「這桌收了幾份檯費」，**不要加 `left_at is null`** ——
       收桌時在座玩家一律被寫 `left_at`，那個條件會讓收桌那一刻
       掉回 0，配桌列表就對一個早就收齊的房喊「前往結帳」。
       ⚠ 也不要改成數 `order_id is not null`：暢打的人 order_id 是 null
       （那是「不用付」不是「還沒付」）。 */
    'paid_count', (
      select count(*) from session_players sp
       where sp.session_id = q.matched_session_id),
    'session_status', ts.status,
    'settled_at', ts.ended_at,
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'member_id', m.id, 'nickname', m.display_name,
        'rank', m.rank, 'title', m.title,
        'tier', coalesce(m.tier_override, m.tier),
        'joined_at', p.joined_at,
        'walk_in', p.join_source = 'pos_walkin',
        /* 🆕 2026-10-07：客人在 LINE 按了「確定會到」（POS 座位卡畫「✓ 會到」） */
        'attend_confirmed', p.attend_confirmed_at is not null,
        /* 頭像四欄（2026-09-26）：與 get_session_tx 同一組鍵，POS 的座位卡直接畫。
           少了它們，配桌列表上每個人都是通用小熊。 */
        'avatar_source', m.avatar_source,
        'avatar_photo_path', m.avatar_photo_path,
        'avatar_bear', m.avatar_bear,
        'avatar_url', m.avatar_url
      ) order by p.joined_at)
      from match_queue_players p
      join members m on m.id = p.member_id
      where p.queue_id = q.id and p.left_at is null), '[]'::jsonb)
    /* 排序：現在的事在前；已收桌的之間**依收桌時間新到舊**。
       ⚠ 舊版依 `play_at`（開打時間）—— 往回翻時順序會跳。 */
  ) order by (ts.status is distinct from 'completed') desc,
             (q.status = 'seated') desc,
             (q.status = 'matched') desc,
             ts.ended_at desc nulls last,
             q.play_at), '[]'::jsonb)
  from match_queues q
  join picked pk on pk.id = q.id
  left join stake_levels sl on sl.id = q.stake_level_id and sl.org_id = p_org
  left join members mo on mo.id = q.opened_by
  left join table_sessions ts on ts.id = q.matched_session_id
  left join tables tb on tb.id = ts.table_id
$function$;

/* ============================================================
   驗證（單一 SELECT，不 raise —— 硬規則 1.8）
   ⑤ 借最近一則配桌湊滿通知試組卡片；找不到樣本就印 ⚪
   ============================================================ */
with tok as (
  select n.id from app_notifications n where n.type = 'table_ok' order by n.created_at desc limit 1
)
select concat_ws(E'\n',
  case when exists (select 1 from information_schema.columns where table_schema = 'public'
                     and table_name = 'match_queue_players' and column_name = 'attend_confirmed_at')
       then '✅ ① 配桌名單多了「確定會到的時間」' else '🔴 ① 欄位不在' end,
  case when public._url_encode('高雄市 A-1') = '%E9%AB%98%E9%9B%84%E5%B8%82%20A-1'
       then '✅ ② 網址編碼：高雄市 A-1 → %E9%AB%98%E9%9B%84%E5%B8%82%20A-1' else '🔴 ② 網址編碼不對：' || public._url_encode('高雄市 A-1') end,
  case when public._push_when_short(null) = '湊滿就開打'
        and public._push_when_short(now()) like '今天 %'
       then '✅ ③ 開打時間短寫法照舊（今天／明天／月日）' else '🔴 ③ 開打時間寫法變了' end,
  coalesce((select case when public._push_flex(tok.id) #>> '{contents,footer,contents,0,action,type}' = 'postback'
                         and public._push_flex(tok.id) #>> '{contents,footer,contents,0,action,data}' like 'attend:%'
                         and public._push_flex(tok.id) #>> '{contents,footer,contents,1,action,uri}' like '%?tab=match'
                         and public._push_flex(tok.id)::text like '%"地址"%'
                         and public._push_flex(tok.id)::text like '%"積分"%'
                        then '✅ ④ 湊滿卡片有地址、積分、「確定會到」與「查看牌局詳情」；通知那一行：' || (public._push_flex(tok.id) ->> 'altText')
                        else '🔴 ④ 湊滿卡片缺東西' end from tok),
           '⚪ ④ 線上沒有配桌湊滿通知可以試'),
  coalesce((select case when public._push_text(tok.id) like '%地址：%' and public._push_text(tok.id) like '%積分：%'
                        then '✅ ⑤ 文字版也有地址、積分各一行' else '🔴 ⑤ 文字版缺地址或積分' end from tok), '⚪ ⑤'),
  case when public.line_attend_confirm_tx('U00000000000000000000000000000000', gen_random_uuid()) ->> 'reason' = 'not_member'
       then '✅ ⑥ 不是會員的 LINE 按「確定會到」：' || (public.line_attend_confirm_tx('U00000000000000000000000000000000', gen_random_uuid()) ->> 'reply')
       else '🔴 ⑥ 陌生 LINE 帳號沒被擋' end,
  case when public.line_welcome_flex_tx('阿明') ->> 'altText' = '阿明，歡迎加入 MIGI 咪吉麻將！'
        and public.line_welcome_flex_tx('阿明')::text like '%你負責胡牌%'
        and public.line_welcome_flex_tx(null) ->> 'altText' = '歡迎加入 MIGI 咪吉麻將！'
       then '✅ ⑦ 歡迎卡片組得出來（拿不到名字時不叫名字）' else '🔴 ⑦ 歡迎卡片不對' end,
  case when has_function_privilege('service_role', 'public.line_attend_confirm_tx(text,uuid)', 'execute')
        and not has_function_privilege('anon', 'public.line_attend_confirm_tx(text,uuid)', 'execute')
        and not has_function_privilege('authenticated', 'public.line_attend_confirm_tx(text,uuid)', 'execute')
        and has_function_privilege('service_role', 'public.line_welcome_flex_tx(text)', 'execute')
        and not has_function_privilege('anon', 'public.line_welcome_flex_tx(text)', 'execute')
        and not has_function_privilege('authenticated', 'public.line_welcome_flex_tx(text)', 'execute')
       then '✅ ⑧ 兩支新函式只有 service_role（接收程式）叫得動' else '🔴 ⑧ 新函式的授權不對' end,
  case when (select pg_get_functiondef('public.pos_list_queues_tx_core(uuid,uuid,timestamptz,int)'::regprocedure))
            ~ '''attend_confirmed'', p\.attend_confirmed_at is not null'
        and (select pg_get_functiondef('public.pos_list_queues_tx_core(uuid,uuid,timestamptz,int)'::regprocedure))
            ~ '''paid_count'''
       then '✅ ⑨ POS 配桌列表多回「會到了沒」，原本的欄位還在' else '🔴 ⑨ POS 配桌列表沒換到或換壞了' end
) as "驗證";
