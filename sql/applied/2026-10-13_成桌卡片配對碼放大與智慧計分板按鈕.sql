-- 2026-10-13 成桌 LINE 卡片（_push_flex）三處改動（使用者）
--   ① 配對碼放大（xl → 3xl），下面那行改成「打開手機主畫面的「MIGI 智慧計分板」輸入驗證」
--   ② 沒有配對碼時，原本那一行「手機計分：配對碼已用過……」拿掉（粉色框也不畫）
--   ③ 最下面按鈕區原本那行藍字連結搬到配對碼框下面（只有未配對、有碼的人看得到；使用者：未配對才要那一行），
--      按鈕區改在「查看牌局詳情」下面加一顆黑底白字的「智慧計分板」，連結同一個（加到主畫面的教學頁，用外部瀏覽器開）
--      ⚠ 跑完之後使用者又要「藍字連結放到按鈕最下面」→ 另一份 2026-10-13_成桌卡片藍字連結移到按鈕最下面.sql
--   ⑤ 「確定會到」按鈕與整個出席回報機制拿掉：卡片按鈕、line_attend_confirm_tx、
--      match_queue_players.attend_confirmed_at、POS 配桌列表回的 attend_confirmed（前端與 line-webhook 同日改）
--      ⚠ 已經送出的舊卡片上那顆按鈕還在，按了不會有任何反應（line-webhook 重新部署後就不處理了）
--
--   ④ 已經配對過手機的客人，成桌時不再發配對碼（_tbl_phone_code_on_table_ok）
--      在此之前每一則成桌通知都發一組新的，已配對的人也照樣收到一組用不到的碼；
--      改了之後「未配對 → 配對碼＋藍字連結／已配對 → 兩樣都不畫」才成立（使用者 10-13 要的兩種樣子）。
--      「已配對」＝ 有一支還有效的手機綁在他身上（kind = phone、沒停用、不是只限一場的那種）。
--      ⚠ 換新手機的人：舊那支在後台停用之後，下一次成桌就會再拿到碼；或在平板按「改用手機計分」當場拿一組。
--
-- · _push_flex 與觸發器函式簽名都不變 ⇒ CREATE OR REPLACE，不掉授權。
-- · 以 2026-10-13 線上版本為底（pg_get_functiondef 撈出，md5 d59f570b…），其餘一字未動。
-- · 已經送出的卡片不會變（LINE 卡片送出就固定了），下一張成桌卡片起生效。

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

  -- 手機計分配對碼（2026-10-13）：還沒配對手機的人才有碼 ⇒ 畫粉色框，下面接一行藍字連結到加到主畫面的教學頁；
  -- 已經配對過的人沒有碼 ⇒ 兩樣都不畫（使用者：未配對才要那一行）
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
                             'color', '#8B8582', 'wrap', true, 'margin', 'xs'))),
      jsonb_build_object('type', 'text', 'text', '第一次用？把計分板加到手機主畫面', 'size', 'xs',
                         'color', '#2A62C9', 'decoration', 'underline', 'margin', 'md',
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
      -- 按鈕：白框「查看牌局詳情」＋ 黑底白字「智慧計分板」（2026-10-13 使用者）
      --   出席回報那顆按鈕與它背後的機制同日整個拿掉（使用者）
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
                                         'uri', 'https://table.migi.tw/?install=1&openExternalBrowser=1'))))));
end $function$;

-- ④ 成桌時發配對碼：已經有一支綁好手機的客人跳過
create or replace function public._tbl_phone_code_on_table_ok()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if new.type = 'table_ok' and new.member_id is not null
     -- 已經配對過手機的人不再發碼（卡片上配對碼與加到主畫面的連結都不畫）；只限一場的手機（平板發碼）不算
     and not exists (select 1 from table_devices d
                      where d.kind = 'phone' and d.member_id = new.member_id
                        and d.is_active and d.revoked_at is null and d.bound_session_id is null) then
    perform public._tbl_new_phone_code(new.org_id, new.member_id, null, new.id, null, now() + interval '24 hours');
  end if;
  return null;
end $function$;

-- ⑤ 出席回報機制整個拿掉（2026-10-13 使用者：「確定會到」按鈕與整個機制刪除）
--   a. POS 配桌列表不再回 attend_confirmed（POS 座位卡那顆膠囊同日已從前端拿掉）
--      只刪那一行與它上面的說明，其餘一字不動；刪不到就整份停下（不提交半套）
do $$
declare
  v_old text := pg_get_functiondef('public.pos_list_queues_tx_core'::regproc);
  v_new text;
