-- ============================================================
-- 管理後台「智慧計分板」：裝置的「出錯 N 次」排除兩種無害的回報
-- 2026-10-13 · MIGI 咪吉麻將
--
-- 使用者看後台截圖：客人的手機幾乎每一支都是「異常 · 出錯 15／19／21 次」。查 app_events（近 6 小時）：
--   · 「ResizeObserver loop completed with undelivered notifications」70 次 —— 瀏覽器的無害警告（量尺寸多跑一輪，畫面正常）
--   · 「螢幕常亮要求被拒絕」11 次 —— 手機系統不讓網頁常亮（省電模式、iPhone 限制），常亮本來就是給平板的
--   ⇒ 沒有一筆是真的故障，卻讓每支手機都標成異常，真的出事時反而看不出來。
--
-- 計分板前端同一批改成不再回報這兩種（migi-table health.js、wakelock.js）；
-- 這一份讓「已經記下來的」也不算 —— 不然要等 24 小時卡片才會恢復正常。
--   · 錯誤次數與「最後一筆錯誤」都排除：訊息含 ResizeObserver loop 的、手機的螢幕常亮被拒絕
--   · 平板的螢幕常亮被拒絕照算（那是真的要處理的）
-- 只換 _tbl_device_report 裡那兩段條件（線上比對過剛好兩處），其餘一個字都不改；對不上就整份不執行。
-- ============================================================

do $$
declare
  v_def text := replace(pg_get_functiondef('public._tbl_device_report'::regproc), E'\r\n', E'\n');
  v_old text := $o$where e.event = 'table_error' and e.created_at > now() - interval '24 hours'$o$;
  v_new text := $n$where e.event = 'table_error' and e.created_at > now() - interval '24 hours'
                      and coalesce(e.props ->> 'msg', '') !~* 'ResizeObserver loop'          -- 無害警告（2026-10-13）
                      and not (dv.kind = 'phone' and e.props ->> 'kind' = 'wakelock')$n$;   -- 手機不能常亮是常態
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 2 then
    raise exception '_tbl_device_report 的條件對不上（應該剛好兩處），整份不執行';   -- 守衛
  end if;
  execute replace(v_def, v_old, v_new);
end $$;


-- ============================================================
-- 驗證（單一 SELECT，不 raise）
--   ① 版本數 1、兩處都排除了（舊版會紅 —— 正對照）
--   ② ℹ 排除前後的差：近 24 小時手機的錯誤總數（原本算法 → 新算法）
-- ============================================================
select concat_ws(E'\n',
  case when (select count(*) from pg_proc where proname = '_tbl_device_report' and pronamespace = 'public'::regnamespace) = 1
        and (select (length(x) - length(replace(x, 'ResizeObserver loop', ''))) / length('ResizeObserver loop')
               from (select pg_get_functiondef('public._tbl_device_report'::regproc) as x) y) >= 2
       then '① ✅ 錯誤次數與最後一筆錯誤都排除了無害警告' else '① 🔴 沒改到' end,
  '② ℹ 近 24 小時手機的錯誤：原本算法 '
    || (select count(*) from app_events e join table_devices d on e.props ->> 'device_id' = d.id::text
         where e.event = 'table_error' and e.created_at > now() - interval '24 hours' and d.kind = 'phone')
    || ' 筆 → 新算法 '
    || (select count(*) from app_events e join table_devices d on e.props ->> 'device_id' = d.id::text
         where e.event = 'table_error' and e.created_at > now() - interval '24 hours' and d.kind = 'phone'
           and coalesce(e.props ->> 'msg', '') !~* 'ResizeObserver loop'
           and not (e.props ->> 'kind' = 'wakelock'))
    || ' 筆'
) as "驗證";
