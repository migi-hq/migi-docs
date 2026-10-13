-- ============================================================
-- 成桌 LINE 卡片：拿掉「第一次用？把計分板加到手機主畫面」那一行藍字連結
-- 2026-10-13 · MIGI 咪吉麻將
--
-- 使用者：「第一次用？把計分板加到手機主畫面 這句刪除」
--   ⇒ 未配對的卡片按鈕區只剩：查看牌局詳情 → 智慧計分板 → 禁止賭博那一行（跟已配對的一樣）。
--   配對碼的粉框照舊（還沒配對手機的人才有）。
--
-- 只動 _push_flex 的三處（變數宣告、組連結那一段、按鈕區接上它的那一行），其餘一個字都不改。
-- 底稿是線上版本（= applied/2026-10-13_成桌卡片智慧計分板字縮小按鈕上移.sql）；
-- 任一處對不上就整份回滾，不會改到一半。
-- ============================================================

do $$
declare
  v_def text := replace(pg_get_functiondef('public._push_flex'::regproc), E'\r\n', E'\n');   -- 換行先統一
  v_decl text := $a$  v_link jsonb;
$a$;
  v_block text := $b$  -- 加到主畫面的藍字連結：跟配對碼同一個條件（未配對才有），放在按鈕區的最下面（2026-10-13 使用者）
  v_link := case when f ->> 'phone_code' is null then '[]'::jsonb
    else jsonb_build_array(
      jsonb_build_object('type', 'text', 'text', '第一次用？把計分板加到手機主畫面', 'size', 'xs',
                         'color', '#2A62C9', 'decoration', 'underline', 'align', 'center', 'margin', 'md',
                         'action', jsonb_build_object('type', 'uri', 'label', '加到主畫面',
                                                      'uri', 'https://table.migi.tw/?install=1&openExternalBrowser=1')))
    end;

$b$;
  v_tail_old text := $c$
          || v_link)));$c$;
  v_tail_new text := $d$)));$d$;
  n1 int; n2 int; n3 int;
begin
  n1 := (length(v_def) - length(replace(v_def, v_decl, ''))) / length(v_decl);
  n2 := (length(v_def) - length(replace(v_def, v_block, ''))) / length(v_block);
  n3 := (length(v_def) - length(replace(v_def, v_tail_old, ''))) / length(v_tail_old);
  if n1 <> 1 or n2 <> 1 or n3 <> 1 then
    raise exception '_push_flex 對不上（宣告 % 處、連結 % 處、接上 % 處），整份不執行', n1, n2, n3;   -- 守衛：寧可回滾也不要改到一半
  end if;
  execute replace(replace(replace(v_def, v_decl, ''), v_block, ''), v_tail_old, v_tail_new);
end $$;


-- ============================================================
-- 驗證（單一 SELECT，不 raise —— 硬規則 1.8）
--   ① 版本數 1
--   ② 全文已經沒有那一行連結、也沒有 v_link（舊版會紅 —— 正對照）
--   ③ 配對碼粉框還在（沒有誤刪）
--   ④ 拿線上最近一則成桌通知組卡片：按鈕區 3 樣（兩顆按鈕 ＋ 提醒），整張卡片沒有「加到主畫面」
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
  case when (select strpos(def, '第一次用？') = 0 and strpos(def, 'v_link') = 0 from d)
       then '② ✅ 那一行連結已經拿掉'
       else '② 🔴 連結還在' end,
  case when (select strpos(def, '手機計分配對碼') > 0 and strpos(def, '輸入驗證') > 0 from d)
       then '③ ✅ 配對碼粉框還在'
       else '③ 🔴 配對碼粉框不見了' end,
  coalesce((select case
      when jsonb_array_length(a -> 'footer' -> 'contents') = 3
       and a::text not like '%加到主畫面%'
      then '④ ✅ 按鈕區 = 兩顆按鈕 ＋ 提醒，卡片上沒有加到主畫面的連結'
      else '④ 🔴 卡片不對：' || left((a -> 'footer' -> 'contents')::text, 300) end
    from c), '④ ⚪ 線上沒有成桌通知，這一格測不了')
) as "驗證";
