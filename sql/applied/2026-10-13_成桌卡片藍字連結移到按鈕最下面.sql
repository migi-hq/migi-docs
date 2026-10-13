-- ============================================================
-- 成桌 LINE 卡片：「第一次用？把計分板加到手機主畫面」搬到按鈕最下面
-- 2026-10-13 · MIGI 咪吉麻將
--
-- 使用者：「第一次用？把計分板加到手機主畫面 放到按鈕最下面」
--   前一份（applied/2026-10-13_成桌卡片配對碼放大與智慧計分板按鈕.sql）把它放在配對碼框的正下方；
--   這一份把它搬到「查看牌局詳情」「智慧計分板」兩顆按鈕的下面。
--
-- 規則不變：
--   · 還沒配對手機的人才有配對碼 ⇒ 才有配對碼框、才有這一行藍字連結
--   · 已經配對過的人兩樣都沒有，按鈕區只有那兩顆按鈕
--
-- 只改 _push_flex 一支（CREATE OR REPLACE，簽名不變 ⇒ 不用 DROP、GRANT 不會掉）。
-- 底稿是 2026-10-13 線上 pg_get_functiondef 撈出來的版本（md5 df4033b7…），只動兩處：
--   ① v_code 只剩配對碼框
--   ② 按鈕區在兩顆按鈕後面接上藍字連結（有配對碼才接）
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

  -- 手機計分配對碼（2026-10-13）：還沒配對手機的人才有碼 ⇒ 畫粉色框；已經配對過的人沒有碼 ⇒ 不畫
  v_code := case when f ->> 'phone_code' is null then '[]'::jsonb
    else jsonb_build_array(
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

  -- 加到主畫面的藍字連結：跟配對碼同一個條件（未配對才有），放在兩顆按鈕的最下面（2026-10-13 使用者）
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
      'body', jsonb_build_object('type', 'box', 'layout', 'vertical', 'paddingAll', '18px',
        'contents', jsonb_build_array(
          -- 開頭一行小字（2026-10-07 使用者看過實機後改回這一版）
          jsonb_build_object('type', 'text', 'text', coalesce((f ->> 'name') || '，', '') || '你的牌局成桌了！',
                             'size', 'sm', 'color', '#2E2B2C', 'wrap', true),
          jsonb_build_object('type', 'text', 'text', '開打時間', 'size', 'xs', 'color', '#8B8582', 'margin', 'lg'),
          jsonb_build_object('type', 'text', 'text', f ->> 'short', 'size', 'xxl', 'weight', 'bold',
                             'color', '#2E2B2C', 'margin', 'xs'),
          jsonb_build_object('type', 'separator', 'margin', 'lg', 'color', '#DED9D5'),
          jsonb_build_object('type', 'box', 'layout', 'vertical', 'spacing', 'sm', 'margin', 'lg',
                             'contents', coalesce(v_rows, '[]'::jsonb)),
          jsonb_build_object('type', 'separator', 'margin', 'lg', 'color', '#DED9D5'))
          || v_code
          || jsonb_build_array(
          jsonb_build_object('type', 'text', 'text', '請準時到店，到櫃檯報到就能入座。',
                             'size', 'xs', 'color', '#8B8582', 'wrap', true, 'margin', 'lg'))),
      -- 按鈕：白框「查看牌局詳情」＋ 黑底白字「智慧計分板」（2026-10-13 使用者），未配對的人最下面再接藍字連結
      --   ⚠ LINE 的按鈕沒有外框樣式，白框那顆用「有框的 box ＋ 動作」做
      --   「智慧計分板」開加到主畫面的教學頁
      'footer', jsonb_build_object('type', 'box', 'layout', 'vertical', 'paddingAll', '12px', 'spacing', 'sm',
        'contents', jsonb_build_array(
          jsonb_build_object('type', 'box', 'layout', 'vertical', 'borderWidth', 'normal', 'borderColor', '#DED9D5',
            'cornerRadius', 'md', 'paddingAll', '9px',
            'action', jsonb_build_object('type', 'uri', 'label', '查看牌局詳情', 'uri', f ->> 'url'),
            'contents', jsonb_build_array(
              jsonb_build_object('type', 'text', 'text', '查看牌局詳情', 'size', 'sm', 'weight', 'bold',
                                 'color', '#2E2B2C', 'align', 'center'))),
          jsonb_build_object('type', 'button', 'style', 'primary', 'color', '#2E2B2C', 'height', 'sm',
            'action', jsonb_build_object('type', 'uri', 'label', '智慧計分板',
                                         'uri', 'https://table.migi.tw/?install=1&openExternalBrowser=1')))
          || v_link)));
