/* ============================================================
   LINE 推播：加卡片版（Flex Message），文字版與卡片版共用同一份內容
   2026-10-05 · 接在 2026-10-05_LINE推播_配桌湊滿.sql 之後

   ── 改了什麼 ────────────────────────────────────────
   ```
   _push_fields(notif)    🆕 唯一一份「這則要講什麼」：時間、地點（店名＋桌號）、同桌、是不是測試
   _push_text(notif)      ✏️ 改成讀 _push_fields；第一行加稱呼、多一行玩法（照使用者給的業界通知參考）
   _push_flex(notif)      🆕 卡片版：品牌標題列、稱呼、開打時間放最大、門市／桌號／玩法／同桌、
                             「查看牌局」＋（門市有電話時）「不能準時到？打給門市」
   _push_messages(notif)  🆕 決定這一則送哪幾個框：預設只送文字；通知 payload 帶 style 可以指定
   push_claim_tx          ✏️ 交件時多帶 messages（Edge Function 照著送）；text 仍保留
   ```
   🎯 為什麼要拆 _push_fields：文字版與卡片版各自查一次資料，遲早會出現
     「文字寫 A3 桌、卡片寫還沒帶桌」—— 同一件事兩份定義，這個專案記過很多次。

   ── 用哪一種，改一行 ────────────────────────────────
   `_push_messages` 裡的 v_default：'text'（現在）／'card'／'both'。
   ⚠ 一次推播最多 5 個框，**不管幾個都只算 1 則**，所以 both 不會多花錢 —— 只是客人會看到兩個框。
   測試工具（sql/_工具/推播測試_發給自己.sql）在 payload 帶 style = 'both'，一次比兩種。

   ── 卡片版的通知那一行 ──────────────────────────────
   卡片本身不會出現在手機通知與聊天列表裡，那裡顯示的是 altText ——
   所以另外組一句「你的牌局湊滿了！明天 21:00 · A3 桌」。
   ============================================================ */

-- ① 唯一一份內容
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
  v_tbl text; v_others text; v_when text; v_short text; v_d date;
  v_today date := (now() at time zone 'Asia/Taipei')::date;
begin
  select * into n from app_notifications where id = p_notif;
  if n.id is null or n.type <> 'table_ok' then return null; end if;

  select mq.id, mq.play_at, mq.matched_session_id, s.name as store_name, s.phone as store_phone,
         concat_ws(' · ', mq.game_type, mq.flower, mq.rounds) as game,
         case when sl.is_hygiene then sl.label else '積分 ' || sl.label end as stake,
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

  if q.play_at is null then
    v_when := '湊滿就開打'; v_short := '湊滿就開打';
  else
    v_d := (q.play_at at time zone 'Asia/Taipei')::date;
    -- 「今天 21:00」中間空一格；「10/8（四）21:00」全形括號後面不再空格
    v_short := case when v_d = v_today then '今天 '
                    when v_d = v_today + 1 then '明天 '
                    else to_char(v_d, 'FMMM/FMDD') || '（' ||
                         (array['日','一','二','三','四','五','六'])[extract(dow from v_d)::int + 1] || '）'
               end || to_char(q.play_at at time zone 'Asia/Taipei', 'HH24:MI');
    v_when := v_short || ' 開打';
  end if;

  return jsonb_build_object(
    'test',   n.payload ->> 'test' = 'true',
    'style',  n.payload ->> 'style',
    'when',   v_when,
    'short',  v_short,
    'store',  coalesce(q.store_name, 'MIGI'),
    'table',  v_tbl,
    'place',  coalesce(q.store_name, 'MIGI') || coalesce(' · ' || v_tbl || ' 桌', ''),
    'others', v_others,
    'name',   q.my_name,                                   -- 稱呼客人（參考業界通知：開頭先叫名字）
    'game',   nullif(q.game, ''),                          -- 台麻 · 無花 · 2 將
    'stake',  q.stake,                                     -- 「積分 50/20」；純娛樂的桌只寫「純娛樂」
    'phone',  nullif(regexp_replace(coalesce(q.store_phone, ''), '[^0-9+]', '', 'g'), ''),  -- 打電話用，只留數字
    'phone_label', q.store_phone,
    'url',    'https://liff.line.me/2011312117-Zuul0Ndo');
end $$;
revoke execute on function public._push_fields(uuid) from public, anon, authenticated;

