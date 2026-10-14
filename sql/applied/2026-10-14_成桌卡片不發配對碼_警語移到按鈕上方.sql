-- ============================================================
-- 2026-10-14 LINE 成桌卡片：不再發手機配對碼；警語移到按鈕上方
-- ------------------------------------------------------------
-- 使用者：「LINE 成桌後不用再發配對碼」「LINE 成桌卡 把下面警語放到按鈕上方」
--
-- ① 拿掉成桌時發碼的觸發器 trg_app_notifications_phone_code ＋ 它的函式
--    ⇒ 之後的成桌通知都不會再產生配對碼。
--    手機計分改走另外三條路：會員 App「手機計分板」自己產生、後台發配對碼、平板「改用手機計分」。
--    ⚠ 已經發出去、還沒用的碼照樣有效（24 小時自己過期），這裡不作廢。
-- ② _push_fields：拿掉 phone_code（沒有東西會再發，留著就是一個永遠 null 的欄位）
-- ③ _push_flex：
--    · 配對碼那一塊（分隔線＋粉框）拿掉
--    · 「智慧計分板」按鈕一律開 table.migi.tw（原本沒配對過的人網址帶碼）
--    · 「請準時到店切勿遲到…」從按鈕下面搬到按鈕上面（footer 第一列）
-- 其餘（標題、開打時間、細項、按鈕樣式）一字不改，照線上版（10-14 撈的 pg_get_functiondef）。
-- 兩支都是 CREATE OR REPLACE、簽名不變 ⇒ 授權不會掉。
-- ============================================================

drop trigger if exists trg_app_notifications_phone_code on public.app_notifications;
drop function if exists public._tbl_phone_code_on_table_ok();

