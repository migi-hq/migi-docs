-- ============================================================
-- 成桌 LINE 卡片：「智慧計分板」字縮小跟「查看牌局詳情」一樣、按鈕整體往上移
-- 2026-10-13 · MIGI 咪吉麻將
--
-- 使用者（看過 LINE 實機的測試卡片）：
--   「智慧記分板 文字縮小跟上面按鈕字一樣」「按鈕整體往上移動」
--
-- ① 字縮小：LINE 的按鈕元件字級固定、不能調 ⇒ 改成跟白框那顆同一種做法：
--   黑底的框 ＋ 動作，字 sm 粗體白色；外面加一圈同色邊，兩顆才一樣高（白框那顆有 1px 邊）。
-- ①b 同日使用者：「只有教學 沒有計分板網址連結」⇒ 黑底那顆改開計分板本身（不帶 install），教學頁只留給藍字連結。
-- ② 往上移：卡片中間的下邊距 18 → 6、按鈕區的上邊距 12 → 4（兩段加起來原本 30，現在 10）。
--   ⚠ 只指定 paddingAll 時上下左右一樣；要分開就四邊都寫，不混用 paddingAll。
--
-- 只改 _push_flex 一支（CREATE OR REPLACE，簽名不變 ⇒ 不用 DROP、GRANT 不會掉）。
-- 底稿是 applied/2026-10-13_成桌卡片報到提醒移到按鈕下面.sql（2026-10-13 跑完並查過線上）。
-- ============================================================

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
  v_code jsonb;
  v_link jsonb;
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

  -- 手機計分配對碼（2026-10-13）：還沒配對手機的人才有碼 ⇒ 分隔線 ＋ 粉色框；已經配對過的人沒有碼 ⇒ 都不畫
  v_code := case when f ->> 'phone_code' is null then '[]'::jsonb
    else jsonb_build_array(
      jsonb_build_object('type', 'separator', 'margin', 'lg', 'color', '#DED9D5'),
      jsonb_build_object('type', 'box', 'layout', 'vertical', 'margin', 'lg', 'paddingAll', '10px',
                         'backgroundColor', '#FFF6F8', 'cornerRadius', 'md',
        'contents', jsonb_build_array(
          jsonb_build_object('type', 'text', 'text', '手機計分配對碼', 'size', 'xs', 'color', '#8B8582'),
          -- 配對碼放大（使用者：這個放大），xl → 3xl
          jsonb_build_object('type', 'text', 'text', substr(f ->> 'phone_code', 1, 3) || ' ' || substr(f ->> 'phone_code', 4, 3),
                             'size', '3xl', 'weight', 'bold', 'color', '#2E2B2C', 'margin', 'xs'),
          jsonb_build_object('type', 'text', 'text', '打開手機主畫面的「MIGI 智慧計分板」輸入驗證', 'size', 'xxs',
                             'color', '#8B8582', 'wrap', true, 'margin', 'xs'))))
    end;

  -- 加到主畫面的藍字連結：跟配對碼同一個條件（未配對才有），放在按鈕區的最下面（2026-10-13 使用者）
  v_link := case when f ->> 'phone_code' is null then '[]'::jsonb
    else jsonb_build_array(
      jsonb_build_object('type', 'text', 'text', '第一次用？把計分板加到手機主畫面', 'size', 'xs',
                         'color', '#2A62C9', 'decoration', 'underline', 'align', 'center', 'margin', 'md',
                         'action', jsonb_build_object('type', 'uri', 'label', '加到主畫面',
                                                      'uri', 'https://table.migi.tw/?install=1&openExternalBrowser=1')))
    end;

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
                             'contents', coalesce(v_rows, '[]'::jsonb)))
          || v_code),
      -- 按鈕：白框「查看牌局詳情」＋ 黑底白字「智慧計分板」，下面接提醒，未配對的人最下面再接藍字連結（2026-10-13 使用者）
      --   ⚠ LINE 的按鈕元件沒有外框樣式、字級也不能調 ⇒ 兩顆都用「框 ＋ 動作」做，字一樣大
      --   「智慧計分板」開計分板本身（使用者：只有教學、沒有計分板網址）；教學頁只留給下面的藍字連結
      --   ⚠ iPhone 從 LINE 點出去一律開在 Safari，跟主畫面那個是分開的 ⇒ 主畫面配對過的 iPhone 在這裡仍然會看到教學；
      --     Android 瀏覽器與主畫面共用，配對過就直接進計分板
      --   上邊距 4（原本 12）：按鈕往上移
      'footer', jsonb_build_object('type', 'box', 'layout', 'vertical', 'spacing', 'sm',
        'paddingTop', '4px', 'paddingStart', '12px', 'paddingEnd', '12px', 'paddingBottom', '12px',
        'contents', jsonb_build_array(
          jsonb_build_object('type', 'box', 'layout', 'vertical', 'borderWidth', 'normal', 'borderColor', '#DED9D5',
            'cornerRadius', 'md', 'paddingAll', '9px',
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
                                 'color', '#FFFFFF', 'align', 'center'))),
          jsonb_build_object('type', 'text', 'text', '請準時到店切勿遲到，本場所禁止賭博或任何非法行為。',
                             'size', 'xs', 'color', '#8B8582', 'wrap', true, 'align', 'center', 'margin', 'md'))
          || v_link)));
