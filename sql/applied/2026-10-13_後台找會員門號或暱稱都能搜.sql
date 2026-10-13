-- ============================================================
-- 管理後台找會員：門號或暱稱都能搜（「會員」頁的隱藏／恢復、「智慧計分板」頁的發配對碼共用這一支）
-- 2026-10-13 · MIGI 咪吉麻將
--
-- 使用者：「門號或暱稱都要能搜」
--   原本只比對門號（至少 4 碼）。現在：
--   · 輸入裡有 4 碼以上的數字 ⇒ 比對門號（同原本）
--   · 同時比對暱稱（含隱藏中的人的真名 —— 隱藏時名字搬進 member_hidden，總部要認得出是誰）
--   · 暱稱比對不分大小寫、部分符合就算；% 與 _ 當一般字元（不當萬用字元）
-- ⚠ 參數名稱 p_phone 刻意不改：改名要 DROP 重建、補授權，兩個前端也要一起改；它現在的意思是「搜尋字」。
-- 其餘（權限 member.hide、只找自己機構、最多 20 筆、回傳欄位）一個字都不改。簽名不變 ⇒ CREATE OR REPLACE。
-- ============================================================

create or replace function public.admin_find_members_tx(p_phone text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_q text := btrim(coalesce(p_phone, ''));                       -- 搜尋字（門號或暱稱）
  v_p text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'); -- 裡面的數字（比對門號用）
  v_like text;
begin
  if not public.can('member.hide') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '只有總部可以查詢');
  end if;
  if v_q = '' then
    return jsonb_build_object('ok', true, 'rows', '[]'::jsonb);
  end if;
  -- 暱稱的部分比對：% 與 _ 當一般字元
  v_like := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  /* ⚠ limit 要放在子查詢裡 —— 寫在 jsonb_agg 那一層的話它限制的是
     「聚合完的那一列」，等於沒限制。 */
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', x.id,
             'name', x.name,
             'phone', x.phone,
             'line_bound', x.line_bound,
             'created_at', x.created_at,
             'hidden_at', x.hidden_at,
             'hidden_source', (select l.source from member_hide_log l
                                where l.member_id = x.id and l.action = 'hide'
                                order by l.at desc limit 1),
             'hidden_reason', (select l.reason from member_hide_log l
                                where l.member_id = x.id and l.action = 'hide'
                                order by l.at desc limit 1))
           order by x.created_at)
      from (
        select m.id, coalesce(h.display_name, m.display_name) as name, m.phone,
               m.line_user_id is not null as line_bound, m.created_at, m.hidden_at
          from members m
          left join member_hidden h on h.member_id = m.id
         where m.org_id = (select s.org_id from staff s
                            where s.id = (select staff_id from public.current_staff()))
           and m.deleted_at is null
           and ((length(v_p) >= 4 and m.phone like '%' || v_p || '%')
                or coalesce(h.display_name, m.display_name) ilike v_like)
         order by m.created_at
         limit 20
      ) x), '[]'::jsonb));
end $function$;


-- ============================================================
-- 驗證（單一 SELECT，不 raise）
--   ① 版本數 1、DEFINER、權限判斷還在
--   ② 有比對暱稱、門號那一段還在
--   ③ 不是總部 ⇒ forbidden（這個查詢裡沒有登入身分，擋牆是活的；實際搜尋請在後台試）
--   ④ ℹ 用同一段條件試算：搜「陳」會找到幾位（正對照：暱稱比對有作用）
-- ============================================================
select concat_ws(E'\n',
  case when (select count(*) from pg_proc where proname = 'admin_find_members_tx' and pronamespace = 'public'::regnamespace) = 1
        and (select prosecdef from pg_proc where proname = 'admin_find_members_tx' and pronamespace = 'public'::regnamespace)
        and (select pg_get_functiondef('public.admin_find_members_tx'::regproc) ~ 'can\(''member\.hide''\)')
       then '① ✅ 版本數 1、DEFINER、權限判斷還在' else '① 🔴 函式不對' end,
  case when (select pg_get_functiondef('public.admin_find_members_tx'::regproc) ~ 'ilike v_like'
                and pg_get_functiondef('public.admin_find_members_tx'::regproc) ~ 'm\.phone like')
       then '② ✅ 門號、暱稱都會比對' else '② 🔴 沒改到' end,
  case when public.admin_find_members_tx('陳') ->> 'reason' = 'forbidden'
       then '③ ✅ 沒有總部身分 ⇒ 擋下' else '③ 🔴 沒有身分也查得到' end,
  '④ ℹ 搜「陳」（暱稱）會找到 '
    || (select count(*) from members m left join member_hidden h on h.member_id = m.id
         where m.deleted_at is null and coalesce(h.display_name, m.display_name) ilike '%陳%') || ' 位'
) as "驗證";
