-- ════════════════════════════════════════════════════════════════════
-- 2026-10-20 LINE 成桌卡片：「查看牌局詳情」改黑底白字
-- ────────────────────────────────────────────────────────────────────
-- 使用者：「LINE 結算卡的查看牌局按鈕改黑底白字」
-- · 名字是「查看牌局」的按鈕只有一顆，在成桌卡（配桌湊滿，_push_flex）上；原本白底、灰框、墨字
-- · 牌局結束卡（_push_settle_flex）的「查看成績」本來就是黑底白字，這份不動
-- 改法：那一格的框換成墨色底（#2E2B2C，同牌局結束卡那顆）、字改白、拿掉灰框；大小、位置、連結都不變
-- ⚠ LINE 的按鈕元件字級不能調，所以維持「框 ＋ 動作」的做法（跟原本一樣），只換顏色
-- 簽名不變 ⇒ CREATE OR REPLACE，授權不會掉（只有 postgres／service_role）
-- ════════════════════════════════════════════════════════════════════

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
          jsonb_build_object('type', 'box', 'layout', 'vertical', 'backgroundColor', '#2E2B2C',
            'cornerRadius', 'md', 'paddingAll', '9px', 'margin', 'md',
            'action', jsonb_build_object('type', 'uri', 'label', '查看牌局詳情', 'uri', f ->> 'url'),
            'contents', jsonb_build_array(
              jsonb_build_object('type', 'text', 'text', '查看牌局詳情', 'size', 'sm', 'weight', 'bold',
                                 'color', '#FFFFFF', 'align', 'center')))))));
end $function$;

-- ── 驗證（單一 SELECT；不 raise，硬規則 1.8）──────────────────────────
with f as (
  select p.oid, p.proacl, pg_get_functiondef(p.oid) as d
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.proname = '_push_flex'
),
-- 拿最近一則成桌通知實際組一張卡，看按鈕那一格真的長什麼樣（沒有樣本就出聲，不安靜跳過）
s as (
  select c.card
    from (select public._push_flex(n.id) as card, n.created_at
            from app_notifications n
           where n.type = 'table_ok'
           order by n.created_at desc
           limit 20) c
   where c.card is not null
   order by c.created_at desc
   limit 1
),
btn as (
  select card #> '{contents,footer,contents,2}' as b from s
)
select concat_ws(E'\n',
  case when (select count(*) from f) = 1 then '✅ ① 只有一個版本' else '🔴 ① 版本數 ' || (select count(*) from f) end,
  coalesce((select case when b ->> 'backgroundColor' = '#2E2B2C' and b ->> 'borderWidth' is null
                        then '✅ ② 實際組出來的按鈕：墨色底、沒有灰框'
                        else '🔴 ② 按鈕那一格：' || b::text end from btn),
           '⚪ ② 找不到成桌通知可以組卡，這一格測不了'),
  coalesce((select case when b #>> '{contents,0,color}' = '#FFFFFF' and b #>> '{contents,0,text}' = '查看牌局詳情'
                        then '✅ ③ 按鈕字：白色「查看牌局詳情」'
                        else '🔴 ③ 按鈕字：' || (b -> 'contents')::text end from btn),
           '⚪ ③ 找不到成桌通知可以組卡，這一格測不了'),
  coalesce((select case when b #>> '{action,uri}' is not null then '✅ ④ 連結還在' else '🔴 ④ 連結不見了' end from btn),
           '⚪ ④ 找不到成桌通知可以組卡，這一格測不了'),
  case when not exists (select 1 from f, aclexplode(f.proacl) a
                         where a.grantee in (0, 'anon'::regrole::oid, 'authenticated'::regrole::oid) and a.privilege_type = 'EXECUTE')
       then '✅ ⑤ 前端叫不動（只有 postgres／service_role）' else '🔴 ⑤ 前端叫得動' end
) as "驗證";
