/* ============================================================
   結算抽屜「完成」與 LINE「查看成績」（2026-10-07）

   使用者規格：
   · LINE 牌局結束卡片的「查看成績」→ 那一場的結算抽屜**還沒按過「完成」**就打開結算抽屜（可以按讚）；
     **已經按過「完成」**就跳成績頁。
   · 配桌頁的結算提示：沒完成就一直在，按了「完成」才消失。

   🔴 「完成」**不可以借用已讀**（read_at）：
     · 鈴鐺紅點數的是未讀 ⇒ 結算要未讀到按完成為止的話，紅點會一直掛著
     · 打開通知中心離開時會全部標已讀（mark_notifs_read_tx）⇒ 結算會被一起標成「完成」
     ⇒ 另開一欄 done_at。通知規格本來就把三件事分開：送達 → 已讀 → 已處理（docs/03 通知系統規格 §0）。

   ── 改了什麼 ─────────────────────────────────────────
   ① app_notifications.done_at：這則通知要做的事做完了沒（目前只有結算用：結算抽屜按了「完成」）
   ② mark_settle_done_tx(session)：本人那一場的結算通知記成完成（順便標已讀）—— 只給 authenticated
   ③ list_notifications_tx：每則多回 'done'（只改這一處，撈線上全文替換；換不到就整份停下）
   ④ _push_settle_fields：「查看成績」網址多帶 &settle=<這一場>（同上做法）
      ⚠ 還留著 tab=stats：App 還沒更新到新版時，照舊開成績頁，不會壞

   ⚠ ③④ 的替換是「先確定換得到才執行」，換不到就 raise 讓整份回滾 —— 那是**故意不要提交**的情況（硬規則 1.8）。
   ⚠ 驗證段只有一支 SELECT，不用 raise。跑完我會另外查一次線上。
   ============================================================ */

-- ① 完成時間
alter table public.app_notifications add column if not exists done_at timestamptz;
comment on column public.app_notifications.done_at is
  '這則通知要做的事做完了沒（跟 read_at 已讀分開）。目前只有 settle：結算抽屜按了「完成」（2026-10-07）';

-- ② 這一場的結算完成了
create or replace function public.mark_settle_done_tx(p_session uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := public.current_member_id();
  v_n int;
begin
  if v_me is null then
    raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000';
  end if;
  update app_notifications
     set done_at = coalesce(done_at, now()),
         read_at = coalesce(read_at, now())
   where member_id = v_me and type = 'settle' and ref_id = p_session;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'marked', v_n);
end $$;
revoke execute on function public.mark_settle_done_tx(uuid) from public, anon;
grant  execute on function public.mark_settle_done_tx(uuid) to authenticated;

-- ③④ 只改一處的兩支：撈線上全文 → 換掉那一處 → 確定換到才執行
do $$
declare v_old text; v_new text;
begin
  -- ③ 通知清單多回 done
  v_old := pg_get_functiondef('public.list_notifications_tx(uuid,uuid)'::regprocedure);
  v_new := replace(v_old, '''unread'', (n.read_at is null),',
                          '''unread'', (n.read_at is null), ''done'', (n.done_at is not null),');
  if v_new = v_old then raise exception '③ list_notifications_tx 找不到要換的那一處，整份不動'; end if;
  execute v_new;

  -- ④ 查看成績的網址帶這一場
  v_old := pg_get_functiondef('public._push_settle_fields(uuid)'::regprocedure);
  v_new := replace(v_old, '?tab=stats'');', '?tab=stats&settle='' || v_sid);');
  if v_new = v_old then raise exception '④ _push_settle_fields 找不到要換的那一處，整份不動'; end if;
  execute v_new;
end $$;

/* ── 驗證（單一 SELECT）──────────────────────────────────────
   ⑤ 借線上一則有名次的結算通知試組卡片，看按鈕網址；找不到樣本就印 ⚪ */
with ok as (
  select n.id, n.ref_id from app_notifications n
    join session_players sp on sp.session_id = n.ref_id and sp.member_id = n.member_id and sp.finish_rank is not null
   where n.type = 'settle' order by n.created_at desc limit 1
)
select concat_ws(E'\n',
  case when exists (select 1 from information_schema.columns where table_schema = 'public'
                     and table_name = 'app_notifications' and column_name = 'done_at')
       then '✅ ① 通知多了「完成時間」欄' else '🔴 ① 欄位不在' end,
  case when has_function_privilege('authenticated', 'public.mark_settle_done_tx(uuid)', 'execute')
        and not has_function_privilege('anon', 'public.mark_settle_done_tx(uuid)', 'execute')
        and pg_get_functiondef('public.mark_settle_done_tx(uuid)'::regprocedure) ~ 'member_id = v_me and type = ''settle'''
       then '✅ ② 結算完成：登入的人叫得動、只標本人的' else '🔴 ② 授權或內容不對' end,
  case when pg_get_functiondef('public.list_notifications_tx(uuid,uuid)'::regprocedure) ~ '''done'', \(n\.done_at is not null\)'
        and pg_get_functiondef('public.list_notifications_tx(uuid,uuid)'::regprocedure) ~ 'current_member_id'
        and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'list_notifications_tx') = 1
       then '✅ ③ 通知清單多回「完成了沒」，身分檢查還在、版本數 1' else '🔴 ③ 通知清單沒換到或換壞了' end,
  coalesce((select case when public._push_settle_fields(ok.id) ->> 'url' = 'https://liff.line.me/2011312117-Zuul0Ndo?tab=stats&settle=' || ok.ref_id
                        then '✅ ④ 查看成績網址：' || (public._push_settle_fields(ok.id) ->> 'url')
                        else '🔴 ④ 網址不對：' || coalesce(public._push_settle_fields(ok.id) ->> 'url', 'null') end from ok),
           '⚪ ④ 線上沒有有名次的結算通知可以試')
) as "驗證";