begin
  v_new := regexp_replace(v_old,
    '[ \t]*/\*[^\n]*2026-10-07[^\n]*\n[ \t]*''attend_confirmed'', p\.attend_confirmed_at is not null,\r?\n', '');
  if v_new = v_old or v_new ~ 'attend' then
    raise exception '🔴 pos_list_queues_tx_core 沒有刪乾淨，整份停下（沒有任何東西被改）';
  end if;
  execute v_new;
end $$;

--   b. 處理按鈕的函式（只給 line-webhook 用，沒有其他函式叫它）
drop function if exists public.line_attend_confirm_tx(text, uuid);

--   c. 記確認時間的欄位（2026-10-13 有 6 列有值，一起清掉；沒有檢視表用到它）
alter table public.match_queue_players drop column if exists attend_confirmed_at;

-- ── 驗證（單一 SELECT，不用 raise）────────────────────────────
-- 拿線上最近一則成桌通知組一張卡片，看結構對不對（讀取而已，不會送出）。
-- ① 配對碼字級是 3xl、說明文字換成新的（有碼時）
-- ② 「配對碼已用過」那一行全庫函式裡已經不存在
-- ③ 藍字連結只剩一處（有配對碼那一支，接在配對碼框下面）
-- ④ 按鈕依序是：查看牌局詳情 → 智慧計分板（出席回報那顆已拿掉）
-- ⑤ 已配對過手機的人成桌時不再發碼
-- ⑥⑦⑧⑨ 出席回報機制拆乾淨了（POS 那支、處理函式、欄位、全庫沒有殘留）
with n as (
  select id from public.app_notifications where type = 'table_ok' order by created_at desc limit 1
), c as (
  select public._push_flex(n.id) as j from n
), d as (
  select pg_get_functiondef('public._push_flex'::regproc) as def
)
select
  case when not exists (select 1 from n) then '⚪ ① 沒有成桌通知可以拿來組卡片'
       when (select j from c) is null then '🔴 ① 卡片組不出來'
       else '✅ ① 卡片組得出來' end
  || E'\n' ||
  (select case when def ~ '''size'', ''3xl''' and def ~ 'MIGI 智慧計分板」輸入驗證' then '✅ ① 配對碼 3xl ＋ 新說明'
               else '🔴 ① 配對碼字級或說明沒換到' end from d)
  || E'\n' ||
  (select case when def !~ '配對碼已用過' then '✅ ② 「配對碼已用過」那一行已拿掉' else '🔴 ② 那一行還在' end from d)
  || E'\n' ||
  (select case when (length(def) - length(replace(def, '第一次用？', ''))) / length('第一次用？') = 1
               then '✅ ③ 藍字連結只剩一處（未配對、有配對碼時才出現）'
               else '🔴 ③ 藍字連結出現 ' || ((length(def) - length(replace(def, '第一次用？', ''))) / length('第一次用？')) || ' 處' end from d)
  || E'\n' ||
  (select case when pg_get_functiondef('public._tbl_phone_code_on_table_ok'::regproc) ~ 'd\.bound_session_id is null'
               then '✅ ⑤ 已配對過手機的人成桌時不再發碼' else '🔴 ⑤ 觸發器沒換到' end)
  || E'\n' ||
  (select case when pg_get_functiondef('public.pos_list_queues_tx_core'::regproc) !~ 'attend'
               then '✅ ⑥ POS 配桌列表不再回出席確認' else '🔴 ⑥ POS 那支還有出席確認' end)
  || E'\n' ||
  (select case when to_regprocedure('public.line_attend_confirm_tx(text, uuid)') is null
               then '✅ ⑦ 處理按鈕的函式已刪' else '🔴 ⑦ 函式還在' end)
  || E'\n' ||
  (select case when not exists (select 1 from information_schema.columns where table_schema = 'public'
                                 and table_name = 'match_queue_players' and column_name = 'attend_confirmed_at')
               then '✅ ⑧ 欄位已刪' else '🔴 ⑧ 欄位還在' end)
  || E'\n' ||
  (select case when count(*) = 0 then '✅ ⑨ 全庫已經沒有函式提到出席確認'
               else '🔴 ⑨ 還有：' || string_agg(p.proname, '、') end
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and pg_get_functiondef(p.oid) ~ 'attend_confirm')
  || E'\n④ 按鈕：' ||
  coalesce((select string_agg(coalesce(b -> 'action' ->> 'label', '?'), ' → ' order by o)
              from c, jsonb_array_elements(c.j -> 'contents' -> 'footer' -> 'contents') with ordinality as x(b, o)), '（組不出卡片，見 ①）')
  as "驗證";
