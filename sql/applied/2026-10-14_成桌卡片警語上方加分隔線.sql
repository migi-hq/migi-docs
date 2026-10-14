-- ============================================================
-- 2026-10-14 LINE 成桌卡片：警語上方加一條灰色分隔線
-- ------------------------------------------------------------
-- 使用者：「請準時到店切勿遲到，本場所禁止賭博或任何非法行為。成桌卡上面要有個灰色線」
-- 只改 _push_flex 的 footer：第一列加 separator（#DED9D5），警語往下推 md。
-- 其餘照線上版（就是 sql/applied/2026-10-14_成桌卡片不發配對碼_警語移到按鈕上方.sql 寫進去的那一份）一字不改。
-- 簽名不變 ⇒ CREATE OR REPLACE、授權不動。
-- ============================================================

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
          -- 2026-10-14 使用者：警語上面加一條灰色分隔線（跟卡片裡其他分隔線同一個顏色）
          jsonb_build_object('type', 'separator', 'color', '#DED9D5'),
          jsonb_build_object('type', 'text', 'text', '請準時到店切勿遲到，本場所禁止賭博或任何非法行為。', 'margin', 'md',
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
-- 驗證（單一 SELECT；不 raise，硬規則 1.8）：用最近一則成桌通知實際產生卡片
-- ============================================================
with f as (select public._push_flex((select id from app_notifications where type = 'table_ok' order by created_at desc limit 1)) j),
ft as (select j #> '{contents,footer,contents}' c from f)
select
  case when (select c -> 0 ->> 'type' from ft) = 'separator' and (select c -> 0 ->> 'color' from ft) = '#DED9D5'
       then '✅' else '🔴 footer 第一列：' || coalesce((select (c -> 0)::text from ft), 'null') end || ' ① 最上面是灰色分隔線' as "①",
  case when (select c -> 1 ->> 'text' from ft) like '請準時到店%' then '✅' else '🔴' end || ' ② 分隔線下面是警語' as "②",
  case when (select c -> 2 #>> '{action,label}' from ft) = '查看牌局詳情' and (select c -> 3 #>> '{action,label}' from ft) = '智慧計分板'
       then '✅' else '🔴' end || ' ③ 兩顆按鈕在警語下面' as "③",
  case when (select j::text from f) not like '%手機計分配對碼%' then '✅' else '🔴' end || ' ④ 仍然沒有配對碼' as "④";