-- ② 文字版（輸出跟上一版逐字相同）
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
  -- 2026-10-05 照業界通知的寫法加了稱呼與玩法（第一行就是手機通知會露出來的那一句）
  return concat_ws(E'\n',
    case when (f ->> 'test')::boolean then '【推播測試】' end,
    coalesce((f ->> 'name') || '，', '') || '你的牌局湊滿了！',
    '時間：' || (f ->> 'when'),
    '地點：' || (f ->> 'place'),
    case when coalesce(f ->> 'game', f ->> 'stake') is not null
         then '玩法：' || concat_ws(' · ', f ->> 'game', f ->> 'stake') end,
    case when f ->> 'others' is not null then '同桌：' || (f ->> 'others') end,
    '請準時到店，到櫃檯報到就能入座。',
    '查看牌局：' || (f ->> 'url'));
end $$;
revoke execute on function public._push_text(uuid) from public, anon, authenticated;

-- ③ 卡片版（LINE Flex Message）
--    顏色（2026-10-05 使用者指定，不用桃紅）：標題列 --brand #FAD6DC、主按鈕 --ink #2E2B2C 配白字、
--    次按鈕粉底 #FAD6DC 黑字、灰字 #8B8582。
--    ⚠ 粉色不當字色用：白底上對比約 1.3:1，等於看不見 —— 要粉就當底色
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

  -- 細項：一列「項目 → 內容」，沒有值的那一列整列不畫
  select jsonb_agg(jsonb_build_object('type', 'box', 'layout', 'baseline', 'spacing', 'md', 'contents', jsonb_build_array(
           jsonb_build_object('type', 'text', 'text', k, 'size', 'sm', 'color', '#8B8582', 'flex', 2),
           jsonb_build_object('type', 'text', 'text', v, 'size', 'sm', 'color', '#2E2B2C', 'wrap', true, 'flex', 7)))
         order by o)
    into v_rows
    from (values (1, '門市', f ->> 'store'),
                 (2, '桌號', coalesce((f ->> 'table') || ' 桌', '到店後櫃檯帶位')),
                 (3, '玩法', nullif(concat_ws(' · ', f ->> 'game', f ->> 'stake'), '')),
                 (4, '同桌', f ->> 'others')) t(o, k, v)
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
      -- 標題列：品牌名置中（參考業界的預約通知）
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
      -- 按鈕：主要「查看牌局」；門市有電話才多一顆「打給門市」
      'footer', jsonb_build_object('type', 'box', 'layout', 'vertical', 'spacing', 'sm', 'paddingAll', '12px',
        'contents', jsonb_build_array(
          jsonb_build_object('type', 'button', 'style', 'primary', 'color', '#2E2B2C', 'height', 'sm',
            'action', jsonb_build_object('type', 'uri', 'label', '查看牌局', 'uri', f ->> 'url')))
          || case when f ->> 'phone' is not null
                  then jsonb_build_array(jsonb_build_object('type', 'button', 'style', 'secondary', 'color', '#FAD6DC', 'height', 'sm',
                         'action', jsonb_build_object('type', 'uri', 'label', '不能準時到？打給門市', 'uri', 'tel:' || (f ->> 'phone'))))
                  else '[]'::jsonb end)));
end $$;
revoke execute on function public._push_flex(uuid) from public, anon, authenticated;

