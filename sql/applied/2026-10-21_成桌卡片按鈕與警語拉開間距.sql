/* ============================================================
   成桌卡片：「查看牌局詳情」按鈕跟上面的警語拉開距離（2026-10-21 使用者）
   ------------------------------------------------------------
   使用者：「查看牌局詳情按鈕跟上面的提示文字要有空間」。
   只改一處：按鈕那個 box 的 margin 'md'（8px）→ 'xl'（16px）。其餘逐字照線上版（_push_flex 簽名不變 ⇒ 授權不會掉）。
   LINE Flex 的 margin：none 0 · xs 2 · sm 4 · md 8 · lg 12 · xl 16 · xxl 20（px）。
   ============================================================ */
create or replace function public._push_flex(p_notif uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
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
      -- 2026-10-14 使用者：警語放到按鈕上方 ⇒ footer 第一列是警語，下面才是按鈕
      -- 🆕 2026-10-20 使用者：「查看牌局詳情」改黑底白字（原本白底灰框墨字），跟牌局結束卡那顆同一個墨色
      --   ⚠ LINE 的按鈕元件字級不能調 ⇒ 維持「框 ＋ 動作」的做法，只換顏色
      --   🗑 「智慧計分板」那顆 2026-10-14 晚拿掉（使用者：成桌卡片不放計分板入口；手機計分一律從會員 App「手機計分板」設定）
      'footer', jsonb_build_object('type', 'box', 'layout', 'vertical', 'spacing', 'sm',
        'paddingTop', '4px', 'paddingStart', '12px', 'paddingEnd', '12px', 'paddingBottom', '12px',
        'contents', jsonb_build_array(
          -- 2026-10-14 使用者：警語上面加一條灰色分隔線（跟卡片裡其他分隔線同一個顏色）
          jsonb_build_object('type', 'separator', 'color', '#DED9D5'),
          jsonb_build_object('type', 'text', 'text', '請準時到店切勿遲到，本場所禁止賭博或任何非法行為。', 'margin', 'md',
                             'size', 'xs', 'color', '#8B8582', 'wrap', true, 'align', 'center'),
          -- 🆕 2026-10-21 使用者：按鈕跟上面的警語要有空間 ⇒ margin md（8px）→ xl（16px）
          jsonb_build_object('type', 'box', 'layout', 'vertical', 'backgroundColor', '#2E2B2C',
            'cornerRadius', 'md', 'paddingAll', '9px', 'margin', 'xl',
            'action', jsonb_build_object('type', 'uri', 'label', '查看牌局詳情', 'uri', f ->> 'url'),
            'contents', jsonb_build_array(
              jsonb_build_object('type', 'text', 'text', '查看牌局詳情', 'size', 'sm', 'weight', 'bold',
                                 'color', '#FFFFFF', 'align', 'center')))))));
end $function$;


/* ── 驗證（單一 SELECT，不 raise）：拿最近一則成桌通知實際組一張卡 ──────── */
with n as (
  select id from app_notifications where type = 'table_ok' order by created_at desc limit 1
), c as (
  select public._push_flex(n.id) as card from n
)
select
  (select case when count(*) = 1 then '✅ ① _push_flex 只有一個版本' else '🔴 ① 版本數 ' || count(*) end
     from pg_proc where pronamespace = 'public'::regnamespace and proname = '_push_flex') || E'\n' ||
  coalesce((select case when card is null then '🔴 ② 最近一則成桌通知組不出卡片'
                        else '✅ ② 最近一則成桌通知組得出卡片' end from c), '⚪ ② 沒有成桌通知可以試') || E'\n' ||
  coalesce((select case when card #>> '{contents,footer,contents,2,margin}' = 'xl'
                         and card #>> '{contents,footer,contents,2,contents,0,text}' = '查看牌局詳情'
                        then '✅ ③ 「查看牌局詳情」按鈕上方間距是 xl（16px）'
                        else '🔴 ③ 按鈕間距是 ' || coalesce(card #>> '{contents,footer,contents,2,margin}', '（沒有）') end
              from c), '⚪ ③ 沒有成桌通知可以試') || E'\n' ||
  coalesce((select case when card #>> '{contents,footer,contents,1,text}' like '請準時到店%'
                        then '✅ ④ 警語還在按鈕上面' else '🔴 ④ 警語不見了或位置變了' end from c), '⚪ ④ 沒有成桌通知可以試')
  as "驗證";