CREATE OR REPLACE FUNCTION public._push_fields(p_notif uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- 手機計分配對碼 2026-10-14 起成桌不再發（使用者），這裡不再回傳
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
end $function$;

CREATE OR REPLACE FUNCTION public._push_flex(p_notif uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
        || coalesce((f ->> 'name') || '，', '') || '你的牌局成桌了！'
        || (f ->> 'short') || coalesce(' · ' || (f ->> 'table') || ' 桌', '');

  return jsonb_build_object(
    'type', 'flex',
    'altText', left(v_alt, 400),
    'contents', jsonb_build_object(
      'type', 'bubble', 'size', 'kilo',   -- 2026-10-07 使用者：比預設（mega，幾乎滿版）小一號，約 260 點寬
      'header', jsonb_build_object(
        'type', 'box', 'layout', 'vertical', 'backgroundColor', '#FAD6DC', 'paddingAll', '14px',
        'contents', jsonb_build_array(
          jsonb_build_object('type', 'text', 'text', 'MIGI 咪吉麻將', 'size', 'lg', 'weight', 'bold',
                             'color', '#2E2B2C', 'align', 'center'))
          || case when (f ->> 'test')::boolean
                  then jsonb_build_array(jsonb_build_object('type', 'text', 'text', '推播測試', 'size', 'xxs',
                                                            'color', '#2E2B2C', 'align', 'center'))
                  else '[]'::jsonb end),
      -- 下邊距 6（原本 18）：按鈕往上移（2026-10-13 使用者）
      -- 手機計分配對碼那一塊 2026-10-14 拿掉（成桌不再發碼，使用者）
      'body', jsonb_build_object('type', 'box', 'layout', 'vertical',
        'paddingTop', '18px', 'paddingStart', '18px', 'paddingEnd', '18px', 'paddingBottom', '6px',
        'contents', jsonb_build_array(
          -- 開頭一行小字（2026-10-07 使用者看過實機後改回這一版）
          jsonb_build_object('type', 'text', 'text', coalesce((f ->> 'name') || '，', '') || '你的牌局成桌了！',
                             'size', 'sm', 'color', '#2E2B2C', 'wrap', true),
          jsonb_build_object('type', 'text', 'text', '開打時間', 'size', 'xs', 'color', '#8B8582', 'margin', 'lg'),
          jsonb_build_object('type', 'text', 'text', f ->> 'short', 'size', 'xxl', 'weight', 'bold',
                             'color', '#2E2B2C', 'margin', 'xs'),
          jsonb_build_object('type', 'separator', 'margin', 'lg', 'color', '#DED9D5'),
          jsonb_build_object('type', 'box', 'layout', 'vertical', 'spacing', 'sm', 'margin', 'lg',
                             'contents', coalesce(v_rows, '[]'::jsonb)))),
      -- 2026-10-14 使用者：警語放到按鈕上方 ⇒ footer 第一列是警語，下面才是兩顆按鈕
      -- 按鈕：白框「查看牌局詳情」＋ 黑底白字「智慧計分板」（2026-10-13 使用者）
      --   ⚠ LINE 的按鈕元件沒有外框樣式、字級也不能調 ⇒ 兩顆都用「框 ＋ 動作」做，字一樣大
      --   「智慧計分板」一律開計分板本身（2026-10-14 起成桌不發碼，網址不再帶碼）
      --   ⚠ iPhone 從 LINE 點出去一律開在 Safari，跟主畫面那個是分開的 ⇒ 主畫面配對過的 iPhone 在這裡仍然會看到教學；
      --     Android 瀏覽器與主畫面共用，配對過就直接進計分板
      'footer', jsonb_build_object('type', 'box', 'layout', 'vertical', 'spacing', 'sm',
        'paddingTop', '4px', 'paddingStart', '12px', 'paddingEnd', '12px', 'paddingBottom', '12px',
        'contents', jsonb_build_array(
          jsonb_build_object('type', 'text', 'text', '請準時到店切勿遲到，本場所禁止賭博或任何非法行為。',
                             'size', 'xs', 'color', '#8B8582', 'wrap', true, 'align', 'center'),
          jsonb_build_object('type', 'box', 'layout', 'vertical', 'borderWidth', 'normal', 'borderColor', '#DED9D5',
            'cornerRadius', 'md', 'paddingAll', '9px', 'margin', 'md',
            'action', jsonb_build_object('type', 'uri', 'label', '查看牌局詳情', 'uri', f ->> 'url'),
            'contents', jsonb_build_array(
              jsonb_build_object('type', 'text', 'text', '查看牌局詳情', 'size', 'sm', 'weight', 'bold',
                                 'color', '#2E2B2C', 'align', 'center'))),
          jsonb_build_object('type', 'box', 'layout', 'vertical', 'backgroundColor', '#2E2B2C',
            'borderWidth', 'normal', 'borderColor', '#2E2B2C', 'cornerRadius', 'md', 'paddingAll', '9px',
            'action', jsonb_build_object('type', 'uri', 'label', '智慧計分板',
                                         'uri', 'https://table.migi.tw/?openExternalBrowser=1'),
            'contents', jsonb_build_array(
              jsonb_build_object('type', 'text', 'text', '智慧計分板', 'size', 'sm', 'weight', 'bold',
                                 'color', '#FFFFFF', 'align', 'center')))))));
end $function$;

-- ============================================================
-- 驗證（單一 SELECT；不 raise，硬規則 1.8）
-- 樣本：最近一則成桌通知（e4b88f0f…，10-14 查的；只讀不寫）
-- ============================================================
with f as (select public._push_flex((select id from app_notifications where type = 'table_ok' order by created_at desc limit 1)) j),
ft as (select j #> '{contents,footer,contents}' c from f)
select
  case when not exists (select 1 from pg_trigger where tgname = 'trg_app_notifications_phone_code')
       then '✅' else '🔴' end || ' ① 成桌發碼的觸發器已拿掉' as "①",
  case when to_regprocedure('public._tbl_phone_code_on_table_ok()') is null
       then '✅' else '🔴' end || ' ② 發碼函式已刪' as "②",
  case when (select j from f) is not null and (select j::text from f) not like '%手機計分配對碼%'
            and (select j::text from f) not like '%install=1%'
       then '✅' else '🔴' end || ' ③ 卡片產生得出來、沒有配對碼也沒有帶碼網址' as "③",
  case when (select c -> 0 ->> 'text' from ft) like '請準時到店%'
            and (select c -> 1 #>> '{action,label}' from ft) = '查看牌局詳情'
            and (select c -> 2 #>> '{action,label}' from ft) = '智慧計分板'
       then '✅' else '🔴 footer 順序：' || coalesce((select c::text from ft), 'null') end || ' ④ 警語在兩顆按鈕上方' as "④",
  case when (select c -> 2 #>> '{action,uri}' from ft) = 'https://table.migi.tw/?openExternalBrowser=1'
       then '✅' else '🔴' end || ' ⑤ 智慧計分板開計分板本身' as "⑤",
  case when not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and prokind = 'f'
                          and proname in ('_push_fields', '_push_flex') and pg_get_functiondef(oid) like '%''phone_code''%')
       then '✅' else '🔴' end || ' ⑥ 兩支推播函式都不再讀配對碼' as "⑥";
