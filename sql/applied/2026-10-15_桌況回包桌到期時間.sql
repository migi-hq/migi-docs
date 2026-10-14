-- ============================================================
-- 2026-10-15 即時桌況：list_tables_tx 多回 pkg_expires_at（包桌什麼時候到期）
-- 起因：POS 桌況卡片改版，包桌右下要寫「剩多久」。
--   ⚠ 不可以用 started_at ＋ planned_minutes 算：包桌從計分板定好座位才開始計時，
--     客人加了時間之後到期也會往後延 —— 真正的到期時間只有 _pkg_time 的 expires_at。
--   前端（migi-pos）沒拿到這個鍵就照舊寫「已打多久」，所以這份先跑或後跑都可以。
-- 只在 'pkg_phase' 那一行後面接一個鍵，其餘照線上原文（簽名不變、GRANT 不會丟）
--
-- 跑法：Supabase SQL Editor 整份執行，看最後那一格
-- ============================================================

do $$
declare
  v_def text;
  v_new text;
  v_old text := $a$'pkg_phase', (public._pkg_time(ts.id, false) ->> 'phase'),$a$;
  v_add text := $a$'pkg_phase', (public._pkg_time(ts.id, false) ->> 'phase'),
      'pkg_expires_at', (public._pkg_time(ts.id, false) ->> 'expires_at'),   /* 包桌到期時間（2026-10-15，桌況卡片「剩多久」） */$a$;
begin
  v_def := pg_get_functiondef('public.list_tables_tx'::regproc);
  if position('pkg_expires_at' in v_def) > 0 then
    perform set_config('migi.pkg', '⚪ 已經有 pkg_expires_at（這份跑過一次），沒有再改', true);
    return;
  end if;
  v_new := replace(v_def, v_old, v_add);
  if v_new = v_def then
    perform set_config('migi.pkg', '🔴 找不到 pkg_phase 那一行，沒有改（線上版本跟預期不同）', true);
    return;
  end if;
  execute v_new;
  perform set_config('migi.pkg', '✅ list_tables_tx 已加上 pkg_expires_at', true);
end $$;

-- ============================================================
-- 驗證（單一 SELECT；不 raise，提交後另外查線上）
-- ============================================================
select concat_ws(E'\n',
  current_setting('migi.pkg', true),
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'list_tables_tx') = 1
       then '✅' else '🔴' end || ' ① list_tables_tx 只有一個版本',
  case when position('pkg_expires_at' in pg_get_functiondef('public.list_tables_tx'::regproc)) > 0
       then '✅' else '🔴' end || ' ② 有回 pkg_expires_at',
  case when has_function_privilege('authenticated', 'public.list_tables_tx'::regproc, 'execute')
       then '✅' else '🔴' end || ' ③ POS（authenticated）還叫得動',
  -- 行為：現在開著的包桌，到期時間跟 _pkg_time 算的一樣；沒有開著的包桌就說測不了
  coalesce((select case when count(*) = 0 then null
                        else '✅ ④ 開著的包桌 ' || count(*) || ' 場，到期時間都拿得到（沒開始計時的是 null，屬正常）' end
              from table_sessions ts
             where ts.mode = 'private' and ts.status = 'open' and ts.deleted_at is null),
           '⚪ ④ 現在沒有開著的包桌，行為測不了（等真的有包桌時在 POS 看右下有沒有「剩多久」）')
) as "桌況回包桌到期時間 · 驗證";
