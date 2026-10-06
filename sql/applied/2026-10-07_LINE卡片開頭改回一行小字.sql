/* ============================================================
   LINE 卡片開頭改回一行小字（配桌湊滿、牌局結束）
   2026-10-07 · MIGI 咪吉麻將

   使用者看過實機之後要改回前一版：
     配桌湊滿   「阿明，你的牌局成桌了！」一行小字（不再另起一行大字；同日改字：原本「湊滿了」）
     牌局結束   「阿明，這場牌局結束了！」一行小字（同日再改：不用前一版的「牌局結束，辛苦了！」）
   手機通知列那一句（altText）與純文字版也一起改。
   ⚠ 拿不到名字時那一行就只剩後半句（一定有字，LINE 不收空白文字元件的問題不存在）。
   其餘內容（細項、按鈕、kilo 尺寸）一字不動 —— 從線上版本撈出來改的。
   四支都是 create or replace、簽名不變 ⇒ 授權不會掉。
   ============================================================ */

create or replace function public._push_text(p_notif uuid)
 returns text
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare f jsonb := _push_fields(p_notif);
begin
  if f is null then return null; end if;
  return concat_ws(E'\n',
    case when (f ->> 'test')::boolean then '【推播測試】' end,
    coalesce((f ->> 'name') || '，', '') || '你的牌局成桌了！',
    '時間：' || (f ->> 'when'),
    '地點：' || (f ->> 'place'),
    case when f ->> 'addr' is not null then '地址：' || (f ->> 'addr') end,
    case when f ->> 'game' is not null then '玩法：' || (f ->> 'game') end,
    case when f ->> 'stake_label' is not null then '積分：' || (f ->> 'stake_label') end,
    case when f ->> 'others' is not null then '同桌：' || (f ->> 'others') end,
    '請準時到店，到櫃檯報到就能入座。',
    '查看牌局詳情：' || (f ->> 'url'));
end $function$;

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
end $function$;

create or replace function public._push_settle_text(p_notif uuid)
 returns text
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare f jsonb := _push_settle_fields(p_notif);
begin
  if f is null then return null; end if;
  return concat_ws(E'\n',
    case when (f ->> 'test')::boolean then '【推播測試】' end,
    coalesce((f ->> 'name') || '，', '') || '這場牌局結束了！',
    '名次：第 ' || (f ->> 'rank_no') || ' 名',
    case when not (f ->> 'hyg')::boolean and f ->> 'score' is not null then '桌上積分：' || (f ->> 'score') end,
    case when f ->> 'rating' is not null then '段位分：' || (f ->> 'rating') end,
    case when f ->> 'tier'   is not null then '目前段位：' || (f ->> 'tier') end,
    '門市：' || (f ->> 'store'),
    case when f ->> 'table' is not null then '桌號：' || (f ->> 'table') || ' 桌' end,
    case when f ->> 'play'  is not null then '玩法：' || (f ->> 'play') end,
    case when f ->> 'stake_label' is not null then '積分：' || (f ->> 'stake_label') end,
    case when f ->> 'others'   is not null then '同桌：' || (f ->> 'others') end,
    case when f ->> 'duration' is not null then '花費時間：' || (f ->> 'duration') end,
    '想回顧這場？App 有每一局的紀錄。',
    '查看成績：' || (f ->> 'url'));
end $function$;

create or replace function public._push_settle_flex(p_notif uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  f jsonb := _push_settle_fields(p_notif);
  v_res jsonb;
  v_info jsonb;
  v_alt text;
begin
  if f is null then return null; end if;

  -- 一列「項目 → 內容」，沒有值的整列不畫；桌上積分與段位分的數字用粗體
  -- 第一段：這場的結果。純娛樂不畫「桌上積分」（下面「積分」那一列已經寫純娛樂）
  select jsonb_agg(jsonb_build_object('type', 'box', 'layout', 'baseline', 'spacing', 'md', 'contents', jsonb_build_array(
           jsonb_build_object('type', 'text', 'text', k, 'size', 'sm', 'color', '#8B8582', 'flex', 3),
           jsonb_build_object('type', 'text', 'text', v, 'size', 'sm', 'color', '#2E2B2C', 'wrap', true, 'flex', 7,
                              'weight', case when bold then 'bold' else 'regular' end)))
         order by o)
    into v_res
    from (values (1, '桌上積分', case when (f ->> 'hyg')::boolean then null else f ->> 'score' end, true),
                 (2, '段位分',   f ->> 'rating', (f ->> 'rating') ~ '^[+−0-9]'),
                 (3, '目前段位', f ->> 'tier',   false)) t(o, k, v, bold)
   where v is not null;
  -- 第二段：這場牌局
  select jsonb_agg(jsonb_build_object('type', 'box', 'layout', 'baseline', 'spacing', 'md', 'contents', jsonb_build_array(
           jsonb_build_object('type', 'text', 'text', k, 'size', 'sm', 'color', '#8B8582', 'flex', 3),
           jsonb_build_object('type', 'text', 'text', v, 'size', 'sm', 'color', '#2E2B2C', 'wrap', true, 'flex', 7)))
         order by o)
    into v_info
    from (values (1, '門市',     f ->> 'store'),
                 (2, '桌號',     (f ->> 'table') || ' 桌'),
                 (3, '玩法',     f ->> 'play'),
                 (4, '積分',     f ->> 'stake_label'),
                 (5, '同桌',     f ->> 'others'),
                 (6, '花費時間', f ->> 'duration')) t(o, k, v)
   where v is not null;

  -- 手機通知與聊天列表只看得到這一句
  v_alt := case when (f ->> 'test')::boolean then '【推播測試】' else '' end
        || coalesce((f ->> 'name') || '，', '') || '牌局結束！第 ' || (f ->> 'rank_no') || ' 名'
        || coalesce(' · 段位分 ' || (f ->> 'rating_short'), '');

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
          jsonb_build_object('type', 'text', 'text', coalesce((f ->> 'name') || '，', '') || '這場牌局結束了！',
                             'size', 'sm', 'color', '#2E2B2C', 'wrap', true),
          jsonb_build_object('type', 'text', 'text', '本場名次', 'size', 'xs', 'color', '#8B8582', 'margin', 'lg'),
          jsonb_build_object('type', 'text', 'text', '第 ' || (f ->> 'rank_no') || ' 名', 'size', 'xxl', 'weight', 'bold',
                             'color', '#2E2B2C', 'margin', 'xs'),
          jsonb_build_object('type', 'separator', 'margin', 'lg', 'color', '#DED9D5'),
          jsonb_build_object('type', 'box', 'layout', 'vertical', 'spacing', 'sm', 'margin', 'lg',
                             'contents', coalesce(v_res, '[]'::jsonb)),
          jsonb_build_object('type', 'separator', 'margin', 'lg', 'color', '#DED9D5'),
          jsonb_build_object('type', 'box', 'layout', 'vertical', 'spacing', 'sm', 'margin', 'lg',
                             'contents', coalesce(v_info, '[]'::jsonb)),
          jsonb_build_object('type', 'separator', 'margin', 'lg', 'color', '#DED9D5'),
          jsonb_build_object('type', 'text', 'text', '想回顧這場？App 有每一局的紀錄。',
                             'size', 'xs', 'color', '#8B8582', 'wrap', true, 'margin', 'lg'))),
      'footer', jsonb_build_object('type', 'box', 'layout', 'vertical', 'paddingAll', '12px',
        'contents', jsonb_build_array(
          jsonb_build_object('type', 'button', 'style', 'primary', 'color', '#2E2B2C', 'height', 'sm',
            'action', jsonb_build_object('type', 'uri', 'label', '查看成績', 'uri', f ->> 'url'))))));
