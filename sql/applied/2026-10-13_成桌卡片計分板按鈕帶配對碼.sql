-- ============================================================
-- 成桌 LINE 卡片：「智慧計分板」按鈕，對還沒配對過的人，網址直接帶他自己的配對碼
-- 2026-10-13 · MIGI 咪吉麻將
--
-- 使用者問「為什麼有的教學頁沒有碼、有的有」→「要」
--   教學頁自己不產生碼，只把網址裡帶來的碼印出來（「等一下要輸入的配對碼」）。
--   會員 App、後台、平板 QR 的連結都帶著碼；只有成桌卡片這顆按鈕是固定網址、不帶碼
--   ⇒ 從卡片來的客人看到沒有碼的教學頁，要自己回 LINE 看卡片上的數字。
--
-- 改法：卡片上有配對碼（還沒配對過手機的人）⇒ 按鈕網址帶 install=1&code=<他的碼>；
--   沒有碼（已經配對過）⇒ 照舊開計分板本身。openExternalBrowser=1 兩種都帶。
--   ⚠ Android 打開帶碼的網址會直接配好；iPhone 會到教學頁、碼印在最下面（主畫面打開後照著輸入）。
--
-- 只換 _push_flex 裡那一段網址（線上比對過剛好一處），其餘一個字都不改；對不上就整份不執行。
-- ============================================================

do $$
declare
  v_def text := replace(pg_get_functiondef('public._push_flex'::regproc), E'\r\n', E'\n');
  v_old text := $o$'uri', 'https://table.migi.tw/?openExternalBrowser=1'$o$;
  v_new text := $n$'uri', case when f ->> 'phone_code' is null then 'https://table.migi.tw/?openExternalBrowser=1'
                                       else 'https://table.migi.tw/?install=1&code=' || (f ->> 'phone_code') || '&openExternalBrowser=1' end$n$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception '_push_flex 的按鈕網址對不上，整份不執行';   -- 守衛：寧可回滾也不要改到一半
  end if;
  execute replace(v_def, v_old, v_new);
end $$;


-- ============================================================
-- 驗證（單一 SELECT，不 raise）
--   ① 版本數 1
--   ② 按鈕網址會帶配對碼（舊版會紅 —— 正對照）
--   ③ 拿線上最近一則「沒有有效配對碼」的成桌通知組卡片：按鈕照舊開計分板本身（負對照）
--   ④ 拿線上最近一則「有有效配對碼」的：按鈕網址帶的就是那組碼（線上沒有這種就印 ⚪）
-- ============================================================
with s as (
  select
    (select n.id from app_notifications n where n.type = 'table_ok'
        and not exists (select 1 from table_phone_codes pc where pc.notification_id = n.id and pc.used_at is null and pc.expires_at > now())
        and public._push_fields(n.id) is not null
      order by n.created_at desc limit 1) as no_code,
    (select n.id from app_notifications n where n.type = 'table_ok'
        and exists (select 1 from table_phone_codes pc where pc.notification_id = n.id and pc.used_at is null and pc.expires_at > now())
        and public._push_fields(n.id) is not null
      order by n.created_at desc limit 1) as with_code
)
select concat_ws(E'\n',
  case when (select count(*) from pg_proc where proname = '_push_flex' and pronamespace = 'public'::regnamespace) = 1
       then '① ✅ 版本數 1' else '① 🔴 版本數不是 1' end,
  case when (select pg_get_functiondef('public._push_flex'::regproc) ~ 'install=1&code=')
       then '② ✅ 按鈕網址會帶配對碼' else '② 🔴 沒改到' end,
  coalesce((select case when public._push_flex(s.no_code) -> 'contents' -> 'footer' -> 'contents' -> 1 -> 'action' ->> 'uri'
                              = 'https://table.migi.tw/?openExternalBrowser=1'
                        then '③ ✅ 沒有碼的卡片：按鈕照舊開計分板本身'
                        else '③ 🔴 沒有碼的卡片按鈕不對' end
              from s where s.no_code is not null), '③ ⚪ 線上沒有不帶碼的成桌通知，測不了'),
  coalesce((select case when public._push_flex(s.with_code) -> 'contents' -> 'footer' -> 'contents' -> 1 -> 'action' ->> 'uri'
                              = 'https://table.migi.tw/?install=1&code='
                                || (select pc.code from table_phone_codes pc where pc.notification_id = s.with_code and pc.used_at is null and pc.expires_at > now() limit 1)
                                || '&openExternalBrowser=1'
                        then '④ ✅ 有碼的卡片：按鈕網址帶的就是他那組碼'
                        else '④ 🔴 有碼的卡片按鈕不對' end
              from s where s.with_code is not null), '④ ⚪ 線上沒有帶有效配對碼的成桌通知，測不了')
) as "驗證";