end $function$;


-- ============================================================
-- 驗證（單一 SELECT，不 raise —— 硬規則 1.8）
--   ① 版本數 1
--   ② 那一行藍字連結全文只出現一次（不會一邊在配對碼框下、一邊在按鈕下各一份）
--   ③ 它由按鈕區接上，不是卡片中間（舊版會紅 —— 正對照）
--   ④ 拿線上真的成桌通知試組卡片：有配對碼的 → 按鈕區 3 樣、最後一樣是藍字連結、卡片中間沒有它
--   ⑤ 沒有配對碼的 → 按鈕區只有 2 樣
--   ④⑤ 線上剛好沒有那一種通知時印 ⚪（測不了，不是通過）
-- ============================================================
with d as (
  select pg_get_functiondef('public._push_flex'::regproc) as def
), s as (
  select
    (select n.id from app_notifications n
      where n.type = 'table_ok'
        and exists (select 1 from table_phone_codes pc where pc.notification_id = n.id
                     and pc.used_at is null and pc.expires_at > now())
      order by n.created_at desc limit 1) as with_code,
    (select n.id from app_notifications n
      where n.type = 'table_ok'
        and not exists (select 1 from table_phone_codes pc where pc.notification_id = n.id
                         and pc.used_at is null and pc.expires_at > now())
        and public._push_fields(n.id) is not null
      order by n.created_at desc limit 1) as no_code
), c as (
  select
    public._push_flex(s.with_code) -> 'contents' as a,
    public._push_flex(s.no_code)   -> 'contents' as b
  from s
)
select concat_ws(E'\n',
  case when (select count(*) from pg_proc where proname = '_push_flex' and pronamespace = 'public'::regnamespace) = 1
       then '① ✅ 版本數 1' else '① 🔴 版本數不是 1' end,
  case when (select (length(def) - length(replace(def, '第一次用？把計分板加到手機主畫面', '')))
                    / length('第一次用？把計分板加到手機主畫面') from d) = 1
       then '② ✅ 藍字連結只有一份' else '② 🔴 藍字連結不是剛好一份' end,
  -- ③ 問「誰把它接上去」：按鈕區接 v_link、卡片中間不接（舊版是卡片中間接、按鈕區不接，這一格會紅）
  case when (select strpos(def, '|| v_link') > strpos(def, '''footer''')
                and strpos(def, '|| v_code') < strpos(def, '''footer''')
                and strpos(def, '第一次用？把計分板加到手機主畫面') > strpos(def, 'v_link :=') from d)
       then '③ ✅ 藍字連結由按鈕區接上，配對碼框仍在卡片中間'
       else '③ 🔴 位置不對' end,
  coalesce((select case
      when jsonb_array_length(a -> 'footer' -> 'contents') = 3
       and a -> 'footer' -> 'contents' -> 2 -> 'action' ->> 'label' = '加到主畫面'
       and (a -> 'body')::text not like '%加到主畫面%'
      then '④ ✅ 有配對碼：按鈕區 3 樣，最後一樣是藍字連結；卡片中間沒有它'
      else '④ 🔴 有配對碼的卡片按鈕區不對：' || (a -> 'footer' -> 'contents')::text end
    from c where a is not null), '④ ⚪ 線上沒有帶有效配對碼的成桌通知，這一格測不了'),
  coalesce((select case
      when jsonb_array_length(b -> 'footer' -> 'contents') = 2
       and b::text not like '%加到主畫面%'
      then '⑤ ✅ 沒有配對碼：按鈕區只有 2 顆按鈕'
      else '⑤ 🔴 沒有配對碼的卡片還有藍字連結或按鈕數不對' end
    from c where b is not null), '⑤ ⚪ 線上沒有不帶配對碼的成桌通知，這一格測不了')
) as "驗證";