end $function$;

-- ── 驗證（單一 SELECT）：拿剛剛兩則測試通知實際組一次卡片 ─────────────
--   樣本：配桌 2c6ed8bb…、牌局結束 0cc450ff…（2026-10-07 推播測試建的，都屬老闆）
--   每一格看「輸出」不看函式內文（硬規則 3.5）
with t as (
  select public._push_flex('2c6ed8bb-5aa9-4179-9d80-5f06a85d5695')        as tf,
         public._push_text('2c6ed8bb-5aa9-4179-9d80-5f06a85d5695')        as tt,
         public._push_settle_flex('0cc450ff-f963-4cf2-b85c-7adeae988b15') as sf,
         public._push_settle_text('0cc450ff-f963-4cf2-b85c-7adeae988b15') as st
)
select concat_ws(E'\n',
  case when tf is null then '🔴 ① 配桌卡片組不出來（樣本可能不見了）'
       when tf #>> '{contents,body,contents,0,text}' like '%你的牌局成桌了！'
        and tf #>> '{contents,body,contents,0,size}' = 'sm'
        and tf #>> '{contents,body,contents,1,text}' = '開打時間'
       then '✅ ① 配桌卡片開頭：「' || (tf #>> '{contents,body,contents,0,text}') || '」一行小字，下一列就是開打時間'
       else '🔴 ① 配桌卡片開頭不對：' || coalesce(tf #>> '{contents,body,contents,0,text}', '（空）') end,
  case when tf ->> 'altText' like '%你的牌局成桌了！%' then '✅ ② 配桌通知列：' || (tf ->> 'altText')
       else '🔴 ② 配桌通知列：' || coalesce(tf ->> 'altText', '（空）') end,
  case when split_part(tt, E'\n', 2) like '%你的牌局成桌了！' then '✅ ③ 配桌純文字版第二行：' || split_part(tt, E'\n', 2)
       else '🔴 ③ 配桌純文字版：' || coalesce(split_part(tt, E'\n', 2), '（空）') end,
  case when sf is null then '🔴 ④ 結束卡片組不出來（樣本可能不見了）'
       when sf #>> '{contents,body,contents,0,text}' like '%這場牌局結束了！'
        and sf #>> '{contents,body,contents,0,size}' = 'sm'
        and sf #>> '{contents,body,contents,1,text}' = '本場名次'
       then '✅ ④ 結束卡片開頭：「' || (sf #>> '{contents,body,contents,0,text}') || '」一行小字，下一列就是本場名次'
       else '🔴 ④ 結束卡片開頭不對：' || coalesce(sf #>> '{contents,body,contents,0,text}', '（空）') end,
  case when sf ->> 'altText' like '%牌局結束！第 %' then '✅ ⑤ 結束通知列：' || (sf ->> 'altText')
       else '🔴 ⑤ 結束通知列：' || coalesce(sf ->> 'altText', '（空）') end,
  case when split_part(st, E'\n', 2) like '%這場牌局結束了！' then '✅ ⑥ 結束純文字版第二行：' || split_part(st, E'\n', 2)
       else '🔴 ⑥ 結束純文字版：' || coalesce(split_part(st, E'\n', 2), '（空）') end,
  case when tf #>> '{contents,size}' = 'kilo' and sf #>> '{contents,size}' = 'kilo'
        and tf #>> '{contents,footer,contents,0,action,data}' like 'attend:%'
       then '✅ ⑦ 沒動到的部分還在：兩張都是 kilo、配桌卡片的「確定會到」還在'
       else '🔴 ⑦ 尺寸或按鈕被動到了' end
) as "驗證"
from t;