-- ④ 這一則送哪幾個框
create or replace function public._push_messages(p_notif uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_default text := 'text';          -- 🔴 正式推播用哪一種就改這裡：'text'／'card'／'both'
  v_style text;
  v_text text; v_flex jsonb;
begin
  v_style := coalesce(nullif((select payload ->> 'style' from app_notifications where id = p_notif), ''), v_default);
  v_text := _push_text(p_notif);
  if v_text is null then return null; end if;
  v_flex := _push_flex(p_notif);
  return case v_style
    when 'card' then jsonb_build_array(v_flex)
    when 'both' then jsonb_build_array(jsonb_build_object('type', 'text', 'text', v_text), v_flex)
    else jsonb_build_array(jsonb_build_object('type', 'text', 'text', v_text))
  end;
end $$;
revoke execute on function public._push_messages(uuid) from public, anon, authenticated;

-- ⑤ 取件：多交一份 messages（其餘跟上一版相同）
create or replace function public.push_claim_tx(p_key text, p_limit int default 20)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_out jsonb := '[]'::jsonb;
  r record;
  v_to text; v_gone boolean; v_q record; v_msgs jsonb; v_skip text;
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
    select d.id, d.retry_key, n.id as nid, n.member_id, n.created_at as n_at, n.payload, n.ref_id
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

    select mq.status, mq.play_at into v_q
      from match_queues mq where mq.id = coalesce((r.payload ->> 'queue_id')::uuid, r.ref_id);

    if v_gone then
      v_skip := 'member_gone';
    elsif v_to is null then
      v_skip := 'no_line';
    elsif v_to !~ '^U[0-9a-f]{32}$' then
      v_skip := 'bad_line_id';                -- 測試帳號的假 id（TEST…）
    elsif coalesce(r.payload ->> 'test', '') <> 'true' and (
            v_q.status is null or v_q.status not in ('matched', 'seated')
            or v_q.play_at < now() - interval '30 minutes'
            or r.n_at < now() - interval '6 hours') then
      v_skip := 'stale';                      -- 房取消了、牌局已經過了、或塞太久 —— 不要半夜補送昨天的牌局
    end if;

    if v_skip is null then
      v_msgs := _push_messages(r.nid);
      if v_msgs is null then v_skip := 'stale'; end if;
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
        'text', _push_text(r.nid)));          -- 舊版 Edge Function 只認 text，留著不會壞
    end if;
  end loop;

  return v_out;
end $$;
-- CREATE OR REPLACE 不會丟授權；照樣寫一次，驗證段會核對
revoke execute on function public.push_claim_tx(text, int) from public, anon, authenticated;
grant  execute on function public.push_claim_tx(text, int) to service_role;

/* ============================================================
   驗證（單一 SELECT，不 raise —— 硬規則 1.8）
   ============================================================ */
with s as (
  select n.id from app_notifications n where n.type = 'table_ok' order by n.created_at desc limit 1
)
select concat_ws(E'\n',
  coalesce((select case when public._push_text(s.id) like '%你的牌局湊滿了！' || E'\n' || '時間：%'
                         and public._push_text(s.id) like '%查看牌局：https://liff.line.me/%'
                        then '✅ ① 文字版：' || replace(public._push_text(s.id), E'\n', ' ／ ')
                        else '🔴 ① 文字版變了：' || coalesce(public._push_text(s.id), 'null') end from s),
           '⚪ ① 線上沒有 table_ok 通知可以試（行為測試那份會自己造）'),
  coalesce((select case when public._push_flex(s.id) ->> 'type' = 'flex'
                         and public._push_flex(s.id) #>> '{contents,type}' = 'bubble'
                         and public._push_flex(s.id) #>> '{contents,footer,contents,0,action,uri}' like 'https://liff.line.me/%'
                         and public._push_flex(s.id) ->> 'altText' like '%你的牌局湊滿了！%'
                        then '✅ ② 卡片版組得出來，通知那一行：' || (public._push_flex(s.id) ->> 'altText')
                        else '🔴 ② 卡片版缺東西' end from s), '⚪ ②'),
  coalesce((select case when jsonb_array_length(public._push_messages(s.id)) = 1
                         and public._push_messages(s.id) #>> '{0,type}' = 'text'
                        then '✅ ③ 預設只送文字版（1 個框）'
                        else '🔴 ③ 預設不是文字版：' || public._push_messages(s.id)::text end from s), '⚪ ③'),
  (select case when has_function_privilege('service_role', 'public.push_claim_tx(text,int)', 'execute')
                and not has_function_privilege('anon', 'public.push_claim_tx(text,int)', 'execute')
                and not has_function_privilege('authenticated', 'public.push_claim_tx(text,int)', 'execute')
                and public.push_claim_tx('不是那把鑰匙', 5) = '[]'::jsonb
               then '✅ ④ 取件仍只有 service_role 叫得動，鑰匙不對拿到空陣列'
               else '🔴 ④ 取件的授權或鑰匙檢查壞了' end),
  (select case when count(*) = 4
                and not bool_or(has_function_privilege('anon', p.oid, 'execute'))
                and not bool_or(has_function_privilege('authenticated', p.oid, 'execute'))
               then '✅ ⑤ 四支內部函式（fields／text／flex／messages）前端都叫不到'
               else '🔴 ⑤ 內部函式的授權不對' end
     from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('_push_fields', '_push_text', '_push_flex', '_push_messages'))
) as "驗證";