end $function$;


-- ============================================================
-- 驗證（單一 SELECT，不 raise —— 硬規則 1.8）
--   ① 版本數 1
--   ② 全文已經沒有 LINE 的按鈕元件（舊版有一個，會紅 —— 正對照）
--   ③ 拿線上最近一則成桌通知組卡片：按鈕區前兩樣都是框、字級都是 sm、第二顆白字黑底
--   ④ 同一張卡片：卡片中間下邊距 6、按鈕區上邊距 4
--   ③④ 線上沒有成桌通知時印 ⚪（測不了，不是通過）
-- ============================================================
with d as (
  select pg_get_functiondef('public._push_flex'::regproc) as def
), c as (
  select public._push_flex(n.id) -> 'contents' as a
    from app_notifications n
   where n.type = 'table_ok' and public._push_fields(n.id) is not null
   order by n.created_at desc limit 1
)
select concat_ws(E'\n',
  case when (select count(*) from pg_proc where proname = '_push_flex' and pronamespace = 'public'::regnamespace) = 1
       then '① ✅ 版本數 1' else '① 🔴 版本數不是 1' end,
  case when (select strpos(def, '''type'', ''button''') = 0 from d)
       then '② ✅ 已經沒有 LINE 按鈕元件（兩顆都是框）'
       else '② 🔴 還有 LINE 按鈕元件' end,
  coalesce((select case
      when a -> 'footer' -> 'contents' -> 0 ->> 'type' = 'box'
       and a -> 'footer' -> 'contents' -> 1 ->> 'type' = 'box'
       and a -> 'footer' -> 'contents' -> 0 -> 'contents' -> 0 ->> 'size' = 'sm'
       and a -> 'footer' -> 'contents' -> 1 -> 'contents' -> 0 ->> 'size' = 'sm'
       and a -> 'footer' -> 'contents' -> 1 -> 'contents' -> 0 ->> 'text' = '智慧計分板'
       and a -> 'footer' -> 'contents' -> 1 -> 'contents' -> 0 ->> 'color' = '#FFFFFF'
       and a -> 'footer' -> 'contents' -> 1 ->> 'backgroundColor' = '#2E2B2C'
       and a -> 'footer' -> 'contents' -> 1 -> 'action' ->> 'uri' = 'https://table.migi.tw/?openExternalBrowser=1'
      then '③ ✅ 兩顆都是框、字一樣大（sm），智慧計分板黑底白字、開計分板本身（不是教學頁）'
      else '③ 🔴 按鈕不對：' || left((a -> 'footer' -> 'contents')::text, 300) end
    from c), '③ ⚪ 線上沒有成桌通知，這一格測不了'),
  coalesce((select case
      when a -> 'body' ->> 'paddingBottom' = '6px' and a -> 'footer' ->> 'paddingTop' = '4px'
       and a -> 'body' ->> 'paddingAll' is null and a -> 'footer' ->> 'paddingAll' is null
      then '④ ✅ 卡片中間下邊距 6、按鈕區上邊距 4'
      else '④ 🔴 邊距不對' end
    from c), '④ ⚪ 線上沒有成桌通知，這一格測不了')
) as "驗證";
